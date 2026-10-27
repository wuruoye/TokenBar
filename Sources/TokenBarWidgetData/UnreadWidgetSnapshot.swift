import Foundation

/// The unread tasks TokenBar hands to its desktop widget through the shared
/// App Group container.
public struct UnreadWidgetSnapshot: Codable, Equatable, Sendable {
    public struct Platform: Codable, Equatable, Identifiable, Sendable {
        /// `codex` or `claude`, matching `TokenPlatform.rawValue`.
        public let id: String
        public let name: String
        public let unreadCount: Int

        public init(id: String, name: String, unreadCount: Int) {
            self.id = id
            self.name = name
            self.unreadCount = unreadCount
        }
    }

    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public let platform: String
        /// The Codex thread ID or Claude Desktop session ID.
        public let taskID: String
        public let title: String
        public let prompt: String?
        /// The opening text of the reply that finished the task.
        public let reply: String?
        /// How long the task's last turn ran, in seconds.
        public let turnDuration: TimeInterval?
        public let workspaceName: String?
        public let updatedAt: Date?

        public var id: String {
            "\(self.platform)/\(self.taskID)"
        }

        public var openURL: URL? {
            UnreadTaskLink.url(platform: self.platform, taskID: self.taskID)
        }

        public init(
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

    /// A task still running a turn, listed by title alone.
    public struct RunningItem: Codable, Equatable, Identifiable, Sendable {
        public let platform: String
        public let taskID: String
        public let title: String
        public let startedAt: Date?

        public var id: String {
            "\(self.platform)/\(self.taskID)"
        }

        public var openURL: URL? {
            UnreadTaskLink.url(platform: self.platform, taskID: self.taskID)
        }

        public init(platform: String, taskID: String, title: String, startedAt: Date?) {
            self.platform = platform
            self.taskID = taskID
            self.title = title
            self.startedAt = startedAt
        }
    }

    /// False once TokenBar quits, so the widget does not keep showing counts
    /// nobody updates.
    public let isTracking: Bool
    public let platforms: [Platform]
    /// Every platform's unread tasks, most recently updated first.
    public let tasks: [Item]
    /// Every platform's running tasks, most recently started first.
    public let running: [RunningItem]

    public init(isTracking: Bool, platforms: [Platform], tasks: [Item], running: [RunningItem]) {
        self.isTracking = isTracking
        self.platforms = platforms
        self.tasks = tasks
        self.running = running
    }

    /// Snapshots written before running tasks were shared have none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isTracking = try container.decode(Bool.self, forKey: .isTracking)
        self.platforms = try container.decode([Platform].self, forKey: .platforms)
        self.tasks = try container.decode([Item].self, forKey: .tasks)
        self.running = try container.decodeIfPresent([RunningItem].self, forKey: .running) ?? []
    }

    public var unreadCount: Int {
        self.platforms.reduce(0) { $0 + $1.unreadCount }
    }
}

public extension UnreadWidgetSnapshot.Item {
    /// Codex titles untitled threads with their first prompt, which can also be
    /// the last one.
    var distinctPrompt: String? {
        guard let prompt, prompt != self.title else { return nil }
        return prompt
    }
}

public enum UnreadTaskFormat {
    /// How long a turn ran, such as `42s`, `4m 12s`, or `1h 5m`.
    public static func duration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        guard minutes >= 60 else {
            return seconds % 60 == 0 ? "\(minutes)m" : "\(minutes)m \(seconds % 60)s"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

public enum UnreadWidgetStore {
    public static let widgetKind = "TokenBarUnreadTasks"
    /// `package_app.sh` writes the signed App Group into both Info.plist files.
    public static let appGroupInfoKey = "TokenBarAppGroupIdentifier"

    private static let fileName = "unread-tasks.json"

    public static var appGroupIdentifier: String? {
        (Bundle.main.object(forInfoDictionaryKey: self.appGroupInfoKey) as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func load() -> UnreadWidgetSnapshot? {
        guard let url = self.fileURL(),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(UnreadWidgetSnapshot.self, from: data)
    }

    public static func save(_ snapshot: UnreadWidgetSnapshot) throws {
        guard let url = self.fileURL() else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    private static func fileURL() -> URL? {
        guard let identifier = self.appGroupIdentifier else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(self.fileName, isDirectory: false)
    }
}

/// The `tokenbar://` link a widget row opens. TokenBar turns it into the
/// Codex or Claude link that shows the task in its app.
public enum UnreadTaskLink {
    public static let scheme = "tokenbar"
    private static let host = "unread-task"

    public static func url(platform: String, taskID: String) -> URL? {
        var components = URLComponents()
        components.scheme = self.scheme
        components.host = self.host
        components.queryItems = [
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "id", value: taskID),
        ]
        return components.url
    }

    public static func parse(_ url: URL) -> (platform: String, taskID: String)? {
        guard url.scheme?.lowercased() == self.scheme,
              url.host?.lowercased() == self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let platform = items.first(where: { $0.name == "platform" })?.value,
              let taskID = items.first(where: { $0.name == "id" })?.value,
              !platform.isEmpty,
              !taskID.isEmpty
        else {
            return nil
        }
        return (platform, taskID)
    }
}
