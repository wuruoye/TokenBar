import Foundation

public enum GrokQuotaServiceError: LocalizedError, Equatable, Sendable {
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
        var latest: (record: BillingLogRecord, config: Config)?
        var usedPercent: Double?
        for line in data.split(separator: 0x0A).reversed() {
            guard let record = try? decoder.decode(BillingLogRecord.self, from: Data(line)),
                  record.message == "billing: fetched credits config",
                  let config = record.context?.config
            else {
                continue
            }
            if latest == nil {
                latest = (record, config)
                if let percent = Self.clampedPercent(config.usedPercent) {
                    usedPercent = percent
                    break
                }
                if config.resetDate == nil {
                    break
                }
                continue
            }
            guard let targetReset = latest?.config.resetDate else { break }
            if let recordReset = config.resetDate,
               abs(recordReset.timeIntervalSince(targetReset)) > 1
            {
                break
            }
            if let percent = Self.clampedPercent(config.usedPercent),
               let recordReset = config.resetDate,
               abs(recordReset.timeIntervalSince(targetReset)) <= 1
            {
                usedPercent = percent
                break
            }
        }
        guard let latest else {
            throw GrokQuotaServiceError.snapshotUnavailable
        }
        let resetsAt = latest.config.resetDate
        guard usedPercent != nil || resetsAt != nil else {
            throw GrokQuotaServiceError.invalidSnapshot
        }
        return QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: usedPercent ?? 0,
                windowMinutes: latest.config.currentPeriod?.windowMinutes,
                resetsAt: resetsAt,
                usageKnown: usedPercent != nil),
            resetCredits: nil,
            updatedAt: latest.record.timestamp.flatMap(Self.parseDate) ?? self.now())
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

    private static func clampedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
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

        var resetDate: Date? {
            self.currentPeriod?.end.flatMap(GrokQuotaService.parseDate)
                ?? self.billingPeriodEnd.flatMap(GrokQuotaService.parseDate)
        }

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
