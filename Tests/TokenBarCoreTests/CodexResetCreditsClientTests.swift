import Foundation
import Testing
@testable import TokenBarCore

private actor RecordingHTTPTransport: TokenBarHTTPTransport {
    private let result: Result<TokenBarHTTPResponse, any Error & Sendable>
    private(set) var requests: [URLRequest] = []

    init(result: Result<TokenBarHTTPResponse, any Error & Sendable>) {
        self.result = result
    }

    func response(for request: URLRequest) async throws -> TokenBarHTTPResponse {
        self.requests.append(request)
        return try self.result.get()
    }
}

@Suite("Codex reset credits client")
struct CodexResetCreditsClientTests {
    @Test("reads auth without mutation and filters the effective credit inventory")
    func fetchesAvailableInventory() async throws {
        let home = try Self.makeCodexHome(lastRefresh: "2026-07-14T00:00:00Z")
        defer { try? FileManager.default.removeItem(at: home) }
        let response = TokenBarHTTPResponse(
            data: Data(
                """
                {
                  "available_count": 4,
                  "credits": [
                    {"status":"available","expires_at":"2026-07-16T00:00:00Z"},
                    {"status":"available","expires_at":"2026-07-18T00:00:00.000Z"},
                    {"status":"available","expires_at":null},
                    {"status":"available","expires_at":"2026-07-14T00:00:00Z"},
                    {"status":"redeemed","expires_at":"2026-07-17T00:00:00Z"}
                  ]
                }
                """.utf8),
            statusCode: 200)
        let transport = RecordingHTTPTransport(result: .success(response))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T00:00:00Z"))
        let client = CodexResetCreditsClient(
            environment: ["CODEX_HOME": home.path],
            transport: transport,
            now: { now })

        let snapshot = try #require(try await client.fetch())

        #expect(snapshot.availableCount == 3)
        #expect(snapshot.nextExpiresAt == ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z"))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-test")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-test")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "TokenBar")
    }

    @Test("stale credentials hide reset credits without making a request")
    func staleCredentialsAreSkipped() async throws {
        let home = try Self.makeCodexHome(lastRefresh: "2026-07-01T00:00:00Z")
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = RecordingHTTPTransport(result: .success(TokenBarHTTPResponse(data: Data(), statusCode: 200)))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T00:00:00Z"))
        let client = CodexResetCreditsClient(
            environment: ["CODEX_HOME": home.path],
            transport: transport,
            now: { now })

        let snapshot = try await client.fetch()

        #expect(snapshot == nil)
        #expect(await transport.requests.isEmpty)
    }

    @Test("auth decoder accepts camel-case token keys")
    func authDecoderAcceptsCamelCase() throws {
        let data = Data(
            """
            {
              "tokens": {
                "accessToken": "access",
                "refreshToken": "refresh",
                "accountId": "account"
              },
              "last_refresh": "2026-07-14T12:00:00.123Z"
            }
            """.utf8)

        let credentials = try CodexAuthStore.parse(data: data)

        #expect(credentials.accessToken == "access")
        #expect(credentials.accountID == "account")
        #expect(credentials.lastRefresh != nil)
    }

    @Test("custom HTTPS base URL is honored while insecure configuration falls back")
    func resolvesSafeBaseURL() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")

        try Data("chatgpt_base_url = 'https://example.com/custom/'\n".utf8).write(to: config)
        #expect(CodexResetCreditsClient.resetCreditsURL(environment: ["CODEX_HOME": home.path]).absoluteString
            == "https://example.com/custom/wham/rate-limit-reset-credits")

        try Data("chatgpt_base_url = 'http://example.com/'\n".utf8).write(to: config)
        #expect(CodexResetCreditsClient.resetCreditsURL(environment: ["CODEX_HOME": home.path]).absoluteString
            == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
    }

    @Test("bearer-token redirects are restricted to the same HTTPS origin")
    func redirectPolicy() {
        let original = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

        #expect(SameOriginRedirectDelegate.allowsRedirect(
            from: original,
            to: URL(string: "https://chatgpt.com:443/backend-api/login")!))
        #expect(!SameOriginRedirectDelegate.allowsRedirect(
            from: original,
            to: URL(string: "https://example.com/backend-api/login")!))
        #expect(!SameOriginRedirectDelegate.allowsRedirect(
            from: original,
            to: URL(string: "http://chatgpt.com/backend-api/login")!))
        #expect(!SameOriginRedirectDelegate.allowsRedirect(
            from: original,
            to: URL(string: "https://chatgpt.com:444/backend-api/login")!))
    }

    private static func makeCodexHome(lastRefresh: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = Data(
            """
            {
              "tokens": {
                "access_token": "access-test",
                "refresh_token": "refresh-test",
                "account_id": "account-test"
              },
              "last_refresh": "\(lastRefresh)"
            }
            """.utf8)
        try auth.write(to: home.appendingPathComponent("auth.json"))
        return home
    }
}
