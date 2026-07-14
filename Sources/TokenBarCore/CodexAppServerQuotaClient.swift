import Foundation

protocol CodexRateLimitsRequesting: Sendable {
    func fetchRateLimitsResult() async throws -> Data
}

struct CodexAppServerQuotaClient: Sendable {
    private let requester: any CodexRateLimitsRequesting
    private let now: @Sendable () -> Date

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        initializeTimeout: TimeInterval = 8,
        requestTimeout: TimeInterval = 4,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.requester = CodexAppServerRPC(
            environment: environment,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout)
        self.now = now
    }

    init(
        requester: any CodexRateLimitsRequesting,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.requester = requester
        self.now = now
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        let data: Data
        do {
            data = try await self.requester.fetchRateLimitsResult()
        } catch let CodexAppServerError.requestFailed(message) {
            if let snapshot = Self.recoverQuota(fromRequestFailure: message, updatedAt: self.now()) {
                return snapshot
            }
            throw CodexAppServerError.requestFailed(message)
        }
        let result: RateLimitsResult
        do {
            result = try JSONDecoder().decode(RateLimitsResult.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse(error.localizedDescription)
        }

        let session = result.rateLimits.primary.map(Self.mapWindow)
        let weekly = result.rateLimits.secondary.map(Self.mapWindow)
        guard session != nil || weekly != nil else {
            throw CodexQuotaServiceError.noQuotaWindows
        }
        return QuotaSnapshot(
            session: session,
            weekly: weekly,
            resetCredits: nil,
            updatedAt: self.now())
    }

    private static func recoverQuota(
        fromRequestFailure message: String,
        updatedAt: Date) -> QuotaSnapshot?
    {
        guard let object = Self.extractJSONObject(after: "body=", in: message),
              let data = object.data(using: .utf8),
              let body = try? JSONDecoder().decode(RateLimitsErrorBody.self, from: data)
        else {
            return nil
        }
        let session = body.rateLimit?.primaryWindow.map(Self.mapErrorWindow)
        let weekly = body.rateLimit?.secondaryWindow.map(Self.mapErrorWindow)
        guard session != nil || weekly != nil else { return nil }
        return QuotaSnapshot(
            session: session,
            weekly: weekly,
            resetCredits: nil,
            updatedAt: updatedAt)
    }

    private static func extractJSONObject(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let suffix = text[markerRange.upperBound...]
        guard let start = suffix.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false
        for index in suffix[start...].indices {
            let character = suffix[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(suffix[start ... index])
                }
            }
        }
        return nil
    }

    private static func mapWindow(_ window: RateLimitWindow) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(
            usedPercent: window.usedPercent,
            windowMinutes: window.windowDurationMinutes,
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    private static func mapErrorWindow(_ window: RateLimitsErrorBody.Window) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(
            usedPercent: window.usedPercent,
            windowMinutes: window.limitWindowSeconds.map { max(0, $0 / 60) },
            resetsAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

enum CodexAppServerError: LocalizedError, Sendable {
    case codexNotFound
    case launchFailed(String)
    case connectionClosed(String?)
    case requestFailed(String)
    case invalidResponse(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            "Codex CLI was not found. Install Codex or set CODEX_CLI_PATH."
        case let .launchFailed(message):
            "Could not launch Codex: \(message)"
        case let .connectionClosed(message):
            message.map { "Codex app-server closed its connection: \($0)" }
                ?? "Codex app-server closed its connection."
        case let .requestFailed(message):
            "Codex app-server request failed: \(message)"
        case let .invalidResponse(message):
            "Codex app-server returned invalid data: \(message)"
        case let .timedOut(method):
            "Codex app-server timed out while waiting for \(method)."
        }
    }
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimits

    struct RateLimits: Decodable {
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?

        private enum CodingKeys: String, CodingKey {
            case primary
            case secondary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.primary = (try? container.decodeIfPresent(RateLimitWindow.self, forKey: .primary)) ?? nil
            self.secondary = (try? container.decodeIfPresent(RateLimitWindow.self, forKey: .secondary)) ?? nil
        }
    }
}

private struct RateLimitsErrorBody: Decodable {
    let rateLimit: RateLimit?

    private enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        private enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.primaryWindow = (try? container.decodeIfPresent(Window.self, forKey: .primaryWindow)) ?? nil
            self.secondaryWindow = (try? container.decodeIfPresent(Window.self, forKey: .secondaryWindow)) ?? nil
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAt: Int64?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.usedPercent = try RateLimitWindow.decodeDouble(container, keys: [.usedPercent])
            self.limitWindowSeconds = RateLimitWindow.decodeInt(container, keys: [.limitWindowSeconds])
            self.resetAt = RateLimitWindow.decodeInt64(container, keys: [.resetAt])
        }
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMinutes: Int?
    let resetsAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case usedPercentSnake = "used_percent"
        case windowDurationMinutes = "windowDurationMins"
        case windowDurationMinutesSnake = "window_duration_mins"
        case resetsAt
        case resetsAtSnake = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try Self.decodeDouble(
            container,
            keys: [.usedPercent, .usedPercentSnake])
        self.windowDurationMinutes = Self.decodeInt(
            container,
            keys: [.windowDurationMinutes, .windowDurationMinutesSnake])
        self.resetsAt = Self.decodeInt64(
            container,
            keys: [.resetsAt, .resetsAtSnake])
    }

    fileprivate static func decodeDouble<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        keys: [Key]) throws -> Double
    {
        for key in keys {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
        }
        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Missing quota usage percentage."))
    }

    fileprivate static func decodeInt<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        keys: [Key]) -> Int?
    {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
        }
        return nil
    }

    fileprivate static func decodeInt64<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        keys: [Key]) -> Int64?
    {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int64(value)
            }
        }
        return nil
    }
}

private struct CodexAppServerRPC: CodexRateLimitsRequesting, Sendable {
    let environment: [String: String]
    let initializeTimeout: TimeInterval
    let requestTimeout: TimeInterval

    func fetchRateLimitsResult() async throws -> Data {
        guard let executableURL = try await CodexBinaryResolver.resolveWithLoginShell(
            environment: self.environment)
        else {
            throw CodexAppServerError.codexNotFound
        }

        let session = try CodexAppServerSession(
            executableURL: executableURL,
            environment: CodexBinaryResolver.childEnvironment(
                self.environment,
                executableURL: executableURL))
        do {
            _ = try await session.request(
                method: "initialize",
                parameters: [
                    "clientInfo": [
                        "name": "tokenbar",
                        "version": "1.0.0",
                    ],
                ],
                timeout: self.initializeTimeout)
            try session.notify(method: "initialized")
            let result = try await session.request(
                method: "account/rateLimits/read",
                parameters: nil,
                timeout: self.requestTimeout)
            await session.shutdownAndWait()
            return result
        } catch {
            await session.shutdownAndWait()
            throw error
        }
    }
}

enum CodexBinaryResolver {
    static func resolveWithLoginShell(
        environment: [String: String],
        fileManager: FileManager = .default) async throws -> URL?
    {
        try Task.checkCancellation()
        if let direct = Self.resolve(
            environment: environment,
            fileManager: fileManager,
            loginShellPaths: [])
        {
            return direct
        }
        let loginShellPaths = await CodexLoginShellPathCache.shared.paths(environment: environment)
        try Task.checkCancellation()
        return Self.resolve(
            environment: environment,
            fileManager: fileManager,
            loginShellPaths: loginShellPaths)
    }

    static func resolve(
        environment: [String: String],
        fileManager: FileManager = .default,
        loginShellPaths: [String]) -> URL?
    {
        var candidates: [String] = []
        let home = Self.homeURL(environment: environment, fileManager: fileManager)
        if let configured = environment["CODEX_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            let expanded = configured == "~"
                ? home.path
                : configured.hasPrefix("~/")
                    ? home.path + String(configured.dropFirst())
                    : configured
            if expanded.hasPrefix("/") {
                candidates.append(expanded)
            }
        }

        let environmentPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        for directory in environmentPaths + loginShellPaths where directory.hasPrefix("/") {
            candidates.append(directory + "/codex")
        }

        candidates.append(contentsOf: Self.managerCandidates(home: home, fileManager: fileManager))
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home.path)/Applications/Codex.app/Contents/Resources/codex",
            "\(home.path)/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ])

        var seen: Set<String> = []
        for candidate in candidates {
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: standardized.path) {
                return standardized
            }
        }
        return nil
    }

    private static func homeURL(
        environment: [String: String],
        fileManager: FileManager) -> URL
    {
        if let configured = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           configured.hasPrefix("/")
        {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser.standardizedFileURL
    }

    private static func managerCandidates(home: URL, fileManager: FileManager) -> [String] {
        let fixedDirectories = [
            ".local/bin",
            ".npm-global/bin",
            ".volta/bin",
            ".bun/bin",
            ".fnm/current/bin",
            ".local/share/mise/shims",
            ".asdf/shims",
            "Library/pnpm",
        ]
        var candidates = fixedDirectories.map {
            home.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false).path
        }
        candidates.append(contentsOf: Self.versionedManagerCandidates(
            root: home.appendingPathComponent(".nvm/versions/node", isDirectory: true),
            suffix: "bin/codex",
            fileManager: fileManager))
        candidates.append(contentsOf: Self.versionedManagerCandidates(
            root: home.appendingPathComponent(".fnm/node-versions", isDirectory: true),
            suffix: "installation/bin/codex",
            fileManager: fileManager))
        return candidates
    }

    private static func versionedManagerCandidates(
        root: URL,
        suffix: String,
        fileManager: FileManager) -> [String]
    {
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return versions.sorted(by: >).map {
            root.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: false).path
        }
    }

    static func childEnvironment(
        _ environment: [String: String],
        executableURL: URL) -> [String: String]
    {
        var result = environment
        let existing = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let preferred = [
            executableURL.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        var seen: Set<String> = []
        result["PATH"] = (preferred + existing)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return result
    }
}

actor CodexLoginShellPathCache {
    typealias Capture = @Sendable ([String: String]) async -> [String]

    static let shared = CodexLoginShellPathCache()

    private struct Key: Hashable, Sendable {
        let shell: String
        let home: String
        let path: String
    }

    private let capture: Capture
    private var cached: [Key: [String]] = [:]
    private var inFlight: [Key: Task<[String], Never>] = [:]

    init(capture: @escaping Capture = CodexLoginShellPathCapturer.capture) {
        self.capture = capture
    }

    func paths(environment: [String: String]) async -> [String] {
        let key = Key(
            shell: environment["SHELL"] ?? "",
            home: environment["HOME"] ?? "",
            path: environment["PATH"] ?? "")
        if let cached = self.cached[key] { return cached }
        if let task = self.inFlight[key] { return await task.value }

        let capture = self.capture
        let task = Task { await capture(environment) }
        self.inFlight[key] = task
        let result = await task.value
        self.inFlight[key] = nil
        self.cached[key] = result
        return result
    }
}

enum CodexLoginShellPathCapturer {
    private static let marker = "__TOKENBAR_LOGIN_PATH__="
    private static let supportedShellNames: Set<String> = ["bash", "dash", "ksh", "sh", "zsh"]
    private static let trustedShellRoots = ["/bin/", "/usr/bin/", "/opt/homebrew/bin/", "/usr/local/bin/"]

    static func capture(environment: [String: String]) async -> [String] {
        guard let shell = Self.supportedShellURL(environment: environment) else { return [] }
        let isCI = ["1", "true"].contains(environment["CI"]?.lowercased())
        let shellFlags = isCI ? ["-c"] : ["-l", "-i", "-c"]
        let command = "printf '\\n\(Self.marker)%s\\n' \"$PATH\""
        guard let result = try? await ProcessRunner.run(
            executableURL: shell,
            arguments: shellFlags + [command],
            environment: environment,
            timeout: 3,
            maximumOutputBytes: 256 * 1024)
        else {
            return []
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
        guard let line = output.split(whereSeparator: \.isNewline).last(where: {
            $0.hasPrefix(Self.marker)
        }) else {
            return []
        }
        return line.dropFirst(Self.marker.count)
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
    }

    static func supportedShellURL(
        environment: [String: String],
        fileManager: FileManager = .default) -> URL?
    {
        let configured = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [configured, "/bin/zsh", "/bin/bash"].compactMap { $0 }
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            guard Self.supportedShellNames.contains(url.lastPathComponent),
                  Self.trustedShellRoots.contains(where: { url.path.hasPrefix($0) }),
                  fileManager.isExecutableFile(atPath: url.path)
            else {
                continue
            }
            return url
        }
        return nil
    }
}

enum CodexJSONRPCWire {
    static func result(from line: Data, matchingID: Int) throws -> Data? {
        let object: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexAppServerError.invalidResponse("Expected a JSON object.")
            }
            object = dictionary
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.invalidResponse(error.localizedDescription)
        }

        guard let responseID = Self.integerID(object["id"]) else {
            return nil
        }
        guard responseID == matchingID else { return nil }

        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Unknown RPC error"
            throw CodexAppServerError.requestFailed(message)
        }
        guard let result = object["result"] else {
            throw CodexAppServerError.invalidResponse("Missing result field.")
        }
        guard JSONSerialization.isValidJSONObject(result) else {
            throw CodexAppServerError.invalidResponse("Result was not valid JSON.")
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

private final class CodexAppServerSession: @unchecked Sendable {
    private let control: ProcessControl
    private let completion: ProcessCompletion
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let lineContinuation: AsyncStream<Data>.Continuation
    private var lineIterator: AsyncStream<Data>.Iterator
    private let lineFramer = LineFramer()
    private let stderrBuffer = RPCStderrBuffer()
    private let stateLock = NSLock()
    private var nextID = 1
    private var isShutdown = false

    init(executableURL: URL, environment: [String: String]) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.errorOutput = errorPipe.fileHandleForReading

        let pair = AsyncStream<Data>.makeStream()
        self.lineContinuation = pair.continuation
        self.lineIterator = pair.stream.makeAsyncIterator()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let completion = ProcessCompletion()
        self.completion = completion
        self.control = ProcessControl(process: process)
        process.terminationHandler = { completedProcess in
            completion.resolve(completedProcess.terminationStatus)
        }

        let continuation = self.lineContinuation
        let framer = self.lineFramer
        self.output.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                for line in framer.finish() {
                    continuation.yield(line)
                }
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in framer.append(chunk) {
                continuation.yield(line)
            }
        }

        let stderrBuffer = self.stderrBuffer
        self.errorOutput.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(chunk)
        }

        do {
            try process.run()
        } catch {
            self.output.readabilityHandler = nil
            self.errorOutput.readabilityHandler = nil
            self.lineContinuation.finish()
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
    }

    func request(
        method: String,
        parameters: [String: Any]?,
        timeout: TimeInterval) async throws -> Data
    {
        let id = self.takeNextID()
        try self.send(id: id, method: method, parameters: parameters)
        return try await self.withTimeout(method: method, seconds: timeout) {
            while let line = await self.lineIterator.next() {
                if let result = try CodexJSONRPCWire.result(from: line, matchingID: id) {
                    return result
                }
            }
            try Task.checkCancellation()
            throw CodexAppServerError.connectionClosed(self.stderrBuffer.text)
        }
    }

    func notify(method: String, parameters: [String: Any]? = nil) throws {
        let payload: [String: Any] = [
            "method": method,
            "params": parameters ?? [:],
        ]
        try self.write(payload)
    }

    func shutdown() {
        self.stateLock.lock()
        guard !self.isShutdown else {
            self.stateLock.unlock()
            return
        }
        self.isShutdown = true
        self.stateLock.unlock()

        self.output.readabilityHandler = nil
        self.errorOutput.readabilityHandler = nil
        self.lineContinuation.finish()
        try? self.input.close()
        self.control.terminate()
    }

    func shutdownAndWait() async {
        self.shutdown()
        await self.control.terminateAndWait(completion: self.completion)
    }

    private func takeNextID() -> Int {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        let id = self.nextID
        self.nextID += 1
        return id
    }

    private func send(id: Int, method: String, parameters: [String: Any]?) throws {
        var payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": parameters ?? [:],
        ]
        if parameters == nil {
            payload["params"] = [:]
        }
        try self.write(payload)
    }

    private func write(_ payload: [String: Any]) throws {
        do {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A)
            try self.input.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.requestFailed(error.localizedDescription)
        }
    }

    private func withTimeout(
        method: String,
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Data) async throws -> Data
    {
        let race = RPCRequestRace()
        let operationTask = Task {
            do {
                race.resolve(.success(try await operation()))
            } catch is CancellationError {
                race.resolve(.cancelled)
            } catch let error as CodexAppServerError {
                race.resolve(.failure(error))
            } catch {
                race.resolve(.failure(.invalidResponse(error.localizedDescription)))
            }
        }
        var timeoutTask: Task<Void, Never>?
        if seconds.isFinite {
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(max(0, seconds)))
                } catch {
                    return
                }
                if race.resolve(.timedOut) {
                    self?.shutdown()
                }
            }
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: { [weak self] in
            if race.resolve(.cancelled) {
                self?.shutdown()
            }
        }
        if let timeoutTask {
            timeoutTask.cancel()
            await timeoutTask.value
        }
        if case .timedOut = outcome {
            operationTask.cancel()
        } else if case .cancelled = outcome {
            operationTask.cancel()
        }
        await operationTask.value

        switch outcome {
        case let .success(data):
            try Task.checkCancellation()
            return data
        case let .failure(error):
            try Task.checkCancellation()
            throw error
        case .timedOut:
            await self.shutdownAndWait()
            if Task.isCancelled { throw CancellationError() }
            throw CodexAppServerError.timedOut(method)
        case .cancelled:
            await self.shutdownAndWait()
            throw CancellationError()
        }
    }
}

private enum RPCRequestOutcome: Sendable {
    case success(Data)
    case failure(CodexAppServerError)
    case timedOut
    case cancelled
}

private final class RPCRequestRace: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: RPCRequestOutcome?
    private var continuation: CheckedContinuation<RPCRequestOutcome, Never>?

    @discardableResult
    func resolve(_ outcome: RPCRequestOutcome) -> Bool {
        self.lock.lock()
        guard self.outcome == nil else {
            self.lock.unlock()
            return false
        }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: outcome)
        return true
    }

    func wait() async -> RPCRequestOutcome {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if let outcome = self.outcome {
                self.lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }
}

private final class LineFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.buffer.append(data)
        return self.drainCompleteLines()
    }

    func finish() -> [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }
        var lines = self.drainCompleteLines()
        if !self.buffer.isEmpty {
            lines.append(self.buffer)
            self.buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }

    private func drainCompleteLines() -> [Data] {
        var lines: [Data] = []
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            let line = Data(self.buffer[..<newline])
            self.buffer.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}

private final class RPCStderrBuffer: @unchecked Sendable {
    private static let maximumBytes = 64 * 1024
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let remaining = max(0, Self.maximumBytes - self.data.count)
        if remaining > 0 {
            self.data.append(chunk.prefix(remaining))
        }
    }

    var text: String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let value = String(decoding: self.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
