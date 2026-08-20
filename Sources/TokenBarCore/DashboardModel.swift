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

private enum QuotaRefreshResult: Sendable {
    case success(TokenPlatform, QuotaSnapshot)
    case cancelled(TokenPlatform)
    case failure(TokenPlatform, String)
}

@MainActor
@Observable
public final class DashboardModel {
    public static let defaultBackgroundRefreshInterval: Duration = .seconds(5 * 60)
    public static let defaultQuotaRefreshInterval = DashboardModel.defaultBackgroundRefreshInterval
    public static let defaultActivityRefreshInterval = DashboardModel.defaultBackgroundRefreshInterval
    public static let automaticQuotaRefreshMinimumAge: TimeInterval = 60

    public private(set) var quotas: [TokenPlatform: DashboardSourceState<QuotaSnapshot>]
    public private(set) var weeklyQuotaUsageHistories: [TokenPlatform: WeeklyQuotaUsageHistory] = [:]
    public private(set) var activity = DashboardSourceState<ActivitySnapshot>()
    public var scope: DashboardScope = .codex

    public var quota: DashboardSourceState<QuotaSnapshot> {
        self.quotaState(for: .codex)
    }

    public var quotaSnapshot: QuotaSnapshot? { self.quota.value }
    public var activitySnapshot: ActivitySnapshot? { self.activity.value }
    public var visibleActivitySnapshot: ActivitySnapshot? {
        self.activity.value?.scoped(to: self.scope.platform)
    }

    public var visibleActivity: DashboardSourceState<ActivitySnapshot> {
        DashboardSourceState(
            value: self.visibleActivitySnapshot,
            isRefreshing: self.activity.isRefreshing,
            errorMessage: self.activity.errorMessage)
    }

    @ObservationIgnored public var quotaResetHandler: ((QuotaResetEvent) -> Void)?
    @ObservationIgnored private let quotaServices: [TokenPlatform: any QuotaProviding]
    @ObservationIgnored private let activityService: any ActivityProviding
    @ObservationIgnored private let cache: (any ActivitySnapshotCaching)?
    @ObservationIgnored private let quotaCache: (any QuotaSnapshotCaching)?
    @ObservationIgnored private let weeklyQuotaUsageCache: (any WeeklyQuotaUsageCaching)?
    @ObservationIgnored private var quotaRefreshInterval: Duration
    @ObservationIgnored private var activityRefreshInterval: Duration
    @ObservationIgnored private var statisticsTimeZone: TokenBarStatisticsTimeZone
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var quotaTimerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAllTask: Task<Void, Never>?
    @ObservationIgnored private var activityRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var activityRefreshGeneration = 0
    @ObservationIgnored private var lastQuotaRefreshAttemptAt: [TokenPlatform: Date] = [:]
    @ObservationIgnored private var quotaRefreshEnabledPlatforms: Set<TokenPlatform>
    @ObservationIgnored private var quotaResetDetector = QuotaResetDetector()
    @ObservationIgnored private var isStarted = false

    public init(
        quotaService: any QuotaProviding = CodexQuotaService(),
        additionalQuotaServices: [any QuotaProviding] = [],
        activityService: any ActivityProviding = ActivityService(),
        cache: (any ActivitySnapshotCaching)? = SnapshotCache(),
        quotaCache: (any QuotaSnapshotCaching)? = nil,
        weeklyQuotaUsageCache: (any WeeklyQuotaUsageCaching)? = nil,
        quotaRefreshInterval: Duration = DashboardModel.defaultQuotaRefreshInterval,
        activityRefreshInterval: Duration = DashboardModel.defaultActivityRefreshInterval,
        statisticsTimeZone: TokenBarStatisticsTimeZone = TokenBarSettings.defaultStatisticsTimeZone)
    {
        var quotaServices: [TokenPlatform: any QuotaProviding] = [:]
        for service in [quotaService] + additionalQuotaServices {
            quotaServices[service.platform] = service
        }
        self.quotaServices = quotaServices
        self.quotaRefreshEnabledPlatforms = Set(quotaServices.keys)
        self.quotas = quotaServices.reduce(into: [:]) { states, entry in
            states[entry.key] = DashboardSourceState()
        }
        self.activityService = activityService
        self.cache = cache
        self.quotaCache = quotaCache
        self.weeklyQuotaUsageCache = weeklyQuotaUsageCache
        self.quotaRefreshInterval = quotaRefreshInterval
        self.activityRefreshInterval = activityRefreshInterval
        self.statisticsTimeZone = statisticsTimeZone
        self.sleep = { duration in
            try await Task.sleep(for: duration)
        }
        self.now = Date.init
    }

    init(
        quotaService: any QuotaProviding,
        additionalQuotaServices: [any QuotaProviding] = [],
        activityService: any ActivityProviding,
        cache: (any ActivitySnapshotCaching)?,
        quotaCache: (any QuotaSnapshotCaching)? = nil,
        weeklyQuotaUsageCache: (any WeeklyQuotaUsageCaching)? = nil,
        quotaRefreshInterval: Duration,
        activityRefreshInterval: Duration,
        statisticsTimeZone: TokenBarStatisticsTimeZone = TokenBarSettings.defaultStatisticsTimeZone,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        var quotaServices: [TokenPlatform: any QuotaProviding] = [:]
        for service in [quotaService] + additionalQuotaServices {
            quotaServices[service.platform] = service
        }
        self.quotaServices = quotaServices
        self.quotaRefreshEnabledPlatforms = Set(quotaServices.keys)
        self.quotas = quotaServices.reduce(into: [:]) { states, entry in
            states[entry.key] = DashboardSourceState()
        }
        self.activityService = activityService
        self.cache = cache
        self.quotaCache = quotaCache
        self.weeklyQuotaUsageCache = weeklyQuotaUsageCache
        self.quotaRefreshInterval = quotaRefreshInterval
        self.activityRefreshInterval = activityRefreshInterval
        self.statisticsTimeZone = statisticsTimeZone
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
        if let cachedUsage = try? await self.weeklyQuotaUsageCache?.loadWeeklyQuotaUsage() {
            self.weeklyQuotaUsageHistories = cachedUsage.filter {
                self.quotaServices[$0.key] != nil
            }
        }
        var seededWeeklyQuotaUsage = false
        if let cachedQuotas = try? await self.quotaCache?.loadQuotas() {
            for (platform, snapshot) in cachedQuotas
                where self.quotaServices[platform] != nil
                    && self.quotaState(for: platform).value == nil
            {
                seededWeeklyQuotaUsage = self.recordWeeklyQuotaUsage(snapshot, for: platform)
                    || seededWeeklyQuotaUsage
                self.setQuotaState(DashboardSourceState(value: snapshot), for: platform)
                if self.quotaRefreshEnabledPlatforms.contains(platform) {
                    _ = self.quotaResetDetector.observe(snapshot, for: platform)
                }
            }
        }
        if seededWeeklyQuotaUsage {
            try? await self.weeklyQuotaUsageCache?.saveWeeklyQuotaUsage(
                self.weeklyQuotaUsageHistories)
        }

        self.startRefreshTimers()
        await self.refreshAll(forceQuota: false)
    }

    public func stop() {
        self.isStarted = false
        self.quotaTimerTask?.cancel()
        self.quotaTimerTask = nil
        self.refreshAllTask?.cancel()
        self.refreshAllTask = nil
        self.activityRefreshGeneration += 1
        self.activityRefreshTask?.cancel()
        self.activityRefreshTask = nil
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

    @discardableResult
    public func updateStatisticsTimeZone(_ timeZone: TokenBarStatisticsTimeZone) -> Bool {
        guard self.statisticsTimeZone != timeZone else { return false }
        self.statisticsTimeZone = timeZone
        return true
    }

    @discardableResult
    public func updateQuotaRefreshEnabled(
        _ isEnabled: Bool,
        for platform: TokenPlatform) -> Bool
    {
        guard self.quotaServices[platform] != nil else { return false }
        if isEnabled {
            return self.quotaRefreshEnabledPlatforms.insert(platform).inserted
        }
        guard self.quotaRefreshEnabledPlatforms.remove(platform) != nil else { return false }
        self.lastQuotaRefreshAttemptAt.removeValue(forKey: platform)
        self.quotaResetDetector.reset(for: platform)
        let state = self.quotaState(for: platform)
        if state.isRefreshing {
            self.setQuotaState(
                DashboardSourceState(
                    value: state.value,
                    errorMessage: state.errorMessage),
                for: platform)
        }
        return true
    }

    public func refreshAll(forceQuota: Bool = true) async {
        if let refreshAllTask = self.refreshAllTask {
            await refreshAllTask.value
            return
        }

        let refreshAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshQuotas(force: forceQuota)
            await self.refreshActivity()
        }
        self.refreshAllTask = refreshAllTask
        await refreshAllTask.value
        self.refreshAllTask = nil
    }

    public func refreshQuota() async {
        await self.refreshQuota(for: .codex)
    }

    public func refreshQuotas(force: Bool = true) async {
        let pending = self.quotaServices.filter { platform, _ in
            self.quotaRefreshEnabledPlatforms.contains(platform)
                && !self.quotaState(for: platform).isRefreshing
                && (force || self.shouldAutomaticallyRefreshQuota(for: platform))
        }
        let attemptedAt = self.now()
        let previous = self.quotas
        for platform in pending.keys {
            self.lastQuotaRefreshAttemptAt[platform] = attemptedAt
            let state = self.quotaState(for: platform)
            self.setQuotaState(
                DashboardSourceState(
                    value: state.value,
                    isRefreshing: true,
                    errorMessage: nil),
                for: platform)
        }

        var savedSnapshot = false
        await withTaskGroup(of: QuotaRefreshResult.self) { group in
            for (platform, service) in pending {
                group.addTask {
                    do {
                        let snapshot = try await service.fetchQuota()
                        try Task.checkCancellation()
                        return .success(platform, snapshot)
                    } catch is CancellationError {
                        return .cancelled(platform)
                    } catch {
                        return .failure(platform, error.localizedDescription)
                    }
                }
            }
            for await result in group {
                switch result {
                case let .success(platform, snapshot):
                    self.acceptQuotaSnapshot(
                        snapshot,
                        mergingFrom: previous[platform]?.value,
                        for: platform)
                    savedSnapshot = true
                case let .cancelled(platform):
                    let state = previous[platform] ?? DashboardSourceState()
                    self.setQuotaState(state, for: platform)
                case let .failure(platform, message):
                    self.setQuotaState(
                        DashboardSourceState(
                            value: previous[platform]?.value,
                            errorMessage: message),
                        for: platform)
                }
            }
        }
        if savedSnapshot {
            try? await self.quotaCache?.saveQuotas(self.quotaSnapshots())
            try? await self.weeklyQuotaUsageCache?.saveWeeklyQuotaUsage(
                self.weeklyQuotaUsageHistories)
        }
    }

    public func refreshQuota(for platform: TokenPlatform) async {
        guard self.quotaRefreshEnabledPlatforms.contains(platform),
              let quotaService = self.quotaServices[platform]
        else {
            return
        }
        let current = self.quotaState(for: platform)
        guard !current.isRefreshing else { return }
        self.lastQuotaRefreshAttemptAt[platform] = self.now()
        self.setQuotaState(
            DashboardSourceState(
                value: current.value,
                isRefreshing: true,
                errorMessage: nil),
            for: platform)
        do {
            let snapshot = try await quotaService.fetchQuota()
            try Task.checkCancellation()
            self.acceptQuotaSnapshot(
                snapshot,
                mergingFrom: current.value,
                for: platform)
            try? await self.quotaCache?.saveQuotas(self.quotaSnapshots())
            try? await self.weeklyQuotaUsageCache?.saveWeeklyQuotaUsage(
                self.weeklyQuotaUsageHistories)
        } catch is CancellationError {
            self.setQuotaState(
                DashboardSourceState(
                    value: current.value,
                    errorMessage: current.errorMessage),
                for: platform)
        } catch {
            self.setQuotaState(
                DashboardSourceState(
                    value: current.value,
                    errorMessage: error.localizedDescription),
                for: platform)
        }
    }

    public func quotaState(for platform: TokenPlatform) -> DashboardSourceState<QuotaSnapshot> {
        self.quotas[platform] ?? DashboardSourceState()
    }

    public func weeklyQuotaUsage(for platform: TokenPlatform) -> WeeklyQuotaUsageHistory? {
        self.weeklyQuotaUsageHistories[platform]
    }

    public func weeklyQuotaUsageToday(for platform: TokenPlatform) -> WeeklyQuotaDailyUsage? {
        self.weeklyQuotaUsageHistories[platform]?.usage(
            at: self.now(),
            statisticsTimeZone: self.statisticsTimeZone)
    }

    public func weeklyQuotaUsage(
        for platform: TokenPlatform,
        on date: String) -> WeeklyQuotaDailyUsage?
    {
        self.weeklyQuotaUsageHistories[platform]?.usage(
            on: date,
            statisticsTimeZone: self.statisticsTimeZone)
    }

    private func setQuotaState(
        _ state: DashboardSourceState<QuotaSnapshot>,
        for platform: TokenPlatform)
    {
        var quotas = self.quotas
        quotas[platform] = state
        self.quotas = quotas
    }

    private func quotaSnapshots() -> [TokenPlatform: QuotaSnapshot] {
        self.quotas.reduce(into: [:]) { snapshots, entry in
            snapshots[entry.key] = entry.value.value
        }
    }

    private func acceptQuotaSnapshot(
        _ snapshot: QuotaSnapshot,
        mergingFrom previous: QuotaSnapshot?,
        for platform: TokenPlatform)
    {
        let snapshot = Self.mergingMissingResetDates(
            in: snapshot,
            from: previous,
            now: self.now())
        _ = self.recordWeeklyQuotaUsage(snapshot, for: platform)
        self.setQuotaState(DashboardSourceState(value: snapshot), for: platform)
        let events = self.quotaResetDetector.observe(snapshot, for: platform)
        for event in events {
            self.quotaResetHandler?(event)
        }
    }

    @discardableResult
    private func recordWeeklyQuotaUsage(
        _ snapshot: QuotaSnapshot,
        for platform: TokenPlatform) -> Bool
    {
        let previous = self.weeklyQuotaUsageHistories[platform]
        let history = previous?.recording(snapshot)
            ?? WeeklyQuotaUsageHistory.starting(with: snapshot)
        guard let history, history != previous else { return false }
        var histories = self.weeklyQuotaUsageHistories
        histories[platform] = history
        self.weeklyQuotaUsageHistories = histories
        return true
    }

    private func shouldAutomaticallyRefreshQuota(for platform: TokenPlatform) -> Bool {
        let now = self.now()
        if let lastAttempt = self.lastQuotaRefreshAttemptAt[platform],
           now.timeIntervalSince(lastAttempt) < Self.automaticQuotaRefreshMinimumAge
        {
            return false
        }
        guard let updatedAt = self.quotaState(for: platform).value?.updatedAt else {
            return true
        }
        return now.timeIntervalSince(updatedAt) >= Self.automaticQuotaRefreshMinimumAge
    }

    private static func mergingMissingResetDates(
        in snapshot: QuotaSnapshot,
        from previous: QuotaSnapshot?,
        now: Date) -> QuotaSnapshot
    {
        func merge(
            _ window: QuotaWindowSnapshot?,
            previous: QuotaWindowSnapshot?) -> QuotaWindowSnapshot?
        {
            guard let window else { return nil }
            let inheritedReset: Date? = {
                guard window.resetsAt == nil,
                      let reset = previous?.resetsAt,
                      reset > now,
                      reset > snapshot.updatedAt
                else {
                    return nil
                }
                if let currentMinutes = window.windowMinutes,
                   let previousMinutes = previous?.windowMinutes,
                   currentMinutes != previousMinutes
                {
                    return nil
                }
                guard let windowMinutes = window.windowMinutes ?? previous?.windowMinutes,
                      windowMinutes > 0,
                      reset.timeIntervalSince(snapshot.updatedAt)
                      <= TimeInterval(windowMinutes * 60)
                else {
                    return nil
                }
                return reset
            }()
            return QuotaWindowSnapshot(
                usedPercent: window.usedPercent,
                windowMinutes: window.windowMinutes ?? previous?.windowMinutes,
                resetsAt: window.resetsAt ?? inheritedReset)
        }
        return QuotaSnapshot(
            session: merge(snapshot.session, previous: previous?.session),
            weekly: merge(snapshot.weekly, previous: previous?.weekly),
            resetCredits: snapshot.resetCredits,
            updatedAt: snapshot.updatedAt,
            origin: snapshot.origin)
    }

    public var isRefreshing: Bool {
        self.activity.isRefreshing || self.quotas.values.contains(where: \.isRefreshing)
    }

    private func weeklyResetDates() -> [TokenPlatform: Date] {
        self.quotas.reduce(into: [:]) { result, entry in
            guard self.quotaRefreshEnabledPlatforms.contains(entry.key),
                  let windowStart = entry.value.value?.weekly?
                .weeklyPacing(at: self.now(), weekdaysOnly: false)?.windowStart
            else {
                return
            }
            result[entry.key] = windowStart
        }
    }

    public func refreshActivity() async {
        await self.startActivityRefresh(restarting: false)
    }

    public func restartActivityRefresh() async {
        await self.startActivityRefresh(restarting: true)
    }

    private func startActivityRefresh(restarting: Bool) async {
        if restarting {
            self.activityRefreshGeneration += 1
            self.activityRefreshTask?.cancel()
            self.activityRefreshTask = nil
        } else if self.activityRefreshTask != nil {
            return
        }
        let generation = self.activityRefreshGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performActivityRefresh(generation: generation)
        }
        self.activityRefreshTask = task
        await task.value
        if generation == self.activityRefreshGeneration {
            self.activityRefreshTask = nil
        }
    }

    private func performActivityRefresh(generation: Int) async {
        guard generation == self.activityRefreshGeneration else { return }
        self.activity = DashboardSourceState(
            value: self.activity.value,
            isRefreshing: true,
            errorMessage: nil)
        while true {
            let statisticsTimeZone = self.statisticsTimeZone
            do {
                let snapshot = try await self.activityService.fetchActivity(
                    sinceWeeklyResetAtByPlatform: self.weeklyResetDates(),
                    statisticsTimeZone: statisticsTimeZone)
                try Task.checkCancellation()
                guard generation == self.activityRefreshGeneration else { return }
                guard statisticsTimeZone == self.statisticsTimeZone else { continue }
                self.activity = DashboardSourceState(value: snapshot)
                try? await self.cache?.saveActivity(snapshot)
                return
            } catch is CancellationError {
                guard generation == self.activityRefreshGeneration else { return }
                self.activity = DashboardSourceState(
                    value: self.activity.value,
                    errorMessage: self.activity.errorMessage)
                return
            } catch {
                guard generation == self.activityRefreshGeneration else { return }
                guard statisticsTimeZone == self.statisticsTimeZone else { continue }
                self.activity = DashboardSourceState(
                    value: self.activity.value,
                    errorMessage: error.localizedDescription)
                return
            }
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
                await self.refreshAll(forceQuota: false)
            }
        }
    }
}
