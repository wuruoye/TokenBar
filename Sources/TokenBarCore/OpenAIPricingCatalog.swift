import Foundation

public protocol OpenAIPricingCatalogUpdating: Sendable {
    func refreshIfNeeded() async -> URL?
}

public actor OpenAIPricingCatalogUpdater: OpenAIPricingCatalogUpdating {
    public static let officialMarkdownURL = URL(
        string: "https://developers.openai.com/api/docs/pricing.md")!
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
        sourceURL: URL = OpenAIPricingCatalogUpdater.officialMarkdownURL,
        fileURL: URL = OpenAIPricingCatalogUpdater.defaultURL(),
        refreshInterval: TimeInterval = OpenAIPricingCatalogUpdater.defaultRefreshInterval,
        retryInterval: TimeInterval = OpenAIPricingCatalogUpdater.defaultRetryInterval,
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
            .appendingPathComponent("openai-pricing.md", isDirectory: false)
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
        guard data.count >= 1_024,
              data.count <= 2_000_000,
              let markdown = String(data: data, encoding: .utf8)
        else {
            return false
        }
        let lines = markdown.lines
        guard lines.contains(where: { $0 == "# Pricing" }) else { return false }
        return Self.hasValidPricingSection(lines, heading: "### Standard pricing data")
            && Self.hasValidPricingSection(lines, heading: "### Fast pricing data")
    }

    private nonisolated static func hasValidPricingSection(
        _ lines: [String],
        heading: String) -> Bool
    {
        let expectedHeader = [
            "Model",
            "Short context input",
            "Short context cached input",
            "Short context cache writes",
            "Short context output",
            "Long context input",
            "Long context cached input",
            "Long context cache writes",
            "Long context output",
        ]
        guard let headingIndex = lines.firstIndex(of: heading) else { return false }
        let section = lines[lines.index(after: headingIndex)...]
        guard let headerIndex = section.firstIndex(where: { $0.hasPrefix("| Model |") }),
              Self.tableCells(section[headerIndex]) == expectedHeader
        else {
            return false
        }

        let rows = section[section.index(after: headerIndex)...]
            .dropFirst()
            .prefix(while: { $0.hasPrefix("|") })
            .map(Self.tableCells)
        guard rows.count >= 8,
              rows.allSatisfy({ cells in
                  cells.count == expectedHeader.count
                      && !cells[0].isEmpty
                      && cells.dropFirst().allSatisfy(Self.isPriceCell)
              })
        else {
            return false
        }

        let requiredModels = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        return requiredModels.allSatisfy { model in
            rows.contains(where: { cells in
                cells[0] == model
            })
        }
    }

    private nonisolated static func tableCells(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private nonisolated static func isPriceCell(_ value: String) -> Bool {
        if value == "-" { return true }
        guard value.hasPrefix("$"),
              let price = Double(value.dropFirst())
        else {
            return false
        }
        return price.isFinite && price > 0 && price <= 1_000
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
              response.url?.host == officialMarkdownURL.host,
              response.mimeType == "text/markdown"
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

private extension String {
    var lines: [String] {
        self.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
