import AppKit
import SwiftUI
import TokenBarCore

/// Activity summaries cover a single statistics day, not the session's lifetime.
struct DesktopSessionInfo {
    let platform: TokenPlatform
    let taskID: String
    let sessionID: String
    let session: SessionSummary?
    let usageDate: String?

    init(
        platform: TokenPlatform,
        taskID: String,
        sessions: [SessionSummary],
        usageDate: String?,
        resolveClaudeSession: (String) -> String? = {
            ClaudeDesktopSessionResolver().cliSessionID(for: $0)
        })
    {
        self.platform = platform
        self.taskID = taskID
        let sessionID = platform == .claude ? resolveClaudeSession(taskID) ?? taskID : taskID
        let candidates = sessions.filter { $0.platformID == platform && !$0.isSynchronizedRemote }
        self.session = candidates.first { $0.id == sessionID }
            ?? candidates.first {
                platform == .codex && UUID(uuidString: taskID) != nil
                    && $0.id.hasSuffix("-\(taskID)")
            }
        self.sessionID = self.session?.id ?? sessionID
        self.usageDate = usageDate
    }

    var copyText: String {
        self.session?.tokscaleCopyText ?? "provider=\(self.platform.rawValue) session_id=\(self.sessionID)"
    }
}

struct DesktopSessionPresentation {
    enum StatusKind {
        case unread
        case running
        case background
        case interrupted
        case recent
    }

    let title: String
    let statusLabel: String
    let statusKind: StatusKind
    let info: DesktopSessionInfo
    let workspaceName: String?
    let liveNote: String?
    let timestamp: Date?
    let turnDuration: TimeInterval?

    var resolvedWorkspaceName: String? {
        self.info.session?.workspaceLabel ?? self.workspaceName
    }

    var resolvedWorkspacePath: String? {
        self.info.session?.workspacePath
    }
}

@MainActor
enum DesktopSessionMenuBuilder {
    static func makeMenu(for presentation: DesktopSessionPresentation) -> NSMenu {
        let menu = SessionContextNSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = DesktopSessionMenuCardView.preferredWidth

        menu.addActionItem(
            title: "Copy Session",
            systemImageName: "doc.on.doc")
        {
            Self.copy(presentation.info.copyText)
        }
        menu.addActionItem(
            title: "Copy Session ID",
            systemImageName: "number")
        {
            Self.copy(presentation.info.sessionID)
        }
        if let path = presentation.resolvedWorkspacePath {
            menu.addActionItem(
                title: "Copy Project Path",
                systemImageName: "folder")
            {
                Self.copy(path)
            }
        }

        menu.addItem(.separator())

        let cardItem = NSMenuItem()
        cardItem.isEnabled = true
        let card = DesktopSessionMenuCardView(
            presentation: presentation,
            accentColor: TokenBarSettings.shared.theme.color)
        cardItem.view = SessionMenuHostingView(
            rootView: card,
            width: DesktopSessionMenuCardView.preferredWidth)
        menu.addItem(cardItem)
        return menu
    }

    static func makeSummaryMenu(
        tasks: [UnreadWidgetSnapshot.RunningItem],
        isInBackground: Bool,
        sessionInfo: (String, String) -> DesktopSessionInfo) -> NSMenu
    {
        if tasks.count == 1, let task = tasks.first {
            return self.makeMenu(for: Self.presentation(
                for: task,
                isInBackground: isInBackground,
                info: sessionInfo(task.platform, task.taskID)))
        }

        let menu = SessionContextNSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: isInBackground ? "Background Tasks" : "Running Tasks"))

        for task in tasks {
            let platform = TokenPlatform(rawValue: task.platform)
            let title = task.title.menuTruncated(to: 44)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = true
            if let icon = PlatformStatusIcon.image(for: platform)?.copy() as? NSImage {
                icon.size = NSSize(width: 14, height: 14)
                icon.isTemplate = true
                item.image = icon
            }
            item.submenu = self.makeMenu(for: Self.presentation(
                for: task,
                isInBackground: isInBackground,
                info: sessionInfo(task.platform, task.taskID)))
            menu.addItem(item)
        }
        return menu
    }

    static func presentation(
        for task: UnreadWidgetSnapshot.Item,
        isUnread: Bool,
        info: DesktopSessionInfo) -> DesktopSessionPresentation
    {
        let liveNote: String? = if let ask = task.askQuestion {
            "Waiting for reply · \(ask)"
        } else if let bg = task.backgroundActivity {
            "Background · \(bg)"
        } else {
            nil
        }
        return DesktopSessionPresentation(
            title: task.title,
            statusLabel: isUnread ? "Unread" : "Recently read",
            statusKind: isUnread ? .unread : .recent,
            info: info,
            workspaceName: task.workspaceName,
            liveNote: liveNote,
            timestamp: task.updatedAt,
            turnDuration: task.turnDuration)
    }

    static func presentation(
        for task: UnreadWidgetSnapshot.RunningItem,
        isInBackground: Bool,
        info: DesktopSessionInfo) -> DesktopSessionPresentation
    {
        let statusLabel: String
        let statusKind: DesktopSessionPresentation.StatusKind
        if task.isInterrupted {
            statusLabel = "Interrupted"
            statusKind = .interrupted
        } else if isInBackground {
            statusLabel = "Background"
            statusKind = .background
        } else {
            statusLabel = "Running"
            statusKind = .running
        }
        return DesktopSessionPresentation(
            title: task.title,
            statusLabel: statusLabel,
            statusKind: statusKind,
            info: info,
            workspaceName: nil,
            liveNote: task.activity,
            timestamp: task.startedAt,
            turnDuration: nil)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - AppKit Menu & Anchor

final class SessionContextNSMenu: NSMenu {
    private var handlers: [() -> Void] = []

    func addActionItem(title: String, systemImageName: String, handler: @escaping () -> Void) {
        let index = self.handlers.count
        self.handlers.append(handler)
        let item = NSMenuItem(title: title, action: #selector(self.performIndexedAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = index
        item.image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
        self.addItem(item)
    }

    @objc private func performIndexedAction(_ sender: NSMenuItem) {
        let index = sender.tag
        guard self.handlers.indices.contains(index) else { return }
        self.handlers[index]()
    }
}

final class SessionContextMenuAnchorView: NSView {
    var menuBuilder: (() -> NSMenu)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct SessionContextMenuAnchor: NSViewRepresentable {
    let menuBuilder: () -> NSMenu

    func makeNSView(context: Context) -> SessionContextMenuAnchorView {
        let view = SessionContextMenuAnchorView()
        view.menuBuilder = self.menuBuilder
        return view
    }

    func updateNSView(_ view: SessionContextMenuAnchorView, context: Context) {
        view.menuBuilder = self.menuBuilder
    }
}

private final class SessionMenuHostingView<Content: View>: NSHostingView<Content> {
    private let fixedSize: NSSize

    init(rootView: Content, width: CGFloat) {
        self.fixedSize = Self.measuredSize(for: rootView, width: width)
        super.init(rootView: rootView)
        self.sizingOptions = []
        self.frame = NSRect(origin: .zero, size: self.fixedSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    required init(rootView: Content) {
        self.fixedSize = .zero
        super.init(rootView: rootView)
    }

    override var allowsVibrancy: Bool { true }

    override var intrinsicContentSize: NSSize {
        self.fixedSize
    }

    private static func measuredSize(for rootView: Content, width: CGFloat) -> NSSize {
        let probe = NSHostingView(rootView: rootView.frame(width: width, alignment: .topLeading))
        probe.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        probe.layoutSubtreeIfNeeded()
        let height = ceil(probe.fittingSize.height)
        return NSSize(width: width, height: max(1, height))
    }
}

// MARK: - Rich Menu Card View

private struct DesktopSessionMenuCardView: View {
    static let preferredWidth: CGFloat = 320

    let presentation: DesktopSessionPresentation
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.headerBlock
            if let session = self.presentation.info.session {
                self.usagePanel(session)
            } else {
                self.emptyUsagePanel
            }
            self.sessionIDFooter
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: Self.preferredWidth, alignment: .topLeading)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                self.platformBadge
                self.statusPill
                Spacer(minLength: 4)
                if let tierBadge = self.presentation.info.session?.menuServiceTierBadge {
                    self.tierBadgeView(tierBadge)
                }
                if let timeText = self.headerTimeText {
                    Text(timeText)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(self.presentation.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if self.hasMetadataLine {
                HStack(spacing: 10) {
                    if let workspace = self.presentation.resolvedWorkspaceName {
                        Label(workspace, systemImage: "folder")
                            .lineLimit(1)
                    }
                    if let model = self.presentation.info.session?.menuModelText {
                        Label(model, systemImage: "cpu")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .labelStyle(MenuInlineLabelStyle())
            }

            if let liveNote = self.presentation.liveNote?.trimmingCharacters(in: .whitespacesAndNewlines),
               !liveNote.isEmpty
            {
                HStack(spacing: 5) {
                    Image(systemName: self.presentation.statusKind == .unread ? "questionmark.circle" : "waveform")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(self.statusColor)
                    Text(liveNote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(self.statusColor.opacity(0.09))
                }
            }
        }
    }

    private var platformBadge: some View {
        let platform = self.presentation.info.platform
        return HStack(spacing: 4) {
            if let image = PlatformStatusIcon.image(for: platform) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                    .foregroundStyle(self.platformTint)
            }
            Text(platform.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(self.statusColor)
                .frame(width: 5, height: 5)
            Text(self.presentation.statusLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(self.statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            Capsule(style: .continuous)
                .fill(self.statusColor.opacity(0.12))
        }
    }

    private func tierBadgeView(_ text: String) -> some View {
        let accent = Color(nsColor: TokenBarVisualStyle.tierBadgeAccentNSColor)
        return Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(accent.opacity(0.3), lineWidth: 0.5)
                    }
            }
    }

    private func usagePanel(_ session: SessionSummary) -> some View {
        let subagentCount = self.subagentRequestCount(in: session)
        let turnsSummary = subagentCount > 0
            ? "\(session.requestCount) turns · \(subagentCount) subagents"
            : "\(session.requestCount) \(session.requestCount == 1 ? "turn" : "turns")"

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                DashboardSectionLabel(title: self.presentation.info.usageDate.map { "Usage · \($0)" } ?? "Recorded usage")
                Spacer(minLength: 6)
                Text(turnsSummary)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                SessionMetricTile(
                    label: "Spent",
                    value: session.menuCostText ?? session.costUsd.costText(tokenTotal: session.tokens.total))
                SessionMetricTile(
                    label: "Tokens",
                    value: session.tokens.total.compactCount)
                SessionMetricTile(
                    label: "Cache hit",
                    value: session.tokens.cachePercentageText)
            }

            VStack(alignment: .leading, spacing: 7) {
                TokenStackedBar(tokens: session.tokens)
                    .frame(height: 5)
                self.tokenBreakdownGrid(session.tokens)
            }

            if let context = session.context, context.promptTokens > 0 {
                self.contextBar(context)
            }

            if self.hasPerformanceFooter(session) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                self.performanceFooter(session)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
    }

    private func tokenBreakdownGrid(_ tokens: TokenBreakdown) -> some View {
        let items = self.tokenRows(for: tokens)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(0 ..< (items.count + 1) / 2, id: \.self) { rowIndex in
                let left = items[rowIndex * 2]
                let right = rowIndex * 2 + 1 < items.count ? items[rowIndex * 2 + 1] : nil
                HStack(spacing: 12) {
                    self.tokenLegendRow(left)
                    if let right {
                        self.tokenLegendRow(right)
                    } else {
                        Spacer(minLength: 0)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func tokenLegendRow(_ item: TokenRowItem) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(item.color)
                .frame(width: 6, height: 6)
            Text(item.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(item.value.formatted())
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    private func contextBar(_ context: SessionContextOccupancy) -> some View {
        let ratio: Double? = if let percent = context.percent {
            min(max(percent / 100, 0), 1)
        } else if let window = context.contextWindow, window > 0 {
            min(max(Double(context.promptTokens) / Double(window), 0), 1)
        } else {
            nil
        }
        let percentValue = ratio.map { Int(($0 * 100).rounded()) }
        let barColor: Color = switch percentValue ?? 0 {
        case 90...: .red
        case 75...: .orange
        default: self.accentColor
        }
        let summary: String = {
            var parts = [context.promptTokens.compactCount]
            if let window = context.contextWindow, window > 0 {
                parts[0] += " / \(window.compactCount)"
            }
            if let percentValue {
                parts.append("\(percentValue)%")
            }
            return parts.joined(separator: " · ")
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(summary)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            if let ratio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.09))
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(4, proxy.size.width * ratio))
                    }
                }
                .frame(height: 4)
            }

            if let system = context.systemTokens, let messages = context.messageTokens {
                Text("System \(system.compactCount) · Messages \(messages.compactCount)")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 1)
    }

    private func performanceFooter(_ session: SessionSummary) -> some View {
        HStack(spacing: 12) {
            if let ttft = session.menuAverageTTFTText {
                self.footerMetric(symbol: "timer", text: "\(ttft) first token")
            }
            if let speed = session.menuAverageTPSText {
                self.footerMetric(symbol: "bolt", text: speed)
            }
            if let span = self.sessionSpanText(session) {
                self.footerMetric(symbol: "clock", text: span)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func footerMetric(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .monospacedDigit()
        }
    }

    private var emptyUsagePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(self.presentation.info.usageDate.map { "No recorded usage for \($0)" } ?? "Usage not recorded yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let duration = self.presentation.turnDuration, duration >= 1 {
                Text("Last turn · \(UnreadTaskFormat.duration(duration))")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
    }

    private var sessionIDFooter: some View {
        HStack(spacing: 5) {
            Text("ID")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.quaternary)
            Text(self.presentation.info.sessionID)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var hasMetadataLine: Bool {
        self.presentation.resolvedWorkspaceName != nil || self.presentation.info.session?.menuModelText != nil
    }

    private var headerTimeText: String? {
        if let session = self.presentation.info.session,
           session.startedAtMs > 0,
           session.endedAtMs >= session.startedAtMs
        {
            let start = Date(timeIntervalSince1970: Double(session.startedAtMs) / 1000)
            let end = Date(timeIntervalSince1970: Double(session.endedAtMs) / 1000)
            let startClock = Self.clockText(start)
            let endClock = Self.clockText(end)
            return startClock == endClock ? startClock : "\(startClock)–\(endClock)"
        }
        if let timestamp = self.presentation.timestamp {
            return Self.relativeTimeText(timestamp)
        }
        return nil
    }

    private var platformTint: Color {
        switch self.presentation.info.platform {
        case .claude:
            Color(red: 0.85, green: 0.47, blue: 0.34)
        case .antigravity:
            Color(red: 0.26, green: 0.52, blue: 0.96)
        default:
            .primary
        }
    }

    private var statusColor: Color {
        switch self.presentation.statusKind {
        case .unread:
            Color(red: 1.0, green: 0.30, blue: 0.24)
        case .running:
            self.accentColor
        case .interrupted:
            .orange
        case .background, .recent:
            .secondary
        }
    }

    private func tokenRows(for tokens: TokenBreakdown) -> [TokenRowItem] {
        var rows: [TokenRowItem] = [
            TokenRowItem(label: "Input", value: tokens.input, color: TokenBarPalette.input),
            TokenRowItem(label: "Output", value: tokens.output, color: TokenBarPalette.output),
        ]
        if tokens.cacheWrite > 0 {
            rows.append(TokenRowItem(label: "Cache read", value: tokens.cacheRead, color: TokenBarPalette.cache))
            rows.append(TokenRowItem(label: "Cache write", value: tokens.cacheWrite, color: TokenBarPalette.cache.opacity(0.55)))
        } else {
            rows.append(TokenRowItem(label: "Cache", value: tokens.cacheRead, color: TokenBarPalette.cache))
        }
        if tokens.reasoning > 0 {
            rows.append(TokenRowItem(label: "Reasoning", value: tokens.reasoning, color: TokenBarPalette.reasoning))
        }
        return rows
    }

    private func subagentRequestCount(in session: SessionSummary) -> Int {
        session.requests.flatMap(\.physicalRequests).count { $0.isSubagent }
    }

    private func hasPerformanceFooter(_ session: SessionSummary) -> Bool {
        session.menuAverageTTFTText != nil
            || session.menuAverageTPSText != nil
            || self.sessionSpanText(session) != nil
    }

    private func sessionSpanText(_ session: SessionSummary) -> String? {
        let elapsedSeconds = Double(max(0, session.endedAtMs - session.startedAtMs)) / 1000
        guard elapsedSeconds >= 1 else { return nil }
        return UnreadTaskFormat.duration(elapsedSeconds)
    }

    private static func clockText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static func relativeTimeText(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 {
            return "just now"
        }
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        if minutes < 24 * 60 {
            return "\(minutes / 60)h ago"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct TokenRowItem {
    let label: String
    let value: Int64
    let color: Color
}

private struct SessionMetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }
}

private struct MenuInlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3.5) {
            configuration.icon
                .font(.system(size: 9.5, weight: .medium))
            configuration.title
        }
    }
}
