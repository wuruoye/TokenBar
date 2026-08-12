import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ActivitySyncIncrementalOutcome: Sendable {
    public let response: ActivitySyncDownloadResponse?
    public let uploadErrorDescription: String?
    public let downloadErrorDescription: String?

    public init(
        response: ActivitySyncDownloadResponse?,
        uploadErrorDescription: String? = nil,
        downloadErrorDescription: String? = nil)
    {
        self.response = response
        self.uploadErrorDescription = uploadErrorDescription
        self.downloadErrorDescription = downloadErrorDescription
    }
}

public protocol ActivitySyncIncrementalNetworking: ActivitySyncNetworking {
    func synchronizeIncrementally(
        _ envelope: ActivitySyncUploadEnvelope,
        configuration: ActivitySyncConfiguration) async throws -> ActivitySyncIncrementalOutcome
}

enum ActivitySyncJSONValue: Codable, Equatable, Sendable {
    case object([String: ActivitySyncJSONValue])
    case array([ActivitySyncJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "JSON number must be finite")
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ActivitySyncJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ActivitySyncJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "JSON number must be finite"))
            }
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: ActivitySyncJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [ActivitySyncJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        switch self {
        case let .integer(value): value
        case let .number(value) where value.rounded() == value: Int64(exactly: value)
        default: nil
        }
    }
}

enum ActivitySyncSnapshotPartitioner {
    static let maximumPartitions = 100_000

    static func partitions(_ snapshot: ActivitySnapshot) throws -> [String: ActivitySyncJSONValue] {
        let encoded = try self.canonicalData(snapshot)
        let value = try JSONDecoder().decode(ActivitySyncJSONValue.self, from: encoded)
        guard var root = value.objectValue else {
            throw ActivitySyncError.invalidResponse("snapshot must encode as an object")
        }
        let sessions = root.removeValue(forKey: "sessions")?.arrayValue ?? []
        let days = root.removeValue(forKey: "days")?.arrayValue ?? []
        let sourcesValue = root.removeValue(forKey: "sources")
        let memoryValue = root.removeValue(forKey: "memoryUsage")

        var sourceSummaries: [ActivitySyncJSONValue]? = nil
        if let sourcesValue {
            guard let sources = sourcesValue.arrayValue else {
                throw ActivitySyncError.invalidResponse("snapshot sources must be an array")
            }
            sourceSummaries = try sources.map { source in
                guard var object = source.objectValue else {
                    throw ActivitySyncError.invalidResponse("snapshot source must be an object")
                }
                object.removeValue(forKey: "days")
                return .object(object)
            }
        }
        var memorySummary: ActivitySyncJSONValue = .null
        if let memoryValue {
            guard var object = memoryValue.objectValue else {
                throw ActivitySyncError.invalidResponse("snapshot memoryUsage must be an object")
            }
            object.removeValue(forKey: "days")
            memorySummary = .object(object)
        }

        var result: [String: ActivitySyncJSONValue] = [
            "summary": .object([
                "snapshot": .object(root),
                "sources": sourceSummaries.map(ActivitySyncJSONValue.array) ?? .null,
                "memoryUsage": memorySummary,
            ]),
        ]
        for day in days {
            guard let date = day.objectValue?["date"]?.stringValue else {
                throw ActivitySyncError.invalidResponse("snapshot day date is invalid")
            }
            try self.insert(day, key: self.partitionKey("day", [date]), into: &result)
        }
        for source in sourcesValue?.arrayValue ?? [] {
            guard let sourceObject = source.objectValue,
                  let platform = sourceObject["platform"]?.stringValue,
                  let sourceDays = sourceObject["days"]?.arrayValue
            else {
                throw ActivitySyncError.invalidResponse("snapshot source is invalid")
            }
            for day in sourceDays {
                guard let date = day.objectValue?["date"]?.stringValue else {
                    throw ActivitySyncError.invalidResponse("snapshot source day is invalid")
                }
                try self.insert(
                    .object(["platform": .string(platform), "day": day]),
                    key: self.partitionKey("source-day", [platform, date]),
                    into: &result)
            }
        }
        for session in sessions {
            guard let object = session.objectValue,
                  let id = object["id"]?.stringValue
            else {
                throw ActivitySyncError.invalidResponse("snapshot session identity is invalid")
            }
            let platform = object["platform"]?.stringValue ?? ""
            try self.insert(
                session,
                key: self.partitionKey("session", [platform, id]),
                into: &result)
        }
        for day in memoryValue?.objectValue?["days"]?.arrayValue ?? [] {
            guard let date = day.objectValue?["date"]?.stringValue else {
                throw ActivitySyncError.invalidResponse("snapshot memory day is invalid")
            }
            try self.insert(
                day,
                key: self.partitionKey("memory-day", [date]),
                into: &result)
        }
        guard result.count <= self.maximumPartitions else {
            throw ActivitySyncError.invalidResponse("snapshot contains too many partitions")
        }
        return result
    }

    static func manifest(
        _ partitions: [String: ActivitySyncJSONValue]) throws -> [String: String]
    {
        guard partitions.count <= self.maximumPartitions else {
            throw ActivitySyncError.invalidResponse("snapshot contains too many partitions")
        }
        return try partitions.mapValues { value in
            self.sha256Hex(try self.canonicalData(value))
        }
    }

    static func materialize(
        _ partitions: [String: ActivitySyncJSONValue]) throws -> ActivitySnapshot
    {
        guard !partitions.isEmpty,
              partitions.count <= self.maximumPartitions,
              let summary = partitions["summary"]?.objectValue,
              Set(summary.keys) == Set(["snapshot", "sources", "memoryUsage"]),
              var root = summary["snapshot"]?.objectValue
        else {
            throw ActivitySyncError.invalidResponse("incremental summary is invalid")
        }
        guard ["sessions", "days", "sources", "memoryUsage"].allSatisfy({ root[$0] == nil }) else {
            throw ActivitySyncError.invalidResponse("incremental summary contains split fields")
        }

        var days: [ActivitySyncJSONValue] = []
        var sessions: [ActivitySyncJSONValue] = []
        var sourceDays: [String: [ActivitySyncJSONValue]] = [:]
        var memoryDays: [ActivitySyncJSONValue] = []
        for (key, value) in partitions where key != "summary" {
            if key.hasPrefix("day:") {
                guard let date = value.objectValue?["date"]?.stringValue,
                      key == self.partitionKey("day", [date])
                else {
                    throw ActivitySyncError.invalidResponse("incremental day identity is invalid")
                }
                days.append(value)
            } else if key.hasPrefix("source-day:") {
                guard let object = value.objectValue,
                      Set(object.keys) == Set(["platform", "day"]),
                      let platform = object["platform"]?.stringValue,
                      let day = object["day"],
                      let date = day.objectValue?["date"]?.stringValue,
                      key == self.partitionKey("source-day", [platform, date])
                else {
                    throw ActivitySyncError.invalidResponse("incremental source-day identity is invalid")
                }
                sourceDays[platform, default: []].append(day)
            } else if key.hasPrefix("session:") {
                guard let object = value.objectValue,
                      let id = object["id"]?.stringValue
                else {
                    throw ActivitySyncError.invalidResponse("incremental session identity is invalid")
                }
                let platform = object["platform"]?.stringValue ?? ""
                guard key == self.partitionKey("session", [platform, id]) else {
                    throw ActivitySyncError.invalidResponse("incremental session identity is invalid")
                }
                sessions.append(value)
            } else if key.hasPrefix("memory-day:") {
                guard let date = value.objectValue?["date"]?.stringValue,
                      key == self.partitionKey("memory-day", [date])
                else {
                    throw ActivitySyncError.invalidResponse("incremental memory-day identity is invalid")
                }
                memoryDays.append(value)
            } else {
                throw ActivitySyncError.invalidResponse("incremental partition kind is invalid")
            }
        }
        days.sort { self.date(of: $0) > self.date(of: $1) }
        sessions.sort {
            let left = $0.objectValue ?? [:]
            let right = $1.objectValue ?? [:]
            let leftKey = (
                left["endedAtMs"]?.integerValue ?? 0,
                left["startedAtMs"]?.integerValue ?? 0,
                left["platform"]?.stringValue ?? "",
                left["id"]?.stringValue ?? "")
            let rightKey = (
                right["endedAtMs"]?.integerValue ?? 0,
                right["startedAtMs"]?.integerValue ?? 0,
                right["platform"]?.stringValue ?? "",
                right["id"]?.stringValue ?? "")
            return leftKey > rightKey
        }
        root["days"] = .array(days)
        root["sessions"] = .array(sessions)

        switch summary["sources"] {
        case let .array(sourceSummaries):
            var sources: [ActivitySyncJSONValue] = []
            var platforms = Set<String>()
            for sourceSummary in sourceSummaries {
                guard var object = sourceSummary.objectValue,
                      object["days"] == nil,
                      let platform = object["platform"]?.stringValue,
                      platforms.insert(platform).inserted
                else {
                    throw ActivitySyncError.invalidResponse("incremental source summary is invalid")
                }
                var platformDays = sourceDays.removeValue(forKey: platform) ?? []
                platformDays.sort { self.date(of: $0) > self.date(of: $1) }
                object["days"] = .array(platformDays)
                sources.append(.object(object))
            }
            guard sourceDays.isEmpty else {
                throw ActivitySyncError.invalidResponse("incremental source-day has no source")
            }
            sources.sort {
                ($0.objectValue?["platform"]?.stringValue ?? "")
                    < ($1.objectValue?["platform"]?.stringValue ?? "")
            }
            root["sources"] = .array(sources)
        case .null:
            guard sourceDays.isEmpty else {
                throw ActivitySyncError.invalidResponse("incremental source-day has no source")
            }
        default:
            throw ActivitySyncError.invalidResponse("incremental source summaries are invalid")
        }

        switch summary["memoryUsage"] {
        case let .object(memorySummary):
            guard memorySummary["days"] == nil else {
                throw ActivitySyncError.invalidResponse("incremental memory summary is invalid")
            }
            var memory = memorySummary
            memoryDays.sort { self.date(of: $0) > self.date(of: $1) }
            memory["days"] = .array(memoryDays)
            root["memoryUsage"] = .object(memory)
        case .null:
            guard memoryDays.isEmpty else {
                throw ActivitySyncError.invalidResponse("incremental memory-day has no summary")
            }
        default:
            throw ActivitySyncError.invalidResponse("incremental memory summary is invalid")
        }
        return try JSONDecoder().decode(
            ActivitySnapshot.self,
            from: self.canonicalData(ActivitySyncJSONValue.object(root)))
    }

    static func apply(
        snapshot: ActivitySnapshot,
        upserts: [String: ActivitySyncJSONValue],
        deletes: [String]) throws -> ActivitySnapshot
    {
        guard upserts.count <= self.maximumPartitions,
              deletes.count <= self.maximumPartitions,
              Set(deletes).count == deletes.count,
              Set(upserts.keys).isDisjoint(with: deletes)
        else {
            throw ActivitySyncError.invalidResponse("incremental changes are invalid")
        }
        var partitions = try self.partitions(snapshot)
        for key in deletes {
            partitions.removeValue(forKey: key)
        }
        for (key, value) in upserts {
            guard !key.isEmpty, key.count <= 256 else {
                throw ActivitySyncError.invalidResponse("incremental partition key is invalid")
            }
            partitions[key] = value
        }
        return try self.materialize(partitions)
    }

    static func partitionKey(_ kind: String, _ identity: [String]) -> String {
        var data = Data(kind.utf8)
        for value in identity {
            data.append(0)
            data.append(contentsOf: value.utf8)
        }
        return "\(kind):\(self.sha256Hex(data))"
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func insert(
        _ value: ActivitySyncJSONValue,
        key: String,
        into partitions: inout [String: ActivitySyncJSONValue]) throws
    {
        guard partitions.updateValue(value, forKey: key) == nil else {
            throw ActivitySyncError.invalidResponse("snapshot contains duplicate partitions")
        }
    }

    private static func date(of value: ActivitySyncJSONValue) -> String {
        value.objectValue?["date"]?.stringValue ?? ""
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ActivitySyncV2UploadState: Codable, Sendable {
    let revision: Int64
    let lastFullAtMs: Int64
    let schemaVersion: Int
    let timezone: String
    let manifest: [String: String]
}

struct ActivitySyncV2RemoteEntry: Codable, Sendable {
    let device: ActivitySyncDevice
    let generatedAtMs: Int64
    let receivedAtMs: Int64
    let revision: Int64
    let manifest: [String: String]
    let snapshot: ActivitySnapshot

    var storedSnapshot: ActivitySyncStoredSnapshot {
        ActivitySyncStoredSnapshot(
            device: self.device,
            generatedAtMs: self.generatedAtMs,
            receivedAtMs: self.receivedAtMs,
            snapshot: self.snapshot)
    }
}

struct ActivitySyncV2State: Codable, Sendable {
    var stateVersion: Int
    var serverURL: String
    var localDeviceID: String
    var upload: ActivitySyncV2UploadState?
    var lastDownloadFullAtMs: Int64?
    var remotes: [ActivitySyncV2RemoteEntry]

    static func empty(configuration: ActivitySyncConfiguration) -> ActivitySyncV2State {
        ActivitySyncV2State(
            stateVersion: 1,
            serverURL: configuration.serverURL.absoluteString,
            localDeviceID: configuration.device.id,
            upload: nil,
            lastDownloadFullAtMs: nil,
            remotes: [])
    }
}

actor ActivitySyncIncrementalStore {
    private let fileURL: URL

    init(fileURL: URL = ActivitySyncIncrementalStore.defaultURL()) {
        self.fileURL = fileURL
    }

    func load(configuration: ActivitySyncConfiguration) -> ActivitySyncV2State {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= ActivitySyncRemoteClient.maximumDownloadBytes,
              let data = try? Data(contentsOf: self.fileURL),
              let state = try? JSONDecoder().decode(ActivitySyncV2State.self, from: data),
              state.stateVersion == 1,
              state.serverURL == configuration.serverURL.absoluteString,
              state.localDeviceID == configuration.device.id
        else {
            return .empty(configuration: configuration)
        }
        return state
    }

    func save(_ state: ActivitySyncV2State) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: self.fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.fileURL.path)
    }

    nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("activity-sync-v2-state.json", isDirectory: false)
    }
}

private enum ActivitySyncV2UploadMode: String {
    case full
    case delta
}

private struct ActivitySyncV2FullUpload: Encodable {
    let protocolVersion = 2
    let mode = "full"
    let device: ActivitySyncDevice
    let generatedAtMs: Int64
    let snapshot: ActivitySnapshot
}

private struct ActivitySyncV2DeltaUpload: Encodable {
    let protocolVersion = 2
    let mode = "delta"
    let device: ActivitySyncDevice
    let generatedAtMs: Int64
    let baseRevision: Int64
    let upserts: [String: ActivitySyncJSONValue]
    let deletes: [String]
}

private struct ActivitySyncV2UploadPlan {
    var mode: ActivitySyncV2UploadMode
    var data: Data
    let fullData: Data
    let manifest: [String: String]
    let previousLastFullAtMs: Int64?

    mutating func forceFull() {
        self.mode = .full
        self.data = self.fullData
    }
}

private struct ActivitySyncV2UploadResponse: Decodable {
    let protocolVersion: Int
    let revision: Int64
    let status: String
    let receivedAtMs: Int64
}

private struct ActivitySyncV2KnownSnapshot: Encodable {
    let deviceId: String
    let revision: Int64
    let manifest: [String: String]
}

private struct ActivitySyncV2QueryRequest: Encodable {
    let protocolVersion = 2
    let known: [ActivitySyncV2KnownSnapshot]
    let forceFull: Bool
    let excludeDeviceId: String
}

private struct ActivitySyncV2SnapshotChange: Decodable {
    let mode: String
    let device: ActivitySyncDevice
    let generatedAtMs: Int64
    let receivedAtMs: Int64
    let revision: Int64
    let manifest: [String: String]
    let snapshot: ActivitySnapshot?
    let upserts: [String: ActivitySyncJSONValue]?
    let deletes: [String]?
}

private struct ActivitySyncV2QueryResponse: Decodable {
    let protocolVersion: Int
    let snapshots: [ActivitySyncV2SnapshotChange]
    let deletedDeviceIds: [String]
}

extension ActivitySyncRemoteClient: ActivitySyncIncrementalNetworking {
    public func synchronizeIncrementally(
        _ envelope: ActivitySyncUploadEnvelope,
        configuration: ActivitySyncConfiguration) async throws -> ActivitySyncIncrementalOutcome
    {
        var state = await self.incrementalStore.load(configuration: configuration)
        state = self.validated(state: state, configuration: configuration)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var uploadErrorDescription: String?
        var usedLegacyProtocol = false
        do {
            var plan = try self.uploadPlan(
                envelope: envelope,
                state: state,
                configuration: configuration,
                nowMs: nowMs)
            do {
                let response = try await self.uploadV2(
                    data: plan.data,
                    configuration: configuration)
                state.upload = try self.uploadState(
                    response: response,
                    plan: plan,
                    envelope: envelope,
                    nowMs: nowMs)
            } catch ActivitySyncError.staleSnapshot where plan.mode == .delta {
                plan.forceFull()
                let response = try await self.uploadV2(
                    data: plan.data,
                    configuration: configuration)
                state.upload = try self.uploadState(
                    response: response,
                    plan: plan,
                    envelope: envelope,
                    nowMs: nowMs)
            } catch ActivitySyncError.server(404) {
                usedLegacyProtocol = true
                try await self.upload(envelope, configuration: configuration)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            uploadErrorDescription = error.localizedDescription
        }

        if usedLegacyProtocol {
            return try await self.legacyDownloadOutcome(
                configuration: configuration,
                uploadErrorDescription: uploadErrorDescription)
        }

        var downloadErrorDescription: String?
        var response: ActivitySyncDownloadResponse?
        do {
            let forceFull = self.fullCalibrationDue(
                lastFullAtMs: state.lastDownloadFullAtMs,
                deviceID: configuration.device.id,
                nowMs: nowMs)
            do {
                state = try await self.queryV2(
                    state: state,
                    configuration: configuration,
                    forceFull: forceFull,
                    nowMs: nowMs)
            } catch ActivitySyncError.invalidResponse where !forceFull {
                state = try await self.queryV2(
                    state: state,
                    configuration: configuration,
                    forceFull: true,
                    nowMs: nowMs)
            } catch ActivitySyncError.server(404) {
                return try await self.legacyDownloadOutcome(
                    configuration: configuration,
                    uploadErrorDescription: uploadErrorDescription)
            }
            response = ActivitySyncDownloadResponse(
                snapshots: state.remotes.map(\.storedSnapshot).sorted {
                    $0.device.id < $1.device.id
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            downloadErrorDescription = error.localizedDescription
        }

        do {
            try await self.incrementalStore.save(state)
        } catch {
            let storageMessage = "Incremental sync metadata could not be saved: \(error.localizedDescription)"
            downloadErrorDescription = [downloadErrorDescription, storageMessage]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return ActivitySyncIncrementalOutcome(
            response: response,
            uploadErrorDescription: uploadErrorDescription,
            downloadErrorDescription: downloadErrorDescription)
    }

    private func legacyDownloadOutcome(
        configuration: ActivitySyncConfiguration,
        uploadErrorDescription: String?) async throws -> ActivitySyncIncrementalOutcome
    {
        do {
            return ActivitySyncIncrementalOutcome(
                response: try await self.download(configuration: configuration),
                uploadErrorDescription: uploadErrorDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ActivitySyncIncrementalOutcome(
                response: nil,
                uploadErrorDescription: uploadErrorDescription,
                downloadErrorDescription: error.localizedDescription)
        }
    }

    private func uploadPlan(
        envelope: ActivitySyncUploadEnvelope,
        state: ActivitySyncV2State,
        configuration: ActivitySyncConfiguration,
        nowMs: Int64) throws -> ActivitySyncV2UploadPlan
    {
        try Self.validate(
            device: envelope.device,
            generatedAtMs: envelope.generatedAtMs,
            receivedAtMs: nil,
            snapshot: envelope.snapshot)
        let partitions = try ActivitySyncSnapshotPartitioner.partitions(envelope.snapshot)
        let manifest = try ActivitySyncSnapshotPartitioner.manifest(partitions)
        let fullData = try ActivitySyncSnapshotPartitioner.canonicalData(ActivitySyncV2FullUpload(
            device: envelope.device,
            generatedAtMs: envelope.generatedAtMs,
            snapshot: envelope.snapshot))
        var result = ActivitySyncV2UploadPlan(
            mode: .full,
            data: fullData,
            fullData: fullData,
            manifest: manifest,
            previousLastFullAtMs: state.upload?.lastFullAtMs)
        guard let previous = state.upload,
              previous.revision > 0,
              previous.schemaVersion == envelope.snapshot.schemaVersion,
              previous.timezone == envelope.snapshot.timezone,
              self.valid(manifest: previous.manifest),
              !self.fullCalibrationDue(
                  lastFullAtMs: previous.lastFullAtMs,
                  deviceID: configuration.device.id,
                  nowMs: nowMs)
        else {
            return result
        }
        let upserts = partitions.filter { previous.manifest[$0.key] != manifest[$0.key] }
        let deletes = previous.manifest.keys.filter { manifest[$0] == nil }.sorted()
        let deltaData = try ActivitySyncSnapshotPartitioner.canonicalData(ActivitySyncV2DeltaUpload(
            device: envelope.device,
            generatedAtMs: envelope.generatedAtMs,
            baseRevision: previous.revision,
            upserts: upserts,
            deletes: deletes))
        if deltaData.count * 100 < fullData.count * 70 {
            result.mode = .delta
            result.data = deltaData
        }
        return result
    }

    private func uploadV2(
        data: Data,
        configuration: ActivitySyncConfiguration) async throws -> ActivitySyncV2UploadResponse
    {
        guard data.count <= Self.maximumUploadBytes else {
            throw ActivitySyncError.requestTooLarge
        }
        let url = Self.endpoint(
            baseURL: configuration.serverURL,
            components: ["v2", "snapshots", configuration.device.id])
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: self.timeout)
        request.httpMethod = "PUT"
        request.httpBody = data
        self.authorize(&request, token: configuration.token, hasBody: true)
        let response = try await self.perform(request, maximumBodyBytes: 64 * 1024)
        switch response.statusCode {
        case 200 ... 299:
            break
        case 401, 403:
            throw ActivitySyncError.unauthorized
        case 409:
            throw ActivitySyncError.staleSnapshot
        default:
            throw ActivitySyncError.server(response.statusCode)
        }
        do {
            let value = try JSONDecoder().decode(ActivitySyncV2UploadResponse.self, from: response.data)
            guard value.protocolVersion == 2,
                  value.revision > 0,
                  value.receivedAtMs > 0,
                  ["created", "updated", "retry"].contains(value.status)
            else {
                throw ActivitySyncError.invalidResponse("invalid protocol-v2 upload metadata")
            }
            return value
        } catch let error as ActivitySyncError {
            throw error
        } catch {
            throw ActivitySyncError.invalidResponse(error.localizedDescription)
        }
    }

    private func uploadState(
        response: ActivitySyncV2UploadResponse,
        plan: ActivitySyncV2UploadPlan,
        envelope: ActivitySyncUploadEnvelope,
        nowMs: Int64) throws -> ActivitySyncV2UploadState
    {
        let lastFullAtMs: Int64
        switch plan.mode {
        case .full:
            lastFullAtMs = nowMs
        case .delta:
            guard let previous = plan.previousLastFullAtMs else {
                throw ActivitySyncError.invalidResponse("missing full calibration metadata")
            }
            lastFullAtMs = previous
        }
        return ActivitySyncV2UploadState(
            revision: response.revision,
            lastFullAtMs: lastFullAtMs,
            schemaVersion: envelope.snapshot.schemaVersion,
            timezone: envelope.snapshot.timezone,
            manifest: plan.manifest)
    }

    private func queryV2(
        state: ActivitySyncV2State,
        configuration: ActivitySyncConfiguration,
        forceFull: Bool,
        nowMs: Int64) async throws -> ActivitySyncV2State
    {
        let known = state.remotes.map {
            ActivitySyncV2KnownSnapshot(
                deviceId: $0.device.id,
                revision: $0.revision,
                manifest: $0.manifest)
        }.sorted { $0.deviceId < $1.deviceId }
        let data = try ActivitySyncSnapshotPartitioner.canonicalData(ActivitySyncV2QueryRequest(
            known: known,
            forceFull: forceFull,
            excludeDeviceId: configuration.device.id))
        guard data.count <= Self.maximumUploadBytes else {
            throw ActivitySyncError.requestTooLarge
        }
        let url = Self.endpoint(
            baseURL: configuration.serverURL,
            components: ["v2", "snapshots", "query"])
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: self.timeout)
        request.httpMethod = "POST"
        request.httpBody = data
        self.authorize(&request, token: configuration.token, hasBody: true)
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
        let decoded: ActivitySyncV2QueryResponse
        do {
            decoded = try JSONDecoder().decode(ActivitySyncV2QueryResponse.self, from: response.data)
        } catch {
            throw ActivitySyncError.invalidResponse(error.localizedDescription)
        }
        guard decoded.protocolVersion == 2 else {
            throw ActivitySyncError.invalidProtocolVersion(decoded.protocolVersion)
        }
        var next = state
        var entries = forceFull
            ? [:]
            : Dictionary(uniqueKeysWithValues: state.remotes.map { ($0.device.id, $0) })
        for deviceID in decoded.deletedDeviceIds {
            guard let uuid = UUID(uuidString: deviceID),
                  uuid.uuidString.lowercased() == deviceID,
                  deviceID != configuration.device.id
            else {
                throw ActivitySyncError.invalidResponse("deleted device ID is invalid")
            }
            entries.removeValue(forKey: deviceID)
        }
        var changedDeviceIDs = Set<String>()
        for change in decoded.snapshots {
            guard change.device.id != configuration.device.id,
                  changedDeviceIDs.insert(change.device.id).inserted,
                  change.revision > 0,
                  change.generatedAtMs > 0,
                  change.receivedAtMs > 0,
                  self.valid(manifest: change.manifest)
            else {
                throw ActivitySyncError.invalidResponse("incremental snapshot metadata is invalid")
            }
            let snapshot: ActivitySnapshot
            switch change.mode {
            case "full":
                guard let value = change.snapshot,
                      change.upserts == nil,
                      change.deletes == nil
                else {
                    throw ActivitySyncError.invalidResponse("full snapshot change is invalid")
                }
                snapshot = value.redactedForSync()
            case "delta":
                guard !forceFull,
                      change.snapshot == nil,
                      let upserts = change.upserts,
                      let deletes = change.deletes,
                      let previous = entries[change.device.id]
                else {
                    throw ActivitySyncError.invalidResponse("delta snapshot has no valid base")
                }
                snapshot = try ActivitySyncSnapshotPartitioner.apply(
                    snapshot: previous.snapshot,
                    upserts: upserts,
                    deletes: deletes).redactedForSync()
            default:
                throw ActivitySyncError.invalidResponse("incremental snapshot mode is invalid")
            }
            try Self.validate(
                device: change.device,
                generatedAtMs: change.generatedAtMs,
                receivedAtMs: change.receivedAtMs,
                snapshot: snapshot)
            let partitionKeys = Set(try ActivitySyncSnapshotPartitioner.partitions(snapshot).keys)
            guard partitionKeys == Set(change.manifest.keys) else {
                throw ActivitySyncError.invalidResponse("incremental manifest keys do not converge")
            }
            entries[change.device.id] = ActivitySyncV2RemoteEntry(
                device: change.device,
                generatedAtMs: change.generatedAtMs,
                receivedAtMs: change.receivedAtMs,
                revision: change.revision,
                manifest: change.manifest,
                snapshot: snapshot)
        }
        next.remotes = entries.values.sorted { $0.device.id < $1.device.id }
        if forceFull {
            next.lastDownloadFullAtMs = nowMs
        }
        return next
    }

    private func validated(
        state: ActivitySyncV2State,
        configuration: ActivitySyncConfiguration) -> ActivitySyncV2State
    {
        var value = state
        if let upload = value.upload,
           upload.revision <= 0 || upload.lastFullAtMs <= 0 || !self.valid(manifest: upload.manifest)
        {
            value.upload = nil
        }
        do {
            var deviceIDs = Set<String>()
            for remote in value.remotes {
                guard remote.device.id != configuration.device.id,
                      remote.revision > 0,
                      self.valid(manifest: remote.manifest),
                      deviceIDs.insert(remote.device.id).inserted
                else {
                    throw ActivitySyncError.invalidResponse("cached incremental metadata is invalid")
                }
                try Self.validate(
                    device: remote.device,
                    generatedAtMs: remote.generatedAtMs,
                    receivedAtMs: remote.receivedAtMs,
                    snapshot: remote.snapshot.redactedForSync())
                guard Set(try ActivitySyncSnapshotPartitioner.partitions(remote.snapshot).keys)
                    == Set(remote.manifest.keys)
                else {
                    throw ActivitySyncError.invalidResponse("cached incremental manifest is invalid")
                }
            }
        } catch {
            value.remotes = []
            value.lastDownloadFullAtMs = nil
        }
        return value
    }

    private func fullCalibrationDue(
        lastFullAtMs: Int64?,
        deviceID: String,
        nowMs: Int64) -> Bool
    {
        guard let lastFullAtMs, lastFullAtMs > 0, nowMs >= lastFullAtMs else {
            return true
        }
        let digest = SHA256.hash(data: Data(deviceID.utf8))
        let prefix = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let jitter = Int64(prefix % UInt32(60 * 60 * 1000))
        return nowMs - lastFullAtMs >= 24 * 60 * 60 * 1000 + jitter
    }

    private func valid(manifest: [String: String]) -> Bool {
        manifest.count <= ActivitySyncSnapshotPartitioner.maximumPartitions
            && manifest.allSatisfy { key, digest in
                !key.isEmpty
                    && key.count <= 256
                    && digest.count == 64
                    && digest.utf8.allSatisfy {
                        (48 ... 57).contains($0) || (97 ... 102).contains($0)
                    }
            }
    }

    private func authorize(
        _ request: inout URLRequest,
        token: String,
        hasBody: Bool)
    {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if hasBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")
    }
}
