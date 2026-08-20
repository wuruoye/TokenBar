import Foundation

public struct WeeklyQuotaPacing: Equatable, Sendable {
    public let windowStart: Date
    public let windowEnd: Date
    public let weekdaysOnly: Bool
    public let segmentCount: Int
    public let currentSegment: Int
    public let actualUsedPercent: Double
    public let expectedUsedPercent: Double
    public let deltaPercentagePoints: Double
}

public extension QuotaWindowSnapshot {
    func weeklyPacing(
        at referenceDate: Date,
        weekdaysOnly: Bool,
        calendar: Calendar = .autoupdatingCurrent) -> WeeklyQuotaPacing?
    {
        guard self.usedPercent.isFinite,
              let windowMinutes = self.windowMinutes,
              windowMinutes > 0,
              let windowEnd = self.resetsAt,
              windowEnd.timeIntervalSinceReferenceDate.isFinite
        else {
            return nil
        }

        let duration = TimeInterval(windowMinutes) * 60
        guard duration.isFinite, duration > 0 else { return nil }

        let windowStart = windowEnd.addingTimeInterval(-duration)
        let elapsed = referenceDate.timeIntervalSince(windowStart)
        let timeUntilReset = windowEnd.timeIntervalSince(referenceDate)
        guard timeUntilReset > 0,
              timeUntilReset <= duration,
              elapsed >= 0,
              elapsed <= duration
        else {
            return nil
        }

        let actualUsedPercent = self.usedPercent.clamped(to: 0 ... 100)
        if elapsed == 0, actualUsedPercent > 0 {
            return nil
        }
        let progress = weekdaysOnly
            ? Self.weekdayProgress(
                elapsed: elapsed,
                duration: duration,
                windowStart: windowStart,
                calendar: calendar)
            : Self.everyDayProgress(elapsed: elapsed, duration: duration)

        return WeeklyQuotaPacing(
            windowStart: windowStart,
            windowEnd: windowEnd,
            weekdaysOnly: weekdaysOnly,
            segmentCount: progress.segmentCount,
            currentSegment: progress.currentSegment,
            actualUsedPercent: actualUsedPercent,
            expectedUsedPercent: progress.expectedUsedPercent,
            deltaPercentagePoints: actualUsedPercent - progress.expectedUsedPercent)
    }

    private static func everyDayProgress(
        elapsed: TimeInterval,
        duration: TimeInterval) -> WeeklyQuotaProgress
    {
        let segmentCount = 7
        let segmentDuration = duration / Double(segmentCount)
        let zeroBasedSegment = Int((elapsed / segmentDuration).rounded(.down))
            .clamped(to: 0 ... segmentCount - 1)
        return WeeklyQuotaProgress(
            segmentCount: segmentCount,
            currentSegment: zeroBasedSegment + 1,
            expectedUsedPercent: (elapsed / duration * 100).clamped(to: 0 ... 100))
    }

    private static func weekdayProgress(
        elapsed: TimeInterval,
        duration: TimeInterval,
        windowStart: Date,
        calendar: Calendar) -> WeeklyQuotaProgress
    {
        let segmentCount = 5
        let referenceDate = windowStart.addingTimeInterval(elapsed)
        let windowEnd = windowStart.addingTimeInterval(duration)
        var dayStart = calendar.startOfDay(for: windowStart)
        var weekdayIntervals: [DateInterval] = []
        while dayStart < windowEnd {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let weekday = calendar.component(.weekday, from: dayStart)
            if weekday != 1, weekday != 7 {
                let intervalStart = max(dayStart, windowStart)
                let intervalEnd = min(nextDay, windowEnd)
                if intervalStart < intervalEnd {
                    weekdayIntervals.append(DateInterval(
                        start: intervalStart,
                        end: intervalEnd))
                }
            }
            dayStart = nextDay
        }

        let totalWeekdayDuration = weekdayIntervals.reduce(0) { $0 + $1.duration }
        let elapsedWeekdayDuration = weekdayIntervals.reduce(into: 0.0) { result, interval in
            result += referenceDate.timeIntervalSince(interval.start)
                .clamped(to: 0 ... interval.duration)
        }
        let expectedUsedPercent = (elapsedWeekdayDuration / totalWeekdayDuration * 100)
            .clamped(to: 0 ... 100)
        let segmentProgress = expectedUsedPercent / (100 / Double(segmentCount))
        let isWithinWorkday = weekdayIntervals.contains {
            referenceDate >= $0.start && referenceDate < $0.end
        }
        let currentSegment = isWithinWorkday
            ? Int(segmentProgress.rounded(.down)) + 1
            : Int(segmentProgress.rounded(.up))

        return WeeklyQuotaProgress(
            segmentCount: segmentCount,
            currentSegment: currentSegment.clamped(to: 0 ... segmentCount),
            expectedUsedPercent: expectedUsedPercent)
    }
}

private struct WeeklyQuotaProgress {
    let segmentCount: Int
    let currentSegment: Int
    let expectedUsedPercent: Double
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
