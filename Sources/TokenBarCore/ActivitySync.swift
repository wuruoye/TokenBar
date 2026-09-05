import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import Security

public enum ActivitySyncDeviceOS: String, Codable, CaseIterable, Sendable {
    case macos
    case windows
    case linux
}

public struct ActivitySyncDevice: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let os: ActivitySyncDeviceOS
    public let clientVersion: String?

    public init(
        id: String,
        name: String,
        os: ActivitySyncDeviceOS,
        clientVersion: String? = nil)
    {
        self.id = id
        self.name = name
        self.os = os
        self.clientVersion = clientVersion
    }
}

public struct ActivitySyncUploadEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let device: ActivitySyncDevice
    public let generatedAtMs: Int64
    public let snapshot: ActivitySnapshot

    public init(
        protocolVersion: Int = 1,
        device: ActivitySyncDevice,
        generatedAtMs: Int64,
        snapshot: ActivitySnapshot)
    {
        self.protocolVersion = protocolVersion
        self.device = device
        self.generatedAtMs = generatedAtMs
        self.snapshot = snapshot
    }
}

public struct ActivitySyncStoredSnapshot: Codable, Equatable, Sendable {
    public let device: ActivitySyncDevice
    public let generatedAtMs: Int64
    public let receivedAtMs: Int64
    public let snapshot: ActivitySnapshot

    public init(
        device: ActivitySyncDevice,
        generatedAtMs: Int64,
        receivedAtMs: Int64,
        snapshot: ActivitySnapshot)
    {
        self.device = device
        self.generatedAtMs = generatedAtMs
        self.receivedAtMs = receivedAtMs
        self.snapshot = snapshot
    }
}

public struct ActivitySyncDownloadResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let snapshots: [ActivitySyncStoredSnapshot]

    public init(protocolVersion: Int = 1, snapshots: [ActivitySyncStoredSnapshot]) {
        self.protocolVersion = protocolVersion
        self.snapshots = snapshots
    }
}

public enum ActivitySyncConfigurationError: LocalizedError, Equatable, Sendable {
    case missingServerURL
    case invalidServerURL
    case insecureServerURL
    case missingToken
    case invalidToken
    case invalidDeviceID
    case invalidDeviceName

    public var errorDescription: String? {
        switch self {
        case .missingServerURL:
            "Enter the sync server URL."
        case .invalidServerURL:
            "The sync server URL is invalid."
        case .insecureServerURL:
            "The sync server must use HTTPS. HTTP is allowed only for localhost testing."
        case .missingToken:
            "Enter this device's sync access token."
        case .invalidToken:
            "The sync access token must contain 32 to 512 non-whitespace ASCII characters."
        case .invalidDeviceID:
            "The device ID is invalid."
        case .invalidDeviceName:
            "The device name must contain 1 to 80 characters."
        }
    }
}

public struct ActivitySyncConfiguration: Equatable, Sendable {
    public let serverURL: URL
    public let token: String
    public let device: ActivitySyncDevice

    public init(serverURL: URL, token: String, device: ActivitySyncDevice) throws {
        guard UUID(uuidString: device.id) != nil else {
            throw ActivitySyncConfigurationError.invalidDeviceID
        }
        let deviceName = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceName.isEmpty,
              deviceName.count <= 80,
              !deviceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ActivitySyncConfigurationError.invalidDeviceName
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ActivitySyncConfigurationError.missingToken
        }
        guard (32 ... 512).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({ (33 ... 126).contains(Int($0.value)) })
        else {
            throw ActivitySyncConfigurationError.invalidToken
        }
        self.serverURL = try Self.validate(serverURL: serverURL)
        self.token = token
        self.device = ActivitySyncDevice(
            id: device.id.lowercased(),
            name: deviceName,
            os: device.os,
            clientVersion: device.clientVersion)
    }

    public static func parse(
        serverURL rawServerURL: String,
        token: String,
        device: ActivitySyncDevice) throws -> ActivitySyncConfiguration
    {
        let value = rawServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ActivitySyncConfigurationError.missingServerURL
        }
        guard let url = URL(string: value) else {
            throw ActivitySyncConfigurationError.invalidServerURL
        }
        return try ActivitySyncConfiguration(serverURL: url, token: token, device: device)
    }

    private static func validate(serverURL: URL) throws -> URL {
        guard let components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              scheme == "https" || scheme == "http"
        else {
            throw ActivitySyncConfigurationError.invalidServerURL
        }
        let loopbackHosts = Set(["localhost", "127.0.0.1", "::1"])
        guard scheme == "https" || loopbackHosts.contains(host) else {
            throw ActivitySyncConfigurationError.insecureServerURL
        }
        var normalized = components
        while normalized.path.count > 1, normalized.path.hasSuffix("/") {
            normalized.path.removeLast()
        }
        guard let result = normalized.url else {
            throw ActivitySyncConfigurationError.invalidServerURL
        }
        return result
    }
}

public enum ActivitySyncError: LocalizedError, Equatable, Sendable {
    case invalidProtocolVersion(Int)
    case requestTooLarge
    case responseTooLarge
    case unauthorized
    case staleSnapshot
    case server(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidProtocolVersion(version):
            "Unsupported sync protocol version \(version)."
        case .requestTooLarge:
            "The activity snapshot exceeds the 16 MiB upload limit."
        case .responseTooLarge:
            "The sync server response is too large."
        case .unauthorized:
            "The sync server rejected the shared token."
        case .staleSnapshot:
            "The server already has a newer snapshot for this device."
        case let .server(status):
            "The sync server returned HTTP \(status)."
        case let .invalidResponse(message):
            "The sync server returned invalid data: \(message)"
        }
    }
}

public protocol ActivitySyncNetworking: Sendable {
    func upload(
        _ envelope: ActivitySyncUploadEnvelope,
        configuration: ActivitySyncConfiguration) async throws

    func download(
        configuration: ActivitySyncConfiguration) async throws -> ActivitySyncDownloadResponse
}

public struct ActivitySyncRemoteClient: ActivitySyncNetworking, Sendable {
    static let maximumUploadBytes = 16 * 1024 * 1024
    static let maximumDownloadBytes = 64 * 1024 * 1024

    let transport: any TokenBarHTTPTransport
    let timeout: TimeInterval
    let incrementalStore: ActivitySyncIncrementalStore

    public init(timeout: TimeInterval = 15) {
        self.init(
            transport: EphemeralHTTPTransport(
                allowsSameOriginRedirects: false,
                bypassesProxy: true),
            timeout: timeout,
            incrementalStore: ActivitySyncIncrementalStore())
    }

    init(
        transport: any TokenBarHTTPTransport,
        timeout: TimeInterval = 15,
        incrementalStore: ActivitySyncIncrementalStore = ActivitySyncIncrementalStore())
    {
        self.transport = transport
        self.timeout = timeout
        self.incrementalStore = incrementalStore
    }

    public func upload(
        _ envelope: ActivitySyncUploadEnvelope,
        configuration: ActivitySyncConfiguration) async throws
    {
        guard envelope.protocolVersion == 1 else {
            throw ActivitySyncError.invalidProtocolVersion(envelope.protocolVersion)
        }
        guard envelope.device.id.caseInsensitiveCompare(configuration.device.id) == .orderedSame else {
            throw ActivitySyncError.invalidResponse("the upload device does not match the configured device")
        }
        try Self.validate(
            device: envelope.device,
            generatedAtMs: envelope.generatedAtMs,
            receivedAtMs: nil,
            snapshot: envelope.snapshot)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(envelope)
        } catch {
            throw ActivitySyncError.invalidResponse(error.localizedDescription)
        }
        guard data.count <= Self.maximumUploadBytes else {
            throw ActivitySyncError.requestTooLarge
        }
        let url = Self.endpoint(
            baseURL: configuration.serverURL,
            components: ["v1", "snapshots", configuration.device.id])
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: self.timeout)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")

        let response = try await self.perform(request, maximumBodyBytes: 64 * 1024)
        switch response.statusCode {
        case 200 ... 299:
            return
        case 401, 403:
            throw ActivitySyncError.unauthorized
        case 409:
            throw ActivitySyncError.staleSnapshot
        default:
            throw ActivitySyncError.server(response.statusCode)
        }
    }

    public func download(
        configuration: ActivitySyncConfiguration) async throws -> ActivitySyncDownloadResponse
    {
        let url = Self.endpoint(
            baseURL: configuration.serverURL,
            components: ["v1", "snapshots"])
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: self.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")

        let response = try await self.perform(
            request,
            maximumBodyBytes: Self.maximumDownloadBytes)
        switch response.statusCode {
        case 200 ... 299:
            break
        case 401, 403:
            throw ActivitySyncError.unauthorized
        default:
            throw ActivitySyncError.server(response.statusCode)
        }
        guard response.data.count <= Self.maximumDownloadBytes else {
            throw ActivitySyncError.responseTooLarge
        }
        do {
            let value = try JSONDecoder().decode(ActivitySyncDownloadResponse.self, from: response.data)
            guard value.protocolVersion == 1 else {
                throw ActivitySyncError.invalidProtocolVersion(value.protocolVersion)
            }
            var deviceIDs = Set<String>()
            var snapshots: [ActivitySyncStoredSnapshot] = []
            for record in value.snapshots {
                let sanitizedSnapshot = record.snapshot.redactedForSync()
                try Self.validate(
                    device: record.device,
                    generatedAtMs: record.generatedAtMs,
                    receivedAtMs: record.receivedAtMs,
                    snapshot: sanitizedSnapshot)
                guard deviceIDs.insert(record.device.id).inserted else {
                    throw ActivitySyncError.invalidResponse(
                        "the download contains duplicate device IDs")
                }
                snapshots.append(ActivitySyncStoredSnapshot(
                    device: record.device,
                    generatedAtMs: record.generatedAtMs,
                    receivedAtMs: record.receivedAtMs,
                    snapshot: sanitizedSnapshot))
            }
            return ActivitySyncDownloadResponse(
                protocolVersion: value.protocolVersion,
                snapshots: snapshots.sorted { $0.device.id < $1.device.id })
        } catch let error as ActivitySyncError {
            throw error
        } catch {
            throw ActivitySyncError.invalidResponse(error.localizedDescription)
        }
    }

    static func endpoint(baseURL: URL, components: [String]) -> URL {
        components.reduce(baseURL) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }

    func perform(
        _ request: URLRequest,
        maximumBodyBytes: Int) async throws -> TokenBarHTTPResponse
    {
        do {
            return try await self.transport.response(
                for: request,
                maximumBodyBytes: maximumBodyBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch TokenBarHTTPTransportError.responseTooLarge {
            throw ActivitySyncError.responseTooLarge
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    static func validate(
        device: ActivitySyncDevice,
        generatedAtMs: Int64,
        receivedAtMs: Int64?,
        snapshot: ActivitySnapshot) throws
    {
        guard let deviceID = UUID(uuidString: device.id),
              deviceID.uuidString.lowercased() == device.id
        else {
            throw ActivitySyncError.invalidResponse("a device ID is not a UUID")
        }
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ActivitySyncError.invalidResponse("a device name is invalid")
        }
        if let clientVersion = device.clientVersion {
            guard clientVersion.count <= 80,
                  !clientVersion.unicodeScalars.contains(
                    where: CharacterSet.controlCharacters.contains)
            else {
                throw ActivitySyncError.invalidResponse("a client version is invalid")
            }
        }
        guard generatedAtMs > 0,
              receivedAtMs.map({ $0 > 0 }) ?? true,
              snapshot.generatedAtMs == generatedAtMs,
              snapshot.schemaVersion > 0,
              !snapshot.timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ActivitySyncError.invalidResponse("a snapshot has invalid metadata")
        }
        guard snapshot.timezone.count <= 128,
              !snapshot.timezone.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains)
        else {
            throw ActivitySyncError.invalidResponse("a snapshot timezone is invalid")
        }
        try Self.validate(snapshot: snapshot)
    }

    private static func validate(snapshot: ActivitySnapshot) throws {
        try Self.validate(totals: snapshot.today, label: "snapshot.today")
        if let totals = snapshot.rangeTotals {
            try Self.validate(totals: totals, label: "snapshot.rangeTotals")
        }
        if let weekly = snapshot.weeklySinceReset {
            try Self.validate(range: weekly, generatedAtMs: snapshot.generatedAtMs)
        }
        var dayIDs = Set<String>()
        for day in snapshot.days {
            guard dayIDs.insert(day.date).inserted else {
                throw ActivitySyncError.invalidResponse("snapshot days contain duplicate dates")
            }
            try Self.validate(day: day)
        }
        var sessionIDs = Set<String>()
        for session in snapshot.sessions {
            let identity = "\(session.platformID.rawValue)\u{0}\(session.id)"
            guard sessionIDs.insert(identity).inserted else {
                throw ActivitySyncError.invalidResponse(
                    "snapshot sessions contain duplicate identities")
            }
            try Self.validate(session: session)
        }
        var sourcePlatforms = Set<TokenPlatform>()
        for source in snapshot.sourceSnapshots {
            guard !source.platform.rawValue.isEmpty,
                  sourcePlatforms.insert(source.platform).inserted
            else {
                throw ActivitySyncError.invalidResponse(
                    "snapshot sources contain an invalid or duplicate platform")
            }
            try Self.validate(totals: source.today, label: "source.today")
            if let totals = source.rangeTotals {
                try Self.validate(totals: totals, label: "source.rangeTotals")
            }
            if let weekly = source.weeklySinceReset {
                try Self.validate(range: weekly, generatedAtMs: snapshot.generatedAtMs)
            }
            var sourceDayIDs = Set<String>()
            for day in source.days {
                guard sourceDayIDs.insert(day.date).inserted else {
                    throw ActivitySyncError.invalidResponse(
                        "source days contain duplicate dates")
                }
                try Self.validate(day: day)
            }
        }
        if let memory = snapshot.memoryUsage {
            guard memory.collectedFromMs > 0,
                  memory.lastReceivedAtMs.map({ $0 > 0 }) ?? true,
                  memory.lastMemoryReceivedAtMs.map({ $0 > 0 }) ?? true,
                  memory.observationCount >= 0
            else {
                throw ActivitySyncError.invalidResponse("snapshot memory metadata is invalid")
            }
            try Self.validate(memory: memory.today)
            try Self.validate(memory: memory.rangeTotals)
            var memoryDayIDs = Set<String>()
            for day in memory.days {
                guard !day.date.isEmpty, memoryDayIDs.insert(day.date).inserted else {
                    throw ActivitySyncError.invalidResponse("snapshot memory day is invalid")
                }
                try Self.validate(memory: day.totals)
            }
        }
    }

    private static func validate(totals: ActivityTotals, label: String) throws {
        try Self.validate(tokens: totals.tokens, label: "\(label).tokens")
        guard Self.isNonnegativeFinite(totals.costUsd),
              totals.requestCount >= 0,
              totals.sessionCount >= 0,
              totals.averageGenerationTokensPerSecond.map(Self.isNonnegativeFinite) ?? true,
              totals.averageTimeToFirstTokenMs.map(Self.isNonnegativeFinite) ?? true,
              totals.firstTokenSampleCount.map({ $0 >= 0 }) ?? true,
              Self.hasConsistentFirstTokenAverage(
                  totals.averageTimeToFirstTokenMs,
                  sampleCount: totals.firstTokenSampleCount)
        else {
            throw ActivitySyncError.invalidResponse("\(label) contains invalid totals")
        }
        if let costs = totals.tokenCosts {
            let values = [costs.input, costs.output, costs.cacheRead, costs.cacheWrite, costs.reasoning]
            guard values.allSatisfy(Self.isNonnegativeFinite) else {
                throw ActivitySyncError.invalidResponse("\(label) contains invalid token costs")
            }
        }
    }

    private static func validate(tokens: TokenBreakdown, label: String) throws {
        guard [tokens.input, tokens.output, tokens.cacheRead, tokens.cacheWrite, tokens.reasoning]
            .allSatisfy({ $0 >= 0 })
        else {
            throw ActivitySyncError.invalidResponse("\(label) contains negative tokens")
        }
    }

    private static func validate(range: ActivityRangeSummary, generatedAtMs: Int64) throws {
        guard range.startedAtMs > 0, range.startedAtMs <= generatedAtMs else {
            throw ActivitySyncError.invalidResponse("snapshot range timestamp is invalid")
        }
        try Self.validate(totals: range.totals, label: "snapshot range")
    }

    private static func validate(day: DailySummary) throws {
        guard !day.date.isEmpty,
              Self.isNonnegativeFinite(day.costUsd),
              day.averageGenerationTokensPerSecond.map(Self.isNonnegativeFinite) ?? true,
              day.averageTimeToFirstTokenMs.map(Self.isNonnegativeFinite) ?? true,
              day.firstTokenSampleCount.map({ $0 >= 0 }) ?? true,
              Self.hasConsistentFirstTokenAverage(
                  day.averageTimeToFirstTokenMs,
                  sampleCount: day.firstTokenSampleCount),
              day.requestCount >= 0,
              day.sessionCount >= 0
        else {
            throw ActivitySyncError.invalidResponse("snapshot day is invalid")
        }
        try Self.validate(tokens: day.tokens, label: "snapshot day tokens")
        for model in day.models {
            guard Self.isNonnegativeFinite(model.costUsd),
                  model.requestCount >= 0,
                  model.sessionCount >= 0
            else {
                throw ActivitySyncError.invalidResponse("snapshot daily model is invalid")
            }
            try Self.validate(tokens: model.tokens, label: "snapshot daily model tokens")
        }
    }

    private static func validate(session: SessionSummary) throws {
        guard !session.id.isEmpty,
              session.startedAtMs > 0,
              session.endedAtMs >= session.startedAtMs,
              Self.isNonnegativeFinite(session.costUsd),
              session.title.map(isValidActivitySyncSessionTitle) ?? true,
              session.workspacePath == nil,
              session.workspaceLabel == nil
        else {
            throw ActivitySyncError.invalidResponse("snapshot session is invalid or not redacted")
        }
        try Self.validate(tokens: session.tokens, label: "snapshot session tokens")
        for request in session.requests {
            try Self.validate(request: request, depth: 0)
        }
    }

    private static func validate(request: RequestSummary, depth: Int) throws {
        guard depth <= 100,
              !request.id.isEmpty,
              !request.sessionId.isEmpty,
              !request.physicalSessionId.isEmpty,
              request.startedAtMs > 0,
              request.endedAtMs >= request.startedAtMs,
              request.durationMs.map({ $0 >= 0 }) ?? true,
              request.modelDurationMs.map({ $0 >= 0 }) ?? true,
              request.timeToFirstTokenMs.map({ $0 >= 0 }) ?? true,
              Self.isNonnegativeFinite(request.costUsd),
              request.promptPreview == nil,
              request.outputPreview == nil,
              request.sessionPath == nil
        else {
            throw ActivitySyncError.invalidResponse("snapshot request is invalid or not redacted")
        }
        try Self.validate(tokens: request.tokens, label: "snapshot request tokens")
        for contribution in request.contributions ?? [] {
            try Self.validate(request: contribution, depth: depth + 1)
        }
    }

    private static func validate(memory: MemoryUsageTotals) throws {
        for phase in [memory.phase1, memory.phase2] {
            guard [
                phase.total,
                phase.input,
                phase.cachedInput,
                phase.cacheWriteInput,
                phase.output,
                phase.reasoningOutput,
            ].allSatisfy({ $0 >= 0 }) else {
                throw ActivitySyncError.invalidResponse("snapshot memory totals are invalid")
            }
        }
    }

    private static func isNonnegativeFinite(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    private static func hasConsistentFirstTokenAverage(
        _ average: Double?,
        sampleCount: Int?) -> Bool
    {
        if average == nil {
            return sampleCount == nil || sampleCount == 0
        }
        return sampleCount.map { $0 > 0 } ?? false
    }
}

public enum ActivitySyncPhase: String, Equatable, Sendable {
    case disabled
    case ready
    case syncing
    case success
    case partial
    case failure
}

public struct ActivitySyncReport: Equatable, Sendable {
    public let phase: ActivitySyncPhase
    public let attemptedAt: Date?
    public let succeededAt: Date?
    public let deviceCount: Int
    public let message: String?

    public init(
        phase: ActivitySyncPhase,
        attemptedAt: Date? = nil,
        succeededAt: Date? = nil,
        deviceCount: Int = 0,
        message: String? = nil)
    {
        self.phase = phase
        self.attemptedAt = attemptedAt
        self.succeededAt = succeededAt
        self.deviceCount = deviceCount
        self.message = message
    }

    public static let disabled = ActivitySyncReport(phase: .disabled)
    public static let ready = ActivitySyncReport(phase: .ready)
}

public struct SynchronizedActivityService: ActivityProviding, Sendable {
    private let local: any ActivityProviding
    private let networking: any ActivitySyncNetworking
    private let configuration: @Sendable () async -> ActivitySyncConfiguration?
    private let report: @Sendable (ActivitySyncReport) async -> Void
    private let now: @Sendable () -> Date

    public init(
        local: any ActivityProviding,
        networking: any ActivitySyncNetworking = ActivitySyncRemoteClient(),
        configuration: @escaping @Sendable () async -> ActivitySyncConfiguration?,
        report: @escaping @Sendable (ActivitySyncReport) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.local = local
        self.networking = networking
        self.configuration = configuration
        self.report = report
        self.now = now
    }

    public func fetchActivity(
        sinceWeeklyResetAt: Date?,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        let local = try await self.local.fetchActivity(
            sinceWeeklyResetAt: sinceWeeklyResetAt,
            statisticsTimeZone: statisticsTimeZone)
        return await self.synchronize(local)
    }

    public func fetchActivity(
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        let local = try await self.local.fetchActivity(
            sinceWeeklyResetAtByPlatform: sinceWeeklyResetAtByPlatform,
            statisticsTimeZone: statisticsTimeZone)
        return await self.synchronize(local)
    }

    public func fetchSessions(
        on date: String,
        statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> [SessionSummary]
    {
        try await self.local.fetchSessions(
            on: date,
            statisticsTimeZone: statisticsTimeZone)
    }

    private func synchronize(_ local: ActivitySnapshot) async -> ActivitySnapshot {
        guard let configuration = await self.configuration() else {
            return local
        }
        let attemptedAt = self.now()
        await self.report(ActivitySyncReport(phase: .syncing, attemptedAt: attemptedAt))
        let envelope = ActivitySyncUploadEnvelope(
            device: configuration.device,
            generatedAtMs: local.generatedAtMs,
            snapshot: local.redactedForSync())
        if let incremental = self.networking as? any ActivitySyncIncrementalNetworking {
            do {
                let outcome = try await incremental.synchronizeIncrementally(
                    envelope,
                    configuration: configuration)
                guard await self.configuration() == configuration else {
                    return local
                }
                guard let response = outcome.response else {
                    let messages = [
                        outcome.uploadErrorDescription,
                        outcome.downloadErrorDescription,
                    ].compactMap { $0 }.filter { !$0.isEmpty }
                    await self.report(ActivitySyncReport(
                        phase: outcome.uploadErrorDescription == nil ? .partial : .failure,
                        attemptedAt: attemptedAt,
                        succeededAt: outcome.uploadErrorDescription == nil ? self.now() : nil,
                        deviceCount: 1,
                        message: messages.isEmpty ? nil : messages.joined(separator: " ")))
                    return local
                }
                let merged = ActivitySnapshotMerger.merge(
                    local: local,
                    localDevice: configuration.device,
                    remote: response.snapshots)
                let localDeviceID = configuration.device.id.lowercased()
                let remoteDeviceIDs = Set(response.snapshots.compactMap { record -> String? in
                    let deviceID = record.device.id.lowercased()
                    return deviceID == localDeviceID ? nil : deviceID
                })
                let compatibleDeviceIDs = Set(response.snapshots.compactMap { record -> String? in
                    let deviceID = record.device.id.lowercased()
                    guard deviceID != localDeviceID,
                          record.snapshot.timezone == local.timezone
                    else {
                        return nil
                    }
                    return deviceID
                })
                let incompatibleDeviceCount = remoteDeviceIDs
                    .subtracting(compatibleDeviceIDs).count
                var messages = [
                    outcome.uploadErrorDescription,
                    outcome.downloadErrorDescription,
                ].compactMap { $0 }.filter { !$0.isEmpty }
                if incompatibleDeviceCount > 0 {
                    messages.append(
                        incompatibleDeviceCount == 1
                            ? "1 device uses a different statistics timezone."
                            : "\(incompatibleDeviceCount) devices use a different statistics timezone.")
                }
                await self.report(ActivitySyncReport(
                    phase: messages.isEmpty ? .success : .partial,
                    attemptedAt: attemptedAt,
                    succeededAt: self.now(),
                    deviceCount: compatibleDeviceIDs.count + 1,
                    message: messages.isEmpty ? nil : messages.joined(separator: " ")))
                return merged
            } catch is CancellationError {
                await self.report(.ready)
                return local
            } catch {
                await self.report(ActivitySyncReport(
                    phase: .failure,
                    attemptedAt: attemptedAt,
                    deviceCount: 1,
                    message: error.localizedDescription))
                return local
            }
        }
        var uploadError: Error?
        do {
            try await self.networking.upload(envelope, configuration: configuration)
        } catch is CancellationError {
            await self.report(.ready)
            return local
        } catch {
            uploadError = error
        }
        guard await self.configuration() == configuration else {
            return local
        }
        do {
            let response = try await self.networking.download(configuration: configuration)
            guard await self.configuration() == configuration else {
                return local
            }
            let merged = ActivitySnapshotMerger.merge(
                local: local,
                localDevice: configuration.device,
                remote: response.snapshots)
            let localDeviceID = configuration.device.id.lowercased()
            let remoteDeviceIDs = Set(response.snapshots.compactMap { record -> String? in
                let deviceID = record.device.id.lowercased()
                return deviceID == localDeviceID ? nil : deviceID
            })
            let compatibleDeviceIDs = Set(response.snapshots.compactMap { record -> String? in
                let deviceID = record.device.id.lowercased()
                guard deviceID != localDeviceID,
                      record.snapshot.timezone == local.timezone
                else {
                    return nil
                }
                return deviceID
            })
            let incompatibleDeviceCount = remoteDeviceIDs
                .subtracting(compatibleDeviceIDs).count
            var messages = [uploadError?.localizedDescription].compactMap { $0 }
            if incompatibleDeviceCount > 0 {
                messages.append(
                    incompatibleDeviceCount == 1
                        ? "1 device uses a different statistics timezone."
                        : "\(incompatibleDeviceCount) devices use a different statistics timezone.")
            }
            let succeededAt = self.now()
            await self.report(ActivitySyncReport(
                phase: messages.isEmpty ? .success : .partial,
                attemptedAt: attemptedAt,
                succeededAt: succeededAt,
                deviceCount: compatibleDeviceIDs.count + 1,
                message: messages.isEmpty ? nil : messages.joined(separator: " ")))
            return merged
        } catch is CancellationError {
            await self.report(.ready)
            return local
        } catch {
            let messages = [uploadError?.localizedDescription, error.localizedDescription]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            await self.report(ActivitySyncReport(
                phase: uploadError == nil ? .partial : .failure,
                attemptedAt: attemptedAt,
                succeededAt: uploadError == nil ? self.now() : nil,
                deviceCount: 1,
                message: messages.joined(separator: " ")))
            return local
        }
    }
}

public enum ActivitySnapshotMerger {
    public static func merge(
        local: ActivitySnapshot,
        localDevice: ActivitySyncDevice,
        remote: [ActivitySyncStoredSnapshot]) -> ActivitySnapshot
    {
        var latest: [String: ActivitySyncStoredSnapshot] = [:]
        for record in remote
            where record.generatedAtMs > 0
                && record.receivedAtMs > 0
                && record.snapshot.generatedAtMs == record.generatedAtMs
                && record.snapshot.schemaVersion > 0
                && record.snapshot.timezone == local.timezone
        {
            let deviceID = record.device.id.lowercased()
            if let existing = latest[deviceID],
               existing.generatedAtMs >= record.generatedAtMs
            {
                continue
            }
            latest[deviceID] = record
        }
        latest.removeValue(forKey: localDevice.id.lowercased())
        let candidates = [Candidate(device: localDevice, snapshot: local, isLocal: true)]
            + latest.values.map { Candidate(device: $0.device, snapshot: $0.snapshot, isLocal: false) }
        guard candidates.count > 1 else { return local }

        let allowedDates = Set(local.days.map(\.date))
        let currentDate = local.days.map(\.date).max()
        let currentCandidates = candidates.filter { candidate in
            guard let currentDate else { return candidate.isLocal }
            return candidate.snapshot.days.map(\.date).max() == currentDate
        }
        guard currentCandidates.count > 1 else { return local }
        let days = self.mergeDays(
            currentCandidates.flatMap { $0.snapshot.days },
            allowedDates: allowedDates)
        let today = self.sumTotals(currentCandidates.map { $0.snapshot.today })
        let rangeTotals = self.sumTotals(currentCandidates.map { candidate in
            let candidateDates = Set(candidate.snapshot.days.map(\.date))
            if candidateDates.isSubset(of: allowedDates),
               let totals = candidate.snapshot.rangeTotals
            {
                return totals
            }
            return self.totals(from: self.mergeDays(
                candidate.snapshot.days,
                allowedDates: allowedDates))
        })
        let weeklySinceReset = self.mergeWeekly(
            currentCandidates.compactMap { $0.snapshot.weeklySinceReset },
            targetStartMs: local.weeklySinceReset?.startedAtMs)
        let sessions = currentCandidates.flatMap { candidate in
            candidate.isLocal
                ? candidate.snapshot.sessions
                : candidate.snapshot.sessions.map {
                    self.namespaced($0, for: candidate.device)
                }
        }
        .sorted {
            if $0.endedAtMs != $1.endedAtMs { return $0.endedAtMs > $1.endedAtMs }
            return $0.platformScopedID < $1.platformScopedID
        }

        let platforms = Set(currentCandidates.flatMap {
            $0.snapshot.sourceSnapshots.map(\.platform)
        })
        let sources = platforms.sorted { $0.rawValue < $1.rawValue }.map { platform in
            let sourceCandidates = currentCandidates.compactMap { candidate -> SourceCandidate? in
                guard let source = candidate.snapshot.sourceSnapshots.first(where: {
                    $0.platform == platform
                }) else {
                    return nil
                }
                return SourceCandidate(candidate: candidate, source: source)
            }
            let sourceDays = self.mergeDays(
                sourceCandidates.flatMap { $0.source.days },
                allowedDates: allowedDates)
            let targetStart = local.sourceSnapshots
                .first(where: { $0.platform == platform })?.weeklySinceReset?.startedAtMs
            return ActivitySourceSnapshot(
                platform: platform,
                today: self.sumTotals(sourceCandidates.map { $0.source.today }),
                weeklySinceReset: self.mergeWeekly(
                    sourceCandidates.compactMap { $0.source.weeklySinceReset },
                    targetStartMs: targetStart),
                days: sourceDays,
                rangeTotals: self.sumTotals(sourceCandidates.map { sourceCandidate in
                    let candidateDates = Set(sourceCandidate.source.days.map(\.date))
                    if candidateDates.isSubset(of: allowedDates),
                       let totals = sourceCandidate.source.rangeTotals
                    {
                        return totals
                    }
                    return self.totals(from: self.mergeDays(
                        sourceCandidate.source.days,
                        allowedDates: allowedDates))
                }))
        }

        return ActivitySnapshot(
            schemaVersion: local.schemaVersion,
            generatedAtMs: local.generatedAtMs,
            timezone: local.timezone,
            today: today,
            sessions: sessions,
            days: days,
            weeklySinceReset: weeklySinceReset,
            sources: sources,
            rangeTotals: rangeTotals,
            memoryUsage: local.memoryUsage)
    }

    private struct Candidate {
        let device: ActivitySyncDevice
        let snapshot: ActivitySnapshot
        let isLocal: Bool
    }

    private struct SourceCandidate {
        let candidate: Candidate
        let source: ActivitySourceSnapshot
    }

    private struct ModelKey: Hashable {
        let platform: TokenPlatform
        let model: String
        let provider: String
    }

    private static func mergeDays(
        _ days: [DailySummary],
        allowedDates: Set<String>) -> [DailySummary]
    {
        Dictionary(grouping: days.filter { allowedDates.contains($0.date) }, by: \.date)
            .map { date, values in
                let firstToken = self.weightedAverageTimeToFirstToken(
                    values,
                    average: { $0.averageTimeToFirstTokenMs },
                    sampleCount: { $0.firstTokenSampleCount })
                let models = Dictionary(
                    grouping: values.flatMap(\.models),
                    by: {
                        ModelKey(
                            platform: $0.platform ?? .codex,
                            model: $0.model,
                            provider: $0.provider)
                    })
                    .map { key, models in
                        DailyModelSummary(
                            model: key.model,
                            provider: key.provider,
                            tokens: self.sumTokens(models.map(\.tokens)),
                            costUsd: self.sumFinite(models.map(\.costUsd)),
                            requestCount: models.reduce(0) {
                                $0.saturatingAddForSync($1.requestCount)
                            },
                            sessionCount: models.reduce(0) {
                                $0.saturatingAddForSync($1.sessionCount)
                            },
                            platform: key.platform)
                    }
                    .sorted {
                        if $0.platform?.rawValue != $1.platform?.rawValue {
                            return ($0.platform?.rawValue ?? "") < ($1.platform?.rawValue ?? "")
                        }
                        if $0.model != $1.model { return $0.model < $1.model }
                        return $0.provider < $1.provider
                    }
                return DailySummary(
                    date: date,
                    tokens: self.sumTokens(values.map(\.tokens)),
                    costUsd: self.sumFinite(values.map(\.costUsd)),
                    requestCount: values.reduce(0) {
                        $0.saturatingAddForSync($1.requestCount)
                    },
                    sessionCount: values.reduce(0) {
                        $0.saturatingAddForSync($1.sessionCount)
                    },
                    averageGenerationTokensPerSecond: self.weightedAverageGenerationTokensPerSecond(
                        values,
                        tokens: { $0.tokens },
                        rate: { $0.averageGenerationTokensPerSecond }),
                    averageTimeToFirstTokenMs: firstToken.average,
                    firstTokenSampleCount: firstToken.sampleCount,
                    models: models)
            }
            .sorted { $0.date < $1.date }
    }

    private static func mergeWeekly(
        _ ranges: [ActivityRangeSummary],
        targetStartMs: Int64?) -> ActivityRangeSummary?
    {
        guard let targetStartMs else { return nil }
        let matching = ranges.filter { $0.startedAtMs == targetStartMs }
        guard !matching.isEmpty else { return nil }
        return ActivityRangeSummary(
            startedAtMs: targetStartMs,
            totals: self.sumTotals(matching.map(\.totals)))
    }

    private static func totals(from days: [DailySummary]) -> ActivityTotals {
        let firstToken = self.weightedAverageTimeToFirstToken(
            days,
            average: { $0.averageTimeToFirstTokenMs },
            sampleCount: { $0.firstTokenSampleCount })
        return ActivityTotals(
            tokens: self.sumTokens(days.map(\.tokens)),
            costUsd: self.sumFinite(days.map(\.costUsd)),
            requestCount: days.reduce(0) { $0.saturatingAddForSync($1.requestCount) },
            sessionCount: days.reduce(0) { $0.saturatingAddForSync($1.sessionCount) },
            averageGenerationTokensPerSecond: self.weightedAverageGenerationTokensPerSecond(
                days,
                tokens: { $0.tokens },
                rate: { $0.averageGenerationTokensPerSecond }),
            averageTimeToFirstTokenMs: firstToken.average,
            firstTokenSampleCount: firstToken.sampleCount)
    }

    private static func sumTotals(_ totals: [ActivityTotals]) -> ActivityTotals {
        let tokenCosts: TokenCostBreakdown? = totals.allSatisfy { $0.tokenCosts != nil }
            ? TokenCostBreakdown(
                input: self.sumFinite(totals.compactMap(\.tokenCosts).map(\.input)),
                output: self.sumFinite(totals.compactMap(\.tokenCosts).map(\.output)),
                cacheRead: self.sumFinite(totals.compactMap(\.tokenCosts).map(\.cacheRead)),
                cacheWrite: self.sumFinite(totals.compactMap(\.tokenCosts).map(\.cacheWrite)),
                reasoning: self.sumFinite(totals.compactMap(\.tokenCosts).map(\.reasoning)))
            : nil
        let firstToken = self.weightedAverageTimeToFirstToken(
            totals,
            average: { $0.averageTimeToFirstTokenMs },
            sampleCount: { $0.firstTokenSampleCount })
        return ActivityTotals(
            tokens: self.sumTokens(totals.map(\.tokens)),
            costUsd: self.sumFinite(totals.map(\.costUsd)),
            requestCount: totals.reduce(0) { $0.saturatingAddForSync($1.requestCount) },
            sessionCount: totals.reduce(0) { $0.saturatingAddForSync($1.sessionCount) },
            tokenCosts: tokenCosts,
            averageGenerationTokensPerSecond: self.weightedAverageGenerationTokensPerSecond(
                totals,
                tokens: { $0.tokens },
                rate: { $0.averageGenerationTokensPerSecond }),
            averageTimeToFirstTokenMs: firstToken.average,
            firstTokenSampleCount: firstToken.sampleCount)
    }

    private static func weightedAverageTimeToFirstToken<Value>(
        _ values: [Value],
        average: (Value) -> Double?,
        sampleCount: (Value) -> Int?) -> (average: Double?, sampleCount: Int?)
    {
        var totalMs = 0.0
        var totalSamples = 0
        for value in values {
            guard let average = average(value),
                  let sampleCount = sampleCount(value),
                  sampleCount > 0
            else {
                continue
            }
            totalMs = totalMs.saturatingAddForSync(average * Double(sampleCount))
            totalSamples = totalSamples.saturatingAddForSync(sampleCount)
        }
        guard totalSamples > 0 else { return (nil, nil) }
        return (totalMs / Double(totalSamples), totalSamples)
    }

    private static func weightedAverageGenerationTokensPerSecond<Value>(
        _ values: [Value],
        tokens: (Value) -> TokenBreakdown,
        rate: (Value) -> Double?) -> Double?
    {
        var generatedTokens = 0.0
        var modeledSeconds = 0.0
        for value in values {
            guard let rate = rate(value), rate > 0 else { continue }
            let tokens = tokens(value)
            let count = Double(tokens.output.saturatingAddForSync(tokens.reasoning))
            generatedTokens = generatedTokens.saturatingAddForSync(count)
            modeledSeconds = modeledSeconds.saturatingAddForSync(count / rate)
        }
        return modeledSeconds > 0 ? generatedTokens / modeledSeconds : nil
    }

    private static func sumTokens(_ values: [TokenBreakdown]) -> TokenBreakdown {
        values.reduce(.zero) { result, tokens in
            TokenBreakdown(
                input: result.input.saturatingAddForSync(tokens.input),
                output: result.output.saturatingAddForSync(tokens.output),
                cacheRead: result.cacheRead.saturatingAddForSync(tokens.cacheRead),
                cacheWrite: result.cacheWrite.saturatingAddForSync(tokens.cacheWrite),
                reasoning: result.reasoning.saturatingAddForSync(tokens.reasoning))
        }
    }

    private static func sumFinite(_ values: [Double]) -> Double {
        values.reduce(0) { $0.saturatingAddForSync($1) }
    }

    private static func namespaced(
        _ session: SessionSummary,
        for device: ActivitySyncDevice) -> SessionSummary
    {
        SessionSummary(
            id: "sync:\(device.id):\(session.id)",
            workspaceLabel: device.name,
            startedAtMs: session.startedAtMs,
            endedAtMs: session.endedAtMs,
            tokens: session.tokens,
            costUsd: session.costUsd,
            models: session.models,
            requests: session.requests.map { self.namespaced($0, for: device) },
            title: session.title,
            workspacePath: nil,
            platform: session.platform)
    }

    private static func namespaced(
        _ request: RequestSummary,
        for device: ActivitySyncDevice) -> RequestSummary
    {
        RequestSummary(
            id: "sync:\(device.id):\(request.id)",
            sessionId: "sync:\(device.id):\(request.sessionId)",
            physicalSessionId: "sync:\(device.id):\(request.physicalSessionId)",
            isSubagent: request.isSubagent,
            agent: request.agent,
            model: request.model,
            provider: request.provider,
            startedAtMs: request.startedAtMs,
            endedAtMs: request.endedAtMs,
            durationMs: request.durationMs,
            modelDurationMs: request.modelDurationMs,
            timeToFirstTokenMs: request.timeToFirstTokenMs,
            tokens: request.tokens,
            costUsd: request.costUsd,
            costSource: request.costSource,
            promptPreview: nil,
            outputPreview: nil,
            sessionPath: nil,
            contributions: request.contributions?.map { self.namespaced($0, for: device) },
            serviceTier: request.serviceTier,
            reasoningEffort: request.reasoningEffort,
            platform: request.platform)
    }
}

public extension ActivitySnapshot {
    func redactedForSync() -> ActivitySnapshot {
        ActivitySnapshot(
            schemaVersion: self.schemaVersion,
            generatedAtMs: self.generatedAtMs,
            timezone: self.timezone,
            today: self.today,
            sessions: self.sessions.map { $0.redactedForSync() },
            days: self.days,
            weeklySinceReset: self.weeklySinceReset,
            sources: self.sources,
            rangeTotals: self.rangeTotals,
            memoryUsage: self.memoryUsage)
    }
}

public extension SessionSummary {
    func redactedForSync() -> SessionSummary {
        let redacted = self.redactedForCache()
        return SessionSummary(
            id: redacted.id,
            workspaceLabel: nil,
            startedAtMs: redacted.startedAtMs,
            endedAtMs: redacted.endedAtMs,
            tokens: redacted.tokens,
            costUsd: redacted.costUsd,
            models: redacted.models,
            requests: redacted.requests,
            title: sanitizedActivitySyncSessionTitle(self.title),
            workspacePath: nil,
            platform: redacted.platform)
    }

    var synchronizedDeviceID: String? {
        synchronizedDeviceIDForActivitySync(from: self.id)
    }

    var synchronizedOriginalSessionID: String? {
        synchronizedIdentityForActivitySync(from: self.id)?.originalID
    }

    var isSynchronizedRemote: Bool {
        self.synchronizedDeviceID != nil
    }
}

public extension RequestSummary {
    var synchronizedDeviceID: String? {
        synchronizedDeviceIDForActivitySync(from: self.id)
    }

    var isSynchronizedRemote: Bool {
        self.synchronizedDeviceID != nil
    }
}

public protocol ActivitySyncCredentialStoring: Sendable {
    func loadToken() throws -> String?
    func saveToken(_ token: String?) throws
}

public enum ActivitySyncCredentialError: LocalizedError, Sendable {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "Keychain operation failed (\(status))."
        }
    }
}

struct ActivitySyncKeychainAccess: Sendable {
    let load: @Sendable (_ service: String, _ account: String) throws -> Data?
    let save: @Sendable (_ data: Data, _ service: String, _ account: String) throws -> Void

    static let system = Self(
        load: { service, account in
            var query = Self.baseQuery(service: service, account: account)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw ActivitySyncCredentialError.keychain(status)
            }
            return data
        },
        save: { data, service, account in
            let query = Self.baseQuery(service: service, account: account)
            let value = [kSecValueData as String: data] as CFDictionary
            let updateStatus = SecItemUpdate(query as CFDictionary, value)
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else {
                throw ActivitySyncCredentialError.keychain(updateStatus)
            }

            var insert = query
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            if insertStatus == errSecSuccess { return }
            if insertStatus == errSecDuplicateItem,
               SecItemUpdate(query as CFDictionary, value) == errSecSuccess
            {
                return
            }
            throw ActivitySyncCredentialError.keychain(insertStatus)
        })

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct KeychainActivitySyncCredentialStore: ActivitySyncCredentialStoring, Sendable {
    private let currentService: String
    private let legacyService: String
    private let account: String
    private let keychain: ActivitySyncKeychainAccess

    public init(
        service: String = "com.wuruoye.TokenBar.activity-sync",
        account: String = "shared-token")
    {
        self.currentService = "\(service).v2"
        self.legacyService = service
        self.account = account
        self.keychain = .system
    }

    init(
        service: String,
        account: String,
        keychain: ActivitySyncKeychainAccess)
    {
        self.currentService = "\(service).v2"
        self.legacyService = service
        self.account = account
        self.keychain = keychain
    }

    public func loadToken() throws -> String? {
        if let data = try self.keychain.load(self.currentService, self.account) {
            return try Self.token(from: data)
        }

        guard let legacyData = try self.keychain.load(self.legacyService, self.account) else {
            return nil
        }
        let token = try Self.token(from: legacyData)
        try self.keychain.save(legacyData, self.currentService, self.account)
        return token
    }

    public func saveToken(_ token: String?) throws {
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try self.keychain.save(Data(value.utf8), self.currentService, self.account)
    }

    private static func token(from data: Data) throws -> String {
        guard let token = String(data: data, encoding: .utf8) else {
            throw ActivitySyncCredentialError.keychain(errSecDecode)
        }
        return token
    }
}

@MainActor
@Observable
public final class ActivitySyncController {
    public private(set) var report: ActivitySyncReport
    public private(set) var credentialMessage: String?
    public private(set) var configurationMessage: String?
    public private(set) var configurationRevision = 0
    public var token: String {
        didSet {
            guard self.token != oldValue else { return }
            self.configurationRevision &+= 1
            do {
                try self.credentials.saveToken(self.token)
                self.credentialMessage = nil
            } catch {
                self.credentialMessage = error.localizedDescription
            }
        }
    }

    private let settings: TokenBarSettings
    private let credentials: any ActivitySyncCredentialStoring
    private let clientVersion: String?

    public init(
        settings: TokenBarSettings = .shared,
        credentials: any ActivitySyncCredentialStoring = KeychainActivitySyncCredentialStore(),
        clientVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    {
        self.settings = settings
        self.credentials = credentials
        self.clientVersion = clientVersion
        do {
            self.token = try credentials.loadToken() ?? ""
            self.credentialMessage = nil
        } catch {
            self.token = ""
            self.credentialMessage = error.localizedDescription
        }
        self.configurationMessage = nil
        self.report = settings.syncEnabled ? .ready : .disabled
    }

    public func configuration() -> ActivitySyncConfiguration? {
        guard self.settings.syncEnabled else {
            self.report = .disabled
            return nil
        }
        do {
            let hadConfigurationError = self.configurationMessage != nil
            let configuration = try ActivitySyncConfiguration.parse(
                serverURL: self.settings.syncServerURL,
                token: self.token,
                device: ActivitySyncDevice(
                    id: self.settings.syncDeviceID,
                    name: self.settings.syncDeviceName,
                    os: .macos,
                    clientVersion: self.clientVersion))
            self.configurationMessage = nil
            if self.report.phase == .disabled || hadConfigurationError {
                self.report = .ready
            }
            return configuration
        } catch {
            self.configurationMessage = error.localizedDescription
            self.report = ActivitySyncReport(phase: .failure, message: error.localizedDescription)
            return nil
        }
    }

    public func accept(_ report: ActivitySyncReport) {
        self.report = report
    }
}

private extension Int64 {
    func saturatingAddForSync(_ other: Int64) -> Int64 {
        let (value, overflow) = self.addingReportingOverflow(other)
        guard overflow else { return value }
        return other >= 0 ? .max : .min
    }
}

private extension Int {
    func saturatingAddForSync(_ other: Int) -> Int {
        let (value, overflow) = self.addingReportingOverflow(other)
        guard overflow else { return value }
        return other >= 0 ? .max : .min
    }
}

private extension Double {
    func saturatingAddForSync(_ other: Double) -> Double {
        let value = self + other
        return value.isFinite ? value : .greatestFiniteMagnitude
    }
}

private func synchronizedDeviceIDForActivitySync(from value: String) -> String? {
    synchronizedIdentityForActivitySync(from: value)?.deviceID
}

private func synchronizedIdentityForActivitySync(
    from value: String) -> (deviceID: String, originalID: String)?
{
    guard value.hasPrefix("sync:") else { return nil }
    let remainder = value.dropFirst("sync:".count)
    guard let separator = remainder.firstIndex(of: ":") else { return nil }
    let candidate = String(remainder[..<separator])
    let originalID = String(remainder[remainder.index(after: separator)...])
    guard !originalID.isEmpty,
          let deviceID = UUID(uuidString: candidate)?.uuidString.lowercased()
    else {
        return nil
    }
    return (deviceID, originalID)
}

private func sanitizedActivitySyncSessionTitle(_ value: String?) -> String? {
    guard let value, isValidActivitySyncSessionTitle(value) else { return nil }
    return value
}

private func isValidActivitySyncSessionTitle(_ value: String) -> Bool {
    !value.isEmpty
        && value.utf8.count <= 512
        && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}
