import Foundation

/// A Codex or Claude desktop task whose turn is still running, or whose
/// background tasks are.
public struct DesktopRunningTask: Equatable, Identifiable, Sendable {
    public let platform: TokenPlatform
    /// The Codex thread ID or Claude Desktop session ID that each app's deep
    /// link opens.
    public let id: String
    public let title: String?
    public let startedAt: Date?
    /// What the turn, or else its background tasks, is doing now.
    public let activity: String?
    /// The turn ended, and only tasks it started in the background still run.
    public let isInBackground: Bool

    public init(
        platform: TokenPlatform,
        id: String,
        title: String?,
        startedAt: Date?,
        activity: String? = nil,
        isInBackground: Bool = false)
    {
        self.platform = platform
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.activity = activity
        self.isInBackground = isInBackground
    }
}

/// Whether a running task's transcript has gone quiet for so long that its app
/// most likely quit mid-turn.
enum DesktopRunningTaskLiveness {
    static let quietLimit: TimeInterval = 30 * 60
}

/// Follows each Codex rollout's turn events and the progress notes a running
/// turn writes. A running rollout grows with every event, so after the first
/// read only appended lines are scanned. Confined to the unread watcher's queue.
final class CodexTurnStateReader {
    struct TurnState: Equatable {
        var isRunning = false
        var startedAt: Date?
        /// The turn's latest progress note.
        var activity: String?
    }

    private struct Progress {
        var offset: UInt64
        var state: TurnState
    }

    private enum Event {
        case started(at: Date?)
        case ended
        case note(String)
    }

    private static let markers = ["\"task_started\"", "\"task_complete\"", "\"turn_aborted\"", "\"commentary\""]
        .map { Data($0.utf8) }

    private var progress: [String: Progress] = [:]

    func state(of url: URL, size: UInt64) -> TurnState {
        if var known = self.progress[url.path], known.offset <= size {
            if known.offset < size {
                known = self.advance(known, in: url, to: size)
                self.progress[url.path] = known
            }
            return known.state
        }
        var state = TurnState()
        var note: String?
        DesktopUnreadTurnReader.scanBackward(in: url, markers: Self.markers) { line in
            switch Self.event(line) {
            case let .started(startedAt):
                state = TurnState(isRunning: true, startedAt: startedAt, activity: note)
                return true
            case .ended:
                return true
            case let .note(text):
                note = note ?? text
                return false
            case nil:
                return false
            }
        }
        self.progress[url.path] = Progress(offset: size, state: state)
        return state
    }

    func forget(except paths: Set<String>) {
        self.progress = self.progress.filter { paths.contains($0.key) }
    }

    private func advance(_ known: Progress, in url: URL, to size: UInt64) -> Progress {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return known }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: known.offset)) != nil,
              let appended = try? handle.read(upToCount: Int(size - known.offset)),
              let lastNewline = appended.lastIndex(of: 0x0A)
        else {
            return known
        }
        var next = known
        for line in appended[..<lastNewline].split(separator: 0x0A)
            where Self.markers.contains(where: { line.range(of: $0) != nil })
        {
            switch Self.event(Data(line)) {
            case let .started(startedAt):
                next.state = TurnState(isRunning: true, startedAt: startedAt)
            case .ended:
                next.state = TurnState()
            case let .note(text):
                next.state.activity = text
            case nil:
                break
            }
        }
        // A line still being written is read again once it ends.
        next.offset = known.offset + UInt64(appended.distance(from: appended.startIndex, to: lastNewline)) + 1
        return next
    }

    private static func event(_ line: Data) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any]
        else {
            return nil
        }
        switch payload["type"] as? String {
        case "task_started":
            let timestamp = (object["timestamp"] as? String).flatMap {
                try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            }
            return .started(at: timestamp)
        case "task_complete", "turn_aborted":
            return .ended
        case "item_completed":
            // Codex marks the messages it writes while working as commentary.
            guard let item = payload["item"] as? [String: Any],
                  item["type"] as? String == "AgentMessage",
                  item["phase"] as? String == "commentary"
            else {
                return nil
            }
            let text = (item["content"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? String)?.lowercased() == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            return DesktopUnreadTurnReader.replySummary(text).map { .note($0) }
        default:
            return nil
        }
    }
}

/// Follows the commands, monitors, and agents a Claude session runs in the
/// background, which keep working after its turn ends and report back when
/// they stop. A transcript only grows, so after the first read only appended
/// lines are scanned. Confined to the unread watcher's queue.
final class ClaudeBackgroundTaskReader {
    private struct Task {
        var startedAt: Date
        var activity: String?
    }

    private struct Progress {
        var offset: UInt64
        /// Each task without a report yet, by task ID.
        var pending: [String: Task] = [:]
        /// What the latest calls of tools that can run in the background
        /// said they do, by tool use ID. A call's result follows it closely.
        var calls: [(id: String, activity: String)] = []
    }

    private static let backgroundTools: Set<String> = ["Bash", "Agent", "Task", "Monitor"]
    private static let recentCallLimit = 32
    private static let callMarker = Data("\"type\":\"tool_use\"".utf8)
    private static let monitorMarker = Data("Monitor started (task ".utf8)
    private static let stopMarker = Data("Successfully stopped task".utf8)
    private static let reportMarker = Data("<task-id>".utf8)
    private static let requestMarker = Data("\"type\":\"api-request".utf8)
    private static let markers = [
        callMarker,
        Data("\"backgroundTaskId\"".utf8),
        Data("\"isAsync\":true".utf8),
        monitorMarker,
        stopMarker,
        reportMarker,
    ]
    /// Long sessions write megabytes of tool output.
    private static let maximumScannedBytes: UInt64 = 32 << 20

    private var progress: [String: Progress] = [:]

    /// When the earliest task still running started, and what the running
    /// tasks do, in the order they started. A task that started before
    /// `cutoff`, when Claude Desktop launched, ended with it.
    func runningTasks(in url: URL, size: UInt64, after cutoff: Date) -> (startedAt: Date, activity: String?)? {
        var known = self.progress[url.path].flatMap { $0.offset <= size ? $0 : nil }
            ?? Progress(offset: size > Self.maximumScannedBytes ? size - Self.maximumScannedBytes : 0)
        if known.offset < size {
            known = self.advance(known, in: url, to: size)
        }
        self.progress[url.path] = known
        let running = known.pending.values.filter { $0.startedAt > cutoff }.sorted { $0.startedAt < $1.startedAt }
        guard let first = running.first else { return nil }
        let activities = running.compactMap(\.activity)
        return (first.startedAt, activities.isEmpty ? nil : activities.joined(separator: " · "))
    }

    func forget(except paths: Set<String>) {
        self.progress = self.progress.filter { paths.contains($0.key) }
    }

    private func advance(_ known: Progress, in url: URL, to size: UInt64) -> Progress {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return known }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: known.offset)) != nil,
              let appended = try? handle.read(upToCount: Int(size - known.offset)),
              let lastNewline = appended.lastIndex(of: 0x0A)
        else {
            return known
        }
        var next = known
        for line in appended[..<lastNewline].split(separator: 0x0A)
            where Self.markers.contains(where: { line.range(of: $0) != nil })
        {
            Self.apply(Data(line), to: &next)
        }
        // A line still being written is read again once it ends.
        next.offset = known.offset + UInt64(appended.distance(from: appended.startIndex, to: lastNewline)) + 1
        return next
    }

    /// A task reports how it ended in a `<task-notification>`, which is queued
    /// while a turn runs and then sent as a prompt.
    private static func apply(_ line: Data, to progress: inout Progress) {
        if line.range(of: self.reportMarker) != nil, let text = String(data: line, encoding: .utf8) {
            for match in text.matches(of: #/<task-id>([^<\\]+)</task-id>/#) {
                progress.pending[String(match.output.1)] = nil
            }
        }
        // Copies of each request repeat the calls and results; reading only the
        // entries themselves keeps large requests from being parsed.
        guard line.prefix(64).range(of: self.requestMarker) == nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["isSidechain"] as? Bool != true
        else {
            return
        }
        if object["type"] as? String == "assistant" {
            let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks where self.backgroundTools.contains(block["name"] as? String ?? "") {
                guard let id = block["id"] as? String,
                      let activity = DesktopUnreadTurnReader.claudeToolActivity(block)
                else {
                    continue
                }
                progress.calls.append((id, activity))
            }
            progress.calls = progress.calls.suffix(self.recentCallLimit)
            return
        }
        guard object["type"] as? String == "user",
              let result = object["toolUseResult"] as? [String: Any]
        else {
            return
        }
        if line.range(of: self.stopMarker) != nil, let id = result["task_id"] as? String {
            progress.pending[id] = nil
            return
        }
        let id = result["backgroundTaskId"] as? String
            ?? (result["isAsync"] as? Bool == true ? result["agentId"] as? String : nil)
            ?? (line.range(of: self.monitorMarker) != nil ? result["taskId"] as? String : nil)
        guard let id,
              let startedAt = (object["timestamp"] as? String).flatMap({
                  try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
              })
        else {
            return
        }
        let callID = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]])?
            .lazy.compactMap { $0["tool_use_id"] as? String }.first
        progress.pending[id] = Task(
            startedAt: startedAt,
            activity: progress.calls.last { $0.id == callID }?.activity)
    }
}

/// Follows what a running Claude turn is doing: the step of its task list in
/// progress, or else its latest progress note, or else what its latest tool
/// call says it does. A transcript only grows, so after the first read, which
/// goes back to the prompt that opened the turn, only appended lines are
/// scanned. Confined to the unread watcher's queue.
final class ClaudeActivityReader {
    private struct Step {
        var text: String
        var status: String
    }

    private struct Turn {
        var steps: [Step] = []
        var note: String?
        var described: String?

        var activity: String? {
            if let index = self.steps.firstIndex(where: { $0.status == "in_progress" }) {
                return "\(index + 1)/\(self.steps.count) \(self.steps[index].text)"
            }
            return self.note ?? self.described
        }
    }

    private struct Progress {
        var offset: UInt64
        var turn: Turn
    }

    private enum Entry {
        case prompt
        case reply([[String: Any]])
    }

    private static let planTool = "mcp__ccd_turn__update_plan"
    private static let wrapUpTool = "mcp__ccd_turn__wrap_up"
    private static let markers = ["\"type\":\"user\"", "\"type\":\"assistant\""].map { Data($0.utf8) }
    private static let requestMarker = Data("\"type\":\"api-request".utf8)

    private var progress: [String: Progress] = [:]

    func activity(in url: URL, size: UInt64) -> String? {
        if var known = self.progress[url.path], known.offset <= size {
            if known.offset < size {
                known = self.advance(known, in: url, to: size)
                self.progress[url.path] = known
            }
            return known.turn.activity
        }
        var entries: [Entry] = []
        DesktopUnreadTurnReader.scanBackward(in: url, markers: Self.markers) { line in
            guard let entry = Self.entry(line) else { return false }
            entries.append(entry)
            if case .prompt = entry {
                return true
            }
            return false
        }
        var turn = Turn()
        for entry in entries.reversed() {
            Self.apply(entry, to: &turn)
        }
        self.progress[url.path] = Progress(offset: size, turn: turn)
        return turn.activity
    }

    func forget(except paths: Set<String>) {
        self.progress = self.progress.filter { paths.contains($0.key) }
    }

    private func advance(_ known: Progress, in url: URL, to size: UInt64) -> Progress {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return known }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: known.offset)) != nil,
              let appended = try? handle.read(upToCount: Int(size - known.offset)),
              let lastNewline = appended.lastIndex(of: 0x0A)
        else {
            return known
        }
        var next = known
        for line in appended[..<lastNewline].split(separator: 0x0A)
            where Self.markers.contains(where: { line.range(of: $0) != nil })
        {
            if let entry = Self.entry(Data(line)) {
                Self.apply(entry, to: &next.turn)
            }
        }
        // A line still being written is read again once it ends.
        next.offset = known.offset + UInt64(appended.distance(from: appended.startIndex, to: lastNewline)) + 1
        return next
    }

    /// Tool results and the reports of background tasks carry a turn on, while
    /// any other prompt opens a new one.
    private static func entry(_ line: Data) -> Entry? {
        guard line.prefix(64).range(of: self.requestMarker) == nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["isSidechain"] as? Bool != true,
              object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else {
            return nil
        }
        switch object["type"] as? String {
        case "assistant":
            return .reply(message["content"] as? [[String: Any]] ?? [])
        case "user":
            if let blocks = message["content"] as? [[String: Any]],
               blocks.allSatisfy({ $0["type"] as? String == "tool_result" })
            {
                return nil
            }
            if (object["origin"] as? [String: Any])?["kind"] as? String == "task-notification"
                || (message["content"] as? String)?.hasPrefix("<task-notification>") == true
            {
                return nil
            }
            return .prompt
        default:
            return nil
        }
    }

    private static func apply(_ entry: Entry, to turn: inout Turn) {
        guard case let .reply(blocks) = entry else {
            turn = Turn()
            return
        }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let note = DesktopUnreadTurnReader.replySummary(block["text"] as? String) {
                    turn.note = note
                }
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case self.planTool:
                    self.updatePlan(&turn.steps, with: input)
                case "TodoWrite":
                    turn.steps = (input["todos"] as? [[String: Any]] ?? []).compactMap { todo in
                        let status = todo["status"] as? String ?? "pending"
                        let text = status == "in_progress" ? todo["activeForm"] as? String ?? todo["content"] as? String
                            : todo["content"] as? String
                        return text.map { Step(text: $0, status: status) }
                    }
                case self.wrapUpTool:
                    turn.steps = turn.steps.map { Step(text: $0.text, status: "completed") }
                default:
                    if let described = (input["description"] as? String).flatMap(DesktopUnreadTurnReader.flattened) {
                        turn.described = described
                    }
                }
            default:
                continue
            }
        }
    }

    /// A plan is set whole, then moves on a step at a time, or marks steps
    /// done and starts one out of order. Steps count from 1.
    private static func updatePlan(_ steps: inout [Step], with input: [String: Any]) {
        if let items = input["items"] as? [[String: Any]] {
            steps = items.compactMap { item in
                (item["content"] as? String).map { Step(text: $0, status: item["status"] as? String ?? "pending") }
            }
            return
        }
        if input["advance"] as? Bool == true {
            if let current = steps.firstIndex(where: { $0.status == "in_progress" }) {
                steps[current].status = "completed"
            }
            if let next = steps.firstIndex(where: { $0.status == "pending" }) {
                steps[next].status = "in_progress"
            }
        }
        for number in input["done"] as? [Int] ?? [] where steps.indices.contains(number - 1) {
            steps[number - 1].status = "completed"
        }
        if let number = input["start"] as? Int, steps.indices.contains(number - 1) {
            steps[number - 1].status = "in_progress"
        }
    }
}
