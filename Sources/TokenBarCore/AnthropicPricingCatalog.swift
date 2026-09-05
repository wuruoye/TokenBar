import Foundation

public protocol AnthropicPricingCatalogUpdating: Sendable {
    func refreshIfNeeded() async -> URL?
    func refreshNowIfAllowed() async -> URL?
}

public extension AnthropicPricingCatalogUpdating {
    func refreshNowIfAllowed() async -> URL? { nil }
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
            guard Self.isValidOfficialMarkdown(data) else {
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
              let header = markdown.split(separator: "\n").first(where: {
                  Self.isOfficialPricingHeader(String($0))
              }),
              Self.tableCells(String(header)).count == 6
        else {
            return false
        }
        return markdown.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("| Claude ") }
            .count >= 5
    }

    private nonisolated static func isOfficialPricingHeader(_ line: String) -> Bool {
        let header = line.trimmingCharacters(in: .whitespaces).lowercased()
        return header.hasPrefix("| model")
            && header.contains("base input tokens")
            && header.contains("5m cache writes")
            && header.contains("1h cache writes")
            && (header.contains("cache hits and refreshes")
                || header.contains("cache hits & refreshes"))
            && header.contains("output tokens")
    }

    private nonisolated static func tableCells(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
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
