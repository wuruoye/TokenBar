import Foundation

/// Snapshots published by background launchers. The launcher owns the files;
/// TokenBar only reads them and checks process identities, including after a restart.
struct CodexBackgroundTaskReader: Sendable {
    struct Task: Sendable {
        let id: String
        let name: String
        let activity: String
        let startedAt: Date
        let isInterrupted: Bool
    }

    private struct Record: Decodable {
        let schemaVersion: Int
        let platform: String
        let taskID: String
        let threadID: String
        let name: String
        let activity: String?
        let status: String
        let createdAt: String
        let startedAt: String?
        let workerPID: Int32?
        let workerSignature: String?
        let jobPID: Int32?
        let jobSignature: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", platform, name, activity, status
            case taskID = "task_id", threadID = "thread_id"
            case createdAt = "created_at", startedAt = "started_at"
            case workerPID = "worker_pid", workerSignature = "worker_signature"
            case jobPID = "job_pid", jobSignature = "job_signature"
        }
    }

    let directory: URL

    static func directory(environment: [String: String]) -> URL {
        if let path = environment["TOKENBAR_BACKGROUND_TASKS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenBar/background-tasks", isDirectory: true)
    }

    func tasks(now: Date) -> [String: Task] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: self.directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        let decoder = JSONDecoder()
        let records = files.compactMap { url -> Record? in
            guard url.pathExtension == "json",
                  let info = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  info.isRegularFile == true, (info.fileSize ?? .max) <= 64 * 1024,
                  let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.schemaVersion == 1, record.platform == "codex",
                  UUID(uuidString: record.threadID) != nil,
                  !record.taskID.isEmpty, !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["starting", "running"].contains(record.status)
            else { return nil }
            return record
        }
        let identities = Self.processIdentities(Set(records.flatMap { [$0.workerPID, $0.jobPID].compactMap { $0 } }))
        var grouped: [String: [Task]] = [:]
        for record in records {
            guard let createdAt = Self.date(record.createdAt) else { continue }
            let workerAlive = record.workerPID.flatMap { identities[$0] }.map {
                $0 == record.workerSignature?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            } ?? false
            let jobAlive = record.jobPID.flatMap { identities[$0] }.map {
                $0 == record.jobSignature?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            } ?? false
            let starting = record.status == "starting" && now.timeIntervalSince(createdAt) < 10
            let interrupted = !workerAlive && !jobAlive && !starting
            // Keep an unreported interruption visible for a day, without treating
            // an old timestamp as proof that a long-running process has stopped.
            guard !interrupted || now.timeIntervalSince(createdAt) < 24 * 60 * 60 else { continue }
            let description = DesktopUnreadTurnReader.flattened(record.activity ?? "")
                ?? DesktopUnreadTurnReader.flattened(record.name) ?? record.name
            let activity = if interrupted {
                "已中断，结果未知 · \(description)"
            } else if !workerAlive && jobAlive {
                "完成通知进程已退出 · \(description)"
            } else {
                description
            }
            grouped[record.threadID, default: []].append(Task(
                id: record.taskID, name: record.name, activity: activity,
                startedAt: record.startedAt.flatMap(Self.date) ?? createdAt,
                isInterrupted: interrupted))
        }
        return grouped.mapValues { tasks in
            let ordered = tasks.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
            return Task(
                id: ordered[0].id, name: ordered[0].name,
                activity: ordered.map(\.activity).joined(separator: " · "),
                startedAt: ordered[0].startedAt,
                isInterrupted: ordered.allSatisfy(\.isInterrupted))
        }
    }

    private static func date(_ value: String) -> Date? {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: Date.ISO8601FormatStyle()))
    }

    /// One bounded process query per refresh. Matching start times prevents PID
    /// reuse from keeping an abandoned task alive; zombies have already exited.
    private static func processIdentities(_ pids: Set<Int32>) -> [Int32: String] {
        let pids = pids.filter { $0 > 0 }
        guard !pids.isEmpty else { return [:] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", pids.sorted().map(String.init).joined(separator: ","), "-o", "pid=,lstart=,stat="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var identities: [Int32: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 7, let pid = Int32(parts[0]), !parts[6].contains("Z") else { continue }
            identities[pid] = parts[1...5].joined(separator: " ")
        }
        return identities
    }
}
