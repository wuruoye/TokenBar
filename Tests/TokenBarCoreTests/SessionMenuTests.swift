import Testing
@testable import TokenBarCore

@Suite("Session menu")
struct SessionMenuTests {
    @Test("folded menu shows the ten most recent sessions")
    func foldedMenu() {
        let sessions = (0 ..< 12).reversed().map { index in
            Self.session(id: "session-\(index)", endedAtMs: Int64(index))
        }
        let projection = Self.snapshot(sessions: sessions).sessionMenu(limit: 10)

        #expect(projection.visibleSessions.map(\.id) == (2 ..< 12).reversed().map { "session-\($0)" })
        #expect(projection.remainingCount == 2)
    }

    @Test("expanded menu shows all sessions with stable ordering")
    func expandedMenu() {
        let sessions = [
            Self.session(id: "b", endedAtMs: 2),
            Self.session(id: "c", endedAtMs: 1),
            Self.session(id: "a", endedAtMs: 2),
        ]
        let projection = Self.snapshot(sessions: sessions).sessionMenu(limit: nil)

        #expect(projection.visibleSessions.map(\.id) == ["a", "b", "c"])
        #expect(projection.remainingCount == 0)
    }

    @Test("session title prefers Codex title, then root prompt, then workspace")
    func sessionTitle() {
        let session = Self.session(
            id: "session",
            endedAtMs: 3,
            workspaceLabel: "workspace",
            requests: [
                Self.request(id: "later", startedAtMs: 2, prompt: "later prompt", isSubagent: false),
                Self.request(id: "subagent", startedAtMs: 0, prompt: "subagent prompt", isSubagent: true),
                Self.request(id: "first", startedAtMs: 1, prompt: "  first\n prompt  ", isSubagent: false),
            ],
            title: "  generated\n title  ")

        #expect(session.menuTitle == "generated title")
        #expect(session.redactedForCache().menuTitle == "workspace")

        let promptFallback = Self.session(
            id: "fallback",
            endedAtMs: 3,
            workspaceLabel: "workspace",
            requests: [Self.request(id: "first", startedAtMs: 1, prompt: "first prompt", isSubagent: false)])
        #expect(promptFallback.menuTitle == "first prompt")
    }

    private static func snapshot(sessions: [SessionSummary]) -> ActivitySnapshot {
        ActivitySnapshot(
            schemaVersion: 2,
            generatedAtMs: 0,
            timezone: "UTC",
            today: .zero,
            sessions: sessions,
            days: [])
    }

    private static func session(
        id: String,
        endedAtMs: Int64,
        workspaceLabel: String? = nil,
        requests: [RequestSummary] = [],
        title: String? = nil) -> SessionSummary
    {
        SessionSummary(
            id: id,
            workspaceLabel: workspaceLabel,
            startedAtMs: 0,
            endedAtMs: endedAtMs,
            tokens: .zero,
            costUsd: 0,
            models: ["gpt-test"],
            requests: requests,
            title: title)
    }

    private static func request(
        id: String,
        startedAtMs: Int64,
        prompt: String?,
        isSubagent: Bool) -> RequestSummary
    {
        RequestSummary(
            id: id,
            sessionId: "session",
            physicalSessionId: "physical",
            isSubagent: isSubagent,
            agent: nil,
            model: "gpt-test",
            provider: "openai",
            startedAtMs: startedAtMs,
            endedAtMs: startedAtMs,
            durationMs: nil,
            tokens: .zero,
            costUsd: 0,
            costSource: .unknown,
            promptPreview: prompt,
            outputPreview: nil,
            sessionPath: nil)
    }
}
