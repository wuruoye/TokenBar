import Foundation
import Testing
@testable import TokenBarCore

@Suite("Weekly quota daily usage")
struct WeeklyQuotaUsageTests {
    private let windowStart: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 17))!
    }()

    @Test("records observed increases against statistics dates")
    func recordsDailyIncreases() throws {
        let first = self.snapshot(usedPercent: 20, offset: 86_400 + 3_600)
        let second = self.snapshot(usedPercent: 23.5, offset: 86_400 + 7_200)
        let third = self.snapshot(usedPercent: 31, offset: 2 * 86_400 + 3_600)

        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
            .recording(second)
            .recording(third)
        let firstDay = try #require(history.usage(
            on: "2026-08-18",
            statisticsTimeZone: .utc))
        let secondDay = try #require(history.usage(
            on: "2026-08-19",
            statisticsTimeZone: .utc))

        #expect(firstDay.usedPercentagePoints == 3.5)
        #expect(firstDay.isPartial)
        #expect(secondDay.usedPercentagePoints == 7.5)
        #expect(!secondDay.isPartial)
    }

    @Test("regroups timestamped increments for another timezone")
    func regroupsForTimezone() throws {
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: self.snapshot(
            usedPercent: 20,
            offset: 10 * 3_600)))
            .recording(self.snapshot(usedPercent: 25, offset: 23.5 * 3_600))
            .recording(self.snapshot(usedPercent: 30, offset: 24.5 * 3_600))
        let plusTwo = try #require(TimeZone(secondsFromGMT: 2 * 3_600))

        #expect(history.usage(on: "2026-08-17", timeZone: .gmt)?.usedPercentagePoints == 5)
        #expect(history.usage(on: "2026-08-18", timeZone: .gmt)?.usedPercentagePoints == 5)
        #expect(history.usage(on: "2026-08-18", timeZone: plusTwo)?.usedPercentagePoints == 10)
    }

    @Test("does not double count quota corrections")
    func ignoresCorrectionsBelowHighWaterMark() throws {
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: self.snapshot(
            usedPercent: 40,
            offset: 86_400)))
            .recording(self.snapshot(usedPercent: 38, offset: 86_500))
            .recording(self.snapshot(usedPercent: 41, offset: 86_600))

        #expect(history.usage(
            at: self.windowStart.addingTimeInterval(86_600),
            statisticsTimeZone: .utc)?.usedPercentagePoints == 1)
        #expect(history.highWaterUsedPercent == 41)
    }

    @Test("ignores duplicate and older samples")
    func ignoresStaleSamples() throws {
        let first = self.snapshot(usedPercent: 15, offset: 1_000)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
            .recording(self.snapshot(usedPercent: 30, offset: 1_000))
            .recording(self.snapshot(usedPercent: 30, offset: 900))

        #expect(history.highWaterUsedPercent == 15)
        #expect(history.increments.isEmpty)
    }

    @Test("keeps previous dates when the weekly window changes")
    func keepsPreviousCycles() throws {
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: self.snapshot(
            usedPercent: 20,
            offset: 5 * 86_400)))
            .recording(self.snapshot(usedPercent: 25, offset: 5 * 86_400 + 300))
        let nextWindowStart = self.windowStart.addingTimeInterval(7 * 86_400)
        let next = self.snapshot(
            usedPercent: 4,
            offset: 600,
            windowStart: nextWindowStart)

        let reset = history.recording(next)

        #expect(reset.currentWindowStart == nextWindowStart)
        #expect(reset.usage(
            on: "2026-08-22",
            statisticsTimeZone: .utc)?.usedPercentagePoints == 5)
        #expect(reset.usage(
            on: "2026-08-24",
            statisticsTimeZone: .utc)?.usedPercentagePoints == 0)
        #expect(reset.usage(
            on: "2026-08-24",
            statisticsTimeZone: .utc)?.isPartial == true)
    }

    @Test("requires a current weekly window")
    func requiresWeeklyWindow() {
        let snapshot = QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: 20,
                windowMinutes: 10_080,
                resetsAt: nil),
            resetCredits: nil,
            updatedAt: self.windowStart)

        #expect(WeeklyQuotaUsageHistory.starting(with: snapshot) == nil)
    }

    private func snapshot(
        usedPercent: Double,
        offset: TimeInterval,
        windowStart: Date? = nil) -> QuotaSnapshot
    {
        let windowStart = windowStart ?? self.windowStart
        return QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: usedPercent,
                windowMinutes: 10_080,
                resetsAt: windowStart.addingTimeInterval(7 * 86_400)),
            resetCredits: nil,
            updatedAt: windowStart.addingTimeInterval(offset))
    }
}
