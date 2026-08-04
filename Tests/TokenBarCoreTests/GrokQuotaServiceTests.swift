import Foundation
import Testing
@testable import TokenBarCore

@Suite("GrokQuotaService")
struct GrokQuotaServiceTests {
    @Test("decodes the latest official Grok billing snapshot")
    func decodesLatestSnapshot() async throws {
        let log = Data(
            """
            {"ts":"2027-01-01T00:00:00.000Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":12,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2027-01-01T00:00:00Z","end":"2027-01-08T00:00:00Z"}}}}
            {"ts":"2027-01-02T03:04:05.123Z","msg":"unrelated"}
            {"ts":"2027-01-03T06:07:08.456Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":42.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2027-01-02T00:00:00Z","end":"2027-01-09T00:00:00Z"}}}}
            """.utf8)
        let service = GrokQuotaService(loadLog: { log })

        let quota = try await service.fetchQuota()

        #expect(service.platform == .grok)
        #expect(quota.session == nil)
        #expect(quota.weekly?.usedPercent == 42.5)
        #expect(quota.weekly?.windowMinutes == 10_080)
        #expect(quota.weekly?.resetsAt == ISO8601DateFormatter().date(from: "2027-01-09T00:00:00Z"))
        #expect(quota.updatedAt == self.date("2027-01-03T06:07:08.456Z"))
    }

    @Test("supports the legacy included-credit fields")
    func decodesLegacySnapshot() async throws {
        let log = Data(
            """
            {"ts":"2027-01-01T00:00:00Z","msg":"billing: fetched credits config","ctx":{"config":{"monthlyLimit":{"val":2000},"used":{"val":500},"billingPeriodEnd":"2027-02-01T00:00:00Z"}}}
            """.utf8)
        let service = GrokQuotaService(loadLog: { log })

        let quota = try await service.fetchQuota()

        #expect(quota.weekly?.usedPercent == 25)
        #expect(quota.weekly?.windowMinutes == nil)
        #expect(quota.weekly?.resetsAt == ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z"))
    }

    @Test("rejects a log without a usable billing snapshot")
    func rejectsMissingSnapshot() async {
        let service = GrokQuotaService(loadLog: {
            Data(#"{"ts":"2027-01-01T00:00:00Z","msg":"other"}"#.utf8)
        })

        await #expect(throws: GrokQuotaServiceError.self) {
            _ = try await service.fetchQuota()
        }
    }

    private func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
