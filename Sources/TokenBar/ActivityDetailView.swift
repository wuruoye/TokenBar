import Charts
import SwiftUI
import TokenBarCore

struct ActivityDetailView: View {
    static let preferredWidth: CGFloat = 580
    static let preferredHeight: CGFloat = 450

    @Bindable var model: DashboardModel
    let accentColor: Color

    @State private var selectedDate: String?

    private var days: [DailySummary] {
        Array((self.model.activitySnapshot?.days ?? []).sorted { $0.date < $1.date }.suffix(30))
    }

    private var selectedDay: DailySummary? {
        if let selectedDate,
           let selected = self.days.first(where: { $0.date == selectedDate })
        {
            return selected
        }
        return self.days.last(where: { $0.tokens.total > 0 }) ?? self.days.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.header
            self.chart
                .frame(height: 150)
            Divider()
            if let day = self.selectedDay {
                self.dayDetail(day)
            } else {
                ContentUnavailableView(
                    "No activity",
                    systemImage: "chart.bar",
                    description: Text("Activity will appear after Codex sessions are scanned."))
            }
        }
        .padding(16)
        .frame(
            width: Self.preferredWidth,
            height: Self.preferredHeight,
            alignment: .topLeading)
        .background(Color.clear)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Activity Detail")
                .font(.system(size: 14, weight: .semibold))
            Text("30 days")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            if let snapshot = self.model.activitySnapshot {
                Text(
                    snapshot.days.suffix(30)
                        .reduce(Int64(0)) { $0.saturatingAdd($1.tokens.total) }
                        .compactCount)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        let maximum = max(1, self.days.map(\.tokens.total).max() ?? 0)
        let ticks = self.axisTickIndices

        return Chart {
            ForEach(Array(self.days.enumerated()), id: \.element.id) { index, day in
                BarMark(
                    x: .value("Day", Double(index)),
                    y: .value("Tokens", day.tokens.total))
                    .foregroundStyle(
                        day.id == self.selectedDay?.id
                            ? self.accentColor
                            : self.accentColor.opacity(0.38))
                    .cornerRadius(2)
            }

            if let selectedIndex = self.selectedIndex {
                RuleMark(x: .value("Selected", Double(selectedIndex)))
                    .foregroundStyle(self.accentColor.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisTick().foregroundStyle(Color.secondary.opacity(0.3))
                AxisValueLabel {
                    if let rawIndex = value.as(Double.self) {
                        let index = Int(rawIndex.rounded())
                        if self.days.indices.contains(index) {
                            Text(self.days[index].date.shortDateLabel)
                                .font(.system(size: 9.5))
                                .offset(x: index == self.days.count - 1 ? -14 : 0)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let tokens = value.as(Int64.self) {
                        Text(tokens.compactCount)
                            .font(.system(size: 9.5))
                    }
                }
            }
        }
        .chartYScale(domain: 0 ... maximum)
        .chartXScale(
            domain: -0.6 ... max(0.6, Double(self.days.count - 1) + 0.6),
            range: .plotDimension(startPadding: 12, endPadding: 24))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case let .active(location) = phase,
                              let plotFrame = proxy.plotFrame
                        else {
                            return
                        }
                        let frame = geometry[plotFrame]
                        guard frame.contains(location), !self.days.isEmpty else { return }
                        let plotX = location.x - frame.minX
                        guard let rawIndex = proxy.value(atX: plotX, as: Double.self) else { return }
                        let index = min(max(Int(rawIndex.rounded()), 0), self.days.count - 1)
                        self.selectedDate = self.days[index].date
                    }
            }
        }
        .transaction { $0.animation = nil }
    }

    private func dayDetail(_ day: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.date)
                        .font(.system(size: 13, weight: .semibold))
                    Text(
                        "\(day.sessionCount) sessions · \(day.requestCount) turns · "
                            + "Cache× \(day.tokens.cacheReuseText)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(day.tokens.total.compactCount)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(day.costUsd.costText(tokenTotal: day.tokens.total))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TokenBarVisualStyle.costAccentColor)
            }

            Text("Models")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            if day.models.isEmpty {
                Text("Model breakdown is unavailable for cached activity. Refresh to load it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else if day.models.count <= 3 {
                self.modelRows(day)
                    .frame(maxHeight: 125, alignment: .top)
            } else {
                ScrollView {
                    self.modelRows(day)
                }
                .frame(height: 125)
            }
        }
    }

    private func modelRows(_ day: DailySummary) -> some View {
        VStack(spacing: 7) {
            ForEach(Array(day.models.enumerated()), id: \.offset) { _, model in
                ActivityModelRow(
                    usage: model,
                    maximumTokens: day.models.map(\.tokens.total).max() ?? 1,
                    accentColor: self.accentColor)
            }
        }
    }

    private var selectedIndex: Int? {
        guard let selectedDay else { return nil }
        return self.days.firstIndex(where: { $0.id == selectedDay.id })
    }

    private var axisTickIndices: [Double] {
        guard !self.days.isEmpty else { return [] }
        let last = self.days.count - 1
        return Array(Set([0, last / 4, last / 2, last * 3 / 4, last]))
            .sorted()
            .map(Double.init)
    }
}

private struct ActivityModelRow: View {
    let usage: DailyModelSummary
    let maximumTokens: Int64
    let accentColor: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(self.usage.model)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(
                        "\(self.usage.provider) · \(self.usage.requestCount) turns · "
                            + "\(self.usage.sessionCount) sessions")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(self.usage.tokens.total.compactCount)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Cache× \(self.usage.tokens.cacheReuseText)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(self.usage.costUsd.costText(tokenTotal: self.usage.tokens.total))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TokenBarVisualStyle.costAccentColor)
            }

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(self.accentColor.opacity(0.72))
                            .frame(width: proxy.size.width * self.fraction)
                    }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
    }

    private var fraction: CGFloat {
        guard self.maximumTokens > 0 else { return 0 }
        return CGFloat(self.usage.tokens.total) / CGFloat(self.maximumTokens)
    }
}
