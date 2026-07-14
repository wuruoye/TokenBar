import Foundation

public struct WeeklyQuotaPacing: Equatable, Sendable {
    public static let segmentCount = 7

    public let windowStart: Date
    public let windowEnd: Date
    public let currentSegment: Int
    public let actualUsedPercent: Double
    public let expectedUsedPercent: Double
    public let deltaPercentagePoints: Double
}

public extension QuotaWindowSnapshot {
    func weeklyPacing(at referenceDate: Date) -> WeeklyQuotaPacing? {
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
        let expectedUsedPercent = (elapsed / duration * 100).clamped(to: 0 ... 100)
        let segmentDuration = duration / Double(WeeklyQuotaPacing.segmentCount)
        let zeroBasedSegment = Int((elapsed / segmentDuration).rounded(.down))
            .clamped(to: 0 ... WeeklyQuotaPacing.segmentCount - 1)

        return WeeklyQuotaPacing(
            windowStart: windowStart,
            windowEnd: windowEnd,
            currentSegment: zeroBasedSegment + 1,
            actualUsedPercent: actualUsedPercent,
            expectedUsedPercent: expectedUsedPercent,
            deltaPercentagePoints: actualUsedPercent - expectedUsedPercent)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
