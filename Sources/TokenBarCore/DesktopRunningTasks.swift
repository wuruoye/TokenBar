import Foundation

/// A Codex or Claude desktop task whose turn is still running.
public struct DesktopRunningTask: Equatable, Identifiable, Sendable {
    public let platform: TokenPlatform
    /// The Codex thread ID or Claude Desktop session ID that each app's deep
    /// link opens.
    public let id: String
    public let title: String?
    public let startedAt: Date?

    public init(platform: TokenPlatform, id: String, title: String?, startedAt: Date?) {
        self.platform = platform
        self.id = id
        self.title = title
        self.startedAt = startedAt
    }
}

/// Whether a running task's transcript has gone quiet for so long that its app
/// most likely quit mid-turn.
enum DesktopRunningTaskLiveness {
    static let quietLimit: TimeInterval = 30 * 60
}

/// Follows each Codex rollout's turn events. A running rollout grows with every
/// event, so after the first read only appended lines are scanned. Confined to
/// the unread watcher's queue.
final class CodexTurnStateReader {
    struct TurnState: Equatable {
        var isRunning = false
        var startedAt: Date?
    }

    private struct Progress {
        var offset: UInt64
        var state: TurnState
    }

    private static let markers = ["\"task_started\"", "\"task_complete\"", "\"turn_aborted\""]
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
        DesktopUnreadTurnReader.scanBackward(in: url, markers: Self.markers) { line in
            guard let event = Self.turnEvent(line) else { return false }
            state = event
            return true
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
            if let event = Self.turnEvent(Data(line)) {
                next.state = event
            }
        }
        // A line still being written is read again once it ends.
        next.offset = known.offset + UInt64(appended.distance(from: appended.startIndex, to: lastNewline)) + 1
        return next
    }

    private static func turnEvent(_ line: Data) -> TurnState? {
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
            return TurnState(isRunning: true, startedAt: timestamp)
        case "task_complete", "turn_aborted":
            return TurnState(isRunning: false, startedAt: nil)
        default:
            return nil
        }
    }
}
