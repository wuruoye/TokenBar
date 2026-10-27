import Foundation
import Observation
import TokenBarCore
import TokenBarWidgetData
import WidgetKit

/// Shares the unread desktop tasks with the TokenBar widget and reloads it when
/// they change. Builds signed without an App Group have no widget and skip this.
@MainActor
final class UnreadWidgetPublisher {
    /// Codex and Claude publish separately when a task finishes or is read, so a
    /// short delay lets one widget reload cover both.
    private static let coalescingDelay: Duration = .milliseconds(400)

    private let unreadTasks: DesktopUnreadTaskMonitor
    private let settings: TokenBarSettings
    private var published: UnreadWidgetSnapshot?
    private var pendingPublish: Task<Void, Never>?
    private var isStarted = false

    init(unreadTasks: DesktopUnreadTaskMonitor, settings: TokenBarSettings) {
        self.unreadTasks = unreadTasks
        self.settings = settings
    }

    func start() {
        guard UnreadWidgetStore.appGroupIdentifier != nil, !self.isStarted else { return }
        self.isStarted = true
        self.observe()
        self.schedulePublish()
    }

    func stop() {
        guard self.isStarted else { return }
        self.isStarted = false
        self.pendingPublish?.cancel()
        self.pendingPublish = nil
        self.publish(UnreadWidgetSnapshot(isTracking: false, platforms: [], tasks: [], running: []))
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
            self.publish(Self.snapshot(of: self.unreadTasks, settings: self.settings))
        }
    }

    /// Matches the menu bar, which hides Claude's unread count with its section.
    /// A task that started another turn is listed as running, not unread. The
    /// desktop card shows the same snapshot.
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
        guard snapshot != self.published else { return }
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
