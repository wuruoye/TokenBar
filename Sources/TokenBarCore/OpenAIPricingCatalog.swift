import Foundation

public protocol OpenAIPricingCatalogUpdating: Sendable {
    func refreshIfNeeded() async -> URL?
    func refreshNowIfAllowed() async -> URL?
}

public extension OpenAIPricingCatalogUpdating {
    func refreshNowIfAllowed() async -> URL? { nil }
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
        // Only the table shape is checked, never particular model names, so
        // the copy keeps updating after OpenAI retires a model from the page.
        return Self.hasValidPricingSection(lines, heading: "### Standard pricing data")
    }

    /// Checks every table under the heading by column name, so a table that
    /// reorders columns, adds cache-write durations, or lists older models in a
    /// shorter table still passes.
    private nonisolated static func hasValidPricingSection(
        _ lines: [String],
        heading: String) -> Bool
    {
        guard let headingIndex = lines.firstIndex(of: heading) else { return false }
        let requiredColumns = [
            ["short context input", "input"],
            ["short context cached input", "cached input"],
            ["short context output", "output"],
        ]
        var rowCount = 0
        var index = lines.index(after: headingIndex)
        while index < lines.endIndex {
            let line = lines[index]
            if ["# ", "## ", "### "].contains(where: { line.hasPrefix($0) }) {
                break
            }
            guard line.hasPrefix("| Model |") else {
                index += 1
                continue
            }
            let header = Self.tableCells(line).map { $0.lowercased() }
            guard requiredColumns.allSatisfy({ names in header.contains(where: names.contains) })
            else {
                return false
            }
            index += 2
            while index < lines.endIndex, lines[index].hasPrefix("|") {
                let cells = Self.tableCells(lines[index])
                guard cells.count == header.count,
                      !cells[0].isEmpty,
                      cells.dropFirst().allSatisfy(Self.isPriceCell)
                else {
                    return false
                }
                rowCount += 1
                index += 1
            }
        }
        return rowCount >= 8
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
