import Foundation
@testable import TokenBarCore
import Testing

struct MenuRowPresentationTests {
    @Test("Session and request details keep only total tokens and Tokscale cache reuse")
    func tokenDetails() {
        let tokens = TokenBreakdown(
            input: 12_900,
            output: 4_200,
            cacheRead: 26_800,
            cacheWrite: 1_500,
            reasoning: 2_100)

        #expect(tokens.sessionMenuDetail == "47K total · Cache× 1.9x")
        #expect(tokens.requestMenuDetail == "47K total · Cache× 1.9x")
        #expect(tokens.cacheReuseText == "1.9x")
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
            tokens: .zero,
            costUsd: costUsd,
            costSource: costSource,
            promptPreview: prompt,
            outputPreview: output,
            sessionPath: nil,
            contributions: contributions,
            serviceTier: serviceTier)
    }
}
