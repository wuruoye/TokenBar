import Foundation
import Testing
@testable import TokenBarCore

private actor OpenAIPricingFetchRecorder {
    private(set) var count = 0
    let data: Data

    init(data: Data) {
        self.data = data
    }

    func fetch(_: URL) -> Data {
        self.count += 1
        return self.data
    }
}

@Suite("OpenAIPricingCatalogUpdater")
struct OpenAIPricingCatalogTests {
    @Test("downloads a validated catalog once per refresh interval")
    func downloadsOncePerInterval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("openai-pricing.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_788_264_000)
        let recorder = OpenAIPricingFetchRecorder(data: Self.validMarkdown)
        let updater = OpenAIPricingCatalogUpdater(
            fileURL: fileURL,
            now: { now },
            fetch: { url in await recorder.fetch(url) })

        let first = await updater.refreshIfNeeded()
        let second = await updater.refreshIfNeeded()

        #expect(first == fileURL)
        #expect(second == fileURL)
        #expect(await recorder.count == 1)
        #expect(try Data(contentsOf: fileURL) == Self.validMarkdown)
        let permissions = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("keeps the last catalog when a refresh is invalid")
    func preservesStaleCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("openai-pricing.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = Data("previous validated catalog".utf8)
        try stale.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: fileURL.path)
        let updater = OpenAIPricingCatalogUpdater(
            fileURL: fileURL,
            now: { Date(timeIntervalSince1970: 1_788_264_000) },
            fetch: { _ in Data("invalid".utf8) })

        let result = await updater.refreshIfNeeded()

        #expect(result == fileURL)
        #expect(try Data(contentsOf: fileURL) == stale)
    }

    @Test("forces a fresh catalog once and throttles repeated unknown-model refreshes")
    func forcesFreshCatalogOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("openai-pricing.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.validMarkdown.write(to: fileURL)
        let now = Date(timeIntervalSince1970: 1_788_300_000)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fileURL.path)
        let recorder = OpenAIPricingFetchRecorder(data: Self.validMarkdown)
        let updater = OpenAIPricingCatalogUpdater(
            fileURL: fileURL,
            now: { now },
            fetch: { url in await recorder.fetch(url) })

        let cached = await updater.refreshIfNeeded()
        let refreshed = await updater.refreshNowIfAllowed()
        let throttled = await updater.refreshNowIfAllowed()

        #expect(cached == fileURL)
        #expect(refreshed == fileURL)
        #expect(throttled == nil)
        #expect(await recorder.count == 1)
    }

    @Test("rejects a catalog without the official Fast table")
    func rejectsMissingFastTable() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("openai-pricing.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = Self.validMarkdown.replacingOccurrences(
            of: "### Fast pricing data",
            with: "### Missing pricing data")
        let updater = OpenAIPricingCatalogUpdater(
            fileURL: fileURL,
            fetch: { _ in Data(invalid.utf8) })

        let result = await updater.refreshIfNeeded()

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    private static let validMarkdown = Data(
        """
        # Pricing

        ### Standard pricing data

        | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | gpt-5.6-sol | $4.00 | $0.40 | $5.00 | $20.00 | $8.00 | $0.80 | $10.00 | $30.00 |
        | gpt-5.6-terra | $2.00 | $0.20 | $2.50 | $12.00 | $4.00 | $0.40 | $5.00 | $18.00 |
        | gpt-5.6-luna | $0.20 | $0.02 | $0.25 | $1.20 | $0.40 | $0.04 | $0.50 | $1.80 |
        | gpt-5.5 (<272K context length) | $5.00 | $0.50 | - | $30.00 | $10.00 | $1.00 | - | $45.00 |
        | gpt-5.4 (<272K context length) | $2.50 | $0.25 | - | $15.00 | $5.00 | $0.50 | - | $22.50 |
        | gpt-5.4-mini | $0.75 | $0.075 | - | $4.50 | - | - | - | - |
        | gpt-5.2 | $1.75 | $0.175 | - | $14.00 | - | - | - | - |
        | gpt-5.1 | $1.25 | $0.125 | - | $10.00 | - | - | - | - |

        ### Fast pricing data

        | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | gpt-5.6-sol | $8.00 | $0.80 | $10.00 | $40.00 | $16.00 | $1.60 | $20.00 | $60.00 |
        | gpt-5.6-terra | $4.00 | $0.40 | $5.00 | $24.00 | $8.00 | $0.80 | $10.00 | $36.00 |
        | gpt-5.6-luna | $0.40 | $0.04 | $0.50 | $2.40 | $0.80 | $0.08 | $1.00 | $3.60 |
        | gpt-5.5 (<272K context length) | $12.50 | $1.25 | - | $75.00 | - | - | - | - |
        | gpt-5.4 (<272K context length) | $5.00 | $0.50 | - | $30.00 | - | - | - | - |
        | gpt-5.4-mini | $1.50 | $0.15 | - | $9.00 | - | - | - | - |
        | gpt-5.2 | $3.50 | $0.35 | - | $28.00 | - | - | - | - |
        | gpt-5.1 | $2.50 | $0.25 | - | $20.00 | - | - | - | - |
        """.utf8)
}

private extension Data {
    func replacingOccurrences(of target: String, with replacement: String) -> String {
        String(decoding: self, as: UTF8.self)
            .replacingOccurrences(of: target, with: replacement)
    }
}
