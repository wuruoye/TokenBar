import Foundation

public enum GrokQuotaServiceError: LocalizedError, Sendable {
    case logUnavailable
    case snapshotUnavailable
    case invalidSnapshot

    public var errorDescription: String? {
        switch self {
        case .logUnavailable:
            "Grok Build's local usage log was not found. Run `grok` and sign in first."
        case .snapshotUnavailable:
            "Grok quota data was not found. Open Grok Build and run `/usage` once."
        case .invalidSnapshot:
            "Grok Build returned invalid quota data."
        }
    }
}

/// Reads the latest billing snapshot that Grok Build writes to its unified log.
///
/// This intentionally does not read `auth.json` or make an authenticated
/// request on Grok's behalf. The official CLI remains the sole owner of the
/// credential and network exchange.
public struct GrokQuotaService: QuotaProviding, Sendable {
    public let platform = TokenPlatform.grok

    private let loadLog: @Sendable () throws -> Data
    private let now: @Sendable () -> Date

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let logURL = Self.logURL(environment: environment)
        self.loadLog = {
            do {
                return try Data(contentsOf: logURL, options: .mappedIfSafe)
            } catch {
                throw GrokQuotaServiceError.logUnavailable
            }
        }
        self.now = Date.init
    }

    init(
        loadLog: @escaping @Sendable () throws -> Data,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.loadLog = loadLog
        self.now = now
    }

    public func fetchQuota() async throws -> QuotaSnapshot {
        let data = try self.loadLog()
        let decoder = JSONDecoder()
        let record = data.split(separator: 0x0A).reversed().lazy.compactMap { line in
            try? decoder.decode(BillingLogRecord.self, from: Data(line))
        }.first { record in
            record.message == "billing: fetched credits config"
                && record.context?.config != nil
        }
        guard let record, let config = record.context?.config else {
            throw GrokQuotaServiceError.snapshotUnavailable
        }
        guard let usedPercent = config.usedPercent,
              usedPercent.isFinite
        else {
            throw GrokQuotaServiceError.invalidSnapshot
        }

        let resetsAt = config.currentPeriod?.end.flatMap(Self.parseDate)
            ?? config.billingPeriodEnd.flatMap(Self.parseDate)
        let windowMinutes = config.currentPeriod?.windowMinutes
        return QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: min(max(usedPercent, 0), 100),
                windowMinutes: windowMinutes,
                resetsAt: resetsAt),
            resetCredits: nil,
            updatedAt: record.timestamp.flatMap(Self.parseDate) ?? self.now())
    }

    private static func logURL(environment: [String: String]) -> URL {
        let grokHome: URL
        if let configured = environment["GROK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            grokHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let home = environment["HOME"].flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? FileManager.default.homeDirectoryForCurrentUser.path
            grokHome = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".grok", isDirectory: true)
        }
        return grokHome
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("unified.jsonl", isDirectory: false)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension GrokQuotaService {
    struct BillingLogRecord: Decodable {
        let timestamp: String?
        let message: String?
        let context: Context?

        private enum CodingKeys: String, CodingKey {
            case timestamp = "ts"
            case message = "msg"
            case context = "ctx"
        }
    }

    struct Context: Decodable {
        let config: Config?
    }

    struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let monthlyLimit: Cent?
        let used: Cent?
        let billingPeriodEnd: String?

        var usedPercent: Double? {
            if let creditUsagePercent {
                return creditUsagePercent
            }
            guard let limit = self.monthlyLimit?.value,
                  limit > 0,
                  let used = self.used?.value
            else {
                return nil
            }
            return Double(used) / Double(limit) * 100
        }
    }

    struct Period: Decodable {
        let type: String?
        let start: String?
        let end: String?

        var windowMinutes: Int? {
            if let start = self.start.flatMap(GrokQuotaService.parseDate),
               let end = self.end.flatMap(GrokQuotaService.parseDate)
            {
                let minutes = end.timeIntervalSince(start) / 60
                if minutes.isFinite, minutes > 0, minutes <= Double(Int.max) {
                    return Int(minutes.rounded())
                }
            }
            return self.type?.localizedCaseInsensitiveContains("weekly") == true
                ? 7 * 24 * 60
                : nil
        }
    }

    struct Cent: Decodable {
        let value: Int64

        private enum CodingKeys: String, CodingKey {
            case value = "val"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.value = try container.decodeIfPresent(Int64.self, forKey: .value) ?? 0
        }
    }
}
