import Foundation
import Observation

public struct DashboardSourceState<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value?
    public let isRefreshing: Bool
    public let errorMessage: String?

    public init(value: Value? = nil, isRefreshing: Bool = false, errorMessage: String? = nil) {
        self.value = value
        self.isRefreshing = isRefreshing
        self.errorMessage = errorMessage
    }
}

@MainActor
@Observable
public final class DashboardModel {
    public static let defaultBackgroundRefreshInterval: Duration = .seconds(5 * 60)
    public static let defaultQuotaRefreshInterval = DashboardModel.defaultBackgroundRefreshInterval
    public static let defaultActivityRefreshInterval = DashboardModel.defaultBackgroundRefreshInterval

    public private(set) var quota = DashboardSourceState<QuotaSnapshot>()
    public private(set) var activity = DashboardSourceState<ActivitySnapshot>()

    public var quotaSnapshot: QuotaSnapshot? { self.quota.value }
    public var activitySnapshot: ActivitySnapshot? { self.activity.value }

    @ObservationIgnored private let quotaService: any QuotaProviding
    @ObservationIgnored private let activityService: any ActivityProviding
    @ObservationIgnored private let cache: (any ActivitySnapshotCaching)?
    @ObservationIgnored private var quotaRefreshInterval: Duration
    @ObservationIgnored private var activityRefreshInterval: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var quotaTimerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAllTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    public init(
        quotaService: any QuotaProviding = CodexQuotaService(),
        activityService: any ActivityProviding = ActivityService(),
        cache: (any ActivitySnapshotCaching)? = SnapshotCache(),
        quotaRefreshInterval: Duration = DashboardModel.defaultQuotaRefreshInterval,
        activityRefreshInterval: Duration = DashboardModel.defaultActivityRefreshInterval)
    {
        self.quotaService = quotaService
        self.activityService = activityService
        self.cache = cache
        self.quotaRefreshInterval = quotaRefreshInterval
        self.activityRefreshInterval = activityRefreshInterval
        self.sleep = { duration in
            try await Task.sleep(for: duration)
        }
        self.now = Date.init
    }

    init(
        quotaService: any QuotaProviding,
        activityService: any ActivityProviding,
        cache: (any ActivitySnapshotCaching)?,
        quotaRefreshInterval: Duration,
        activityRefreshInterval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.quotaService = quotaService
        self.activityService = activityService
        self.cache = cache
        self.quotaRefreshInterval = quotaRefreshInterval
        self.activityRefreshInterval = activityRefreshInterval
        self.sleep = sleep
        self.now = now
    }

    public func start() async {
        guard !self.isStarted else { return }
        self.isStarted = true

        if self.activity.value == nil,
           let cached = try? await self.cache?.loadActivity()
        {
            self.activity = DashboardSourceState(value: cached)
        }

        self.startRefreshTimers()
        await self.refreshAll()
    }

    public func stop() {
        self.isStarted = false
        self.quotaTimerTask?.cancel()
        self.quotaTimerTask = nil
        self.refreshAllTask?.cancel()
        self.refreshAllTask = nil
    }

    public func updateBackgroundRefreshInterval(_ interval: Duration) {
        guard interval > .zero,
              self.quotaRefreshInterval != interval || self.activityRefreshInterval != interval
        else {
            return
        }
        self.quotaRefreshInterval = interval
        self.activityRefreshInterval = interval
        if self.isStarted {
            self.startRefreshTimers()
        }
    }

    public func refreshAll() async {
        if let refreshAllTask = self.refreshAllTask {
            await refreshAllTask.value
            return
        }

        let refreshAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshQuota()
            await self.refreshActivity()
        }
        self.refreshAllTask = refreshAllTask
        await refreshAllTask.value
        self.refreshAllTask = nil
    }

    public func refreshQuota() async {
        guard !self.quota.isRefreshing else { return }
        self.quota = DashboardSourceState(
            value: self.quota.value,
            isRefreshing: true,
            errorMessage: nil)
        do {
            let snapshot = try await self.quotaService.fetchQuota()
            try Task.checkCancellation()
            self.quota = DashboardSourceState(value: snapshot)
        } catch is CancellationError {
            self.quota = DashboardSourceState(
                value: self.quota.value,
                errorMessage: self.quota.errorMessage)
        } catch {
            self.quota = DashboardSourceState(
                value: self.quota.value,
                errorMessage: error.localizedDescription)
        }
    }

    public func refreshActivity() async {
        guard !self.activity.isRefreshing else { return }
        self.activity = DashboardSourceState(
            value: self.activity.value,
            isRefreshing: true,
            errorMessage: nil)
        do {
            let weeklyResetAt = self.quota.value.flatMap { snapshot in
                snapshot.weekly?.weeklyPacing(at: self.now())?.windowStart
            }
            let snapshot = try await self.activityService.fetchActivity(
                sinceWeeklyResetAt: weeklyResetAt)
            try Task.checkCancellation()
            self.activity = DashboardSourceState(value: snapshot)
            try? await self.cache?.saveActivity(snapshot)
        } catch is CancellationError {
            self.activity = DashboardSourceState(
                value: self.activity.value,
                errorMessage: self.activity.errorMessage)
        } catch {
            self.activity = DashboardSourceState(
                value: self.activity.value,
                errorMessage: error.localizedDescription)
        }
    }

    private func startRefreshTimers() {
        self.quotaTimerTask?.cancel()
        let interval = self.quotaRefreshInterval <= self.activityRefreshInterval
            ? self.quotaRefreshInterval
            : self.activityRefreshInterval
        self.quotaTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isStarted else { return }
                await self.refreshAll()
            }
        }
    }
}
