import Foundation
import Testing
@testable import TokenBarCore

private enum StubFailure: Error {
    case failed
}

private actor QueueQuotaProvider: QuotaProviding {
    let platform: TokenPlatform
    private var results: [Result<QuotaSnapshot, StubFailure>]

    init(
        _ results: [Result<QuotaSnapshot, StubFailure>],
        platform: TokenPlatform = .codex)
    {
        self.platform = platform
        self.results = results
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        guard !self.results.isEmpty else { throw StubFailure.failed }
        return try self.results.removeFirst().get()
    }
}

private actor QueueActivityProvider: ActivityProviding {
    private var results: [Result<ActivitySnapshot, StubFailure>]
    private(set) var weeklyResetDates: [Date?] = []
    private(set) var statisticsTimeZones: [TokenBarStatisticsTimeZone] = []

    init(_ results: [Result<ActivitySnapshot, StubFailure>]) {
        self.results = results
    }

    func fetchActivity(
        sinceWeeklyResetAt: Date?,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.weeklyResetDates.append(sinceWeeklyResetAt)
        self.statisticsTimeZones.append(statisticsTimeZone)
        guard !self.results.isEmpty else { throw StubFailure.failed }
        return try self.results.removeFirst().get()
    }
}

private actor PausingActivityProvider: ActivityProviding {
    private let snapshots: [ActivitySnapshot]
    private(set) var statisticsTimeZones: [TokenBarStatisticsTimeZone] = []
    private var firstRequestWaiter: CheckedContinuation<Void, Never>?
    private var firstRequestRelease: CheckedContinuation<Void, Never>?

    init(_ snapshots: [ActivitySnapshot]) {
        self.snapshots = snapshots
    }

    func fetchActivity(
        sinceWeeklyResetAt _: Date?,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.statisticsTimeZones.append(statisticsTimeZone)
        let index = self.statisticsTimeZones.count - 1
        if index == 0 {
            self.firstRequestWaiter?.resume()
            self.firstRequestWaiter = nil
            await withCheckedContinuation { continuation in
                self.firstRequestRelease = continuation
            }
        }
        return self.snapshots[index]
    }

    func waitForFirstRequest() async {
        guard self.statisticsTimeZones.isEmpty else { return }
        await withCheckedContinuation { continuation in
            self.firstRequestWaiter = continuation
        }
    }

    func releaseFirstRequest() {
        self.firstRequestRelease?.resume()
        self.firstRequestRelease = nil
    }
}

private actor MemoryActivityCache: ActivitySnapshotCaching {
    var snapshot: ActivitySnapshot?

    init(snapshot: ActivitySnapshot? = nil) {
        self.snapshot = snapshot
    }

    func loadActivity() async throws -> ActivitySnapshot? {
        self.snapshot
    }

    func saveActivity(_ snapshot: ActivitySnapshot) async throws {
        self.snapshot = snapshot.redactedForCache()
    }
}

private actor MemoryQuotaCache: QuotaSnapshotCaching {
    var snapshots: [TokenPlatform: QuotaSnapshot]

    init(snapshots: [TokenPlatform: QuotaSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func loadQuotas() async throws -> [TokenPlatform: QuotaSnapshot] {
        self.snapshots
    }

    func saveQuotas(_ snapshots: [TokenPlatform: QuotaSnapshot]) async throws {
        self.snapshots = snapshots
    }
}

private actor MemoryWeeklyQuotaUsageCache: WeeklyQuotaUsageCaching {
    var histories: [TokenPlatform: WeeklyQuotaUsageHistory]

    init(histories: [TokenPlatform: WeeklyQuotaUsageHistory] = [:]) {
        self.histories = histories
    }

    func loadWeeklyQuotaUsage() async throws -> [TokenPlatform: WeeklyQuotaUsageHistory] {
        self.histories
    }

    func saveWeeklyQuotaUsage(
        _ histories: [TokenPlatform: WeeklyQuotaUsageHistory]) async throws
    {
        self.histories = histories
    }
}

private struct StaticPlatformQuotaProvider: QuotaProviding {
    let platform: TokenPlatform
    let snapshot: QuotaSnapshot

    func fetchQuota() async throws -> QuotaSnapshot {
        self.snapshot
    }
}

private actor QuotaFetchRecorder {
    private(set) var count = 0

    func record() {
        self.count += 1
    }
}

private struct RecordingPlatformQuotaProvider: QuotaProviding {
    let platform: TokenPlatform
    let snapshot: QuotaSnapshot
    let recorder: QuotaFetchRecorder

    func fetchQuota() async throws -> QuotaSnapshot {
        await self.recorder.record()
        return self.snapshot
    }
}

private actor PlatformResetActivityProvider: ActivityProviding {
    let snapshot: ActivitySnapshot
    private(set) var resets: [TokenPlatform: Date] = [:]

    init(snapshot: ActivitySnapshot) {
        self.snapshot = snapshot
    }

    func fetchActivity(
        sinceWeeklyResetAt: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.resets = [.codex: sinceWeeklyResetAt].compactMapValues { $0 }
        return self.snapshot
    }

    func fetchActivity(
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.resets = sinceWeeklyResetAtByPlatform
        return self.snapshot
    }
}

@Suite("DashboardModel")
struct DashboardModelTests {
    @Test("background refresh defaults to five minutes for both data sources")
    @MainActor
    func defaultBackgroundRefreshInterval() {
        #expect(DashboardModel.defaultQuotaRefreshInterval == .seconds(300))
        #expect(DashboardModel.defaultActivityRefreshInterval == .seconds(300))
    }

    @Test("refreshes platform quotas independently and forwards both cycle starts")
    @MainActor
    func refreshesPlatformQuotas() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codexReset = now.addingTimeInterval(4 * 86_400)
        let claudeReset = now.addingTimeInterval(6 * 86_400)
        let codexQuota = self.quota(reset: codexReset, updatedAt: now)
        let claudeQuota = self.quota(reset: claudeReset, updatedAt: now)
        let activity = PlatformResetActivityProvider(snapshot: TestFixtures.activity())
        let model = DashboardModel(
            quotaService: StaticPlatformQuotaProvider(
                platform: .codex,
                snapshot: codexQuota),
            additionalQuotaServices: [
                StaticPlatformQuotaProvider(platform: .claude, snapshot: claudeQuota),
            ],
            activityService: activity,
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { now })

        await model.refreshAll()

        #expect(model.quotaState(for: .codex).value == codexQuota)
        #expect(model.quotaState(for: .claude).value == claudeQuota)
        let resets = await activity.resets
        #expect(resets[.codex] == codexReset.addingTimeInterval(-7 * 86_400))
        #expect(resets[.claude] == claudeReset.addingTimeInterval(-7 * 86_400))
    }

    @Test("disabled quota platform is skipped at startup and refreshes after enabling")
    @MainActor
    func skipsDisabledQuotaPlatform() async {
        let codexRecorder = QuotaFetchRecorder()
        let claudeRecorder = QuotaFetchRecorder()
        let snapshot = TestFixtures.quota(usedPercent: 20)
        let model = DashboardModel(
            quotaService: RecordingPlatformQuotaProvider(
                platform: .codex,
                snapshot: snapshot,
                recorder: codexRecorder),
            additionalQuotaServices: [
                RecordingPlatformQuotaProvider(
                    platform: .claude,
                    snapshot: snapshot,
                    recorder: claudeRecorder),
            ],
            activityService: QueueActivityProvider([
                .success(TestFixtures.activity()),
            ]),
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() })

        #expect(model.updateQuotaRefreshEnabled(false, for: .claude))
        await model.start()
        model.stop()

        #expect(await codexRecorder.count == 1)
        #expect(await claudeRecorder.count == 0)
        #expect(model.updateQuotaRefreshEnabled(true, for: .claude))

        await model.refreshQuota(for: .claude)

        #expect(await claudeRecorder.count == 1)
        #expect(model.quotaState(for: .claude).value == snapshot)
    }

    @Test("independent refresh errors retain each lane's last good value")
    @MainActor
    func retainsLastGoodValues() async {
        let quota = TestFixtures.quota(usedPercent: 25)
        let activity = TestFixtures.activity()
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([.success(quota), .failure(.failed)]),
            activityService: QueueActivityProvider([.success(activity), .failure(.failed)]),
            cache: nil)

        await model.refreshAll()
        await model.refreshAll()

        #expect(model.quota.value == quota)
        #expect(model.activity.value == activity)
        #expect(model.quota.errorMessage != nil)
        #expect(model.activity.errorMessage != nil)
        #expect(!model.quota.isRefreshing)
        #expect(!model.activity.isRefreshing)
    }

    @Test("quota refresh records and persists daily weekly usage")
    @MainActor
    func recordsDailyWeeklyUsage() async {
        let windowStart = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = windowStart.addingTimeInterval(7 * 86_400)
        let latestSampleAt = windowStart.addingTimeInterval(2 * 86_400 + 300)
        func quota(usedPercent: Double, offset: TimeInterval) -> QuotaSnapshot {
            QuotaSnapshot(
                session: nil,
                weekly: QuotaWindowSnapshot(
                    usedPercent: usedPercent,
                    windowMinutes: 10_080,
                    resetsAt: reset),
                resetCredits: nil,
                updatedAt: windowStart.addingTimeInterval(offset))
        }
        let usageCache = MemoryWeeklyQuotaUsageCache()
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([
                .success(quota(usedPercent: 32, offset: 2 * 86_400)),
                .success(quota(usedPercent: 39, offset: 2 * 86_400 + 300)),
            ]),
            activityService: QueueActivityProvider([]),
            cache: nil,
            weeklyQuotaUsageCache: usageCache,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { latestSampleAt })

        await model.refreshQuota()
        await model.refreshQuota()

        #expect(model.weeklyQuotaUsage(for: .codex)?.usage(
            at: latestSampleAt,
            statisticsTimeZone: .utc)?.usedPercentagePoints == 7)
        #expect(model.weeklyQuotaUsageToday(for: .codex)?.usedPercentagePoints == 7)
        #expect(await usageCache.histories[.codex] == model.weeklyQuotaUsage(for: .codex))
    }

    @Test("missing reset metadata does not inherit an expired reset date")
    @MainActor
    func rejectsExpiredInheritedReset() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = self.quota(
            reset: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-600))
        let desktopSample = QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: 4,
                windowMinutes: 10_080,
                resetsAt: nil),
            resetCredits: nil,
            updatedAt: now,
            origin: .claudeDesktop)
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([.success(previous), .success(desktopSample)]),
            activityService: QueueActivityProvider([]),
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { now })

        await model.refreshQuota()
        await model.refreshQuota()

        #expect(model.quota.value?.weekly?.usedPercent == 4)
        #expect(model.quota.value?.weekly?.resetsAt == nil)
        #expect(model.quota.value?.origin == .claudeDesktop)
    }

    @Test("missing reset metadata retains a compatible future reset date")
    @MainActor
    func retainsCompatibleFutureReset() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(2 * 86_400)
        let previous = self.quota(reset: reset, updatedAt: now.addingTimeInterval(-600))
        let desktopSample = QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: 4,
                windowMinutes: 10_080,
                resetsAt: nil),
            resetCredits: nil,
            updatedAt: now,
            origin: .claudeDesktop)
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([.success(previous), .success(desktopSample)]),
            activityService: QueueActivityProvider([]),
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { now })

        await model.refreshQuota()
        await model.refreshQuota()

        #expect(model.quota.value?.weekly?.resetsAt == reset)
        #expect(model.quota.value?.origin == .claudeDesktop)
    }

    @Test("Claude weekly reset falls back to Sunday evening and reanchors on refill")
    @MainActor
    func infersClaudeWeeklyReset() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
        let firstObservedAt = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 24,
            hour: 10)))
        let refillObservedAt = firstObservedAt.addingTimeInterval(24 * 60 * 60)
        let expectedInitialReset = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 30,
            hour: 20)))
        let provider = QueueQuotaProvider([
            .success(QuotaSnapshot(
                session: nil,
                weekly: QuotaWindowSnapshot(
                    usedPercent: 20,
                    windowMinutes: 10_080,
                    resetsAt: nil),
                resetCredits: nil,
                updatedAt: firstObservedAt,
                origin: .claudeDesktop)),
            .success(QuotaSnapshot(
                session: nil,
                weekly: QuotaWindowSnapshot(
                    usedPercent: 0,
                    windowMinutes: 10_080,
                    resetsAt: nil),
                resetCredits: nil,
                updatedAt: refillObservedAt,
                origin: .claudeDesktop)),
        ], platform: .claude)
        let quotaCache = MemoryQuotaCache()
        let model = DashboardModel(
            quotaService: provider,
            activityService: QueueActivityProvider([]),
            cache: nil,
            quotaCache: quotaCache,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { refillObservedAt },
            calendar: calendar)

        await model.refreshQuota(for: .claude)
        #expect(model.quotaState(for: .claude).value?.weekly?.resetsAt == expectedInitialReset)

        await model.refreshQuota(for: .claude)
        let reanchoredReset = refillObservedAt.addingTimeInterval(7 * 24 * 60 * 60)
        #expect(model.quotaState(for: .claude).value?.weekly?.resetsAt == reanchoredReset)
        #expect(await quotaCache.snapshots[.claude]?.weekly?.resetsAt == reanchoredReset)
    }

    @Test("Claude fallback anchor advances by whole weekly windows")
    @MainActor
    func advancesClaudeWeeklyAnchor() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredReset = now.addingTimeInterval(-6 * 24 * 60 * 60)
        let expectedReset = expiredReset.addingTimeInterval(7 * 24 * 60 * 60)
        let provider = QueueQuotaProvider([
            .success(QuotaSnapshot(
                session: nil,
                weekly: QuotaWindowSnapshot(
                    usedPercent: 20,
                    windowMinutes: 10_080,
                    resetsAt: expiredReset),
                resetCredits: nil,
                updatedAt: now.addingTimeInterval(-7 * 24 * 60 * 60),
                origin: .claudeDesktop)),
            .success(QuotaSnapshot(
                session: nil,
                weekly: QuotaWindowSnapshot(
                    usedPercent: 30,
                    windowMinutes: 10_080,
                    resetsAt: nil),
                resetCredits: nil,
                updatedAt: now,
                origin: .claudeDesktop)),
        ], platform: .claude)
        let model = DashboardModel(
            quotaService: provider,
            activityService: QueueActivityProvider([]),
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { now })

        await model.refreshQuota(for: .claude)
        await model.refreshQuota(for: .claude)

        #expect(model.quotaState(for: .claude).value?.weekly?.resetsAt == expectedReset)
    }

    @Test("refresh passes the current weekly window start to activity")
    @MainActor
    func passesWeeklyWindowStart() async {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = updatedAt.addingTimeInterval(4 * 86_400)
        let windowStart = reset.addingTimeInterval(-7 * 86_400)
        let quota = QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: 35,
                windowMinutes: 10_080,
                resetsAt: reset),
            resetCredits: nil,
            updatedAt: updatedAt)
        let activity = QueueActivityProvider([.success(TestFixtures.activity())])
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([.success(quota)]),
            activityService: activity,
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { updatedAt })

        await model.refreshAll()

        let requested = await activity.weeklyResetDates
        #expect(requested.count == 1)
        #expect(abs((requested[0]?.timeIntervalSince(windowStart)) ?? .infinity) < 0.001)
        #expect(await activity.statisticsTimeZones == [.utc])
    }

    @Test("expired weekly windows do not request stale reset activity")
    @MainActor
    func rejectsExpiredWeeklyWindow() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: 80,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(-1)),
            resetCredits: nil,
            updatedAt: now.addingTimeInterval(-300))
        let activity = QueueActivityProvider([.success(TestFixtures.activity())])
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([.success(quota)]),
            activityService: activity,
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { now })

        await model.refreshAll()

        let requested = await activity.weeklyResetDates
        #expect(requested.count == 1)
        #expect(requested[0] == nil)
    }

    @Test("startup hydrates activity cache and refreshes both sources")
    @MainActor
    func startsWithIndependentSources() async {
        let cachedActivity = TestFixtures.activity(generatedAtMs: 1)
        let quota = TestFixtures.quota(usedPercent: 40)
        let cache = MemoryActivityCache(snapshot: cachedActivity)
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([.success(quota)]),
            activityService: QueueActivityProvider([.failure(.failed)]),
            cache: cache,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(60),
            sleep: { _ in throw CancellationError() })

        await model.start()
        model.stop()

        #expect(model.quota.value == quota)
        #expect(model.activity.value == cachedActivity)
        #expect(model.activity.errorMessage != nil)
    }

    @Test("startup hydrates quota cache and retains it when a forced refresh fails")
    @MainActor
    func startsWithQuotaCache() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cachedQuota = self.quota(
            reset: now.addingTimeInterval(4 * 86_400),
            updatedAt: now)
        let quotaCache = MemoryQuotaCache(snapshots: [.codex: cachedQuota])
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([.failure(.failed)]),
            activityService: QueueActivityProvider([.success(TestFixtures.activity())]),
            cache: nil,
            quotaCache: quotaCache,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { _ in throw CancellationError() },
            now: { now })

        await model.start()
        await model.refreshQuotas()
        model.stop()

        #expect(model.quota.value == cachedQuota)
        #expect(model.quota.errorMessage != nil)
    }

    @Test("changing the background interval restarts the combined refresh timer")
    @MainActor
    func changesBackgroundInterval() async {
        let sleeps = DurationRecorder()
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([.success(TestFixtures.quota(usedPercent: 10))]),
            activityService: QueueActivityProvider([.success(TestFixtures.activity())]),
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { duration in
                await sleeps.record(duration)
                throw CancellationError()
            })

        await model.start()
        model.updateBackgroundRefreshInterval(.seconds(60))
        await Task.yield()
        model.stop()

        #expect(await sleeps.values.contains(.seconds(60)))
    }

    @Test("activity refresh uses the selected statistics timezone")
    @MainActor
    func changesStatisticsTimeZone() async {
        let activity = QueueActivityProvider([
            .success(TestFixtures.activity()),
            .success(TestFixtures.activity()),
        ])
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([]),
            activityService: activity,
            cache: nil)

        await model.refreshActivity()
        #expect(model.updateStatisticsTimeZone(.local))
        await model.refreshActivity()

        #expect(await activity.statisticsTimeZones == [.utc, .local])
    }

    @Test("changing timezone during a refresh retries with the new timezone")
    @MainActor
    func retriesWhenStatisticsTimeZoneChanges() async {
        let utcSnapshot = TestFixtures.activity(generatedAtMs: 1)
        let localSnapshot = TestFixtures.activity(generatedAtMs: 2)
        let activity = PausingActivityProvider([utcSnapshot, localSnapshot])
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([]),
            activityService: activity,
            cache: nil)

        let refresh = Task { @MainActor in
            await model.refreshActivity()
        }
        await activity.waitForFirstRequest()
        #expect(model.updateStatisticsTimeZone(.local))
        await model.refreshActivity()
        await activity.releaseFirstRequest()
        await refresh.value

        #expect(await activity.statisticsTimeZones == [.utc, .local])
        #expect(model.activity.value == localSnapshot)
    }

    @Test("restarting activity refresh prevents stale in-flight results from landing")
    @MainActor
    func restartsActivityRefresh() async {
        let stale = TestFixtures.activity(generatedAtMs: 1)
        let current = TestFixtures.activity(generatedAtMs: 2)
        let activity = PausingActivityProvider([stale, current])
        let model = DashboardModel(
            quotaService: QueueQuotaProvider([]),
            activityService: activity,
            cache: nil)

        let first = Task { @MainActor in
            await model.refreshActivity()
        }
        await activity.waitForFirstRequest()
        await model.restartActivityRefresh()
        await activity.releaseFirstRequest()
        await first.value

        #expect(model.activity.value == current)
        #expect(await activity.statisticsTimeZones.count == 2)
    }

    private func quota(reset: Date, updatedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: 30,
                windowMinutes: 10_080,
                resetsAt: reset),
            resetCredits: nil,
            updatedAt: updatedAt)
    }
}

private actor DurationRecorder {
    private(set) var values: [Duration] = []

    func record(_ value: Duration) {
        self.values.append(value)
    }
}
