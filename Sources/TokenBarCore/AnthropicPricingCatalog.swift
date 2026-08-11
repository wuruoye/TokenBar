import Foundation

public protocol AnthropicPricingCatalogUpdating: Sendable {
    func refreshIfNeeded() async -> URL?
}

public actor AnthropicPricingCatalogUpdater: AnthropicPricingCatalogUpdating {
    public static let officialMarkdownURL = URL(
        string: "https://platform.claude.com/docs/en/about-claude/pricing.md")!
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
        sourceURL: URL = AnthropicPricingCatalogUpdater.officialMarkdownURL,
        fileURL: URL = AnthropicPricingCatalogUpdater.defaultURL(),
        refreshInterval: TimeInterval = AnthropicPricingCatalogUpdater.defaultRefreshInterval,
        retryInterval: TimeInterval = AnthropicPricingCatalogUpdater.defaultRetryInterval,
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
        let now = self.now()
        if self.isFresh(at: now) {
            return self.fileURL
        }
        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < self.retryInterval
        {
            return self.existingURL
        }
        self.lastAttemptAt = now

        do {
            let data = try await self.fetch(self.sourceURL)
            guard Self.isValidOfficialMarkdown(data) else {
                return self.existingURL
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
            return self.existingURL
        }
    }

    public nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("anthropic-pricing.md", isDirectory: false)
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

    private nonisolated static func isValidOfficialMarkdown(_ data: Data) -> Bool {
        guard data.count >= 256,
              data.count <= 2_000_000,
              let markdown = String(data: data, encoding: .utf8),
              markdown.contains("## Model pricing"),
              markdown.contains("| Model"),
              markdown.contains("Base Input Tokens"),
              markdown.contains("5m Cache Writes"),
              markdown.contains("1h Cache Writes"),
              markdown.contains("Cache Hits & Refreshes"),
              markdown.contains("Output Tokens")
        else {
            return false
        }
        return markdown.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("| Claude ") }
            .count >= 5
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url?.scheme == "https",
              response.url?.host == officialMarkdownURL.host
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
