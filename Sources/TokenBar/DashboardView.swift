import Charts
import SwiftUI
import TokenBarCore

/// Card geometry shared by the dropdown. Card content starts 16pt from the menu edge,
/// the same inset as native menu item text, and cards line up with row highlights.
enum DashboardLayout {
    static let cardInset: CGFloat = 6
    static let cardPadding: CGFloat = 10
    static let cardGap: CGFloat = 6
    static let cardRadius: CGFloat = 10
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
    static let headerHeight: CGFloat = 40
    static let stackedHeaderHeight: CGFloat = 62
    static let compactHeaderHeight: CGFloat = 30
    private static let unavailableWeeklyHeight: CGFloat = 20
    fileprivate static let weeklyQuotaHeight: CGFloat = 76
    fileprivate static let fiveHourQuotaHeight: CGFloat = 34
    fileprivate static let resetCreditsHeight: CGFloat = 16
    fileprivate static let quotaBlockSpacing: CGFloat = 12
    static let todayHeight: CGFloat = 152

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
        switch DashboardScope.visibleScopes(
            showsClaude: showsClaude,
            showsGrok: showsGrok,
            showsAntigravity: showsAntigravity).count
        {
        case ...1: self.compactHeaderHeight
        case 2: self.headerHeight
        default: self.stackedHeaderHeight
        }
    }

    static func contentHeight(
        quota: QuotaSnapshot?,
        providesQuota: Bool = true) -> CGFloat
    {
        (providesQuota ? self.quotaHeight(quota: quota) + DashboardLayout.cardGap : 0)
            + self.todayHeight
            + DashboardLayout.cardGap
    }

    static func quotaHeight(
        hasWeekly: Bool,
        hasFiveHour: Bool,
        hasResetCredits: Bool) -> CGFloat
    {
        var blocks = [hasWeekly ? self.weeklyQuotaHeight : self.unavailableWeeklyHeight]
        if hasFiveHour {
            blocks.append(self.fiveHourQuotaHeight)
        }
        if hasResetCredits {
            blocks.append(self.resetCreditsHeight)
        }
        return blocks.reduce(0, +)
            + self.quotaBlockSpacing * CGFloat(blocks.count - 1)
            + DashboardLayout.cardPadding * 2
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
        Group {
            switch scopes.count {
            case ...1:
                HStack(spacing: 8) {
                    self.title
                    Spacer(minLength: 8)
                    self.status
                }
                .padding(.horizontal, 16)
                .padding(.top, 7)
            case 2:
                HStack(spacing: 8) {
                    self.selector(scopes: scopes, fillsWidth: false)
                    Spacer(minLength: 8)
                    self.status
                }
                .padding(.leading, DashboardLayout.cardInset)
                .padding(.trailing, 16)
                .padding(.top, 8)
            default:
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        self.title
                        Spacer(minLength: 8)
                        self.status
                    }
                    .frame(height: 16)
                    .padding(.horizontal, 10)
                    self.selector(scopes: scopes, fillsWidth: true)
                }
                .padding(.horizontal, DashboardLayout.cardInset)
                .padding(.top, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var title: some View {
        Text("TokenBar")
            .font(.system(size: 13, weight: .semibold))
    }

    private var status: some View {
        HStack(spacing: 6) {
            if self.model.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(self.updatedText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func selector(scopes: [DashboardScope], fillsWidth: Bool) -> some View {
        DashboardScopeSelector(
            selection: self.model.scope,
            scopes: scopes,
            fillsWidth: fillsWidth)
        { scope in
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
        return "Updated \(date.compactPastText)"
    }
}

struct DashboardOverviewContentView: View {
    @Bindable var model: DashboardModel
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    var body: some View {
        let platform = self.model.scope.platform
        let quotaState = self.model.quotaState(for: platform)
        VStack(spacing: DashboardLayout.cardGap) {
            if self.model.providesQuota(for: platform) {
                QuotaCard(
                    state: quotaState,
                    activity: self.model.visibleActivity,
                    usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                    accentColor: self.accentColor)
                    .frame(height: DashboardOverviewView.quotaHeight(quota: quotaState.value))
            }
            TodayCard(
                state: self.model.visibleActivity,
                weeklyQuotaUsage: self.model.weeklyQuotaUsageToday(for: platform),
                usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                accentColor: self.accentColor)
                .frame(height: DashboardOverviewView.todayHeight)
        }
        .padding(.bottom, DashboardLayout.cardGap)
        .background(Color.clear)
    }
}

/// Rounded, lightly filled panel that groups one topic in the dropdown.
struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        self.content
            .padding(DashboardLayout.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: DashboardLayout.cardRadius, style: .continuous)
                shape
                    .fill(Color.primary.opacity(0.045))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            }
            .padding(.horizontal, DashboardLayout.cardInset)
    }
}

private struct DashboardScopeSelector: View {
    let selection: DashboardScope
    let scopes: [DashboardScope]
    let fillsWidth: Bool
    let onSelect: (DashboardScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(self.scopes) { scope in
                DashboardScopeSegment(
                    scope: scope,
                    isSelected: self.selection == scope,
                    fillsWidth: self.fillsWidth)
                    .onTapGesture {
                        guard self.selection != scope else { return }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            self.onSelect(scope)
                        }
                    }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Platform")
    }
}

private struct DashboardScopeSegment: View {
    let scope: DashboardScope
    let isSelected: Bool
    let fillsWidth: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let icon = PlatformStatusIcon.image(for: self.scope.platform) {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            }
            Text(self.scope.displayName)
                .font(.system(size: 11.5, weight: self.isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(self.isSelected ? Color.primary : Color.secondary)
        .padding(.horizontal, self.fillsWidth ? 4 : 11)
        .frame(maxWidth: self.fillsWidth ? .infinity : nil)
        .frame(height: 22)
        .background {
            if self.isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(TokenBarVisualStyle.selectedSegmentColor)
                    .shadow(color: .black.opacity(0.14), radius: 0.5, y: 0.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

private struct QuotaCard: View {
    let state: DashboardSourceState<QuotaSnapshot>
    let activity: DashboardSourceState<ActivitySnapshot>
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: DashboardOverviewView.quotaBlockSpacing) {
                if let snapshot = self.state.value, let weekly = snapshot.weekly {
                    WeeklyQuotaBlock(
                        window: weekly,
                        measuredAt: snapshot.updatedAt,
                        activity: self.activity,
                        warning: self.warningText(snapshot),
                        usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                        accentColor: self.accentColor)
                        .frame(height: DashboardOverviewView.weeklyQuotaHeight, alignment: .top)
                } else {
                    QuotaTitleRow(
                        title: "Weekly",
                        detail: nil,
                        remainingPercent: nil,
                        placeholder: self.state.isRefreshing
                            ? "Loading quota…"
                            : "Quota unavailable",
                        warning: self.state.errorMessage)
                }

                if let fiveHour = self.state.value?.session {
                    FiveHourQuotaBlock(window: fiveHour, accentColor: self.accentColor)
                        .frame(height: DashboardOverviewView.fiveHourQuotaHeight, alignment: .top)
                }

                if let resetCredits = self.state.value?.resetCredits {
                    ResetCreditsRow(snapshot: resetCredits)
                        .frame(height: DashboardOverviewView.resetCreditsHeight)
                }
            }
        }
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

private struct QuotaTitleRow: View {
    let title: String
    let detail: String?
    let remainingPercent: Double?
    var placeholder = "Usage unavailable"
    var warning: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(self.title)
                .font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .help(warning)
            }
            Spacer(minLength: 6)
            if let remainingPercent {
                Text("\(Int(remainingPercent.rounded()))%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(QuotaTint.text(remainingPercent: remainingPercent))
                Text("left")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                InlinePlaceholder(text: self.placeholder)
            }
        }
        .frame(height: 20)
    }
}

private enum QuotaTint {
    static func bar(remainingPercent: Double, accentColor: Color) -> Color {
        switch remainingPercent {
        case ..<10: .red
        case ..<20: .orange
        default: accentColor
        }
    }

    static func text(remainingPercent: Double) -> Color {
        switch remainingPercent {
        case ..<10: .red
        case ..<20: .orange
        default: .primary
        }
    }
}

private struct WeeklyQuotaBlock: View {
    let window: QuotaWindowSnapshot
    let measuredAt: Date
    let activity: DashboardSourceState<ActivitySnapshot>
    let warning: String?
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    private var remainingPercent: Double {
        self.window.remainingPercent.clamped(to: 0 ... 100)
    }

    private var pacing: WeeklyQuotaPacing? {
        guard let reset = self.window.resetsAt, reset > Date() else { return nil }
        return self.window.weeklyPacing(
            at: self.measuredAt,
            weekdaysOnly: self.usesWeekdayWeeklyPacing)
    }

    private var cycleTotals: ActivityTotals? {
        guard let pacing = self.pacing,
              let summary = self.activity.value?.weeklySinceReset,
              abs(summary.startedAt.timeIntervalSince(pacing.windowStart)) < 1
        else {
            return nil
        }
        return summary.totals
    }

    var body: some View {
        let pacing = self.pacing
        let tint = QuotaTint.bar(remainingPercent: self.remainingPercent, accentColor: self.accentColor)
        VStack(alignment: .leading, spacing: 0) {
            QuotaTitleRow(
                title: "Weekly",
                detail: self.resetText,
                remainingPercent: self.window.usageKnown ? self.remainingPercent : nil,
                warning: self.warning)

            Group {
                if let pacing {
                    WeeklyQuotaSegmentedBar(pacing: pacing, tint: tint)
                } else {
                    QuotaBar(
                        usedPercent: self.window.usageKnown ? 100 - self.remainingPercent : 0,
                        tint: tint)
                        .frame(height: 8)
                }
            }
            .frame(height: 12)
            .padding(.top, 6)

            self.paceRow(pacing)
                .frame(height: 14)
                .padding(.top, 6)

            self.cycleRow
                .frame(height: 14)
                .padding(.top, 4)
        }
        .help(pacing.map(self.helpText) ?? "")
    }

    private func paceRow(_ pacing: WeeklyQuotaPacing?) -> some View {
        HStack(spacing: 4) {
            if let pacing {
                Text(
                    "\(pacing.weekdaysOnly ? "Workday" : "Day") "
                        + "\(pacing.currentSegment)/\(pacing.segmentCount)"
                        + " · \(Int(pacing.expectedUsedPercent.rounded()))% expected")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(self.deltaText(pacing))
                    .fontWeight(.medium)
                    .foregroundStyle(self.deltaColor(pacing))
            } else {
                Text(self.window.usageKnown
                    ? "\(Int((100 - self.remainingPercent).rounded()))% used"
                    : "Usage unavailable")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
            }
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
    }

    private var cycleRow: some View {
        HStack(spacing: 4) {
            Text("Since reset")
                .foregroundStyle(.secondary)
            if let totals = self.cycleTotals {
                Text("· \(totals.sessionCount) sessions · \(totals.requestCount) turns")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text("\(totals.tokens.total.compactCount) tokens")
                    .monospacedDigit()
                Text(totals.costUsd.costText(tokenTotal: totals.tokens.total))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            } else {
                Spacer(minLength: 6)
                Text(self.cyclePlaceholder)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var cyclePlaceholder: String {
        if self.pacing == nil {
            return "Waiting for a reset window"
        }
        return self.activity.isRefreshing ? "Calculating…" : "Unavailable"
    }

    private var resetText: String {
        guard let reset = self.window.resetsAt, reset > Date() else { return "reset unavailable" }
        return "resets \(reset.compactFutureText)"
    }

    private func deltaText(_ pacing: WeeklyQuotaPacing) -> String {
        let delta = pacing.deltaPercentagePoints
        guard abs(delta) >= 1 else { return "On pace" }
        return "\(Int(abs(delta).rounded()))pp \(delta > 0 ? "over" : "under") pace"
    }

    private func deltaColor(_ pacing: WeeklyQuotaPacing) -> Color {
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
            + "linear pace \(Int(pacing.expectedUsedPercent.rounded()))%."
    }
}

private struct WeeklyQuotaSegmentedBar: View {
    let pacing: WeeklyQuotaPacing
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                HStack(spacing: 3) {
                    ForEach(0 ..< self.pacing.segmentCount, id: \.self) { index in
                        GeometryReader { segment in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(TokenBarPalette.track)
                                Rectangle()
                                    .fill(self.tint)
                                    .frame(width: segment.size.width * self.fillFraction(for: index))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        }
                    }
                }
                .frame(height: 8)

                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 2, height: 12)
                    .position(
                        x: self.markerX(in: proxy.size.width),
                        y: proxy.size.height / 2)
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityText)
    }

    private func fillFraction(for index: Int) -> Double {
        let segmentPercent = 100 / Double(self.pacing.segmentCount)
        let segmentStart = Double(index) * segmentPercent
        return ((self.pacing.actualUsedPercent - segmentStart) / segmentPercent).clamped(to: 0 ... 1)
    }

    private func markerX(in width: CGFloat) -> CGFloat {
        let raw = width * CGFloat(self.pacing.expectedUsedPercent / 100)
        return raw.clamped(to: 1 ... max(1, width - 1))
    }

    private var accessibilityText: String {
        let delta = self.pacing.deltaPercentagePoints
        let comparison = abs(delta) < 1
            ? "on pace"
            : "\(Int(abs(delta).rounded())) percentage points \(delta > 0 ? "over" : "under") pace"
        return "Weekly quota, \(Int(self.pacing.actualUsedPercent.rounded())) percent used, "
            + "\(Int(self.pacing.expectedUsedPercent.rounded())) percent expected, \(comparison)."
    }
}

/// Fills with the used share, like the weekly bar, so both quota bars read the same way.
private struct QuotaBar: View {
    let usedPercent: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(TokenBarPalette.track)
                Capsule()
                    .fill(self.tint)
                    .frame(width: proxy.size.width * self.usedPercent.clamped(to: 0 ... 100) / 100)
            }
        }
    }
}

private struct FiveHourQuotaBlock: View {
    let window: QuotaWindowSnapshot
    let accentColor: Color

    var body: some View {
        let remaining = self.window.remainingPercent.clamped(to: 0 ... 100)
        VStack(alignment: .leading, spacing: 0) {
            QuotaTitleRow(
                title: "5-hour",
                detail: self.resetText,
                remainingPercent: self.window.usageKnown ? remaining : nil)
            QuotaBar(
                usedPercent: self.window.usageKnown ? 100 - remaining : 0,
                tint: QuotaTint.bar(remainingPercent: remaining, accentColor: self.accentColor))
                .frame(height: 8)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .combine)
    }

    private var resetText: String {
        guard let reset = self.window.resetsAt, reset > Date() else {
            return "reset unavailable"
        }
        return "resets \(reset.compactFutureText)"
    }
}

private struct ResetCreditsRow: View {
    let snapshot: QuotaResetCreditsSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Extra resets")
                .font(.system(size: 12, weight: .semibold))
            if let expiration = self.snapshot.nextExpiresAt {
                Text("next expires \(expiration.compactFutureText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(self.countText)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var countText: String {
        "\(self.snapshot.availableCount) available"
    }
}

private struct TodayCard: View {
    let state: DashboardSourceState<ActivitySnapshot>
    let weeklyQuotaUsage: WeeklyQuotaDailyUsage?
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    var body: some View {
        let snapshot = self.state.value
        let totals = snapshot?.today
        DashboardCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Today")
                        .font(.system(size: 12, weight: .semibold))
                    if let totals {
                        Text("\(totals.sessionCount) sessions · \(totals.requestCount) turns")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let totals {
                        Text(totals.tokens.total.compactCount)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("tokens")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    } else {
                        InlinePlaceholder(
                            text: self.state.isRefreshing ? "Scanning activity…" : "No activity today")
                    }
                }
                .frame(height: 26)

                ActivityTotalsBreakdown(
                    totals: totals ?? .empty,
                    firstTokenText: totals?.menuAverageTTFTText ?? snapshot?.menuAverageTTFTText,
                    speedText: totals?.menuAverageTPSText ?? snapshot?.menuAverageTPSText,
                    weeklyQuotaUsage: self.weeklyQuotaUsage,
                    usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                    accentColor: self.accentColor)
                    .padding(.top, 8)
            }
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

/// Token mix legend plus a labelled row of headline numbers; shared by the Today card
/// and the activity detail submenu.
struct ActivityTotalsBreakdown: View {
    let totals: ActivityTotals
    let firstTokenText: String?
    let speedText: String?
    var weeklyQuotaUsage: WeeklyQuotaDailyUsage?
    var usesWeekdayWeeklyPacing = false
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TokenStackedBar(tokens: self.totals.tokens)
                .frame(height: 6)

            HStack(spacing: 16) {
                TokenLegend(
                    label: "Input",
                    value: self.totals.tokens.displayedInput,
                    costUsd: self.totals.tokenCosts?.displayedInput,
                    color: TokenBarPalette.input)
                TokenLegend(
                    label: "Output",
                    value: self.totals.tokens.output,
                    costUsd: self.totals.tokenCosts?.output,
                    color: TokenBarPalette.output)
            }
            .frame(height: 14)
            .padding(.top, 10)
            HStack(spacing: 16) {
                TokenLegend(
                    label: "Cache",
                    value: self.totals.tokens.displayedCache,
                    costUsd: self.totals.tokenCosts?.displayedCache,
                    color: TokenBarPalette.cache)
                TokenLegend(
                    label: "Reasoning",
                    value: self.totals.tokens.reasoning,
                    costUsd: self.totals.tokenCosts?.reasoning,
                    color: TokenBarPalette.reasoning)
            }
            .frame(height: 14)
            .padding(.top, 5)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 10)

            HStack(alignment: .top, spacing: 8) {
                StatCell(
                    value: self.totals.costUsd.costText(tokenTotal: self.totals.tokens.total),
                    label: "cost")
                if let usage = self.weeklyQuotaUsage {
                    StatCell(
                        value: usage.menuValueText,
                        label: "weekly quota",
                        tint: usage.tint(
                            usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                            accentColor: self.accentColor))
                        .help(usage.helpText(usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing))
                }
                StatCell(value: self.totals.tokens.cachePercentageText, label: "cache hit")
                StatCell(value: self.firstTokenText ?? "—", label: "first token")
                StatCell(
                    value: self.speedText.map { $0.replacingOccurrences(of: " tok/s", with: "") } ?? "—",
                    label: "tok/s")
            }
            .frame(height: 30)
            .padding(.top, 8)
        }
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(self.value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(self.tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(self.label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TokenStackedBar: View {
    let tokens: TokenBreakdown

    private var components: [TokenComponent] {
        [
            TokenComponent(id: "input", value: self.tokens.displayedInput, color: TokenBarPalette.input),
            TokenComponent(id: "output", value: self.tokens.output, color: TokenBarPalette.output),
            TokenComponent(id: "cache", value: self.tokens.displayedCache, color: TokenBarPalette.cache),
            TokenComponent(id: "reasoning", value: self.tokens.reasoning, color: TokenBarPalette.reasoning),
        ].filter { $0.value > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(TokenBarPalette.track)
                if self.tokens.total > 0 {
                    HStack(spacing: 1) {
                        ForEach(self.components) { component in
                            Rectangle()
                                .fill(component.color)
                                .frame(
                                    width: max(
                                        2,
                                        (proxy.size.width - CGFloat(max(0, self.components.count - 1)))
                                            * CGFloat(component.value) / CGFloat(self.tokens.total)))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
        }
    }
}

private struct TokenComponent: Identifiable {
    let id: String
    let value: Int64
    let color: Color
}

private struct TokenLegend: View {
    let label: String
    let value: Int64
    let costUsd: Double?
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(self.color)
                .frame(width: 6, height: 6)
            Text(self.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(self.value.compactCount)
                .monospacedDigit()
            Text(self.costText ?? "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity)
        .lineLimit(1)
    }

    private var costText: String? {
        guard let costUsd = self.costUsd, costUsd.isFinite, costUsd >= 0 else { return nil }
        return costUsd.tokenComponentCostText
    }
}

struct ActivitySummarySection: View {
    static let preferredHeight: CGFloat = 133
    private static let cardHeight: CGFloat = 127

    let state: DashboardSourceState<ActivitySnapshot>
    let accentColor: Color
    let showsChevron: Bool

    private var days: [DailySummary] {
        Array((self.state.value?.days ?? []).sorted { $0.date < $1.date }.suffix(30))
    }

    private var lastSevenDays: [DailySummary] {
        Array(self.days.suffix(7))
    }

    var body: some View {
        VStack(spacing: 0) {
            DashboardCard {
                self.content
            }
            .frame(height: Self.cardHeight)
            Spacer(minLength: 0)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Activity")
                    .font(.system(size: 12, weight: .semibold))
                Text("30 days")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(self.totalTokens.compactCount)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
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
            .frame(height: 18)

            ZStack {
                Chart {
                    ForEach(self.days) { day in
                        BarMark(
                            x: .value("Day", day.date),
                            y: .value("Tokens", day.tokens.total))
                            .foregroundStyle(
                                day.id == self.days.last?.id
                                    ? self.accentColor
                                    : self.accentColor.opacity(0.5))
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
            .frame(height: 52)
            .padding(.top, 6)
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

            HStack(spacing: 4) {
                Text("Last 7 days \(self.sevenDayTokens.compactCount)")
                Spacer(minLength: 6)
                Text(
                    "\(self.requestCount) turns · \(self.averageTokens.compactCount)/day"
                        + " · Cache \(self.totalCachePercentageText)")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: 13)
            .padding(.top, 4)
        }
    }

    private var totalTokens: Int64 {
        self.days.reduce(0) { $0 + $1.tokens.total }
    }

    private var sevenDayTokens: Int64 {
        self.lastSevenDays.reduce(0) { $0 + $1.tokens.total }
    }

    private var maximumTokens: Int64 {
        self.days.map(\.tokens.total).max() ?? 0
    }

    private var requestCount: Int {
        self.days.reduce(0) { $0 + $1.requestCount }
    }

    private var totalCachePercentageText: String {
        self.days.reduce(TokenBreakdown.zero) { total, day in
            TokenBreakdown(
                input: total.input.saturatingAdd(day.tokens.input),
                output: total.output.saturatingAdd(day.tokens.output),
                cacheRead: total.cacheRead.saturatingAdd(day.tokens.cacheRead),
                cacheWrite: total.cacheWrite.saturatingAdd(day.tokens.cacheWrite),
                reasoning: total.reasoning.saturatingAdd(day.tokens.reasoning))
        }.cachePercentageText
    }

    private var averageTokens: Int64 {
        guard !self.days.isEmpty else { return 0 }
        return self.totalTokens / Int64(self.days.count)
    }
}

private struct InlinePlaceholder: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Token mix colors stay fixed so the user's accent theme never collides with a category.
enum TokenBarPalette {
    static let input = Color(red: 0.26, green: 0.52, blue: 0.96)
    static let output = Color(red: 0.62, green: 0.42, blue: 0.92)
    static let cache = Color(red: 0.20, green: 0.68, blue: 0.60)
    static let reasoning = Color(red: 0.95, green: 0.62, blue: 0.22)
    static let positive = Color(red: 0.20, green: 0.66, blue: 0.48)
    static let track = Color.primary.opacity(0.09)
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
