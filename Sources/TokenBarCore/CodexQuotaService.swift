import Foundation

public protocol QuotaProviding: Sendable {
    var platform: TokenPlatform { get }
    func fetchQuota() async throws -> QuotaSnapshot
}

public extension QuotaProviding {
    var platform: TokenPlatform { .codex }
}

public enum CodexQuotaServiceError: LocalizedError, Sendable {
    case noQuotaWindows
    case localQuotaUnavailable
    case localQuotaExpired

    public var errorDescription: String? {
        switch self {
        case .noQuotaWindows:
            "Codex did not return a 5-hour or weekly quota window."
        case .localQuotaUnavailable:
            "No Codex quota was found in local session logs. Use Codex to update local quota data."
        case .localQuotaExpired:
            "The quota windows recorded in Codex's local session logs have expired. Use Codex to update local quota data."
        }
    }
}

public struct CodexQuotaService: QuotaProviding, Sendable {
    public let platform = TokenPlatform.codex

    private let loadQuota: @Sendable () async throws -> QuotaSnapshot
    private let loadResetCredits: @Sendable () async throws -> QuotaResetCreditsSnapshot?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let quotaClient = CodexLocalQuotaClient(environment: environment)
        self.loadQuota = {
            try quotaClient.fetchQuota()
        }
        self.loadResetCredits = { nil }
    }

    init(loadQuota: @escaping @Sendable () async throws -> QuotaSnapshot) {
        self.loadQuota = loadQuota
        self.loadResetCredits = { nil }
    }

    init(
        loadQuota: @escaping @Sendable () async throws -> QuotaSnapshot,
        loadResetCredits: @escaping @Sendable () async throws -> QuotaResetCreditsSnapshot?)
    {
        self.loadQuota = loadQuota
        self.loadResetCredits = loadResetCredits
    }

    public func fetchQuota() async throws -> QuotaSnapshot {
        let quota = try await self.loadQuota()
        do {
            let resetCredits = try await self.loadResetCredits()
            try Task.checkCancellation()
            return QuotaSnapshot(
                session: quota.session,
                weekly: quota.weekly,
                resetCredits: resetCredits,
                updatedAt: quota.updatedAt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return quota
        }
    }

}
