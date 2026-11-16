import AppKit
import ApplicationServices
import Foundation
import SQLite3
import TokenBarCore

enum SessionLauncherError: LocalizedError {
    case invalidSessionID
    case unsupportedPlatform(TokenPlatform)
    case applicationUnavailable(TokenPlatform)
    case workspaceUnavailable(TokenPlatform)

    var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            "The session does not have a valid identifier."
        case let .workspaceUnavailable(platform):
            "This \(platform.displayName) session did not record a workspace folder to open."
        case let .unsupportedPlatform(platform):
            "Opening \(platform.displayName) sessions is not supported."
        case let .applicationUnavailable(platform):
            "macOS could not open this session in the \(platform.displayName) app."
        }
    }
}

@MainActor
struct SessionLauncher {
    static let antigravityFocusURL = URL(string: "antigravity://focus")!

    private let openURL: (URL) -> Bool
    private let resolveClaudeDesktopSessionID: (String) -> String?
    private let resolveAntigravitySession: (String) -> AntigravitySessionTarget?
    private let launchGrokSession: (SessionSummary) -> Bool
    private let launchAntigravityApplication: () -> Bool
    private let navigateAntigravityConversation: @MainActor (String, String?, String?) -> Void

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        resolveClaudeDesktopSessionID: @escaping (String) -> String? = {
            ClaudeDesktopSessionResolver().desktopSessionID(for: $0)
        },
        resolveAntigravitySession: @escaping (String) -> AntigravitySessionTarget? = {
            AntigravitySessionResolver().target(for: $0)
        },
        launchGrokSession: @escaping (SessionSummary) -> Bool = {
            GrokTerminalSessionLauncher().open($0)
        },
        launchAntigravityApplication: @escaping () -> Bool = {
            AntigravityWorkspaceLauncher().openApplication()
        },
        navigateAntigravityConversation: @escaping @MainActor (String, String?, String?) -> Void = {
            AntigravityConversationNavigator.shared.navigate(
                to: $0, expectedTitle: $1, workspacePath: $2)
        })
    {
        self.openURL = openURL
        self.resolveClaudeDesktopSessionID = resolveClaudeDesktopSessionID
        self.resolveAntigravitySession = resolveAntigravitySession
        self.launchGrokSession = launchGrokSession
        self.launchAntigravityApplication = launchAntigravityApplication
        self.navigateAntigravityConversation = navigateAntigravityConversation
    }

    func open(_ session: SessionSummary, onWillOpen: ((String) -> Void)? = nil) throws {
        if session.platformID == .with {
            // With's URL scheme only handles sign-in callbacks, so a session can
            // only be shown by bringing the app forward.
            guard Self.openApplication(bundleIdentifier: Self.withBundleIdentifier) else {
                throw SessionLauncherError.applicationUnavailable(.with)
            }
            return
        }
        if session.platformID == .grok {
            guard self.launchGrokSession(session) else {
                throw SessionLauncherError.applicationUnavailable(.grok)
            }
            return
        }
        if session.platformID == .antigravity {
            let sessionID = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isSafePathIdentifier(sessionID) else {
                throw SessionLauncherError.invalidSessionID
            }
            let title: String? = if let raw = session.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                                    !raw.isEmpty
            {
                raw
            } else {
                nil
            }
            let workspacePath: String? = if let raw = session.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                                            !raw.isEmpty
            {
                raw
            } else {
                nil
            }
            onWillOpen?(sessionID)
            try self.openAntigravity(
                conversationID: sessionID,
                expectedTitle: title,
                workspacePath: workspacePath)
            return
        }
        let claudeDesktopSessionID = session.platformID == .claude
            ? self.resolveClaudeDesktopSessionID(session.id)
            : nil
        let url = try Self.deepLink(
            for: session,
            claudeDesktopSessionID: claudeDesktopSessionID)
        switch session.platformID {
        case .codex:
            if let threadID = Self.codexThreadID(from: session.id.trimmingCharacters(in: .whitespacesAndNewlines)) {
                onWillOpen?(threadID)
            }
        case .claude:
            if let desktopSessionID = claudeDesktopSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !desktopSessionID.isEmpty
            {
                onWillOpen?(desktopSessionID)
            }
        default:
            break
        }
        guard self.openURL(url) else {
            throw SessionLauncherError.applicationUnavailable(session.platformID)
        }
    }

    /// Unread tasks already carry the ID each app's own deep link takes.
    func openUnreadTask(
        platform: TokenPlatform,
        id: String,
        onWillOpen: ((String) -> Void)? = nil) throws
    {
        if platform == .with {
            onWillOpen?(id)
            guard Self.openApplication(bundleIdentifier: Self.withBundleIdentifier) else {
                throw SessionLauncherError.applicationUnavailable(.with)
            }
            return
        }
        if platform == .antigravity {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isSafePathIdentifier(trimmed) else {
                throw SessionLauncherError.invalidSessionID
            }
            onWillOpen?(trimmed)
            try self.openAntigravity(
                conversationID: trimmed,
                expectedTitle: nil,
                workspacePath: nil)
            return
        }
        let url = try Self.deepLink(platform: platform, id: id)
        onWillOpen?(id)
        guard self.openURL(url) else {
            throw SessionLauncherError.applicationUnavailable(platform)
        }
    }

    private func openAntigravity(
        conversationID: String,
        expectedTitle: String?,
        workspacePath: String?) throws
    {
        let activated = AntigravityWorkspaceLauncher().openFocusURLAsync()
            || self.openURL(Self.antigravityFocusURL)
            || self.launchAntigravityApplication()
        guard activated else {
            throw SessionLauncherError.applicationUnavailable(.antigravity)
        }
        self.navigateAntigravityConversation(conversationID, expectedTitle, workspacePath)
    }

    /// Builds the link that shows a Codex thread or Claude Desktop session in
    /// its app.
    static func deepLink(platform: TokenPlatform, id: String) throws -> URL {
        var components = URLComponents()
        switch platform {
        case .codex:
            guard let threadID = self.codexThreadID(from: id) else {
                throw SessionLauncherError.invalidSessionID
            }
            components.scheme = "codex"
            components.host = "threads"
            components.path = "/\(threadID)"
        case .claude:
            guard Self.isSafePathIdentifier(id) else {
                throw SessionLauncherError.invalidSessionID
            }
            components.scheme = "claude"
            // `code/continue` switches to a local session inside the running
            // app, as its notification does. `claude-code-desktop/<id>`
            // reloads the whole window first.
            if Self.isClaudeLocalSessionID(id) {
                components.host = "code"
                components.path = "/continue"
                components.queryItems = [URLQueryItem(name: "session", value: id)]
            } else {
                components.host = "claude.ai"
                components.path = "/claude-code-desktop/\(id)"
            }
        case .workbuddy:
            guard Self.isSafePathIdentifier(id) else {
                throw SessionLauncherError.invalidSessionID
            }
            // The same link WorkBuddy's own task notifications open.
            components.scheme = "workbuddy"
            components.host = "chat"
            components.path = "/\(id)"
        default:
            throw SessionLauncherError.unsupportedPlatform(platform)
        }
        guard let url = components.url else {
            throw SessionLauncherError.invalidSessionID
        }
        return url
    }

    static func deepLink(
        for session: SessionSummary,
        claudeDesktopSessionID: String? = nil) throws -> URL
    {
        let sessionID = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty,
              !sessionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw SessionLauncherError.invalidSessionID
        }

        switch session.platformID {
        case .codex:
            return try self.deepLink(platform: .codex, id: sessionID)
        case .claude:
            if let desktopSessionID = claudeDesktopSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            {
                return try self.deepLink(platform: .claude, id: desktopSessionID)
            }
            var components = URLComponents()
            components.scheme = "claude"
            components.host = "claude.ai"
            components.path = "/local_sessions"
            guard let url = components.url else {
                throw SessionLauncherError.invalidSessionID
            }
            return url
        case .workbuddy:
            return try self.deepLink(platform: .workbuddy, id: sessionID)
        default:
            throw SessionLauncherError.unsupportedPlatform(session.platformID)
        }
    }

    static let withBundleIdentifier = "com.tencent.with"

    static func openApplication(bundleIdentifier: String) -> Bool {
        guard let application = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return false
        }
        NSWorkspace.shared.openApplication(
            at: application,
            configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private static func codexThreadID(from sessionID: String) -> String? {
        if UUID(uuidString: sessionID) != nil {
            return sessionID
        }
        guard sessionID.count >= 36 else { return nil }
        let suffix = String(sessionID.suffix(36))
        return UUID(uuidString: suffix) == nil ? nil : suffix
    }

    /// Claude Desktop's `code/continue` link accepts `local_` followed by up to
    /// 64 letters, digits, and hyphens.
    private static func isClaudeLocalSessionID(_ value: String) -> Bool {
        guard value.hasPrefix("local_") else { return false }
        let suffix = value.dropFirst("local_".count)
        return (1...64).contains(suffix.count)
            && suffix.unicodeScalars.allSatisfy {
                ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-"
            }
    }

    private static func isSafePathIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }
}

@MainActor
private struct GrokTerminalSessionLauncher {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func open(_ session: SessionSummary) -> Bool {
        let sessionID = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeIdentifier(sessionID),
              let executable = self.executableURL()
        else {
            return false
        }
        let workspace = session.workspacePath.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        let command = "exec \(Self.shellQuote(executable.path))"
            + " --cwd \(Self.shellQuote(workspace))"
            + " --resume \(Self.shellQuote(sessionID))"
        let script = """
        #!/bin/zsh
        command rm -f -- "$0"
        \(command)
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBar-Grok-\(UUID().uuidString).command")
        do {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path)
            guard NSWorkspace.shared.open(scriptURL) else {
                try? FileManager.default.removeItem(at: scriptURL)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            return false
        }
    }

    private func executableURL() -> URL? {
        var candidates: [URL] = []
        if let configured = self.environment["GROK_BIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            candidates.append(URL(fileURLWithPath: configured))
        }
        let home = self.environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        let grokHome = self.environment["GROK_HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? URL(fileURLWithPath: home).appendingPathComponent(".grok").path
        candidates.append(
            URL(fileURLWithPath: grokHome).appendingPathComponent("bin/grok"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/grok"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/grok"))
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

struct ClaudeDesktopSessionResolver {
    private struct Record: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let title: String?
        let completedTurns: Int?
        let lastActivityAt: Int64?
        let createdAt: Int64?
        let isArchived: Bool?

        var hasTitle: Bool {
            !(self.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        var isResumeImportAlias: Bool {
            self.cliSessionId.map { self.sessionId == "local_\($0)" } ?? false
        }
    }

    private let sessionsRoot: URL

    init(sessionsRoot: URL = Self.defaultSessionsRoot()) {
        self.sessionsRoot = sessionsRoot
    }

    func desktopSessionID(for cliSessionID: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: self.sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        var matches: [Record] = []
        for case let fileURL as URL in enumerator
            where fileURL.pathExtension == "json"
        {
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.cliSessionId == cliSessionID,
                  Self.isSafeSessionID(record.sessionId)
            else {
                continue
            }
            matches.append(record)
        }

        return matches.sorted(by: Self.isPreferred).first?.sessionId
    }

    private static func isPreferred(_ lhs: Record, _ rhs: Record) -> Bool {
        let lhsActive = lhs.isArchived != true
        let rhsActive = rhs.isArchived != true
        if lhsActive != rhsActive {
            return lhsActive
        }
        if lhs.isResumeImportAlias != rhs.isResumeImportAlias {
            return !lhs.isResumeImportAlias
        }
        if lhs.hasTitle != rhs.hasTitle {
            return lhs.hasTitle
        }
        let lhsTurns = lhs.completedTurns ?? 0
        let rhsTurns = rhs.completedTurns ?? 0
        if lhsTurns != rhsTurns {
            return lhsTurns > rhsTurns
        }
        let lhsActivity = lhs.lastActivityAt ?? 0
        let rhsActivity = rhs.lastActivityAt ?? 0
        if lhsActivity != rhsActivity {
            return lhsActivity > rhsActivity
        }
        return (lhs.createdAt ?? .max) < (rhs.createdAt ?? .max)
    }

    private static func isSafeSessionID(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }

    private static func defaultSessionsRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
    }
}

struct AntigravitySessionTarget: Equatable, Sendable {
    let title: String?
    let projectID: String?
    let workspacePath: String?
}

struct AntigravitySessionResolver {
    private let databaseURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.databaseURL = AntigravityQuotaService.antigravityHomeURL(environment: environment)
            .appendingPathComponent("conversation_summaries.db", isDirectory: false)
    }

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func target(for conversationID: String) -> AntigravitySessionTarget? {
        let sql = """
            SELECT title, project_id, workspace_uris
            FROM conversation_summaries
            WHERE conversation_id = ?
            LIMIT 1
            """
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var shouldTryImmutable = false
        let openResult = sqlite3_open_v2(self.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        if openResult == SQLITE_OK {
            sqlite3_busy_timeout(database, 1000)
            let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            if prepareResult != SQLITE_OK {
                shouldTryImmutable = prepareResult == SQLITE_CANTOPEN || prepareResult == SQLITE_READONLY
                sqlite3_finalize(statement)
                statement = nil
                sqlite3_close(database)
                database = nil
            }
        } else {
            shouldTryImmutable = openResult == SQLITE_CANTOPEN || openResult == SQLITE_READONLY
            sqlite3_close(database)
            database = nil
        }
        if statement == nil, shouldTryImmutable {
            let immutableURI = self.databaseURL.absoluteString + "?immutable=1"
            guard sqlite3_open_v2(
                immutableURI,
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                nil) == SQLITE_OK,
                  sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else {
                return nil
            }
        }
        guard statement != nil else {
            return nil
        }
        sqlite3_bind_text(
            statement,
            1,
            conversationID,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        let title = Self.text(statement, 0)
        let projectID = Self.text(statement, 1)
        let workspacePath = Self.text(statement, 2).flatMap(Self.workspacePath)
        return AntigravitySessionTarget(
            title: title,
            projectID: projectID,
            workspacePath: workspacePath)
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func workspacePath(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let uris = try? JSONDecoder().decode([String].self, from: data),
              let first = uris.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty
        else {
            return nil
        }
        if let url = URL(string: first), url.isFileURL {
            return url.path.isEmpty ? nil : url.path
        }
        let stripped = first.hasPrefix("file://") ? String(first.dropFirst("file://".count)) : first
        return stripped.isEmpty ? nil : stripped
    }
}

@MainActor
private struct AntigravityWorkspaceLauncher {
    private let bundleIdentifier = "com.google.antigravity"

    /// Dispatches `antigravity://focus` asynchronously via LaunchServices so
    /// `@MainActor` never blocks on the target app's AppleEvent round-trip.
    func openFocusURLAsync() -> Bool {
        guard let application = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: self.bundleIdentifier)
        else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [SessionLauncher.antigravityFocusURL],
            withApplicationAt: application,
            configuration: configuration,
            completionHandler: nil)
        return true
    }

    func openApplication() -> Bool {
        guard let application = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: self.bundleIdentifier)
        else {
            return false
        }
        NSWorkspace.shared.openApplication(
            at: application,
            configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

/// Switches Antigravity's Hub window to `/c/<conversationID>` by pressing the
/// matching sidebar `AXLink` via macOS Accessibility and focusing `Message input`.
///
/// Antigravity's `antigravity://open` URL scheme resets the Hub router to the
/// blank new-conversation screen when invoked without a prompt, whereas
/// `antigravity://focus` brings the existing window forward untouched. Each
/// window mounts built-in browser `WebContentsView` tabs alongside the local
/// Hub `WebContentsView`, so TokenBar locates the local `127.0.0.1`/`localhost`
/// Hub `AXWebArea` by pruning non-Hub `AXWebArea` subtrees under `AXWindows`
/// (with `AXUIElementCopyElementAtPosition` as a fallback when `AXWindows` is
/// not yet populated), caches `(webArea, sidebar)` per PID, presses `/c/<id>`
/// on a `.userInteractive` queue, and focuses `Message input`.
final class AntigravityConversationNavigator: @unchecked Sendable {
    static let shared = AntigravityConversationNavigator()

    private static let bundleIdentifier = "com.google.antigravity"

    private struct CachedHubElements {
        var webArea: AXUIElement
        var sidebar: AXUIElement?
    }

    private struct HubAncestors {
        var webArea: AXUIElement?
        var sidebar: AXUIElement?
        var window: AXUIElement?
    }

    private struct HubScanResult {
        var targetLink: AXUIElement?
        var sidebar: AXUIElement?
        var toggleSidebarButton: AXUIElement?
        var collapsedSectionButton: AXUIElement?
        var conversationLinkCount = 0
        var visitedCount = 0
    }

    private enum AttemptOutcome {
        case pressed(pid: pid_t, root: AXUIElement)
        case retry(sawLoadedSidebar: Bool)
    }

    private let workerQueue = DispatchQueue(
        label: "com.wuruoye.TokenBar.antigravity-navigator",
        qos: .userInteractive)
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var hasPromptedForAccessibility = false
    private var cachedHubByPID: [pid_t: CachedHubElements] = [:]

    @MainActor
    func navigate(
        to conversationID: String,
        expectedTitle: String?,
        workspacePath: String?)
    {
        let currentGeneration = self.nextGeneration()
        self.workerQueue.async { [weak self] in
            guard let self else { return }
            guard self.ensureAccessibilityTrusted(generation: currentGeneration) else { return }

            var resolvedMetadata = false
            var resolvedTitle = expectedTitle
            var resolvedWorkspaceName = Self.workspaceFolderName(from: workspacePath)

            var didToggleSidebar = false
            var didExpandSection = false
            var stableSidebarMisses = 0

            for attempt in 0 ..< 80 {
                guard self.isCurrent(generation: currentGeneration) else { return }

                let justExpandedUI = didToggleSidebar || didExpandSection
                if attempt > 0, (resolvedTitle == nil || resolvedWorkspaceName == nil), !resolvedMetadata {
                    resolvedMetadata = true
                    if let target = AntigravitySessionResolver().target(for: conversationID) {
                        if resolvedTitle == nil {
                            resolvedTitle = target.title
                        }
                        if resolvedWorkspaceName == nil {
                            resolvedWorkspaceName = Self.workspaceFolderName(from: target.workspacePath)
                        }
                    }
                }

                let outcome = self.tryPressConversationLink(
                    conversationID: conversationID,
                    expectedTitle: resolvedTitle,
                    expectedWorkspaceName: resolvedWorkspaceName,
                    didToggleSidebar: &didToggleSidebar,
                    didExpandSection: &didExpandSection)

                switch outcome {
                case let .pressed(pid, root):
                    self.ensureMessageInputFocused(
                        pid: pid,
                        root: root,
                        conversationID: conversationID,
                        generation: currentGeneration)
                    return
                case let .retry(sawLoadedSidebar):
                    let expandedThisTurn = !justExpandedUI && (didToggleSidebar || didExpandSection)
                    if expandedThisTurn {
                        stableSidebarMisses = 0
                    } else if sawLoadedSidebar {
                        stableSidebarMisses += 1
                        if stableSidebarMisses >= 15 {
                            return
                        }
                    }
                }

                Thread.sleep(forTimeInterval: attempt < 20 ? 0.015 : 0.06)
            }
        }
    }

    private func nextGeneration() -> UInt64 {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.generation &+= 1
        return self.generation
    }

    private func isCurrent(generation: UInt64) -> Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.generation == generation
    }

    private func cachedElements(for pid: pid_t) -> CachedHubElements? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.cachedHubByPID[pid]
    }

    private func setCachedElements(_ elements: CachedHubElements?, for pid: pid_t) {
        self.stateLock.lock()
        self.cachedHubByPID[pid] = elements
        self.stateLock.unlock()
    }

    private func ensureAccessibilityTrusted(generation: UInt64) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        let shouldPrompt: Bool = {
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            if self.hasPromptedForAccessibility {
                return false
            }
            self.hasPromptedForAccessibility = true
            return true
        }()
        if shouldPrompt {
            DispatchQueue.main.async {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
        for _ in 0 ..< 38 {
            Thread.sleep(forTimeInterval: 0.4)
            guard self.isCurrent(generation: generation) else { return false }
            if AXIsProcessTrusted() {
                return true
            }
        }
        return AXIsProcessTrusted() && self.isCurrent(generation: generation)
    }

    private func tryPressConversationLink(
        conversationID: String,
        expectedTitle: String?,
        expectedWorkspaceName: String?,
        didToggleSidebar: inout Bool,
        didExpandSection: inout Bool) -> AttemptOutcome
    {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        guard !apps.isEmpty else { return .retry(sawLoadedSidebar: false) }

        var sawLoadedSidebar = false
        var toggleCandidate: (button: AXUIElement, window: AXUIElement?, app: NSRunningApplication)?
        var expandCandidate: AXUIElement?
        var titleMatchedWindow: (window: AXUIElement, app: NSRunningApplication)?

        for app in apps {
            let pid = app.processIdentifier

            // Fast path: reuse validated Hub AXWebArea / Sidebar for this PID.
            if let cached = self.cachedElements(for: pid),
               Self.stringAttribute(kAXRoleAttribute as CFString, of: cached.webArea) == "AXWebArea"
            {
                if Self.isShowingSession(cached.webArea, conversationID: conversationID) {
                    return .pressed(pid: pid, root: cached.webArea)
                }
                if let cachedSidebar = cached.sidebar, Self.isSidebarLandmark(cachedSidebar) {
                    let quickScan = Self.scanSidebar(
                        cachedSidebar,
                        conversationID: conversationID,
                        expectedWorkspaceName: expectedWorkspaceName)
                    if let link = quickScan.targetLink,
                       AXUIElementPerformAction(link, kAXPressAction as CFString) == .success
                    {
                        return .pressed(pid: pid, root: cached.webArea)
                    }
                }
            } else {
                self.setCachedElements(nil, for: pid)
            }

            let appElement = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

            let windows = Self.windows(of: appElement)
            var scannedWebAreas: [AXUIElement] = []
            let hubRoots = Self.discoverHubRoots(appElement: appElement, windows: windows, pid: pid)
            for root in hubRoots {
                guard let webArea = root.webArea else { continue }
                if scannedWebAreas.contains(where: { CFEqual($0, webArea) }) {
                    continue
                }
                scannedWebAreas.append(webArea)

                if Self.isShowingSession(webArea, conversationID: conversationID) {
                    if let window = root.window {
                        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    }
                    self.setCachedElements(CachedHubElements(webArea: webArea, sidebar: root.sidebar), for: pid)
                    return .pressed(pid: pid, root: webArea)
                }

                let scan = Self.scanHubWebArea(
                    webArea,
                    knownSidebar: root.sidebar,
                    conversationID: conversationID,
                    expectedWorkspaceName: expectedWorkspaceName)
                self.setCachedElements(
                    CachedHubElements(webArea: webArea, sidebar: scan.sidebar ?? root.sidebar),
                    for: pid)

                if let link = scan.targetLink {
                    if let window = root.window {
                        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    }
                    if AXUIElementPerformAction(link, kAXPressAction as CFString) == .success {
                        return .pressed(pid: pid, root: webArea)
                    }
                }
                if scan.conversationLinkCount > 0 {
                    sawLoadedSidebar = true
                }
                if expandCandidate == nil, let sectionButton = scan.collapsedSectionButton {
                    expandCandidate = sectionButton
                }
                if toggleCandidate == nil,
                   scan.conversationLinkCount == 0,
                   scan.sidebar == nil,
                   let toggleButton = scan.toggleSidebarButton
                {
                    toggleCandidate = (toggleButton, root.window, app)
                }
            }

            // Standalone IDE window fallback (windows that do not host a Hub AXWebArea).
            for window in windows where Self.hubWebArea(in: window) == nil {
                let scan = Self.scanNonHubArea(root: window, conversationID: conversationID)
                if let link = scan.targetLink {
                    Self.raiseAndActivate(window: window, app: app)
                    if AXUIElementPerformAction(link, kAXPressAction as CFString) == .success {
                        return .pressed(pid: pid, root: window)
                    }
                }
                if scan.conversationLinkCount > 0 {
                    sawLoadedSidebar = true
                }
                let windowTitle = Self.stringAttribute(kAXTitleAttribute as CFString, of: window)
                if Self.windowTitleMatches(windowTitle, expectedTitle: expectedTitle),
                   scan.conversationLinkCount == 0
                {
                    titleMatchedWindow = (window, app)
                } else if toggleCandidate == nil,
                          scan.visitedCount > 15,
                          scan.conversationLinkCount == 0,
                          let toggleButton = scan.toggleSidebarButton
                {
                    toggleCandidate = (toggleButton, window, app)
                }
            }
        }

        if let matched = titleMatchedWindow {
            Self.raiseAndActivate(window: matched.window, app: matched.app)
            return .pressed(pid: matched.app.processIdentifier, root: matched.window)
        }

        if !didExpandSection, let sectionButton = expandCandidate {
            if AXUIElementPerformAction(sectionButton, kAXPressAction as CFString) == .success {
                didExpandSection = true
            }
        } else if !didToggleSidebar, let candidate = toggleCandidate {
            if let window = candidate.window {
                Self.raiseAndActivate(window: window, app: candidate.app)
            }
            if AXUIElementPerformAction(candidate.button, kAXPressAction as CFString) == .success {
                didToggleSidebar = true
            }
        }

        return .retry(sawLoadedSidebar: sawLoadedSidebar)
    }

    /// Antigravity's editor only auto-focuses `Message input` on route mount
    /// when `document.hasFocus()` is already `true` and focus is not on a
    /// sidebar `<a>` link. Focus it explicitly once the window is frontmost and
    /// the target session route is active.
    private func ensureMessageInputFocused(
        pid: pid_t,
        root: AXUIElement,
        conversationID: String,
        generation: UInt64)
    {
        let appElement = AXUIElementCreateApplication(pid)
        let isWebArea = Self.stringAttribute(kAXRoleAttribute as CFString, of: root) == "AXWebArea"

        for _ in 0 ..< 30 {
            guard self.isCurrent(generation: generation) else { return }
            let frontmost = Self.boolAttribute(kAXFrontmostAttribute as CFString, of: appElement) == true
            let routeReady = !isWebArea || Self.isShowingSession(root, conversationID: conversationID)
            if frontmost, routeReady {
                if !Self.isMessageInputFocused(appElement: appElement),
                   let input = Self.findMessageInput(in: root)
                {
                    _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                if Self.isMessageInputFocused(appElement: appElement) {
                    Thread.sleep(forTimeInterval: 0.025)
                    guard self.isCurrent(generation: generation) else { return }
                    if Self.isMessageInputFocused(appElement: appElement) {
                        return
                    }
                    if let input = Self.findMessageInput(in: root) {
                        _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    }
                    if Self.isMessageInputFocused(appElement: appElement) {
                        return
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.015)
        }
    }

    private static func isMessageInputFocused(appElement: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return false
        }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        return Self.hasLabel("Message input", on: element)
    }

    private static func findMessageInput(in root: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [root]
        var visited = 0

        while let element = stack.popLast(), visited < 800 {
            visited += 1
            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
            if role == "AXTextArea" || role == "AXComboBox" || role == "AXTextField" {
                if Self.boolAttribute(kAXEnabledAttribute as CFString, of: element) != false,
                   Self.hasLabel("Message input", on: element)
                {
                    return element
                }
                continue
            }
            if role == "AXWebArea", !CFEqual(element, root) {
                continue
            }
            if role == kAXButtonRole as String || role == "AXPopUpButton" || role == "AXImage"
                || role == "AXStaticText" || role == "AXLink" || role == "AXCheckBox"
                || role == "AXList" || role == "AXHeading" || role == "AXMenuBar" || role == "AXMenu"
            {
                continue
            }
            if role == "AXGroup", Self.isIgnoredHubRegion(element) || Self.isSidebarLandmark(element) {
                continue
            }
            // Pushing in order makes popLast() visit trailing children (the
            // bottom input composer) before leading children (Conversation Log).
            stack.append(contentsOf: Self.children(of: element))
        }
        return nil
    }

    private static func discoverHubRoots(
        appElement: AXUIElement,
        windows: [AXUIElement],
        pid: pid_t) -> [HubAncestors]
    {
        var results: [HubAncestors] = []

        // Primary: structural AXWindow -> local Hub AXWebArea (pruning embedded
        // browser WebContentsView tabs in 1 node without coordinate assumptions).
        let unminimized = windows.filter { Self.boolAttribute(kAXMinimizedAttribute as CFString, of: $0) != true }
        let orderedWindows = unminimized.isEmpty ? windows : unminimized
        for window in orderedWindows {
            if let hubArea = Self.hubWebArea(in: window) {
                results.append(HubAncestors(webArea: hubArea, sidebar: nil, window: window))
            }
        }
        if !results.isEmpty {
            return results
        }

        // Fallback: hit-test inside CGWindow bounds when Electron BaseWindow has
        // not yet materialized its AXWindow element.
        let rects = Self.onScreenWindowBounds(pid: pid)
        for rect in rects {
            let probePoints = [
                CGPoint(x: min(rect.minX + 120, rect.maxX - 16), y: min(rect.minY + 180, rect.maxY - 16)),
                CGPoint(x: min(rect.minX + 24, rect.maxX - 16), y: min(rect.minY + 56, rect.maxY - 16)),
                CGPoint(x: rect.midX, y: min(rect.minY + 48, rect.maxY - 16)),
                CGPoint(x: min(rect.minX + 24, rect.maxX - 16), y: rect.midY),
            ]
            for point in probePoints {
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(
                    appElement,
                    Float(point.x),
                    Float(point.y),
                    &hit) == .success,
                      let hit
                else {
                    continue
                }
                let ancestors = Self.resolveHubAncestors(from: hit)
                if ancestors.webArea != nil {
                    results.append(ancestors)
                    if ancestors.sidebar != nil {
                        break
                    }
                }
            }
        }

        if results.isEmpty {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused,
               CFGetTypeID(focused) == AXUIElementGetTypeID()
            {
                let element = unsafeDowncast(focused, to: AXUIElement.self)
                let ancestors = Self.resolveHubAncestors(from: element)
                if ancestors.webArea != nil {
                    results.append(ancestors)
                }
            }
        }

        return results
    }

    private static func hubWebArea(in window: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        var visited = 0

        while index < queue.count, visited < 400 {
            let (element, depth) = queue[index]
            index += 1
            visited += 1

            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
            if role == "AXWebArea" {
                if Self.isLocalHubWebArea(element) {
                    return element
                }
                // Never descend into built-in browser WebContentsView tabs.
                continue
            }
            if role == kAXButtonRole as String || role == "AXMenuBar" || role == "AXMenu" {
                continue
            }
            guard depth < 12 else { continue }
            for child in Self.children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func resolveHubAncestors(from start: AXUIElement) -> HubAncestors {
        var result = HubAncestors()
        var fallbackWebArea: AXUIElement?
        var current = start

        for _ in 0 ..< 64 {
            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: current)
            if result.sidebar == nil, Self.isSidebarLandmark(current) {
                result.sidebar = current
            } else if role == "AXWebArea" {
                fallbackWebArea = current
                if Self.isLocalHubWebArea(current) {
                    result.webArea = current
                }
            } else if role == kAXWindowRole as String {
                result.window = current
            }

            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else {
                break
            }
            let next = unsafeDowncast(parent, to: AXUIElement.self)
            if CFEqual(next, current) {
                break
            }
            current = next
        }

        if result.webArea == nil {
            result.webArea = fallbackWebArea
        }
        return result
    }

    private static func scanHubWebArea(
        _ webArea: AXUIElement,
        knownSidebar: AXUIElement?,
        conversationID: String,
        expectedWorkspaceName: String?) -> HubScanResult
    {
        var result = HubScanResult()
        var sidebar = knownSidebar

        if sidebar == nil {
            var queue: [(element: AXUIElement, depth: Int)] = [(webArea, 0)]
            var index = 0
            while index < queue.count, result.visitedCount < 400 {
                let (element, depth) = queue[index]
                index += 1
                result.visitedCount += 1

                let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
                if role == "AXGroup" {
                    if Self.isSidebarLandmark(element) {
                        sidebar = element
                        if result.toggleSidebarButton != nil {
                            break
                        }
                        continue
                    }
                    if Self.isIgnoredHubRegion(element) {
                        continue
                    }
                } else if role == kAXButtonRole as String, result.toggleSidebarButton == nil {
                    let label = Self.stringAttribute(kAXDescriptionAttribute as CFString, of: element)
                        ?? Self.stringAttribute(kAXTitleAttribute as CFString, of: element)
                    if let label, label.hasPrefix("Toggle Sidebar") {
                        result.toggleSidebarButton = element
                        if sidebar != nil {
                            break
                        }
                    }
                    continue
                } else if role != "AXWebArea" {
                    continue
                }

                guard depth < 14 else { continue }
                for child in Self.children(of: element) {
                    queue.append((child, depth + 1))
                }
            }
        }

        result.sidebar = sidebar
        if let sidebar {
            let sidebarScan = Self.scanSidebar(
                sidebar,
                conversationID: conversationID,
                expectedWorkspaceName: expectedWorkspaceName)
            result.targetLink = sidebarScan.targetLink
            result.conversationLinkCount = sidebarScan.conversationLinkCount
            result.collapsedSectionButton = sidebarScan.collapsedSectionButton
            result.visitedCount += sidebarScan.visitedCount
            if result.targetLink != nil {
                return result
            }
        }

        // Main-area fallback (e.g. `/history` list or future landmark rename).
        let fallback = Self.scanNonHubArea(root: webArea, conversationID: conversationID)
        result.visitedCount += fallback.visitedCount
        if let link = fallback.targetLink {
            result.targetLink = link
        }
        if fallback.conversationLinkCount > result.conversationLinkCount {
            result.conversationLinkCount = fallback.conversationLinkCount
        }
        if result.toggleSidebarButton == nil {
            result.toggleSidebarButton = fallback.toggleSidebarButton
        }
        return result
    }

    private static func scanSidebar(
        _ sidebar: AXUIElement,
        conversationID: String,
        expectedWorkspaceName: String?) -> HubScanResult
    {
        var result = HubScanResult(sidebar: sidebar)
        var queue: [AXUIElement] = [sidebar]
        var buttons: [AXUIElement] = []
        var index = 0

        while index < queue.count, result.visitedCount < 2500 {
            let element = queue[index]
            index += 1
            result.visitedCount += 1

            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
            if role == "AXLink" {
                if let url = Self.elementURL(of: element) {
                    if Self.matchesConversationLink(url, conversationID: conversationID) {
                        result.targetLink = element
                        return result
                    }
                    if Self.isHubURL(url), url.path.hasPrefix("/c/") {
                        result.conversationLinkCount += 1
                    }
                }
                continue
            }

            if role == kAXButtonRole as String {
                buttons.append(element)
                continue
            }

            if role == "AXPopUpButton" || role == "AXImage" || role == "AXStaticText" || role == "AXCheckBox" {
                continue
            }

            queue.append(contentsOf: Self.children(of: element))
        }

        var fallbackMainHeaderButton: AXUIElement?
        for button in buttons {
            guard Self.boolAttribute("AXExpanded" as CFString, of: button) == false else { continue }
            let label = (Self.stringAttribute(kAXTitleAttribute as CFString, of: button)
                ?? Self.stringAttribute(kAXDescriptionAttribute as CFString, of: button))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label, !label.isEmpty else { continue }
            if let expectedWorkspaceName,
               label.caseInsensitiveCompare(expectedWorkspaceName) == .orderedSame
            {
                result.collapsedSectionButton = button
                break
            }
            if fallbackMainHeaderButton == nil,
               label == "Conversations" || label == "Workspaces" || label == "Projects"
            {
                fallbackMainHeaderButton = button
            }
        }

        if result.collapsedSectionButton == nil, result.conversationLinkCount == 0 {
            result.collapsedSectionButton = fallbackMainHeaderButton
        }
        return result
    }

    private static func scanNonHubArea(root: AXUIElement, conversationID: String) -> HubScanResult {
        var result = HubScanResult()
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        let maxNodes = 4000
        let maxDepth = 32

        while index < queue.count, result.visitedCount < maxNodes {
            let (element, depth) = queue[index]
            index += 1
            result.visitedCount += 1

            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
            if role == "AXWebArea", !CFEqual(element, root) {
                if !Self.isLocalHubWebArea(element) {
                    continue
                }
            }
            if role == "AXLink" {
                if let url = Self.elementURL(of: element) {
                    if Self.matchesConversationLink(url, conversationID: conversationID) {
                        result.targetLink = element
                        return result
                    }
                    if Self.isHubURL(url), url.path.hasPrefix("/c/") {
                        result.conversationLinkCount += 1
                    }
                }
                continue
            }
            if role == kAXButtonRole as String {
                if result.toggleSidebarButton == nil {
                    let label = Self.stringAttribute(kAXDescriptionAttribute as CFString, of: element)
                        ?? Self.stringAttribute(kAXTitleAttribute as CFString, of: element)
                    if let label, label.hasPrefix("Toggle Sidebar") {
                        result.toggleSidebarButton = element
                    }
                }
                continue
            }
            if role == "AXPopUpButton" || role == "AXImage" || role == "AXStaticText" || role == "AXCheckBox"
                || role == "AXMenuBar" || role == "AXMenu" || role == "AXApplication"
            {
                continue
            }
            if role == "AXGroup", Self.isSidebarLandmark(element) || Self.isIgnoredHubRegion(element) {
                continue
            }

            guard depth < maxDepth else { continue }
            for child in Self.children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    private static func isSidebarLandmark(_ element: AXUIElement) -> Bool {
        Self.hasLabel("Sidebar", on: element)
            && (Self.stringAttribute(kAXSubroleAttribute as CFString, of: element) == "AXLandmarkNavigation"
                || Self.stringAttribute(kAXRoleAttribute as CFString, of: element) == kAXGroupRole as String)
    }

    private static func isIgnoredHubRegion(_ element: AXUIElement) -> Bool {
        Self.hasLabel("File Viewer", on: element)
            || Self.hasLabel("Notifications", on: element)
            || Self.hasLabel("Typeahead menu", on: element)
    }

    private static func hasLabel(_ expected: String, on element: AXUIElement) -> Bool {
        Self.stringAttribute(kAXDescriptionAttribute as CFString, of: element) == expected
            || Self.stringAttribute(kAXTitleAttribute as CFString, of: element) == expected
    }

    private static func isLocalHubWebArea(_ element: AXUIElement) -> Bool {
        guard let url = Self.elementURL(of: element) else { return false }
        return Self.isHubURL(url)
    }

    private static func isShowingSession(_ element: AXUIElement, conversationID: String) -> Bool {
        guard let url = Self.elementURL(of: element) else { return false }
        return Self.matchesSession(url, conversationID: conversationID)
    }

    static func matchesSession(_ url: URL, conversationID: String) -> Bool {
        guard Self.isHubURL(url), url.path.hasPrefix("/c/") else {
            return false
        }
        let target = conversationID.lowercased()
        let rawIDs = String(url.path.dropFirst("/c/".count))
        if rawIDs.lowercased() == target {
            return true
        }
        guard rawIDs.contains("+") else {
            return false
        }
        let panes = rawIDs.split(separator: "+").map { $0.lowercased() }
        guard panes.contains(target) else {
            return false
        }
        let focused = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "focused" })?
            .value?
            .lowercased()
        return (focused ?? panes.first) == target
    }

    static func matchesConversationLink(_ url: URL, conversationID: String) -> Bool {
        guard Self.isHubURL(url) else { return false }
        return url.path.lowercased() == "/c/\(conversationID.lowercased())"
    }

    private static func isHubURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func elementURL(of element: AXUIElement) -> URL? {
        for attr in [kAXURLAttribute as CFString, kAXDocumentAttribute as CFString] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
                  let value
            else {
                continue
            }
            if let url = value as? URL {
                return url
            }
            if let raw = value as? String, let url = URL(string: raw) {
                return url
            }
        }
        return nil
    }

    private static func onScreenWindowBounds(pid: pid_t) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }
        return windows.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 300,
                  rect.height >= 200
            else {
                return nil
            }
            return rect
        }
    }

    private static func workspaceFolderName(from workspacePath: String?) -> String? {
        guard let raw = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let name = URL(fileURLWithPath: raw).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? nil : name
    }

    private static func raiseAndActivate(window: AXUIElement, app: NSRunningApplication) {
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = app.activate(options: [.activateAllWindows])
    }

    private static func windows(of appElement: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement]
        {
            result = list.filter {
                !CFEqual($0, appElement)
                    && Self.stringAttribute(kAXRoleAttribute as CFString, of: $0) == kAXWindowRole as String
            }
        }
        if result.isEmpty {
            for attr in [kAXMainWindowAttribute as CFString, kAXFocusedWindowAttribute as CFString] {
                var single: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, attr, &single) == .success,
                   let element = single,
                   CFGetTypeID(element) == AXUIElementGetTypeID()
                {
                    let axWindow = unsafeDowncast(element, to: AXUIElement.self)
                    if !CFEqual(axWindow, appElement),
                       Self.stringAttribute(kAXRoleAttribute as CFString, of: axWindow) == kAXWindowRole as String
                    {
                        result.append(axWindow)
                        break
                    }
                }
            }
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else {
            return []
        }
        return children
    }

    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String
        else {
            return nil
        }
        return string
    }

    private static func boolAttribute(_ attribute: CFString, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let boolValue = value as? Bool
        else {
            return nil
        }
        return boolValue
    }

    private static func windowTitleMatches(_ windowTitle: String?, expectedTitle: String?) -> Bool {
        guard let windowTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !windowTitle.isEmpty,
              let expected = expectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty
        else {
            return false
        }
        let truncated = expected.count > 25 ? String(expected.prefix(25)) + "..." : expected
        return windowTitle == expected
            || windowTitle == truncated
            || windowTitle.hasPrefix(expected + " —")
            || windowTitle.hasPrefix(truncated + " —")
    }
}
