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
@MainActor
@Observable
public final class DesktopUnreadTaskMonitor {
    /// Unread tasks per platform, most recently updated first.
    public private(set) var tasks: [TokenPlatform: [DesktopUnreadTask]] = [:]
    /// Tasks still running a turn per platform, most recently started first.
    public private(set) var running: [TokenPlatform: [DesktopRunningTask]] = [:]

    @ObservationIgnored private let reader: DesktopUnreadTaskReader
    @ObservationIgnored private var watcher: DesktopUnreadTaskWatcher?

    @ObservationIgnored private let claudeTrackerStateURL: URL?

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

    public func start() {
        guard self.watcher == nil else { return }
        let watcher = DesktopUnreadTaskWatcher(
            reader: self.reader,
            claudeTrackerStateURL: self.claudeTrackerStateURL,
            publish: { [weak self] platform, tasks in
                Task { @MainActor [weak self] in
                    self?.accept(tasks, for: platform)
                }
            },
            publishRunning: { [weak self] platform, tasks in
                Task { @MainActor [weak self] in
                    self?.acceptRunning(tasks, for: platform)
                }
            })
        self.watcher = watcher
        watcher.start()
    }

    public func stop() {
        self.watcher?.stop()
        self.watcher = nil
        self.tasks = [:]
        self.running = [:]
    }

    public func refresh() {
        self.watcher?.refresh()
    }

    private func accept(_ tasks: [DesktopUnreadTask], for platform: TokenPlatform) {
        guard self.watcher != nil, self.tasks[platform] != tasks else { return }
        self.tasks[platform] = tasks
    }

    private func acceptRunning(_ tasks: [DesktopRunningTask], for platform: TokenPlatform) {
        guard self.watcher != nil, self.running[platform] != tasks else { return }
        self.running[platform] = tasks
    }
}

struct DesktopUnreadTaskReader: Sendable {
    static let platforms: [TokenPlatform] = [.codex, .claude]

    let codexHome: URL
    let claudeSupportDirectory: URL
    let claudeProjectsDirectory: URL
    let claudeMainLog: URL

    init(codexHome: URL, claudeSupportDirectory: URL, claudeProjectsDirectory: URL, claudeMainLog: URL) {
        self.codexHome = codexHome
        self.claudeSupportDirectory = claudeSupportDirectory
        self.claudeProjectsDirectory = claudeProjectsDirectory
        self.claudeMainLog = claudeMainLog
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
                .appendingPathComponent("Library/Logs/Claude/main.log", isDirectory: false))
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
        let threads = self.visibleCodexThreads(.updatedSince(now.addingTimeInterval(-24 * 60 * 60)))
        let rollouts = Set(threads.compactMap(\.rolloutPath))
        states.forget(except: rollouts)
        let tasks = threads.compactMap { thread -> DesktopRunningTask? in
            guard let path = thread.rolloutPath,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modifiedAt) < DesktopRunningTaskLiveness.quietLimit
            else {
                return nil
            }
            let state = states.state(of: URL(fileURLWithPath: path), size: size)
            guard state.isRunning else { return nil }
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
        let completedTurns: Int?
        let lastFocusedAt: Int64?
        let lastActivityAt: Int64?
        let lastTurnEdgeAt: Int64?
        let isArchived: Bool?
        let title: String?
        let cwd: String?
        let cliSessionId: String?
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

    /// When the running Claude Desktop launched. The tasks its sessions run in
    /// the background end when it quits.
    func claudeLaunchedAt() -> Date? {
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
            let started = process.kp_proc.p_starttime
            return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
        }
        return nil
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
            .filter { !self.waiting.contains($0.key) }
            .values.map { $0.since.addingTimeInterval(Self.overrideLifetime) }.min()
    }

    /// Returns the IDs of the sessions the sidebar shows as unread.
    /// `finishedTurns` are sessions whose transcript just finished a turn,
    /// which Claude records only after the session's stop hooks run, or paused
    /// it to wait for the user, which `waiting` lists.
    mutating func update(
        store: Set<String>,
        storeCommittedAt: Date,
        sessions: [String: ClaudeSessionSnapshot],
        finishedTurns: Set<String> = [],
        waiting: Set<String> = [],
        shownSession: () -> ClaudeShownSession,
        now: Date) -> Set<String>
    {
        if self.hasBaseline {
            // A session first found waiting, as at launch, just paused its turn.
            self.recordEvents(
                in: sessions,
                finishedTurns: finishedTurns.union(waiting.subtracting(self.waiting)),
                shownSession: shownSession,
                now: now)
        }
        self.sessions = sessions
        self.state.progress = sessions.mapValues {
            Progress(completedTurns: $0.completedTurns, lastFocusedAt: $0.lastFocusedAt)
        }
        self.hasBaseline = true
        self.waiting = waiting

        let overrides = self.state.overrides.filter { id, override in
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
            if session.completedTurns > previous.completedTurns {
                self.state.overrides[id] = Override(isUnread: id != shownID, since: session.modifiedAt)
            } else if finishedTurns.contains(id) {
                self.state.overrides[id] = Override(
                    isUnread: id != shownID,
                    since: now,
                    recordedTurns: session.completedTurns)
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

    private let publish: @Sendable (TokenPlatform, [DesktopUnreadTask]) -> Void
    private let publishRunning: @Sendable (TokenPlatform, [DesktopRunningTask]) -> Void
    private let claudeTrackerStateURL: URL?
    private let turns = DesktopUnreadTurnReader()
    private let codexTurnStates = CodexTurnStateReader()
    private let claudeBackgroundTasks = ClaudeBackgroundTaskReader()
    private let claudeActivities = ClaudeActivityReader()
    private var stream: FSEventStreamRef?
    private var codexPaths: Set<String> = []
    private var codexSessionsPrefix: String?
    private var claudePrefixes: [String] = []
    private var claudeTracker = ClaudeUnreadTracker()
    private var savedClaudeTrackerState: ClaudeUnreadTracker.State?
    private var claudeRecountScheduledAt: Date?
    private var claudeRereadScheduled = false
    private var codexRunningIDs: Set<String> = []
    private var claudeRunningIDs: Set<String> = []
    private var claudeWaitingIDs: Set<String> = []
    private var claudeBackgroundIDs: Set<String> = []
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
        publish: @escaping @Sendable (TokenPlatform, [DesktopUnreadTask]) -> Void,
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

    private func startStream() {
        guard self.stream == nil else { return }
        var roots: [String] = []
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
                self.publish(.codex, self.reader.codexUnreadTasks(turns: self.turns))
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
            shownSession: self.reader.claudeShownSession,
            now: now)
        self.claudeTranscripts.watch(Set(transcripts.values.map(\.path)))
        self.claudeBackgroundTasks.forget(except: Set(transcripts.values.map(\.path)))
        self.claudeActivities.forget(except: Set(transcripts.values.map(\.path)))
        self.claudeRunningIDs = Set(running.map(\.id))
        self.claudeBackgroundIDs = Set(running.filter(\.isInBackground).map(\.id))
        self.claudeWaitingIDs = waiting
        self.publish(.claude, self.claudeTasks(ids, sessions: sessions))
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
        lazy var claudeLaunchedAt = self.reader.claudeLaunchedAt()
        let tasks = sessions.compactMap { id, session -> DesktopRunningTask? in
            guard !session.isArchived,
                  let edge = session.lastTurnEdgeAt ?? session.lastActivityAt,
                  now.timeIntervalSince(edge) < 6 * 60 * 60,
                  let transcript = session.cliSessionID.flatMap({
                      self.turns.claudeTranscriptURL(
                          cliSessionID: $0,
                          workspacePath: session.workspacePath,
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
            switch self.turns.claudeTurnState(transcript: transcript) {
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
