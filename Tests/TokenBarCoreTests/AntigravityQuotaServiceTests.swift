import Foundation
import Testing
@testable import TokenBarCore

private actor RequestRecorder {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}

@Suite("AntigravityQuotaService")
struct AntigravityQuotaServiceTests {
    @Test("reports the pool that runs out first with both of its windows")
    func reportsTheMostConstrainedPool() async throws {
        let recorder = RequestRecorder()
        let service = AntigravityQuotaService(
            loadMainLog: { Self.mainLog },
            loadServerLog: { Self.serverLog },
            send: { request in
                await recorder.record(request)
                return (Self.quotaResponse, Self.okResponse)
            },
            now: { Date(timeIntervalSince1970: 1_788_400_000) })

        let snapshot = try await service.fetchQuota()

        // The Gemini pool is the constrained one; the untouched pool must not
        // supply either row.
        #expect(abs((snapshot.weekly?.usedPercent ?? 0) - 20) < 1e-9)
        #expect(snapshot.weekly?.resetsAt == Self.date("2026-09-04T17:19:34Z"))
        #expect(abs((snapshot.session?.usedPercent ?? 0) - 40) < 1e-9)
        #expect(snapshot.session?.resetsAt == Self.date("2026-09-03T07:45:53Z"))
        #expect(snapshot.session?.windowMinutes == 300)
        #expect(snapshot.weekly?.windowMinutes == 10_080)

        // Discovery must use the newest launch recorded in the logs.
        let request = await recorder.request
        #expect(request?.url?.absoluteString == "http://127.0.0.1:58600"
            + "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
        #expect(
            request?.value(forHTTPHeaderField: "x-codeium-csrf-token")
                == "d3116cba-e1ce-40e8-a900-9a77ac7881eb")
    }

    @Test("reports the server as unavailable when the logs have no live endpoint")
    func requiresAPortAndToken() async {
        let service = AntigravityQuotaService(
            loadMainLog: { Data("nothing useful here\n".utf8) },
            loadServerLog: { Self.serverLog },
            send: { _ in Issue.record("no request expected"); return (Data(), Self.okResponse) })

        await #expect(throws: AntigravityQuotaServiceError.self) {
            _ = try await service.fetchQuota()
        }
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static let okResponse = HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:58600")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil)!

    private static let mainLog = Data("""
    [info] Spawning: /Applications/Antigravity.app/... --csrf_token 33847645-177b-477d-b163-67c558055e2c --app_data_dir antigravity
    [info] Spawning: /Applications/Antigravity.app/... --csrf_token d3116cba-e1ce-40e8-a900-9a77ac7881eb --app_data_dir antigravity

    """.utf8)

    private static let serverLog = Data("""
    I0903 server.go:593] Language server listening on random port at 58599 for HTTPS (gRPC)
    I0903 server.go:593] Language server listening on random port at 58600 for HTTP (gRPC)

    """.utf8)

    private static let quotaResponse = Data("""
    {"response":{"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.8,
         "resetTime":"2026-09-04T17:19:34Z"},
        {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.6,
         "resetTime":"2026-09-03T07:45:53Z"}]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1,
         "resetTime":"2026-09-10T04:35:02Z"},
        {"bucketId":"3p-5h","window":"5h","remainingFraction":1,
         "resetTime":"2026-09-03T09:35:02Z"}]}]}}
    """.utf8)
}
