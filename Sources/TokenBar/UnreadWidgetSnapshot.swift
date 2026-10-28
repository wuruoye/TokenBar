import Foundation

/// The tasks the desktop card shows: unread, running, working on in the
/// background, and read last.
struct UnreadWidgetSnapshot: Equatable, Sendable {
    struct Platform: Equatable, Identifiable, Sendable {
        /// `codex` or `claude`, matching `TokenPlatform.rawValue`.
        let id: String
        let name: String
        let unreadCount: Int

        init(id: String, name: String, unreadCount: Int) {
            self.id = id
            self.name = name
            self.unreadCount = unreadCount
        }
    }

    /// Codable because the tasks read last are kept across launches.
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let platform: String
        /// The Codex thread ID or Claude Desktop session ID.
        let taskID: String
        let title: String
        let prompt: String?
        /// The opening text of the reply that finished the task.
        let reply: String?
        /// How long the task's last turn ran, in seconds.
        let turnDuration: TimeInterval?
        let workspaceName: String?
        let updatedAt: Date?

        var id: String {
            "\(self.platform)/\(self.taskID)"
        }

        init(
            platform: String,
            taskID: String,
            title: String,
            prompt: String?,
            reply: String?,
            turnDuration: TimeInterval?,
            workspaceName: String?,
            updatedAt: Date?)
        {
            self.platform = platform
            self.taskID = taskID
            self.title = title
            self.prompt = prompt
            self.reply = reply
            self.turnDuration = turnDuration
            self.workspaceName = workspaceName
            self.updatedAt = updatedAt
        }
    }

    /// A task still running a turn, listed by title and what it is doing.
    struct RunningItem: Equatable, Identifiable, Sendable {
        let platform: String
        let taskID: String
        let title: String
        let startedAt: Date?
        /// What the turn, or else its background tasks, is doing now.
        let activity: String?

        var id: String {
            "\(self.platform)/\(self.taskID)"
        }

        init(platform: String, taskID: String, title: String, startedAt: Date?, activity: String? = nil) {
            self.platform = platform
            self.taskID = taskID
            self.title = title
            self.startedAt = startedAt
            self.activity = activity
        }
    }

    let platforms: [Platform]
    /// Every platform's unread tasks, most recently updated first.
    let tasks: [Item]
    /// Every platform's running tasks, most recently started first.
    let running: [RunningItem]
    /// Read tasks whose turn ended while work it started in the background
    /// still runs, most recently started first.
    let background: [RunningItem]
    /// The last tasks the user read, most recently read first.
    let recent: [Item]

    init(
        platforms: [Platform],
        tasks: [Item],
        running: [RunningItem],
        background: [RunningItem] = [],
        recent: [Item] = [])
    {
        self.platforms = platforms
        self.tasks = tasks
        self.running = running
        self.background = background
        self.recent = recent
    }

    var unreadCount: Int {
        self.platforms.reduce(0) { $0 + $1.unreadCount }
    }
}

extension UnreadWidgetSnapshot.Item {
    /// Codex titles untitled threads with their first prompt, which can also be
    /// the last one.
    var distinctPrompt: String? {
        guard let prompt, prompt != self.title else { return nil }
        return prompt
    }
}

enum UnreadTaskFormat {
    /// How long a turn ran, such as `42s`, `4m 12s`, or `1h 5m`.
    static func duration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        guard minutes >= 60 else {
            return seconds % 60 == 0 ? "\(minutes)m" : "\(minutes)m \(seconds % 60)s"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
