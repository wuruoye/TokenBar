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
    private let navigateAntigravityConversation: @MainActor (String, String?) -> Void

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
        navigateAntigravityConversation: @escaping @MainActor (String, String?) -> Void = {
            AntigravityConversationNavigator.shared.navigate(to: $0, expectedTitle: $1)
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
            let target = self.resolveAntigravitySession(sessionID)
            let fallbackTitle = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedTitle = target?.title ?? fallbackTitle.flatMap { $0.isEmpty ? nil : $0 }
            onWillOpen?(sessionID)
            try self.openAntigravity(conversationID: sessionID, expectedTitle: expectedTitle)
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
        if platform == .antigravity {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isSafePathIdentifier(trimmed) else {
                throw SessionLauncherError.invalidSessionID
            }
            let target = self.resolveAntigravitySession(trimmed)
            onWillOpen?(trimmed)
            try self.openAntigravity(conversationID: trimmed, expectedTitle: target?.title)
            return
        }
        let url = try Self.deepLink(platform: platform, id: id)
        onWillOpen?(id)
        guard self.openURL(url) else {
            throw SessionLauncherError.applicationUnavailable(platform)
        }
    }

    private func openAntigravity(conversationID: String, expectedTitle: String?) throws {
        let activated = self.openURL(Self.antigravityFocusURL) || self.launchAntigravityApplication()
        guard activated else {
            throw SessionLauncherError.applicationUnavailable(.antigravity)
        }
        self.navigateAntigravityConversation(conversationID, expectedTitle)
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
        default:
            throw SessionLauncherError.unsupportedPlatform(session.platformID)
        }
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
/// matching sidebar conversation link via macOS Accessibility.
///
/// Antigravity's `antigravity://open` URL scheme resets the Hub router to the
/// blank new-conversation screen when invoked without a prompt, whereas
/// `antigravity://focus` brings the existing window forward untouched and each
/// sidebar item is exposed as a standard `AXLink` whose `AXURL` path is
/// `/c/<conversationID>`.
@MainActor
final class AntigravityConversationNavigator {
    static let shared = AntigravityConversationNavigator()

    private let bundleIdentifier = "com.google.antigravity"
    private var hasPromptedForAccessibility = false
    private var activeTask: Task<Void, Never>?

    func navigate(to conversationID: String, expectedTitle: String?) {
        self.activeTask?.cancel()
        self.activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !AXIsProcessTrusted() {
                if !self.hasPromptedForAccessibility {
                    self.hasPromptedForAccessibility = true
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
                for _ in 0 ..< 38 {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    if AXIsProcessTrusted() {
                        break
                    }
                }
                guard AXIsProcessTrusted(), !Task.isCancelled else { return }
            }

            var didToggleSidebar = false
            for attempt in 0 ..< 16 {
                guard !Task.isCancelled else { return }
                if self.tryPressConversationLink(
                    conversationID: conversationID,
                    expectedTitle: expectedTitle,
                    allowToggleSidebar: !didToggleSidebar,
                    didToggleSidebar: &didToggleSidebar)
                {
                    return
                }
                let delay: Duration = attempt == 0 ? .milliseconds(120) : .milliseconds(160)
                try? await Task.sleep(for: delay)
            }
        }
    }

    private struct WindowScan {
        var targetLink: AXUIElement?
        var conversationLinkCount = 0
        var toggleSidebarButton: AXUIElement?
        var visitedCount = 0
    }

    private func tryPressConversationLink(
        conversationID: String,
        expectedTitle: String?,
        allowToggleSidebar: Bool,
        didToggleSidebar: inout Bool) -> Bool
    {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleIdentifier)
        guard !apps.isEmpty else { return false }
        let targetPath = "/c/\(conversationID)"

        var fallbackToggleCandidate: (window: AXUIElement, button: AXUIElement, app: NSRunningApplication)?
        var titleMatchedWindow: (window: AXUIElement, app: NSRunningApplication)?

        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

            let windows = Self.windows(of: appElement)
            for window in windows {
                let scan = Self.scan(window: window, targetPath: targetPath)
                if let link = scan.targetLink {
                    Self.raiseAndActivate(window: window, app: app)
                    if AXUIElementPerformAction(link, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
                let windowTitle = Self.stringAttribute(kAXTitleAttribute as CFString, of: window)
                if Self.windowTitleMatches(windowTitle, expectedTitle: expectedTitle),
                   scan.conversationLinkCount == 0
                {
                    titleMatchedWindow = (window, app)
                } else if fallbackToggleCandidate == nil,
                          scan.visitedCount > 15,
                          scan.conversationLinkCount == 0,
                          let toggleButton = scan.toggleSidebarButton
                {
                    fallbackToggleCandidate = (window, toggleButton, app)
                }
            }
        }

        if let matched = titleMatchedWindow {
            Self.raiseAndActivate(window: matched.window, app: matched.app)
            return true
        }

        if allowToggleSidebar, let candidate = fallbackToggleCandidate {
            Self.raiseAndActivate(window: candidate.window, app: candidate.app)
            if AXUIElementPerformAction(candidate.button, kAXPressAction as CFString) == .success {
                didToggleSidebar = true
            }
        }
        return false
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
            result.append(contentsOf: list)
        }
        if result.isEmpty {
            for attr in [kAXMainWindowAttribute as CFString, kAXFocusedWindowAttribute as CFString] {
                var single: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, attr, &single) == .success,
                   let element = single
                {
                    // CoreFoundation type check for AXUIElement
                    if CFGetTypeID(element) == AXUIElementGetTypeID() {
                        result.append(unsafeDowncast(element, to: AXUIElement.self))
                        break
                    }
                }
            }
        }
        return result
    }

    private static func scan(window: AXUIElement, targetPath: String) -> WindowScan {
        var result = WindowScan()
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        let maxNodes = 12000
        let maxDepth = 50

        while index < queue.count, result.visitedCount < maxNodes {
            let (element, depth) = queue[index]
            index += 1
            result.visitedCount += 1

            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element)
            if role == "AXLink", let path = Self.urlPath(of: element) {
                if path == targetPath {
                    result.targetLink = element
                    return result
                }
                if path.hasPrefix("/c/") {
                    result.conversationLinkCount += 1
                }
            } else if role == kAXButtonRole as String, result.toggleSidebarButton == nil {
                let label = Self.stringAttribute(kAXDescriptionAttribute as CFString, of: element)
                    ?? Self.stringAttribute(kAXTitleAttribute as CFString, of: element)
                if let label, label.hasPrefix("Toggle Sidebar") {
                    result.toggleSidebarButton = element
                }
            }

            guard depth < maxDepth else { continue }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement]
            {
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }
        return result
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

    private static func urlPath(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        if let url = value as? URL {
            return url.path
        }
        if let raw = value as? String {
            if let url = URL(string: raw), !url.path.isEmpty {
                return url.path
            }
            return raw
        }
        return nil
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
