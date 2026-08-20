import Foundation

public protocol ActivitySnapshotCaching: Sendable {
    func loadActivity() async throws -> ActivitySnapshot?
    func saveActivity(_ snapshot: ActivitySnapshot) async throws
}

public protocol QuotaSnapshotCaching: Sendable {
    func loadQuotas() async throws -> [TokenPlatform: QuotaSnapshot]
    func saveQuotas(_ snapshots: [TokenPlatform: QuotaSnapshot]) async throws
}

public protocol WeeklyQuotaUsageCaching: Sendable {
    func loadWeeklyQuotaUsage() async throws -> [TokenPlatform: WeeklyQuotaUsageHistory]
    func saveWeeklyQuotaUsage(_ histories: [TokenPlatform: WeeklyQuotaUsageHistory]) async throws
}

public actor SnapshotCache: ActivitySnapshotCaching {
    private let fileURL: URL

    public init(fileURL: URL = SnapshotCache.defaultURL()) {
        self.fileURL = fileURL
    }

    public func loadActivity() async throws -> ActivitySnapshot? {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: self.fileURL)
        return try JSONDecoder().decode(ActivitySnapshot.self, from: data)
    }

    public func saveActivity(_ snapshot: ActivitySnapshot) async throws {
        let redacted = snapshot.redactedForCache()
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(redacted).write(to: self.fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.fileURL.path)
    }

    public nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("activity-snapshot.json", isDirectory: false)
    }
}

public actor QuotaSnapshotCache: QuotaSnapshotCaching {
    private struct Entry: Codable {
        let platform: TokenPlatform
        let snapshot: QuotaSnapshot
    }

    private struct Payload: Codable {
        let snapshots: [Entry]
    }

    private let fileURL: URL

    public init(fileURL: URL = QuotaSnapshotCache.defaultURL()) {
        self.fileURL = fileURL
    }

    public func loadQuotas() async throws -> [TokenPlatform: QuotaSnapshot] {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            return [:]
        }
        let payload = try JSONDecoder().decode(
            Payload.self,
            from: Data(contentsOf: self.fileURL))
        return payload.snapshots.reduce(into: [:]) { snapshots, entry in
            snapshots[entry.platform] = entry.snapshot
        }
    }

    public func saveQuotas(_ snapshots: [TokenPlatform: QuotaSnapshot]) async throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Payload(snapshots: snapshots
            .map { Entry(platform: $0.key, snapshot: $0.value) }
            .sorted { $0.platform.rawValue < $1.platform.rawValue })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: self.fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.fileURL.path)
    }

    public nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("quota-snapshots.json", isDirectory: false)
    }
}

public actor WeeklyQuotaUsageCache: WeeklyQuotaUsageCaching {
    private struct Entry: Codable {
        let platform: TokenPlatform
        let history: WeeklyQuotaUsageHistory
    }

    private struct Payload: Codable {
        let histories: [Entry]
    }

    private let fileURL: URL

    public init(fileURL: URL = WeeklyQuotaUsageCache.defaultURL()) {
        self.fileURL = fileURL
    }

    public func loadWeeklyQuotaUsage() async throws -> [TokenPlatform: WeeklyQuotaUsageHistory] {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            return [:]
        }
        let payload = try JSONDecoder().decode(
            Payload.self,
            from: Data(contentsOf: self.fileURL))
        return payload.histories.reduce(into: [:]) { histories, entry in
            if let history = entry.history.validated() {
                histories[entry.platform] = history
            }
        }
    }

    public func saveWeeklyQuotaUsage(
        _ histories: [TokenPlatform: WeeklyQuotaUsageHistory]) async throws
    {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Payload(histories: histories
            .map { Entry(platform: $0.key, history: $0.value) }
            .sorted { $0.platform.rawValue < $1.platform.rawValue })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: self.fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.fileURL.path)
    }

    public nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("weekly-quota-usage.json", isDirectory: false)
    }
}
