import Charts
import SwiftUI
import TokenBarCore

/// Geometry shared by the dropdown. Text starts 16pt from the menu edge like native
/// menu items; panels sit 6pt in so their edges line up with row highlights.
enum DashboardLayout {
    static let textInset: CGFloat = 16
    static let panelInset: CGFloat = 6
    static let panelPadding: CGFloat = 10
    static let panelRadius: CGFloat = 10
    static let sectionGap: CGFloat = 14
}

struct DashboardSummaryView: View {
    @Bindable var model: DashboardModel
    let showsClaude: Bool
    let showsGrok: Bool
    let showsAntigravity: Bool
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    static func preferredHeight(
        quota: QuotaSnapshot?,
        providesQuota: Bool = true,
        showsClaude: Bool,
        showsGrok: Bool,
        showsAntigravity: Bool) -> CGFloat
    {
        DashboardOverviewView.preferredHeight(
            quota: quota,
            providesQuota: providesQuota,
            showsClaude: showsClaude,
            showsGrok: showsGrok,
            showsAntigravity: showsAntigravity)
            + ActivitySummarySection.preferredHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            DashboardOverviewView(
                model: self.model,
                showsClaude: self.showsClaude,
                showsGrok: self.showsGrok,
                showsAntigravity: self.showsAntigravity,
                usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                accentColor: self.accentColor)
            ActivitySummarySection(
                state: self.model.visibleActivity,
                accentColor: self.accentColor,
                showsChevron: false)
                .frame(height: ActivitySummarySection.preferredHeight)
        }
        .background(Color.clear)
    }
}

struct DashboardOverviewView: View {
    static let headerHeight: CGFloat = 42
    static let compactHeaderHeight: CGFloat = 30
    fileprivate static let gaugeRowHeight: CGFloat = 66
    fileprivate static let resetCreditsHeight: CGFloat = 26
    fileprivate static let quotaPlaceholderHeight: CGFloat = 20
    static let todayHeight: CGFloat = 138

    @Bindable var model: DashboardModel
    let showsClaude: Bool
    let showsGrok: Bool
    let showsAntigravity: Bool
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    static func preferredHeight(
        quota: QuotaSnapshot?,
        providesQuota: Bool = true,
        showsClaude: Bool,
        showsGrok: Bool,
        showsAntigravity: Bool) -> CGFloat
    {
        self.headerHeight(
            showsClaude: showsClaude,
            showsGrok: showsGrok,
            showsAntigravity: showsAntigravity)
            + self.contentHeight(quota: quota, providesQuota: providesQuota)
    }

    static func headerHeight(
        showsClaude: Bool,
        showsGrok: Bool,
        showsAntigravity: Bool) -> CGFloat
    {
        DashboardScope.visibleScopes(
            showsClaude: showsClaude,
            showsGrok: showsGrok,
            showsAntigravity: showsAntigravity).count > 1
            ? self.headerHeight
            : self.compactHeaderHeight
    }

    static func contentHeight(
        quota: QuotaSnapshot?,
        providesQuota: Bool = true) -> CGFloat
    {
        (providesQuota ? self.quotaHeight(quota: quota) + DashboardLayout.sectionGap : 0)
            + self.todayHeight
            + DashboardLayout.sectionGap
    }

    static func quotaHeight(
        hasWeekly: Bool,
        hasFiveHour: Bool,
        hasResetCredits: Bool) -> CGFloat
    {
        (hasWeekly || hasFiveHour ? self.gaugeRowHeight : self.quotaPlaceholderHeight)
            + (hasResetCredits ? self.resetCreditsHeight : 0)
            + DashboardLayout.panelPadding * 2
    }

    static func quotaHeight(quota: QuotaSnapshot?) -> CGFloat {
        self.quotaHeight(
            hasWeekly: quota?.weekly != nil,
            hasFiveHour: quota?.session != nil,
            hasResetCredits: quota?.resetCredits != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeaderView(
                model: self.model,
                showsClaude: self.showsClaude,
                showsGrok: self.showsGrok,
                showsAntigravity: self.showsAntigravity,
                accentColor: self.accentColor,
                onSelectScope: nil)
                .frame(height: Self.headerHeight(
                    showsClaude: self.showsClaude,
                    showsGrok: self.showsGrok,
                    showsAntigravity: self.showsAntigravity))
            DashboardOverviewContentView(
                model: self.model,
                usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                accentColor: self.accentColor)
        }
        .background(Color.clear)
    }
}

// MARK: - Header

struct DashboardHeaderView: View {
    @Bindable var model: DashboardModel
    let showsClaude: Bool
    let showsGrok: Bool
    let showsAntigravity: Bool
    let accentColor: Color
    let onSelectScope: ((DashboardScope) -> Void)?

    var body: some View {
        let scopes = DashboardScope.visibleScopes(
            showsClaude: self.showsClaude,
            showsGrok: self.showsGrok,
            showsAntigravity: self.showsAntigravity)
        HStack(spacing: 6) {
            if scopes.count > 1 {
                ForEach(scopes) { scope in
                    PlatformTab(
                        scope: scope,
                        remainingPercent: self.weeklyRemaining(for: scope),
                        isSelected: self.model.scope == scope,
                        showsName: scopes.count <= 2 || self.model.scope == scope,
                        accentColor: self.accentColor)
                        .onTapGesture {
                            self.select(scope)
                        }
                }
            } else {
                Text("TokenBar")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, DashboardLayout.textInset - DashboardLayout.panelInset)
            }
            Spacer(minLength: 6)
            if scopes.count <= 2 {
                if self.model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(self.updatedText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(self.updatedHelp)
            }
        }
        .padding(.leading, DashboardLayout.panelInset)
        .padding(.trailing, DashboardLayout.textInset)
        .padding(.top, scopes.count > 1 ? 10 : 7)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    private func weeklyRemaining(for scope: DashboardScope) -> Double? {
        guard self.model.providesQuota(for: scope.platform),
              let weekly = self.model.quotaState(for: scope.platform).value?.weekly,
              weekly.usageKnown
        else {
            return nil
        }
        return weekly.remainingPercent.clamped(to: 0 ... 100)
    }

    private func select(_ scope: DashboardScope) {
        guard self.model.scope != scope else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let onSelectScope = self.onSelectScope {
                onSelectScope(scope)
            } else {
                self.model.scope = scope
            }
        }
    }

    private var updatedText: String {
        guard let date = self.model.activitySnapshot?.generatedAt else {
            return self.model.activity.isRefreshing ? "Refreshing…" : "Waiting for data"
        }
        return date.compactPastText
    }

    private var updatedHelp: String {
        guard let date = self.model.activitySnapshot?.generatedAt else { return "" }
        return "Activity updated \(date.formatted(date: .omitted, time: .shortened))"
    }
}

/// Platform switch that also previews each platform's weekly headroom.
private struct PlatformTab: View {
    let scope: DashboardScope
    let remainingPercent: Double?
    let isSelected: Bool
    let showsName: Bool
    let accentColor: Color

    var body: some View {
        HStack(spacing: 5) {
            if let icon = PlatformStatusIcon.image(for: self.scope.platform) {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(self.isSelected ? Color.primary : Color.secondary)
            }
            if self.showsName {
                Text(self.scope.displayName)
                    .font(.system(size: 12, weight: self.isSelected ? .semibold : .medium))
                    .foregroundStyle(self.isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            if let remainingPercent {
                Text("\(Int(remainingPercent.rounded()))%")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(QuotaStatus(remainingPercent: remainingPercent).textColor(
                        normal: self.isSelected ? .secondary : .tertiary))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background {
            if self.isSelected {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .contentShape(Capsule())
        .help(self.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var helpText: String {
        guard let remainingPercent else { return self.scope.displayName }
        return "\(self.scope.displayName): \(Int(remainingPercent.rounded()))% of the weekly quota left"
    }
}

// MARK: - Overview

struct DashboardOverviewContentView: View {
    @Bindable var model: DashboardModel
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    var body: some View {
        let platform = self.model.scope.platform
        let quotaState = self.model.quotaState(for: platform)
        VStack(spacing: DashboardLayout.sectionGap) {
            if self.model.providesQuota(for: platform) {
                QuotaPanel(
                    state: quotaState,
                    usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                    accentColor: self.accentColor)
                    .frame(height: DashboardOverviewView.quotaHeight(quota: quotaState.value))
            }
            TodaySection(
                state: self.model.visibleActivity,
                weeklyQuotaUsage: self.model.weeklyQuotaUsageToday(for: platform),
                usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                accentColor: self.accentColor)
                .frame(height: DashboardOverviewView.todayHeight, alignment: .top)
        }
        .padding(.bottom, DashboardLayout.sectionGap)
        .background(Color.clear)
    }
}

/// Lightly filled rounded panel for instrument-style content.
struct DashboardPanel<Content: View>: View {
    var padding: CGFloat = DashboardLayout.panelPadding
    @ViewBuilder let content: Content

    var body: some View {
        self.content
            .padding(self.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: DashboardLayout.panelRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
    }
}

/// Small uppercase heading that opens each section.
struct DashboardSectionLabel: View {
    let title: String

    var body: some View {
        Text(self.title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Menu item heading in the dashboard's section style.
struct MenuSectionHeaderView: View {
    static let height: CGFloat = 26

    let title: String

    var body: some View {
        DashboardSectionLabel(title: self.title)
            .padding(.horizontal, DashboardLayout.textInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Quota

private enum QuotaStatus {
    case healthy
    case low
    case critical

    init(remainingPercent: Double) {
        switch remainingPercent {
        case ..<10: self = .critical
        case ..<20: self = .low
        default: self = .healthy
        }
    }

    func fillColor(accentColor: Color) -> Color {
        switch self {
        case .healthy: accentColor
        case .low: .orange
        case .critical: .red
        }
    }

    func textColor(normal: HierarchicalShapeStyle) -> AnyShapeStyle {
        switch self {
        case .healthy: AnyShapeStyle(normal)
        case .low: AnyShapeStyle(Color.orange)
        case .critical: AnyShapeStyle(Color.red)
        }
    }
}

private struct QuotaPanel: View {
    let state: DashboardSourceState<QuotaSnapshot>
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    var body: some View {
        let snapshot = self.state.value
        DashboardPanel {
            VStack(alignment: .leading, spacing: 0) {
                if snapshot?.weekly != nil || snapshot?.session != nil {
                    HStack(alignment: .center, spacing: 0) {
                        if let snapshot, let weekly = snapshot.weekly {
                            WeeklyGaugeBlock(
                                window: weekly,
                                measuredAt: snapshot.updatedAt,
                                warning: self.warningText(snapshot),
                                usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                                accentColor: self.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if snapshot?.weekly != nil, snapshot?.session != nil {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 1, height: 48)
                                .padding(.horizontal, 10)
                        }
                        if let fiveHour = snapshot?.session {
                            FiveHourGaugeBlock(window: fiveHour, accentColor: self.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(height: DashboardOverviewView.gaugeRowHeight)
                } else {
                    HStack(spacing: 6) {
                        Text(self.state.isRefreshing ? "Loading quota…" : "Quota unavailable")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        if let errorMessage = self.state.errorMessage {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .help(errorMessage)
                        }
                    }
                    .frame(height: DashboardOverviewView.quotaPlaceholderHeight)
                }

                if let resetCredits = snapshot?.resetCredits {
                    ResetCreditsRow(snapshot: resetCredits)
                        .frame(height: DashboardOverviewView.resetCreditsHeight, alignment: .bottom)
                }
            }
        }
        .padding(.horizontal, DashboardLayout.panelInset)
        .help(self.sourceText)
    }

    private var sourceText: String {
        guard let snapshot = self.state.value else {
            return self.state.errorMessage ?? "Quota has not been sampled yet."
        }
        let age = snapshot.updatedAt.compactPastText
        switch snapshot.origin {
        case .claudeDesktop:
            return "Quota from Claude Desktop, sampled \(age)."
        case .liveProvider:
            return "Quota from Anthropic, sampled \(age)."
        case nil:
            return "Quota sampled \(age)."
        }
    }

    /// Surfaces refresh errors and samples old enough that the percentages may be wrong.
    private func warningText(_ snapshot: QuotaSnapshot) -> String? {
        if let errorMessage = self.state.errorMessage {
            return errorMessage
        }
        guard Date().timeIntervalSince(snapshot.updatedAt) >= 30 * 60 else { return nil }
        return "Last sampled \(snapshot.updatedAt.compactPastText)"
    }
}

/// Open ring that fills with the used share; weekly rings split into pacing segments
/// and mark where linear usage would be.
private struct QuotaGauge: View {
    static let diameter: CGFloat = 62
    private static let lineWidth: CGFloat = 7
    private static let startAngle: Double = 150
    private static let sweep: Double = 240

    let usedPercent: Double?
    let segmentCount: Int
    let expectedPercent: Double?
    let tint: Color

    var body: some View {
        let segments = max(1, self.segmentCount)
        let gap: Double = segments > 1 ? 7 : 0
        let segmentSweep = (Self.sweep - gap * Double(segments - 1)) / Double(segments)
        ZStack {
            ForEach(0 ..< segments, id: \.self) { index in
                let start = Double(index) * (segmentSweep + gap)
                self.arc(from: start, to: start + segmentSweep)
                    .stroke(
                        Color.primary.opacity(0.09),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: segments > 1 ? .butt : .round))
                let fill = self.fillFraction(index: index, segments: segments)
                if fill > 0 {
                    self.arc(from: start, to: start + segmentSweep * fill)
                        .stroke(
                            self.tint,
                            style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: segments > 1 ? .butt : .round))
                }
            }
            if let expectedPercent {
                let angle = Self.startAngle + self.angleOffset(
                    percent: expectedPercent,
                    segments: segments,
                    segmentSweep: segmentSweep,
                    gap: gap)
                let radius = (Self.diameter - Self.lineWidth) / 2
                Capsule()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 2, height: Self.lineWidth + 6)
                    .rotationEffect(.degrees(angle + 90))
                    .offset(
                        x: radius * cos(angle * .pi / 180),
                        y: radius * sin(angle * .pi / 180))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }

    private func arc(from start: Double, to end: Double) -> some Shape {
        GaugeArc(
            startAngle: Self.startAngle + start,
            endAngle: Self.startAngle + end,
            inset: Self.lineWidth / 2)
    }

    private func fillFraction(index: Int, segments: Int) -> Double {
        guard let usedPercent else { return 0 }
        let used = usedPercent.clamped(to: 0 ... 100) / 100
        return ((used - Double(index) / Double(segments)) * Double(segments)).clamped(to: 0 ... 1)
    }

    private func angleOffset(percent: Double, segments: Int, segmentSweep: Double, gap: Double) -> Double {
        let position = (percent.clamped(to: 0 ... 100) / 100) * Double(segments)
        let index = min(segments - 1, Int(position))
        return Double(index) * (segmentSweep + gap) + (position - Double(index)) * segmentSweep
    }
}

private struct GaugeArc: Shape {
    let startAngle: Double
    let endAngle: Double
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2 - self.inset,
            startAngle: .degrees(self.startAngle),
            endAngle: .degrees(self.endAngle),
            clockwise: false)
        return path
    }
}

private struct GaugeCenterLabel: View {
    let remainingPercent: Double?
    let status: QuotaStatus

    var body: some View {
        VStack(spacing: -1) {
            Text(self.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(self.status.textColor(normal: .primary))
            Text("left")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .offset(y: 2)
    }
}

private struct WeeklyGaugeBlock: View {
    let window: QuotaWindowSnapshot
    let measuredAt: Date
    let warning: String?
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    private var pacing: WeeklyQuotaPacing? {
        guard let reset = self.window.resetsAt, reset > Date() else { return nil }
        return self.window.weeklyPacing(
            at: self.measuredAt,
            weekdaysOnly: self.usesWeekdayWeeklyPacing)
    }

    var body: some View {
        let remaining = self.window.usageKnown ? self.window.remainingPercent.clamped(to: 0 ... 100) : nil
        let status = QuotaStatus(remainingPercent: remaining ?? 100)
        let pacing = self.pacing
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                QuotaGauge(
                    usedPercent: remaining.map { 100 - $0 },
                    segmentCount: pacing?.segmentCount ?? 1,
                    expectedPercent: pacing?.expectedUsedPercent,
                    tint: status.fillColor(accentColor: self.accentColor))
                GaugeCenterLabel(remainingPercent: remaining, status: status)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Weekly")
                        .font(.system(size: 12, weight: .semibold))
                    if let warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.orange)
                            .help(warning)
                    }
                }
                Text(self.window.resetsAt.map { "Resets \($0.compactFutureText)" } ?? "Reset unknown")
                    .foregroundStyle(.secondary)
                if let pacing {
                    Text(
                        "\(pacing.weekdaysOnly ? "Workday" : "Day") "
                            + "\(pacing.currentSegment) of \(pacing.segmentCount)")
                        .foregroundStyle(.secondary)
                    Text(self.paceText(pacing))
                        .fontWeight(.medium)
                        .foregroundStyle(self.paceColor(pacing))
                }
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .padding(.top, 2)
        }
        .help(pacing.map(self.helpText) ?? "")
        .accessibilityElement(children: .combine)
    }

    private func paceText(_ pacing: WeeklyQuotaPacing) -> String {
        let delta = pacing.deltaPercentagePoints
        guard abs(delta) >= 1 else { return "On pace" }
        return "\(Int(abs(delta).rounded()))pp \(delta > 0 ? "over" : "under") pace"
    }

    private func paceColor(_ pacing: WeeklyQuotaPacing) -> Color {
        let delta = pacing.deltaPercentagePoints
        if delta >= 1 {
            return .orange
        }
        if delta <= -1 {
            return TokenBarPalette.positive
        }
        return .secondary
    }

    private func helpText(_ pacing: WeeklyQuotaPacing) -> String {
        let start = pacing.windowStart.formatted(date: .abbreviated, time: .shortened)
        let end = pacing.windowEnd.formatted(date: .abbreviated, time: .shortened)
        let paceDescription = pacing.weekdaysOnly
            ? "Each segment is one calendar workday from midnight to midnight; weekends do not advance the pace. "
            : "Each segment is one seventh of the quota window. "
        return "Weekly cycle \(start) – \(end). \(paceDescription)"
            + "Used \(Int(pacing.actualUsedPercent.rounded()))%; "
            + "the marker shows linear pace at \(Int(pacing.expectedUsedPercent.rounded()))%."
    }
}

private struct FiveHourGaugeBlock: View {
    let window: QuotaWindowSnapshot
    let accentColor: Color

    var body: some View {
        let remaining = self.window.usageKnown ? self.window.remainingPercent.clamped(to: 0 ... 100) : nil
        let status = QuotaStatus(remainingPercent: remaining ?? 100)
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                QuotaGauge(
                    usedPercent: remaining.map { 100 - $0 },
                    segmentCount: 1,
                    expectedPercent: nil,
                    tint: status.fillColor(accentColor: self.accentColor))
                GaugeCenterLabel(remainingPercent: remaining, status: status)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("5-hour")
                    .font(.system(size: 12, weight: .semibold))
                Text(self.resetText)
                    .foregroundStyle(.secondary)
                if let remaining {
                    Text("\(Int((100 - remaining).rounded()))% used")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Usage unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var resetText: String {
        guard let reset = self.window.resetsAt, reset > Date() else {
            return "Reset unknown"
        }
        return "Resets \(reset.compactFutureText)"
    }
}

private struct ResetCreditsRow: View {
    let snapshot: QuotaResetCreditsSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(self.snapshot.availableCount) extra \(self.snapshot.availableCount == 1 ? "reset" : "resets")")
                .fontWeight(.medium)
            Spacer(minLength: 6)
            if let expiration = self.snapshot.nextExpiresAt {
                Text("next expires \(expiration.compactFutureText)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
}

// MARK: - Today

private struct TodaySection: View {
    let state: DashboardSourceState<ActivitySnapshot>
    let weeklyQuotaUsage: WeeklyQuotaDailyUsage?
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    var body: some View {
        let snapshot = self.state.value
        let totals = snapshot?.today ?? .empty
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                DashboardSectionLabel(title: "Today")
                Spacer(minLength: 6)
                Text(self.summaryText(snapshot?.today))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DashboardLayout.textInset)
            .frame(height: 14)

            HStack(spacing: 6) {
                MetricTile(
                    label: "Spent",
                    value: totals.costUsd.costText(tokenTotal: totals.tokens.total))
                MetricTile(label: "Tokens", value: totals.tokens.total.compactCount)
                if let usage = self.weeklyQuotaUsage {
                    MetricTile(
                        label: "Of weekly",
                        value: usage.menuValueText,
                        tint: usage.tint(
                            usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                            accentColor: self.accentColor))
                        .help(usage.helpText(usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing))
                } else {
                    MetricTile(label: "Turns", value: "\(totals.requestCount)")
                }
            }
            .frame(height: 52)
            .padding(.horizontal, DashboardLayout.panelInset)
            .padding(.top, 8)

            TokenMixView(totals: totals)
                .padding(.horizontal, DashboardLayout.textInset)
                .padding(.top, 12)

            PerformanceRow(
                cacheText: totals.tokens.total > 0 ? totals.tokens.cachePercentageText : nil,
                firstTokenText: snapshot?.today.menuAverageTTFTText ?? snapshot?.menuAverageTTFTText,
                speedText: snapshot?.today.menuAverageTPSText ?? snapshot?.menuAverageTPSText)
                .padding(.horizontal, DashboardLayout.textInset)
                .padding(.top, 10)
        }
    }

    private func summaryText(_ totals: ActivityTotals?) -> String {
        guard let totals else {
            return self.state.isRefreshing ? "Scanning activity…" : "No activity yet"
        }
        return "\(totals.sessionCount) sessions · \(totals.requestCount) turns"
    }
}

private struct MetricTile: View {
    let label: String
    let value: String
    var tint: Color?

    var body: some View {
        DashboardPanel(padding: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Text(self.value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(self.tint ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, DashboardLayout.textInset - DashboardLayout.panelInset)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Thin proportional bar with an inline legend; per-type costs live in the tooltip.
private struct TokenMixView: View {
    let totals: ActivityTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TokenStackedBar(tokens: self.totals.tokens)
                .frame(height: 5)
            HStack(spacing: 0) {
                ForEach(TokenKind.allCases, id: \.self) { kind in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(kind.color)
                            .frame(width: 6, height: 6)
                        Text(kind.shortLabel)
                            .foregroundStyle(.secondary)
                        Text(kind.value(in: self.totals.tokens).compactCount)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: kind == .input ? .leading : (kind == .reasoning ? .trailing : .center))
                }
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
        }
        .help(self.costHelp)
    }

    private var costHelp: String {
        guard let costs = self.totals.tokenCosts else { return "" }
        return TokenKind.allCases.map { kind in
            "\(kind.label): \(kind.value(in: self.totals.tokens).compactCount) · "
                + kind.cost(in: costs).tokenComponentCostText
        }
        .joined(separator: "\n")
    }
}

private struct PerformanceRow: View {
    let cacheText: String?
    let firstTokenText: String?
    let speedText: String?

    var body: some View {
        HStack(spacing: 14) {
            self.metric(symbol: "arrow.triangle.2.circlepath", value: self.cacheText, label: "cache hit")
            self.metric(symbol: "timer", value: self.firstTokenText, label: "first token")
            self.metric(symbol: "bolt", value: self.speedText, label: nil)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
    }

    private func metric(symbol: String, value: String?, label: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value ?? "—")
                .monospacedDigit()
            if let label {
                Text(label)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum TokenKind: CaseIterable {
    case input
    case output
    case cache
    case reasoning

    var label: String {
        switch self {
        case .input: "Input"
        case .output: "Output"
        case .cache: "Cache"
        case .reasoning: "Reasoning"
        }
    }

    var shortLabel: String {
        switch self {
        case .input: "In"
        case .output: "Out"
        case .cache: "Cache"
        case .reasoning: "Reason"
        }
    }

    var color: Color {
        switch self {
        case .input: TokenBarPalette.input
        case .output: TokenBarPalette.output
        case .cache: TokenBarPalette.cache
        case .reasoning: TokenBarPalette.reasoning
        }
    }

    func value(in tokens: TokenBreakdown) -> Int64 {
        switch self {
        case .input: tokens.displayedInput
        case .output: tokens.output
        case .cache: tokens.displayedCache
        case .reasoning: tokens.reasoning
        }
    }

    func cost(in costs: TokenCostBreakdown) -> Double {
        switch self {
        case .input: costs.displayedInput
        case .output: costs.output
        case .cache: costs.displayedCache
        case .reasoning: costs.reasoning
        }
    }
}

struct WeeklyQuotaUsageLabel: View {
    let usage: WeeklyQuotaDailyUsage
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(self.usage.menuValueText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(self.usage.tint(
                    usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                    accentColor: self.accentColor))
            Text("of weekly quota")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .help(self.usage.helpText(usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Weekly quota used, \(self.usage.menuValueText) of the weekly allowance")
    }
}

/// Token mix with per-type costs and headline numbers, for the activity detail submenu.
struct ActivityTotalsBreakdown: View {
    let totals: ActivityTotals
    let firstTokenText: String?
    let speedText: String?
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TokenStackedBar(tokens: self.totals.tokens)
                .frame(height: 6)

            HStack(spacing: 16) {
                TokenLegend(kind: .input, totals: self.totals)
                TokenLegend(kind: .output, totals: self.totals)
            }
            .frame(height: 14)
            .padding(.top, 10)
            HStack(spacing: 16) {
                TokenLegend(kind: .cache, totals: self.totals)
                TokenLegend(kind: .reasoning, totals: self.totals)
            }
            .frame(height: 14)
            .padding(.top, 5)

            HStack(spacing: 6) {
                MetricTile(
                    label: "Spent",
                    value: self.totals.costUsd.costText(tokenTotal: self.totals.tokens.total))
                MetricTile(label: "Cache hit", value: self.totals.tokens.cachePercentageText)
                MetricTile(label: "First token", value: self.firstTokenText ?? "—")
                MetricTile(
                    label: "Tok/s",
                    value: self.speedText.map { $0.replacingOccurrences(of: " tok/s", with: "") } ?? "—")
            }
            .frame(height: 52)
            .padding(.top, 12)
        }
    }
}

private struct TokenLegend: View {
    let kind: TokenKind
    let totals: ActivityTotals

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(self.kind.color)
                .frame(width: 6, height: 6)
            Text(self.kind.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(self.kind.value(in: self.totals.tokens).compactCount)
                .monospacedDigit()
            Text(self.totals.tokenCosts.map { self.kind.cost(in: $0).tokenComponentCostText } ?? "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity)
        .lineLimit(1)
    }
}

private struct TokenStackedBar: View {
    let tokens: TokenBreakdown

    private var components: [(kind: TokenKind, value: Int64)] {
        TokenKind.allCases
            .map { ($0, $0.value(in: self.tokens)) }
            .filter { $0.1 > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if self.tokens.total > 0 {
                    let components = self.components
                    HStack(spacing: 1) {
                        ForEach(components, id: \.kind) { component in
                            Rectangle()
                                .fill(component.kind.color)
                                .frame(
                                    width: max(
                                        2,
                                        (proxy.size.width - CGFloat(max(0, components.count - 1)))
                                            * CGFloat(component.value) / CGFloat(self.tokens.total)))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
        }
    }
}

// MARK: - Activity

struct ActivitySummarySection: View {
    static let preferredHeight: CGFloat = 126

    let state: DashboardSourceState<ActivitySnapshot>
    let accentColor: Color
    let showsChevron: Bool

    private var days: [DailySummary] {
        Array((self.state.value?.days ?? []).sorted { $0.date < $1.date }.suffix(30))
    }

    private var cycle: ActivityRangeSummary? {
        self.state.value?.weeklySinceReset
    }

    /// First day of the current weekly quota cycle, in the statistics time zone the days use.
    private var cycleStartDay: String? {
        guard let cycle = self.cycle else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TokenBarSettings.shared.statisticsTimeZone == .utc
            ? TimeZone(identifier: "UTC")
            : .autoupdatingCurrent
        return formatter.string(from: cycle.startedAt)
    }

    var body: some View {
        let cycleStartDay = self.cycleStartDay
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                DashboardSectionLabel(title: "Last 30 days")
                Spacer(minLength: 6)
                Text(self.totalTokens.compactCount)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if self.showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                }
            }
            .frame(height: 14)

            ZStack {
                Chart {
                    ForEach(self.days) { day in
                        BarMark(
                            x: .value("Day", day.date),
                            y: .value("Tokens", day.tokens.total))
                            .foregroundStyle(self.barColor(day, cycleStartDay: cycleStartDay))
                            .cornerRadius(2)
                    }
                    RuleMark(y: .value("Zero", 0))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.primary.opacity(0.12))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0 ... max(1, self.maximumTokens))

                if self.totalTokens == 0 {
                    Text(self.state.isRefreshing ? "Refreshing activity…" : "No activity yet")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 54)
            .padding(.top, 10)
            .transaction { $0.animation = nil }

            HStack {
                Text(self.days.first?.date.shortDateLabel ?? "")
                Spacer()
                Text(self.days.last?.date.shortDateLabel ?? "")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .frame(height: 11)
            .padding(.top, 3)

            HStack(spacing: 5) {
                if let cycle = self.cycle {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(self.accentColor)
                        .frame(width: 8, height: 8)
                    Text("This cycle")
                        .foregroundStyle(.secondary)
                    Text(
                        "\(cycle.totals.tokens.total.compactCount) · "
                            + cycle.totals.costUsd.costText(tokenTotal: cycle.totals.tokens.total))
                        .fontWeight(.medium)
                        .monospacedDigit()
                    Text("· \(cycle.totals.sessionCount) sessions")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text("Avg \(self.averageTokens.compactCount)/day")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: 14)
            .padding(.top, 6)
        }
        .padding(.horizontal, DashboardLayout.textInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func barColor(_ day: DailySummary, cycleStartDay: String?) -> Color {
        if day.id == self.days.last?.id {
            return self.accentColor
        }
        if let cycleStartDay, day.date >= cycleStartDay {
            return self.accentColor.opacity(0.55)
        }
        return Color.primary.opacity(0.16)
    }

    private var totalTokens: Int64 {
        self.days.reduce(0) { $0 + $1.tokens.total }
    }

    private var maximumTokens: Int64 {
        self.days.map(\.tokens.total).max() ?? 0
    }

    private var averageTokens: Int64 {
        guard !self.days.isEmpty else { return 0 }
        return self.totalTokens / Int64(self.days.count)
    }
}

/// Fixed palette for token types so a user's accent theme never collides with a category.
enum TokenBarPalette {
    static let input = Color(red: 0.26, green: 0.52, blue: 0.96)
    static let output = Color(red: 0.62, green: 0.42, blue: 0.92)
    static let cache = Color(red: 0.20, green: 0.68, blue: 0.60)
    static let reasoning = Color(red: 0.95, green: 0.62, blue: 0.22)
    static let positive = Color(red: 0.20, green: 0.66, blue: 0.48)
}

private extension ActivityTotals {
    static let empty = ActivityTotals(tokens: .zero, costUsd: 0, requestCount: 0, sessionCount: 0)
}

extension WeeklyQuotaDailyUsage {
    // 匀速消耗周额度时单日应占的百分点：按 5 个工作日或 7 天平摊
    fileprivate static func evenDailyShare(usesWeekdayWeeklyPacing: Bool) -> Double {
        100 / (usesWeekdayWeeklyPacing ? 5.0 : 7.0)
    }

    func tint(usesWeekdayWeeklyPacing: Bool, accentColor: Color) -> Color {
        let share = Self.evenDailyShare(usesWeekdayWeeklyPacing: usesWeekdayWeeklyPacing)
        switch self.usedPercentagePoints / share {
        case ..<0.85: return TokenBarPalette.positive
        case ..<1.25: return accentColor
        case ..<2: return Color.orange
        default: return Color.red
        }
    }

    func helpText(usesWeekdayWeeklyPacing: Bool) -> String {
        let share = Self.evenDailyShare(usesWeekdayWeeklyPacing: usesWeekdayWeeklyPacing)
            .formatted(.number.precision(.fractionLength(0 ... 1)))
        let pace = usesWeekdayWeeklyPacing
            ? " An even pace is about \(share)% per weekday."
            : " An even pace is about \(share)% per day."
        return self.menuHelpText + pace
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Int64 {
    var compactCount: String {
        let absolute = abs(Double(self))
        let divisor: Double
        let suffix: String
        switch absolute {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            return self.formatted()
        }
        return "\((Double(self) / divisor).formatted(.number.precision(.fractionLength(0 ... 1))))\(suffix)"
    }

    func saturatingAdd(_ other: Int64) -> Int64 {
        let (value, overflow) = self.addingReportingOverflow(other)
        guard overflow else { return value }
        return other >= 0 ? .max : .min
    }
}

extension Double {
    var usdText: String {
        String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            self)
    }

    func costText(tokenTotal: Int64) -> String {
        tokenTotal > 0 && self <= 0 ? "—" : self.usdText
    }

    fileprivate var tokenComponentCostText: String {
        self > 0 && self < 0.01 ? "<$0.01" : self.usdText
    }
}

extension String {
    func menuTruncated(to limit: Int) -> String {
        guard self.count > limit else { return self }
        return "\(self.prefix(max(0, limit - 1)))…"
    }

    var shortDateLabel: String {
        self.count >= 10 ? String(self.suffix(5)).replacingOccurrences(of: "-", with: "/") : self
    }
}

extension WeeklyQuotaDailyUsage {
    var menuValueText: String {
        self.usedPercentagePoints.formatted(
            .number.precision(.fractionLength(0 ... 1))) + "%"
    }

    var menuHelpText: String {
        let base = "Observed weekly-quota change between TokenBar samples on \(self.date)."
        guard self.isPartial else { return base }
        return base + " Tracking for a quota cycle began after some quota was already used, "
            + "so the day's earlier usage is not included."
    }
}

private extension Date {
    var compactPastText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(self)))
        switch seconds {
        case 0 ..< 60:
            return "just now"
        case 60 ..< 3600:
            return "\(seconds / 60)m ago"
        case 3600 ..< 86_400:
            return "\(seconds / 3600)h ago"
        default:
            return "\(seconds / 86_400)d ago"
        }
    }

    var compactFutureText: String {
        let seconds = max(0, Int(self.timeIntervalSinceNow))
        if seconds < 60 {
            return "in <1m"
        }
        if seconds < 3600 {
            return "in \(seconds / 60)m"
        }
        if seconds < 86_400 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
    }
}
