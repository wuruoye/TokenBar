import Charts
import SwiftUI
import TokenBarCore

struct MemorySummarySection: View {
    static let preferredHeight: CGFloat = 114

    let usage: MemoryUsageSnapshot?
    let receiverState: MemoryReceiverState
    let configurationState: CodexMemoryConfigurationState
    let accentColor: Color

    private var totals: MemoryUsageTotals {
        self.usage?.today ?? .zero
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Codex Memory")
                    .font(.system(size: 12, weight: .semibold))
                Text("Today")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(self.totals.total.compactCount)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                self.phaseSummary("Phase 1", usage: self.totals.phase1, color: self.accentColor)
                self.phaseSummary("Phase 2", usage: self.totals.phase2, color: .blue)
            }

            let combined = self.totals.combined
            HStack(spacing: 10) {
                self.inlineMetric("In", combined.input)
                self.inlineMetric("Cached", combined.cachedInput)
                self.inlineMetric("Out", combined.output)
                self.inlineMetric("Reason", combined.reasoningOutput)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(self.statusColor)
                    .frame(width: 6, height: 6)
                Text(self.statusText)
                    .lineLimit(1)
                Spacer()
                Text("Cost —")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func phaseSummary(
        _ label: String,
        usage: MemoryPhaseUsage,
        color: Color) -> some View
    {
        HStack(spacing: 6) {
            Capsule()
                .fill(color.opacity(0.78))
                .frame(width: 3, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text(usage.total.compactCount)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
    }

    private func inlineMetric(_ label: String, _ value: Int64) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value.compactCount).monospacedDigit()
        }
        .font(.system(size: 9.5))
    }

    private var statusText: String {
        guard self.receiverState.isListening else {
            return "Receiver \(self.receiverState.title.lowercased())"
        }
        guard self.configurationState == .configured else {
            return "Codex config: \(self.configurationState.title.lowercased())"
        }
        guard self.usage?.lastReceivedAt != nil else {
            return "Restart Codex/ChatGPT · no OTLP yet"
        }
        if let lastMemoryReceivedAt = self.usage?.lastMemoryReceivedAt {
            return "Memory export \(lastMemoryReceivedAt.memoryRelativeText)"
        }
        return "Connected · waiting for a Memory run"
    }

    private var statusColor: Color {
        guard self.receiverState.isListening else { return .orange }
        guard self.configurationState == .configured else { return .orange }
        return self.usage?.lastReceivedAt == nil ? .orange : .green
    }
}

struct MemoryDetailView: View {
    static let preferredWidth: CGFloat = 540
    static let preferredHeight: CGFloat = 560

    @Bindable var model: DashboardModel
    @Bindable var telemetry: MemoryTelemetryController
    let accentColor: Color

    @State private var selectedDate: String?

    private var usage: MemoryUsageSnapshot? {
        self.model.activitySnapshot?.memoryUsage
    }

    private var rangeTotals: MemoryUsageTotals {
        self.usage?.rangeTotals ?? .zero
    }

    private var days: [MemoryDailySummary] {
        Array((self.usage?.days ?? []).sorted { $0.date < $1.date }.suffix(30))
    }

    private var selectedDay: MemoryDailySummary? {
        if let selectedDate,
           let selected = self.days.first(where: { $0.date == selectedDate })
        {
            return selected
        }
        return self.days.last(where: { $0.totals.total > 0 }) ?? self.days.last
    }

    private var selectedTotals: MemoryUsageTotals {
        self.selectedDay?.totals ?? .zero
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Codex Memory Tokens")
                    .font(.system(size: 14, weight: .semibold))
                Text("30 days")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(self.rangeTotals.total.compactCount)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            ZStack {
                self.chart
                if self.rangeTotals.total == 0 {
                    Text(self.emptyStateText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(height: 120)

            if let day = self.selectedDay {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.date)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(day.totals.total.compactCount)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tokens")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                MemoryPhaseCard(
                    title: "Phase 1 · Extraction",
                    usage: self.selectedTotals.phase1,
                    color: self.accentColor)
                MemoryPhaseCard(
                    title: "Phase 2 · Consolidation",
                    usage: self.selectedTotals.phase2,
                    color: .blue)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                self.statusRow("Receiver", value: self.telemetry.receiverState.title)
                self.statusRow("Codex config", value: self.telemetry.configurationState.title)
                if let usage = self.usage {
                    self.statusRow(
                        "Collecting since",
                        value: usage.collectedFrom.memoryTimestampText)
                    self.statusRow(
                        "Last OTLP export",
                        value: usage.lastReceivedAt?.memoryTimestampText
                            ?? "No Codex connection yet")
                    self.statusRow(
                        "Last Memory export",
                        value: usage.lastMemoryReceivedAt?.memoryTimestampText
                            ?? "No Memory metrics received")
                    self.statusRow(
                        "Local storage",
                        value: "\(usage.observationCount.formatted()) observations · SQLite")
                }
            }
            .font(.system(size: 10.5))

            Text(self.footerText)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.telemetry.configurationState.canInstall {
                Button(
                    self.telemetry.configurationState == .needsAnalytics
                        ? "Enable Codex Analytics"
                        : "Enable Memory Metrics")
                {
                    self.telemetry.installConfiguration()
                }
            }
            if let message = self.telemetry.configurationErrorMessage {
                Text(message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(
            width: Self.preferredWidth,
            height: Self.preferredHeight,
            alignment: .topLeading)
        .background(Color.clear)
        .onAppear {
            self.telemetry.refreshConfiguration()
        }
    }

    private var chart: some View {
        let maximum = max(1, self.days.map(\.totals.total).max() ?? 0)
        let ticks = self.axisTickIndices

        return Chart {
            ForEach(Array(self.days.enumerated()), id: \.element.id) { index, day in
                BarMark(
                    x: .value("Day", Double(index)),
                    y: .value("Phase 1", day.phase1.total))
                    .foregroundStyle(
                        day.id == self.selectedDay?.id
                            ? self.accentColor
                            : self.accentColor.opacity(0.34))
                    .cornerRadius(2)
                BarMark(
                    x: .value("Day", Double(index)),
                    y: .value("Phase 2", day.phase2.total))
                    .foregroundStyle(
                        day.id == self.selectedDay?.id
                            ? Color.blue
                            : Color.blue.opacity(0.34))
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
                                .font(.system(size: 9))
                                .offset(x: index == self.days.count - 1 ? -14 : 0)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let tokens = value.as(Int64.self) {
                        Text(tokens.compactCount).font(.system(size: 9))
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

    private func statusRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1)
        }
    }

    private var footerText: String {
        if self.telemetry.configurationState == .customOpenTelemetry {
            return "TokenBar preserved the existing [otel] block. Point its metrics exporter to \(CodexMemoryConfigurationService.endpoint) with JSON, or keep the custom collector."
        }
        return "Only future Memory runs are counted; historical tokens cannot be backfilled. Uses histogram sum, not observation count. Cached input and reasoning are subsets, and pricing attribution is unavailable."
    }

    private var emptyStateText: String {
        if self.telemetry.configurationState.canInstall {
            return "Enable Memory metrics to start collecting"
        }
        if self.telemetry.configurationState == .customOpenTelemetry {
            return "Point the Codex metrics exporter to TokenBar"
        }
        guard self.telemetry.receiverState.isListening else {
            return "Memory metrics receiver is unavailable"
        }
        guard self.usage?.lastReceivedAt != nil else {
            return "Restart Codex/ChatGPT to activate metrics"
        }
        return "Connected · waiting for Phase 1 or Phase 2"
    }
}

private struct MemoryPhaseCard: View {
    let title: String
    let usage: MemoryPhaseUsage
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(self.color).frame(width: 7, height: 7)
                Text(self.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(self.usage.total.compactCount)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            self.row("Input", self.usage.input)
            self.row("Cached input", self.usage.cachedInput)
            self.row("Cache write", self.usage.cacheWriteInput)
            self.row("Output", self.usage.output)
            self.row("Reasoning", self.usage.reasoningOutput)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: Int64) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.compactCount).monospacedDigit()
        }
        .font(.system(size: 10.5))
    }
}

private extension Date {
    var memoryTimestampText: String {
        self.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .year()
                .hour()
                .minute()
                .locale(Locale(identifier: "en_US")))
    }

    var memoryRelativeText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(self)))
        return switch seconds {
        case 0 ..< 60: "just now"
        case 60 ..< 3_600: "\(seconds / 60)m ago"
        case 3_600 ..< 86_400: "\(seconds / 3_600)h ago"
        default: "\(seconds / 86_400)d ago"
        }
    }
}
