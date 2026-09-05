import Foundation

public struct TokenPlatform: RawRepresentable, Codable, Equatable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public var id: String { self.rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        default: self.rawValue.capitalized
        }
    }

    public var shortLabel: String {
        switch self {
        case .codex: "C"
        case .claude: "A"
        case .grok: "G"
        case .antigravity: "AG"
        default: String(self.displayName.prefix(1))
        }
    }

    public static let codex = TokenPlatform(rawValue: "codex")
    public static let claude = TokenPlatform(rawValue: "claude")
    public static let grok = TokenPlatform(rawValue: "grok")
    public static let antigravity = TokenPlatform(rawValue: "antigravity")
}

public enum DashboardScope: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case codex
    case claude
    case grok
    case antigravity

    public var id: String { self.rawValue }

    public var displayName: String {
        switch self {
        case .codex: TokenPlatform.codex.displayName
        case .claude: TokenPlatform.claude.displayName
        case .grok: TokenPlatform.grok.displayName
        case .antigravity: TokenPlatform.antigravity.displayName
        }
    }

    public var platform: TokenPlatform {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .grok: .grok
        case .antigravity: .antigravity
        }
    }

    public var supportsCodexMemory: Bool {
        self == .codex
    }

    public static func visibleScopes(
        showsClaude: Bool,
        showsGrok: Bool,
        showsAntigravity: Bool) -> [Self]
    {
        Self.allCases.filter { scope in
            switch scope {
            case .codex: true
            case .claude: showsClaude
            case .grok: showsGrok
            case .antigravity: showsAntigravity
            }
        }
    }
}

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

    public var displayedInput: Int64 {
        self.input.saturatingAdd(self.cacheWrite)
    }

    public var displayedCache: Int64 {
        self.cacheRead
    }

    public static let zero = TokenBreakdown(
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        reasoning: 0)
}

public struct TokenCostBreakdown: Codable, Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let reasoning: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, reasoning: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public var displayedInput: Double {
        self.input + self.cacheWrite
    }

    public var displayedCache: Double {
        self.cacheRead
    }

    public var total: Double {
        self.input + self.output + self.cacheRead + self.cacheWrite + self.reasoning
    }
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

public enum QuotaSnapshotOrigin: String, Codable, Equatable, Sendable {
    case liveProvider
    case claudeDesktop
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let session: QuotaWindowSnapshot?
    public let weekly: QuotaWindowSnapshot?
    public let resetCredits: QuotaResetCreditsSnapshot?
    public let updatedAt: Date
    public let origin: QuotaSnapshotOrigin?

    public init(
        session: QuotaWindowSnapshot?,
        weekly: QuotaWindowSnapshot?,
        resetCredits: QuotaResetCreditsSnapshot?,
        updatedAt: Date,
        origin: QuotaSnapshotOrigin? = nil)
    {
        self.session = session
        self.weekly = weekly
        self.resetCredits = resetCredits
        self.updatedAt = updatedAt
        self.origin = origin
    }

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

public enum ActivityServiceTier: String, Codable, Equatable, Sendable {
    case unknown
    case standard
    case fast
    case mixed

    public static func combining(_ tiers: some Sequence<ActivityServiceTier>) -> ActivityServiceTier {
        var knownTier: ActivityServiceTier?
        for tier in tiers where tier != .unknown {
            if tier == .mixed {
                return .mixed
            }
            if let knownTier, knownTier != tier {
                return .mixed
            }
            knownTier = tier
        }
        return knownTier ?? .unknown
    }
}

public struct RequestSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let platform: TokenPlatform?
    public let sessionId: String
    public let physicalSessionId: String
    public let isSubagent: Bool
    public let agent: String?
    public let model: String
    public let provider: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let durationMs: Int64?
    public let modelDurationMs: Int64?
    public let timeToFirstTokenMs: Int64?
    public let tokens: TokenBreakdown
    public let costUsd: Double
    public let costSource: ActivityCostSource
    public let promptPreview: String?
    public let outputPreview: String?
    public let sessionPath: String?
    public let contributions: [RequestSummary]?
    public let serviceTier: ActivityServiceTier?

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
        modelDurationMs: Int64? = nil,
        timeToFirstTokenMs: Int64? = nil,
        tokens: TokenBreakdown,
        costUsd: Double,
        costSource: ActivityCostSource,
        promptPreview: String?,
        outputPreview: String?,
        sessionPath: String?,
        contributions: [RequestSummary]? = nil,
        serviceTier: ActivityServiceTier? = nil,
        platform: TokenPlatform? = nil)
    {
        self.id = id
        self.platform = platform
        self.sessionId = sessionId
        self.physicalSessionId = physicalSessionId
        self.isSubagent = isSubagent
        self.agent = agent
        self.model = model
        self.provider = provider
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.durationMs = durationMs
        self.modelDurationMs = modelDurationMs
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.tokens = tokens
        self.costUsd = costUsd
        self.costSource = costSource
        self.promptPreview = promptPreview
        self.outputPreview = outputPreview
        self.sessionPath = sessionPath
        self.contributions = contributions
        self.serviceTier = serviceTier
    }

    public var startedAt: Date {
        Date(timeIntervalSince1970: Double(self.startedAtMs) / 1000)
    }

    public var platformID: TokenPlatform {
        self.platform ?? .codex
    }

    public var platformScopedID: String {
        "\(self.platformID.rawValue):\(self.id)"
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
            modelDurationMs: self.modelDurationMs,
            timeToFirstTokenMs: self.timeToFirstTokenMs,
            tokens: self.tokens,
            costUsd: self.costUsd,
            costSource: self.costSource,
            promptPreview: nil,
            outputPreview: nil,
            sessionPath: nil,
            contributions: self.contributions?.map { $0.redactedForCache() },
            serviceTier: self.serviceTier,
            platform: self.platform)
    }
}

public struct SessionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let platform: TokenPlatform?
    public let title: String?
    public let workspacePath: String?
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
        title: String? = nil,
        workspacePath: String? = nil,
        platform: TokenPlatform? = nil)
    {
        self.id = id
        self.platform = platform
        self.title = title
        self.workspacePath = workspacePath
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

    public var platformID: TokenPlatform {
        self.platform ?? .codex
    }

    public var platformScopedID: String {
        "\(self.platformID.rawValue):\(self.id)"
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
            title: nil,
            workspacePath: nil,
            platform: self.platform)
    }
}

public struct SessionMenuProjection: Equatable, Sendable {
    public let visibleSessions: [SessionSummary]
    public let remainingCount: Int
}

public struct ActivityTotals: Codable, Equatable, Sendable {
    public let tokens: TokenBreakdown
    public let costUsd: Double
    public let tokenCosts: TokenCostBreakdown?
    public let averageGenerationTokensPerSecond: Double?
    public let averageTimeToFirstTokenMs: Double?
    public let firstTokenSampleCount: Int?
    public let requestCount: Int
    public let sessionCount: Int

    public init(
        tokens: TokenBreakdown,
        costUsd: Double,
        requestCount: Int,
        sessionCount: Int,
        tokenCosts: TokenCostBreakdown? = nil,
        averageGenerationTokensPerSecond: Double? = nil,
        averageTimeToFirstTokenMs: Double? = nil,
        firstTokenSampleCount: Int? = nil)
    {
        self.tokens = tokens
        self.costUsd = costUsd
        self.tokenCosts = tokenCosts
        self.averageGenerationTokensPerSecond = averageGenerationTokensPerSecond
        self.averageTimeToFirstTokenMs = averageTimeToFirstTokenMs
        self.firstTokenSampleCount = firstTokenSampleCount
        self.requestCount = requestCount
        self.sessionCount = sessionCount
    }

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
    public let platform: TokenPlatform?
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
        sessionCount: Int,
        platform: TokenPlatform? = nil)
    {
        self.platform = platform
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
    public let averageGenerationTokensPerSecond: Double?
    public let averageTimeToFirstTokenMs: Double?
    public let firstTokenSampleCount: Int?
    public let requestCount: Int
    public let sessionCount: Int
    public let models: [DailyModelSummary]

    public init(
        date: String,
        tokens: TokenBreakdown,
        costUsd: Double,
        requestCount: Int,
        sessionCount: Int,
        averageGenerationTokensPerSecond: Double? = nil,
        averageTimeToFirstTokenMs: Double? = nil,
        firstTokenSampleCount: Int? = nil,
        models: [DailyModelSummary] = [])
    {
        self.date = date
        self.tokens = tokens
        self.costUsd = costUsd
        self.averageGenerationTokensPerSecond = averageGenerationTokensPerSecond
        self.averageTimeToFirstTokenMs = averageTimeToFirstTokenMs
        self.firstTokenSampleCount = firstTokenSampleCount
        self.requestCount = requestCount
        self.sessionCount = sessionCount
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case tokens
        case costUsd
        case averageGenerationTokensPerSecond
        case averageTimeToFirstTokenMs
        case firstTokenSampleCount
        case requestCount
        case sessionCount
        case models
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(String.self, forKey: .date)
        self.tokens = try container.decode(TokenBreakdown.self, forKey: .tokens)
        self.costUsd = try container.decode(Double.self, forKey: .costUsd)
        self.averageGenerationTokensPerSecond = try container.decodeIfPresent(
            Double.self,
            forKey: .averageGenerationTokensPerSecond)
        self.averageTimeToFirstTokenMs = try container.decodeIfPresent(
            Double.self,
            forKey: .averageTimeToFirstTokenMs)
        self.firstTokenSampleCount = try container.decodeIfPresent(
            Int.self,
            forKey: .firstTokenSampleCount)
        self.requestCount = try container.decode(Int.self, forKey: .requestCount)
        self.sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        self.models = try container.decodeIfPresent([DailyModelSummary].self, forKey: .models) ?? []
    }
}

public struct ActivitySourceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let platform: TokenPlatform
    public let today: ActivityTotals
    public let rangeTotals: ActivityTotals?
    public let weeklySinceReset: ActivityRangeSummary?
    public let days: [DailySummary]

    public init(
        platform: TokenPlatform,
        today: ActivityTotals,
        weeklySinceReset: ActivityRangeSummary?,
        days: [DailySummary],
        rangeTotals: ActivityTotals? = nil)
    {
        self.platform = platform
        self.today = today
        self.rangeTotals = rangeTotals
        self.weeklySinceReset = weeklySinceReset
        self.days = days
    }

    public var id: TokenPlatform { self.platform }
}

public struct MemoryPhaseUsage: Codable, Equatable, Sendable {
    public let total: Int64
    public let input: Int64
    public let cachedInput: Int64
    public let cacheWriteInput: Int64
    public let output: Int64
    public let reasoningOutput: Int64

    public init(
        total: Int64,
        input: Int64,
        cachedInput: Int64,
        cacheWriteInput: Int64,
        output: Int64,
        reasoningOutput: Int64)
    {
        self.total = total
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoningOutput = reasoningOutput
    }

    public var cache: Int64 {
        self.cachedInput.saturatingAdd(self.cacheWriteInput)
    }

    public func adding(_ other: MemoryPhaseUsage) -> MemoryPhaseUsage {
        MemoryPhaseUsage(
            total: self.total.saturatingAdd(other.total),
            input: self.input.saturatingAdd(other.input),
            cachedInput: self.cachedInput.saturatingAdd(other.cachedInput),
            cacheWriteInput: self.cacheWriteInput.saturatingAdd(other.cacheWriteInput),
            output: self.output.saturatingAdd(other.output),
            reasoningOutput: self.reasoningOutput.saturatingAdd(other.reasoningOutput))
    }

    public static let zero = MemoryPhaseUsage(
        total: 0,
        input: 0,
        cachedInput: 0,
        cacheWriteInput: 0,
        output: 0,
        reasoningOutput: 0)
}

public struct MemoryUsageTotals: Codable, Equatable, Sendable {
    public let phase1: MemoryPhaseUsage
    public let phase2: MemoryPhaseUsage

    public init(phase1: MemoryPhaseUsage, phase2: MemoryPhaseUsage) {
        self.phase1 = phase1
        self.phase2 = phase2
    }

    public var total: Int64 {
        self.phase1.total.saturatingAdd(self.phase2.total)
    }

    public var combined: MemoryPhaseUsage {
        self.phase1.adding(self.phase2)
    }

    public static let zero = MemoryUsageTotals(phase1: .zero, phase2: .zero)
}

public struct MemoryDailySummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { self.date }

    public let date: String
    public let phase1: MemoryPhaseUsage
    public let phase2: MemoryPhaseUsage

    public init(date: String, phase1: MemoryPhaseUsage, phase2: MemoryPhaseUsage) {
        self.date = date
        self.phase1 = phase1
        self.phase2 = phase2
    }

    public var totals: MemoryUsageTotals {
        MemoryUsageTotals(phase1: self.phase1, phase2: self.phase2)
    }
}

public struct MemoryUsageSnapshot: Codable, Equatable, Sendable {
    public let collectedFromMs: Int64
    public let lastReceivedAtMs: Int64?
    public let lastMemoryReceivedAtMs: Int64?
    public let observationCount: Int64
    public let today: MemoryUsageTotals
    public let rangeTotals: MemoryUsageTotals
    public let days: [MemoryDailySummary]

    public init(
        collectedFromMs: Int64,
        lastReceivedAtMs: Int64?,
        lastMemoryReceivedAtMs: Int64?,
        observationCount: Int64,
        today: MemoryUsageTotals,
        rangeTotals: MemoryUsageTotals,
        days: [MemoryDailySummary])
    {
        self.collectedFromMs = collectedFromMs
        self.lastReceivedAtMs = lastReceivedAtMs
        self.lastMemoryReceivedAtMs = lastMemoryReceivedAtMs
        self.observationCount = observationCount
        self.today = today
        self.rangeTotals = rangeTotals
        self.days = days
    }

    public var collectedFrom: Date {
        Date(timeIntervalSince1970: Double(self.collectedFromMs) / 1000)
    }

    public var lastReceivedAt: Date? {
        self.lastReceivedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    public var lastMemoryReceivedAt: Date? {
        self.lastMemoryReceivedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAtMs: Int64
    public let timezone: String
    public let today: ActivityTotals
    public let rangeTotals: ActivityTotals?
    public let weeklySinceReset: ActivityRangeSummary?
    public let sessions: [SessionSummary]
    public let days: [DailySummary]
    public let sources: [ActivitySourceSnapshot]?
    public let memoryUsage: MemoryUsageSnapshot?

    public init(
        schemaVersion: Int,
        generatedAtMs: Int64,
        timezone: String,
        today: ActivityTotals,
        sessions: [SessionSummary],
        days: [DailySummary],
        weeklySinceReset: ActivityRangeSummary? = nil,
        sources: [ActivitySourceSnapshot]? = nil,
        rangeTotals: ActivityTotals? = nil,
        memoryUsage: MemoryUsageSnapshot? = nil)
    {
        self.schemaVersion = schemaVersion
        self.generatedAtMs = generatedAtMs
        self.timezone = timezone
        self.today = today
        self.rangeTotals = rangeTotals
        self.weeklySinceReset = weeklySinceReset
        self.sessions = sessions
        self.days = days
        self.sources = sources
        self.memoryUsage = memoryUsage
    }

    public var generatedAt: Date {
        Date(timeIntervalSince1970: Double(self.generatedAtMs) / 1000)
    }

    public var sourceSnapshots: [ActivitySourceSnapshot] {
        self.sources ?? []
    }

    public func scoped(to platform: TokenPlatform?) -> ActivitySnapshot {
        guard let platform else { return self }
        guard let source = self.sourceSnapshots.first(where: { $0.platform == platform }) else {
            if platform == .codex, self.sourceSnapshots.isEmpty {
                return self
            }
            return ActivitySnapshot(
                schemaVersion: self.schemaVersion,
                generatedAtMs: self.generatedAtMs,
                timezone: self.timezone,
                today: .zero,
                sessions: [],
                days: self.days.map {
                    DailySummary(
                        date: $0.date,
                        tokens: .zero,
                        costUsd: 0,
                        requestCount: 0,
                        sessionCount: 0)
                },
                sources: [],
                rangeTotals: .zero,
                memoryUsage: platform == .codex ? self.memoryUsage : nil)
        }
        return ActivitySnapshot(
            schemaVersion: self.schemaVersion,
            generatedAtMs: self.generatedAtMs,
            timezone: self.timezone,
            today: source.today,
            sessions: self.sessions.filter { $0.platformID == platform },
            days: source.days,
            weeklySinceReset: source.weeklySinceReset,
            sources: [source],
            rangeTotals: source.rangeTotals,
            memoryUsage: platform == .codex ? self.memoryUsage : nil)
    }

    public func redactedForCache() -> ActivitySnapshot {
        ActivitySnapshot(
            schemaVersion: self.schemaVersion,
            generatedAtMs: self.generatedAtMs,
            timezone: self.timezone,
            today: self.today,
            sessions: self.sessions.map { $0.redactedForCache() },
            days: self.days,
            weeklySinceReset: self.weeklySinceReset,
            sources: self.sources,
            rangeTotals: self.rangeTotals,
            memoryUsage: self.memoryUsage)
    }

    public func sessionMenu(limit: Int?) -> SessionMenuProjection {
        let sorted = self.sessions.sorted {
            if $0.endedAtMs != $1.endedAtMs {
                return $0.endedAtMs > $1.endedAtMs
            }
            return $0.platformScopedID < $1.platformScopedID
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
