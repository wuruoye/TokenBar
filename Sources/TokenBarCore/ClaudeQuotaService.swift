import CryptoKit
import Foundation
import Security

public enum ClaudeQuotaServiceError: LocalizedError, Sendable {
    case credentialsUnavailable
    case invalidCredentials
    case authorizationExpired
    case requestFailed(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            "Claude Code credentials were not found. Run `claude` and sign in."
        case .invalidCredentials:
            "Claude Code credentials do not contain an OAuth access token."
        case .authorizationExpired:
            "Claude Code authorization has expired. Run `claude` to sign in again."
        case let .requestFailed(status):
            "Claude quota request failed with HTTP \(status)."
        case .invalidResponse:
            "Claude returned invalid quota data."
        }
    }
}

public struct ClaudeQuotaService: QuotaProviding, Sendable {
    public let platform = TokenPlatform.claude

    private let loadAccessToken: @Sendable () throws -> String
    private let fetchUsage: @Sendable (String) async throws -> Data
    private let loadCachedDesktopUsage: @Sendable (Date) -> Data?
    private let loadCachedStatusLineUsage: @Sendable (Date) -> Data?
    private let now: @Sendable () -> Date

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let credentialsURL = Self.credentialsURL(environment: environment)
        let keychainServices = Self.keychainCredentialServices(
            configDirectoryPath: credentialsURL.deletingLastPathComponent().path)
        self.loadAccessToken = {
            if let data = try? Data(contentsOf: credentialsURL),
               let token = Self.accessToken(from: data)
            {
                return token
            }
            if let token = Self.keychainAccessToken(services: keychainServices) {
                return token
            }
            throw ClaudeQuotaServiceError.credentialsUnavailable
        }
        self.fetchUsage = { token in
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ClaudeQuotaServiceError.invalidResponse
            }
            switch response.statusCode {
            case 200 ..< 300:
                return data
            case 401, 403:
                throw ClaudeQuotaServiceError.authorizationExpired
            default:
                throw ClaudeQuotaServiceError.requestFailed(response.statusCode)
            }
        }
        self.loadCachedDesktopUsage = { sampledAt in
            Self.cachedDesktopUsage(at: sampledAt)
        }
        let statusLineUsageURL = Self.statusLineUsageURL()
        self.loadCachedStatusLineUsage = { _ in
            try? Data(contentsOf: statusLineUsageURL)
        }
        self.now = Date.init
    }

    init(
        loadAccessToken: @escaping @Sendable () throws -> String,
        fetchUsage: @escaping @Sendable (String) async throws -> Data,
        loadCachedDesktopUsage: @escaping @Sendable (Date) -> Data? = { _ in nil },
        loadCachedStatusLineUsage: @escaping @Sendable (Date) -> Data? = { _ in nil },
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.loadAccessToken = loadAccessToken
        self.fetchUsage = fetchUsage
        self.loadCachedDesktopUsage = loadCachedDesktopUsage
        self.loadCachedStatusLineUsage = loadCachedStatusLineUsage
        self.now = now
    }

    public func fetchQuota() async throws -> QuotaSnapshot {
        do {
            let token = try self.loadAccessToken()
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClaudeQuotaServiceError.invalidCredentials
            }
            let data = try await self.fetchUsage(token)
            return try self.decodeUsage(data, origin: .liveProvider)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let snapshot = self.cachedQuota(at: self.now()) {
                return snapshot
            }
            throw error
        }
    }

    private func cachedQuota(at referenceDate: Date) -> QuotaSnapshot? {
        let desktop = self.loadCachedDesktopUsage(referenceDate)
            .flatMap { try? self.decodeUsage($0, origin: .claudeDesktop) }
        let statusLine = self.loadCachedStatusLineUsage(referenceDate)
            .flatMap { try? self.decodeUsage($0, origin: .liveProvider) }

        guard let desktop else {
            guard let statusLine,
                  Self.isFresh(statusLine, at: referenceDate)
            else {
                return nil
            }
            return statusLine
        }
        guard let statusLine else { return desktop }

        let statusLineIsFresh = Self.isFresh(statusLine, at: referenceDate)
        return QuotaSnapshot(
            session: Self.mergedWindow(
                desktop.session,
                with: statusLine.session,
                at: referenceDate,
                includeObservedWindow: statusLineIsFresh),
            weekly: Self.mergedWindow(
                desktop.weekly,
                with: statusLine.weekly,
                at: referenceDate,
                includeObservedWindow: statusLineIsFresh),
            resetCredits: nil,
            updatedAt: desktop.updatedAt,
            origin: .claudeDesktop)
    }

    private static func isFresh(_ snapshot: QuotaSnapshot, at referenceDate: Date) -> Bool {
        let age = referenceDate.timeIntervalSince(snapshot.updatedAt)
        return age >= -60 && age < 30 * 60
    }

    private static func mergedWindow(
        _ current: QuotaWindowSnapshot?,
        with observed: QuotaWindowSnapshot?,
        at referenceDate: Date,
        includeObservedWindow: Bool) -> QuotaWindowSnapshot?
    {
        guard let current else { return includeObservedWindow ? observed : nil }
        guard let reset = observed?.resetsAt,
              let windowMinutes = current.windowMinutes,
              reset > referenceDate,
              reset.timeIntervalSince(referenceDate) <= TimeInterval(windowMinutes * 60)
        else {
            return current
        }
        return QuotaWindowSnapshot(
            usedPercent: current.usedPercent,
            windowMinutes: current.windowMinutes,
            resetsAt: reset)
    }

    private func decodeUsage(
        _ data: Data,
        origin: QuotaSnapshotOrigin) throws -> QuotaSnapshot
    {
        let response: UsageResponse
        do {
            response = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw ClaudeQuotaServiceError.invalidResponse
        }
        guard response.fiveHour != nil || response.sevenDay != nil else {
            throw ClaudeQuotaServiceError.invalidResponse
        }
        return QuotaSnapshot(
            session: response.fiveHour?.snapshot(windowMinutes: 5 * 60),
            weekly: response.sevenDay?.snapshot(windowMinutes: 7 * 24 * 60),
            resetCredits: nil,
            updatedAt: response.cachedAtMilliseconds.map {
                Date(timeIntervalSince1970: $0 / 1000)
            } ?? self.now(),
            origin: origin)
    }

    private static func credentialsURL(environment: [String: String]) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent(".credentials.json", isDirectory: false)
        }
        let home = environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json", isDirectory: false)
    }

    private static func accessToken(from data: Data) -> String? {
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              let token = credentials.claudeAiOauth?.accessToken?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    static func keychainCredentialServices(configDirectoryPath: String) -> [String] {
        let normalizedPath = URL(
            fileURLWithPath: configDirectoryPath,
            isDirectory: true).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalizedPath.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return [
            "Claude Code-credentials-\(suffix)",
            "Claude Code-credentials",
        ]
    }

    private static func keychainAccessToken(services: [String]) -> String? {
        for service in services {
            guard let data = self.keychainCredentials(service: service),
                  let token = self.accessToken(from: data)
            else {
                continue
            }
            return token
        }
        return nil
    }

    private static func keychainCredentials(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func cachedDesktopUsage(at now: Date) -> Data? {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = base
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("plan-usage-history.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(PlanUsageHistory.self, from: data),
              let sample = history.samples.max(by: { $0.timestamp < $1.timestamp }),
              now.timeIntervalSince1970 * 1000 - Double(sample.timestamp) >= -60 * 1000,
              now.timeIntervalSince1970 * 1000 - Double(sample.timestamp) < 30 * 60 * 1000,
              sample.usage.fiveHour != nil || sample.usage.sevenDay != nil
        else {
            return nil
        }

        var payload: [String: Any] = [
            "_cached_at_ms": sample.timestamp,
        ]
        if let fiveHour = sample.usage.fiveHour {
            payload["five_hour"] = ["utilization": fiveHour]
        }
        if let sevenDay = sample.usage.sevenDay {
            payload["seven_day"] = ["utilization": sevenDay]
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private static func statusLineUsageURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("claude-rate-limits.json", isDirectory: false)
    }
}

private extension ClaudeQuotaService {
    struct Credentials: Decodable {
        let claudeAiOauth: OAuth?
    }

    struct OAuth: Decodable {
        let accessToken: String?
    }

    struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let cachedAtMilliseconds: Double?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case cachedAtMilliseconds = "_cached_at_ms"
        }
    }

    struct PlanUsageHistory: Decodable {
        let samples: [PlanUsageSample]
    }

    struct PlanUsageSample: Decodable {
        let timestamp: Int64
        let usage: PlanUsage

        private enum CodingKeys: String, CodingKey {
            case timestamp = "t"
            case usage = "u"
        }
    }

    struct PlanUsage: Decodable {
        let fiveHour: Double?
        let sevenDay: Double?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "fh"
            case sevenDay = "sd"
        }
    }

    struct Window: Decodable {
        let utilization: Double
        let resetsAt: String?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        func snapshot(windowMinutes: Int) -> QuotaWindowSnapshot {
            QuotaWindowSnapshot(
                usedPercent: self.utilization.clamped(to: 0 ... 100),
                windowMinutes: windowMinutes,
                resetsAt: self.resetsAt.flatMap(Self.parseDate))
        }

        private static func parseDate(_ value: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
