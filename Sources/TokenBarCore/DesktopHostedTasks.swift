import Foundation
import SQLite3

/// Unread and running tasks of the two Tencent desktop hosts.
///
/// WorkBuddy keeps its own sidebar state in `~/.workbuddy/workbuddy.db`: it
/// sets `sessions.unread` when a turn finishes while the session is not in
/// front, and clears it when the user opens the session. A turn is running
/// while the session transcript has not yet ended with the assistant's reply.
///
/// With keeps history on its server. Locally its board table holds the unread
/// flag of the sessions it tracks, and the message index records whether the
/// latest turn of each session is still streaming. Prompts and replies come
/// from the message cache when the app still holds them.
struct DesktopHostedTaskReader: Sendable {
    let workBuddyHome: URL
    let withSupportDirectory: URL
    let openCodeDataDirectory: URL

    /// Unread sessions older than this are left to the app's own sidebar.
    static let unreadWindow: TimeInterval = 7 * 24 * 60 * 60
    /// The transcript tail read for a session's last turn.
    private static let tailBytes: UInt64 = 2 * 1024 * 1024

    init(environment: [String: String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.workBuddyHome = environment["WORKBUDDY_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".workbuddy", isDirectory: true)
        self.withSupportDirectory = environment["WITH_DATA_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/com.tencent.with", isDirectory: true)
        if let openCodeDir = environment["OPENCODE_DATA_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
            self.openCodeDataDirectory = URL(fileURLWithPath: openCodeDir, isDirectory: true)
        } else if let xdgDataHome = environment["XDG_DATA_HOME"].flatMap({ $0.isEmpty ? nil : $0 }) {
            self.openCodeDataDirectory = URL(fileURLWithPath: xdgDataHome, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        } else {
            self.openCodeDataDirectory = home
                .appendingPathComponent(".local/share/opencode", isDirectory: true)
        }
    }

    var workBuddyDatabase: URL {
        self.workBuddyHome.appendingPathComponent("workbuddy.db", isDirectory: false)
    }

    var withDatabase: URL {
        self.withSupportDirectory.appendingPathComponent("data.db", isDirectory: false)
    }

    var withMessageCache: URL {
        self.withSupportDirectory.appendingPathComponent("qa_detail.db", isDirectory: false)
    }

    var openCodeDatabase: URL {
        self.openCodeDataDirectory.appendingPathComponent("opencode.db", isDirectory: false)
    }

    // MARK: WorkBuddy

    struct WorkBuddySession: Equatable, Sendable {
        let id: String
        let title: String?
        let workspacePath: String?
        let unread: Bool
        let lastActivityAt: Date?
    }

    func workBuddySessions(now: Date) -> [WorkBuddySession] {
        guard let database = Self.open(self.workBuddyDatabase) else { return [] }
        defer { sqlite3_close(database) }
        let since = Int64((now.timeIntervalSince1970 - Self.unreadWindow) * 1000)
        let query = """
            SELECT id, coalesce(nullif(custom_title, ''), title), cwd, unread, last_activity_at
            FROM sessions
            WHERE ((transport = 'local' AND deleted_at IS NULL) OR (transport = 'cloud' AND deleted_at = -1))
              AND status != 'archived'
              AND coalesce(is_background_automation, 0) = 0
              AND coalesce(last_activity_at, updated_at) >= ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, since)
        var sessions: [WorkBuddySession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.text(statement, 0) else { continue }
            sessions.append(WorkBuddySession(
                id: id,
                title: Self.text(statement, 1),
                workspacePath: Self.text(statement, 2),
                unread: sqlite3_column_int(statement, 3) != 0,
                lastActivityAt: Self.millisecondsDate(sqlite3_column_int64(statement, 4))))
        }
        return sessions
    }

    /// Transcripts live in `projects/<project>/<session>.jsonl`; the project
    /// folder name is derived from the workspace but not reliably, so the
    /// session file is looked up by name.
    func workBuddyTranscripts() -> [String: URL] {
        let projects = self.workBuddyHome.appendingPathComponent("projects", isDirectory: true)
        let fileManager = FileManager.default
        var transcripts: [String: URL] = [:]
        for folder in (try? fileManager.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil)) ?? []
        {
            for file in (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension == "jsonl"
            {
                transcripts[file.deletingPathExtension().lastPathComponent] = file
            }
        }
        return transcripts
    }

    struct WorkBuddyTurn: Equatable, Sendable {
        let prompt: String?
        let reply: String?
        let startedAt: Date?
        let endedAt: Date?
        /// The turn has not yet ended with the assistant's reply.
        let isOpen: Bool
        let activity: String?
    }

    /// The session's last turn, read from the end of its transcript.
    func workBuddyLastTurn(transcript: URL) -> WorkBuddyTurn? {
        guard let lines = Self.tailLines(of: transcript, maxBytes: Self.tailBytes) else { return nil }
        var last: [String: Any]?
        var reply: String?
        var endedAt: Date?
        var prompt: String?
        var startedAt: Date?
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                continue
            }
            let type = row["type"] as? String
            if ["ai-title", "session-meta", "file-history-snapshot"].contains(type ?? "") {
                continue
            }
            if last == nil {
                last = row
            }
            let role = row["role"] as? String
            if type == "message", role == "assistant", reply == nil {
                reply = Self.contentText(row["content"])
                endedAt = Self.timestamp(row["timestamp"])
            }
            if type == "message", role == "user" {
                let provider = row["providerData"] as? [String: Any]
                if (provider?["startsNewUserRequest"] as? Bool) ?? true {
                    prompt = Self.userPrompt(row["content"])
                    startedAt = Self.timestamp(row["timestamp"])
                    break
                }
            }
        }
        guard let last else { return nil }
        let isOpen = !(last["type"] as? String == "message" && last["role"] as? String == "assistant")
        let activity: String? = switch last["type"] as? String {
        case "function_call": (last["name"] as? String).map { "Running \($0)" }
        case "function_call_result": "Thinking"
        case "reasoning": "Thinking"
        default: nil
        }
        return WorkBuddyTurn(
            prompt: prompt,
            reply: isOpen ? nil : reply,
            startedAt: startedAt,
            endedAt: isOpen ? nil : endedAt,
            isOpen: isOpen,
            activity: activity)
    }

    // MARK: With

    struct WithSession: Equatable, Sendable {
        let id: String
        let unread: Bool
        let isStreaming: Bool
        let latestMessageID: String?
        let requestedAt: Date?
        let lastActivityAt: Date?
    }

    func withSessions(now: Date) -> [WithSession] {
        guard let database = Self.open(self.withDatabase) else { return [] }
        defer { sqlite3_close(database) }
        // Each session's latest turn, joined with the board's unread flag.
        let query = """
            SELECT i.session_id, i.message_id, i.status, i.request_at,
                   coalesce(b.unread, 0), coalesce(b.updated_at, 0)
            FROM qa_session_message_index i
            LEFT JOIN board_session_state b ON b.session_id = i.session_id
            WHERE i.request_at = (
                SELECT max(request_at) FROM qa_session_message_index j WHERE j.session_id = i.session_id)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var sessions: [String: WithSession] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.text(statement, 0) else { continue }
            let requestedAt = Self.text(statement, 3).flatMap(Self.localDate)
            let boardUpdatedAt = Self.millisecondsDate(sqlite3_column_int64(statement, 5))
            let lastActivityAt = [requestedAt, boardUpdatedAt].compactMap(\.self).max()
            guard let lastActivityAt, now.timeIntervalSince(lastActivityAt) < Self.unreadWindow else { continue }
            sessions[id] = WithSession(
                id: id,
                unread: sqlite3_column_int(statement, 4) != 0,
                isStreaming: Self.text(statement, 2) == "streaming",
                latestMessageID: Self.text(statement, 1),
                requestedAt: requestedAt,
                lastActivityAt: lastActivityAt)
        }
        return Array(sessions.values)
    }

    struct WithTurn: Equatable, Sendable {
        let prompt: String?
        let reply: String?
        let duration: TimeInterval?
    }

    /// The cached prompt and reply of one turn, when With still holds it.
    func withTurn(messageID: String) -> WithTurn? {
        guard let database = Self.open(self.withMessageCache) else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT payload_json FROM qa_message_detail WHERE message_id = ?", -1, &statement, nil)
            == SQLITE_OK
        else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, messageID, -1, Self.sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let payload = Self.text(statement, 0)?.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else {
            return nil
        }
        let reply = (json["response"] as? String).map { stream in
            stream.components(separatedBy: "\n\n").compactMap { chunk -> String? in
                guard let data = chunk.data(using: .utf8),
                      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      event["type"] as? String == "TEXT_MESSAGE_CONTENT"
                else {
                    return nil
                }
                return ((event["rawEvent"] as? [String: Any])?["content"] as? String) ?? event["delta"] as? String
            }.joined()
        }
        let duration = (json["cost_time"] as? NSNumber).map { $0.doubleValue / 1000 }.flatMap { $0 > 0 ? $0 : nil }
        return WithTurn(
            prompt: Self.nonEmpty(json["request"] as? String),
            reply: Self.nonEmpty(reply),
            duration: duration)
    }

    // MARK: OpenCode

    struct OpenCodeSession: Equatable, Sendable {
        let id: String
        let title: String?
        let workspacePath: String?
        let isRunning: Bool
        let unread: Bool
        let busyAt: Date?
        let idleAt: Date?
        let updatedAt: Date?
    }

    struct OpenCodeTurn: Equatable, Sendable {
        let prompt: String?
        let reply: String?
        let activity: String?
        let askQuestion: String?
    }

    func openCodeSessions(now: Date) -> [OpenCodeSession] {
        guard let database = Self.open(self.openCodeDatabase) else { return [] }
        defer { sqlite3_close(database) }
        let since = Int64((now.timeIntervalSince1970 - Self.unreadWindow) * 1000)
        let query = """
            SELECT id, title, directory, time_busy, time_idle, time_viewed, time_updated
            FROM session_v2
            WHERE parent_id IS NULL
              AND time_archived IS NULL
              AND time_updated >= ?
            ORDER BY time_updated DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, since)
        var sessions: [OpenCodeSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.text(statement, 0) else { continue }
            let title = Self.text(statement, 1)
            let workspacePath = Self.text(statement, 2)
            let busyMs = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3)
            let idleMs = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4)
            let viewedMs = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 5)
            let updatedMs = sqlite3_column_int64(statement, 6)
            let isRunning = busyMs.map { busy in
                idleMs.map { busy > $0 } ?? true
            } ?? false
            let unread = !isRunning && idleMs.map { idle in
                viewedMs.map { $0 < idle } ?? true
            } ?? false
            sessions.append(OpenCodeSession(
                id: id,
                title: title,
                workspacePath: workspacePath,
                isRunning: isRunning,
                unread: unread,
                busyAt: busyMs.flatMap(Self.millisecondsDate),
                idleAt: idleMs.flatMap(Self.millisecondsDate),
                updatedAt: Self.millisecondsDate(updatedMs)))
        }
        return sessions
    }

    func openCodeLastTurn(sessionID: String) -> OpenCodeTurn? {
        guard let database = Self.open(self.openCodeDatabase) else { return nil }
        defer { sqlite3_close(database) }
        let query = """
            SELECT type, data
            FROM session_message
            WHERE session_id = ?
              AND type IN ('user', 'assistant')
            ORDER BY seq DESC
            LIMIT 40
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, Self.sqliteTransient)
        var rows: [(type: String, json: [String: Any])] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let type = Self.text(statement, 0),
                  let rawData = Self.text(statement, 1)?.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any]
            else {
                continue
            }
            rows.append((type: type, json: json))
        }
        guard !rows.isEmpty else { return nil }
        rows.reverse()

        let startIndex = rows.lastIndex(where: { $0.type == "user" }) ?? 0
        var prompt: String?
        var reply: String?
        var activity: String?
        var askQuestion: String?

        for row in rows[startIndex...] {
            if row.type == "user" {
                let metadata = row.json["metadata"] as? [String: Any]
                prompt = Self.nonEmpty(metadata?["displayText"] as? String)
                    ?? Self.nonEmpty(row.json["text"] as? String)
                reply = nil
                activity = nil
                askQuestion = nil
                continue
            }
            guard row.type == "assistant" else { continue }
            let parts = row.json["content"] as? [[String: Any]] ?? []
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    if let text = Self.nonEmpty(part["text"] as? String) {
                        reply = text
                    }
                    activity = "Replying"
                case "reasoning":
                    activity = "Thinking"
                case "tool":
                    let name = part["name"] as? String ?? "tool"
                    let state = part["state"] as? [String: Any]
                    let status = state?["status"] as? String
                    let isPending = status != "completed" && status != "error"
                    if name == "question", isPending {
                        let input = state?["input"] as? [String: Any]
                        let questions = input?["questions"] as? [[String: Any]]
                        let first = questions?.first
                        askQuestion = Self.nonEmpty(first?["question"] as? String)
                            ?? Self.nonEmpty(first?["header"] as? String)
                            ?? "Waiting for your answer"
                        activity = "Waiting for your answer"
                    } else if isPending {
                        activity = "Running \(name)"
                    }
                default:
                    break
                }
            }
        }
        return OpenCodeTurn(
            prompt: prompt,
            reply: reply,
            activity: activity,
            askQuestion: askQuestion)
    }

    // MARK: Helpers

    private static func open(_ url: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        sqlite3_busy_timeout(database, 1000)
        return database
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return Self.nonEmpty(String(cString: value))
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func millisecondsDate(_ value: Int64) -> Date? {
        value > 0 ? Date(timeIntervalSince1970: TimeInterval(value) / 1000) : nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        return Date(timeIntervalSince1970: raw < 10_000_000_000 ? raw : raw / 1000)
    }

    /// With writes `request_at` as local wall-clock time.
    private static func localDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func contentText(_ content: Any?) -> String? {
        if let text = content as? String {
            return Self.nonEmpty(text)
        }
        let parts = (content as? [[String: Any]] ?? []).compactMap { part -> String? in
            let type = part["type"] as? String
            guard type == nil || type == "output_text" || type == "text" else { return nil }
            return part["text"] as? String
        }
        return Self.nonEmpty(parts.joined())
    }

    /// The user's own words, without the `<system-reminder>` context blocks
    /// WorkBuddy prepends to each prompt.
    private static func userPrompt(_ content: Any?) -> String? {
        if let text = content as? String {
            return Self.nonEmpty(text)
        }
        let parts = (content as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<system-reminder") }
        return Self.nonEmpty(parts.joined(separator: "\n"))
    }

    private static func tailLines(of url: URL, maxBytes: UInt64) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        // The tail can start inside a multibyte character; that first line is dropped below.
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }
}
