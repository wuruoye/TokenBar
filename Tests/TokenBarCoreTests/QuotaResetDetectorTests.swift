import Foundation
@testable import TokenBarCore
import Testing

private actor ResetSequenceQuotaProvider: QuotaProviding {
    private var snapshots: [QuotaSnapshot]

    init(_ snapshots: [QuotaSnapshot]) {
        self.snapshots = snapshots
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        self.snapshots.removeFirst()
    }
}

@Suite("Quota reset detection")
struct QuotaResetDetectorTests {
    @Test("A transient zero is held until the reset boundary advances")
    func transientZero() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = observedAt.addingTimeInterval(3 * 86_400)
        var detector = QuotaResetDetector()

        #expect(detector.observe(
            self.snapshot(
                weeklyUsedPercent: 72,
                weeklyResetAt: resetAt,
                updatedAt: observedAt),
            for: .codex).isEmpty)
        #expect(detector.observe(
            self.snapshot(
                weeklyUsedPercent: 0,
                weeklyResetAt: resetAt,
                updatedAt: observedAt.addingTimeInterval(60)),
            for: .codex).isEmpty)

        let nextResetAt = resetAt.addingTimeInterval(7 * 86_400)
        let events = detector.observe(
            self.snapshot(
                weeklyUsedPercent: 0.4,
                weeklyResetAt: nextResetAt,
                updatedAt: observedAt.addingTimeInterval(120)),
            for: .codex)

        #expect(events == [
            QuotaResetEvent(
                platform: .codex,
                window: .weekly,
                detectedAt: observedAt.addingTimeInterval(120),
                previousResetAt: resetAt,
                resetAt: nextResetAt),
        ])
        #expect(detector.observe(
            self.snapshot(
                weeklyUsedPercent: 0.5,
                weeklyResetAt: nextResetAt,
                updatedAt: observedAt.addingTimeInterval(180)),
            for: .codex).isEmpty)
    }

    @Test("Boundary jitter and stale observations do not trigger a reset")
    func boundaryJitter() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = observedAt.addingTimeInterval(3 * 86_400)
        var detector = QuotaResetDetector()

        _ = detector.observe(
            self.snapshot(
                weeklyUsedPercent: 60,
                weeklyResetAt: resetAt,
                updatedAt: observedAt),
            for: .codex)
        #expect(detector.observe(
            self.snapshot(
                weeklyUsedPercent: 0,
                weeklyResetAt: resetAt.addingTimeInterval(119),
                updatedAt: observedAt.addingTimeInterval(60)),
            for: .codex).isEmpty)
        #expect(detector.observe(
            self.snapshot(
                weeklyUsedPercent: 0,
                weeklyResetAt: resetAt.addingTimeInterval(7 * 86_400),
                updatedAt: observedAt.addingTimeInterval(-60)),
            for: .codex).isEmpty)
    }

    @Test("Dashboard model publishes the confirmed reset once")
    @MainActor
    func modelPublishesReset() async {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = observedAt.addingTimeInterval(3 * 86_400)
        let nextResetAt = resetAt.addingTimeInterval(7 * 86_400)
        let provider = ResetSequenceQuotaProvider([
            self.snapshot(
                weeklyUsedPercent: 80,
                weeklyResetAt: resetAt,
                updatedAt: observedAt),
            self.snapshot(
                weeklyUsedPercent: 0,
                weeklyResetAt: resetAt,
                updatedAt: observedAt.addingTimeInterval(60)),
            self.snapshot(
                weeklyUsedPercent: 0,
                weeklyResetAt: nextResetAt,
                updatedAt: observedAt.addingTimeInterval(120)),
        ])
        let model = DashboardModel(
            quotaService: provider,
            cache: nil)
        var events: [QuotaResetEvent] = []
        model.quotaResetHandler = { events.append($0) }

        await model.refreshQuota()
        await model.refreshQuota()
        await model.refreshQuota()

        #expect(events.count == 1)
        #expect(events.first?.window == .weekly)
        #expect(events.first?.resetAt == nextResetAt)
    }

    private func snapshot(
        weeklyUsedPercent: Double,
        weeklyResetAt: Date?,
        updatedAt: Date) -> QuotaSnapshot
    {
        QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: weeklyUsedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyResetAt),
            resetCredits: nil,
            updatedAt: updatedAt)
    }
}
