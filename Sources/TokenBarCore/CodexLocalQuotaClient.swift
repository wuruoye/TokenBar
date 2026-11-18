import Foundation

/// Reads quota already recorded by Codex; never launches Codex or sends a request.
struct CodexLocalQuotaClient: Sendable {
    private let homeURL: URL
    private let now: @Sendable () -> Date

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        let configured = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let home = environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.homeURL = configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".codex", isDirectory: true)
        self.now = now
    }

    func fetchQuota() throws -> QuotaSnapshot {
        var latest: QuotaSnapshot?
        let referenceDate = self.now()
        for candidate in self.sessionFiles() {
            try Task.checkCancellation()
            // Codex appends events, so older unchanged files cannot contain a newer sample.
            if let latest, candidate.modifiedAt < latest.updatedAt { break }
            guard let snapshot = try? Self.latestQuota(at: candidate.url, now: referenceDate)
            else {
                continue
            }
            if latest.map({ snapshot.updatedAt > $0.updatedAt }) ?? true {
                latest = snapshot
            }
        }
        try Task.checkCancellation()
        guard let latest else { throw CodexQuotaServiceError.localQuotaUnavailable }
        func currentWindow(_ window: QuotaWindowSnapshot?) -> QuotaWindowSnapshot? {
            guard let window else { return nil }
            if let reset = window.resetsAt, reset <= referenceDate { return nil }
            return window
        }
        let session = currentWindow(latest.session)
        let weekly = currentWindow(latest.weekly)
        guard session != nil || weekly != nil else {
            throw CodexQuotaServiceError.localQuotaExpired
        }
        return QuotaSnapshot(
            session: session,
            weekly: weekly,
            resetCredits: nil,
            updatedAt: latest.updatedAt)
    }

    private func sessionFiles() -> [(url: URL, modifiedAt: Date)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var files: [(url: URL, modifiedAt: Date)] = []
        for name in ["sessions", "archived_sessions"] {
            guard let enumerator = FileManager.default.enumerator(
                at: self.homeURL.appendingPathComponent(name, isDirectory: true),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
            else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true
                else {
                    continue
                }
                files.append((url, values.contentModificationDate ?? .distantPast))
            }
        }
        return files.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func latestQuota(at url: URL, now: Date) throws -> QuotaSnapshot? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var offset = try file.seekToEnd()
        var partialLine = Data()
        while offset > 0 {
            try Task.checkCancellation()
            let count = min(offset, 1024 * 1024)
            offset -= count
            try file.seek(toOffset: offset)
            var data = try file.read(upToCount: Int(count)) ?? Data()
            data.append(partialLine)
            partialLine = Data()
            if offset > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else {
                    partialLine = data
                    continue
                }
                partialLine = data.prefix(upTo: newline)
                data = data.suffix(from: data.index(after: newline))
            }
            if let snapshot = Self.latestQuota(in: data, now: now) {
                return snapshot
            }
        }
        return nil
    }

    private static func latestQuota(in data: Data, now: Date) -> QuotaSnapshot? {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        for line in data.split(separator: 0x0A).reversed() {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  entry.type == "event_msg",
                  entry.payload.type == "token_count",
                  let limits = entry.payload.rateLimits,
                  limits.limitId == nil || limits.limitId == "codex",
                  let timestamp = fractional.date(from: entry.timestamp)
                    ?? seconds.date(from: entry.timestamp),
                  timestamp.timeIntervalSince(now) <= 60
            else {
                continue
            }
            let primary = limits.primary?.snapshot
            let secondary = limits.secondary?.snapshot
            let windows = [primary, secondary].compactMap { $0 }
            let session = windows.first { $0.windowMinutes == 300 }
                ?? primary.flatMap { $0.windowMinutes == nil ? $0 : nil }
            let weekly = windows.first { $0.windowMinutes == 10080 }
                ?? secondary.flatMap { $0.windowMinutes == nil ? $0 : nil }
            guard session != nil || weekly != nil else { continue }
            return QuotaSnapshot(
                session: session,
                weekly: weekly,
                resetCredits: nil,
                updatedAt: timestamp)
        }
        return nil
    }
}

private extension CodexLocalQuotaClient {
    struct Entry: Decodable {
        let type: String
        let timestamp: String
        let payload: Payload
    }

    struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits?

        private enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let limitId: String?
        let primary: Window?
        let secondary: Window?

        private enum CodingKeys: String, CodingKey {
            case limitId = "limit_id"
            case primary
            case secondary
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Double?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        var snapshot: QuotaWindowSnapshot? {
            guard self.usedPercent.isFinite,
                  (0 ... 100).contains(self.usedPercent)
            else {
                return nil
            }
            return QuotaWindowSnapshot(
                usedPercent: self.usedPercent,
                windowMinutes: self.windowMinutes,
                resetsAt: self.resetsAt.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
        }
    }
}
