import AppKit
import SwiftUI
import TokenBarCore

/// The desktop card's content: unread tasks with their replies, then running
/// tasks, tasks whose work runs on in the background, and the tasks read last,
/// laid out for the card's widget size so nothing scrolls or is cut off. While
/// anything is unread the card breathes with a soft red glow, and each running
/// task turns a ring.
struct DesktopCardView: View {
    enum DragPhase {
        case changed
        case ended
    }

    /// Room around the card for the glow, which a window would otherwise clip.
    static let glowRoom: CGFloat = 22
    /// The corner radius of macOS desktop widgets.
    static let cornerRadius: CGFloat = 27.88
    private static let padding: CGFloat = 14

    let state: DesktopCardState
    let open: (String, String) -> Void
    let drag: (DragPhase) -> Void
    let resize: (DragPhase) -> Void
    let setSize: (DesktopCardSize) -> Void
    let hide: () -> Void
    @State private var isHovered = false

    var body: some View {
        let snapshot = self.state.snapshot
        let size = self.state.points
        let inner = CGSize(width: size.width - Self.padding * 2, height: size.height - Self.padding * 2)
        // The rows are laid out for the size the card is heading to, while the
        // card itself follows its window as that resizes.
        self.content(snapshot, in: inner)
            .frame(width: inner.width, height: inner.height, alignment: .topLeading)
            .padding(Self.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            // `BreathingGlow` draws the drop shadow once in Core Animation; a
            // SwiftUI shadow would be re-rendered with every redraw.
            .modifier(CardSurface(shape: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)))
            .overlay {
                BreathingGlow(
                    cornerRadius: Self.cornerRadius,
                    inset: Self.glowRoom,
                    isActive: !snapshot.tasks.isEmpty,
                    animates: self.state.isVisible)
                    .padding(-Self.glowRoom)
            }
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip(resize: self.resize)
                    .opacity(self.isHovered ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .onHover { self.isHovered = $0 }
            .animation(.easeOut(duration: 0.2), value: self.isHovered)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in self.drag(.changed) }
                    .onEnded { _ in self.drag(.ended) })
            .contextMenu {
                Picker("Size", selection: Binding(get: { self.state.size }, set: self.setSize)) {
                    ForEach(DesktopCardSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Hide Desktop Card", action: self.hide)
            }
            .padding(Self.glowRoom)
    }

    private static let rowTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .move(edge: .top)),
        removal: .opacity)

    @ViewBuilder
    private func content(_ snapshot: UnreadWidgetSnapshot, in inner: CGSize) -> some View {
        switch self.state.size {
        case .small:
            self.smallContent(snapshot)
        case .medium:
            self.mediumContent(snapshot)
        case .large:
            VStack(alignment: .leading, spacing: CardMetrics.headerSpacing) {
                CardHeader(snapshot: snapshot, animates: self.state.isVisible)
                self.listContent(
                    snapshot,
                    height: inner.height - CardMetrics.headerHeight - CardMetrics.headerSpacing)
            }
        case .automatic, .extraLarge:
            VStack(alignment: .leading, spacing: CardMetrics.headerSpacing) {
                CardHeader(snapshot: snapshot, animates: self.state.isVisible)
                self.columnContent(
                    snapshot,
                    height: inner.height - CardMetrics.headerHeight - CardMetrics.headerSpacing,
                    showsUnread: inner.width > CardMetrics.columnWidth)
            }
        }
    }

    /// The count, then the newest unread task, with running tasks, or else
    /// background ones, summed up at the bottom.
    @ViewBuilder
    private func smallContent(_ snapshot: UnreadWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BreathingBadge(count: snapshot.unreadCount, animates: self.state.isVisible)
                Text("Unread")
                    .font(CardFont.sans(13, .semibold))
                    .foregroundStyle(snapshot.unreadCount > 0 ? .primary : .secondary)
            }
            if let task = snapshot.tasks.first {
                Button { self.open(task.platform, task.taskID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            UnreadPlatformIcon(platform: task.platform, size: 11)
                            CardTimeText(date: task.updatedAt)
                        }
                        Text(task.title)
                            .font(CardFont.sans(12, .semibold))
                            .lineLimit(snapshot.running.isEmpty && snapshot.background.isEmpty ? 3 : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Label("All caught up", systemImage: "checkmark.circle")
                    .font(CardFont.sans(12, .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            self.summaryRow(snapshot)
        }
    }

    /// Two short unread rows, or one and a running summary. With nothing
    /// unread, the tasks read last take their place.
    @ViewBuilder
    private func mediumContent(_ snapshot: UnreadWidgetSnapshot) -> some View {
        let limit = snapshot.running.isEmpty && snapshot.background.isEmpty ? 2 : 1
        let rows = Array(snapshot.tasks.prefix(limit))
        VStack(alignment: .leading, spacing: CardMetrics.headerSpacing) {
            CardHeader(snapshot: snapshot, animates: self.state.isVisible)
            if rows.isEmpty {
                if snapshot.recent.isEmpty {
                    CaughtUpRow()
                } else {
                    self.compactSection("Recently read", rows: Array(snapshot.recent.prefix(limit)), isUnread: false)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, task in
                    VStack(spacing: 0) {
                        if index > 0 {
                            Divider().padding(.leading, CardGrid.textInset)
                        }
                        UnreadCardRow(task: task, replyLines: 1, showsDetails: false) {
                            self.open(task.platform, task.taskID)
                        }
                    }
                    .transition(Self.rowTransition)
                }
            }
            Spacer(minLength: 0)
            self.summaryRow(snapshot)
        }
    }

    @ViewBuilder
    private func summaryRow(_ snapshot: UnreadWidgetSnapshot) -> some View {
        let isInBackground = snapshot.running.isEmpty
        let tasks = isInBackground ? snapshot.background : snapshot.running
        if let task = tasks.first {
            RunningSummaryRow(running: tasks, isInBackground: isInBackground, animates: self.state.isVisible) {
                self.open(task.platform, task.taskID)
            }
        }
    }

    /// Full unread rows, then the running tasks, the background ones, and the
    /// tasks read last, as many of each as fit.
    @ViewBuilder
    private func listContent(_ snapshot: UnreadWidgetSnapshot, height: CGFloat) -> some View {
        let fit = CardMetrics.fit(
            unread: snapshot.tasks.count,
            running: snapshot.running.count,
            background: snapshot.background.count,
            recent: snapshot.recent.count,
            height: height)
        VStack(alignment: .leading, spacing: CardMetrics.sectionGap) {
            if snapshot.tasks.isEmpty, snapshot.recent.isEmpty {
                CaughtUpRow()
            }
            if fit.unread > 0 {
                self.unreadRows(Array(snapshot.tasks.prefix(fit.unread)))
            }
            if fit.running > 0 {
                self.runningSection(snapshot.running, rows: fit.running, isInBackground: false)
            }
            if fit.background > 0 {
                self.runningSection(snapshot.background, rows: fit.background, isInBackground: true)
            }
            if fit.recent > 0 {
                self.compactSection("Recently read", rows: Array(snapshot.recent.prefix(fit.recent)), isUnread: false)
            }
        }
    }

    /// Running tasks, background ones, the unread titles without room for a
    /// full row, and the tasks read last in a column a medium widget wide, then
    /// the unread rows beside it while the card is wide enough. Sections later
    /// in the column give way first.
    @ViewBuilder
    private func columnContent(_ snapshot: UnreadWidgetSnapshot, height: CGFloat, showsUnread: Bool) -> some View {
        let unreadCount = showsUnread
            ? min(snapshot.tasks.count, CardMetrics.rows(fitting: height, rowHeight: CardMetrics.unreadRowHeight))
            : 0
        let more = Array(snapshot.tasks.dropFirst(unreadCount))
        let fit = CardMetrics.sections(
            [
                (snapshot.running.count, CardMetrics.runningRowHeight),
                (snapshot.background.count, CardMetrics.runningRowHeight),
                (more.count, CardMetrics.compactRowHeight),
                (snapshot.recent.count, CardMetrics.compactRowHeight),
            ],
            height: height)
        HStack(alignment: .top, spacing: CardMetrics.columnGap) {
            VStack(alignment: .leading, spacing: CardMetrics.sectionGap) {
                if snapshot.running.isEmpty, snapshot.background.isEmpty, more.isEmpty, snapshot.recent.isEmpty {
                    CaughtUpRow(isCaughtUp: snapshot.tasks.isEmpty)
                }
                if fit[0] > 0 {
                    self.runningSection(snapshot.running, rows: fit[0], isInBackground: false)
                }
                if fit[1] > 0 {
                    self.runningSection(snapshot.background, rows: fit[1], isInBackground: true)
                }
                if fit[2] > 0 {
                    self.compactSection("More unread", rows: Array(more.prefix(fit[2])), isUnread: true)
                }
                if fit[3] > 0 {
                    self.compactSection("Recently read", rows: Array(snapshot.recent.prefix(fit[3])), isUnread: false)
                }
            }
            .frame(width: CardMetrics.columnWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            if showsUnread {
                self.unreadRows(Array(snapshot.tasks.prefix(unreadCount)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func unreadRows(_ rows: [UnreadWidgetSnapshot.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, task in
                VStack(spacing: 0) {
                    if index > 0 {
                        Divider().padding(.leading, CardGrid.textInset)
                    }
                    UnreadCardRow(task: task, replyLines: 2, showsDetails: true) {
                        self.open(task.platform, task.taskID)
                    }
                }
                .transition(Self.rowTransition)
            }
        }
    }

    @ViewBuilder
    private func compactSection(
        _ title: String,
        rows: [UnreadWidgetSnapshot.Item],
        isUnread: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: title)
            ForEach(rows) { task in
                CompactTaskRow(task: task, isUnread: isUnread) {
                    self.open(task.platform, task.taskID)
                }
                .transition(Self.rowTransition)
            }
        }
    }

    @ViewBuilder
    private func runningSection(
        _ tasks: [UnreadWidgetSnapshot.RunningItem],
        rows: Int,
        isInBackground: Bool) -> some View
    {
        let title = isInBackground ? "Background" : "Running"
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: tasks.count > rows ? "\(title) · \(tasks.count)" : title)
            ForEach(tasks.prefix(rows)) { task in
                RunningCardRow(task: task, isInBackground: isInBackground, animates: self.state.isVisible) {
                    self.open(task.platform, task.taskID)
                }
                .transition(Self.rowTransition)
            }
        }
    }
}

/// Fixed row heights, so each widget size shows only whole rows.
private enum CardMetrics {
    static let headerHeight: CGFloat = 26
    static let headerSpacing: CGFloat = 8
    /// A title, two reply lines, the prompt and project line, and a divider.
    static let unreadRowHeight: CGFloat = 86
    /// A title and what the task is doing.
    static let runningRowHeight: CGFloat = 40
    static let compactRowHeight: CGFloat = 28
    static let sectionLabelHeight: CGFloat = 18
    static let sectionGap: CGFloat = 10
    static let caughtUpHeight: CGFloat = 28
    /// A medium widget's width inside the card's padding, so the column keeps
    /// its width when the card widens beside it.
    static let columnWidth: CGFloat = 316
    static let columnGap: CGFloat = 28

    static func rows(fitting height: CGFloat, rowHeight: CGFloat) -> Int {
        max(0, Int(height / rowHeight))
    }

    static func sectionHeight(rows: Int, rowHeight: CGFloat) -> CGFloat {
        self.sectionLabelHeight + CGFloat(rows) * rowHeight
    }

    /// Splits the height between unread rows, the running and background
    /// sections, and the tasks read last. Unread rows come first, but up to two
    /// running rows always keep their place.
    static func fit(
        unread: Int,
        running: Int,
        background: Int,
        recent: Int,
        height: CGFloat) -> (unread: Int, running: Int, background: Int, recent: Int)
    {
        let reservedRunning = min(running, 2)
        let runningSpace = reservedRunning > 0
            ? self.sectionGap + self.sectionHeight(rows: reservedRunning, rowHeight: self.runningRowHeight)
            : 0
        let unreadRows = min(unread, self.rows(fitting: height - runningSpace, rowHeight: self.unreadRowHeight))
        let used = unread == 0 && recent == 0
            ? self.caughtUpHeight
            : CGFloat(unreadRows) * self.unreadRowHeight
        let sections = self.sections(
            [
                (running, self.runningRowHeight),
                (background, self.runningRowHeight),
                (recent, self.compactRowHeight),
            ],
            height: height,
            used: used)
        return (unreadRows, sections[0], sections[1], sections[2])
    }

    /// How many rows of each titled section fit below `used`, in order.
    static func sections(
        _ sections: [(count: Int, rowHeight: CGFloat)],
        height: CGFloat,
        used: CGFloat = 0) -> [Int]
    {
        var used = used
        return sections.map { section in
            guard section.count > 0 else { return 0 }
            let gap = used > 0 ? self.sectionGap : 0
            let rows = min(
                section.count,
                self.rows(fitting: height - used - gap - self.sectionLabelHeight, rowHeight: section.rowHeight))
            if rows > 0 {
                used += gap + self.sectionHeight(rows: rows, rowHeight: section.rowHeight)
            }
            return rows
        }
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(CardFont.sans(11, .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, CardGrid.textInset)
            .frame(height: CardMetrics.sectionLabelHeight, alignment: .leading)
    }
}

private struct CaughtUpRow: View {
    /// False when tasks are unread but none runs.
    var isCaughtUp = true

    var body: some View {
        HStack(spacing: CardGrid.spacing) {
            Image(systemName: self.isCaughtUp ? "checkmark.circle" : "pause.circle")
                .frame(width: CardGrid.iconColumn)
            Text(self.isCaughtUp ? "All caught up" : "Nothing running")
        }
        .font(CardFont.sans(12, .medium))
        .foregroundStyle(.secondary)
        .frame(height: CardMetrics.caughtUpHeight)
    }
}

/// The first running task's title with a spinning ring, and how many more run.
private struct RunningSummaryRow: View {
    let running: [UnreadWidgetSnapshot.RunningItem]
    let isInBackground: Bool
    let animates: Bool
    let action: () -> Void

    var body: some View {
        if let first = self.running.first {
            Button(action: self.action) {
                HStack(spacing: 6) {
                    ZStack {
                        SpinningRing(
                            tint: CardAccent.ringTint(for: first.platform, isInBackground: self.isInBackground),
                            animates: self.animates)
                            .frame(width: 18, height: 18)
                        CardPlatformIcon(platform: first.platform, size: 12)
                    }
                    Text(first.title)
                        .font(CardFont.sans(11))
                        .lineLimit(1)
                    if self.running.count > 1 {
                        Text("+\(self.running.count - 1)")
                            .font(CardFont.sans(11, .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// An unread task beyond the full rows, or a task read last: its icon, title,
/// and when the reply came.
private struct CompactTaskRow: View {
    let task: UnreadWidgetSnapshot.Item
    let isUnread: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: CardGrid.spacing) {
                Group {
                    if self.isUnread {
                        UnreadPlatformIcon(platform: self.task.platform, size: 12)
                    } else {
                        CardPlatformIcon(platform: self.task.platform, size: 12)
                    }
                }
                .frame(width: CardGrid.iconColumn)
                Text(self.task.title)
                    .font(CardFont.sans(12))
                    .foregroundStyle(self.isUnread ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                CardTimeText(date: self.task.updatedAt)
            }
            .frame(height: CardMetrics.compactRowHeight)
            .modifier(RowHighlight(isHovered: self.isHovered))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: self.isHovered)
    }
}

/// A platform icon with the red unread dot.
private struct UnreadPlatformIcon: View {
    let platform: String
    let size: CGFloat

    var body: some View {
        CardPlatformIcon(platform: self.platform, size: self.size)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(CardAccent.unread)
                    .frame(width: self.size * 0.5, height: self.size * 0.5)
                    .offset(x: self.size * 0.2, y: -self.size * 0.2)
            }
    }
}

/// Drags the card's bottom-right corner to resize it.
private struct ResizeGrip: View {
    let resize: (DesktopCardView.DragPhase) -> Void

    var body: some View {
        Canvas { context, size in
            for offset in [4.0, 8.0, 12.0] {
                var line = Path()
                line.move(to: CGPoint(x: size.width - offset, y: size.height - 2))
                line.addLine(to: CGPoint(x: size.width - 2, y: size.height - offset))
                context.stroke(line, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .frame(width: 18, height: 18)
        .padding(5)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in self.resize(.changed) }
                .onEnded { _ in self.resize(.ended) })
        .help("Drag to resize")
    }
}

/// Every row puts its badge, icon, or ring in one column and starts its text
/// at the same edge after it.
private enum CardGrid {
    static let iconColumn: CGFloat = 26
    static let spacing: CGFloat = 9
    static var textInset: CGFloat {
        self.iconColumn + self.spacing
    }

    /// Room a hover highlight extends past the rows without moving them.
    static let highlightOutset: CGFloat = 6
}

/// A highlight behind a hovered row that reaches past the row's edges, so the
/// row's contents stay on the card's grid.
private struct RowHighlight: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, CardGrid.highlightOutset)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(self.isHovered ? 0.06 : 0)))
            .padding(.horizontal, -CardGrid.highlightOutset)
            .contentShape(Rectangle())
    }
}

/// The unread count, then what each agent used today. The usage drops its
/// last figures first when the card is too narrow.
private struct CardHeader: View {
    let snapshot: UnreadWidgetSnapshot
    let animates: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CardGrid.spacing) {
            BreathingBadge(count: self.snapshot.unreadCount, animates: self.animates)
            Text("Unread")
                .font(CardFont.sans(13, .semibold))
                .foregroundStyle(self.snapshot.unreadCount > 0 ? .primary : .secondary)
                .fixedSize()
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                self.usage(figures: 4)
                self.usage(figures: 3)
                self.usage(figures: 2)
                self.usage(figures: 1)
            }
        }
    }

    /// Every piece of text shares one size and baseline; each icon sits on
    /// the same line, centered on the digits.
    private func usage(figures: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ForEach(self.snapshot.platforms) { platform in
                if let today = platform.today {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        CardPlatformIcon(platform: platform.id, size: 12)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.7 }
                            .padding(.trailing, 2)
                        ForEach(Array(today.figures.prefix(figures).enumerated()), id: \.offset) { index, figure in
                            if index > 0 {
                                Text("·").foregroundStyle(.tertiary)
                            }
                            Text(figure)
                        }
                    }
                    .help("\(platform.name) today: \(today.summary)")
                }
            }
        }
        .foregroundStyle(.secondary)
        .font(CardFont.sans(12))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

extension UnreadWidgetSnapshot.Usage {
    /// Tokens, cost, the weekly quota used today, and generation speed, with
    /// whole dollars from $10 on.
    var figures: [String] {
        var figures = [self.tokens.statusBarCompactCount]
        if self.costUsd > 0 {
            figures.append(self.costUsd < 10 ? self.costUsd.usdText : Self.wholeDollarText(self.costUsd))
        }
        if let quota = self.weeklyQuotaUsedToday {
            figures.append("+\(Self.percentText(quota))")
        }
        if let speed = self.tokensPerSecond {
            figures.append("\(Int(speed.rounded())) tps")
        }
        return figures
    }

    var summary: String {
        var parts = ["\(self.tokens.formatted()) tokens"]
        if self.costUsd > 0 {
            parts.append(self.costUsd.usdText)
        }
        if let quota = self.weeklyQuotaUsedToday {
            parts.append("\(Self.percentText(quota)) of the weekly quota")
        }
        if let speed = self.tokensPerSecond {
            parts.append("\(Int(speed.rounded())) tokens/s")
        }
        return parts.joined(separator: " · ")
    }

    private static func wholeDollarText(_ amount: Double) -> String {
        amount >= 1_000
            ? String(format: "$%.1fK", locale: Locale(identifier: "en_US_POSIX"), amount / 1_000)
            : String(format: "$%.0f", locale: Locale(identifier: "en_US_POSIX"), amount)
    }

    private static func percentText(_ points: Double) -> String {
        String(
            format: points < 10 ? "%.1f%%" : "%.0f%%",
            locale: Locale(identifier: "en_US_POSIX"),
            max(0, points))
    }
}

/// The title and when the reply came, then the reply itself, then what the
/// user asked with the project and how long the turn ran.
private struct UnreadCardRow: View {
    let task: UnreadWidgetSnapshot.Item
    let replyLines: Int
    let showsDetails: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(alignment: .top, spacing: CardGrid.spacing) {
                UnreadPlatformIcon(platform: self.task.platform, size: 14)
                    .padding(.top, 2)
                    .frame(width: CardGrid.iconColumn)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(self.task.title)
                            .font(CardFont.sans(13, .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        CardTimeText(date: self.task.updatedAt)
                    }
                    if let reply = self.task.reply {
                        Text(reply)
                            .font(CardFont.sans(12))
                            .foregroundStyle(.primary)
                            .lineLimit(self.replyLines)
                    }
                    if self.showsDetails {
                        self.details
                    }
                }
            }
            .padding(.vertical, 8)
            .modifier(RowHighlight(isHovered: self.isHovered))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: self.isHovered)
    }

    @ViewBuilder
    private var details: some View {
        let duration = self.task.turnDuration.flatMap { $0 >= 1 ? UnreadTaskFormat.duration($0) : nil }
        if self.task.distinctPrompt != nil || self.task.workspaceName != nil || duration != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let prompt = self.task.distinctPrompt {
                    Label(prompt, systemImage: "person.fill")
                        .labelStyle(CompactLabelStyle())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let workspace = self.task.workspaceName {
                    Text(workspace)
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .trailing)
                        .fixedSize(horizontal: self.task.distinctPrompt == nil, vertical: false)
                }
                if let duration {
                    Label(duration, systemImage: "timer")
                        .labelStyle(CompactLabelStyle())
                        .fixedSize()
                }
            }
            .font(CardFont.sans(10.5))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

private struct RunningCardRow: View {
    let task: UnreadWidgetSnapshot.RunningItem
    let isInBackground: Bool
    let animates: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: CardGrid.spacing) {
                ZStack {
                    SpinningRing(
                        tint: CardAccent.ringTint(for: self.task.platform, isInBackground: self.isInBackground),
                        animates: self.animates)
                        .frame(width: 20, height: 20)
                    CardPlatformIcon(platform: self.task.platform, size: 14)
                }
                .frame(width: CardGrid.iconColumn)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(self.task.title)
                            .font(CardFont.sans(12))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let startedAt = self.task.startedAt {
                            ElapsedMinutesText(since: startedAt)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let activity = self.task.activity {
                        Text(activity)
                            .font(CardFont.sans(10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(height: CardMetrics.runningRowHeight)
            .modifier(RowHighlight(isHovered: self.isHovered))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: self.isHovered)
    }
}

/// Elapsed time in whole minutes, such as `now`, `12m`, or `1h 5m`. Redrawing
/// the card once a minute instead of every second keeps it nearly idle.
private struct ElapsedMinutesText: View {
    let since: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            // The schedule's date is the start of the minute, which can trail now.
            let minutes = max(0, Int(max(context.date, Date()).timeIntervalSince(self.since) / 60))
            Text(minutes == 0 ? "now" : UnreadTaskFormat.duration(TimeInterval(minutes * 60)))
                .font(CardFont.sans(11))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// When the reply arrived: `now`, `5m ago`, `3h ago`, or a date before that.
private struct CardTimeText: View {
    let date: Date?

    var body: some View {
        if let date {
            TimelineView(.everyMinute) { context in
                let minutes = Int(max(context.date, Date()).timeIntervalSince(date) / 60)
                Group {
                    if minutes < 1 {
                        Text("now")
                    } else if minutes < 60 {
                        Text("\(minutes)m ago")
                    } else if minutes < 24 * 60 {
                        Text("\(minutes / 60)h ago")
                    } else {
                        Text(date, format: .dateTime.month(.abbreviated).day())
                    }
                }
                .font(CardFont.sans(11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            }
        }
    }
}

// MARK: Animation

/// Core Animation runs these loops in the window server, so an always-on card
/// costs TokenBar no redraws. Each loop stops while the card is hidden.
private struct BreathingBadge: View {
    let count: Int
    let animates: Bool

    var body: some View {
        let isUnread = self.count > 0
        Text(self.count > 99 ? "99+" : "\(self.count)")
            .font(CardFont.sans(14, .bold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(self.count)))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(isUnread ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 26, height: 26)
            .background {
                if isUnread {
                    ZStack {
                        PulseRings(color: NSColor(CardAccent.unread), animates: self.animates)
                            .frame(width: 26, height: 26)
                        Circle().fill(CardAccent.unread)
                    }
                }
            }
    }
}

/// A faint ring that slowly expands out of the badge and fades away.
private struct PulseRings: NSViewRepresentable {
    let color: NSColor
    let animates: Bool

    func makeNSView(context: Context) -> PulseRingsView {
        PulseRingsView()
    }

    func updateNSView(_ view: PulseRingsView, context: Context) {
        view.color = self.color
        view.animates = self.animates
    }
}

private final class PulseRingsView: NSView {
    private static let period: CFTimeInterval = 3.2
    private let rings = [CAShapeLayer()]

    var color = NSColor.systemRed {
        didSet { self.needsLayout = true }
    }

    var animates = false {
        didSet {
            guard self.animates != oldValue else { return }
            self.needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        for ring in self.rings {
            ring.fillColor = nil
            ring.lineWidth = 1.5
            ring.opacity = 0
            self.layer?.addSublayer(ring)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        for (index, ring) in self.rings.enumerated() {
            ring.frame = self.bounds
            ring.path = CGPath(ellipseIn: self.bounds, transform: nil)
            ring.strokeColor = self.color.cgColor
            guard self.animates else {
                ring.removeAllAnimations()
                continue
            }
            guard ring.animation(forKey: "pulse") == nil else { continue }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 1.45
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.35
            fade.toValue = 0
            let pulse = CAAnimationGroup()
            pulse.animations = [scale, fade]
            pulse.duration = Self.period
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulse.beginTime = CACurrentMediaTime() + Self.period / 2 * Double(index)
            ring.add(pulse, forKey: "pulse")
        }
    }
}

/// The card's soft drop shadow, plus a red border and glow that breathe while
/// anything is unread. The view is larger than the card by `inset` on every
/// side, so neither is clipped.
private struct BreathingGlow: NSViewRepresentable {
    let cornerRadius: CGFloat
    let inset: CGFloat
    let isActive: Bool
    let animates: Bool

    func makeNSView(context: Context) -> BreathingGlowView {
        BreathingGlowView()
    }

    func updateNSView(_ view: BreathingGlowView, context: Context) {
        view.cornerRadius = self.cornerRadius
        view.inset = self.inset
        view.isActive = self.isActive
        view.animates = self.animates
        view.needsLayout = true
    }
}

private final class BreathingGlowView: NSView {
    private static let period: CFTimeInterval = 3
    private let dropShadow = CAShapeLayer()
    private let dropShadowMask = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let glowMask = CAShapeLayer()
    private let border = CAShapeLayer()

    var cornerRadius: CGFloat = 18
    var inset: CGFloat = 22
    var isActive = false
    var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        // Both shadows come from the card's shape and are masked to the outside
        // of the card, so they never tint its contents.
        self.dropShadow.shadowColor = NSColor.black.cgColor
        self.dropShadow.shadowOpacity = 0.18
        self.dropShadow.shadowRadius = 10
        self.dropShadow.shadowOffset = CGSize(width: 0, height: -4)
        self.glow.shadowOffset = .zero
        self.glow.shadowRadius = 8
        for mask in [self.dropShadowMask, self.glowMask] {
            mask.fillRule = .evenOdd
            mask.fillColor = NSColor.black.cgColor
        }
        self.dropShadow.mask = self.dropShadowMask
        self.glow.mask = self.glowMask
        self.border.fillColor = nil
        self.border.lineWidth = 1
        self.layer?.addSublayer(self.dropShadow)
        self.layer?.addSublayer(self.glow)
        self.layer?.addSublayer(self.border)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let card = self.bounds.insetBy(dx: self.inset, dy: self.inset)
        let path = CGPath(
            roundedRect: card,
            cornerWidth: self.cornerRadius,
            cornerHeight: self.cornerRadius,
            transform: nil)
        let red = NSColor(CardAccent.unread).cgColor
        let outside = CGMutablePath()
        outside.addRect(self.bounds)
        outside.addPath(path)
        for (layer, mask) in [(self.dropShadow, self.dropShadowMask), (self.glow, self.glowMask)] {
            layer.frame = self.bounds
            layer.shadowPath = path
            mask.frame = self.bounds
            mask.path = outside
        }
        self.glow.shadowColor = red
        self.border.frame = self.bounds
        self.border.path = CGPath(
            roundedRect: card.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: self.cornerRadius - 0.75,
            cornerHeight: self.cornerRadius - 0.75,
            transform: nil)
        // The card draws its own hairline while nothing is unread.
        self.border.strokeColor = self.isActive ? red : nil

        guard self.isActive else {
            self.glow.shadowOpacity = 0
            self.border.opacity = 1
            self.glow.removeAllAnimations()
            self.border.removeAllAnimations()
            return
        }
        self.glow.shadowOpacity = 0.15
        self.border.opacity = 0.35
        guard self.animates else {
            self.glow.removeAllAnimations()
            self.border.removeAllAnimations()
            return
        }
        if self.glow.animation(forKey: "breath") == nil {
            self.glow.add(Self.breath(keyPath: "shadowOpacity", from: 0.05, to: 0.25), forKey: "breath")
            self.border.add(Self.breath(keyPath: "opacity", from: 0.2, to: 0.5), forKey: "breath")
        }
    }

    private static func breath(keyPath: String, from: Float, to: Float) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = self.period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}

/// A short, faint arc that slowly turns around a running task's icon, quieter
/// than the unread glow.
private struct SpinningRing: NSViewRepresentable {
    let tint: Color
    let animates: Bool

    func makeNSView(context: Context) -> SpinningRingView {
        SpinningRingView()
    }

    func updateNSView(_ view: SpinningRingView, context: Context) {
        view.tint = NSColor(self.tint)
        view.animates = self.animates
        view.needsLayout = true
    }
}

private final class SpinningRingView: NSView {
    private let arc = CAShapeLayer()

    var tint = NSColor.labelColor
    var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.arc.fillColor = nil
        self.arc.lineWidth = 1.5
        self.arc.lineCap = .round
        self.arc.strokeStart = 0
        self.arc.strokeEnd = 0.3
        self.arc.opacity = 0.55
        self.layer?.addSublayer(self.arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        self.arc.frame = self.bounds
        self.arc.path = CGPath(ellipseIn: self.bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        // Resolve dynamic colors for the card's light or dark appearance.
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.arc.strokeColor = self.tint.cgColor
        }
        guard self.animates else {
            self.arc.removeAllAnimations()
            return
        }
        guard self.arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 3
        spin.repeatCount = .infinity
        self.arc.add(spin, forKey: "spin")
    }
}

// MARK: Pieces

/// Liquid Glass over the desktop, tinted with the window color so the
/// wallpaper shows through only faintly, or a thick material on systems
/// without it. The glass stays behind the content: content inside it takes
/// its colors from the wallpaper and can become hard to read.
private struct CardSurface: ViewModifier {
    /// How strongly the window color covers the glass.
    private static let tintOpacity = 0.7

    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background {
                Color.clear.glassEffect(
                    .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(Self.tintOpacity)),
                    in: self.shape)
            }
        } else {
            content.background {
                ZStack {
                    self.shape.fill(.thickMaterial)
                    self.shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
        }
    }
}

/// Anthropic Sans from the app's resources, or the system font in a build
/// without it. The font is not open source, so the repository leaves it out
/// and a local copy is bundled at build time. The text cut of each weight
/// suits the card's small sizes.
@MainActor
enum CardFont {
    private static let isAvailable: Bool = {
        guard let file = PlatformStatusIcon.resourceBundle.url(forResource: "AnthropicSans", withExtension: "ttf") else {
            return false
        }
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        return NSFont(name: "AnthropicSansVariable-TextRegular", size: 12) != nil
    }()

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard self.isAvailable else { return .system(size: size, weight: weight) }
        let style = switch weight {
        case .ultraLight, .thin, .light: "Light"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        case .heavy, .black: "Extrabold"
        default: "Regular"
        }
        return .custom("AnthropicSansVariable-Text\(style)", fixedSize: size)
    }
}

private struct CardPlatformIcon: View {
    let platform: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image = PlatformStatusIcon.image(for: TokenPlatform(rawValue: self.platform)) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.fill")
                    .resizable()
            }
        }
        .frame(width: self.size, height: self.size)
        .foregroundStyle(CardAccent.tint(for: self.platform))
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            configuration.icon
                .font(CardFont.sans(8, .semibold))
            configuration.title
        }
    }
}

private enum CardAccent {
    static let unread = Color(red: 1.0, green: 0.30, blue: 0.24)

    static func tint(for platform: String) -> Color {
        platform == TokenPlatform.claude.rawValue
            ? Color(red: 0.85, green: 0.47, blue: 0.34)
            : .primary
    }

    /// Work left in the background turns a muted ring.
    static func ringTint(for platform: String, isInBackground: Bool) -> Color {
        isInBackground ? Color(nsColor: .tertiaryLabelColor) : self.tint(for: platform)
    }
}
