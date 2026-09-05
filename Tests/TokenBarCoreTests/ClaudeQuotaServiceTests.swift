import Foundation
import Testing
@testable import TokenBarCore

@Suite("ClaudeQuotaService")
struct ClaudeQuotaServiceTests {
    @Test("decodes independent five-hour and weekly statusline windows")
    func decodesStatusLineWindows() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = ClaudeQuotaService(
            loadCachedStatusLineUsage: { _ in
                Data(
                    """
                    {
                      "_cached_at_ms": 1800000000000,
                      "five_hour": {
                        "utilization": 37.5,
                        "resets_at": "2027-01-15T10:30:00.000Z"
                      },
                      "seven_day": {
                        "utilization": 110,
                        "resets_at": "2027-01-20T08:00:00Z"
                      }
                    }
                    """.utf8)
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

    @Test("reports unavailable when local sources have no supported quota windows")
    func rejectsMissingLocalWindows() async {
        let service = ClaudeQuotaService(
            loadCachedStatusLineUsage: { _ in
                Data(#"{"seven_day_opus":{"utilization":20}}"#.utf8)
            })

        await #expect(throws: ClaudeQuotaServiceError.localUsageUnavailable) {
            _ = try await service.fetchQuota()
        }
    }

    @Test("uses a fresh Claude Desktop sample")
    func usesDesktopUsage() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let service = ClaudeQuotaService(
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

    @Test("adds statusline reset times to a fresher Claude Desktop sample")
    func mergesStatusLineResetsIntoDesktopUsage() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let service = ClaudeQuotaService(
            loadCachedDesktopUsage: { _ in
                Data(
                    """
                    {
                      "_cached_at_ms": 1800000000123,
                      "five_hour": {"utilization": 39},
                      "seven_day": {"utilization": 4}
                    }
                    """.utf8)
            },
            loadCachedStatusLineUsage: { _ in
                Data(
                    """
                    {
                      "_cached_at_ms": 1799900000000,
                      "five_hour": {
                        "utilization": 80,
                        "resets_at": "2027-01-15T10:00:00Z"
                      },
                      "seven_day": {
                        "utilization": 70,
                        "resets_at": "2027-01-21T03:20:00Z"
                      }
                    }
                    """.utf8)
            },
            now: { now })

        let quota = try await service.fetchQuota()

        #expect(quota.session?.usedPercent == 39)
        #expect(quota.weekly?.usedPercent == 4)
        #expect(quota.session?.resetsAt == ISO8601DateFormatter().date(
            from: "2027-01-15T10:00:00Z"))
        #expect(quota.weekly?.resetsAt == ISO8601DateFormatter().date(
            from: "2027-01-21T03:20:00Z"))
        #expect(quota.updatedAt == Date(timeIntervalSince1970: 1_800_000_000.123))
        #expect(quota.origin == .claudeDesktop)
    }

    @Test("uses a fresh statusline snapshot when Claude Desktop has no sample")
    func fallsBackToFreshStatusLineUsage() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let service = ClaudeQuotaService(
            loadCachedStatusLineUsage: { _ in
                Data(
                    """
                    {
                      "_cached_at_ms": 1800000050000,
                      "seven_day": {
                        "utilization": 21,
                        "resets_at": "2027-01-21T03:20:00Z"
                      }
                    }
                    """.utf8)
            },
            now: { now })

        let quota = try await service.fetchQuota()

        #expect(quota.session == nil)
        #expect(quota.weekly?.usedPercent == 21)
        #expect(quota.weekly?.resetsAt == ISO8601DateFormatter().date(
            from: "2027-01-21T03:20:00Z"))
        #expect(quota.updatedAt == Date(timeIntervalSince1970: 1_800_000_050))
        #expect(quota.origin == .liveProvider)
    }

    @Test("does not surface stale statusline percentages without a current local sample")
    func rejectsStaleStatusLineUsageAlone() async {
        let service = ClaudeQuotaService(
            loadCachedStatusLineUsage: { _ in
                Data(
                    """
                    {
                      "_cached_at_ms": 1799900000000,
                      "seven_day": {
                        "utilization": 21,
                        "resets_at": "2027-01-21T03:20:00Z"
                      }
                    }
                    """.utf8)
            },
            now: { Date(timeIntervalSince1970: 1_800_000_100) })

        await #expect(throws: ClaudeQuotaServiceError.localUsageUnavailable) {
            _ = try await service.fetchQuota()
        }
    }
}
