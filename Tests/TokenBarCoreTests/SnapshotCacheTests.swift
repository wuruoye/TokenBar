import Foundation
import Testing
@testable import TokenBarCore

@Suite("SnapshotCache")
struct SnapshotCacheTests {
    @Test("persists only redacted activity")
    func persistsRedactedActivity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBarTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("activity.json")
        let cache = SnapshotCache(fileURL: fileURL)
        let weeklySinceReset = ActivityRangeSummary(
            startedAtMs: 1_719_700_000_000,
            totals: ActivityTotals(
                tokens: .zero,
                costUsd: 1.25,
                requestCount: 4,
                sessionCount: 2))
        let rangeTotals = ActivityTotals(
            tokens: TokenBreakdown(input: 100, output: 20, cacheRead: 300, cacheWrite: 5, reasoning: 10),
            costUsd: 2.5,
            requestCount: 8,
            sessionCount: 3,
            averageGenerationTokensPerSecond: 25,
            timedGeneratedTokens: 30,
            totalModelDurationMs: 1_200,
            timedRequestCount: 2)
        let nestedRequest = RequestSummary(
            id: "child-request",
            sessionId: "session-1",
            physicalSessionId: "child-session",
            isSubagent: true,
            agent: "Faraday",
            model: "gpt-test",
            provider: "openai",
            startedAtMs: 1_720_000_000_100,
            endedAtMs: 1_720_000_000_900,
            durationMs: 800,
            modelDurationMs: 600,
            tokens: .zero,
            costUsd: 0.05,
            costSource: .estimated,
            promptPreview: "nested prompt secret",
            outputPreview: "nested output secret",
            sessionPath: "/Users/private/.codex/sessions/child-session.jsonl",
            serviceTier: .fast)
        let original = TestFixtures.activity(
            promptPreview: "prompt secret",
            outputPreview: "output secret",
            sessionPath: "/Users/private/.codex/sessions/private-session.jsonl",
            sessionTitle: "generated title secret",
            weeklySinceReset: weeklySinceReset,
            rangeTotals: rangeTotals,
            requestContributions: [nestedRequest])

        try await cache.saveActivity(original)
        let loaded = try await cache.loadActivity()
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

        #expect(loaded?.sessions.first?.requests.first?.promptPreview == nil)
        #expect(loaded?.sessions.first?.requests.first?.outputPreview == nil)
        #expect(loaded?.sessions.first?.requests.first?.sessionPath == nil)
        #expect(loaded?.sessions.first?.requests.first?.contributions?.first?.promptPreview == nil)
        #expect(loaded?.sessions.first?.requests.first?.contributions?.first?.outputPreview == nil)
        #expect(loaded?.sessions.first?.requests.first?.contributions?.first?.sessionPath == nil)
        #expect(loaded?.sessions.first?.requests.first?.contributions?.first?.physicalSessionId == "child-session")
        #expect(loaded?.sessions.first?.requests.first?.contributions?.first?.serviceTier == .fast)
        #expect(loaded?.sessions.first?.requests.first?.contributions?.first?.modelDurationMs == 600)
        #expect(loaded?.sessions.first?.title == nil)
        #expect(!raw.contains("prompt secret"))
        #expect(!raw.contains("output secret"))
        #expect(!raw.contains("private-session.jsonl"))
        #expect(!raw.contains("generated title secret"))
        #expect(!raw.contains("nested prompt secret"))
        #expect(!raw.contains("nested output secret"))
        #expect(!raw.contains("child-session.jsonl"))
        #expect(loaded?.today == original.today)
        #expect(loaded?.rangeTotals == rangeTotals)
        #expect(loaded?.weeklySinceReset == weeklySinceReset)
        #expect(permissions == 0o600)
    }

    @Test("round-trips daily timing summaries")
    func roundTripsDailyTimingSummaries() throws {
        let day = DailySummary(
            date: "2026-09-02",
            tokens: TokenBreakdown(
                input: 10,
                output: 120,
                cacheRead: 30,
                cacheWrite: 5,
                reasoning: 20),
            costUsd: 0.5,
            requestCount: 3,
            sessionCount: 2,
            timedGeneratedTokens: 100,
            totalModelDurationMs: 2_500,
            timedRequestCount: 2)

        let decoded = try JSONDecoder().decode(
            DailySummary.self,
            from: JSONEncoder().encode(day))

        #expect(decoded == day)
    }

    @Test("persists independent platform quota snapshots")
    func persistsQuotaSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBarQuotaTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("quotas.json")
        let cache = QuotaSnapshotCache(fileURL: fileURL)
        let codex = TestFixtures.quota(usedPercent: 20)
        let fixture = TestFixtures.quota(usedPercent: 35)
        let claude = QuotaSnapshot(
            session: fixture.session,
            weekly: fixture.weekly,
            resetCredits: fixture.resetCredits,
            updatedAt: fixture.updatedAt,
            origin: .claudeDesktop)

        try await cache.saveQuotas([.codex: codex, .claude: claude])
        let loaded = try await cache.loadQuotas()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

        #expect(loaded[.codex] == codex)
        #expect(loaded[.claude] == claude)
        #expect(loaded[.claude]?.origin == .claudeDesktop)
        #expect(permissions == 0o600)
    }
}
