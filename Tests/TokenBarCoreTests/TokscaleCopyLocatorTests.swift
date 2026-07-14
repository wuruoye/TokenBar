@testable import TokenBarCore
import Testing

struct TokscaleCopyLocatorTests {
    @Test("Session copy matches Tokscale locator exactly")
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

        #expect(session.tokscaleCopyText == "platform=codex session_id=root-session")
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
