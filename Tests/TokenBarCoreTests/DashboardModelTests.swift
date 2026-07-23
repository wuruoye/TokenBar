import Foundation
import Testing
@testable import TokenBarCore

private enum StubFailure: Error {
    case failed
}

private actor QueueQuotaProvider: QuotaProviding {
    private var results: [Result<QuotaSnapshot, StubFailure>]

    init(_ results: [Result<QuotaSnapshot, StubFailure>]) {
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

@Suite("DashboardModel")
struct DashboardModelTests {
    @Test("background refresh defaults to five minutes for both data sources")
    @MainActor
    func defaultBackgroundRefreshInterval() {
        #expect(DashboardModel.defaultQuotaRefreshInterval == .seconds(300))
        #expect(DashboardModel.defaultActivityRefreshInterval == .seconds(300))
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
}

private actor DurationRecorder {
    private(set) var values: [Duration] = []

    func record(_ value: Duration) {
        self.values.append(value)
    }
}
