import Foundation

public protocol ActivitySnapshotCaching: Sendable {
    func loadActivity() async throws -> ActivitySnapshot?
    func saveActivity(_ snapshot: ActivitySnapshot) async throws
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
