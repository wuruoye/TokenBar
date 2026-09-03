import Foundation

public protocol ActivityProviding: Sendable {
    func fetchActivity(
        sinceWeeklyResetAt: Date?,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot

    func fetchActivity(
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot

    func fetchSessions(
        on date: String,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> [SessionSummary]
}

public extension ActivityProviding {
    func fetchActivity() async throws -> ActivitySnapshot {
        try await self.fetchActivity(
            sinceWeeklyResetAt: nil,
            statisticsTimeZone: .utc)
    }

    func fetchActivity(sinceWeeklyResetAt: Date?) async throws -> ActivitySnapshot {
        try await self.fetchActivity(
            sinceWeeklyResetAt: sinceWeeklyResetAt,
            statisticsTimeZone: .utc)
    }

    func fetchActivity(
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        try await self.fetchActivity(
            sinceWeeklyResetAt: sinceWeeklyResetAtByPlatform[.codex],
            statisticsTimeZone: statisticsTimeZone)
    }

    func fetchSessions(
        on date: String,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> [SessionSummary]
    {
        let snapshot = try await self.fetchActivity(
            sinceWeeklyResetAtByPlatform: [:],
            statisticsTimeZone: statisticsTimeZone)
        guard snapshot.days.map(\.date).max() == date else { return [] }
        return snapshot.sessions
    }
}

public protocol ActivityHelperRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval) async throws -> Data
}

public struct SubprocessActivityHelperRunner: ActivityHelperRunning, Sendable {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval) async throws -> Data
    {
        let result = try await ProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            timeout: timeout)
        return result.stdout
    }
}

public enum ActivityServiceError: LocalizedError, Sendable {
    case helperNotFound([String])
    case emptyOutput
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .helperNotFound(paths):
            let searched = paths.isEmpty ? "no candidate paths" : paths.joined(separator: ", ")
            return "tokenbar-helper was not found (searched: \(searched))."
        case .emptyOutput:
            return "tokenbar-helper returned no activity data."
        case let .invalidOutput(message):
            return "tokenbar-helper returned invalid JSON: \(message)"
        }
    }
}

public struct ActivityService: ActivityProviding, Sendable {
    public static let helperExecutableName = "tokenbar-helper"

    private let arguments: [String]
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let memoryDatabaseURLProvider: @Sendable () async -> URL?
    private let openAIPricingCatalog: (any OpenAIPricingCatalogUpdating)?
    private let anthropicPricingCatalog: (any AnthropicPricingCatalogUpdating)?
    private let openRouterPricingCatalog: (any OpenRouterPricingCatalogUpdating)?
    private let resolveHelper: @Sendable () throws -> URL
    private let runner: any ActivityHelperRunning

    public init(
        helperURL: URL? = nil,
        arguments: [String] = [],
        memoryDatabaseURL: URL? = nil,
        memoryDatabaseURLProvider: (@Sendable () async -> URL?)? = nil,
        openAIPricingCatalog: (any OpenAIPricingCatalogUpdating)? = nil,
        anthropicPricingCatalog: (any AnthropicPricingCatalogUpdating)? = nil,
        openRouterPricingCatalog: (any OpenRouterPricingCatalogUpdating)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 120,
        runner: any ActivityHelperRunning = SubprocessActivityHelperRunner())
    {
        self.arguments = arguments
        self.memoryDatabaseURLProvider = memoryDatabaseURLProvider ?? { memoryDatabaseURL }
        self.openAIPricingCatalog = openAIPricingCatalog
        self.anthropicPricingCatalog = anthropicPricingCatalog
        self.openRouterPricingCatalog = openRouterPricingCatalog
        self.environment = environment
        self.timeout = timeout
        self.runner = runner
        self.resolveHelper = {
            try Self.resolveHelperExecutable(explicitURL: helperURL, environment: environment)
        }
    }

    init(
        arguments: [String] = [],
        memoryDatabaseURL: URL? = nil,
        memoryDatabaseURLProvider: (@Sendable () async -> URL?)? = nil,
        openAIPricingCatalog: (any OpenAIPricingCatalogUpdating)? = nil,
        anthropicPricingCatalog: (any AnthropicPricingCatalogUpdating)? = nil,
        openRouterPricingCatalog: (any OpenRouterPricingCatalogUpdating)? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval = 120,
        resolveHelper: @escaping @Sendable () throws -> URL,
        runner: any ActivityHelperRunning)
    {
        self.arguments = arguments
        self.memoryDatabaseURLProvider = memoryDatabaseURLProvider ?? { memoryDatabaseURL }
        self.openAIPricingCatalog = openAIPricingCatalog
        self.anthropicPricingCatalog = anthropicPricingCatalog
        self.openRouterPricingCatalog = openRouterPricingCatalog
        self.environment = environment
        self.timeout = timeout
        self.resolveHelper = resolveHelper
        self.runner = runner
    }

    public func fetchActivity(
        sinceWeeklyResetAt: Date?,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        var resets: [TokenPlatform: Date] = [:]
        resets[.codex] = sinceWeeklyResetAt
        return try await self.fetchActivity(
            sinceWeeklyResetAtByPlatform: resets,
            statisticsTimeZone: statisticsTimeZone)
    }

    public func fetchActivity(
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        let helperURL = try self.resolveHelper()
        let memoryDatabaseURL = await self.memoryDatabaseURLProvider()
        return try await self.fetchSnapshot(
            helperURL: helperURL,
            sinceWeeklyResetAtByPlatform: sinceWeeklyResetAtByPlatform,
            memoryDatabaseURL: memoryDatabaseURL,
            snapshotArguments: [],
            statisticsTimeZone: statisticsTimeZone)
    }

    public func fetchSessions(
        on date: String,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> [SessionSummary]
    {
        let helperURL = try self.resolveHelper()
        let snapshot = try await self.fetchSnapshot(
            helperURL: helperURL,
            sinceWeeklyResetAtByPlatform: [:],
            memoryDatabaseURL: nil,
            snapshotArguments: ["--days", "1", "--end-date", date],
            statisticsTimeZone: statisticsTimeZone)
        return snapshot.sessions
    }

    private func fetchSnapshot(
        helperURL: URL,
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        memoryDatabaseURL: URL?,
        snapshotArguments: [String],
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        async let openAIPricingURL = self.openAIPricingCatalog?.refreshIfNeeded()
        async let anthropicPricingURL = self.anthropicPricingCatalog?.refreshIfNeeded()
        async let openRouterPricingURL = self.openRouterPricingCatalog?.refreshIfNeeded()
        let pricingURLs = await (openAIPricingURL, anthropicPricingURL, openRouterPricingURL)
        let initial = try await self.runSnapshot(
            helperURL: helperURL,
            sinceWeeklyResetAtByPlatform: sinceWeeklyResetAtByPlatform,
            memoryDatabaseURL: memoryDatabaseURL,
            openAIPricingURL: pricingURLs.0,
            anthropicPricingURL: pricingURLs.1,
            openRouterPricingURL: pricingURLs.2,
            snapshotArguments: snapshotArguments,
            statisticsTimeZone: statisticsTimeZone)

        let unpricedPlatforms = Self.unpricedCatalogPlatforms(in: initial)
        guard !unpricedPlatforms.isEmpty else { return initial }
        async let refreshedOpenAIPricingURL: URL? = unpricedPlatforms.contains(.codex)
            ? self.openAIPricingCatalog?.refreshNowIfAllowed()
            : nil
        async let refreshedAnthropicPricingURL: URL? = unpricedPlatforms.contains(.claude)
            ? self.anthropicPricingCatalog?.refreshNowIfAllowed()
            : nil
        async let refreshedGooglePricingURL: URL? = unpricedPlatforms.contains(.antigravity)
            ? self.openRouterPricingCatalog?.refreshNowIfAllowed()
            : nil
        let refreshedURLs = await (
            refreshedOpenAIPricingURL,
            refreshedAnthropicPricingURL,
            refreshedGooglePricingURL)
        guard refreshedURLs.0 != nil || refreshedURLs.1 != nil || refreshedURLs.2 != nil
        else {
            return initial
        }

        return (try? await self.runSnapshot(
            helperURL: helperURL,
            sinceWeeklyResetAtByPlatform: sinceWeeklyResetAtByPlatform,
            memoryDatabaseURL: memoryDatabaseURL,
            openAIPricingURL: refreshedURLs.0 ?? pricingURLs.0,
            anthropicPricingURL: refreshedURLs.1 ?? pricingURLs.1,
            openRouterPricingURL: refreshedURLs.2 ?? pricingURLs.2,
            snapshotArguments: snapshotArguments,
            statisticsTimeZone: statisticsTimeZone)) ?? initial
    }

    private func runSnapshot(
        helperURL: URL,
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        memoryDatabaseURL: URL?,
        openAIPricingURL: URL?,
        anthropicPricingURL: URL?,
        openRouterPricingURL: URL?,
        snapshotArguments: [String],
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        let data = try await self.runner.run(
            executableURL: helperURL,
            arguments: self.helperArguments(
                sinceWeeklyResetAtByPlatform: sinceWeeklyResetAtByPlatform,
                memoryDatabaseURL: memoryDatabaseURL,
                openAIPricingURL: openAIPricingURL,
                anthropicPricingURL: anthropicPricingURL,
                openRouterPricingURL: openRouterPricingURL,
                snapshotArguments: snapshotArguments,
                statisticsTimeZone: statisticsTimeZone),
            environment: self.helperEnvironment(statisticsTimeZone: statisticsTimeZone),
            timeout: self.timeout)
        guard !data.isEmpty else { throw ActivityServiceError.emptyOutput }
        do {
            return try JSONDecoder().decode(ActivitySnapshot.self, from: data)
        } catch {
            throw ActivityServiceError.invalidOutput(error.localizedDescription)
        }
    }

    private static func unpricedCatalogPlatforms(
        in snapshot: ActivitySnapshot) -> Set<TokenPlatform>
    {
        var platforms: Set<TokenPlatform> = []
        for session in snapshot.sessions {
            for request in session.requests.flatMap(\.physicalRequests)
                where request.costSource == .unknown && request.tokens.total > 0
            {
                let platform = request.platform ?? session.platform ?? .codex
                if platform == .codex || platform == .claude || platform == .antigravity {
                    platforms.insert(platform)
                }
            }
        }
        return platforms
    }

    private func helperArguments(
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        memoryDatabaseURL: URL?,
        openAIPricingURL: URL?,
        anthropicPricingURL: URL?,
        openRouterPricingURL: URL?,
        snapshotArguments: [String],
        statisticsTimeZone: TokenBarStatisticsTimeZone) -> [String]
    {
        var arguments = self.arguments
        arguments += snapshotArguments
        arguments += ["--statistics-timezone", statisticsTimeZone.rawValue]
        if let value = Self.milliseconds(sinceWeeklyResetAtByPlatform[.codex]) {
            arguments += ["--weekly-reset-ms", String(value)]
        }
        if let value = Self.milliseconds(sinceWeeklyResetAtByPlatform[.claude]) {
            arguments += ["--claude-weekly-reset-ms", String(value)]
        }
        if let value = Self.milliseconds(sinceWeeklyResetAtByPlatform[.grok]) {
            arguments += ["--grok-weekly-reset-ms", String(value)]
        }
        if let value = Self.milliseconds(sinceWeeklyResetAtByPlatform[.antigravity]) {
            arguments += ["--antigravity-weekly-reset-ms", String(value)]
        }
        if let memoryDatabaseURL {
            arguments += ["--memory-database", memoryDatabaseURL.path]
        }
        if let openAIPricingURL {
            arguments += ["--openai-pricing-markdown", openAIPricingURL.path]
        }
        if let anthropicPricingURL {
            arguments += ["--anthropic-pricing-markdown", anthropicPricingURL.path]
        }
        if let openRouterPricingURL {
            arguments += ["--openrouter-pricing-json", openRouterPricingURL.path]
        }
        return arguments
    }

    private static func milliseconds(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        let milliseconds = date.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max)
        else {
            return nil
        }
        return Int64(milliseconds.rounded())
    }

    private func helperEnvironment(
        statisticsTimeZone: TokenBarStatisticsTimeZone) -> [String: String]
    {
        var environment = self.environment
        environment["TZ"] = statisticsTimeZone.processEnvironmentValue
        environment.removeValue(forKey: "TOKENBAR_SYNC_TOKEN")
        return environment
    }

    public static func resolveHelperExecutable(
        explicitURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL
    {
        let candidates = Self.helperCandidates(explicitURL: explicitURL, environment: environment)
        if let candidate = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return candidate
        }
        throw ActivityServiceError.helperNotFound(candidates.map(\.path))
    }

    static func helperCandidates(
        explicitURL: URL?,
        environment: [String: String]) -> [URL]
    {
        var candidates: [URL] = []
        if let explicitURL {
            candidates.append(explicitURL)
        }
        if let configuredPath = environment["TOKENBAR_HELPER_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredPath.isEmpty
        {
            candidates.append(URL(fileURLWithPath: configuredPath))
        }
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: self.helperExecutableName) {
            candidates.append(auxiliary)
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent(self.helperExecutableName, isDirectory: false))

        let repositoryRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
            .standardizedFileURL
        for configuration in ["debug", "release"] {
            candidates.append(
                repositoryRoot
                    .appendingPathComponent("Helper/target", isDirectory: true)
                    .appendingPathComponent(configuration, isDirectory: true)
                    .appendingPathComponent(self.helperExecutableName, isDirectory: false))
        }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
