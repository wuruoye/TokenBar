import Foundation
import Testing
@testable import TokenBarCore

@Suite("Weekly quota pacing")
struct WeeklyQuotaPacingTests {
    @Test("derives the reset-anchored window and linear seven-segment pace")
    func derivesPacing() throws {
        let windowStart = Date(timeIntervalSince1970: 1_800_000_000)
        let windowEnd = windowStart.addingTimeInterval(7 * 86_400)
        let referenceDate = windowStart.addingTimeInterval(3.5 * 86_400)
        let window = QuotaWindowSnapshot(
            usedPercent: 62,
            windowMinutes: 10_080,
            resetsAt: windowEnd)

        let pacing = try #require(window.weeklyPacing(at: referenceDate))

        #expect(pacing.windowStart == windowStart)
        #expect(pacing.windowEnd == windowEnd)
        #expect(pacing.currentSegment == 4)
        #expect(abs(pacing.actualUsedPercent - 62) < 0.001)
        #expect(abs(pacing.expectedUsedPercent - 50) < 0.001)
        #expect(abs(pacing.deltaPercentagePoints - 12) < 0.001)
    }

    @Test("clamps actual usage and advances segments on absolute-day boundaries")
    func clampsAndSegments() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(7 * 86_400)
        let window = QuotaWindowSnapshot(
            usedPercent: 125,
            windowMinutes: 10_080,
            resetsAt: reset)

        let pacing = try #require(window.weeklyPacing(at: start.addingTimeInterval(2 * 86_400)))

        #expect(pacing.currentSegment == 3)
        #expect(pacing.actualUsedPercent == 100)
        #expect(abs(pacing.expectedUsedPercent - (2.0 / 7.0 * 100)) < 0.001)
    }

    @Test("rejects incomplete, expired, future, and internally inconsistent windows")
    func rejectsInvalidWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validReset = now.addingTimeInterval(4 * 86_400)

        #expect(QuotaWindowSnapshot(usedPercent: 10, windowMinutes: nil, resetsAt: validReset)
            .weeklyPacing(at: now) == nil)
        #expect(QuotaWindowSnapshot(usedPercent: 10, windowMinutes: 0, resetsAt: validReset)
            .weeklyPacing(at: now) == nil)
        #expect(QuotaWindowSnapshot(usedPercent: 10, windowMinutes: 10_080, resetsAt: nil)
            .weeklyPacing(at: now) == nil)
        #expect(QuotaWindowSnapshot(
            usedPercent: 10,
            windowMinutes: 10_080,
            resetsAt: now.addingTimeInterval(-1))
            .weeklyPacing(at: now) == nil)
        #expect(QuotaWindowSnapshot(
            usedPercent: 10,
            windowMinutes: 10_080,
            resetsAt: now.addingTimeInterval(8 * 86_400))
            .weeklyPacing(at: now) == nil)
        #expect(QuotaWindowSnapshot(
            usedPercent: 10,
            windowMinutes: 10_080,
            resetsAt: now.addingTimeInterval(7 * 86_400))
            .weeklyPacing(at: now) == nil)
        #expect(QuotaWindowSnapshot(
            usedPercent: .nan,
            windowMinutes: 10_080,
            resetsAt: validReset)
            .weeklyPacing(at: now) == nil)
    }
}
