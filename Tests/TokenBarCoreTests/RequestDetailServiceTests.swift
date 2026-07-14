import Foundation
import Testing
@testable import TokenBarCore

private struct RequestDetailHelperInvocation: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
}

private actor RequestDetailHelperRecorder {
    private var invocations: [RequestDetailHelperInvocation] = []

    func record(_ invocation: RequestDetailHelperInvocation) {
        self.invocations.append(invocation)
    }

    func snapshot() -> [RequestDetailHelperInvocation] {
        self.invocations
    }
}

private struct RecordingRequestDetailHelperRunner: ActivityHelperRunning {
    let output: Data
    let recorder: RequestDetailHelperRecorder

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval) async throws -> Data
    {
        await self.recorder.record(RequestDetailHelperInvocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            timeout: timeout))
        return self.output
    }
}

@Suite("CodexRequestDetailService")
struct RequestDetailServiceTests {
    @Test("passes the request range to the helper and decodes its JSON")
    func passesArgumentsAndDecodesJSON() async throws {
        let helperURL = URL(fileURLWithPath: "/fixture/tokenbar-helper")
        let sessionPath = "/tmp/codex-session.jsonl"
        let environment = ["TOKENBAR_TEST": "request-detail"]
        let recorder = RequestDetailHelperRecorder()
        let runner = RecordingRequestDetailHelperRunner(
            output: Data(
                #"{"prompt":"full prompt\nsecond line","output":"full output"}"#.utf8),
            recorder: recorder)
        let service = CodexRequestDetailService(
            environment: environment,
            timeout: 7,
            resolveHelper: { helperURL },
            runner: runner)
        let request = try #require(
            TestFixtures.activity(sessionPath: sessionPath).sessions.first?.requests.first)

        let detail = try await service.fetchDetail(for: request)

        #expect(detail == RequestDetail(prompt: "full prompt\nsecond line", output: "full output"))
        let invocation = try #require(await recorder.snapshot().first)
        #expect(invocation.executableURL == helperURL)
        #expect(invocation.arguments == [
            "request-detail",
            "--session-path", sessionPath,
            "--start-ms", String(request.startedAtMs),
            "--end-ms", String(request.endedAtMs),
        ])
        #expect(invocation.environment == environment)
        #expect(invocation.timeout == 7)
    }

    @Test("rejects a missing session path without starting the helper")
    func rejectsMissingSessionPathWithoutRunningHelper() async {
        let recorder = RequestDetailHelperRecorder()
        let service = CodexRequestDetailService(
            resolveHelper: { URL(fileURLWithPath: "/fixture/tokenbar-helper") },
            runner: RecordingRequestDetailHelperRunner(
                output: Data(#"{"prompt":null,"output":null}"#.utf8),
                recorder: recorder))
        let request = try? #require(TestFixtures.activity().sessions.first?.requests.first)

        guard let request else {
            Issue.record("Missing request fixture")
            return
        }
        do {
            _ = try await service.fetchDetail(for: request)
            Issue.record("Expected a missing-session-path error")
        } catch RequestDetailServiceError.missingSessionPath {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await recorder.snapshot().isEmpty)
    }

    @Test("rejects empty helper output")
    func rejectsEmptyOutput() async throws {
        let recorder = RequestDetailHelperRecorder()
        let service = CodexRequestDetailService(
            resolveHelper: { URL(fileURLWithPath: "/fixture/tokenbar-helper") },
            runner: RecordingRequestDetailHelperRunner(output: Data(), recorder: recorder))
        let request = try #require(
            TestFixtures.activity(sessionPath: "/tmp/codex-session.jsonl").sessions.first?.requests.first)

        do {
            _ = try await service.fetchDetail(for: request)
            Issue.record("Expected an empty-output error")
        } catch RequestDetailServiceError.emptyOutput {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await recorder.snapshot().count == 1)
    }

    @Test("rejects malformed helper JSON")
    func rejectsMalformedJSON() async throws {
        let recorder = RequestDetailHelperRecorder()
        let service = CodexRequestDetailService(
            resolveHelper: { URL(fileURLWithPath: "/fixture/tokenbar-helper") },
            runner: RecordingRequestDetailHelperRunner(
                output: Data("not-json".utf8),
                recorder: recorder))
        let request = try #require(
            TestFixtures.activity(sessionPath: "/tmp/codex-session.jsonl").sessions.first?.requests.first)

        do {
            _ = try await service.fetchDetail(for: request)
            Issue.record("Expected an invalid-output error")
        } catch RequestDetailServiceError.invalidOutput {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await recorder.snapshot().count == 1)
    }
}
