import Darwin
import Foundation

public enum AntigravityQuotaServiceError: LocalizedError, Sendable {
    case logUnavailable
    case serverUnavailable
    case requestFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .logUnavailable:
            "Antigravity's local logs were not found. Launch Antigravity once first."
        case .serverUnavailable:
            "Antigravity's local language server is not running. Open Antigravity to refresh quota."
        case let .requestFailed(message):
            "Antigravity's local language server refused the quota request: \(message)"
        case .invalidResponse:
            "Antigravity returned quota data TokenBar could not read."
        }
    }
}

/// Reads the quota summary Antigravity's own language server serves on loopback.
///
/// Antigravity 2.0 writes its daemon port and CSRF token to
/// `~/.gemini/antigravity/daemon/*.json`, and older builds log them under
/// `~/Library/Logs/Antigravity`. TokenBar reads what Antigravity already
/// recorded and asks the local server the same question the IDE asks. This
/// never touches `~/.gemini/jetski-standalone-oauth-token` and never contacts
/// Google.
public struct AntigravityQuotaService: QuotaProviding, Sendable {
    public let platform = TokenPlatform.antigravity

    struct DaemonEndpoint: Equatable, Sendable {
        let port: Int
        let token: String
    }

    private struct DaemonRecord: Decodable {
        let pid: Int32?
        let httpPort: Int?
        let csrfToken: String?
    }

    private static let quotaPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    private let loadDaemonEndpoints: @Sendable () -> [DaemonEndpoint]
    private let loadMainLog: @Sendable () throws -> Data
    private let loadServerLog: @Sendable () throws -> Data
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let now: @Sendable () -> Date

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let daemonDirectory = Self.antigravityHomeURL(environment: environment)
            .appendingPathComponent("daemon", isDirectory: true)
        let logDirectory = Self.logDirectory(environment: environment)
        self.loadDaemonEndpoints = {
            Self.daemonEndpoints(in: daemonDirectory)
        }
        self.loadMainLog = {
            try Self.loadLog(at: logDirectory.appendingPathComponent("main.log"))
        }
        self.loadServerLog = {
            try Self.loadLog(at: logDirectory.appendingPathComponent("language_server.log"))
        }
        self.send = { request in try await URLSession.shared.data(for: request) }
        self.now = Date.init
    }

    init(
        loadDaemonEndpoints: @escaping @Sendable () -> [DaemonEndpoint] = { [] },
        loadMainLog: @escaping @Sendable () throws -> Data,
        loadServerLog: @escaping @Sendable () throws -> Data,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.loadDaemonEndpoints = loadDaemonEndpoints
        self.loadMainLog = loadMainLog
        self.loadServerLog = loadServerLog
        self.send = send
        self.now = now
    }

    public func fetchQuota() async throws -> QuotaSnapshot {
        var daemonError: AntigravityQuotaServiceError?
        for endpoint in self.loadDaemonEndpoints() {
            do {
                return try await self.fetchQuota(port: endpoint.port, token: endpoint.token)
            } catch let error as AntigravityQuotaServiceError {
                if case .serverUnavailable = error {
                    continue
                }
                daemonError = daemonError ?? error
            }
        }

        do {
            let mainLog = try self.loadMainLog()
            let serverLog = try self.loadServerLog()
            guard let token = Self.latestCSRFToken(in: mainLog),
                  let port = Self.latestHTTPPort(in: serverLog)
            else {
                throw daemonError ?? AntigravityQuotaServiceError.serverUnavailable
            }
            return try await self.fetchQuota(port: port, token: token)
        } catch let error as AntigravityQuotaServiceError {
            if let daemonError, case .logUnavailable = error {
                throw daemonError
            }
            throw error
        }
    }

    private func fetchQuota(port: Int, token: String) async throws -> QuotaSnapshot {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(Self.quotaPath)") else {
            throw AntigravityQuotaServiceError.serverUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = Data("{}".utf8)

        let data: Data
        do {
            let (body, response) = try await self.send(request)
            guard let response = response as? HTTPURLResponse else {
                throw AntigravityQuotaServiceError.invalidResponse
            }
            guard response.statusCode == 200 else {
                throw AntigravityQuotaServiceError.requestFailed(
                    Self.failureMessage(status: response.statusCode, body: body))
            }
            data = body
        } catch let error as AntigravityQuotaServiceError {
            throw error
        } catch {
            throw AntigravityQuotaServiceError.serverUnavailable
        }

        guard let summary = try? JSONDecoder().decode(QuotaSummary.self, from: data),
              let group = Self.mostConstrainedGroup(in: summary.response.groups)
        else {
            throw AntigravityQuotaServiceError.invalidResponse
        }
        return QuotaSnapshot(
            session: Self.window(in: group, window: "5h", minutes: 300),
            weekly: Self.window(in: group, window: "weekly", minutes: 7 * 24 * 60),
            resetCredits: nil,
            updatedAt: self.now(),
            origin: .liveProvider)
    }

    /// Antigravity meters Gemini and third-party models as separate pools. Only
    /// one fits a provider tab, so report the pool that runs out first and keep
    /// both of its windows so the two rows describe the same pool.
    static func mostConstrainedGroup(in groups: [QuotaGroup]) -> QuotaGroup? {
        groups
            .filter { group in !group.buckets.isEmpty }
            .min { left, right in
                Self.lowestRemainingFraction(left) < Self.lowestRemainingFraction(right)
            }
    }

    private static func lowestRemainingFraction(_ group: QuotaGroup) -> Double {
        group.buckets.map(\.remainingFraction).min() ?? 1
    }

    private static func window(
        in group: QuotaGroup,
        window: String,
        minutes: Int) -> QuotaWindowSnapshot?
    {
        guard let bucket = group.buckets.first(where: { $0.window == window }) else {
            return nil
        }
        let remaining = min(max(bucket.remainingFraction, 0), 1)
        return QuotaWindowSnapshot(
            usedPercent: (1 - remaining) * 100,
            windowMinutes: minutes,
            resetsAt: bucket.resetTime.flatMap(Self.parseDate))
    }

    /// The IDE appends every launch to the same log, so the last spawn wins.
    static func latestCSRFToken(in log: Data) -> String? {
        Self.lastMatch(in: log, pattern: "--csrf_token ([0-9a-fA-F-]{36})")
    }

    static func latestHTTPPort(in log: Data) -> Int? {
        Self.lastMatch(
            in: log,
            pattern: "listening on random port at ([0-9]{1,5}) for HTTP\\b")
            .flatMap(Int.init)
            .flatMap { (1 ... 65_535).contains($0) ? $0 : nil }
    }

    private static func lastMatch(in log: Data, pattern: String) -> String? {
        guard let text = String(data: log, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: pattern)
        else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = expression.matches(in: text, range: range).last,
              let captured = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captured])
    }

    private static func failureMessage(status: Int, body: Data) -> String {
        let detail = String(data: body.prefix(200), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detail, !detail.isEmpty else { return "HTTP \(status)" }
        return "HTTP \(status): \(detail)"
    }

    private static func loadLog(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AntigravityQuotaServiceError.logUnavailable
        }
    }

    public static func antigravityHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let configured = environment["ANTIGRAVITY_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let home = environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".gemini/antigravity", isDirectory: true)
    }

    static func daemonEndpoints(in directory: URL) -> [DaemonEndpoint] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        let candidates = files.compactMap { url -> (url: URL, modifiedAt: Date, isHub: Bool)? in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  (values.fileSize ?? .max) <= 64 * 1024
            else {
                return nil
            }
            return (
                url,
                values.contentModificationDate ?? .distantPast,
                url.lastPathComponent.hasPrefix("hub_"))
        }.sorted { left, right in
            if left.isHub != right.isHub {
                return left.isHub && !right.isHub
            }
            return left.modifiedAt > right.modifiedAt
        }
        let decoder = JSONDecoder()
        var seen = Set<Int>()
        var endpoints: [DaemonEndpoint] = []
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate.url),
                  let record = try? decoder.decode(DaemonRecord.self, from: data),
                  let port = record.httpPort,
                  (1 ... 65_535).contains(port),
                  let token = record.csrfToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else {
                continue
            }
            if let pid = record.pid, !Self.isProcessAlive(pid) {
                continue
            }
            if seen.insert(port).inserted {
                endpoints.append(DaemonEndpoint(port: port, token: token))
            }
        }
        return endpoints
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func logDirectory(environment: [String: String]) -> URL {
        if let configured = environment["ANTIGRAVITY_LOG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let home = environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Logs/Antigravity", isDirectory: true)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

extension AntigravityQuotaService {
    struct QuotaSummary: Decodable {
        let response: QuotaResponse
    }

    struct QuotaResponse: Decodable {
        let groups: [QuotaGroup]
    }

    struct QuotaGroup: Decodable {
        let displayName: String?
        let buckets: [QuotaBucket]
    }

    struct QuotaBucket: Decodable {
        let bucketId: String?
        let window: String?
        let remainingFraction: Double
        let resetTime: String?
    }
}
