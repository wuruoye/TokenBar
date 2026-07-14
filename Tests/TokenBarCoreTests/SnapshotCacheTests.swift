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
            tokens: .zero,
            costUsd: 0.05,
            costSource: .estimated,
            promptPreview: "nested prompt secret",
            outputPreview: "nested output secret",
            sessionPath: "/Users/private/.codex/sessions/child-session.jsonl")
        let original = TestFixtures.activity(
            promptPreview: "prompt secret",
            outputPreview: "output secret",
            sessionPath: "/Users/private/.codex/sessions/private-session.jsonl",
            sessionTitle: "generated title secret",
            weeklySinceReset: weeklySinceReset,
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
        #expect(loaded?.sessions.first?.title == nil)
        #expect(!raw.contains("prompt secret"))
        #expect(!raw.contains("output secret"))
        #expect(!raw.contains("private-session.jsonl"))
        #expect(!raw.contains("generated title secret"))
        #expect(!raw.contains("nested prompt secret"))
        #expect(!raw.contains("nested output secret"))
        #expect(!raw.contains("child-session.jsonl"))
        #expect(loaded?.today == original.today)
        #expect(loaded?.weeklySinceReset == weeklySinceReset)
        #expect(permissions == 0o600)
    }
}
