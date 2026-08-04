import Testing
@testable import TokenBarCore

@Suite("Platform activity")
struct PlatformActivityTests {
    @Test("dashboard exposes the three provider tabs and visibility filters")
    func platformTabs() {
        #expect(DashboardScope.allCases == [.codex, .claude, .grok])
        #expect(DashboardScope.visibleScopes(
            showsClaude: true,
            showsGrok: true) == [.codex, .claude, .grok])
        #expect(DashboardScope.visibleScopes(
            showsClaude: false,
            showsGrok: true) == [.codex, .grok])
        #expect(DashboardScope.visibleScopes(
            showsClaude: false,
            showsGrok: false) == [.codex])
        #expect(DashboardScope.codex.platform == .codex)
        #expect(DashboardScope.claude.platform == .claude)
        #expect(DashboardScope.grok.platform == .grok)
    }

    @Test("scopes totals, days, and colliding session ids by platform")
    func scopesSnapshot() {
        let codexTotals = ActivityTotals(
            tokens: TokenBreakdown(input: 100, output: 10, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            costUsd: 1,
            requestCount: 1,
            sessionCount: 1)
        let claudeTotals = ActivityTotals(
            tokens: TokenBreakdown(input: 200, output: 20, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            costUsd: 2,
            requestCount: 1,
            sessionCount: 1)
        let codexSession = self.session(platform: .codex, tokens: codexTotals.tokens)
        let claudeSession = self.session(platform: .claude, tokens: claudeTotals.tokens)
        let snapshot = ActivitySnapshot(
            schemaVersion: 4,
            generatedAtMs: 1,
            timezone: "UTC",
            today: ActivityTotals(
                tokens: TokenBreakdown(input: 300, output: 30, cacheRead: 0, cacheWrite: 0, reasoning: 0),
                costUsd: 3,
                requestCount: 2,
                sessionCount: 2),
            sessions: [codexSession, claudeSession],
            days: [],
            sources: [
                ActivitySourceSnapshot(
                    platform: .codex,
                    today: codexTotals,
                    weeklySinceReset: nil,
                    days: [self.day(tokens: codexTotals.tokens)],
                    rangeTotals: codexTotals),
                ActivitySourceSnapshot(
                    platform: .claude,
                    today: claudeTotals,
                    weeklySinceReset: nil,
                    days: [self.day(tokens: claudeTotals.tokens)],
                    rangeTotals: claudeTotals),
            ],
            rangeTotals: ActivityTotals(
                tokens: TokenBreakdown(input: 300, output: 30, cacheRead: 0, cacheWrite: 0, reasoning: 0),
                costUsd: 3,
                requestCount: 2,
                sessionCount: 2))

        let claude = snapshot.scoped(to: .claude)

        #expect(codexSession.id == claudeSession.id)
        #expect(codexSession.platformScopedID != claudeSession.platformScopedID)
        #expect(claude.today == claudeTotals)
        #expect(claude.rangeTotals == claudeTotals)
        #expect(claude.sessions.map(\.platformID) == [.claude])
        #expect(claude.days.first?.tokens.input == 200)
    }

    private func session(platform: TokenPlatform, tokens: TokenBreakdown) -> SessionSummary {
        SessionSummary(
            id: "shared-session",
            workspaceLabel: "workspace",
            startedAtMs: 1,
            endedAtMs: 2,
            tokens: tokens,
            costUsd: 0,
            models: [],
            requests: [],
            platform: platform)
    }

    private func day(tokens: TokenBreakdown) -> DailySummary {
        DailySummary(
            date: "2026-07-24",
            tokens: tokens,
            costUsd: 0,
            requestCount: 1,
            sessionCount: 1)
    }
}
