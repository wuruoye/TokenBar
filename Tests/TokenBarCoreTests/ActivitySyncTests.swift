import Foundation
import Testing
@testable import TokenBarCore

private actor RecordingSyncNetwork: ActivitySyncNetworking {
    enum Failure: Error {
        case upload
        case download
    }

    private(set) var uploaded: [ActivitySyncUploadEnvelope] = []
    var response: ActivitySyncDownloadResponse
    var failsUpload = false
    var failsDownload = false

    init(response: ActivitySyncDownloadResponse) {
        self.response = response
    }

    func upload(
        _ envelope: ActivitySyncUploadEnvelope,
        configuration _: ActivitySyncConfiguration) async throws
    {
        if self.failsUpload { throw Failure.upload }
        self.uploaded.append(envelope)
    }

    func download(
        configuration _: ActivitySyncConfiguration) async throws -> ActivitySyncDownloadResponse
    {
        if self.failsDownload { throw Failure.download }
        return self.response
    }

    func setFailures(upload: Bool, download: Bool) {
        self.failsUpload = upload
        self.failsDownload = download
    }
}

private actor RecordingSyncReports {
    private(set) var values: [ActivitySyncReport] = []

    func append(_ report: ActivitySyncReport) {
        self.values.append(report)
    }
}

private actor CancellingSyncNetwork: ActivitySyncNetworking {
    private(set) var downloadCount = 0

    func upload(
        _: ActivitySyncUploadEnvelope,
        configuration _: ActivitySyncConfiguration) async throws
    {
        throw CancellationError()
    }

    func download(
        configuration _: ActivitySyncConfiguration) async throws -> ActivitySyncDownloadResponse
    {
        self.downloadCount += 1
        return ActivitySyncDownloadResponse(snapshots: [])
    }
}

private struct StaticActivityProvider: ActivityProviding {
    let snapshot: ActivitySnapshot

    func fetchActivity(
        sinceWeeklyResetAt _: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.snapshot
    }

    func fetchActivity(
        sinceWeeklyResetAtByPlatform _: [TokenPlatform: Date],
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.snapshot
    }
}

private actor RecordingHTTPTransport: TokenBarHTTPTransport {
    private var responses: [TokenBarHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [TokenBarHTTPResponse]) {
        self.responses = responses
    }

    func response(for request: URLRequest) async throws -> TokenBarHTTPResponse {
        self.requests.append(request)
        return self.responses.removeFirst()
    }
}

@Suite("Multi-device activity sync")
struct ActivitySyncTests {
    private let sharedToken = String(repeating: "s", count: 32)
    private let localDevice = ActivitySyncDevice(
        id: "11111111-1111-4111-8111-111111111111",
        name: "Mac Studio",
        os: .macos,
        clientVersion: "1")
    private let remoteDevice = ActivitySyncDevice(
        id: "22222222-2222-4222-8222-222222222222",
        name: "Windows PC",
        os: .windows,
        clientVersion: "1")

    @Test("sync redaction removes content and paths recursively")
    func redactsSensitiveFields() throws {
        let contribution = RequestSummary(
            id: "physical",
            sessionId: "session",
            physicalSessionId: "physical-session",
            isSubagent: true,
            agent: "worker",
            model: "gpt-test",
            provider: "openai",
            startedAtMs: 1,
            endedAtMs: 2,
            durationMs: 1,
            tokens: .zero,
            costUsd: 0,
            costSource: .estimated,
            promptPreview: "nested prompt",
            outputPreview: "nested output",
            sessionPath: "/private/nested.jsonl")
        let snapshot = TestFixtures.activity(
            promptPreview: "private prompt",
            outputPreview: "private output",
            sessionPath: "/private/session.jsonl",
            sessionTitle: "private title",
            requestContributions: [contribution])

        let redacted = snapshot.redactedForSync()
        let session = try #require(redacted.sessions.first)
        let request = try #require(session.requests.first)
        let nested = try #require(request.contributions?.first)

        #expect(session.title == nil)
        #expect(session.workspacePath == nil)
        #expect(session.workspaceLabel == nil)
        #expect(request.promptPreview == nil)
        #expect(request.outputPreview == nil)
        #expect(request.sessionPath == nil)
        #expect(nested.promptPreview == nil)
        #expect(nested.outputPreview == nil)
        #expect(nested.sessionPath == nil)
    }

    @Test("configuration requires HTTPS except on loopback")
    func validatesServerURL() throws {
        let https = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com/base/",
            token: self.sharedToken,
            device: self.localDevice)
        let localhost = try ActivitySyncConfiguration.parse(
            serverURL: "http://127.0.0.1:18765",
            token: self.sharedToken,
            device: self.localDevice)

        #expect(https.serverURL.absoluteString == "https://sync.example.com/base")
        #expect(localhost.serverURL.absoluteString == "http://127.0.0.1:18765")
        #expect(throws: ActivitySyncConfigurationError.insecureServerURL) {
            _ = try ActivitySyncConfiguration.parse(
                serverURL: "http://sync.example.com",
                token: self.sharedToken,
                device: self.localDevice)
        }
        #expect(throws: ActivitySyncConfigurationError.missingToken) {
            _ = try ActivitySyncConfiguration.parse(
                serverURL: "https://sync.example.com",
                token: " ",
                device: self.localDevice)
        }
        #expect(throws: ActivitySyncConfigurationError.invalidToken) {
            _ = try ActivitySyncConfiguration.parse(
                serverURL: "https://sync.example.com",
                token: "too-short",
                device: self.localDevice)
        }
    }

    @Test("remote client sends the versioned authenticated protocol")
    func remoteClientProtocol() async throws {
        let snapshot = TestFixtures.activity().redactedForSync()
        let stored = ActivitySyncStoredSnapshot(
            device: self.localDevice,
            generatedAtMs: snapshot.generatedAtMs,
            receivedAtMs: snapshot.generatedAtMs + 1,
            snapshot: snapshot)
        let responseData = try JSONEncoder().encode(
            ActivitySyncDownloadResponse(snapshots: [stored]))
        let transport = RecordingHTTPTransport(responses: [
            TokenBarHTTPResponse(data: Data(), statusCode: 204),
            TokenBarHTTPResponse(data: responseData, statusCode: 200),
        ])
        let client = ActivitySyncRemoteClient(transport: transport)
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com/tokenbar",
            token: self.sharedToken,
            device: self.localDevice)
        let envelope = ActivitySyncUploadEnvelope(
            device: self.localDevice,
            generatedAtMs: snapshot.generatedAtMs,
            snapshot: snapshot)

        try await client.upload(envelope, configuration: configuration)
        let downloaded = try await client.download(configuration: configuration)
        let requests = await transport.requests

        #expect(downloaded.snapshots == [stored])
        #expect(requests.map { $0.httpMethod } == ["PUT", "GET"])
        #expect(requests[0].url?.path == "/tokenbar/v1/snapshots/11111111-1111-4111-8111-111111111111")
        #expect(requests[1].url?.path == "/tokenbar/v1/snapshots")
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(self.sharedToken)"
        })
        let uploaded = try JSONDecoder().decode(
            ActivitySyncUploadEnvelope.self,
            from: try #require(requests[0].httpBody))
        #expect(uploaded == envelope)
    }

    @Test("remote client rejects invalid stored snapshot metadata")
    func rejectsInvalidStoredSnapshot() async throws {
        let snapshot = TestFixtures.activity().redactedForSync()
        let responseData = try JSONEncoder().encode(ActivitySyncDownloadResponse(snapshots: [
            ActivitySyncStoredSnapshot(
                device: ActivitySyncDevice(
                    id: "not-a-uuid",
                    name: "Broken device",
                    os: .linux),
                generatedAtMs: snapshot.generatedAtMs,
                receivedAtMs: snapshot.generatedAtMs + 1,
                snapshot: snapshot),
        ]))
        let transport = RecordingHTTPTransport(responses: [
            TokenBarHTTPResponse(data: responseData, statusCode: 200),
        ])
        let client = ActivitySyncRemoteClient(transport: transport)
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com",
            token: self.sharedToken,
            device: self.localDevice)

        await #expect(throws: ActivitySyncError.self) {
            _ = try await client.download(configuration: configuration)
        }
    }

    @Test("remote client rejects duplicate device IDs")
    func rejectsDuplicateDeviceIDs() async throws {
        let snapshot = TestFixtures.activity().redactedForSync()
        let stored = ActivitySyncStoredSnapshot(
            device: self.remoteDevice,
            generatedAtMs: snapshot.generatedAtMs,
            receivedAtMs: snapshot.generatedAtMs + 1,
            snapshot: snapshot)
        let responseData = try JSONEncoder().encode(
            ActivitySyncDownloadResponse(snapshots: [stored, stored]))
        let client = ActivitySyncRemoteClient(
            transport: RecordingHTTPTransport(responses: [
                TokenBarHTTPResponse(data: responseData, statusCode: 200),
            ]))
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com",
            token: self.sharedToken,
            device: self.localDevice)

        await #expect(throws: ActivitySyncError.self) {
            _ = try await client.download(configuration: configuration)
        }
    }

    @Test("remote client re-redacts legacy workspace labels")
    func redactsLegacyWorkspaceLabels() async throws {
        let legacy = TestFixtures.activity()
        let stored = ActivitySyncStoredSnapshot(
            device: self.remoteDevice,
            generatedAtMs: legacy.generatedAtMs,
            receivedAtMs: legacy.generatedAtMs + 1,
            snapshot: legacy)
        let responseData = try JSONEncoder().encode(
            ActivitySyncDownloadResponse(snapshots: [stored]))
        let client = ActivitySyncRemoteClient(
            transport: RecordingHTTPTransport(responses: [
                TokenBarHTTPResponse(data: responseData, statusCode: 200),
            ]))
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com",
            token: self.sharedToken,
            device: self.localDevice)

        let response = try await client.download(configuration: configuration)

        #expect(response.snapshots.first?.snapshot.sessions.first?.workspaceLabel == nil)
    }

    @Test("remote client rejects negative aggregate counts")
    func rejectsNegativeCounts() async throws {
        let base = TestFixtures.activity().redactedForSync()
        let invalid = ActivitySnapshot(
            schemaVersion: base.schemaVersion,
            generatedAtMs: base.generatedAtMs,
            timezone: base.timezone,
            today: ActivityTotals(
                tokens: base.today.tokens,
                costUsd: base.today.costUsd,
                requestCount: -1,
                sessionCount: 1),
            sessions: base.sessions,
            days: base.days)
        let responseData = try JSONEncoder().encode(ActivitySyncDownloadResponse(snapshots: [
            ActivitySyncStoredSnapshot(
                device: self.remoteDevice,
                generatedAtMs: invalid.generatedAtMs,
                receivedAtMs: invalid.generatedAtMs + 1,
                snapshot: invalid),
        ]))
        let client = ActivitySyncRemoteClient(
            transport: RecordingHTTPTransport(responses: [
                TokenBarHTTPResponse(data: responseData, statusCode: 200),
            ]))
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com",
            token: self.sharedToken,
            device: self.localDevice)

        await #expect(throws: ActivitySyncError.self) {
            _ = try await client.download(configuration: configuration)
        }
    }

    @Test("merger replaces the local server echo and sums remote devices")
    func mergesDevices() throws {
        let local = TestFixtures.activity(
            promptPreview: "local prompt",
            sessionTitle: "local title",
            rangeTotals: TestFixtures.activity().today)
        let remoteBase = TestFixtures.activity(
            promptPreview: "must be removed",
            sessionTitle: "must be removed",
            rangeTotals: TestFixtures.activity().today)
        let remote = ActivitySnapshot(
            schemaVersion: remoteBase.schemaVersion - 1,
            generatedAtMs: remoteBase.generatedAtMs,
            timezone: remoteBase.timezone,
            today: remoteBase.today,
            sessions: remoteBase.sessions,
            days: remoteBase.days,
            weeklySinceReset: remoteBase.weeklySinceReset,
            sources: remoteBase.sources,
            rangeTotals: remoteBase.rangeTotals,
            memoryUsage: remoteBase.memoryUsage).redactedForSync()
        let localEcho = ActivitySyncStoredSnapshot(
            device: self.localDevice,
            generatedAtMs: local.generatedAtMs - 10,
            receivedAtMs: local.generatedAtMs,
            snapshot: local.redactedForSync())
        let remoteRecord = ActivitySyncStoredSnapshot(
            device: self.remoteDevice,
            generatedAtMs: remote.generatedAtMs,
            receivedAtMs: remote.generatedAtMs + 1,
            snapshot: remote)

        let merged = ActivitySnapshotMerger.merge(
            local: local,
            localDevice: self.localDevice,
            remote: [localEcho, remoteRecord])

        #expect(merged.today.tokens.total == local.today.tokens.total * 2)
        #expect(merged.today.requestCount == 2)
        #expect(merged.rangeTotals?.tokens.total == local.today.tokens.total * 2)
        #expect(merged.sessions.count == 2)
        #expect(merged.sessions.contains { $0.title == "local title" })
        let remoteSession = try #require(merged.sessions.first {
            $0.id.hasPrefix("sync:\(self.remoteDevice.id):")
        })
        #expect(remoteSession.isSynchronizedRemote)
        #expect(remoteSession.synchronizedDeviceID == self.remoteDevice.id)
        #expect(remoteSession.title == nil)
        #expect(remoteSession.workspacePath == nil)
        #expect(remoteSession.workspaceLabel == "Windows PC")
        let remoteRequest = try #require(remoteSession.requests.first)
        #expect(remoteRequest.isSynchronizedRemote)
        #expect(remoteRequest.synchronizedDeviceID == self.remoteDevice.id)
        #expect(remoteRequest.promptPreview == nil)
    }

    @Test("stale device snapshots are excluded from the merged calendar")
    func excludesStaleSnapshot() {
        let local = TestFixtures.activity()
        let staleBase = TestFixtures.activity(generatedAtMs: local.generatedAtMs - 86_400_000)
        let stale = ActivitySnapshot(
            schemaVersion: staleBase.schemaVersion,
            generatedAtMs: staleBase.generatedAtMs,
            timezone: staleBase.timezone,
            today: staleBase.today,
            sessions: staleBase.sessions,
            days: [DailySummary(
                date: "2024-07-02",
                tokens: staleBase.today.tokens,
                costUsd: staleBase.today.costUsd,
                requestCount: 1,
                sessionCount: 1)])
        let record = ActivitySyncStoredSnapshot(
            device: self.remoteDevice,
            generatedAtMs: stale.generatedAtMs,
            receivedAtMs: local.generatedAtMs,
            snapshot: stale)

        let merged = ActivitySnapshotMerger.merge(
            local: local,
            localDevice: self.localDevice,
            remote: [record])

        #expect(merged.today == local.today)
        #expect(merged.sessions.count == local.sessions.count)
        #expect(merged.days == local.days)
    }

    @Test("range merge preserves per-device token costs, speed, and unique counts")
    func preservesExactRangeTotals() throws {
        let base = TestFixtures.activity()
        let range = ActivityTotals(
            tokens: base.today.tokens,
            costUsd: base.today.costUsd,
            requestCount: Int.max,
            sessionCount: 1,
            tokenCosts: base.today.tokenCosts,
            averageGenerationTokensPerSecond: 6)
        let local = ActivitySnapshot(
            schemaVersion: base.schemaVersion,
            generatedAtMs: base.generatedAtMs,
            timezone: base.timezone,
            today: base.today,
            sessions: base.sessions,
            days: base.days,
            rangeTotals: range)
        let remote = ActivitySnapshot(
            schemaVersion: base.schemaVersion,
            generatedAtMs: base.generatedAtMs,
            timezone: base.timezone,
            today: base.today,
            sessions: base.sessions,
            days: base.days,
            rangeTotals: range).redactedForSync()

        let merged = ActivitySnapshotMerger.merge(
            local: local,
            localDevice: self.localDevice,
            remote: [ActivitySyncStoredSnapshot(
                device: self.remoteDevice,
                generatedAtMs: remote.generatedAtMs,
                receivedAtMs: remote.generatedAtMs + 1,
                snapshot: remote)])

        #expect(merged.rangeTotals?.requestCount == Int.max)
        #expect(merged.rangeTotals?.sessionCount == 2)
        #expect(merged.rangeTotals?.tokenCosts?.input == (range.tokenCosts?.input ?? 0) * 2)
        #expect(merged.rangeTotals?.averageGenerationTokensPerSecond == 6)
    }

    @Test("synchronized provider uploads redacted data and returns the merged snapshot")
    func synchronizedProvider() async throws {
        let local = TestFixtures.activity(
            promptPreview: "private",
            sessionTitle: "private title")
        let remote = local.redactedForSync()
        let network = RecordingSyncNetwork(response: ActivitySyncDownloadResponse(snapshots: [
            ActivitySyncStoredSnapshot(
                device: self.remoteDevice,
                generatedAtMs: remote.generatedAtMs,
                receivedAtMs: remote.generatedAtMs + 1,
                snapshot: remote),
        ]))
        let reports = RecordingSyncReports()
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com",
            token: self.sharedToken,
            device: self.localDevice)
        let service = SynchronizedActivityService(
            local: StaticActivityProvider(snapshot: local),
            networking: network,
            configuration: { configuration },
            report: { await reports.append($0) })

        let result = try await service.fetchActivity()
        let uploaded = try #require(await network.uploaded.first)
        let values = await reports.values

        #expect(result.today.tokens.total == local.today.tokens.total * 2)
        #expect(uploaded.snapshot.sessions.first?.title == nil)
        #expect(uploaded.snapshot.sessions.first?.requests.first?.promptPreview == nil)
        #expect(values.first?.phase == .syncing)
        #expect(values.last?.phase == .success)
        #expect(values.last?.deviceCount == 2)
    }

    @Test("synchronization failures preserve local activity")
    func failuresPreserveLocal() async throws {
        let local = TestFixtures.activity(promptPreview: "local remains available")
        let network = RecordingSyncNetwork(
            response: ActivitySyncDownloadResponse(snapshots: []))
        await network.setFailures(upload: true, download: true)
        let reports = RecordingSyncReports()
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com",
            token: self.sharedToken,
            device: self.localDevice)
        let service = SynchronizedActivityService(
            local: StaticActivityProvider(snapshot: local),
            networking: network,
            configuration: { configuration },
            report: { await reports.append($0) })

        let result = try await service.fetchActivity()

        #expect(result == local)
        #expect(await reports.values.last?.phase == .failure)
    }

    @Test("timezone mismatches are excluded and reported")
    func reportsTimezoneMismatch() async throws {
        let local = TestFixtures.activity()
        let remote = ActivitySnapshot(
            schemaVersion: local.schemaVersion,
            generatedAtMs: local.generatedAtMs,
            timezone: "Asia/Shanghai",
            today: local.today,
            sessions: local.sessions,
            days: local.days)
            .redactedForSync()
        let network = RecordingSyncNetwork(response: ActivitySyncDownloadResponse(snapshots: [
            ActivitySyncStoredSnapshot(
                device: self.remoteDevice,
                generatedAtMs: remote.generatedAtMs,
                receivedAtMs: remote.generatedAtMs + 1,
                snapshot: remote),
        ]))
        let reports = RecordingSyncReports()
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com",
            token: self.sharedToken,
            device: self.localDevice)
        let service = SynchronizedActivityService(
            local: StaticActivityProvider(snapshot: local),
            networking: network,
            configuration: { configuration },
            report: { await reports.append($0) })

        let result = try await service.fetchActivity()
        let report = try #require(await reports.values.last)

        #expect(result == local)
        #expect(report.phase == .partial)
        #expect(report.deviceCount == 1)
        #expect(report.message?.contains("different statistics timezone") == true)
    }

    @Test("cancellation preserves local activity and clears syncing state")
    func cancellationPreservesLocal() async throws {
        let local = TestFixtures.activity()
        let network = CancellingSyncNetwork()
        let reports = RecordingSyncReports()
        let configuration = try ActivitySyncConfiguration.parse(
            serverURL: "https://sync.example.com",
            token: self.sharedToken,
            device: self.localDevice)
        let service = SynchronizedActivityService(
            local: StaticActivityProvider(snapshot: local),
            networking: network,
            configuration: { configuration },
            report: { await reports.append($0) })

        let result = try await service.fetchActivity()

        #expect(result == local)
        #expect(await network.downloadCount == 0)
        #expect(await reports.values.last?.phase == .ready)
    }
}
