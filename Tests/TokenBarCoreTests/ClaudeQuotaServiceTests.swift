import Foundation
import Testing
@testable import TokenBarCore

private enum ClaudeQuotaFixtureError: Error {
    case wrongToken
}

@Suite("ClaudeQuotaService")
struct ClaudeQuotaServiceTests {
    @Test("derives Claude Code's config-specific Keychain service before the legacy fallback")
    func derivesCredentialServices() {
        #expect(ClaudeQuotaService.keychainCredentialServices(
            configDirectoryPath: "/Users/sigma/.claude") == [
                "Claude Code-credentials-df599960",
                "Claude Code-credentials",
            ])
    }

    @Test("decodes independent five-hour and weekly quota windows")
    func decodesUsageWindows() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = Data(
            """
            {
              "five_hour": {
                "utilization": 37.5,
                "resets_at": "2027-01-15T10:30:00.000Z"
              },
              "seven_day": {
                "utilization": 110,
                "resets_at": "2027-01-20T08:00:00Z"
              },
              "seven_day_opus": null
            }
            """.utf8)
        let service = ClaudeQuotaService(
            loadAccessToken: { "claude-oauth-token" },
            fetchUsage: { token in
                guard token == "claude-oauth-token" else {
                    throw ClaudeQuotaFixtureError.wrongToken
                }
                return response
            },
            now: { now })

        let quota = try await service.fetchQuota()

        #expect(service.platform == .claude)
        #expect(quota.session?.usedPercent == 37.5)
        #expect(quota.session?.windowMinutes == 300)
        #expect(quota.weekly?.usedPercent == 100)
        #expect(quota.weekly?.windowMinutes == 10_080)
        #expect(quota.weekly?.resetsAt == ISO8601DateFormatter().date(from: "2027-01-20T08:00:00Z"))
        #expect(quota.resetCredits == nil)
        #expect(quota.updatedAt == now)
        #expect(quota.origin == .liveProvider)
    }

    @Test("rejects a response without supported quota windows")
    func rejectsMissingWindows() async {
        let service = ClaudeQuotaService(
            loadAccessToken: { "token" },
            fetchUsage: { _ in Data(#"{"seven_day_opus":{"utilization":20}}"#.utf8) })

        await #expect(throws: ClaudeQuotaServiceError.self) {
            _ = try await service.fetchQuota()
        }
    }

    @Test("falls back to a fresh Claude Desktop sample when credentials are unavailable")
    func fallsBackToDesktopUsageWithoutCredentials() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let service = ClaudeQuotaService(
            loadAccessToken: { throw ClaudeQuotaServiceError.credentialsUnavailable },
            fetchUsage: { _ in throw ClaudeQuotaFixtureError.wrongToken },
            loadCachedDesktopUsage: { sampledAt in
                guard sampledAt == now else { return nil }
                return Data(
                    """
                    {
                      "_cached_at_ms": 1800000000123,
                      "five_hour": {"utilization": 39},
                      "seven_day": {"utilization": 4}
                    }
                    """.utf8)
            },
            now: { now })

        let quota = try await service.fetchQuota()

        #expect(quota.session?.usedPercent == 39)
        #expect(quota.weekly?.usedPercent == 4)
        #expect(quota.session?.resetsAt == nil)
        #expect(quota.weekly?.resetsAt == nil)
        #expect(quota.updatedAt == Date(timeIntervalSince1970: 1_800_000_000.123))
        #expect(quota.origin == .claudeDesktop)
    }
}
