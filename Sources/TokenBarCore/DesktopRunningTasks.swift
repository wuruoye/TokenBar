import Foundation

/// A Codex, Claude, or Antigravity desktop task whose turn is still running,
/// or whose background tasks are.
public struct DesktopRunningTask: Equatable, Identifiable, Sendable {
    public let platform: TokenPlatform
    /// The Codex thread ID, Claude Desktop session ID, or Antigravity
    /// conversation ID.
    public let id: String
    public let title: String?
    public let startedAt: Date?
    /// What the turn, or else its background tasks, is doing now.
    public let activity: String?
    /// The turn ended, and only tasks it started in the background still run.
    public let isInBackground: Bool
    /// A background process disappeared without reporting its result.
    public let isInterrupted: Bool

    public init(
        platform: TokenPlatform,
        id: String,
        title: String?,
        startedAt: Date?,
        activity: String? = nil,
        isInBackground: Bool = false,
        isInterrupted: Bool = false)
    {
        self.platform = platform
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.activity = activity
        self.isInBackground = isInBackground
        self.isInterrupted = isInterrupted
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
    struct PendingQuestion: Equatable {
        let id: String
        let text: String
        let askedAt: Date?
        let isAsync: Bool
    }

    struct TurnState: Equatable {
        var isRunning = false
        var startedAt: Date?
        /// The turn's latest progress note.
        var activity: String?
        /// Questions asked in the rollout that the user has not answered yet.
        var pendingQuestions: [PendingQuestion] = []

        var askQuestion: String? {
            self.pendingQuestions.last?.text
        }

        var askedAt: Date? {
            self.pendingQuestions.last?.askedAt
        }
    }

    private struct Progress {
        var offset: UInt64
        var state: TurnState
    }

    private enum Event {
        case started(at: Date?)
        case ended
        case aborted
        case note(String)
        case question(PendingQuestion)
        case questionToolOutput(callID: String, isAcceptedPlaceholder: Bool)
        case questionReply(rawText: String)
        case humanPrompt
    }

    private static let markers = [
        "\"task_started\"",
        "\"task_complete\"",
        "\"turn_aborted\"",
        "\"commentary\"",
        "\"request_user_input",
        "\"function_call_output\"",
        "<send_user_message_question_reply>",
        "\"UserMessage\"",
        "\"user_message\"",
    ].map { Data($0.utf8) }

    private var progress: [String: Progress] = [:]

    func state(of url: URL, size: UInt64) -> TurnState {
        if var known = self.progress[url.path], known.offset <= size {
            if known.offset < size {
                known = self.advance(known, in: url, to: size)
                self.progress[url.path] = known
            }
            return known.state
        }
        var events: [Event] = []
        var sawTurnBoundary = false
        var sawHumanPrompt = false
        DesktopUnreadTurnReader.scanBackward(in: url, markers: Self.markers) { line in
            guard let event = Self.event(line) else { return false }
            events.append(event)
            switch event {
            case .started, .ended, .aborted:
                sawTurnBoundary = true
            case .humanPrompt:
                sawHumanPrompt = true
            default:
                break
            }
            return sawTurnBoundary && sawHumanPrompt
        }
        var state = TurnState()
        for event in events.reversed() {
            Self.apply(event, to: &state)
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
            if let event = Self.event(Data(line)) {
                Self.apply(event, to: &next.state)
            }
        }
        // A line still being written is read again once it ends.
        next.offset = known.offset + UInt64(appended.distance(from: appended.startIndex, to: lastNewline)) + 1
        return next
    }

    private static func apply(_ event: Event, to state: inout TurnState) {
        switch event {
        case let .started(startedAt):
            state.isRunning = true
            state.startedAt = startedAt
            state.activity = nil
        case .ended:
            state.isRunning = false
            state.startedAt = nil
            state.activity = nil
            state.pendingQuestions.removeAll { !$0.isAsync }
        case .aborted:
            state.isRunning = false
            state.startedAt = nil
            state.activity = nil
            state.pendingQuestions.removeAll()
        case let .note(text):
            if state.isRunning {
                state.activity = text
            }
        case let .question(question):
            state.pendingQuestions.removeAll { $0.id == question.id }
            state.pendingQuestions.append(question)
        case let .questionToolOutput(callID, isAcceptedPlaceholder):
            if !isAcceptedPlaceholder {
                state.pendingQuestions.removeAll { $0.id == callID }
            }
        case let .questionReply(rawText):
            let matched = state.pendingQuestions.contains { !$0.id.isEmpty && rawText.contains($0.id) }
            if matched {
                state.pendingQuestions.removeAll { !$0.id.isEmpty && rawText.contains($0.id) }
            } else {
                state.pendingQuestions.removeAll()
            }
        case .humanPrompt:
            state.pendingQuestions.removeAll()
        }
    }

    private static func event(_ line: Data) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        let timestamp = (object["timestamp"] as? String).flatMap {
            (try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date($0, strategy: Date.ISO8601FormatStyle()))
        }
        switch object["type"] as? String {
        case "response_item":
            guard let payload = object["payload"] as? [String: Any] else { return nil }
            switch payload["type"] as? String {
            case "function_call":
                let name = payload["name"] as? String ?? ""
                guard name == "request_user_input" || name == "request_user_input_async" else {
                    return nil
                }
                let callID = payload["call_id"] as? String ?? ""
                let argsText = payload["arguments"] as? String ?? ""
                let args = (try? JSONSerialization.jsonObject(with: Data(argsText.utf8))) as? [String: Any]
                let questions = (args?["questions"] as? [[String: Any]] ?? []).compactMap { item -> String? in
                    (item["title"] as? String)
                        ?? (item["question"] as? String)
                        ?? (item["header"] as? String)
                }
                let raw = questions.isEmpty ? "Waiting for your answer" : questions.joined(separator: " · ")
                guard let text = DesktopUnreadTurnReader.replySummary(raw) ?? DesktopUnreadTurnReader.flattened(raw) else {
                    return nil
                }
                return .question(PendingQuestion(
                    id: callID,
                    text: text,
                    askedAt: timestamp,
                    isAsync: name == "request_user_input_async"))
            case "function_call_output":
                guard let callID = payload["call_id"] as? String, !callID.isEmpty else { return nil }
                let output = (payload["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let isAccepted = output.contains("\"accepted\":true") || output.contains("\"accepted\": true")
                return .questionToolOutput(callID: callID, isAcceptedPlaceholder: isAccepted)
            default:
                return nil
            }
        case "event_msg":
            guard let payload = object["payload"] as? [String: Any] else { return nil }
            switch payload["type"] as? String {
            case "task_started":
                return .started(at: timestamp)
            case "task_complete":
                return .ended
            case "turn_aborted":
                return .aborted
            case "user_message":
                guard let message = payload["message"] as? String else { return nil }
                if message.contains("<send_user_message_question_reply>") {
                    return .questionReply(rawText: message)
                }
                return Self.isCodexHumanPrompt(message) ? .humanPrompt : nil
            case "item_completed":
                guard let item = payload["item"] as? [String: Any] else { return nil }
                switch item["type"] as? String {
                case "UserMessage":
                    let text = (item["content"] as? [[String: Any]] ?? [])
                        .filter { ($0["type"] as? String)?.lowercased() == "text" }
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                    if text.contains("<send_user_message_question_reply>") {
                        return .questionReply(rawText: text)
                    }
                    return Self.isCodexHumanPrompt(text) ? .humanPrompt : nil
                case "AgentMessage":
                    // Codex marks the messages it writes while working as commentary.
                    guard item["phase"] as? String == "commentary" else { return nil }
                    let text = (item["content"] as? [[String: Any]] ?? [])
                        .filter { ($0["type"] as? String)?.lowercased() == "text" }
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                    return DesktopUnreadTurnReader.replySummary(text).map { .note($0) }
                default:
                    return nil
                }
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func isCodexHumanPrompt(_ raw: String) -> Bool {
        var text = raw
        if let request = text.range(of: "## My request:") {
            text = String(text[request.upperBound...])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("<"),
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("【后台完成】")
        else {
            return false
        }
        return true
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

/// Follows what a running Antigravity turn is doing from its append-only
/// `transcript.jsonl`: the latest tool call summary, or else the latest model
/// progress note since the user prompt that opened the turn, as well as tasks
/// still running in the background after the turn ends. Confined to the unread
/// watcher's queue.
final class AntigravityActivityReader {
    private struct Progress {
        var offset: UInt64
        var activity: String?
    }

    private struct BackgroundTask {
        var startedAt: Date
        var activity: String?
    }

    private struct BackgroundProgress {
        var offset: UInt64
        var pending: [String: BackgroundTask] = [:]
        var lastCallActivity: String?
    }

    private enum Entry {
        case prompt
        case step(String)
    }

    private static let markers = ["\"USER_INPUT\"", "\"PLANNER_RESPONSE\""].map { Data($0.utf8) }
    private static let backgroundMarkers = [
        "\"PLANNER_RESPONSE\"",
        "Tool is running as a background task",
        "\"SYSTEM_MESSAGE\"",
        "Task id \"",
    ].map { Data($0.utf8) }
    private static let maximumScannedBytes: UInt64 = 32 << 20

    private var progress: [String: Progress] = [:]
    private var backgroundProgress: [String: BackgroundProgress] = [:]

    func activity(in url: URL, size: UInt64) -> String? {
        if var known = self.progress[url.path], known.offset <= size {
            if known.offset < size {
                known = self.advance(known, in: url, to: size)
                self.progress[url.path] = known
            }
            return known.activity
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
        var activity: String?
        for entry in entries.reversed() {
            switch entry {
            case .prompt:
                activity = nil
            case let .step(text):
                activity = text
            }
        }
        self.progress[url.path] = Progress(offset: size, activity: activity)
        return activity
    }

    func runningBackgroundTasks(
        in url: URL,
        size: UInt64,
        after cutoff: Date) -> (startedAt: Date, activity: String?)?
    {
        var known = self.backgroundProgress[url.path].flatMap { $0.offset <= size ? $0 : nil }
            ?? BackgroundProgress(offset: size > Self.maximumScannedBytes ? size - Self.maximumScannedBytes : 0)
        if known.offset < size {
            known = self.advanceBackground(known, in: url, to: size)
        }
        self.backgroundProgress[url.path] = known
        let running = known.pending.values
            .filter { $0.startedAt > cutoff }
            .sorted { $0.startedAt < $1.startedAt }
        guard let first = running.first else { return nil }
        let activities = running.compactMap(\.activity)
        return (first.startedAt, activities.isEmpty ? nil : activities.joined(separator: " · "))
    }

    func forget(except paths: Set<String>) {
        self.progress = self.progress.filter { paths.contains($0.key) }
        self.backgroundProgress = self.backgroundProgress.filter { paths.contains($0.key) }
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
            switch Self.entry(Data(line)) {
            case .prompt:
                next.activity = nil
            case let .step(text):
                next.activity = text
            case nil:
                break
            }
        }
        next.offset = known.offset + UInt64(appended.distance(from: appended.startIndex, to: lastNewline)) + 1
        return next
    }

    private func advanceBackground(_ known: BackgroundProgress, in url: URL, to size: UInt64) -> BackgroundProgress {
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
            where Self.backgroundMarkers.contains(where: { line.range(of: $0) != nil })
        {
            Self.applyBackground(Data(line), to: &next)
        }
        next.offset = known.offset + UInt64(appended.distance(from: appended.startIndex, to: lastNewline)) + 1
        return next
    }

    private static func applyBackground(_ line: Data, to progress: inout BackgroundProgress) {
        if let text = String(data: line, encoding: .utf8) {
            for match in text.matches(of: #/Task id \\?"([^"\\]+)\\?" finished/#) {
                progress.pending[String(match.output.1)] = nil
            }
            for match in text.matches(of: #/\bsender=([0-9a-fA-F-]{8,})\b/#) {
                progress.pending[String(match.output.1)] = nil
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }
        switch object["type"] as? String {
        case "PLANNER_RESPONSE" where object["source"] as? String == "MODEL":
            let calls = object["tool_calls"] as? [[String: Any]] ?? []
            for call in calls {
                let name = call["name"] as? String ?? ""
                let args = (call["args"] as? [String: Any])
                    ?? (call["arguments"] as? [String: Any])
                    ?? [:]
                if name == "manage_task",
                   DesktopUnreadTurnReader.antigravityArgumentString(args, "Action") == "kill",
                   let id = DesktopUnreadTurnReader.antigravityArgumentString(args, "TaskId")
                {
                    progress.pending[id] = nil
                } else if name == "run_command" || name == "schedule",
                          let activity = DesktopUnreadTurnReader.antigravityToolActivity(call)
                {
                    progress.lastCallActivity = activity
                }
            }
        case "GENERIC" where object["status"] as? String == "RUNNING":
            guard let content = object["content"] as? String,
                  let match = content.firstMatch(
                      of: #/Tool is running as a background task with task id:\s*([^\s\n]+)/#),
                  let startedAt = DesktopUnreadTurnReader.antigravityTimestamp(object)
            else {
                return
            }
            let id = String(match.output.1)
            let fallback = content.firstMatch(of: #/Task Description:\s*([^\n]+)/#)
                .flatMap { DesktopUnreadTurnReader.flattened(String($0.output.1)) }
                .map { "Run \($0)" }
            progress.pending[id] = BackgroundTask(
                startedAt: startedAt,
                activity: progress.lastCallActivity ?? fallback)
            progress.lastCallActivity = nil
        default:
            break
        }
    }

    private static func entry(_ line: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        switch object["type"] as? String {
        case "USER_INPUT" where object["source"] as? String == "USER_EXPLICIT":
            return DesktopUnreadTurnReader.antigravityHumanText(object["content"] as? String) == nil
                ? nil
                : .prompt
        case "PLANNER_RESPONSE" where object["source"] as? String == "MODEL":
            let calls = object["tool_calls"] as? [[String: Any]] ?? []
            if let tool = calls.lazy.compactMap(DesktopUnreadTurnReader.antigravityToolActivity).last {
                return .step(tool)
            }
            return DesktopUnreadTurnReader.replySummary(object["content"] as? String).map(Entry.step)
        default:
            return nil
        }
    }
}
