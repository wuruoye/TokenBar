import Foundation

public protocol ActivityProviding: Sendable {
    func fetchActivity(sinceWeeklyResetAt: Date?) async throws -> ActivitySnapshot
}

public extension ActivityProviding {
    func fetchActivity() async throws -> ActivitySnapshot {
        try await self.fetchActivity(sinceWeeklyResetAt: nil)
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
    private let resolveHelper: @Sendable () throws -> URL
    private let runner: any ActivityHelperRunning

    public init(
        helperURL: URL? = nil,
        arguments: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 120,
        runner: any ActivityHelperRunning = SubprocessActivityHelperRunner())
    {
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.runner = runner
        let candidates = Self.helperCandidates(explicitURL: helperURL, environment: environment)
        self.resolveHelper = {
            if let candidate = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }) {
                return candidate
            }
            throw ActivityServiceError.helperNotFound(candidates.map(\.path))
        }
    }

    init(
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval = 120,
        resolveHelper: @escaping @Sendable () throws -> URL,
        runner: any ActivityHelperRunning)
    {
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.resolveHelper = resolveHelper
        self.runner = runner
    }

    public func fetchActivity(sinceWeeklyResetAt: Date?) async throws -> ActivitySnapshot {
        let helperURL = try self.resolveHelper()
        let data = try await self.runner.run(
            executableURL: helperURL,
            arguments: self.helperArguments(sinceWeeklyResetAt: sinceWeeklyResetAt),
            environment: self.environment,
            timeout: self.timeout)
        guard !data.isEmpty else {
            throw ActivityServiceError.emptyOutput
        }
        do {
            return try JSONDecoder().decode(ActivitySnapshot.self, from: data)
        } catch {
            throw ActivityServiceError.invalidOutput(error.localizedDescription)
        }
    }

    private func helperArguments(sinceWeeklyResetAt: Date?) -> [String] {
        guard let sinceWeeklyResetAt else { return self.arguments }
        let milliseconds = sinceWeeklyResetAt.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max)
        else {
            return self.arguments
        }
        return self.arguments + ["--weekly-reset-ms", String(Int64(milliseconds.rounded()))]
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
