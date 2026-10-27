import Foundation
import Observation
import TokenBarCore
import TokenBarWidgetData
import WidgetKit

/// Builds the snapshot the TokenBar widget and the desktop card show, keeps the
/// last tasks the user read, and shares the snapshot with the widget, reloading
/// it when it changes. Builds signed without an App Group have no widget, so
/// there the snapshot only feeds the card.
@MainActor
@Observable
final class UnreadWidgetPublisher {
    /// Codex and Claude publish separately when a task finishes or is read, so a
    /// short delay lets one widget reload cover both.
    private static let coalescingDelay: Duration = .milliseconds(400)
    static let recentLimit = 2
    /// Read tasks kept beyond the ones shown, so one that runs again comes back
    /// once it is done.
    private static let readHistoryLimit = 10
    private static let readHistoryKey = "TokenBar.unreadWidget.readHistory"
    /// A turn that ends in the window the user is looking at never becomes
    /// unread, while the unread mark of one that ends elsewhere can trail the
    /// end of the turn by a moment.
    private static let finishGrace: Duration = .seconds(3)

    private(set) var snapshot = UnreadWidgetSnapshot(isTracking: true, platforms: [], tasks: [], running: [])

    @ObservationIgnored private let unreadTasks: DesktopUnreadTaskMonitor
    @ObservationIgnored private let settings: TokenBarSettings
    @ObservationIgnored private let sharesWithWidget = UnreadWidgetStore.appGroupIdentifier != nil
    @ObservationIgnored private var published: UnreadWidgetSnapshot?
    @ObservationIgnored private var pendingPublish: Task<Void, Never>?
    /// Tasks the user read, most recently read first, kept across launches.
    @ObservationIgnored private var readHistory: [UnreadWidgetSnapshot.Item] = []
    /// Tasks whose turn ended without becoming unread yet.
    @ObservationIgnored private var finishedTurns: [String: (item: UnreadWidgetSnapshot.Item, at: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var pendingSettle: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    init(unreadTasks: DesktopUnreadTaskMonitor, settings: TokenBarSettings) {
        self.unreadTasks = unreadTasks
        self.settings = settings
    }

    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        self.readHistory = UserDefaults.standard.data(forKey: Self.readHistoryKey)
            .flatMap { try? JSONDecoder().decode([UnreadWidgetSnapshot.Item].self, from: $0) } ?? []
        self.observe()
        self.schedulePublish()
    }

    func stop() {
        guard self.isStarted else { return }
        self.isStarted = false
        self.pendingPublish?.cancel()
        self.pendingPublish = nil
        self.pendingSettle?.cancel()
        self.pendingSettle = nil
        self.publish(UnreadWidgetSnapshot(
            isTracking: false,
            platforms: [],
            tasks: [],
            running: [],
            recent: self.snapshot.recent))
    }

    private func observe() {
        withObservationTracking {
            _ = self.unreadTasks.tasks
            _ = self.unreadTasks.running
            _ = self.settings.showsClaude
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.observe()
                self.schedulePublish()
            }
        }
    }

    private func schedulePublish() {
        guard self.pendingPublish == nil else { return }
        self.pendingPublish = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            guard let self, !Task.isCancelled, self.isStarted else { return }
            self.pendingPublish = nil
            let next = Self.snapshot(of: self.unreadTasks, settings: self.settings)
            self.snapshot = self.recordingReads(from: self.snapshot, in: next)
            self.publish(self.snapshot)
        }
    }

    /// A task that leaves the unread list without starting another turn was
    /// read, and so was a turn that ended in the window the user was looking
    /// at, which never becomes unread. A read task is listed while it is
    /// neither unread nor running, until newer reads push it out.
    private func recordingReads(
        from previous: UnreadWidgetSnapshot,
        in next: UnreadWidgetSnapshot) -> UnreadWidgetSnapshot
    {
        let current = Set(next.tasks.map(\.id) + next.running.map(\.id) + next.background.map(\.id))
        let platforms = Set(next.platforms.map(\.id))
        let now = ContinuousClock.now
        for task in previous.running + previous.background where !current.contains(task.id) {
            let item = UnreadWidgetSnapshot.Item(
                platform: task.platform,
                taskID: task.taskID,
                title: task.title,
                prompt: nil,
                reply: nil,
                turnDuration: nil,
                workspaceName: nil,
                updatedAt: Date())
            self.finishedTurns[task.id] = (item, now)
        }
        self.finishedTurns = self.finishedTurns.filter { id, finished in
            !current.contains(id) && platforms.contains(finished.item.platform)
        }
        let settled = self.finishedTurns.values
            .filter { now - $0.at >= Self.finishGrace }
            .map(\.item)
        for item in settled {
            self.finishedTurns[item.id] = nil
        }
        if !self.finishedTurns.isEmpty {
            self.scheduleSettle()
        }
        let read = previous.tasks.filter { !current.contains($0.id) && platforms.contains($0.platform) }
            + settled
        if !read.isEmpty {
            let readIDs = Set(read.map(\.id))
            self.readHistory = Array((read + self.readHistory.filter { !readIDs.contains($0.id) })
                .prefix(Self.readHistoryLimit))
            UserDefaults.standard.set(try? JSONEncoder().encode(self.readHistory), forKey: Self.readHistoryKey)
        }
        let recent = self.readHistory
            .filter { !current.contains($0.id) && platforms.contains($0.platform) }
            .prefix(Self.recentLimit)
        return UnreadWidgetSnapshot(
            isTracking: next.isTracking,
            platforms: next.platforms,
            tasks: next.tasks,
            running: next.running,
            background: next.background,
            recent: Array(recent))
    }

    private func scheduleSettle() {
        guard self.pendingSettle == nil else { return }
        self.pendingSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.finishGrace)
            guard let self, !Task.isCancelled, self.isStarted else { return }
            self.pendingSettle = nil
            self.schedulePublish()
        }
    }

    /// Matches the menu bar, which hides Claude's unread count with its section.
    /// A task that started another turn is listed as running, not unread, while
    /// one whose turn ended with tasks left in the background is listed under
    /// those once it is read.
    static func snapshot(
        of unreadTasks: DesktopUnreadTaskMonitor,
        settings: TokenBarSettings) -> UnreadWidgetSnapshot
    {
        let platforms: [TokenPlatform] = settings.showsClaude ? [.codex, .claude] : [.codex]
        let unread = platforms.flatMap { unreadTasks.tasks[$0] ?? [] }
        let unreadIDs = Set(unread.map { "\($0.platform.rawValue)/\($0.id)" })
        let active = platforms
            .flatMap { unreadTasks.running[$0] ?? [] }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        let running = active.filter { !$0.isInBackground }
        let background = active.filter {
            $0.isInBackground && !unreadIDs.contains("\($0.platform.rawValue)/\($0.id)")
        }
        let runningIDs = Set(running.map { "\($0.platform.rawValue)/\($0.id)" })
        let tasks = unread
            .filter { !runningIDs.contains("\($0.platform.rawValue)/\($0.id)") }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return UnreadWidgetSnapshot(
            isTracking: true,
            platforms: platforms.map { platform in
                UnreadWidgetSnapshot.Platform(
                    id: platform.rawValue,
                    name: platform.displayName,
                    unreadCount: tasks.count { $0.platform == platform })
            },
            tasks: tasks.map { task in
                UnreadWidgetSnapshot.Item(
                    platform: task.platform.rawValue,
                    taskID: task.id,
                    title: task.title ?? task.prompt ?? "\(task.platform.displayName) task",
                    prompt: task.prompt,
                    reply: task.reply,
                    turnDuration: task.turnDuration,
                    workspaceName: task.workspacePath.map {
                        URL(fileURLWithPath: $0).lastPathComponent
                    },
                    updatedAt: task.updatedAt)
            },
            running: running.map(Self.runningItem),
            background: background.map(Self.runningItem))
    }

    private static func runningItem(_ task: DesktopRunningTask) -> UnreadWidgetSnapshot.RunningItem {
        UnreadWidgetSnapshot.RunningItem(
            platform: task.platform.rawValue,
            taskID: task.id,
            title: task.title ?? "\(task.platform.displayName) task",
            startedAt: task.startedAt,
            activity: task.activity)
    }

    /// What a task is doing changes with every step it takes, more often than
    /// the widget may reload, so only the card shows it.
    private func publish(_ snapshot: UnreadWidgetSnapshot) {
        let shared = snapshot.withoutActivity
        guard self.sharesWithWidget, shared != self.published else { return }
        do {
            try UnreadWidgetStore.save(shared)
        } catch {
            NSLog("TokenBar could not share unread tasks with its widget: %@", String(describing: error))
            return
        }
        self.published = shared
        WidgetCenter.shared.reloadTimelines(ofKind: UnreadWidgetStore.widgetKind)
    }
}

private extension UnreadWidgetSnapshot {
    var withoutActivity: UnreadWidgetSnapshot {
        let strip = { (task: RunningItem) in
            RunningItem(platform: task.platform, taskID: task.taskID, title: task.title, startedAt: task.startedAt)
        }
        return UnreadWidgetSnapshot(
            isTracking: self.isTracking,
            platforms: self.platforms,
            tasks: self.tasks,
            running: self.running.map(strip),
            background: self.background.map(strip),
            recent: self.recent)
    }
}
