import Foundation

public protocol OpenRouterPricingCatalogUpdating: Sendable {
    func refreshIfNeeded() async -> URL?
    func refreshNowIfAllowed() async -> URL?
}

public extension OpenRouterPricingCatalogUpdating {
    func refreshNowIfAllowed() async -> URL? { nil }
}

/// Keeps a local copy of OpenRouter's public model catalog.
///
/// Google publishes no machine-readable Gemini rate table, so TokenBar reads
/// the same rates from this catalog, which lists them as per-token JSON along
/// with the long-context override. The helper falls back to its bundled table
/// whenever the catalog fails the checks below, so a schema change costs
/// freshness instead of correctness.
public actor OpenRouterPricingCatalogUpdater: OpenRouterPricingCatalogUpdating {
    public static let catalogURL = URL(string: "https://openrouter.ai/api/v1/models")!
    public static let defaultRefreshInterval: TimeInterval = 24 * 60 * 60
    public static let defaultRetryInterval: TimeInterval = 60 * 60

    private let sourceURL: URL
    private let fileURL: URL
    private let refreshInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (URL) async throws -> Data
    private var lastAttemptAt: Date?

    public init(
        sourceURL: URL = OpenRouterPricingCatalogUpdater.catalogURL,
        fileURL: URL = OpenRouterPricingCatalogUpdater.defaultURL(),
        refreshInterval: TimeInterval = OpenRouterPricingCatalogUpdater.defaultRefreshInterval,
        retryInterval: TimeInterval = OpenRouterPricingCatalogUpdater.defaultRetryInterval,
        now: @escaping @Sendable () -> Date = Date.init,
        fetch: (@Sendable (URL) async throws -> Data)? = nil)
    {
        self.sourceURL = sourceURL
        self.fileURL = fileURL
        self.refreshInterval = refreshInterval
        self.retryInterval = retryInterval
        self.now = now
        self.fetch = fetch ?? Self.download
    }

    public func refreshIfNeeded() async -> URL? {
        await self.refresh(force: false)
    }

    public func refreshNowIfAllowed() async -> URL? {
        await self.refresh(force: true)
    }

    private func refresh(force: Bool) async -> URL? {
        let now = self.now()
        if !force, self.isFresh(at: now) {
            return self.fileURL
        }
        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < self.retryInterval
        {
            return force ? nil : self.existingURL
        }
        self.lastAttemptAt = now

        do {
            let data = try await self.fetch(self.sourceURL)
            guard Self.isValidCatalog(data) else {
                return force ? nil : self.existingURL
            }
            let directory = self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            try data.write(to: self.fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: self.fileURL.path)
            return self.fileURL
        } catch {
            return force ? nil : self.existingURL
        }
    }

    public nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("openrouter-models.json", isDirectory: false)
    }

    private var existingURL: URL? {
        FileManager.default.fileExists(atPath: self.fileURL.path) ? self.fileURL : nil
    }

    private func isFresh(at now: Date) -> Bool {
        guard let modifiedAt = try? FileManager.default
            .attributesOfItem(atPath: self.fileURL.path)[.modificationDate] as? Date
        else {
            return false
        }
        return now.timeIntervalSince(modifiedAt) < self.refreshInterval
    }

    nonisolated static func isValidCatalog(_ data: Data) -> Bool {
        guard data.count >= 4_096,
              data.count <= 16_000_000,
              let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = catalog["data"] as? [[String: Any]],
              models.count >= 50
        else {
            return false
        }
        return models.filter { model in
            guard let id = model["id"] as? String,
                  id.hasPrefix("google/gemini"),
                  !id.contains(":"),
                  let pricing = model["pricing"] as? [String: Any]
            else {
                return false
            }
            return pricing["prompt"] != nil && pricing["completion"] != nil
        }.count >= 8
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url?.scheme == "https",
              response.url?.host == catalogURL.host
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
