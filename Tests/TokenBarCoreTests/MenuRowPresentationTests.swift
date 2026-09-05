import Foundation
@testable import TokenBarCore
import Testing

struct MenuRowPresentationTests {
    @Test("Status bar token counts use whole compact units")
    func statusBarTokenCounts() {
        #expect(Int64(999).statusBarCompactCount == "999")
        #expect(Int64(1_499).statusBarCompactCount == "1K")
        #expect(Int64(358_900_000).statusBarCompactCount == "359M")
        #expect(Int64(1_250_000_000).statusBarCompactCount == "1B")
    }

    @Test("Session and request details show cache as a percentage")
    func tokenDetails() {
        let tokens = TokenBreakdown(
            input: 12_900,
            output: 4_200,
            cacheRead: 26_800,
            cacheWrite: 1_500,
            reasoning: 2_100)

        #expect(tokens.sessionMenuDetail == "47K · 65.0%")
        #expect(tokens.requestMenuDetail == "47K · 65.0%")
        #expect(tokens.cachePercentageText == "65.0%")
    }

    @Test("Cache percentage handles empty and fully cached input")
    func cachePercentageBoundaries() {
        #expect(TokenBreakdown.zero.cachePercentageText == "—")
        #expect(TokenBreakdown(
            input: 10,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            reasoning: 0).cachePercentageText == "0.0%")
        #expect(TokenBreakdown(
            input: 0,
            output: 0,
            cacheRead: 10,
            cacheWrite: 0,
            reasoning: 0).cachePercentageText == "100.0%")
    }

    @Test("Cache writes are presented as input without changing the total")
    func cacheWritesArePresentedAsInput() {
        let tokens = TokenBreakdown(
            input: 100,
            output: 20,
            cacheRead: 300,
            cacheWrite: 50,
            reasoning: 10)
        let costs = TokenCostBreakdown(
            input: 1,
            output: 2,
            cacheRead: 3,
            cacheWrite: 4,
            reasoning: 5)

        #expect(tokens.displayedInput == 150)
        #expect(tokens.displayedCache == 300)
        #expect(tokens.total == 480)
        #expect(costs.displayedInput == 5)
        #expect(costs.displayedCache == 3)
        #expect(costs.total == 15)
    }

    @Test("Subagent request title falls back to output")
    func subagentOutputFallback() {
        let request = self.makeRequest(
            isSubagent: true,
            agent: "researcher",
            prompt: nil,
            output: "  found\nthree files ")

        #expect(request.menuRowTitle == "↳ researcher · Output · found three files")
    }

    @Test("Request duration uses Tokscale compact units")
    func durationFormatting() {
        #expect(self.makeRequest(durationMs: nil).menuDurationText == "—")
        #expect(self.makeRequest(durationMs: 42_900).menuDurationText == "42s")
        #expect(self.makeRequest(durationMs: 60_000).menuDurationText == "1m0s")
        #expect(self.makeRequest(durationMs: 123_900).menuDurationText == "2m3s")
    }

    @Test("First-token time is compact and displayed beside TPS")
    func firstTokenFormatting() {
        #expect(self.makeRequest(timeToFirstTokenMs: nil).menuTTFTText == nil)
        #expect(self.makeRequest(timeToFirstTokenMs: 420).menuTTFTText == "420ms")
        #expect(self.makeRequest(timeToFirstTokenMs: 4_918).menuTTFTText == "4.9s")
        #expect(self.makeRequest(timeToFirstTokenMs: 14_358).menuTTFTText == "14.4s")
    }

    @Test("Average TPS is weighted by active model request duration")
    func averageTPS() {
        let fast = self.makeRequest(
            id: "fast",
            durationMs: 60_000,
            modelDurationMs: 1_000,
            timeToFirstTokenMs: 800,
            tokens: TokenBreakdown(
                input: 10_000,
                output: 80,
                cacheRead: 5_000,
                cacheWrite: 0,
                reasoning: 20))
        let slow = self.makeRequest(
            id: "slow",
            durationMs: 120_000,
            modelDurationMs: 3_000,
            timeToFirstTokenMs: 2_200,
            tokens: TokenBreakdown(
                input: 20_000,
                output: 120,
                cacheRead: 10_000,
                cacheWrite: 0,
                reasoning: 30))
        let missingDuration = self.makeRequest(
            id: "unknown",
            durationMs: 1_000,
            tokens: TokenBreakdown(
                input: 0,
                output: 10_000,
                cacheRead: 0,
                cacheWrite: 0,
                reasoning: 0))
        let turn = self.makeRequest(
            id: "turn",
            timeToFirstTokenMs: 800,
            contributions: [fast, slow, missingDuration])
        let session = SessionSummary(
            id: "session",
            workspaceLabel: "TokenBar",
            startedAtMs: fast.startedAtMs,
            endedAtMs: slow.endedAtMs,
            tokens: TokenBreakdown(
                input: 30_000,
                output: 200,
                cacheRead: 15_000,
                cacheWrite: 0,
                reasoning: 50),
            costUsd: 0,
            models: [fast.model],
            requests: [turn])
        let activity = ActivitySnapshot(
            schemaVersion: 3,
            generatedAtMs: slow.endedAtMs,
            timezone: "UTC",
            today: .zero,
            sessions: [session],
            days: [])
        let rangeTotals = ActivityTotals(
            tokens: session.tokens,
            costUsd: 0,
            requestCount: 2,
            sessionCount: 1,
            averageGenerationTokensPerSecond: 62.5,
            averageTimeToFirstTokenMs: 1_500,
            firstTokenSampleCount: 2)
        let day = DailySummary(
            date: "2026-08-17",
            tokens: session.tokens,
            costUsd: 0,
            requestCount: 2,
            sessionCount: 1,
            averageGenerationTokensPerSecond: 62.5,
            averageTimeToFirstTokenMs: 1_500,
            firstTokenSampleCount: 2)

        #expect(fast.averageGenerationTokensPerSecond == 100)
        #expect(turn.averageGenerationTokensPerSecond == 62.5)
        #expect(turn.menuAverageTPSText == "62.5 tok/s")
        #expect(turn.menuPerformanceText == "800ms · 62.5 tok/s")
        #expect(turn.menuDetail.hasSuffix("800ms · 62.5 tok/s"))
        #expect(session.averageGenerationTokensPerSecond == 62.5)
        #expect(session.averageTimeToFirstTokenMs == 800)
        #expect(session.menuPerformanceText == "800ms · 62.5 tok/s")
        #expect(activity.menuAverageTPSText == "62.5 tok/s")
        #expect(activity.menuAverageTTFTText == "800ms")
        #expect(rangeTotals.menuAverageTPSText == "62.5 tok/s")
        #expect(rangeTotals.menuPerformanceText == "1.5s · 62.5 tok/s")
        #expect(day.menuAverageTPSText == "62.5 tok/s")
        #expect(day.menuPerformanceText == "1.5s · 62.5 tok/s")
        #expect(missingDuration.averageGenerationTokensPerSecond == nil)
    }

    @Test("Turn keeps real main and subagent requests for nested menus")
    func turnContributions() {
        let main = self.makeRequest(id: "main", physicalSessionId: "root")
        let child = self.makeRequest(
            id: "child",
            physicalSessionId: "child",
            isSubagent: true,
            agent: "Faraday",
            prompt: nil,
            output: "Checked the parser")
        let turn = self.makeRequest(
            id: "turn",
            physicalSessionId: "root",
            contributions: [main, child])

        #expect(turn.physicalRequests.map(\.id) == ["main", "child"])
        #expect(main.agentRequestMenuTitle == "Main")
        #expect(child.agentRequestMenuTitle == "Faraday")
        #expect(turn.menuRowTitle == "Prompt")
    }

    @Test("Fast badges derive from physical requests for turns and sessions")
    func serviceTierBadges() {
        let fast = self.makeRequest(id: "fast", serviceTier: .fast)
        let unknown = self.makeRequest(id: "unknown")
        let standard = self.makeRequest(id: "standard", serviceTier: .standard)
        let fastTurn = self.makeRequest(
            id: "fast-turn",
            contributions: [fast, unknown])
        let mixedTurn = self.makeRequest(
            id: "mixed-turn",
            contributions: [fast, standard])
        let aggregateFallback = self.makeRequest(
            id: "aggregate-fallback",
            contributions: [unknown],
            serviceTier: .fast)
        let session = SessionSummary(
            id: "session",
            workspaceLabel: "TokenBar",
            startedAtMs: fast.startedAtMs,
            endedAtMs: standard.endedAtMs,
            tokens: .zero,
            costUsd: 0,
            models: [fast.model],
            requests: [fastTurn, mixedTurn])

        #expect(fast.menuServiceTier == .fast)
        #expect(fast.menuServiceTierBadge == "FAST")
        #expect(fastTurn.menuServiceTier == .fast)
        #expect(fastTurn.menuServiceTierBadge == "FAST")
        #expect(standard.menuServiceTierBadge == nil)
        #expect(unknown.menuServiceTier == .unknown)
        #expect(unknown.menuServiceTierBadge == nil)
        #expect(mixedTurn.menuServiceTier == .mixed)
        #expect(mixedTurn.menuServiceTierBadge == "MIXED")
        #expect(aggregateFallback.menuServiceTier == .fast)
        #expect(session.menuServiceTier == .mixed)
        #expect(session.menuServiceTierBadge == "MIXED")
    }

    @Test("Menu costs distinguish estimated, reported, tiny, and unknown values")
    func costFormatting() {
        let estimated = self.makeRequest(costUsd: 0.42, costSource: .estimated)
        #expect(estimated.menuCostText == "~$0.42")
        #expect(self.makeRequest(costUsd: 0.004, costSource: .providerReported).menuCostText == "<$0.01")
        #expect(self.makeRequest(costUsd: 1_240, costSource: .providerReported).menuCostText == "$1.2K")
        #expect(self.makeRequest(costUsd: 0, costSource: .unknown).menuCostText == nil)

        let session = SessionSummary(
            id: "session",
            workspaceLabel: "TokenBar",
            startedAtMs: estimated.startedAtMs,
            endedAtMs: estimated.endedAtMs,
            tokens: estimated.tokens,
            costUsd: estimated.costUsd,
            models: [estimated.model],
            requests: [estimated])
        #expect(session.menuCostText == "~$0.42")
    }

    private func makeRequest(
        id: String = "request",
        physicalSessionId: String = "physical",
        isSubagent: Bool = false,
        agent: String? = nil,
        durationMs: Int64? = nil,
        modelDurationMs: Int64? = nil,
        timeToFirstTokenMs: Int64? = nil,
        tokens: TokenBreakdown = .zero,
        costUsd: Double = 0,
        costSource: ActivityCostSource = .unknown,
        prompt: String? = "Prompt",
        output: String? = nil,
        contributions: [RequestSummary]? = nil,
        serviceTier: ActivityServiceTier? = nil) -> RequestSummary
    {
        RequestSummary(
            id: id,
            sessionId: "session",
            physicalSessionId: physicalSessionId,
            isSubagent: isSubagent,
            agent: agent,
            model: "fixture-model",
            provider: "fixture-provider",
            startedAtMs: 1_700_000_000_000,
            endedAtMs: 1_700_000_001_000,
            durationMs: durationMs,
            modelDurationMs: modelDurationMs,
            timeToFirstTokenMs: timeToFirstTokenMs,
            tokens: tokens,
            costUsd: costUsd,
            costSource: costSource,
            promptPreview: prompt,
            outputPreview: output,
            sessionPath: nil,
            contributions: contributions,
            serviceTier: serviceTier)
    }
}
