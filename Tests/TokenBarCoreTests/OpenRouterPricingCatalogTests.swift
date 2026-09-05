import Foundation
import Testing
@testable import TokenBarCore

@Suite("OpenRouterPricingCatalogUpdater")
struct OpenRouterPricingCatalogTests {
    @Test("stores a validated catalog and keeps the previous one when the schema changes")
    func rejectsACatalogWithoutGeminiPrices() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("openrouter-models.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = OpenRouterPricingCatalogUpdater(
            fileURL: fileURL,
            now: { Date(timeIntervalSince1970: 1_786_400_000) },
            fetch: { _ in Self.validCatalog })
        #expect(await valid.refreshIfNeeded() == fileURL)
        #expect(try Data(contentsOf: fileURL) == Self.validCatalog)
        let permissions = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        // Only `:batch` variants remain priced, so no standard Gemini rate survives.
        let renamed = Data(
            String(data: Self.validCatalog, encoding: .utf8)!
                .replacingOccurrences(of: "\"google/gemini-", with: "\"google/gemini:batch-")
                .utf8)
        let stale = OpenRouterPricingCatalogUpdater(
            fileURL: fileURL,
            now: { Date(timeIntervalSince1970: 1_786_400_000 + 3 * 24 * 60 * 60) },
            fetch: { _ in renamed })
        #expect(await stale.refreshIfNeeded() == fileURL)
        #expect(try Data(contentsOf: fileURL) == Self.validCatalog)
    }

    private static let validCatalog: Data = {
        var models: [[String: Any]] = []
        for index in 0 ..< 8 {
            models.append([
                "id": "google/gemini-\(index).5-flash",
                "pricing": ["prompt": "0.0000003", "completion": "0.0000025"],
            ])
        }
        for index in 0 ..< 50 {
            models.append([
                "id": "vendor/filler-\(index)",
                "pricing": ["prompt": "0.000001", "completion": "0.000002"],
            ])
        }
        return try! JSONSerialization.data(withJSONObject: ["data": models])
    }()
}
