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

        let pacing = try #require(window.weeklyPacing(
            at: referenceDate,
            weekdaysOnly: false))

        #expect(pacing.windowStart == windowStart)
        #expect(pacing.windowEnd == windowEnd)
        #expect(!pacing.weekdaysOnly)
        #expect(pacing.segmentCount == 7)
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

        let pacing = try #require(window.weeklyPacing(
            at: start.addingTimeInterval(2 * 86_400),
            weekdaysOnly: false))

        #expect(pacing.currentSegment == 3)
        #expect(pacing.actualUsedPercent == 100)
        #expect(abs(pacing.expectedUsedPercent - (2.0 / 7.0 * 100)) < 0.001)
    }

    @Test("advances five weekday segments on local midnight boundaries and pauses on weekends")
    func weekdayPacing() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try #require(calendar.date(from: DateComponents(
            year: 2027,
            month: 1,
            day: 3,
            hour: 20)))
        let reset = start.addingTimeInterval(7 * 86_400)
        let window = QuotaWindowSnapshot(
            usedPercent: 55,
            windowMinutes: 10_080,
            resetsAt: reset)

        let mondayStart = try #require(calendar.date(from: DateComponents(
            year: 2027,
            month: 1,
            day: 4)))
        let mondayNoon = try #require(window.weeklyPacing(
            at: mondayStart.addingTimeInterval(12 * 3_600),
            weekdaysOnly: true,
            calendar: calendar))
        let tuesdayStart = try #require(window.weeklyPacing(
            at: mondayStart.addingTimeInterval(86_400),
            weekdaysOnly: true,
            calendar: calendar))
        let saturdayNoon = try #require(window.weeklyPacing(
            at: mondayStart.addingTimeInterval(5.5 * 86_400),
            weekdaysOnly: true,
            calendar: calendar))
        let sundayNoon = try #require(window.weeklyPacing(
            at: mondayStart.addingTimeInterval(6.5 * 86_400),
            weekdaysOnly: true,
            calendar: calendar))

        #expect(mondayNoon.weekdaysOnly)
        #expect(mondayNoon.segmentCount == 5)
        #expect(mondayNoon.currentSegment == 1)
        #expect(abs(mondayNoon.expectedUsedPercent - 10) < 0.001)
        #expect(tuesdayStart.currentSegment == 2)
        #expect(abs(tuesdayStart.expectedUsedPercent - 20) < 0.001)
        #expect(saturdayNoon.currentSegment == 5)
        #expect(abs(saturdayNoon.expectedUsedPercent - 100) < 0.001)
        #expect(sundayNoon.currentSegment == 5)
        #expect(abs(sundayNoon.expectedUsedPercent - 100) < 0.001)
    }

    @Test("rejects incomplete, expired, future, and internally inconsistent windows")
    func rejectsInvalidWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validReset = now.addingTimeInterval(4 * 86_400)

        #expect(QuotaWindowSnapshot(usedPercent: 10, windowMinutes: nil, resetsAt: validReset)
            .weeklyPacing(at: now, weekdaysOnly: false) == nil)
        #expect(QuotaWindowSnapshot(usedPercent: 10, windowMinutes: 0, resetsAt: validReset)
            .weeklyPacing(at: now, weekdaysOnly: false) == nil)
        #expect(QuotaWindowSnapshot(usedPercent: 10, windowMinutes: 10_080, resetsAt: nil)
            .weeklyPacing(at: now, weekdaysOnly: false) == nil)
        #expect(QuotaWindowSnapshot(
            usedPercent: 10,
            windowMinutes: 10_080,
            resetsAt: now.addingTimeInterval(-1))
            .weeklyPacing(at: now, weekdaysOnly: false) == nil)
        #expect(QuotaWindowSnapshot(
            usedPercent: 10,
            windowMinutes: 10_080,
            resetsAt: now.addingTimeInterval(8 * 86_400))
            .weeklyPacing(at: now, weekdaysOnly: false) == nil)
        #expect(QuotaWindowSnapshot(
            usedPercent: 10,
            windowMinutes: 10_080,
            resetsAt: now.addingTimeInterval(7 * 86_400))
            .weeklyPacing(at: now, weekdaysOnly: false) == nil)
        #expect(QuotaWindowSnapshot(
            usedPercent: .nan,
            windowMinutes: 10_080,
            resetsAt: validReset)
            .weeklyPacing(at: now, weekdaysOnly: false) == nil)
    }
}
