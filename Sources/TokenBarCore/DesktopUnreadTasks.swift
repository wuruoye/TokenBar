import CoreServices
import CryptoKit
import Foundation
import Observation
import SQLite3

/// Tracks finished Codex and Claude desktop tasks that each app's sidebar still
/// marks as unread.
@MainActor
@Observable
public final class DesktopUnreadTaskMonitor {
    public private(set) var counts: [TokenPlatform: Int] = [:]

    @ObservationIgnored private let reader: DesktopUnreadTaskReader
    @ObservationIgnored private var watcher: DesktopUnreadTaskWatcher?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.reader = DesktopUnreadTaskReader(environment: environment)
    }

    public func count(for platform: TokenPlatform) -> Int {
        self.counts[platform] ?? 0
    }

    public func start() {
        guard self.watcher == nil else { return }
        let watcher = DesktopUnreadTaskWatcher(reader: self.reader) { [weak self] platform, count in
            Task { @MainActor [weak self] in
                self?.accept(count, for: platform)
            }
        }
        self.watcher = watcher
        watcher.start()
    }

    public func stop() {
        self.watcher?.stop()
        self.watcher = nil
        self.counts = [:]
    }

    public func refresh() {
        self.watcher?.refresh()
    }

    private func accept(_ count: Int, for platform: TokenPlatform) {
        guard self.watcher != nil, self.counts[platform] != count else { return }
        self.counts[platform] = count
    }
}

struct DesktopUnreadTaskReader: Sendable {
    static let platforms: [TokenPlatform] = [.codex, .claude]

    let codexHome: URL
    let claudeSupportDirectory: URL

    init(codexHome: URL, claudeSupportDirectory: URL) {
        self.codexHome = codexHome
        self.claudeSupportDirectory = claudeSupportDirectory
    }

    init(environment: [String: String]) {
        let fileManager = FileManager.default
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(
            codexHome: CodexAuthStore.codexHomeURL(environment: environment),
            claudeSupportDirectory: applicationSupport
                .appendingPathComponent("Claude", isDirectory: true))
    }

    // MARK: Codex

    /// Codex Desktop stores unread thread IDs per signed-in identity and execution
    /// host in `.codex-global-state.json`. The list also keeps subagent threads the
    /// sidebar never shows, so IDs are checked against the local thread database.
    func codexUnreadCount() -> Int {
        let stateURL = self.codexHome.appendingPathComponent(
            ".codex-global-state.json",
            isDirectory: false)
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let readState = object["electron-thread-read-state-v1"] as? [String: Any],
              let identities = readState["unreadByIdentity"] as? [String: Any]
        else {
            return 0
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
        guard !threadIDs.isEmpty else { return 0 }
        return self.visibleCodexThreadCount(threadIDs)
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

    private func visibleCodexThreadCount(_ ids: Set<String>) -> Int {
        guard let databaseURL = self.codexStateDatabaseURL() else { return 0 }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return 0
        }
        sqlite3_busy_timeout(database, 1000)

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT COUNT(*) FROM threads
            WHERE archived = 0
              AND COALESCE(source, '') NOT LIKE '{"subagent"%'
              AND id IN (\(placeholders))
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, Self.sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
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
        let isArchived: Bool?
    }

    /// Claude Desktop keeps its sidebar unread state in the claude.ai renderer's
    /// localStorage entry `epitaxy-unread-v1`. Chromium commits localStorage to disk
    /// in batches, so this set trails the app by tens of seconds.
    func claudeUnreadStore() -> Set<String> {
        let storageKey = Array("_https://claude.ai".utf8) + [0, 1] + Array("epitaxy-unread-v1".utf8)
        let storageDirectory = self.claudeSupportDirectory
            .appendingPathComponent("Local Storage", isDirectory: true)
            .appendingPathComponent("leveldb", isDirectory: true)
        guard let raw = LevelDBSnapshotReader.latestValue(forKey: storageKey, in: storageDirectory),
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
                        modifiedAt: modifiedAt)
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

struct ClaudeSessionSnapshot: Equatable, Sendable {
    let completedTurns: Int
    let lastFocusedAt: Int64
    let isArchived: Bool
    let modifiedAt: Date
}

/// Combines Claude's lagging unread store with the session records the app writes
/// immediately. Like the Claude sidebar, a finished turn in a session other than
/// the one most recently shown counts as unread, and showing a session counts as
/// read. Each guess lasts until the store agrees, a store change made after the
/// event replaces it, or it expires.
struct ClaudeUnreadTracker {
    private enum Override {
        case unread(since: Date)
        case read(since: Date)

        var since: Date {
            switch self {
            case let .unread(since), let .read(since):
                since
            }
        }

        var isUnread: Bool {
            if case .unread = self { true } else { false }
        }
    }

    /// A store change observed this long after an event already reflects it.
    static let storeCommitMargin: TimeInterval = 2
    /// Chromium normally commits localStorage well within this window.
    static let overrideLifetime: TimeInterval = 90

    private(set) var sessions: [String: ClaudeSessionSnapshot] = [:]
    private var store: Set<String> = []
    private var storeChangedAt = Date.distantPast
    private var overrides: [String: Override] = [:]
    private var hasBaseline = false

    var nextExpiry: Date? {
        self.overrides.values.map { $0.since.addingTimeInterval(Self.overrideLifetime) }.min()
    }

    mutating func update(
        store: Set<String>,
        sessions: [String: ClaudeSessionSnapshot],
        now: Date) -> Int
    {
        if !self.hasBaseline || store != self.store {
            self.store = store
            self.storeChangedAt = now
        }
        if self.hasBaseline {
            self.recordEvents(in: sessions)
        }
        self.sessions = sessions
        self.hasBaseline = true

        let storeChangedAt = self.storeChangedAt
        let overrides = self.overrides.filter { id, override in
            override.isUnread != store.contains(id)
                && storeChangedAt <= override.since.addingTimeInterval(Self.storeCommitMargin)
                && now < override.since.addingTimeInterval(Self.overrideLifetime)
        }
        self.overrides = overrides
        return store.union(overrides.keys).filter { id in
            guard let session = sessions[id], !session.isArchived else { return false }
            return overrides[id]?.isUnread ?? store.contains(id)
        }.count
    }

    private mutating func recordEvents(in sessions: [String: ClaudeSessionSnapshot]) {
        let shownID = sessions
            .filter { !$0.value.isArchived }
            .max { $0.value.lastFocusedAt < $1.value.lastFocusedAt }?
            .key
        for (id, session) in sessions {
            guard let previous = self.sessions[id] else { continue }
            if session.lastFocusedAt > previous.lastFocusedAt {
                self.overrides[id] = .read(
                    since: Date(timeIntervalSince1970: TimeInterval(session.lastFocusedAt) / 1000))
            }
            if session.completedTurns > previous.completedTurns {
                self.overrides[id] = id == shownID
                    ? .read(since: session.modifiedAt)
                    : .unread(since: session.modifiedAt)
            }
        }
    }
}

/// Watches the Codex home and Claude support directories and recounts the
/// platform whose unread source changed. All mutable state stays on `queue`.
final class DesktopUnreadTaskWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TokenBar.DesktopUnreadTasks", qos: .utility)
    private let reader: DesktopUnreadTaskReader
    private let publish: @Sendable (TokenPlatform, Int) -> Void
    private var stream: FSEventStreamRef?
    private var codexPaths: Set<String> = []
    private var claudePrefixes: [String] = []
    private var claudeTracker = ClaudeUnreadTracker()
    private var claudeRecountScheduledAt: Date?
    private var isStopped = false

    init(
        reader: DesktopUnreadTaskReader,
        publish: @escaping @Sendable (TokenPlatform, Int) -> Void)
    {
        self.reader = reader
        self.publish = publish
    }

    func start() {
        self.queue.async {
            self.startStream()
            self.recount(DesktopUnreadTaskReader.platforms)
        }
    }

    func stop() {
        self.queue.sync {
            self.isStopped = true
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
            1.0,
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
        for (index, path) in paths.enumerated() {
            if index < flags.count, flags[index] & rescanFlags != 0 {
                changed.formUnion(DesktopUnreadTaskReader.platforms)
                break
            }
            if self.codexPaths.contains(path) {
                changed.insert(.codex)
            } else if self.claudePrefixes.contains(where: { path.hasPrefix($0) }) {
                changed.insert(.claude)
            }
        }
        self.recount(DesktopUnreadTaskReader.platforms.filter { changed.contains($0) })
    }

    private func recount(_ platforms: [TokenPlatform]) {
        guard !self.isStopped else { return }
        for platform in platforms {
            switch platform {
            case .codex:
                self.publish(.codex, self.reader.codexUnreadCount())
            case .claude:
                let store = self.reader.claudeUnreadStore()
                let sessions = self.reader.claudeSessions(reusing: self.claudeTracker.sessions)
                let count = self.claudeTracker.update(store: store, sessions: sessions, now: Date())
                self.publish(.claude, count)
                self.scheduleClaudeExpiryRecount()
            default:
                continue
            }
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

    private static func canonicalPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
