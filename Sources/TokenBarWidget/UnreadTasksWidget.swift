import AppKit
import SwiftUI
import TokenBarWidgetData
import WidgetKit

@main
struct TokenBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        UnreadTasksWidget()
    }
}

struct UnreadTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: UnreadWidgetStore.widgetKind, provider: UnreadTasksProvider()) { entry in
            UnreadTasksWidgetView(snapshot: entry.snapshot)
                .environment(\.minuteRingStart, entry.date)
        }
        .configurationDisplayName("Unread Tasks")
        .description("Finished Codex and Claude tasks you have not opened yet. Click one to open it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UnreadTasksEntry: TimelineEntry {
    let date: Date
    let snapshot: UnreadWidgetSnapshot?
}

/// TokenBar reloads the timeline whenever its unread tasks change. While
/// anything is unread or running, the timeline repeats the snapshot once a
/// minute for an hour so the minute rings restart; otherwise it holds one
/// entry and never refreshes on its own.
struct UnreadTasksProvider: TimelineProvider {
    private static let ringCycles = 60

    func placeholder(in context: Context) -> UnreadTasksEntry {
        UnreadTasksEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadTasksEntry) -> Void) {
        let stored = UnreadWidgetStore.load()
        let showsSample = context.isPreview && (stored?.tasks.isEmpty ?? true)
        completion(UnreadTasksEntry(date: Date(), snapshot: showsSample ? .sample : stored))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadTasksEntry>) -> Void) {
        let now = Date()
        let snapshot = UnreadWidgetStore.load()
        guard let snapshot, snapshot.isTracking, !snapshot.tasks.isEmpty || !snapshot.running.isEmpty else {
            completion(Timeline(entries: [UnreadTasksEntry(date: now, snapshot: snapshot)], policy: .never))
            return
        }
        let minute = Calendar.current.dateInterval(of: .minute, for: now)?.start ?? now
        let entries = (0..<Self.ringCycles).map {
            UnreadTasksEntry(
                date: minute.addingTimeInterval(TimeInterval($0) * MinuteRing.period),
                snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct UnreadTasksWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: UnreadWidgetSnapshot?

    private var hasUnread: Bool {
        self.snapshot?.isTracking == true && self.snapshot?.tasks.isEmpty == false
    }

    var body: some View {
        self.content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if self.hasUnread {
                        LinearGradient(
                            colors: [UnreadAccent.color.opacity(0.18), UnreadAccent.color.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot, snapshot.isTracking {
            if self.family == .systemSmall {
                SmallUnreadView(snapshot: snapshot)
            } else {
                UnreadListView(snapshot: snapshot, family: self.family)
            }
        } else {
            NoticeView(
                symbol: "menubar.rectangle",
                title: "TokenBar is not running",
                detail: "Open TokenBar to track unread Codex and Claude tasks.")
        }
    }
}

private struct SmallUnreadView: View {
    let snapshot: UnreadWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            UnreadHeaderView(snapshot: self.snapshot, countSize: 24, showsPlatformCounts: false)
            PlatformCountsView(platforms: self.snapshot.platforms)
            Spacer(minLength: 0)
            if let task = self.snapshot.tasks.first {
                HStack(spacing: 5) {
                    PlatformIconView(platform: task.platform, size: 11, showsUnreadDot: true)
                    ElapsedText(since: task.updatedAt, isLive: true, alignment: .leading)
                    Spacer(minLength: 0)
                    TurnDurationText(duration: task.turnDuration)
                }
                Text(task.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let reply = task.reply {
                    ReplyText(text: reply, lineLimit: self.snapshot.running.isEmpty ? 3 : 2)
                } else if let prompt = task.distinctPrompt {
                    PromptText(text: prompt, lineLimit: self.snapshot.running.isEmpty ? 3 : 2)
                }
            } else {
                CaughtUpLabel()
            }
            if let running = self.snapshot.running.first {
                RunningRowView(task: running, extraCount: self.snapshot.running.count - 1)
                    .padding(.top, 2)
            }
        }
        .widgetURL(self.snapshot.tasks.first?.openURL ?? self.snapshot.running.first?.openURL)
    }
}

private struct UnreadListView: View {
    let snapshot: UnreadWidgetSnapshot
    let family: WidgetFamily

    private var isLarge: Bool {
        self.family == .systemLarge
    }

    var body: some View {
        let hasRunning = !self.snapshot.running.isEmpty
        let rows = Array(self.snapshot.tasks.prefix(self.isLarge ? (hasRunning ? 3 : 4) : (hasRunning ? 1 : 2)))
        let runningRows = Array(self.snapshot.running.prefix(self.isLarge ? 3 : 2))
        VStack(alignment: .leading, spacing: 8) {
            UnreadHeaderView(snapshot: self.snapshot, countSize: 20, showsPlatformCounts: true)
            if rows.isEmpty {
                CaughtUpLabel()
                    .frame(maxWidth: .infinity, maxHeight: hasRunning ? nil : .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            Divider()
                        }
                        // A medium widget fits two reply lines for the newest task only.
                        TaskRowView(
                            task: task,
                            showsPrompt: self.isLarge,
                            replyLineLimit: self.isLarge || index == 0 ? 2 : 1,
                            isNewest: index == 0)
                    }
                }
                // The header already counts the rows a medium widget leaves out.
                let hiddenCount = self.snapshot.tasks.count - rows.count
                if self.isLarge, hiddenCount > 0 {
                    Text("+\(hiddenCount) more unread")
                        .font(.system(size: 10, weight: .medium))
                        .mutedForeground()
                }
            }
            Spacer(minLength: 0)
            if !runningRows.isEmpty {
                RunningSectionView(
                    rows: runningRows,
                    hiddenCount: self.snapshot.running.count - runningRows.count)
            }
        }
    }
}

private struct UnreadHeaderView: View {
    let snapshot: UnreadWidgetSnapshot
    let countSize: CGFloat
    let showsPlatformCounts: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            UnreadCountBadge(count: self.snapshot.unreadCount, size: self.countSize)
            Text("Unread")
                .font(.system(size: 12, weight: .semibold))
                .mutedForeground(self.snapshot.unreadCount == 0)
            Spacer(minLength: 6)
            if self.showsPlatformCounts {
                PlatformCountsView(platforms: self.snapshot.platforms)
            }
        }
    }
}

/// A filled badge inside a minute ring while anything is unread. Tinted glass
/// drops fills, so the count stands on its own there.
private struct UnreadCountBadge: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let count: Int
    let size: CGFloat

    var body: some View {
        let text = Text("\(self.count)")
            .font(.system(size: self.size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .contentTransition(.numericText(value: Double(self.count)))
        if self.count > 0 {
            let diameter = self.size * 1.45
            ZStack {
                MinuteRing(tint: UnreadAccent.color)
                    .frame(width: diameter + 8, height: diameter + 8)
                if self.renderingMode == .fullColor {
                    Circle()
                        .fill(UnreadAccent.color)
                        .frame(width: diameter, height: diameter)
                    text
                        .foregroundStyle(.white)
                        .frame(width: diameter * 0.8)
                } else {
                    text.frame(width: diameter * 0.8)
                }
            }
        } else {
            text.mutedForeground()
        }
    }
}

/// A ring that fills once a minute. WidgetKit draws a timer progress view
/// itself between timeline entries, and each entry starts the next minute.
private struct MinuteRing: View {
    static let period: TimeInterval = 60

    @Environment(\.minuteRingStart) private var start
    let tint: Color

    var body: some View {
        ProgressView(
            timerInterval: self.start...self.start.addingTimeInterval(Self.period),
            countsDown: false,
            label: { EmptyView() },
            currentValueLabel: { EmptyView() })
            .progressViewStyle(.circular)
            .tint(self.tint)
            .widgetAccentable()
    }
}

private struct MinuteRingStartKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    /// When the current timeline entry's minute ring started.
    var minuteRingStart: Date {
        get { self[MinuteRingStartKey.self] }
        set { self[MinuteRingStartKey.self] = newValue }
    }
}

/// Title and how long the reply has waited, then the reply that finished the
/// task. Large widgets also show the prompt that started it.
private struct TaskRowView: View {
    let task: UnreadWidgetSnapshot.Item
    let showsPrompt: Bool
    let replyLineLimit: Int
    let isNewest: Bool

    var body: some View {
        let row = HStack(alignment: .top, spacing: 8) {
            PlatformIconView(platform: self.task.platform, size: 13, showsUnreadDot: true)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(self.task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    TurnDurationText(duration: self.task.turnDuration)
                    ElapsedText(since: self.task.updatedAt, isLive: self.isNewest)
                }
                if self.showsPrompt, let prompt = self.task.distinctPrompt {
                    PromptText(text: prompt, lineLimit: 1)
                }
                if let reply = self.task.reply {
                    ReplyText(text: reply, lineLimit: self.replyLineLimit)
                } else if !self.showsPrompt, let prompt = self.task.distinctPrompt {
                    PromptText(text: prompt, lineLimit: self.replyLineLimit)
                }
            }
        }
        .contentShape(Rectangle())
        if let url = self.task.openURL {
            Link(destination: url) { row }
        } else {
            row
        }
    }
}

/// Running tasks sit below the unread ones, one title each.
private struct RunningSectionView: View {
    let rows: [UnreadWidgetSnapshot.RunningItem]
    let hiddenCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.hiddenCount > 0 ? "Running · \(self.rows.count + self.hiddenCount)" : "Running")
                .font(.system(size: 10, weight: .semibold))
                .mutedForeground()
            ForEach(self.rows) { task in
                RunningRowView(task: task, extraCount: 0)
            }
        }
    }
}

private struct RunningRowView: View {
    let task: UnreadWidgetSnapshot.RunningItem
    let extraCount: Int

    var body: some View {
        let row = HStack(spacing: 6) {
            ZStack {
                MinuteRing(tint: ProviderIcon.tint(for: self.task.platform))
                    .frame(width: 16, height: 16)
                PlatformIconView(platform: self.task.platform, size: 8, showsUnreadDot: false)
            }
            Text(self.extraCount > 0 ? "\(self.task.title) +\(self.extraCount)" : self.task.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 4)
            ElapsedText(since: self.task.startedAt, isLive: true, tint: nil)
        }
        if let url = self.task.openURL {
            Link(destination: url) { row }
        } else {
            row
        }
    }
}

private struct ReplyText: View {
    let text: String
    let lineLimit: Int

    var body: some View {
        Text(self.text)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .lineLimit(self.lineLimit)
    }
}

/// The user's prompt, marked so it reads apart from the reply.
private struct PromptText: View {
    let text: String
    let lineLimit: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "person.fill")
                .font(.system(size: 8))
            Text(self.text)
                .font(.system(size: 10.5))
                .lineLimit(self.lineLimit)
        }
        .mutedForeground()
    }
}

/// A live elapsed timer keeps ticking between timeline reloads, which is the
/// motion WidgetKit allows. Older tasks show their date instead.
private struct ElapsedText: View {
    let since: Date?
    let isLive: Bool
    var tint: Color? = UnreadAccent.color
    /// Fixed so the ticking digits never shift the title beside them.
    var alignment: Alignment = .trailing

    var body: some View {
        if let since {
            if self.isLive, Date().timeIntervalSince(since) < 24 * 60 * 60 {
                let timer = Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(self.alignment == .leading ? .leading : .trailing)
                    .frame(width: 46, alignment: self.alignment)
                if let tint {
                    timer.foregroundStyle(tint)
                } else {
                    timer.mutedForeground()
                }
            } else {
                UpdatedAtText(date: since)
            }
        }
    }
}

/// How long the finished turn ran.
private struct TurnDurationText: View {
    let duration: TimeInterval?

    var body: some View {
        if let duration, duration >= 1 {
            HStack(spacing: 2) {
                Image(systemName: "timer")
                    .font(.system(size: 8, weight: .semibold))
                Text(UnreadTaskFormat.duration(duration))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize()
            .mutedForeground()
            .accessibilityLabel("Took \(UnreadTaskFormat.duration(duration))")
        }
    }
}

private enum UnreadAccent {
    static let color = Color(red: 1.0, green: 0.30, blue: 0.24)
}

private struct PlatformCountsView: View {
    let platforms: [UnreadWidgetSnapshot.Platform]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(self.platforms) { platform in
                HStack(spacing: 3) {
                    PlatformIconView(platform: platform.id, size: 11, showsUnreadDot: false)
                    Text("\(platform.unreadCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .mutedForeground(platform.unreadCount == 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(platform.name), \(platform.unreadCount) unread")
            }
        }
    }
}

private struct PlatformIconView: View {
    let platform: String
    let size: CGFloat
    let showsUnreadDot: Bool

    var body: some View {
        Group {
            if let image = ProviderIcon.image(for: self.platform) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.fill")
                    .resizable()
            }
        }
        .frame(width: self.size, height: self.size)
        .foregroundStyle(ProviderIcon.tint(for: self.platform))
        .widgetAccentable()
        .overlay(alignment: .topTrailing) {
            if self.showsUnreadDot {
                Circle()
                    .fill(UnreadAccent.color)
                    .frame(width: self.size * 0.5, height: self.size * 0.5)
                    .offset(x: self.size * 0.2, y: -self.size * 0.2)
            }
        }
    }
}

private struct UpdatedAtText: View {
    let date: Date?

    var body: some View {
        if let date {
            Group {
                if Calendar.current.isDateInToday(date) {
                    Text(date, format: .dateTime.hour().minute())
                } else {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                }
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .mutedForeground()
        }
    }
}

private struct CaughtUpLabel: View {
    var body: some View {
        Label("All caught up", systemImage: "checkmark.circle")
            .font(.system(size: 12, weight: .medium))
            .mutedForeground()
    }
}

private struct NoticeView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: self.symbol)
                .font(.system(size: 18, weight: .medium))
                .mutedForeground()
            Spacer(minLength: 0)
            Text(self.title)
                .font(.system(size: 12, weight: .semibold))
            Text(self.detail)
                .font(.system(size: 11))
                .mutedForeground()
                .lineLimit(3)
        }
    }
}

private enum ProviderIcon {
    @MainActor private static var cache: [String: NSImage] = [:]

    /// `package_app.sh` copies the menu bar's provider icons into the extension.
    @MainActor
    static func image(for platform: String) -> NSImage? {
        if let cached = self.cache[platform] {
            return cached
        }
        guard let url = Bundle.main.url(forResource: "ProviderIcon-\(platform)", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = true
        self.cache[platform] = image
        return image
    }

    static func tint(for platform: String) -> Color {
        switch platform {
        case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        default: .primary
        }
    }
}

/// Secondary text all but disappears once the desktop loses focus and macOS
/// draws widgets as tinted glass, so it keeps full strength there.
private struct MutedForeground: ViewModifier {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let isMuted: Bool

    func body(content: Content) -> some View {
        content.foregroundStyle(
            self.isMuted && self.renderingMode != .vibrant
                ? HierarchicalShapeStyle.secondary
                : .primary)
    }
}

private extension View {
    func mutedForeground(_ isMuted: Bool = true) -> some View {
        self.modifier(MutedForeground(isMuted: isMuted))
    }
}

private extension UnreadWidgetSnapshot {
    static let sample = UnreadWidgetSnapshot(
        isTracking: true,
        platforms: [
            Platform(id: "codex", name: "Codex", unreadCount: 2),
            Platform(id: "claude", name: "Claude", unreadCount: 1),
        ],
        tasks: [
            Item(
                platform: "claude",
                taskID: "sample-claude",
                title: "Add a desktop widget",
                prompt: "Show unread tasks on the desktop with a short summary of each prompt.",
                reply: "The widget now lists each unread task with its title, your last prompt, and the opening of the reply.",
                turnDuration: 252,
                workspaceName: "TokenBar",
                updatedAt: Date().addingTimeInterval(-300)),
            Item(
                platform: "codex",
                taskID: "sample-codex-1",
                title: "Fix weekly pace rounding",
                prompt: "The pace marker is off by one day after the weekly reset.",
                reply: "Fixed: the pace now counts days from the reset time instead of midnight, so Monday resets line up.",
                turnDuration: 48,
                workspaceName: "TokenBar",
                updatedAt: Date().addingTimeInterval(-1_800)),
            Item(
                platform: "codex",
                taskID: "sample-codex-2",
                title: "Review sync server logs",
                prompt: "Check why the Linux client stopped uploading yesterday.",
                reply: "Its token expired at 18:02; uploads resume after you sign in again on that machine.",
                turnDuration: 4_380,
                workspaceName: "Sync",
                updatedAt: Date().addingTimeInterval(-7_200)),
        ],
        running: [
            RunningItem(
                platform: "codex",
                taskID: "sample-codex-running",
                title: "Profile the activity helper",
                startedAt: Date().addingTimeInterval(-95)),
        ])
}
