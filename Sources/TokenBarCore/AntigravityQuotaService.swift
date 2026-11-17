import Foundation

public enum AntigravityQuotaServiceError: LocalizedError, Sendable {
    case localQuotaUnavailable

    public var errorDescription: String? {
        switch self {
        case .localQuotaUnavailable:
            "Antigravity quota is read-only. TokenBar shows the last saved quota, if available."
        }
    }
}

/// DashboardModel restores the last saved quota snapshot. Antigravity's local
/// quota endpoint can trigger background requests, so refresh does not query it.
public struct AntigravityQuotaService: QuotaProviding, Sendable {
    public let platform = TokenPlatform.antigravity

    public init() {}

    public func fetchQuota() async throws -> QuotaSnapshot {
        throw AntigravityQuotaServiceError.localQuotaUnavailable
    }

    public static func antigravityHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let configured = environment["ANTIGRAVITY_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let home = environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".gemini/antigravity", isDirectory: true)
    }
}
