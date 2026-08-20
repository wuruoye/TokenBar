@testable import TokenBarCore
import Testing

struct TokscaleCopyLocatorTests {
    @Test("Session copy uses the agent-adapter provider and session keys")
    func sessionLocator() {
        let request = self.makeRequest()
        let session = SessionSummary(
            id: "root-session",
            workspaceLabel: "TokenBar",
            startedAtMs: request.startedAtMs,
            endedAtMs: request.endedAtMs,
            tokens: request.tokens,
            costUsd: request.costUsd,
            models: [request.model],
            requests: [request])

        #expect(session.tokscaleCopyText == "provider=codex session_id=root-session")
        #expect(!session.tokscaleCopyText.contains("\n"))
    }

    @Test("Request copy uses physical session and exact millisecond range")
    func requestLocator() {
        let request = self.makeRequest()

        #expect(
            request.tokscaleCopyText
                == "platform=codex session_id=child-session request_range=1779000000000..1779000003000")
        #expect(!request.tokscaleCopyText.contains("\n"))
    }

    @Test("Synced session copy includes server and restores the remote session ID")
    func syncedSessionLocator() {
        let request = self.makeRequest()
        let server = "11111111-1111-4111-8111-111111111111"
        let session = SessionSummary(
            id: "sync:\(server):root-session",
            workspaceLabel: "Windows Workstation",
            startedAtMs: request.startedAtMs,
            endedAtMs: request.endedAtMs,
            tokens: request.tokens,
            costUsd: request.costUsd,
            models: [request.model],
            requests: [request],
            title: "Remote session")

        #expect(session.synchronizedDeviceID == server)
        #expect(session.synchronizedOriginalSessionID == "root-session")
        #expect(
            session.tokscaleCopyText
                == "provider=codex server=\(server) session_id=root-session")
    }

    @Test("Claude session copy keeps the transcript UUID")
    func claudeSessionLocator() {
        let request = self.makeRequest()
        let sessionID = "2622858e-6ba4-4405-976d-d041e4e0c218"
        let session = SessionSummary(
            id: sessionID,
            workspaceLabel: "TokenBar",
            startedAtMs: request.startedAtMs,
            endedAtMs: request.endedAtMs,
            tokens: request.tokens,
            costUsd: request.costUsd,
            models: [request.model],
            requests: [request],
            platform: .claude)

        #expect(
            session.tokscaleCopyText
                == "provider=claude session_id=2622858e-6ba4-4405-976d-d041e4e0c218")
        #expect(!session.tokscaleCopyText.contains("host_session_id"))
    }

    @Test("Grok session copy uses the provider key")
    func grokSessionLocator() {
        let request = self.makeRequest()
        let session = SessionSummary(
            id: "grok-session",
            workspaceLabel: "TokenBar",
            startedAtMs: request.startedAtMs,
            endedAtMs: request.endedAtMs,
            tokens: request.tokens,
            costUsd: request.costUsd,
            models: [request.model],
            requests: [request],
            platform: .grok)

        #expect(session.tokscaleCopyText == "provider=grok session_id=grok-session")
    }

    @Test("Claude request copy keeps the Tokscale platform locator")
    func claudeLocator() {
        let codex = self.makeRequest()
        let request = RequestSummary(
            id: codex.id,
            sessionId: codex.sessionId,
            physicalSessionId: codex.physicalSessionId,
            isSubagent: codex.isSubagent,
            agent: codex.agent,
            model: "claude-sonnet-4-5",
            provider: "anthropic",
            startedAtMs: codex.startedAtMs,
            endedAtMs: codex.endedAtMs,
            durationMs: codex.durationMs,
            tokens: codex.tokens,
            costUsd: codex.costUsd,
            costSource: codex.costSource,
            promptPreview: codex.promptPreview,
            outputPreview: codex.outputPreview,
            sessionPath: codex.sessionPath,
            platform: .claude)

        #expect(
            request.tokscaleCopyText
                == "platform=claude session_id=child-session request_range=1779000000000..1779000003000")
    }

    private func makeRequest() -> RequestSummary {
        RequestSummary(
            id: "request",
            sessionId: "root-session",
            physicalSessionId: "child-session",
            isSubagent: true,
            agent: "reviewer",
            model: "fixture-model",
            provider: "openai",
            startedAtMs: 1_779_000_000_000,
            endedAtMs: 1_779_000_003_000,
            durationMs: 3_000,
            tokens: .zero,
            costUsd: 0,
            costSource: .unknown,
            promptPreview: "selected request",
            outputPreview: "ignored by Tokscale copy",
            sessionPath: nil)
    }
}
