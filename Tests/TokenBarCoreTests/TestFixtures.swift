import Foundation
@testable import TokenBarCore

enum TestFixtures {
    static func quota(usedPercent: Double) -> QuotaSnapshot {
        QuotaSnapshot(
            session: QuotaWindowSnapshot(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
            weekly: QuotaWindowSnapshot(
                usedPercent: usedPercent / 2,
                windowMinutes: 10080,
                resetsAt: Date(timeIntervalSince1970: 1_800_100_000)),
            resetCredits: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func activity(
        generatedAtMs: Int64 = 1_720_000_000_000,
        promptPreview: String? = nil,
        outputPreview: String? = nil,
        sessionPath: String? = nil,
        sessionTitle: String? = nil,
        weeklySinceReset: ActivityRangeSummary? = nil,
        requestContributions: [RequestSummary]? = nil) -> ActivitySnapshot
    {
        let tokens = TokenBreakdown(input: 10, output: 5, cacheRead: 3, cacheWrite: 2, reasoning: 1)
        let tokenCosts = TokenCostBreakdown(
            input: 0.05,
            output: 0.10,
            cacheRead: 0.03,
            cacheWrite: 0.02,
            reasoning: 0.05)
        let request = RequestSummary(
            id: "request-1",
            sessionId: "session-1",
            physicalSessionId: "physical-1",
            isSubagent: false,
            agent: "codex",
            model: "gpt-test",
            provider: "openai",
            startedAtMs: generatedAtMs,
            endedAtMs: generatedAtMs + 1000,
            durationMs: 1000,
            tokens: tokens,
            costUsd: 0.25,
            costSource: .estimated,
            promptPreview: promptPreview,
            outputPreview: outputPreview,
            sessionPath: sessionPath,
            contributions: requestContributions)
        let session = SessionSummary(
            id: "session-1",
            workspaceLabel: "workspace",
            startedAtMs: generatedAtMs,
            endedAtMs: generatedAtMs + 1000,
            tokens: tokens,
            costUsd: 0.25,
            models: ["gpt-test"],
            requests: [request],
            title: sessionTitle)
        return ActivitySnapshot(
            schemaVersion: 3,
            generatedAtMs: generatedAtMs,
            timezone: "UTC",
            today: ActivityTotals(
                tokens: tokens,
                costUsd: 0.25,
                requestCount: 1,
                sessionCount: 1,
                tokenCosts: tokenCosts),
            sessions: [session],
            days: [DailySummary(
                date: "2024-07-03",
                tokens: tokens,
                costUsd: 0.25,
                requestCount: 1,
                sessionCount: 1)],
            weeklySinceReset: weeklySinceReset)
    }
}
