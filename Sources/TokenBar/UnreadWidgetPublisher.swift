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

    private(set) var snapshot = UnreadWidgetSnapshot(isTracking: true, platforms: [], tasks: [], running: [])

    @ObservationIgnored private let unreadTasks: DesktopUnreadTaskMonitor
    @ObservationIgnored private let settings: TokenBarSettings
    @ObservationIgnored private let sharesWithWidget = UnreadWidgetStore.appGroupIdentifier != nil
    @ObservationIgnored private var published: UnreadWidgetSnapshot?
    @ObservationIgnored private var pendingPublish: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    init(unreadTasks: DesktopUnreadTaskMonitor, settings: TokenBarSettings) {
        self.unreadTasks = unreadTasks
        self.settings = settings
    }

    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        // The tasks read last stay listed after TokenBar restarts.
        if self.sharesWithWidget, let saved = UnreadWidgetStore.load() {
            self.snapshot = UnreadWidgetSnapshot(
                isTracking: true,
                platforms: [],
                tasks: [],
                running: [],
                recent: saved.recent)
        }
        self.observe()
        self.schedulePublish()
    }

    func stop() {
        guard self.isStarted else { return }
        self.isStarted = false
        self.pendingPublish?.cancel()
        self.pendingPublish = nil
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
            self.snapshot = self.keepingRecent(from: self.snapshot, in: next)
            self.publish(self.snapshot)
        }
    }

    /// A task that leaves the unread list without starting another turn was
    /// read. It stays listed until it is unread or running again, or newer
    /// reads push it out.
    private func keepingRecent(
        from previous: UnreadWidgetSnapshot,
        in next: UnreadWidgetSnapshot) -> UnreadWidgetSnapshot
    {
        let current = Set(next.tasks.map(\.id) + next.running.map(\.id))
        let platforms = Set(next.platforms.map(\.id))
        let read = previous.tasks.filter { !current.contains($0.id) }
        var seen = Set<String>()
        let recent = (read + previous.recent)
            .filter { !current.contains($0.id) && platforms.contains($0.platform) && seen.insert($0.id).inserted }
            .prefix(Self.recentLimit)
        return UnreadWidgetSnapshot(
            isTracking: next.isTracking,
            platforms: next.platforms,
            tasks: next.tasks,
            running: next.running,
            recent: Array(recent))
    }

    /// Matches the menu bar, which hides Claude's unread count with its section.
    /// A task that started another turn is listed as running, not unread.
    static func snapshot(
        of unreadTasks: DesktopUnreadTaskMonitor,
        settings: TokenBarSettings) -> UnreadWidgetSnapshot
    {
        let platforms: [TokenPlatform] = settings.showsClaude ? [.codex, .claude] : [.codex]
        let running = platforms
            .flatMap { unreadTasks.running[$0] ?? [] }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        let runningIDs = Set(running.map { "\($0.platform.rawValue)/\($0.id)" })
        let tasks = platforms
            .flatMap { unreadTasks.tasks[$0] ?? [] }
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
            running: running.map { task in
                UnreadWidgetSnapshot.RunningItem(
                    platform: task.platform.rawValue,
                    taskID: task.id,
                    title: task.title ?? "\(task.platform.displayName) task",
                    startedAt: task.startedAt)
            })
    }

    private func publish(_ snapshot: UnreadWidgetSnapshot) {
        guard self.sharesWithWidget, snapshot != self.published else { return }
        do {
            try UnreadWidgetStore.save(snapshot)
        } catch {
            NSLog("TokenBar could not share unread tasks with its widget: %@", String(describing: error))
            return
        }
        self.published = snapshot
        WidgetCenter.shared.reloadTimelines(ofKind: UnreadWidgetStore.widgetKind)
    }
}
