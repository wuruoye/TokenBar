import Foundation
import Testing
@testable import TokenBarCore

private actor PricingFetchRecorder {
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

@Suite("AnthropicPricingCatalogUpdater")
struct AnthropicPricingCatalogTests {
    @Test("downloads a validated catalog once per refresh interval")
    func downloadsOncePerInterval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("anthropic-pricing.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let recorder = PricingFetchRecorder(data: Self.validMarkdown)
        let updater = AnthropicPricingCatalogUpdater(
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
        let fileURL = directory.appendingPathComponent("anthropic-pricing.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = Data("previous validated catalog".utf8)
        try stale.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: fileURL.path)
        let updater = AnthropicPricingCatalogUpdater(
            fileURL: fileURL,
            now: { Date(timeIntervalSince1970: 1_786_400_000) },
            fetch: { _ in Data("invalid".utf8) })

        let result = await updater.refreshIfNeeded()

        #expect(result == fileURL)
        #expect(try Data(contentsOf: fileURL) == stale)
    }

    private static let validMarkdown = Data(
        """
        # Pricing

        ## Model pricing

        | Model | Base Input Tokens | 5m Cache Writes | 1h Cache Writes | Cache Hits & Refreshes | Output Tokens |
        | --- | --- | --- | --- | --- | --- |
        | Claude Fable 5 | $10 / MTok | $12.50 / MTok | $20 / MTok | $1 / MTok | $50 / MTok |
        | Claude Opus 5 | $5 / MTok | $6.25 / MTok | $10 / MTok | $0.50 / MTok | $25 / MTok |
        | Claude Opus 4.8 | $5 / MTok | $6.25 / MTok | $10 / MTok | $0.50 / MTok | $25 / MTok |
        | Claude Sonnet 5 | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok |
        | Claude Haiku 4.5 | $1 / MTok | $1.25 / MTok | $2 / MTok | $0.10 / MTok | $5 / MTok |
        """.utf8)
}
