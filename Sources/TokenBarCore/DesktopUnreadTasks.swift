import CoreServices
import CryptoKit
import Foundation
import Observation
import SQLite3

/// One finished task that a desktop app's sidebar still marks as unread.
public struct DesktopUnreadTask: Equatable, Identifiable, Sendable {
    public let platform: TokenPlatform
    /// The Codex thread ID or Claude Desktop session ID that each app's deep
    /// link opens.
    public let id: String
    public let title: String?
    /// The last prompt the user sent in the task, flattened to one line.
    public let prompt: String?
    /// The opening text of the reply that finished the task, without Markdown.
    public let reply: String?
    /// How long the task's last turn ran.
    public let turnDuration: TimeInterval?
    public let workspacePath: String?
    public let updatedAt: Date?

    public init(
        platform: TokenPlatform,
        id: String,
        title: String?,
        prompt: String?,
        reply: String?,
        turnDuration: TimeInterval?,
        workspacePath: String?,
        updatedAt: Date?)
    {
        self.platform = platform
        self.id = id
        self.title = title
        self.prompt = prompt
        self.reply = reply
        self.turnDuration = turnDuration
        self.workspacePath = workspacePath
        self.updatedAt = updatedAt
    }
}

/// Tracks finished Codex and Claude desktop tasks that each app's sidebar still
/// marks as unread.
///
/// The apps mark the task they show as read as soon as their window comes to
/// the front, even when the user only passes through on the way to another
/// app or Space. So a task an app marks read stays unread here until the user
/// has seen it: opened it from TokenBar, or after it finished, kept its app in
/// front showing it for `readDwell`. Claude logs the session its window shows,
/// and a switch the user makes there reads the sessions on both sides of it
/// however short the visit. Codex logs nothing like that, so a Codex visit
/// that lasts `readDwell` reads every task.
@MainActor
@Observable
public final class DesktopUnreadTaskMonitor {
    /// Unread tasks per platform, most recently updated first.
    public private(set) var tasks: [TokenPlatform: [DesktopUnreadTask]] = [:]
    /// Tasks still running a turn per platform, most recently started first.
    public private(set) var running: [TokenPlatform: [DesktopRunningTask]] = [:]

    /// A time an app was in front.
    private struct Visit {
        let start: Date
        var end: Date?
    }

    private struct HeldTask {
        let task: DesktopUnreadTask
        let since: Date
    }

    /// How long an app has to stay in front for the task it shows to count as read.
    static let readDwell: TimeInterval = 3
    /// An app can write the read state of a task opened from TokenBar a while later.
    static let readLag: TimeInterval = 60
    /// Claude's log reaches back a few hours, so older visits are not kept.
    static let visitHistoryLimit: TimeInterval = 4 * 60 * 60
    /// How long Claude can take to switch to a session opened from TokenBar.
    static let claudeOpenSwitchLag: TimeInterval = 10
    /// Bounds a hold on a task read where TokenBar cannot see, such as on another device.
    static let holdLimit: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private let reader: DesktopUnreadTaskReader
    @ObservationIgnored private var watcher: DesktopUnreadTaskWatcher?

    @ObservationIgnored private let claudeTrackerStateURL: URL?
    @ObservationIgnored private var isClaudeActive = true
    /// The unread tasks each app reports, before held tasks are added.
    @ObservationIgnored private var reported: [TokenPlatform: [DesktopUnreadTask]] = [:]
    /// Tasks an app marked read before the user saw them.
    @ObservationIgnored private var held: [TokenPlatform: [String: HeldTask]] = [:]
    /// The sessions that still exist unarchived, for an app that tells.
    @ObservationIgnored private var existing: [TokenPlatform: Set<String>] = [:]
    /// Each app's recent visits, oldest first, the last one possibly still going.
    @ObservationIgnored private var visits: [TokenPlatform: [Visit]] = [:]
    /// Claude's focus changes, read again only when its log grows.
    @ObservationIgnored private var claudeFocusCache: (logSize: UInt64, changes: [ClaudeFocusChange])?
    /// Tasks opened from TokenBar, which count as read as soon as their app shows them.
    @ObservationIgnored private var openedAt: [TokenPlatform: [String: Date]] = [:]
    /// Claude sessions opened from TokenBar, oldest first. Claude logs the
    /// switch to one like a switch the user makes.
    @ObservationIgnored private var claudeOpens: [(id: String, at: Date)] = []
    @ObservationIgnored private var releaseChecks: [TokenPlatform: Task<Void, Never>] = [:]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        claudeTrackerStateURL: URL? = DesktopUnreadTaskMonitor.defaultClaudeTrackerStateURL())
    {
        self.reader = DesktopUnreadTaskReader(environment: environment)
        self.claudeTrackerStateURL = claudeTrackerStateURL
    }

    public nonisolated static func defaultClaudeTrackerStateURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("claude-unread-state.json", isDirectory: false)
    }

    public var counts: [TokenPlatform: Int] {
        self.tasks.mapValues(\.count)
    }

    public func count(for platform: TokenPlatform) -> Int {
        self.tasks[platform]?.count ?? 0
    }

    public nonisolated static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
    public nonisolated static let codexBundleIdentifier = "com.openai.codex"

    /// Hears which app is in front. Claude counts a turn that ends in the
    /// session its window shows as read, even while another app is in front,
    /// so TokenBar keeps such a turn unread until Claude comes to the front on
    /// it.
    public func setFrontmostApplication(_ bundleIdentifier: String?) {
        let platform: TokenPlatform? = switch bundleIdentifier {
        case Self.claudeBundleIdentifier: .claude
        case Self.codexBundleIdentifier: .codex
        default: nil
        }
        let now = Date()
        for (other, history) in self.visits where other != platform {
            guard let last = history.indices.last, history[last].end == nil else { continue }
            self.visits[other]?[last].end = now
            self.releaseChecks.removeValue(forKey: other)?.cancel()
        }
        if let platform, self.visits[platform]?.last.map({ $0.end != nil }) ?? true {
            self.visits[platform] = (self.visits[platform] ?? []).filter {
                now.timeIntervalSince($0.end ?? now) < Self.visitHistoryLimit
            } + [Visit(start: now)]
            self.scheduleReleaseCheck(for: platform)
        }
        let isClaudeActive = platform == .claude
        if isClaudeActive != self.isClaudeActive {
            self.isClaudeActive = isClaudeActive
            self.watcher?.setClaudeActive(isClaudeActive)
        }
    }

    /// A task opened from TokenBar is read once its app shows it, however
    /// briefly.
    public func markOpened(platform: TokenPlatform, id: String) {
        let now = Date()
        self.openedAt[platform, default: [:]][id] = now
        if platform == .claude {
            self.claudeOpens = self.claudeOpens.filter {
                now.timeIntervalSince($0.at) < Self.visitHistoryLimit
            } + [(id, now)]
        }
        if self.held[platform]?.removeValue(forKey: id) != nil {
            self.publishTasks(for: platform)
        }
    }

    public func start() {
        guard self.watcher == nil else { return }
        let watcher = DesktopUnreadTaskWatcher(
            reader: self.reader,
            claudeTrackerStateURL: self.claudeTrackerStateURL,
            publish: { [weak self] platform, tasks, existing in
                Task { @MainActor [weak self] in
                    self?.accept(tasks, existing: existing, for: platform)
                }
            },
            publishRunning: { [weak self] platform, tasks in
                Task { @MainActor [weak self] in
                    self?.acceptRunning(tasks, for: platform)
                }
            })
        self.watcher = watcher
        watcher.setClaudeActive(self.isClaudeActive)
        watcher.start()
    }

    public func stop() {
        self.watcher?.stop()
        self.watcher = nil
        self.tasks = [:]
        self.running = [:]
        self.reported = [:]
        self.held = [:]
        self.existing = [:]
        self.openedAt = [:]
        self.claudeOpens = []
        for check in self.releaseChecks.values {
            check.cancel()
        }
        self.releaseChecks = [:]
    }

    public func refresh() {
        self.watcher?.refresh()
    }

    /// Holds the tasks the app no longer reports, unless opened from TokenBar.
    private func accept(_ tasks: [DesktopUnreadTask], existing: Set<String>?, for platform: TokenPlatform) {
        guard self.watcher != nil else { return }
        let now = Date()
        let ids = Set(tasks.map(\.id))
        let opened = (self.openedAt[platform] ?? [:]).filter { now.timeIntervalSince($0.value) < Self.readLag }
        self.openedAt[platform] = opened
        for task in self.reported[platform] ?? [] where !ids.contains(task.id) && opened[task.id] == nil {
            self.held[platform, default: [:]][task.id] = HeldTask(task: task, since: now)
        }
        self.reported[platform] = tasks
        self.existing[platform] = existing
        self.releaseHeld(for: platform, now: now)
        self.publishTasks(for: platform)
    }

    private func acceptRunning(_ tasks: [DesktopRunningTask], for platform: TokenPlatform) {
        guard self.watcher != nil, self.running[platform] != tasks else { return }
        self.running[platform] = tasks
        // A new turn means the user saw the last one.
        if !(self.held[platform] ?? [:]).isEmpty {
            self.publishTasks(for: platform)
        }
    }

    private func claudeFocusChanges() -> [ClaudeFocusChange]? {
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: self.reader.claudeMainLog.path))?[.size] as? NSNumber
        else {
            return nil
        }
        if let cache = self.claudeFocusCache, cache.logSize == size.uint64Value {
            return cache.changes
        }
        guard let changes = self.reader.claudeFocusChanges() else { return nil }
        self.claudeFocusCache = (size.uint64Value, changes)
        return changes
    }

    /// Whether a visit that ended after the task finished read it. Without
    /// Claude's log, a visit reads every task once it lasts `readDwell`.
    private func seen(
        _ task: DesktopUnreadTask,
        on platform: TokenPlatform,
        focus: [ClaudeFocusChange]?,
        now: Date) -> Bool
    {
        let finishedAt = task.updatedAt ?? .distantPast
        return (self.visits[platform] ?? []).contains { visit in
            guard (visit.end ?? now) >= finishedAt else { return false }
            guard let focus else {
                return (visit.end ?? now).timeIntervalSince(visit.start) >= Self.readDwell
            }
            return self.claudeVisitRead(task.id, visit: visit, focus: focus, now: now)
        }
    }

    /// The visit read the session if it showed the session for `readDwell`,
    /// or the user switched to it or away from it. A session opened from
    /// TokenBar replaces the one the window showed before the user saw it.
    private func claudeVisitRead(_ id: String, visit: Visit, focus: [ClaudeFocusChange], now: Date) -> Bool {
        var shown = focus.last { $0.at <= visit.start.addingTimeInterval(-1) }?.sessionID
        var shownSince = visit.start
        var duration: TimeInterval = 0
        for change in Self.changes(during: visit, focus: focus, now: now) {
            let at = max(change.at, visit.start)
            if shown == id {
                duration += at.timeIntervalSince(shownSince)
            }
            if shown == id || change.sessionID == id, !self.isOpenSwitch(change) {
                return true
            }
            shown = change.sessionID
            shownSince = at
        }
        if shown == id {
            duration += (visit.end ?? now).timeIntervalSince(shownSince)
        }
        return duration >= Self.readDwell
    }

    /// Claude logs a switch as no session, then the new one, in the same second.
    private func isOpenSwitch(_ change: ClaudeFocusChange) -> Bool {
        self.claudeOpens.contains { open in
            (change.sessionID == nil || change.sessionID == open.id)
                && change.at > open.at.addingTimeInterval(-1)
                && change.at < open.at.addingTimeInterval(Self.claudeOpenSwitchLag)
        }
    }

    /// The log counts seconds, so a switch in the second the visit began
    /// belongs to it.
    private static func changes(
        during visit: Visit,
        focus: [ClaudeFocusChange],
        now: Date) -> [ClaudeFocusChange]
    {
        focus.filter { $0.at > visit.start.addingTimeInterval(-1) && $0.at <= (visit.end ?? now) }
    }

    /// Releases the held tasks the user has since seen, and drops those archived.
    private func releaseHeld(for platform: TokenPlatform, now: Date) {
        guard let held = self.held[platform], !held.isEmpty else { return }
        let focus = platform == .claude ? self.claudeFocusChanges() : nil
        let existing = self.existing[platform]
        self.held[platform] = held.filter { id, hold in
            now.timeIntervalSince(hold.since) < Self.holdLimit
                && existing?.contains(id) != false
                && !self.seen(hold.task, on: platform, focus: focus, now: now)
        }
    }

    /// Checks once when the visit reaches `readDwell`. A switch the user makes
    /// in Claude rewrites the session records, and the recount that follows
    /// releases what it read.
    private func scheduleReleaseCheck(for platform: TokenPlatform) {
        guard let held = self.held[platform], !held.isEmpty,
              let visit = self.visits[platform]?.last,
              visit.end == nil
        else {
            return
        }
        let remaining = Self.readDwell - Date().timeIntervalSince(visit.start)
        guard remaining > 0 else { return }
        let delay = remaining + 0.1
        self.releaseChecks[platform]?.cancel()
        self.releaseChecks[platform] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.releaseChecks[platform] = nil
            self.releaseHeld(for: platform, now: Date())
            self.publishTasks(for: platform)
        }
    }

    /// Publishes the reported tasks and the held ones that are neither
    /// reported again nor running a new turn.
    private func publishTasks(for platform: TokenPlatform) {
        let reported = self.reported[platform] ?? []
        let excluded = Set(reported.map(\.id) + (self.running[platform] ?? []).map(\.id))
        let held = (self.held[platform] ?? [:]).filter { !excluded.contains($0.key) }
        self.held[platform] = held
        let tasks = held.isEmpty ? reported : (reported + held.values.map(\.task)).sorted {
            ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id)
        }
        if !held.isEmpty {
            self.scheduleReleaseCheck(for: platform)
        }
        guard self.tasks[platform] != tasks else { return }
        self.tasks[platform] = tasks
    }
}

struct DesktopUnreadTaskReader: Sendable {
    static let platforms: [TokenPlatform] = [.codex, .claude]

    let codexHome: URL
    let claudeSupportDirectory: URL
    let claudeProjectsDirectory: URL
    let claudeMainLog: URL
    let backgroundTasksDirectory: URL

    init(
        codexHome: URL, claudeSupportDirectory: URL, claudeProjectsDirectory: URL, claudeMainLog: URL,
        backgroundTasksDirectory: URL = CodexBackgroundTaskReader.directory(environment: [:]))
    {
        self.codexHome = codexHome
        self.claudeSupportDirectory = claudeSupportDirectory
        self.claudeProjectsDirectory = claudeProjectsDirectory
        self.claudeMainLog = claudeMainLog
        self.backgroundTasksDirectory = backgroundTasksDirectory
    }

    init(environment: [String: String]) {
        let fileManager = FileManager.default
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let claudeConfigDirectory = environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        self.init(
            codexHome: CodexAuthStore.codexHomeURL(environment: environment),
            claudeSupportDirectory: applicationSupport
                .appendingPathComponent("Claude", isDirectory: true),
            claudeProjectsDirectory: claudeConfigDirectory
                .appendingPathComponent("projects", isDirectory: true),
            claudeMainLog: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Claude/main.log", isDirectory: false),
            backgroundTasksDirectory: CodexBackgroundTaskReader.directory(environment: environment))
    }

    // MARK: Codex

    /// Codex Desktop stores unread thread IDs per signed-in identity and execution
    /// host in `.codex-global-state.json`. The list also keeps subagent threads the
    /// sidebar never shows, so IDs are checked against the local thread database.
    func codexUnreadTasks(turns: DesktopUnreadTurnReader) -> [DesktopUnreadTask] {
        let stateURL = self.codexHome.appendingPathComponent(
            ".codex-global-state.json",
            isDirectory: false)
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let readState = object["electron-thread-read-state-v1"] as? [String: Any],
              let identities = readState["unreadByIdentity"] as? [String: Any]
        else {
            return []
        }

        let hostMaps: [Any] = if let identity = self.codexIdentityKey() {
            identities[identity].map { [$0] } ?? []
        } else {
            Array(identities.values)
        }
        var threadIDs = Set<String>()
        for case let hosts as [String: Any] in hostMaps {
            for (hostKey, ids) in hosts where hostKey.hasPrefix("local:") {
                for case let id as String in ids as? [Any] ?? [] {
                    threadIDs.insert(id)
                }
            }
        }
        guard !threadIDs.isEmpty else { return [] }
        return self.visibleCodexThreads(.ids(threadIDs)).map { thread in
            let turn = thread.rolloutPath.map {
                turns.codexTurn(rolloutURL: URL(fileURLWithPath: $0))
            }
            return DesktopUnreadTask(
                platform: .codex,
                id: thread.id,
                title: thread.title,
                prompt: turn?.prompt ?? thread.firstPrompt,
                reply: turn?.reply,
                turnDuration: turn?.duration,
                workspacePath: thread.workspacePath,
                updatedAt: thread.updatedAt)
        }
    }

    /// Codex Desktop keys ChatGPT sign-ins by
    /// `sha256(JSON.stringify(["chatgpt", accountId, userId]))`.
    private func codexIdentityKey() -> String? {
        let authURL = self.codexHome.appendingPathComponent("auth.json", isDirectory: false)
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = Self.jwtClaims(idToken)
        else {
            return nil
        }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        guard let accountID = (tokens["account_id"] as? String)
            ?? (auth?["chatgpt_account_id"] as? String),
            let userID = (auth?["chatgpt_user_id"] as? String)
            ?? (auth?["user_id"] as? String),
            let identity = try? JSONSerialization.data(
                withJSONObject: ["chatgpt", accountID, userID],
                options: [.withoutEscapingSlashes])
        else {
            return nil
        }
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private struct CodexThread {
        let id: String
        let title: String?
        let firstPrompt: String?
        let workspacePath: String?
        let rolloutPath: String?
        let updatedAt: Date?
    }

    /// Codex threads that ran a turn since a moment, which includes every
    /// thread still running one, and the rollouts their next turn writes to.
    func codexRunningTasks(
        states: CodexTurnStateReader,
        now: Date) -> (tasks: [DesktopRunningTask], rollouts: Set<String>)
    {
        let background = CodexBackgroundTaskReader(directory: self.backgroundTasksDirectory).tasks(now: now)
        var threads = self.visibleCodexThreads(.updatedSince(now.addingTimeInterval(-24 * 60 * 60)))
        let olderIDs = Set(background.keys).subtracting(threads.map(\.id))
        if !olderIDs.isEmpty {
            threads += self.visibleCodexThreads(.ids(olderIDs))
        }
        let rollouts = Set(threads.compactMap(\.rolloutPath))
        states.forget(except: rollouts)
        let tasks = threads.compactMap { thread -> DesktopRunningTask? in
            let backgroundTask = background[thread.id].map { task in
                DesktopRunningTask(
                    platform: .codex, id: thread.id, title: thread.title ?? task.name,
                    startedAt: task.startedAt, activity: task.activity,
                    isInBackground: true, isInterrupted: task.isInterrupted)
            }
            guard let path = thread.rolloutPath,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modifiedAt) < DesktopRunningTaskLiveness.quietLimit
            else {
                return backgroundTask
            }
            let state = states.state(of: URL(fileURLWithPath: path), size: size)
            guard state.isRunning else { return backgroundTask }
            return DesktopRunningTask(
                platform: .codex,
                id: thread.id,
                title: thread.title,
                startedAt: state.startedAt,
                activity: state.activity)
        }
        return (tasks, rollouts)
    }

    private enum CodexThreadFilter {
        case ids(Set<String>)
        case updatedSince(Date)
    }

    private func visibleCodexThreads(_ filter: CodexThreadFilter) -> [CodexThread] {
        guard let databaseURL = self.codexStateDatabaseURL() else { return [] }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_busy_timeout(database, 1000)

        // Older thread databases lack the columns Codex added later, such as the
        // generated `name` the sidebar shows in place of the first prompt.
        let columns = Self.columnNames(of: "threads", in: database)
        func column(_ name: String) -> String {
            columns.contains(name) ? name : "NULL"
        }
        let updatedAt = "COALESCE(\(column("updated_at_ms")), \(column("updated_at")) * 1000)"
        let condition = switch filter {
        case let .ids(ids):
            "id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))"
        case .updatedSince:
            "\(updatedAt) >= ?"
        }
        let sql = """
            SELECT id, \(column("name")), \(column("title")), \(column("cwd")),
                   \(column("rollout_path")), \(updatedAt)
            FROM threads
            WHERE archived = 0
              AND COALESCE(source, '') NOT LIKE '{"subagent"%'
              AND \(condition)
            ORDER BY 6 DESC
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        switch filter {
        case let .ids(ids):
            for (index, id) in ids.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), id, -1, Self.sqliteTransient)
            }
        case let .updatedSince(date):
            sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970 * 1000))
        }
        var threads: [CodexThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.text(statement, 0) else { continue }
            let firstPrompt = Self.text(statement, 2).flatMap(DesktopUnreadTurnReader.flattened)
            let updatedAtMs = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 5)
            threads.append(CodexThread(
                id: id,
                title: Self.text(statement, 1).flatMap(DesktopUnreadTurnReader.flattened) ?? firstPrompt,
                firstPrompt: firstPrompt,
                workspacePath: Self.text(statement, 3),
                rolloutPath: Self.text(statement, 4),
                updatedAt: updatedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }))
        }
        return threads
    }

    private static func columnNames(of table: String, in database: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = Self.text(statement, 1) {
                names.insert(name)
            }
        }
        return names
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func codexStateDatabaseURL() -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: self.codexHome.path) else {
            return nil
        }
        let newest = names.compactMap { name -> (version: Int, name: String)? in
            guard name.hasPrefix("state_"),
                  name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst("state_".count).dropLast(".sqlite".count))
            else {
                return nil
            }
            return (version, name)
        }.max { $0.version < $1.version }
        return newest.map { self.codexHome.appendingPathComponent($0.name, isDirectory: false) }
    }

    // MARK: Claude

    private struct ClaudeSessionRecord: Decodable {
        struct PendingStart: Decodable {
            let since: Int64?
        }

        let completedTurns: Int?
        let lastFocusedAt: Int64?
        let lastActivityAt: Int64?
        let lastTurnEdgeAt: Int64?
        let isArchived: Bool?
        let title: String?
        let cwd: String?
        let cliSessionId: String?
        let pendingFirstStart: PendingStart?
    }

    private var claudeLocalStorageDirectory: URL {
        self.claudeSupportDirectory
            .appendingPathComponent("Local Storage", isDirectory: true)
            .appendingPathComponent("leveldb", isDirectory: true)
    }

    /// Claude Desktop keeps its sidebar unread state in the claude.ai renderer's
    /// localStorage entry `epitaxy-unread-v1`. Chromium commits localStorage to disk
    /// in batches, so this set can trail the app by more than a minute.
    func claudeUnreadStore() -> Set<String> {
        let storageKey = Array("_https://claude.ai".utf8) + [0, 1] + Array("epitaxy-unread-v1".utf8)
        guard let raw = LevelDBSnapshotReader.latestValue(
            forKey: storageKey,
            in: self.claudeLocalStorageDirectory),
              let json = Self.chromiumLocalStorageString(raw),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let state = object["state"] as? [String: Any]
        else {
            return []
        }

        var sessionIDs = Set<String>()
        for field in ["unreadIds", "explicitUnreadIds"] {
            for case let id as String in state[field] as? [Any] ?? [] {
                sessionIDs.insert(id)
            }
        }
        return sessionIDs
    }

    /// When Chromium last committed localStorage. Each commit appends every
    /// change the renderer made so far to the LevelDB write-ahead log, while
    /// compactions only write tables, and claude.ai is the only origin there.
    func claudeStoreCommittedAt() -> Date {
        let logs = (try? FileManager.default.contentsOfDirectory(
            at: self.claudeLocalStorageDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return logs
            .filter { $0.pathExtension == "log" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? .distantPast
    }

    /// Claude Desktop logs the session its window shows, or `null` while it
    /// shows something else, such as a new session or Settings. The sidebar
    /// keeps a session read when a turn finishes there.
    func claudeShownSession() -> ClaudeShownSession {
        let marker = Data("LocalSessions.setFocusedSession: sessionId=".utf8)
        guard let handle = try? FileHandle(forReadingFrom: self.claudeMainLog) else { return .unknown }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return .unknown }
        let tailLength: UInt64 = 256 << 10
        guard (try? handle.seek(toOffset: end > tailLength ? end - tailLength : 0)) != nil,
              let tail = try? handle.readToEnd(),
              let range = tail.range(of: marker, options: .backwards)
        else {
            return .unknown
        }
        let value = tail[range.upperBound...].prefix { byte in
            byte != 0x0A && byte != 0x0D && byte != 0x20 && byte != 0x2C
        }
        guard let id = String(data: Data(value), encoding: .utf8), !id.isEmpty else { return .unknown }
        return id == "null" ? .none : .session(id)
    }

    /// The sessions Claude Desktop's window showed, oldest first, from the end
    /// of its log, which notes each change to the second.
    func claudeFocusChanges() -> [ClaudeFocusChange]? {
        let marker = Data("LocalSessions.setFocusedSession: sessionId=".utf8)
        guard let handle = try? FileHandle(forReadingFrom: self.claudeMainLog) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let tailLength: UInt64 = 256 << 10
        guard (try? handle.seek(toOffset: end > tailLength ? end - tailLength : 0)) != nil,
              let tail = try? handle.readToEnd()
        else {
            return nil
        }
        return tail.split(separator: 0x0A).compactMap { line -> ClaudeFocusChange? in
            guard let range = line.range(of: marker),
                  let at = Self.claudeLogDate(line.prefix(19))
            else {
                return nil
            }
            let value = line[range.upperBound...].prefix { byte in
                byte != 0x0D && byte != 0x20 && byte != 0x2C
            }
            guard let id = String(data: Data(value), encoding: .utf8), !id.isEmpty else { return nil }
            return ClaudeFocusChange(sessionID: id == "null" ? nil : id, at: at)
        }
    }

    /// `yyyy-MM-dd HH:mm:ss` in local time.
    private static func claudeLogDate(_ text: Data.SubSequence) -> Date? {
        let fields = String(decoding: text, as: UTF8.self)
            .split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" })
            .compactMap { Int($0) }
        guard fields.count == 6 else { return nil }
        return Calendar.current.date(from: DateComponents(
            year: fields[0], month: fields[1], day: fields[2],
            hour: fields[3], minute: fields[4], second: fields[5]))
    }

    /// The running Claude Desktop's process and when it launched.
    struct ClaudeLaunch: Equatable, Sendable {
        let pid: pid_t
        let startedAt: Date
    }

    /// The running Claude Desktop. The tasks its sessions run in the background
    /// end when it quits. Checking the known process is one lookup, while
    /// finding a new one goes through every process.
    func claudeLaunch(reusing known: ClaudeLaunch?) -> ClaudeLaunch? {
        if let known, Self.processStartedAt(known.pid) == known.startedAt {
            return known
        }
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        // Leave room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == "Claude",
                  proc_pidpath(process.kp_proc.p_pid, &path, UInt32(path.count)) > 0,
                  String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                      .hasSuffix(".app/Contents/MacOS/Claude")
            else {
                continue
            }
            return ClaudeLaunch(pid: process.kp_proc.p_pid, startedAt: Self.startedAt(process))
        }
        return nil
    }

    private static func processStartedAt(_ pid: pid_t) -> Date? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &process, &size, nil, 0) == 0, size > 0 else { return nil }
        return self.startedAt(process)
    }

    private static func startedAt(_ process: kinfo_proc) -> Date {
        let started = process.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }

    /// Chromium prefixes localStorage values with 0 for UTF-16LE or 1 for Latin-1.
    private static func chromiumLocalStorageString(_ raw: [UInt8]) -> String? {
        guard let format = raw.first else { return nil }
        let payload = Data(raw.dropFirst())
        switch format {
        case 0:
            return String(data: payload, encoding: .utf16LittleEndian)
        case 1:
            return String(data: payload, encoding: .isoLatin1)
        default:
            return nil
        }
    }

    /// Claude Desktop rewrites a session record as soon as a turn finishes or the
    /// session is shown. Only records whose modification date changed are decoded.
    func claudeSessions(
        reusing known: [String: ClaudeSessionSnapshot]) -> [String: ClaudeSessionSnapshot]
    {
        let root = self.claudeSupportDirectory
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
        var sessions: [String: ClaudeSessionSnapshot] = [:]
        for directory in Self.subdirectories(of: root).flatMap({ Self.subdirectories(of: $0) }) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                guard let modifiedAt = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate
                else {
                    continue
                }
                if let existing = sessions[id], existing.modifiedAt >= modifiedAt {
                    continue
                }
                if let cached = known[id], cached.modifiedAt == modifiedAt {
                    sessions[id] = cached
                } else if let data = try? Data(contentsOf: file),
                          let record = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data)
                {
                    sessions[id] = ClaudeSessionSnapshot(
                        completedTurns: record.completedTurns ?? 0,
                        lastFocusedAt: record.lastFocusedAt ?? 0,
                        isArchived: record.isArchived == true,
                        modifiedAt: modifiedAt,
                        title: record.title.flatMap(DesktopUnreadTurnReader.flattened),
                        workspacePath: record.cwd,
                        cliSessionID: record.cliSessionId,
                        lastActivityAt: record.lastActivityAt.map {
                            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
                        },
                        lastTurnEdgeAt: record.lastTurnEdgeAt.map {
                            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
                        },
                        startingSince: record.pendingFirstStart.map {
                            $0.since.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? modifiedAt
                        })
                }
            }
        }
        return sessions
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

}

enum ClaudeShownSession: Equatable, Sendable {
    case unknown
    case none
    case session(String)
}

/// Claude Desktop's window started showing a session, or `nil` for anything else.
struct ClaudeFocusChange: Equatable, Sendable {
    let sessionID: String?
    let at: Date
}

struct ClaudeSessionSnapshot: Equatable, Sendable {
    let completedTurns: Int
    let lastFocusedAt: Int64
    let isArchived: Bool
    let modifiedAt: Date
    let title: String?
    let workspacePath: String?
    let cliSessionID: String?
    let lastActivityAt: Date?
    /// When the session last started or finished a turn.
    let lastTurnEdgeAt: Date?
    /// Claude is still setting up a new session, such as creating its
    /// worktree, and has not started its first turn or written a transcript.
    var startingSince: Date? = nil
}

/// Combines Claude's lagging unread store with the session records the app writes
/// immediately. Like the Claude sidebar, a finished turn in a session other than
/// the one the window shows counts as unread, and showing a session counts as
/// read. Each guess lasts until the store agrees, Chromium commits the store after
/// the event, or it expires.
struct ClaudeUnreadTracker {
    struct Override: Codable, Equatable {
        var isUnread: Bool
        var since: Date
        /// For a turn the transcript shows ended: the turns Claude had recorded
        /// then. Claude records the turn and updates its store only after the
        /// session's stop hooks run, so until then the store cannot overrule it.
        var recordedTurns: Int?
        /// The turn ended in the session Claude's window showed while another
        /// app was in front. Claude counts that as read, so the session stays
        /// unread until Claude comes to the front on it or the user opens it.
        var untilSeen: Bool?
    }

    /// The parts of a session record whose changes are read or unread events.
    struct Progress: Codable, Equatable {
        var completedTurns: Int
        var lastFocusedAt: Int64
    }

    /// Kept across launches, so a guess the store has not caught up with and a
    /// turn that finished while TokenBar was not running still count.
    struct State: Codable, Equatable {
        var progress: [String: Progress] = [:]
        var overrides: [String: Override] = [:]
    }

    /// A commit this long after an event already includes it.
    static let storeCommitMargin: TimeInterval = 2
    /// Chromium can hold localStorage commits back for over a minute; this only
    /// bounds a guess the store never confirms or replaces.
    static let overrideLifetime: TimeInterval = 600

    private(set) var sessions: [String: ClaudeSessionSnapshot] = [:]
    private(set) var state: State
    private var hasBaseline: Bool
    /// Sessions whose turn waits for the user. Claude neither records such a
    /// turn nor marks the session unread, so a guess about one holds while it
    /// waits.
    private var waiting: Set<String> = []

    init(restoring state: State? = nil) {
        self.state = state ?? State()
        self.hasBaseline = state != nil
    }

    var nextExpiry: Date? {
        self.state.overrides
            .filter { !self.waiting.contains($0.key) && $0.value.untilSeen != true }
            .values.map { $0.since.addingTimeInterval(Self.overrideLifetime) }.min()
    }

    /// Returns the IDs of the sessions the sidebar shows as unread.
    /// `finishedTurns` are sessions whose transcript just finished a turn,
    /// which Claude records only after the session's stop hooks run, or paused
    /// it to wait for the user, which `waiting` lists. `isClaudeActive` tells
    /// whether Claude is the app in front.
    mutating func update(
        store: Set<String>,
        storeCommittedAt: Date,
        sessions: [String: ClaudeSessionSnapshot],
        finishedTurns: Set<String> = [],
        waiting: Set<String> = [],
        isClaudeActive: Bool = true,
        shownSession: () -> ClaudeShownSession,
        now: Date) -> Set<String>
    {
        if self.hasBaseline {
            // A session first found waiting, as at launch, just paused its turn.
            self.recordEvents(
                in: sessions,
                finishedTurns: finishedTurns.union(waiting.subtracting(self.waiting)),
                isClaudeActive: isClaudeActive,
                shownSession: shownSession,
                now: now)
        }
        if isClaudeActive,
           self.state.overrides.values.contains(where: { $0.untilSeen == true }),
           case let .session(id) = shownSession(),
           self.state.overrides[id]?.untilSeen == true
        {
            self.state.overrides[id] = Override(isUnread: false, since: now)
        }
        self.sessions = sessions
        self.state.progress = sessions.mapValues {
            Progress(completedTurns: $0.completedTurns, lastFocusedAt: $0.lastFocusedAt)
        }
        self.hasBaseline = true
        self.waiting = waiting

        let overrides = self.state.overrides.filter { id, override in
            if override.untilSeen == true {
                return sessions[id] != nil
            }
            guard override.isUnread != store.contains(id) else { return false }
            if waiting.contains(id) {
                return true
            }
            guard now < override.since.addingTimeInterval(Self.overrideLifetime) else { return false }
            if let recordedTurns = override.recordedTurns,
               (sessions[id]?.completedTurns ?? .max) <= recordedTurns
            {
                return true
            }
            return storeCommittedAt <= override.since.addingTimeInterval(Self.storeCommitMargin)
        }
        self.state.overrides = overrides
        return store.union(overrides.keys).filter { id in
            guard let session = sessions[id], !session.isArchived else { return false }
            return overrides[id]?.isUnread ?? store.contains(id)
        }
    }

    private mutating func recordEvents(
        in sessions: [String: ClaudeSessionSnapshot],
        finishedTurns: Set<String>,
        isClaudeActive: Bool,
        shownSession: () -> ClaudeShownSession,
        now: Date)
    {
        let completedTurn = sessions.contains { id, session in
            session.completedTurns > (self.state.progress[id]?.completedTurns ?? .max)
        }
        // Without Claude's log, assume the window still shows the session
        // shown last.
        let shownID: String? = switch completedTurn || !finishedTurns.isEmpty ? shownSession() : .unknown {
        case let .session(id): id
        case .none: nil
        case .unknown:
            sessions
                .filter { !$0.value.isArchived }
                .max { $0.value.lastFocusedAt < $1.value.lastFocusedAt }?
                .key
        }
        for (id, session) in sessions {
            guard let previous = self.state.progress[id] else { continue }
            if session.lastFocusedAt > previous.lastFocusedAt {
                self.state.overrides[id] = Override(
                    isUnread: false,
                    since: Date(timeIntervalSince1970: TimeInterval(session.lastFocusedAt) / 1000))
            }
            let isUnseen = id == shownID && !isClaudeActive
            if session.completedTurns > previous.completedTurns {
                self.state.overrides[id] = Override(
                    isUnread: id != shownID || isUnseen,
                    since: session.modifiedAt,
                    untilSeen: isUnseen ? true : nil)
            } else if finishedTurns.contains(id) {
                self.state.overrides[id] = Override(
                    isUnread: id != shownID || isUnseen,
                    since: now,
                    recordedTurns: session.completedTurns,
                    untilSeen: isUnseen ? true : nil)
            }
        }
    }
}

/// Watches the Codex home and Claude support directories and recounts the
/// platform whose unread source changed. All mutable state stays on `queue`.
final class DesktopUnreadTaskWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TokenBar.DesktopUnreadTasks", qos: .utility)
    private let reader: DesktopUnreadTaskReader
    /// Running tasks are also rechecked on this interval, which catches an app
    /// that quit mid-turn and never wrote the turn's end.
    private static let runningRefreshInterval: TimeInterval = 60
    /// A turn appends to its rollout or transcript many times a second.
    private static let appendCoalescingDelay: TimeInterval = 0.3

    /// Publishes the unread tasks, and the sessions that still exist
    /// unarchived when the platform tells.
    private let publish: @Sendable (TokenPlatform, [DesktopUnreadTask], Set<String>?) -> Void
    private let publishRunning: @Sendable (TokenPlatform, [DesktopRunningTask]) -> Void
    private let claudeTrackerStateURL: URL?
    private let turns = DesktopUnreadTurnReader()
    private let codexTurnStates = CodexTurnStateReader()
    private let claudeBackgroundTasks = ClaudeBackgroundTaskReader()
    private let claudeActivities = ClaudeActivityReader()
    private var stream: FSEventStreamRef?
    private var codexPaths: Set<String> = []
    private var codexSessionsPrefix: String?
    private var backgroundTasksPrefix: String?
    private var claudePrefixes: [String] = []
    private var claudeTracker = ClaudeUnreadTracker()
    private var savedClaudeTrackerState: ClaudeUnreadTracker.State?
    private var claudeRecountScheduledAt: Date?
    private var claudeRereadScheduled = false
    private var codexRunningIDs: Set<String> = []
    private var claudeRunningIDs: Set<String> = []
    private var claudeWaitingIDs: Set<String> = []
    private var claudeBackgroundIDs: Set<String> = []
    private var isClaudeActive = true
    private var claudeLaunch: DesktopUnreadTaskReader.ClaudeLaunch?
    private lazy var codexRollouts = AppendedFileWatcher(queue: self.queue) { [weak self] in
        self?.scheduleAppendRecount(of: .codex)
    }
    private lazy var claudeTranscripts = AppendedFileWatcher(queue: self.queue) { [weak self] in
        self?.scheduleAppendRecount(of: .claude)
    }
    private var appendRecountsScheduled: Set<TokenPlatform> = []
    private var isStopped = false

    init(
        reader: DesktopUnreadTaskReader,
        claudeTrackerStateURL: URL?,
        publish: @escaping @Sendable (TokenPlatform, [DesktopUnreadTask], Set<String>?) -> Void,
        publishRunning: @escaping @Sendable (TokenPlatform, [DesktopRunningTask]) -> Void)
    {
        self.reader = reader
        self.claudeTrackerStateURL = claudeTrackerStateURL
        self.publish = publish
        self.publishRunning = publishRunning
    }

    func start() {
        self.queue.async {
            self.restoreClaudeTracker()
            self.startStream()
            self.recount(DesktopUnreadTaskReader.platforms)
            self.recountCodexRunning()
            self.scheduleRunningRefresh()
        }
    }

    func stop() {
        self.queue.sync {
            self.isStopped = true
            self.codexRollouts.watch([])
            self.claudeTranscripts.watch([])
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func refresh() {
        self.queue.async {
            self.recount(DesktopUnreadTaskReader.platforms)
        }
    }

    /// Claude coming to the front shows the user the session in its window.
    func setClaudeActive(_ isActive: Bool) {
        self.queue.async {
            guard isActive != self.isClaudeActive else { return }
            self.isClaudeActive = isActive
            if isActive, !self.isStopped {
                self.recount([.claude])
            }
        }
    }

    private func startStream() {
        guard self.stream == nil else { return }
        var roots: [String] = []
        do {
            try FileManager.default.createDirectory(
                at: self.reader.backgroundTasksDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if let root = Self.canonicalPath(self.reader.backgroundTasksDirectory) {
                roots.append(root)
                self.backgroundTasksPrefix = root + "/"
            }
        } catch {
            NSLog("TokenBar could not watch background task snapshots: %@", String(describing: error))
        }
        if let codexRoot = Self.canonicalPath(self.reader.codexHome) {
            roots.append(codexRoot)
            self.codexPaths = [
                codexRoot + "/.codex-global-state.json",
                codexRoot + "/auth.json",
            ]
            self.codexSessionsPrefix = codexRoot + "/sessions/"
        }
        if let claudeRoot = Self.canonicalPath(self.reader.claudeSupportDirectory) {
            roots.append(claudeRoot)
            self.claudePrefixes = [
                claudeRoot + "/Local Storage/leveldb/",
                claudeRoot + "/claude-code-sessions/",
            ]
        }
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<DesktopUnreadTaskWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<DesktopUnreadTaskWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DesktopUnreadTaskWatcher>.fromOpaque(info).takeUnretainedValue()
            let changedPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(changedPaths, flags: UnsafeBufferPointer(start: flags, count: count))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, self.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func handle(_ paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped)
        var changed = Set<TokenPlatform>()
        var codexRolloutChanged = false
        for (index, path) in paths.enumerated() {
            if index < flags.count, flags[index] & rescanFlags != 0 {
                changed.formUnion(DesktopUnreadTaskReader.platforms)
                codexRolloutChanged = true
                break
            }
            if self.codexPaths.contains(path) {
                changed.insert(.codex)
            } else if let prefix = self.codexSessionsPrefix, path.hasPrefix(prefix) {
                codexRolloutChanged = true
            } else if let prefix = self.backgroundTasksPrefix,
                      path.hasPrefix(prefix) || path == String(prefix.dropLast())
            {
                codexRolloutChanged = true
            } else if self.claudePrefixes.contains(where: { path.hasPrefix($0) }) {
                changed.insert(.claude)
            }
        }
        self.recount(DesktopUnreadTaskReader.platforms.filter { changed.contains($0) })
        // Codex marks a thread unread as its turn ends, and a new thread
        // creates its rollout before the vnode watch covers it.
        if changed.contains(.codex) || codexRolloutChanged {
            self.recountCodexRunning()
        }
        if changed.contains(.claude) {
            self.scheduleClaudeReread()
        }
    }

    /// A read can land while Chromium is still writing a LevelDB record and
    /// see the previous value, and the next write may be a minute away.
    private func scheduleClaudeReread() {
        guard !self.claudeRereadScheduled else { return }
        self.claudeRereadScheduled = true
        self.queue.asyncAfter(deadline: .now() + 2) {
            self.claudeRereadScheduled = false
            self.recount([.claude])
        }
    }

    private func scheduleAppendRecount(of platform: TokenPlatform) {
        guard self.appendRecountsScheduled.insert(platform).inserted else { return }
        self.queue.asyncAfter(deadline: .now() + Self.appendCoalescingDelay) {
            self.appendRecountsScheduled.remove(platform)
            switch platform {
            case .codex:
                self.recountCodexRunning()
            case .claude:
                self.recountClaudeRunning()
            default:
                break
            }
        }
    }

    private func recount(_ platforms: [TokenPlatform]) {
        guard !self.isStopped else { return }
        for platform in platforms {
            switch platform {
            case .codex:
                self.publish(.codex, self.reader.codexUnreadTasks(turns: self.turns), nil)
            case .claude:
                self.recountClaude(sessions: self.reader.claudeSessions(reusing: self.claudeTracker.sessions))
            default:
                continue
            }
        }
    }

    /// A finished turn is when Codex notifies and marks the thread unread, so
    /// the unread state is read then and once more after Codex writes it.
    private func recountCodexRunning() {
        guard !self.isStopped else { return }
        let (running, rollouts) = self.reader.codexRunningTasks(states: self.codexTurnStates, now: Date())
        self.codexRollouts.watch(rollouts)
        let runningIDs = Set(running.map(\.id))
        let finishedTurn = !self.codexRunningIDs.subtracting(runningIDs).isEmpty
        self.codexRunningIDs = runningIDs
        self.publishRunning(.codex, running)
        guard finishedTurn else { return }
        self.recount([.codex])
        self.queue.asyncAfter(deadline: .now() + 1.5) {
            self.recount([.codex])
        }
    }

    private func recountClaude(sessions: [String: ClaudeSessionSnapshot]) {
        let now = Date()
        let (running, waiting, transcripts) = self.claudeRunningTasks(sessions, now: now)
        let ids = self.claudeTracker.update(
            store: self.reader.claudeUnreadStore(),
            storeCommittedAt: self.reader.claudeStoreCommittedAt(),
            sessions: sessions,
            finishedTurns: self.claudeFinishedTurns(running: running, transcripts: transcripts),
            waiting: waiting,
            isClaudeActive: self.isClaudeActive,
            shownSession: self.reader.claudeShownSession,
            now: now)
        self.claudeTranscripts.watch(Set(transcripts.values.map(\.path)))
        self.claudeBackgroundTasks.forget(except: Set(transcripts.values.map(\.path)))
        self.claudeActivities.forget(except: Set(transcripts.values.map(\.path)))
        self.claudeRunningIDs = Set(running.map(\.id))
        self.claudeBackgroundIDs = Set(running.filter(\.isInBackground).map(\.id))
        self.claudeWaitingIDs = waiting
        self.publish(
            .claude,
            self.claudeTasks(ids, sessions: sessions),
            Set(sessions.filter { !$0.value.isArchived }.keys))
        self.publishRunning(.claude, running)
        self.saveClaudeTracker()
        self.scheduleClaudeExpiryRecount()
    }

    /// Transcripts change throughout a turn, so they are read against the
    /// session records already loaded, and the unread state is recounted only
    /// when a turn ends or starts or stops waiting for the user.
    private func recountClaudeRunning() {
        guard !self.isStopped else { return }
        let sessions = self.claudeTracker.sessions
        let (running, waiting, transcripts) = self.claudeRunningTasks(sessions, now: Date())
        guard self.claudeFinishedTurns(running: running, transcripts: transcripts).isEmpty,
              waiting == self.claudeWaitingIDs
        else {
            self.recountClaude(sessions: sessions)
            return
        }
        self.claudeRunningIDs = Set(running.map(\.id))
        self.claudeBackgroundIDs = Set(running.filter(\.isInBackground).map(\.id))
        self.publishRunning(.claude, running)
    }

    /// Sessions that were running and whose transcript now ends their turn or
    /// waits for the user, unlike one that went quiet or was archived.
    private func claudeFinishedTurns(
        running: [DesktopRunningTask],
        transcripts: [String: URL]) -> Set<String>
    {
        self.claudeRunningIDs
            .subtracting(running.map(\.id))
            .filter { transcripts[$0] != nil }
    }

    private func scheduleRunningRefresh() {
        self.queue.asyncAfter(deadline: .now() + Self.runningRefreshInterval) {
            guard !self.isStopped else { return }
            self.recountCodexRunning()
            self.recountClaudeRunning()
            self.scheduleRunningRefresh()
        }
    }

    /// Claude Desktop records only when a session last started or finished a
    /// turn, so its transcript tells which one it was. A turn longer than the
    /// candidate window is still caught while its transcript keeps growing.
    /// A session whose turn ended runs while tasks it started in the
    /// background do. Also returns the sessions whose turn waits for the user;
    /// both are followed however long they wait. And returns the transcripts
    /// of recently active sessions, which a turn that starts or ends there
    /// writes to.
    private func claudeRunningTasks(
        _ sessions: [String: ClaudeSessionSnapshot],
        now: Date) -> (tasks: [DesktopRunningTask], waiting: Set<String>, transcripts: [String: URL])
    {
        var waiting = Set<String>()
        var transcripts: [String: URL] = [:]
        lazy var claudeLaunchedAt: Date? = {
            self.claudeLaunch = self.reader.claudeLaunch(reusing: self.claudeLaunch)
            return self.claudeLaunch?.startedAt
        }()
        let tasks = sessions.compactMap { id, session -> DesktopRunningTask? in
            // A new session runs while Claude sets it up, which can take
            // minutes for the worktree of a large repository.
            if let startingSince = session.startingSince {
                guard !session.isArchived, claudeLaunchedAt != nil else { return nil }
                return DesktopRunningTask(
                    platform: .claude,
                    id: id,
                    title: session.title,
                    startedAt: startingSince,
                    activity: "Starting")
            }
            guard !session.isArchived,
                  let edge = session.lastTurnEdgeAt ?? session.lastActivityAt,
                  now.timeIntervalSince(edge) < 6 * 60 * 60,
                  let transcript = session.cliSessionID.flatMap({
                      self.turns.claudeTranscriptURL(
                          cliSessionID: $0,
                          workspacePath: session.workspacePath,
                          activeAt: session.lastActivityAt,
                          projectsDirectory: self.reader.claudeProjectsDirectory)
                  }),
                  // The transcript URL is cached, and a URL caches its resource
                  // values, so its size and modification date come from the
                  // file system.
                  let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let activeAt = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(activeAt) < DesktopRunningTaskLiveness.quietLimit
                      || self.claudeWaitingIDs.contains(id)
                      || self.claudeBackgroundIDs.contains(id)
            else {
                return nil
            }
            transcripts[id] = transcript
            switch self.turns.claudeTurnState(transcript: transcript, size: size, modifiedAt: activeAt) {
            case .running:
                return DesktopRunningTask(
                    platform: .claude,
                    id: id,
                    title: session.title,
                    startedAt: session.lastTurnEdgeAt,
                    activity: self.claudeActivities.activity(in: transcript, size: size))
            case .waitingForUser:
                waiting.insert(id)
                return nil
            case .ended:
                guard let claudeLaunchedAt,
                      let background = self.claudeBackgroundTasks.runningTasks(
                          in: transcript,
                          size: size,
                          after: claudeLaunchedAt)
                else {
                    return nil
                }
                return DesktopRunningTask(
                    platform: .claude,
                    id: id,
                    title: session.title,
                    startedAt: background.startedAt,
                    activity: background.activity,
                    isInBackground: true)
            }
        }.sorted {
            ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id)
        }
        return (tasks, waiting, transcripts)
    }

    private func claudeTasks(
        _ ids: Set<String>,
        sessions: [String: ClaudeSessionSnapshot]) -> [DesktopUnreadTask]
    {
        ids.compactMap { id -> DesktopUnreadTask? in
            guard let session = sessions[id] else { return nil }
            let turn = session.cliSessionID.map {
                self.turns.claudeTurn(
                    cliSessionID: $0,
                    workspacePath: session.workspacePath,
                    activeAt: session.lastActivityAt,
                    projectsDirectory: self.reader.claudeProjectsDirectory)
            }
            return DesktopUnreadTask(
                platform: .claude,
                id: id,
                title: session.title,
                prompt: turn?.prompt,
                reply: turn?.reply,
                turnDuration: turn?.duration,
                workspacePath: session.workspacePath,
                updatedAt: session.lastActivityAt ?? session.modifiedAt)
        }.sorted {
            ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id)
        }
    }

    private func scheduleClaudeExpiryRecount() {
        guard let expiry = self.claudeTracker.nextExpiry,
              self.claudeRecountScheduledAt.map({ expiry < $0 }) ?? true
        else {
            return
        }
        self.claudeRecountScheduledAt = expiry
        self.queue.asyncAfter(deadline: .now() + max(0, expiry.timeIntervalSinceNow) + 0.1) {
            self.claudeRecountScheduledAt = nil
            self.recount([.claude])
        }
    }

    private func restoreClaudeTracker() {
        guard let url = self.claudeTrackerStateURL,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ClaudeUnreadTracker.State.self, from: data)
        else {
            return
        }
        self.claudeTracker = ClaudeUnreadTracker(restoring: state)
        self.savedClaudeTrackerState = state
    }

    private func saveClaudeTracker() {
        guard let url = self.claudeTrackerStateURL,
              self.claudeTracker.state != self.savedClaudeTrackerState
        else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(self.claudeTracker.state).write(to: url, options: [.atomic])
            self.savedClaudeTrackerState = self.claudeTracker.state
        } catch {
            NSLog("TokenBar could not save the Claude unread state: %@", String(describing: error))
        }
    }

    private static func canonicalPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Watches files that an app appends to while keeping them open, such as Codex
/// rollouts. FSEvents reports those writes only once the file is closed, while a
/// vnode source sees each one.
final class AppendedFileWatcher {
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]

    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    /// Watches exactly `paths`. Call on `queue`.
    func watch(_ paths: Set<String>) {
        for (path, source) in self.sources where !paths.contains(path) {
            source.cancel()
            self.sources[path] = nil
        }
        for path in paths where self.sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: self.queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                // A replaced file is watched again by path on the next call.
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    source.cancel()
                    self.sources[path] = nil
                }
                self.onChange()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            self.sources[path] = source
        }
    }
}
