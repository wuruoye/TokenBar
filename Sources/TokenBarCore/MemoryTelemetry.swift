import Foundation
import Observation

public struct MemoryTelemetryPaths: Equatable, Sendable {
    public let directoryURL: URL
    public let databaseURL: URL
    public let receiverStatusURL: URL
    public let receiverLogURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.databaseURL = directoryURL.appendingPathComponent("memory-telemetry.sqlite")
        self.receiverStatusURL = directoryURL.appendingPathComponent("memory-receiver-status.json")
        self.receiverLogURL = directoryURL.appendingPathComponent("memory-receiver.log")
    }

    public static func applicationDefault(fileManager: FileManager = .default) -> MemoryTelemetryPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return MemoryTelemetryPaths(
            directoryURL: base.appendingPathComponent("TokenBar", isDirectory: true))
    }
}

public enum MemoryReceiverState: Equatable, Sendable {
    case stopped
    case starting
    case listening(startedAt: Date)
    case failed(String)

    public var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .failed: "Unavailable"
        }
    }

    public var detail: String? {
        switch self {
        case .stopped: "TokenBar is not receiving metrics."
        case .starting: "Starting the loopback receiver."
        case .listening: "127.0.0.1:4318"
        case let .failed(message): message
        }
    }

    public var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

public enum CodexMemoryConfigurationState: Equatable, Sendable {
    case notConfigured
    case needsAnalytics
    case configured
    case customOpenTelemetry
    case unavailable(String)

    public var title: String {
        switch self {
        case .notConfigured: "Not configured"
        case .needsAnalytics: "Analytics disabled"
        case .configured: "Configured"
        case .customOpenTelemetry: "Custom OpenTelemetry"
        case .unavailable: "Unavailable"
        }
    }

    public var detail: String {
        switch self {
        case .notConfigured:
            "Enable metrics to start collecting from new Codex sessions."
        case .needsAnalytics:
            "The TokenBar endpoint is present, but Codex metrics are disabled."
        case .configured:
            "Restart Codex or ChatGPT once after enabling. New processes send only metrics to TokenBar."
        case .customOpenTelemetry:
            "Existing [otel] settings were preserved. Configure the metrics endpoint manually."
        case let .unavailable(message):
            message
        }
    }

    public var canInstall: Bool {
        switch self {
        case .notConfigured, .needsAnalytics: true
        case .configured, .customOpenTelemetry, .unavailable: false
        }
    }
}

public enum CodexMemoryConfigurationError: LocalizedError, Equatable, Sendable {
    case customOpenTelemetry
    case invalidConfiguration(String)
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .customOpenTelemetry:
            "TokenBar did not modify the existing [otel] configuration."
        case let .invalidConfiguration(message), let .fileOperation(message):
            message
        }
    }
}

public struct CodexMemoryConfigurationService: Sendable {
    public static let endpoint = "http://127.0.0.1:4318/v1/metrics"

    public let configurationURL: URL

    public init(configurationURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let configurationURL {
            self.configurationURL = configurationURL
        } else if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            self.configurationURL = URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("config.toml")
        } else {
            self.configurationURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("config.toml")
        }
    }

    public func inspect() -> CodexMemoryConfigurationState {
        guard FileManager.default.fileExists(atPath: self.configurationURL.path) else {
            return .notConfigured
        }
        do {
            let content = try String(contentsOf: self.configurationURL, encoding: .utf8)
            return Self.inspect(content: content)
        } catch {
            return .unavailable("Could not read Codex config: \(error.localizedDescription)")
        }
    }

    public func install() throws {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: self.configurationURL.path)
        let content: String
        if exists {
            do {
                content = try String(contentsOf: self.configurationURL, encoding: .utf8)
            } catch {
                throw CodexMemoryConfigurationError.fileOperation(
                    "Could not read Codex config: \(error.localizedDescription)")
            }
        } else {
            content = ""
        }
        let state = Self.inspect(content: content)
        guard state != .customOpenTelemetry else {
            throw CodexMemoryConfigurationError.customOpenTelemetry
        }
        if case let .unavailable(message) = state {
            throw CodexMemoryConfigurationError.invalidConfiguration(message)
        }
        if state == .configured {
            return
        }

        var updated = try Self.enablingAnalytics(in: content)
        if !Self.hasSection("otel", in: updated) {
            if !updated.isEmpty, !updated.hasSuffix("\n") {
                updated += "\n"
            }
            if !updated.isEmpty, !updated.hasSuffix("\n\n") {
                updated += "\n"
            }
            updated += """
            # Added by TokenBar. Logs and traces remain disabled.
            [otel]
            exporter = "none"
            trace_exporter = "none"
            log_user_prompt = false
            metrics_exporter = { otlp-http = { endpoint = "\(Self.endpoint)", protocol = "json" } }
            """
            updated += "\n"
        }

        do {
            try fileManager.createDirectory(
                at: self.configurationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let permissions = exists
                ? (try? fileManager.attributesOfItem(atPath: self.configurationURL.path)[.posixPermissions])
                : nil
            if exists {
                let backup = self.configurationURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "config.toml.tokenbar-backup-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)")
                try fileManager.copyItem(at: self.configurationURL, to: backup)
            }
            try Data(updated.utf8).write(to: self.configurationURL, options: .atomic)
            if let permissions {
                try? fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: self.configurationURL.path)
            }
        } catch {
            throw CodexMemoryConfigurationError.fileOperation(
                "Could not update Codex config: \(error.localizedDescription)")
        }
    }

    static func inspect(content: String) -> CodexMemoryConfigurationState {
        let otelSections = Self.sectionRanges("otel", in: content)
        if otelSections.count > 1 {
            return .unavailable("Codex config contains duplicate [otel] sections.")
        }
        guard let otel = otelSections.first else {
            if Self.hasRelatedDefinition("otel", in: content) {
                return .customOpenTelemetry
            }
            return .notConfigured
        }
        let lines = Self.lines(content)
        let body = lines[otel].map(Self.withoutComment).joined().filter { !$0.isWhitespace }
        let exporter = Self.assignment("exporter", in: lines[otel])
        let traceExporter = Self.assignment("trace_exporter", in: lines[otel])
        let logUserPrompt = Self.assignment("log_user_prompt", in: lines[otel])
        let usesTokenBar = body.contains("metrics_exporter=")
            && body.contains("otlp-http")
            && body.contains("endpoint=\"\(Self.endpoint)\"")
            && body.contains("protocol=\"json\"")
            && exporter == "\"none\""
            && traceExporter == "\"none\""
            && logUserPrompt != "true"
        guard usesTokenBar else {
            return .customOpenTelemetry
        }
        let analyticsSections = Self.sectionRanges("analytics", in: content)
        if analyticsSections.count > 1 {
            return .unavailable("Codex config contains duplicate [analytics] sections.")
        }
        guard let analytics = analyticsSections.first else {
            if Self.hasRelatedDefinition("analytics", in: content) {
                return .unavailable("Codex config uses a custom analytics table that TokenBar will not modify.")
            }
            return .needsAnalytics
        }
        return Self.assignment("enabled", in: lines[analytics]) == "true"
            ? .configured
            : .needsAnalytics
    }

    private static func enablingAnalytics(in content: String) throws -> String {
        var lines = Self.lines(content)
        let sections = Self.sectionRanges("analytics", in: content)
        guard sections.count <= 1 else {
            throw CodexMemoryConfigurationError.invalidConfiguration(
                "Codex config contains duplicate [analytics] sections.")
        }
        guard let section = sections.first else {
            guard !Self.hasRelatedDefinition("analytics", in: content) else {
                throw CodexMemoryConfigurationError.invalidConfiguration(
                    "Codex config uses a custom analytics table that TokenBar will not modify.")
            }
            var updated = content
            if !updated.isEmpty, !updated.hasSuffix("\n") {
                updated += "\n"
            }
            if !updated.isEmpty, !updated.hasSuffix("\n\n") {
                updated += "\n"
            }
            updated += "[analytics]\nenabled = true\n"
            return updated
        }
        if let enabledIndex = section.first(where: { index in
            Self.assignmentKey(in: lines[index]) == "enabled"
        }) {
            let indentation = String(lines[enabledIndex].prefix { $0.isWhitespace })
            let comment = lines[enabledIndex].firstIndex(of: "#").map {
                " " + lines[enabledIndex][$0...].trimmingCharacters(in: .whitespaces)
            } ?? ""
            lines[enabledIndex] = "\(indentation)enabled = true\(comment)"
        } else {
            lines.insert("enabled = true", at: section.lowerBound + 1)
        }
        var updated = lines.joined(separator: "\n")
        if content.hasSuffix("\n") {
            updated += "\n"
        }
        return updated
    }

    private static func hasSection(_ name: String, in content: String) -> Bool {
        !Self.sectionRanges(name, in: content).isEmpty
    }

    private static func hasRelatedDefinition(_ name: String, in content: String) -> Bool {
        let lines = Self.lines(content)
        var isAtRoot = true
        for rawLine in lines {
            let line = Self.withoutComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                isAtRoot = false
                if line.hasPrefix("[\(name).") || line.hasPrefix("[[\(name).") {
                    return true
                }
                continue
            }
            if isAtRoot, Self.assignmentKey(in: line) == name {
                return true
            }
        }
        return false
    }

    private static func sectionRanges(_ name: String, in content: String) -> [Range<Int>] {
        let lines = Self.lines(content)
        let header = "[\(name)]"
        let starts = lines.indices.filter { Self.withoutComment(lines[$0]).trimmingCharacters(in: .whitespaces) == header }
        return starts.map { start in
            let end = lines.indices.dropFirst(start + 1).first(where: { index in
                let line = Self.withoutComment(lines[index]).trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("[") && line.hasSuffix("]")
            }) ?? lines.endIndex
            return start ..< end
        }
    }

    private static func assignment(_ key: String, in lines: ArraySlice<String>) -> String? {
        lines.first(where: { Self.assignmentKey(in: $0) == key }).flatMap { line in
            let line = Self.withoutComment(line)
            guard let separator = line.firstIndex(of: "=") else { return nil }
            return line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .filter { !$0.isWhitespace }
        }
    }

    private static func assignmentKey(in line: String) -> String? {
        let line = Self.withoutComment(line)
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private static func lines(_ content: String) -> [String] {
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func withoutComment(_ line: String) -> String {
        var inBasicString = false
        var inLiteralString = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", inBasicString {
                escaped = true
                continue
            }
            if character == "\"", !inLiteralString {
                inBasicString.toggle()
                continue
            }
            if character == "'", !inBasicString {
                inLiteralString.toggle()
                continue
            }
            if character == "#", !inBasicString, !inLiteralString {
                return String(line[..<index])
            }
        }
        return line
    }
}

@MainActor
@Observable
public final class MemoryTelemetryController {
    public static let port = 4318

    public private(set) var receiverState = MemoryReceiverState.stopped
    public private(set) var configurationState: CodexMemoryConfigurationState
    public private(set) var configurationErrorMessage: String?

    public let paths: MemoryTelemetryPaths
    public let configurationService: CodexMemoryConfigurationService

    @ObservationIgnored private let helperURL: URL?
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var receiverProcess: Process?
    @ObservationIgnored private var receiverLogHandle: FileHandle?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var isStopping = false

    public init(
        paths: MemoryTelemetryPaths = .applicationDefault(),
        configurationService: CodexMemoryConfigurationService = CodexMemoryConfigurationService(),
        helperURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        initialReceiverState: MemoryReceiverState = .stopped,
        initialConfigurationState: CodexMemoryConfigurationState? = nil)
    {
        self.paths = paths
        self.configurationService = configurationService
        self.helperURL = helperURL
        self.environment = environment
        self.receiverState = initialReceiverState
        self.configurationState = initialConfigurationState ?? configurationService.inspect()
    }

    public func start() {
        guard self.receiverProcess == nil else { return }
        self.refreshConfiguration()
        self.configurationErrorMessage = nil
        self.receiverState = .starting
        self.isStopping = false
        do {
            try FileManager.default.createDirectory(
                at: self.paths.directoryURL,
                withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: self.paths.directoryURL.path)
            try? FileManager.default.removeItem(at: self.paths.receiverStatusURL)
            if !FileManager.default.fileExists(atPath: self.paths.receiverLogURL.path) {
                FileManager.default.createFile(atPath: self.paths.receiverLogURL.path, contents: nil)
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: self.paths.receiverLogURL.path)
            let logHandle = try FileHandle(forWritingTo: self.paths.receiverLogURL)
            try logHandle.seekToEnd()
            let executable = try ActivityService.resolveHelperExecutable(
                explicitURL: self.helperURL,
                environment: self.environment)
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "memory-receiver",
                "--database", self.paths.databaseURL.path,
                "--status-file", self.paths.receiverStatusURL.path,
                "--port", String(Self.port),
                "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            ]
            process.environment = self.environment
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let exitCode = process.terminationStatus
                Task { @MainActor [weak self] in
                    self?.receiverDidTerminate(exitCode: exitCode)
                }
            }
            try process.run()
            self.receiverProcess = process
            self.receiverLogHandle = logHandle
            self.startupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0 ..< 30 {
                    if Task.isCancelled { return }
                    if self.readReceiverStatus() { return }
                    if self.receiverProcess?.isRunning != true { return }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if self.receiverProcess?.isRunning == true {
                    self.receiverState = .failed("Receiver did not publish its startup status.")
                }
            }
        } catch {
            self.receiverLogHandle?.closeFile()
            self.receiverLogHandle = nil
            self.receiverProcess = nil
            self.receiverState = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        self.isStopping = true
        self.startupTask?.cancel()
        self.startupTask = nil
        let process = self.receiverProcess
        self.receiverProcess = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        self.receiverLogHandle?.closeFile()
        self.receiverLogHandle = nil
        self.receiverState = .stopped
    }

    public func refreshConfiguration() {
        self.configurationState = self.configurationService.inspect()
    }

    public func installConfiguration() {
        self.configurationErrorMessage = nil
        do {
            try self.configurationService.install()
            self.refreshConfiguration()
        } catch {
            self.configurationErrorMessage = error.localizedDescription
            self.refreshConfiguration()
        }
    }

    private func readReceiverStatus() -> Bool {
        guard let data = try? Data(contentsOf: self.paths.receiverStatusURL),
              let status = try? JSONDecoder().decode(ReceiverStatus.self, from: data)
        else {
            return false
        }
        switch status.state {
        case "listening":
            self.receiverState = .listening(
                startedAt: status.startedAtMs.map {
                    Date(timeIntervalSince1970: Double($0) / 1000)
                } ?? Date())
        case "error":
            self.receiverState = .failed(status.message ?? "Memory receiver failed to start.")
        default:
            return false
        }
        return true
    }

    private func receiverDidTerminate(exitCode: Int32) {
        self.startupTask?.cancel()
        self.startupTask = nil
        self.receiverProcess = nil
        self.receiverLogHandle?.closeFile()
        self.receiverLogHandle = nil
        guard !self.isStopping else { return }
        if !self.readReceiverStatus() || self.receiverState.isListening {
            self.receiverState = .failed("Receiver exited with status \(exitCode).")
        }
    }

    private struct ReceiverStatus: Decodable {
        let state: String
        let startedAtMs: Int64?
        let message: String?
    }
}
