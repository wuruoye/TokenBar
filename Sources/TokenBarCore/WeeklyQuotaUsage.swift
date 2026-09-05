import Foundation

public struct WeeklyQuotaTrackingBaseline: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let usedPercent: Double
}

public struct WeeklyQuotaUsageIncrement: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let usedPercentagePoints: Double
}

public struct WeeklyQuotaDailyUsage: Equatable, Identifiable, Sendable {
    public var id: String { self.date }

    public let date: String
    public let usedPercentagePoints: Double
    public let isPartial: Bool
}

public struct WeeklyQuotaUsageHistory: Codable, Equatable, Sendable {
    private static let retentionDuration: TimeInterval = 32 * 86_400

    public let currentWindowStart: Date
    public let currentWindowEnd: Date
    public let lastSampledAt: Date
    public let highWaterUsedPercent: Double
    public let baselines: [WeeklyQuotaTrackingBaseline]
    public let increments: [WeeklyQuotaUsageIncrement]

    public static func starting(with snapshot: QuotaSnapshot) -> Self? {
        guard let sample = WeeklyQuotaUsageSample(snapshot: snapshot) else { return nil }
        return Self(
            currentWindowStart: sample.windowStart,
            currentWindowEnd: sample.windowEnd,
            lastSampledAt: sample.sampledAt,
            highWaterUsedPercent: sample.usedPercent,
            baselines: [WeeklyQuotaTrackingBaseline(
                sampledAt: sample.sampledAt,
                usedPercent: sample.usedPercent)],
            increments: [])
    }

    public func recording(_ snapshot: QuotaSnapshot) -> Self {
        guard let sample = WeeklyQuotaUsageSample(snapshot: snapshot),
              sample.sampledAt > self.lastSampledAt
        else {
            return self
        }

        let cutoff = sample.sampledAt.addingTimeInterval(-Self.retentionDuration)
        var baselines = self.baselines.filter { $0.sampledAt >= cutoff }
        if let precedingBaseline = self.baselines.last(where: { $0.sampledAt < cutoff }) {
            baselines.insert(precedingBaseline, at: 0)
        }
        var increments = self.increments.filter { $0.sampledAt >= cutoff }
        let isCurrentWindow = self.matches(
            windowStart: sample.windowStart,
            windowEnd: sample.windowEnd)
        let highWaterUsedPercent: Double
        if isCurrentWindow {
            highWaterUsedPercent = max(self.highWaterUsedPercent, sample.usedPercent)
            let increment = highWaterUsedPercent - self.highWaterUsedPercent
            if increment > 0 {
                increments.append(WeeklyQuotaUsageIncrement(
                    sampledAt: sample.sampledAt,
                    usedPercentagePoints: increment))
            }
        } else {
            highWaterUsedPercent = sample.usedPercent
            baselines.append(WeeklyQuotaTrackingBaseline(
                sampledAt: sample.sampledAt,
                usedPercent: sample.usedPercent))
        }

        return Self(
            currentWindowStart: sample.windowStart,
            currentWindowEnd: sample.windowEnd,
            lastSampledAt: sample.sampledAt,
            highWaterUsedPercent: highWaterUsedPercent,
            baselines: baselines,
            increments: increments)
    }

    public func usage(
        at date: Date,
        statisticsTimeZone: TokenBarStatisticsTimeZone) -> WeeklyQuotaDailyUsage?
    {
        self.usage(
            on: Self.dateKey(for: date, timeZone: statisticsTimeZone.weeklyQuotaTimeZone),
            timeZone: statisticsTimeZone.weeklyQuotaTimeZone)
    }

    public func usage(
        on date: String,
        statisticsTimeZone: TokenBarStatisticsTimeZone) -> WeeklyQuotaDailyUsage?
    {
        self.usage(on: date, timeZone: statisticsTimeZone.weeklyQuotaTimeZone)
    }

    func usage(on date: String, timeZone: TimeZone) -> WeeklyQuotaDailyUsage? {
        guard let firstSample = self.baselines.first?.sampledAt else { return nil }
        let firstDate = Self.dateKey(for: firstSample, timeZone: timeZone)
        let lastDate = Self.dateKey(for: self.lastSampledAt, timeZone: timeZone)
        guard date >= firstDate, date <= lastDate else { return nil }

        let usedPercentagePoints = self.increments.reduce(into: 0.0) { total, increment in
            if Self.dateKey(for: increment.sampledAt, timeZone: timeZone) == date {
                total += increment.usedPercentagePoints
            }
        }
        let isPartial = self.baselines.contains { baseline in
            baseline.usedPercent > 0
                && Self.dateKey(for: baseline.sampledAt, timeZone: timeZone) == date
        }
        return WeeklyQuotaDailyUsage(
            date: date,
            usedPercentagePoints: usedPercentagePoints,
            isPartial: isPartial)
    }

    func validated() -> Self? {
        let duration = self.currentWindowEnd.timeIntervalSince(self.currentWindowStart)
        guard duration.isFinite,
              duration > 0,
              self.lastSampledAt >= self.currentWindowStart,
              self.lastSampledAt < self.currentWindowEnd,
              self.highWaterUsedPercent.isFinite,
              (0 ... 100).contains(self.highWaterUsedPercent),
              !self.baselines.isEmpty,
              self.highWaterUsedPercent >= (self.baselines.last?.usedPercent ?? 0),
              self.baselines.allSatisfy({ baseline in
                  baseline.sampledAt <= self.lastSampledAt
                      && baseline.usedPercent.isFinite
                      && (0 ... 100).contains(baseline.usedPercent)
              }),
              self.increments.allSatisfy({ increment in
                  increment.sampledAt <= self.lastSampledAt
                      && increment.usedPercentagePoints.isFinite
                      && increment.usedPercentagePoints > 0
                      && increment.usedPercentagePoints <= 100
              }),
              Self.isChronological(self.baselines.map(\.sampledAt)),
              Self.isChronological(self.increments.map(\.sampledAt)),
              (self.baselines.last?.sampledAt ?? .distantPast) >= self.currentWindowStart
        else {
            return nil
        }
        return self
    }

    private func matches(windowStart: Date, windowEnd: Date) -> Bool {
        abs(self.currentWindowStart.timeIntervalSince(windowStart)) < 1
            && abs(self.currentWindowEnd.timeIntervalSince(windowEnd)) < 1
    }

    private static func dateKey(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }

    private static func isChronological(_ dates: [Date]) -> Bool {
        zip(dates, dates.dropFirst()).allSatisfy { $0 <= $1 }
    }
}

private struct WeeklyQuotaUsageSample {
    let windowStart: Date
    let windowEnd: Date
    let sampledAt: Date
    let usedPercent: Double

    init?(snapshot: QuotaSnapshot) {
        guard let weekly = snapshot.weekly,
              weekly.usedPercent.isFinite,
              let windowMinutes = weekly.windowMinutes,
              windowMinutes > 0,
              let windowEnd = weekly.resetsAt
        else {
            return nil
        }
        let duration = TimeInterval(windowMinutes) * 60
        let windowStart = windowEnd.addingTimeInterval(-duration)
        guard duration.isFinite,
              snapshot.updatedAt >= windowStart,
              snapshot.updatedAt < windowEnd
        else {
            return nil
        }
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.sampledAt = snapshot.updatedAt
        self.usedPercent = min(100, max(0, weekly.usedPercent))
    }
}

private extension TokenBarStatisticsTimeZone {
    var weeklyQuotaTimeZone: TimeZone {
        switch self {
        case .utc: .gmt
        case .local: .autoupdatingCurrent
        }
    }
}
