import Foundation

public protocol QuotaProviding: Sendable {
    func fetchQuota() async throws -> QuotaSnapshot
}

public enum CodexQuotaServiceError: LocalizedError, Sendable {
    case noQuotaWindows

    public var errorDescription: String? {
        switch self {
        case .noQuotaWindows:
            "Codex did not return a 5-hour or weekly quota window."
        }
    }
}

public struct CodexQuotaService: QuotaProviding, Sendable {
    private let loadQuota: @Sendable () async throws -> QuotaSnapshot
    private let loadResetCredits: @Sendable () async throws -> QuotaResetCreditsSnapshot?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let quotaClient = CodexAppServerQuotaClient(environment: environment)
        let resetCreditsClient = CodexResetCreditsClient(environment: environment)
        self.loadQuota = {
            try await quotaClient.fetchQuota()
        }
        self.loadResetCredits = {
            try await resetCreditsClient.fetch()
        }
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
