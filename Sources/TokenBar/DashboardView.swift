import Charts
import SwiftUI
import TokenBarCore

struct DashboardSummaryView: View {
    @Bindable var model: DashboardModel
    let showsFiveHour: Bool
    let showsResetCredits: Bool
    let accentColor: Color

    static func preferredHeight(showsFiveHour: Bool, showsResetCredits: Bool) -> CGFloat {
        DashboardOverviewView.preferredHeight(
            showsFiveHour: showsFiveHour,
            showsResetCredits: showsResetCredits)
            + ActivitySummarySection.preferredHeight
            + 1
    }

    var body: some View {
        VStack(spacing: 0) {
            DashboardOverviewView(
                model: self.model,
                showsFiveHour: self.showsFiveHour,
                showsResetCredits: self.showsResetCredits,
                accentColor: self.accentColor)
            Divider().padding(.horizontal, 12)
            ActivitySummarySection(
                state: self.model.activity,
                accentColor: self.accentColor,
                showsChevron: false)
                .frame(height: ActivitySummarySection.preferredHeight)
        }
        .background(Color.clear)
    }
}

struct DashboardOverviewView: View {
    private static let headerHeight: CGFloat = 34
    private static let quotaHeight: CGFloat = 78
    private static let quotaWithFiveHourHeight: CGFloat = 122
    private static let resetCreditsHeight: CGFloat = 30
    private static let todayHeight: CGFloat = 122
    private static let weeklyResetActivityHeight: CGFloat = 64

    @Bindable var model: DashboardModel
    let showsFiveHour: Bool
    let showsResetCredits: Bool
    let accentColor: Color

    static func preferredHeight(showsFiveHour: Bool, showsResetCredits: Bool) -> CGFloat {
        self.headerHeight
            + (showsFiveHour ? self.quotaWithFiveHourHeight : self.quotaHeight)
            + (showsResetCredits ? self.resetCreditsHeight : 0)
            + self.todayHeight
            + self.weeklyResetActivityHeight
            + 2
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
                .frame(height: Self.headerHeight)
            Divider().padding(.horizontal, 12)
            QuotaSummarySection(
                state: self.model.quota,
                showsFiveHour: self.showsFiveHour,
                accentColor: self.accentColor)
                .frame(height: self.quotaSectionHeight)
            Divider().padding(.horizontal, 12)
            TodaySummarySection(
                state: self.model.activity,
                accentColor: self.accentColor)
                .frame(height: Self.todayHeight)
            Divider().padding(.horizontal, 12)
            WeeklyResetActivitySection(
                quota: self.model.quotaSnapshot,
                state: self.model.activity,
                accentColor: self.accentColor)
                .frame(height: Self.weeklyResetActivityHeight)
        }
        .background(Color.clear)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("TokenBar")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if self.model.quota.isRefreshing || self.model.activity.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(self.updatedText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
    }

    private var updatedText: String {
        guard let date = self.model.activitySnapshot?.generatedAt else {
            return self.model.activity.isRefreshing ? "Refreshing…" : "Waiting for data"
        }
        return "Updated \(date.compactPastText)"
    }

    private var quotaSectionHeight: CGFloat {
        (self.showsFiveHour ? Self.quotaWithFiveHourHeight : Self.quotaHeight)
            + (self.showsResetCredits ? Self.resetCreditsHeight : 0)
    }
}

private struct QuotaSummarySection: View {
    let state: DashboardSourceState<QuotaSnapshot>
    let showsFiveHour: Bool
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quota")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if self.state.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(self.state.errorMessage ?? "Quota refresh failed")
                }
            }

            if let snapshot = self.state.value, let weekly = snapshot.weekly {
                WeeklyQuotaProgressRow(
                    window: weekly,
                    measuredAt: snapshot.updatedAt,
                    accentColor: self.accentColor)
            } else {
                InlinePlaceholder(text: self.state.isRefreshing ? "Loading weekly quota…" : "Weekly quota unavailable")
            }

            if self.showsFiveHour, let fiveHour = self.state.value?.session {
                QuotaProgressRow(title: "5-hour", window: fiveHour, accentColor: self.accentColor)
            }

            if let resetCredits = self.state.value?.resetCredits {
                ResetCreditsRow(snapshot: resetCredits)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct WeeklyQuotaProgressRow: View {
    let window: QuotaWindowSnapshot
    let measuredAt: Date
    let accentColor: Color

    var body: some View {
        if let reset = self.window.resetsAt,
           reset > Date(),
           let pacing = self.window.weeklyPacing(at: self.measuredAt)
        {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Weekly")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("· \(self.resetText)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("\(Int((100 - pacing.actualUsedPercent).rounded()))% left")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                WeeklyQuotaSegmentedBar(
                    pacing: pacing,
                    tint: self.tint)

                HStack(spacing: 4) {
                    Text(
                        "Day \(pacing.currentSegment)/\(WeeklyQuotaPacing.segmentCount)"
                            + " · \(Int(pacing.actualUsedPercent.rounded()))% used")
                    Spacer(minLength: 6)
                    Text("\(Int(pacing.expectedUsedPercent.rounded()))% expected")
                    Text("· \(self.deltaText(pacing))")
                        .foregroundStyle(self.deltaColor(pacing))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .help(self.helpText(pacing))
        } else {
            QuotaProgressRow(title: "Weekly", window: self.window, accentColor: self.accentColor)
        }
    }

    private var tint: Color {
        switch self.window.remainingPercent {
        case ..<10: .red
        case ..<20: .orange
        default: self.accentColor
        }
    }

    private var resetText: String {
        guard let reset = self.window.resetsAt else { return "reset unavailable" }
        return "resets \(reset.compactFutureText)"
    }

    private func deltaText(_ pacing: WeeklyQuotaPacing) -> String {
        let delta = pacing.deltaPercentagePoints
        guard abs(delta) >= 1 else { return "on pace" }
        return "\(Int(abs(delta).rounded()))pp \(delta > 0 ? "over" : "under")"
    }

    private func deltaColor(_ pacing: WeeklyQuotaPacing) -> Color {
        let delta = pacing.deltaPercentagePoints
        if delta >= 1 {
            return .orange
        }
        if delta <= -1 {
            return TokenBarPalette.mint
        }
        return .secondary
    }

    private func helpText(_ pacing: WeeklyQuotaPacing) -> String {
        let start = pacing.windowStart.formatted(date: .abbreviated, time: .shortened)
        let end = pacing.windowEnd.formatted(date: .abbreviated, time: .shortened)
        return "Weekly cycle \(start) – \(end). Each segment is one seventh of the quota window. "
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
                    ForEach(0 ..< WeeklyQuotaPacing.segmentCount, id: \.self) { index in
                        GeometryReader { segment in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.15))
                                Rectangle()
                                    .fill(self.tint)
                                    .frame(width: segment.size.width * self.fillFraction(for: index))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                    }
                }
                .frame(height: 8)

                Capsule()
                    .fill(Color.primary.opacity(0.72))
                    .frame(width: 1.5, height: 12)
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
        let segmentPercent = 100 / Double(WeeklyQuotaPacing.segmentCount)
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

private struct QuotaProgressRow: View {
    let title: String
    let window: QuotaWindowSnapshot
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(self.title)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text("\(Int(self.window.remainingPercent.clamped(to: 0 ... 100).rounded()))% left")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.17))
                    Capsule()
                        .fill(self.tint)
                        .frame(width: proxy.size.width * self.window.remainingPercent.clamped(to: 0 ... 100) / 100)
                }
            }
            .frame(height: 6)

            Text(self.resetText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch self.window.remainingPercent {
        case ..<10: .red
        case ..<20: .orange
        default: self.accentColor
        }
    }

    private var resetText: String {
        guard let reset = self.window.resetsAt else { return "Reset time unavailable" }
        return "Resets \(reset.compactFutureText)"
    }
}

private struct ResetCreditsRow: View {
    let snapshot: QuotaResetCreditsSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Extra resets")
                .font(.system(size: 11.5, weight: .medium))
            Spacer()
            Text(self.countText)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let expiration = self.snapshot.nextExpiresAt {
                Text("· expires \(expiration.compactFutureText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var countText: String {
        self.snapshot.availableCount == 1
            ? "1 available"
            : "\(self.snapshot.availableCount) available"
    }
}

private struct WeeklyResetActivitySection: View {
    let quota: QuotaSnapshot?
    let state: DashboardSourceState<ActivitySnapshot>
    let accentColor: Color

    private var pacing: WeeklyQuotaPacing? {
        guard let quota,
              let weekly = quota.weekly,
              let reset = weekly.resetsAt,
              reset > Date()
        else {
            return nil
        }
        return weekly.weeklyPacing(at: quota.updatedAt)
    }

    private var summary: ActivityRangeSummary? {
        guard let pacing = self.pacing,
              let summary = self.state.value?.weeklySinceReset,
              abs(summary.startedAt.timeIntervalSince(pacing.windowStart)) < 1
        else {
            return nil
        }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Since weekly reset")
                    .font(.system(size: 12, weight: .semibold))
                if let pacing = self.pacing {
                    Text("Day \(pacing.currentSegment)/\(WeeklyQuotaPacing.segmentCount)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let totals = self.summary?.totals {
                    Text(totals.tokens.total.compactCount)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tokens")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            TokenStackedBar(
                tokens: self.summary?.totals.tokens ?? .zero,
                accentColor: self.accentColor)

            if let totals = self.summary?.totals {
                HStack {
                    Text(
                        "Cache× \(totals.tokens.cacheReuseText) · "
                            + "\(totals.sessionCount) sessions · \(totals.requestCount) turns")
                    Spacer(minLength: 6)
                    Text(totals.costUsd.costText(tokenTotal: totals.tokens.total))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarVisualStyle.costAccentColor)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                InlinePlaceholder(text: self.placeholderText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var placeholderText: String {
        if self.pacing == nil {
            return "Waiting for a valid weekly reset window…"
        }
        if self.state.isRefreshing {
            return "Calculating activity since reset…"
        }
        return self.state.errorMessage ?? "Weekly reset activity unavailable"
    }
}

private struct TodaySummarySection: View {
    let state: DashboardSourceState<ActivitySnapshot>
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let totals = self.state.value?.today {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(totals.tokens.total.compactCount)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tokens")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                TokenStackedBar(tokens: totals.tokens, accentColor: self.accentColor)

                HStack(spacing: 16) {
                    TokenLegend(label: "Input", value: totals.tokens.input, color: self.accentColor)
                    TokenLegend(label: "Output", value: totals.tokens.output, color: TokenBarPalette.blue)
                }
                HStack(spacing: 16) {
                    TokenLegend(
                        label: "Cache",
                        value: totals.tokens.cacheRead + totals.tokens.cacheWrite,
                        color: TokenBarPalette.mint)
                    TokenLegend(label: "Reasoning", value: totals.tokens.reasoning, color: TokenBarPalette.orange)
                }

                HStack {
                    Text(
                        "Cache× \(totals.tokens.cacheReuseText) · "
                            + "\(totals.sessionCount) sessions · \(totals.requestCount) turns")
                    Spacer()
                    Text(totals.costUsd.costText(tokenTotal: totals.tokens.total))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarVisualStyle.costAccentColor)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Today")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    InlinePlaceholder(text: self.state.isRefreshing ? "Scanning activity…" : "No activity today")
                }
                TokenStackedBar(tokens: .zero, accentColor: self.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct TokenStackedBar: View {
    let tokens: TokenBreakdown
    let accentColor: Color

    private var components: [TokenComponent] {
        [
            TokenComponent(id: "input", value: self.tokens.input, color: self.accentColor),
            TokenComponent(id: "output", value: self.tokens.output, color: TokenBarPalette.blue),
            TokenComponent(
                id: "cache",
                value: self.tokens.cacheRead + self.tokens.cacheWrite,
                color: TokenBarPalette.mint),
            TokenComponent(id: "reasoning", value: self.tokens.reasoning, color: TokenBarPalette.orange),
        ].filter { $0.value > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                if self.tokens.total > 0 {
                    HStack(spacing: 1) {
                        ForEach(self.components) { component in
                            Rectangle()
                                .fill(component.color)
                                .frame(
                                    width: max(
                                        1,
                                        (proxy.size.width - CGFloat(max(0, self.components.count - 1)))
                                            * CGFloat(component.value) / CGFloat(self.tokens.total)))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 8)
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
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity)
    }
}

struct ActivitySummarySection: View {
    static let preferredHeight: CGFloat = 130

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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(.system(size: 12, weight: .semibold))
                Text("30 days · Cache× \(self.totalCacheReuseText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
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

            ZStack {
                Chart(self.days) { day in
                    BarMark(
                        x: .value("Day", day.date),
                        y: .value("Tokens", day.tokens.total))
                        .foregroundStyle(
                            day.id == self.days.last?.id
                                ? self.accentColor
                                : self.accentColor.opacity(0.52))
                        .cornerRadius(1.5)
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
            .frame(height: 62)
            .transaction { $0.animation = nil }

            HStack {
                Text(self.days.first?.date.shortDateLabel ?? "")
                Spacer()
                Text(self.days.last?.date.shortDateLabel ?? "")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)

            HStack {
                Text("7D \(self.sevenDayTokens.compactCount)")
                Spacer()
                Text("\(self.requestCount) turns · \(self.averageTokens.compactCount)/day")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    private var totalCacheReuseText: String {
        self.days.reduce(TokenBreakdown.zero) { total, day in
            TokenBreakdown(
                input: total.input.saturatingAdd(day.tokens.input),
                output: total.output.saturatingAdd(day.tokens.output),
                cacheRead: total.cacheRead.saturatingAdd(day.tokens.cacheRead),
                cacheWrite: total.cacheWrite.saturatingAdd(day.tokens.cacheWrite),
                reasoning: total.reasoning.saturatingAdd(day.tokens.reasoning))
        }.cacheReuseText
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

private enum TokenBarPalette {
    static let indigo = Color(red: 0.48, green: 0.41, blue: 0.86)
    static let blue = Color(red: 0.28, green: 0.58, blue: 0.88)
    static let mint = Color(red: 0.24, green: 0.69, blue: 0.59)
    static let orange = Color(red: 0.91, green: 0.57, blue: 0.25)
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
