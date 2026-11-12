import Compression
import CryptoKit
import Foundation

public enum ClaudeQuotaServiceError: LocalizedError, Sendable, Equatable {
    case localUsageUnavailable
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .localUsageUnavailable:
            "Claude quota is unavailable. Use Claude Code or open Claude Desktop to refresh local usage."
        case .invalidResponse:
            "Claude returned invalid quota data."
        }
    }
}

public struct ClaudeQuotaService: QuotaProviding, Sendable {
    public let platform = TokenPlatform.claude

    private let loadCachedDesktopUsage: @Sendable (Date) -> Data?
    private let loadCachedDesktopHTTPCacheUsage: @Sendable (Date) async -> Data?
    private let loadCachedClaudeConfigUsage: @Sendable (Date) -> Data?
    private let loadCachedStatusLineUsage: @Sendable (Date) -> Data?
    private let now: @Sendable () -> Date

    public init() {
        self.loadCachedDesktopUsage = { sampledAt in
            Self.cachedDesktopUsage(at: sampledAt)
        }
        let httpCacheReader = DesktopHTTPCacheReader()
        self.loadCachedDesktopHTTPCacheUsage = { sampledAt in
            await httpCacheReader.cachedUsage(at: sampledAt)
        }
        self.loadCachedClaudeConfigUsage = { sampledAt in
            Self.cachedClaudeConfigUsage(at: sampledAt)
        }
        let statusLineUsageURL = Self.statusLineUsageURL()
        self.loadCachedStatusLineUsage = { _ in
            try? Data(contentsOf: statusLineUsageURL)
        }
        self.now = Date.init
    }

    init(
        loadCachedDesktopUsage: @escaping @Sendable (Date) -> Data? = { _ in nil },
        loadCachedDesktopHTTPCacheUsage: @escaping @Sendable (Date) async -> Data? = { _ in nil },
        loadCachedClaudeConfigUsage: @escaping @Sendable (Date) -> Data? = { _ in nil },
        loadCachedStatusLineUsage: @escaping @Sendable (Date) -> Data? = { _ in nil },
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.loadCachedDesktopUsage = loadCachedDesktopUsage
        self.loadCachedDesktopHTTPCacheUsage = loadCachedDesktopHTTPCacheUsage
        self.loadCachedClaudeConfigUsage = loadCachedClaudeConfigUsage
        self.loadCachedStatusLineUsage = loadCachedStatusLineUsage
        self.now = now
    }

    public func fetchQuota() async throws -> QuotaSnapshot {
        let referenceDate = self.now()
        guard let snapshot = await self.cachedQuota(at: referenceDate) else {
            throw ClaudeQuotaServiceError.localUsageUnavailable
        }
        return snapshot
    }

    private func cachedQuota(at referenceDate: Date) async -> QuotaSnapshot? {
        let desktopHTTPCache = await self.loadCachedDesktopHTTPCacheUsage(referenceDate)
            .flatMap { try? self.decodeUsage($0, origin: .claudeDesktop) }
        let rawCandidates: [QuotaSnapshot] = [
            desktopHTTPCache,
            self.loadCachedDesktopUsage(referenceDate)
                .flatMap { try? self.decodeUsage($0, origin: .claudeDesktop) },
            self.loadCachedClaudeConfigUsage(referenceDate)
                .flatMap { try? self.decodeUsage($0, origin: .claudeDesktop) },
            self.loadCachedStatusLineUsage(referenceDate)
                .flatMap { try? self.decodeUsage($0, origin: .liveProvider) },
        ].compactMap { $0 }

        let validCandidates = rawCandidates
            .compactMap { Self.normalizedSnapshot($0, at: referenceDate) }
            .sorted { $0.updatedAt > $1.updatedAt }

        guard let primary = validCandidates.first else {
            return nil
        }

        var session = primary.session
        var weekly = primary.weekly

        for candidate in validCandidates.dropFirst() {
            session = Self.mergedWindow(session, with: candidate.session, at: referenceDate)
            weekly = Self.mergedWindow(weekly, with: candidate.weekly, at: referenceDate)
        }

        if let currentSession = session,
           currentSession.resetsAt == nil,
           rawCandidates.contains(where: { raw in
               guard let reset = raw.session?.resetsAt else { return false }
               return reset > primary.updatedAt && reset <= referenceDate
           })
        {
            session = QuotaWindowSnapshot(
                usedPercent: 0,
                windowMinutes: currentSession.windowMinutes ?? 5 * 60,
                resetsAt: nil)
        }

        if let currentWeekly = weekly,
           currentWeekly.resetsAt == nil,
           let passedReset = rawCandidates.compactMap({ raw -> Date? in
               guard let reset = raw.weekly?.resetsAt,
                     reset > primary.updatedAt,
                     reset <= referenceDate
               else {
                   return nil
               }
               return reset
           }).max()
        {
            let windowMinutes = currentWeekly.windowMinutes ?? 7 * 24 * 60
            let rolledReset = Self.nextPeriodicReset(
                from: passedReset,
                every: TimeInterval(windowMinutes * 60),
                after: referenceDate)
            weekly = QuotaWindowSnapshot(
                usedPercent: 0,
                windowMinutes: windowMinutes,
                resetsAt: rolledReset)
        }

        return QuotaSnapshot(
            session: session,
            weekly: weekly,
            resetCredits: nil,
            updatedAt: primary.updatedAt,
            origin: primary.origin)
    }

    private static func normalizedSnapshot(
        _ snapshot: QuotaSnapshot,
        at referenceDate: Date) -> QuotaSnapshot?
    {
        let age = referenceDate.timeIntervalSince(snapshot.updatedAt)
        guard age >= -60 else { return nil }

        let weekly = Self.normalizedWeeklyWindow(
            snapshot.weekly,
            sampleAge: age,
            at: referenceDate)
        let session = Self.normalizedSessionWindow(
            snapshot.session,
            sampleAge: age,
            hasValidWeekly: weekly != nil,
            at: referenceDate)

        guard session != nil || weekly != nil else {
            return nil
        }

        return QuotaSnapshot(
            session: session,
            weekly: weekly,
            resetCredits: snapshot.resetCredits,
            updatedAt: snapshot.updatedAt,
            origin: snapshot.origin)
    }

    private static func normalizedWeeklyWindow(
        _ window: QuotaWindowSnapshot?,
        sampleAge: TimeInterval,
        at referenceDate: Date) -> QuotaWindowSnapshot?
    {
        guard let window else { return nil }
        let windowMinutes = window.windowMinutes ?? 7 * 24 * 60
        let maxAge = TimeInterval(windowMinutes * 60)
        guard sampleAge < maxAge else { return nil }

        if let resetsAt = window.resetsAt {
            if resetsAt > referenceDate,
               resetsAt.timeIntervalSince(referenceDate) <= maxAge
            {
                return window
            }
            if resetsAt <= referenceDate,
               let rolledReset = Self.nextPeriodicReset(
                   from: resetsAt,
                   every: maxAge,
                   after: referenceDate)
            {
                return QuotaWindowSnapshot(
                    usedPercent: 0,
                    windowMinutes: windowMinutes,
                    resetsAt: rolledReset)
            }
            return nil
        }
        return window
    }

    private static func normalizedSessionWindow(
        _ window: QuotaWindowSnapshot?,
        sampleAge: TimeInterval,
        hasValidWeekly: Bool,
        at referenceDate: Date) -> QuotaWindowSnapshot?
    {
        guard let window else { return nil }
        let windowMinutes = window.windowMinutes ?? 5 * 60
        let maxAge = TimeInterval(windowMinutes * 60)

        if let resetsAt = window.resetsAt {
            if resetsAt > referenceDate,
               resetsAt.timeIntervalSince(referenceDate) <= maxAge,
               sampleAge < maxAge
            {
                return window
            }
            if resetsAt <= referenceDate, hasValidWeekly {
                return QuotaWindowSnapshot(
                    usedPercent: 0,
                    windowMinutes: windowMinutes,
                    resetsAt: nil)
            }
            return nil
        }

        if sampleAge < maxAge {
            return window
        }
        if hasValidWeekly {
            return QuotaWindowSnapshot(
                usedPercent: 0,
                windowMinutes: windowMinutes,
                resetsAt: nil)
        }
        return nil
    }

    private static func nextPeriodicReset(
        from reset: Date,
        every duration: TimeInterval,
        after referenceDate: Date) -> Date?
    {
        guard reset.timeIntervalSinceReferenceDate.isFinite,
              referenceDate.timeIntervalSinceReferenceDate.isFinite,
              duration.isFinite,
              duration > 0
        else {
            return nil
        }
        if reset > referenceDate { return reset }
        let elapsed = referenceDate.timeIntervalSince(reset)
        let intervals = floor(elapsed / duration) + 1
        let candidate = reset.addingTimeInterval(intervals * duration)
        return candidate.timeIntervalSinceReferenceDate.isFinite ? candidate : nil
    }

    private static func mergedWindow(
        _ current: QuotaWindowSnapshot?,
        with observed: QuotaWindowSnapshot?,
        at referenceDate: Date) -> QuotaWindowSnapshot?
    {
        guard let current else { return observed }
        guard current.resetsAt == nil,
              let reset = observed?.resetsAt,
              let windowMinutes = current.windowMinutes ?? observed?.windowMinutes,
              reset > referenceDate,
              reset.timeIntervalSince(referenceDate) <= TimeInterval(windowMinutes * 60)
        else {
            return current
        }
        return QuotaWindowSnapshot(
            usedPercent: current.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: reset)
    }

    private func decodeUsage(
        _ data: Data,
        origin: QuotaSnapshotOrigin) throws -> QuotaSnapshot
    {
        let response: UsageResponse
        do {
            response = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw ClaudeQuotaServiceError.invalidResponse
        }
        let session = response.fiveHour?.snapshot(windowMinutes: 5 * 60)
        let weekly = response.sevenDay?.snapshot(windowMinutes: 7 * 24 * 60)
        guard session != nil || weekly != nil else {
            throw ClaudeQuotaServiceError.invalidResponse
        }
        return QuotaSnapshot(
            session: session,
            weekly: weekly,
            resetCredits: nil,
            updatedAt: response.cachedAtMilliseconds.map {
                Date(timeIntervalSince1970: $0 / 1000)
            } ?? self.now(),
            origin: origin)
    }

    private static func cachedDesktopUsage(at now: Date) -> Data? {
        let url = Self.claudeAppSupportDirectory()
            .appendingPathComponent("plan-usage-history.json", isDirectory: false)
        let nowMs = now.timeIntervalSince1970 * 1000
        let maxAgeMs = Double(7 * 24 * 60 * 60 * 1000)
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(PlanUsageHistory.self, from: data),
              let sample = history.samples.max(by: { $0.timestamp < $1.timestamp }),
              nowMs - Double(sample.timestamp) >= -60 * 1000,
              nowMs - Double(sample.timestamp) < maxAgeMs,
              sample.usage.fiveHour != nil || sample.usage.sevenDay != nil
        else {
            return nil
        }

        var payload: [String: Any] = [
            "_cached_at_ms": sample.timestamp,
        ]
        if let fiveHour = sample.usage.fiveHour {
            payload["five_hour"] = ["utilization": fiveHour]
        }
        if let sevenDay = sample.usage.sevenDay {
            payload["seven_day"] = ["utilization": sevenDay]
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private static func cachedClaudeConfigUsage(at now: Date) -> Data? {
        let nowMs = now.timeIntervalSince1970 * 1000
        let maxAgeMs = Double(7 * 24 * 60 * 60 * 1000)
        var newestEntry: (fetchedAtMs: Double, payload: [String: Any])?

        for url in Self.claudeConfigFileURLs() {
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(ClaudeConfigFile.self, from: data),
                  let cached = config.cachedUsageUtilization,
                  nowMs - cached.fetchedAtMs >= -60 * 1000,
                  nowMs - cached.fetchedAtMs < maxAgeMs
            else {
                continue
            }

            if let activeAccount = config.oauthAccount?.accountUuid,
               !activeAccount.isEmpty,
               let cachedAccount = cached.accountUuid,
               !cachedAccount.isEmpty,
               activeAccount != cachedAccount
            {
                continue
            }

            var payload: [String: Any] = [
                "_cached_at_ms": cached.fetchedAtMs,
            ]
            if let fiveHour = cached.utilization.fiveHour?.dictionaryObject {
                payload["five_hour"] = fiveHour
            }
            if let sevenDay = cached.utilization.sevenDay?.dictionaryObject {
                payload["seven_day"] = sevenDay
            }
            guard payload["five_hour"] != nil || payload["seven_day"] != nil else {
                continue
            }

            if newestEntry == nil || cached.fetchedAtMs > newestEntry!.fetchedAtMs {
                newestEntry = (cached.fetchedAtMs, payload)
            }
        }

        guard let newestEntry else { return nil }
        return try? JSONSerialization.data(withJSONObject: newestEntry.payload)
    }

    fileprivate static func claudeAppSupportDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Claude", isDirectory: true)
    }

    fileprivate static func claudeConfigFileURLs() -> [URL] {
        var urls: [URL] = []
        if let customDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !customDir.isEmpty
        {
            let expanded = NSString(string: customDir).expandingTildeInPath
            urls.append(
                URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent(".claude.json", isDirectory: false))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent(".claude.json", isDirectory: false))
        urls.append(
            home
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent(".claude.json", isDirectory: false))
        return urls
    }

    private static func statusLineUsageURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("claude-rate-limits.json", isDirectory: false)
    }
}

private extension ClaudeQuotaService {
    /// Reads `/api/organizations/<org>/usage` responses persisted by Claude Desktop's
    /// Chromium Simple Cache without touching credentials or making network calls.
    final class DesktopHTTPCacheReader: @unchecked Sendable {
        private static let initialMagic: UInt64 = 0xFCFB_6D1B_A772_5C30
        private static let eofMagic: UInt64 = 0xF4FA_6F45_970D_41D8
        private static let maxCacheEntryBytes = 1 * 1024 * 1024
        private static let maxDecompressedBytes = 4 * 1024 * 1024
        private static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

        private struct CachedEntry {
            let modificationDate: Date
            let fileSize: Int
            let sampledAtMs: Double
            let payload: Data?
        }

        private struct ParsedSimpleCacheEntry {
            let sampledAtMs: Double
            let contentEncoding: String?
            let bodyOffset: Int
            let bodyLength: Int
        }

        private let lock = NSLock()
        private var cacheByPath: [String: CachedEntry] = [:]
        private let environment: [String: String]
        private let helperCandidates: [URL]

        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            self.environment = environment
            self.helperCandidates = ActivityService.helperCandidates(
                explicitURL: nil,
                environment: environment)
        }

        func cachedUsage(at now: Date) async -> Data? {
            let orgIDs = Self.candidateOrganizationIDs()
            guard !orgIDs.isEmpty else { return nil }

            let cacheDirectory = ClaudeQuotaService.claudeAppSupportDirectory()
                .appendingPathComponent("Cache", isDirectory: true)
                .appendingPathComponent("Cache_Data", isDirectory: true)
            let nowMs = now.timeIntervalSince1970 * 1000
            let maxAgeMs = Double(7 * 24 * 60 * 60 * 1000)

            var newest: (sampledAtMs: Double, payload: Data)?

            for orgID in orgIDs {
                for endpoint in Self.usageURLs(forOrganizationID: orgID) {
                    let cacheKey = "1/0/\(endpoint)"
                    let fileURL = cacheDirectory.appendingPathComponent(
                        Self.simpleCacheFilename(forKey: cacheKey),
                        isDirectory: false)

                    guard let values = try? fileURL.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                    ]),
                        values.isRegularFile == true,
                        let modifiedAt = values.contentModificationDate,
                        let fileSize = values.fileSize,
                        fileSize > 72,
                        fileSize <= Self.maxCacheEntryBytes
                    else {
                        continue
                    }

                    let modifiedAtMs = modifiedAt.timeIntervalSince1970 * 1000
                    guard nowMs - modifiedAtMs >= -60 * 1000,
                          nowMs - modifiedAtMs < maxAgeMs
                    else {
                        continue
                    }

                    if let memoized = self.memoizedEntry(
                        forPath: fileURL.path,
                        modificationDate: modifiedAt,
                        fileSize: fileSize)
                    {
                        if let payload = memoized.payload,
                           nowMs - memoized.sampledAtMs >= -60 * 1000,
                           nowMs - memoized.sampledAtMs < maxAgeMs,
                           newest == nil || memoized.sampledAtMs > newest!.sampledAtMs
                        {
                            newest = (memoized.sampledAtMs, payload)
                        }
                        continue
                    }

                    let decoded = await self.decodeCacheEntry(
                        at: fileURL,
                        expectedKey: cacheKey,
                        modifiedAt: modifiedAt)
                    let sampledAtMs = decoded?.sampledAtMs ?? modifiedAtMs
                    let payload = decoded?.payload

                    self.storeMemoizedEntry(
                        CachedEntry(
                            modificationDate: modifiedAt,
                            fileSize: fileSize,
                            sampledAtMs: sampledAtMs,
                            payload: payload),
                        forPath: fileURL.path)

                    if let payload,
                       nowMs - sampledAtMs >= -60 * 1000,
                       nowMs - sampledAtMs < maxAgeMs,
                       newest == nil || sampledAtMs > newest!.sampledAtMs
                    {
                        newest = (sampledAtMs, payload)
                    }
                }
            }

            return newest?.payload
        }

        private func memoizedEntry(
            forPath path: String,
            modificationDate: Date,
            fileSize: Int) -> CachedEntry?
        {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let entry = self.cacheByPath[path],
                  entry.modificationDate == modificationDate,
                  entry.fileSize == fileSize
            else {
                return nil
            }
            return entry
        }

        private func storeMemoizedEntry(_ entry: CachedEntry, forPath path: String) {
            self.lock.lock()
            self.cacheByPath[path] = entry
            self.lock.unlock()
        }

        private func decodeCacheEntry(
            at fileURL: URL,
            expectedKey: String,
            modifiedAt: Date) async -> (sampledAtMs: Double, payload: Data)?
        {
            guard let fileData = try? Data(contentsOf: fileURL),
                  fileData.count <= Self.maxCacheEntryBytes,
                  let parsed = Self.parseSimpleCacheEntry(
                      fileData,
                      expectedKey: expectedKey,
                      fileModifiedAt: modifiedAt)
            else {
                return nil
            }

            let bodySlice = fileData[parsed.bodyOffset ..< parsed.bodyOffset + parsed.bodyLength]
            guard let jsonBytes = await self.decompressBody(
                bodySlice,
                encoding: parsed.contentEncoding,
                fileURL: fileURL,
                offset: parsed.bodyOffset,
                length: parsed.bodyLength),
                let response = try? JSONDecoder().decode(UsageResponse.self, from: jsonBytes)
            else {
                return nil
            }

            var payloadObject: [String: Any] = [
                "_cached_at_ms": parsed.sampledAtMs,
            ]
            if let fiveHour = response.fiveHour?.dictionaryObject {
                payloadObject["five_hour"] = fiveHour
            }
            if let sevenDay = response.sevenDay?.dictionaryObject {
                payloadObject["seven_day"] = sevenDay
            }
            guard payloadObject["five_hour"] != nil || payloadObject["seven_day"] != nil,
                  let payload = try? JSONSerialization.data(withJSONObject: payloadObject)
            else {
                return nil
            }
            return (parsed.sampledAtMs, payload)
        }

        private func decompressBody(
            _ body: Data.SubSequence,
            encoding: String?,
            fileURL: URL,
            offset: Int,
            length: Int) async -> Data?
        {
            let normalizedEncoding = encoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let prefix4 = Array(body.prefix(4))

            if normalizedEncoding == "zstd" || prefix4 == Self.zstdMagic {
                return await self.decompressZstdViaHelper(
                    fileURL: fileURL,
                    offset: offset,
                    length: length)
            }
            if normalizedEncoding == "br" {
                return Self.decompressWithAppleCompression(Data(body), algorithm: COMPRESSION_BROTLI)
            }
            if normalizedEncoding == "gzip" || prefix4.prefix(2) == [0x1F, 0x8B] {
                guard let deflatePayload = Self.stripGzipHeader(Data(body)) else { return nil }
                return Self.decompressWithAppleCompression(deflatePayload, algorithm: COMPRESSION_ZLIB)
            }
            if normalizedEncoding == "deflate" {
                return Self.decompressWithAppleCompression(Data(body), algorithm: COMPRESSION_ZLIB)
            }
            if normalizedEncoding == nil || normalizedEncoding == "" || normalizedEncoding == "identity" {
                return Data(body)
            }
            return nil
        }

        private func decompressZstdViaHelper(
            fileURL: URL,
            offset: Int,
            length: Int) async -> Data?
        {
            guard let helperURL = self.helperCandidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }) else {
                return nil
            }
            guard let result = try? await ProcessRunner.run(
                executableURL: helperURL,
                arguments: [
                    "decompress-zstd",
                    "--path", fileURL.path,
                    "--offset", String(offset),
                    "--length", String(length),
                ],
                environment: self.environment,
                timeout: 5,
                maximumOutputBytes: Self.maxDecompressedBytes),
                !result.stdout.isEmpty
            else {
                return nil
            }
            return result.stdout
        }

        private static func parseSimpleCacheEntry(
            _ data: Data,
            expectedKey: String,
            fileModifiedAt: Date) -> ParsedSimpleCacheEntry?
        {
            guard data.count > 72,
                  Self.readUInt64LE(data, at: 0) == Self.initialMagic
            else {
                return nil
            }

            let keyLength = Int(Self.readUInt32LE(data, at: 12))
            let expectedKeyBytes = Data(expectedKey.utf8)
            guard keyLength == expectedKeyBytes.count,
                  24 + keyLength + 48 <= data.count,
                  data.subdata(in: 24 ..< 24 + keyLength) == expectedKeyBytes
            else {
                return nil
            }

            let eof0Offset = data.count - 24
            guard Self.readUInt64LE(data, at: eof0Offset) == Self.eofMagic else {
                return nil
            }
            let flags0 = Self.readUInt32LE(data, at: eof0Offset + 8)
            let stream0Size = Int(Self.readUInt32LE(data, at: eof0Offset + 16))
            let sha0Size = (flags0 & 2) != 0 ? 32 : 0
            let stream0Start = eof0Offset - sha0Size - stream0Size
            let eof1Offset = stream0Start - 24

            let bodyStart = 24 + keyLength
            guard stream0Size > 0,
                  eof1Offset >= bodyStart,
                  Self.readUInt64LE(data, at: eof1Offset) == Self.eofMagic
            else {
                return nil
            }

            let flags1 = Self.readUInt32LE(data, at: eof1Offset + 8)
            let sha1Size = (flags1 & 2) != 0 ? 32 : 0
            let bodyEnd = eof1Offset - sha1Size
            guard bodyEnd > bodyStart else {
                return nil
            }

            let stream0 = data.subdata(in: stream0Start ..< stream0Start + stream0Size)
            guard let headers = Self.parseHTTPResponseHeaders(from: stream0),
                  headers.statusCode == 200
            else {
                return nil
            }

            let modifiedAtMs = fileModifiedAt.timeIntervalSince1970 * 1000
            let sampledAtMs: Double
            if let headerDate = headers.date {
                let headerMs = headerDate.timeIntervalSince1970 * 1000
                if modifiedAtMs >= headerMs, modifiedAtMs - headerMs < 2000 {
                    sampledAtMs = modifiedAtMs
                } else {
                    sampledAtMs = headerMs
                }
            } else {
                sampledAtMs = modifiedAtMs
            }

            return ParsedSimpleCacheEntry(
                sampledAtMs: sampledAtMs,
                contentEncoding: headers.contentEncoding,
                bodyOffset: bodyStart,
                bodyLength: bodyEnd - bodyStart)
        }

        private static func parseHTTPResponseHeaders(
            from stream0: Data) -> (statusCode: Int, date: Date?, contentEncoding: String?)?
        {
            let httpPrefix = Data("HTTP/".utf8)
            guard let statusRange = stream0.range(of: httpPrefix) else {
                return nil
            }

            let slice = stream0[statusRange.lowerBound...]
            var lines: [String] = []
            var currentStart = slice.startIndex
            var index = slice.startIndex

            while index < slice.endIndex {
                if slice[index] == 0 {
                    if index == currentStart {
                        break
                    }
                    if let line = String(data: slice[currentStart ..< index], encoding: .isoLatin1) {
                        lines.append(line)
                    }
                    currentStart = slice.index(after: index)
                }
                index = slice.index(after: index)
            }

            guard let statusLine = lines.first else { return nil }
            let parts = statusLine.split(separator: " ")
            guard parts.count >= 2, let statusCode = Int(parts[1]) else {
                return nil
            }

            var responseDate: Date?
            var contentEncoding: String?
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch name {
                case "date":
                    responseDate = Self.parseHTTPDate(value)
                case "content-encoding":
                    contentEncoding = value
                default:
                    break
                }
            }

            return (statusCode, responseDate, contentEncoding)
        }

        private static func parseHTTPDate(_ value: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: value)
        }

        private static func simpleCacheFilename(forKey key: String) -> String {
            let digest = Array(Insecure.SHA1.hash(data: Data(key.utf8)))
            var hash: UInt64 = 0
            for index in 0 ..< 8 {
                hash |= UInt64(digest[index]) << (index * 8)
            }
            return String(format: "%016llx_0", hash)
        }

        private static func usageURLs(forOrganizationID orgID: String) -> [String] {
            [
                "https://claude.ai/api/organizations/\(orgID)/usage",
                "https://claude.ai/api/organizations/\(orgID)/usage?cedar_ember=1&skip_spend=1",
                "https://claude.ai/api/organizations/\(orgID)/usage?skip_spend=1",
            ]
        }

        private static func candidateOrganizationIDs() -> [String] {
            var activeOrgIDs: [String] = []
            var fallbackOrgIDs: [String] = []

            for url in ClaudeQuotaService.claudeConfigFileURLs() {
                guard let data = try? Data(contentsOf: url),
                      let config = try? JSONDecoder().decode(ClaudeConfigFile.self, from: data)
                else {
                    continue
                }
                if let orgID = config.oauthAccount?.organizationUuid,
                   Self.isValidUUID(orgID),
                   !activeOrgIDs.contains(orgID)
                {
                    activeOrgIDs.append(orgID)
                }
                if let rosterOrgID = config.cachedArtifactRoster?.organizationUuid,
                   Self.isValidUUID(rosterOrgID),
                   !fallbackOrgIDs.contains(rosterOrgID)
                {
                    fallbackOrgIDs.append(rosterOrgID)
                }
            }

            if !activeOrgIDs.isEmpty {
                return activeOrgIDs
            }

            let historyURL = ClaudeQuotaService.claudeAppSupportDirectory()
                .appendingPathComponent("plan-usage-history.json", isDirectory: false)
            if let data = try? Data(contentsOf: historyURL),
               let history = try? JSONDecoder().decode(PlanUsageHistory.self, from: data)
            {
                for sample in history.samples.sorted(by: { $0.timestamp > $1.timestamp }) {
                    if let orgID = sample.organizationUuid,
                       Self.isValidUUID(orgID),
                       !fallbackOrgIDs.contains(orgID)
                    {
                        fallbackOrgIDs.append(orgID)
                    }
                }
            }

            return fallbackOrgIDs
        }

        private static func isValidUUID(_ value: String) -> Bool {
            guard value.count >= 32, value.count <= 64 else { return false }
            return value.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39)
                    || (byte >= 0x41 && byte <= 0x46)
                    || (byte >= 0x61 && byte <= 0x66)
                    || byte == 0x2D
            }
        }

        private static func decompressWithAppleCompression(
            _ data: Data,
            algorithm: compression_algorithm) -> Data?
        {
            guard !data.isEmpty else { return nil }
            var destinationCapacity = max(4096, min(data.count * 8, Self.maxDecompressedBytes))
            while destinationCapacity <= Self.maxDecompressedBytes {
                var output = Data(count: destinationCapacity)
                let decodedBytes = data.withUnsafeBytes { sourceBuffer -> Int in
                    guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return output.withUnsafeMutableBytes { destBuffer -> Int in
                        guard let destBase = destBuffer.bindMemory(to: UInt8.self).baseAddress else {
                            return 0
                        }
                        return compression_decode_buffer(
                            destBase,
                            destinationCapacity,
                            sourceBase,
                            data.count,
                            nil,
                            algorithm)
                    }
                }
                if decodedBytes > 0, decodedBytes < destinationCapacity {
                    output.count = decodedBytes
                    return output
                }
                if destinationCapacity == Self.maxDecompressedBytes {
                    break
                }
                destinationCapacity = min(destinationCapacity * 4, Self.maxDecompressedBytes)
            }
            return nil
        }

        private static func stripGzipHeader(_ data: Data) -> Data? {
            let bytes = [UInt8](data)
            guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
                return nil
            }
            let flags = bytes[3]
            var offset = 10
            if (flags & 0x04) != 0 {
                guard offset + 2 <= bytes.count else { return nil }
                let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
                offset += 2 + xlen
            }
            if (flags & 0x08) != 0 {
                while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
                offset += 1
            }
            if (flags & 0x10) != 0 {
                while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
                offset += 1
            }
            if (flags & 0x02) != 0 {
                offset += 2
            }
            guard offset <= bytes.count - 8 else { return nil }
            return Data(bytes[offset ..< bytes.count - 8])
        }

        private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
            var value: UInt32 = 0
            for index in 0 ..< 4 {
                value |= UInt32(data[offset + index]) << (index * 8)
            }
            return value
        }

        private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0 ..< 8 {
                value |= UInt64(data[offset + index]) << (index * 8)
            }
            return value
        }
    }

    struct ClaudeConfigFile: Decodable {
        let oauthAccount: OAuthAccount?
        let cachedArtifactRoster: ArtifactRoster?
        let cachedUsageUtilization: CachedUsageUtilization?

        struct OAuthAccount: Decodable {
            let accountUuid: String?
            let organizationUuid: String?
        }

        struct ArtifactRoster: Decodable {
            let organizationUuid: String?
        }

        struct CachedUsageUtilization: Decodable {
            let fetchedAtMs: Double
            let accountUuid: String?
            let utilization: UsageResponse
        }
    }

    struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let cachedAtMilliseconds: Double?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case cachedAtMilliseconds = "_cached_at_ms"
        }
    }

    struct PlanUsageHistory: Decodable {
        let samples: [PlanUsageSample]
    }

    struct PlanUsageSample: Decodable {
        let timestamp: Int64
        let organizationUuid: String?
        let usage: PlanUsage

        private enum CodingKeys: String, CodingKey {
            case timestamp = "t"
            case organizationUuid = "org"
            case usage = "u"
        }
    }

    struct PlanUsage: Decodable {
        let fiveHour: Double?
        let sevenDay: Double?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "fh"
            case sevenDay = "sd"
        }
    }

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var dictionaryObject: [String: Any]? {
            guard let utilization else { return nil }
            var dict: [String: Any] = ["utilization": utilization]
            if let resetsAt {
                dict["resets_at"] = resetsAt
            }
            return dict
        }

        func snapshot(windowMinutes: Int) -> QuotaWindowSnapshot? {
            guard let utilization else { return nil }
            return QuotaWindowSnapshot(
                usedPercent: utilization.clamped(to: 0 ... 100),
                windowMinutes: windowMinutes,
                resetsAt: self.resetsAt.flatMap(Self.parseDate))
        }

        private static func parseDate(_ value: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
