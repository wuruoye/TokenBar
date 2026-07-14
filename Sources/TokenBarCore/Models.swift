import Foundation

public struct TokenBreakdown: Codable, Equatable, Sendable {
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let reasoning: Int64

    public init(input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, reasoning: Int64) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public var total: Int64 {
        self.input
            .saturatingAdd(self.output)
            .saturatingAdd(self.cacheRead)
            .saturatingAdd(self.cacheWrite)
            .saturatingAdd(self.reasoning)
    }

    public static let zero = TokenBreakdown(
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        reasoning: 0)
}

public struct QuotaWindowSnapshot: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

public struct QuotaResetCreditsSnapshot: Codable, Equatable, Sendable {
    public let availableCount: Int
    public let nextExpiresAt: Date?

    public init(availableCount: Int, nextExpiresAt: Date?) {
        self.availableCount = max(0, availableCount)
        self.nextExpiresAt = nextExpiresAt
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let session: QuotaWindowSnapshot?
    public let weekly: QuotaWindowSnapshot?
    public let resetCredits: QuotaResetCreditsSnapshot?
    public let updatedAt: Date

    public var mostConstrainedWindow: (label: String, window: QuotaWindowSnapshot)? {
        [("5h", self.session), ("W", self.weekly)]
            .compactMap { label, window in window.map { (label, $0) } }
            .min { $0.1.remainingPercent < $1.1.remainingPercent }
    }
}

public enum ActivityCostSource: String, Codable, Equatable, Sendable {
    case unknown
    case providerReported
    case estimated
}

public struct RequestSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let physicalSessionId: String
    public let isSubagent: Bool
    public let agent: String?
    public let model: String
    public let provider: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let durationMs: Int64?
    public let tokens: TokenBreakdown
    public let costUsd: Double
    public let costSource: ActivityCostSource
    public let promptPreview: String?
    public let outputPreview: String?
    public let sessionPath: String?
    public let contributions: [RequestSummary]?

    public init(
        id: String,
        sessionId: String,
        physicalSessionId: String,
        isSubagent: Bool,
        agent: String?,
        model: String,
        provider: String,
        startedAtMs: Int64,
        endedAtMs: Int64,
        durationMs: Int64?,
        tokens: TokenBreakdown,
        costUsd: Double,
        costSource: ActivityCostSource,
        promptPreview: String?,
        outputPreview: String?,
        sessionPath: String?,
        contributions: [RequestSummary]? = nil)
    {
        self.id = id
        self.sessionId = sessionId
        self.physicalSessionId = physicalSessionId
        self.isSubagent = isSubagent
        self.agent = agent
        self.model = model
        self.provider = provider
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.durationMs = durationMs
        self.tokens = tokens
        self.costUsd = costUsd
        self.costSource = costSource
        self.promptPreview = promptPreview
        self.outputPreview = outputPreview
        self.sessionPath = sessionPath
        self.contributions = contributions
    }

    public var startedAt: Date {
        Date(timeIntervalSince1970: Double(self.startedAtMs) / 1000)
    }

    public var menuTitle: String {
        if let prompt = self.promptPreview?.normalizedMenuText {
            return prompt
        }
        if let agent = self.agent?.normalizedMenuText {
            return agent
        }
        return self.model.normalizedMenuText ?? "Request"
    }

    public var physicalRequests: [RequestSummary] {
        guard let contributions = self.contributions, !contributions.isEmpty else {
            return [self]
        }
        return contributions.flatMap(\.physicalRequests)
    }

    public func redactedForCache() -> RequestSummary {
        RequestSummary(
            id: self.id,
            sessionId: self.sessionId,
            physicalSessionId: self.physicalSessionId,
            isSubagent: self.isSubagent,
            agent: self.agent,
            model: self.model,
            provider: self.provider,
            startedAtMs: self.startedAtMs,
            endedAtMs: self.endedAtMs,
            durationMs: self.durationMs,
            tokens: self.tokens,
            costUsd: self.costUsd,
            costSource: self.costSource,
            promptPreview: nil,
            outputPreview: nil,
            sessionPath: nil,
            contributions: self.contributions?.map { $0.redactedForCache() })
    }
}

public struct SessionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let workspaceLabel: String?
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let tokens: TokenBreakdown
    public let costUsd: Double
    public let models: [String]
    public let requests: [RequestSummary]

    public init(
        id: String,
        workspaceLabel: String?,
        startedAtMs: Int64,
        endedAtMs: Int64,
        tokens: TokenBreakdown,
        costUsd: Double,
        models: [String],
        requests: [RequestSummary],
        title: String? = nil)
    {
        self.id = id
        self.title = title
        self.workspaceLabel = workspaceLabel
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.tokens = tokens
        self.costUsd = costUsd
        self.models = models
        self.requests = requests
    }

    public var requestCount: Int {
        self.requests.count
    }

    public var menuTitle: String {
        if let title = self.title?.normalizedMenuText {
            return title
        }
        let rootRequests = self.requests
            .filter { !$0.isSubagent }
            .sorted {
                if $0.startedAtMs != $1.startedAtMs {
                    return $0.startedAtMs < $1.startedAtMs
                }
                return $0.id < $1.id
            }
        if let prompt = rootRequests.compactMap(\.promptPreview).compactMap(\.normalizedMenuText).first {
            return prompt
        }
        if let workspace = self.workspaceLabel?.normalizedMenuText {
            return workspace
        }
        return self.models.first?.normalizedMenuText ?? "Session"
    }

    public func redactedForCache() -> SessionSummary {
        SessionSummary(
            id: self.id,
            workspaceLabel: self.workspaceLabel,
            startedAtMs: self.startedAtMs,
            endedAtMs: self.endedAtMs,
            tokens: self.tokens,
            costUsd: self.costUsd,
            models: self.models,
            requests: self.requests.map { $0.redactedForCache() },
            title: nil)
    }
}

public struct SessionMenuProjection: Equatable, Sendable {
    public let visibleSessions: [SessionSummary]
    public let remainingCount: Int
}

public struct ActivityTotals: Codable, Equatable, Sendable {
    public let tokens: TokenBreakdown
    public let costUsd: Double
    public let requestCount: Int
    public let sessionCount: Int

    public static let zero = ActivityTotals(
        tokens: .zero,
        costUsd: 0,
        requestCount: 0,
        sessionCount: 0)
}

public struct ActivityRangeSummary: Codable, Equatable, Sendable {
    public let startedAtMs: Int64
    public let totals: ActivityTotals

    public init(startedAtMs: Int64, totals: ActivityTotals) {
        self.startedAtMs = startedAtMs
        self.totals = totals
    }

    public var startedAt: Date {
        Date(timeIntervalSince1970: Double(self.startedAtMs) / 1000)
    }
}

public struct DailyModelSummary: Codable, Equatable, Sendable {
    public let model: String
    public let provider: String
    public let tokens: TokenBreakdown
    public let costUsd: Double
    public let requestCount: Int
    public let sessionCount: Int

    public init(
        model: String,
        provider: String,
        tokens: TokenBreakdown,
        costUsd: Double,
        requestCount: Int,
        sessionCount: Int)
    {
        self.model = model
        self.provider = provider
        self.tokens = tokens
        self.costUsd = costUsd
        self.requestCount = requestCount
        self.sessionCount = sessionCount
    }
}

public struct DailySummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { self.date }

    public let date: String
    public let tokens: TokenBreakdown
    public let costUsd: Double
    public let requestCount: Int
    public let sessionCount: Int
    public let models: [DailyModelSummary]

    public init(
        date: String,
        tokens: TokenBreakdown,
        costUsd: Double,
        requestCount: Int,
        sessionCount: Int,
        models: [DailyModelSummary] = [])
    {
        self.date = date
        self.tokens = tokens
        self.costUsd = costUsd
        self.requestCount = requestCount
        self.sessionCount = sessionCount
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case tokens
        case costUsd
        case requestCount
        case sessionCount
        case models
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(String.self, forKey: .date)
        self.tokens = try container.decode(TokenBreakdown.self, forKey: .tokens)
        self.costUsd = try container.decode(Double.self, forKey: .costUsd)
        self.requestCount = try container.decode(Int.self, forKey: .requestCount)
        self.sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        self.models = try container.decodeIfPresent([DailyModelSummary].self, forKey: .models) ?? []
    }
}

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAtMs: Int64
    public let timezone: String
    public let today: ActivityTotals
    public let weeklySinceReset: ActivityRangeSummary?
    public let sessions: [SessionSummary]
    public let days: [DailySummary]

    public init(
        schemaVersion: Int,
        generatedAtMs: Int64,
        timezone: String,
        today: ActivityTotals,
        sessions: [SessionSummary],
        days: [DailySummary],
        weeklySinceReset: ActivityRangeSummary? = nil)
    {
        self.schemaVersion = schemaVersion
        self.generatedAtMs = generatedAtMs
        self.timezone = timezone
        self.today = today
        self.weeklySinceReset = weeklySinceReset
        self.sessions = sessions
        self.days = days
    }

    public var generatedAt: Date {
        Date(timeIntervalSince1970: Double(self.generatedAtMs) / 1000)
    }

    public func redactedForCache() -> ActivitySnapshot {
        ActivitySnapshot(
            schemaVersion: self.schemaVersion,
            generatedAtMs: self.generatedAtMs,
            timezone: self.timezone,
            today: self.today,
            sessions: self.sessions.map { $0.redactedForCache() },
            days: self.days,
            weeklySinceReset: self.weeklySinceReset)
    }

    public func sessionMenu(limit: Int?) -> SessionMenuProjection {
        let sorted = self.sessions.sorted {
            if $0.endedAtMs != $1.endedAtMs {
                return $0.endedAtMs > $1.endedAtMs
            }
            return $0.id < $1.id
        }
        guard let limit else {
            return SessionMenuProjection(visibleSessions: sorted, remainingCount: 0)
        }
        let visible = Array(sorted.prefix(max(0, limit)))
        return SessionMenuProjection(
            visibleSessions: visible,
            remainingCount: sorted.count - visible.count)
    }
}

private extension String {
    var normalizedMenuText: String? {
        let normalized = self.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

private extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (value, overflow) = self.addingReportingOverflow(other)
        if !overflow {
            return value
        }
        return other >= 0 ? .max : .min
    }
}
