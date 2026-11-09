import CoreServices
import CryptoKit
import Foundation
import Observation
import SQLite3

/// One finished task that a desktop app's sidebar still marks as unread, or a
/// task waiting on a question for the user.
public struct DesktopUnreadTask: Equatable, Identifiable, Sendable {
    public let platform: TokenPlatform
    /// The Codex thread ID, Claude Desktop session ID, or Antigravity
    /// conversation ID.
    public let id: String
    public let title: String?
    /// The last prompt the user sent in the task, flattened to one line.
    public let prompt: String?
    /// The opening text of the reply that finished the task, without Markdown.
    public let reply: String?
    /// The question or review request waiting for the user's answer.
    public let askQuestion: String?
    /// How long the task's last turn ran.
    public let turnDuration: TimeInterval?
    public let workspacePath: String?
    public let updatedAt: Date?

    public init(
        platform: TokenPlatform,
        id: String,
        title: String?,
        prompt: String?,
        reply: String?,
        askQuestion: String? = nil,
        turnDuration: TimeInterval?,
        workspacePath: String?,
        updatedAt: Date?)
    {
        self.platform = platform
        self.id = id
        self.title = title
        self.prompt = prompt
        self.reply = reply
        self.askQuestion = askQuestion
        self.turnDuration = turnDuration
        self.workspacePath = workspacePath
        self.updatedAt = updatedAt
    }
}

/// Tracks finished Codex and Claude desktop tasks that each app's sidebar still
/// marks as unread.
///
/// The apps mark the task they show as read as soon as their window comes to
/// the front, even when the user only passes through on the way to another
/// app or Space. So a task an app marks read stays unread here until the user
/// has seen it: opened it from TokenBar, or after it finished, kept its app in
/// front showing it for `readDwell`. Claude logs the session its window shows,
/// and a switch the user makes there reads the sessions on both sides of it
/// however short the visit. Codex logs nothing like that, so a Codex visit
/// that lasts `readDwell` reads every task.
@MainActor
@Observable
public final class DesktopUnreadTaskMonitor {
    /// Unread tasks per platform, most recently updated first.
    public private(set) var tasks: [TokenPlatform: [DesktopUnreadTask]] = [:]
    /// Tasks still running a turn per platform, most recently started first.
    public private(set) var running: [TokenPlatform: [DesktopRunningTask]] = [:]

    /// A time an app was in front.
    private struct Visit {
        let start: Date
        var end: Date?
    }

    private struct HeldTask {
        let task: DesktopUnreadTask
        let since: Date
    }

    /// How long an app has to stay in front for the task it shows to count as read.
    static let readDwell: TimeInterval = 3
    /// An app can write the read state of a task opened from TokenBar a while later.
    static let readLag: TimeInterval = 60
    /// Claude's log reaches back a few hours, so older visits are not kept.
    static let visitHistoryLimit: TimeInterval = 4 * 60 * 60
    /// How long Claude can take to switch to a session opened from TokenBar.
    static let claudeOpenSwitchLag: TimeInterval = 10
    /// Bounds a hold on a task read where TokenBar cannot see, such as on another device.
    static let holdLimit: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private let reader: DesktopUnreadTaskReader
    @ObservationIgnored private var watcher: DesktopUnreadTaskWatcher?

    @ObservationIgnored private let claudeTrackerStateURL: URL?
    @ObservationIgnored private let antigravityTrackerStateURL: URL?
    @ObservationIgnored private var isClaudeActive = true
    @ObservationIgnored private var isAntigravityActive = true
    /// The unread tasks each app reports, before held tasks are added.
    @ObservationIgnored private var reported: [TokenPlatform: [DesktopUnreadTask]] = [:]
    /// Tasks an app marked read before the user saw them.
    @ObservationIgnored private var held: [TokenPlatform: [String: HeldTask]] = [:]
    /// The sessions that still exist unarchived, for an app that tells.
    @ObservationIgnored private var existing: [TokenPlatform: Set<String>] = [:]
    /// Each app's recent visits, oldest first, the last one possibly still going.
    @ObservationIgnored private var visits: [TokenPlatform: [Visit]] = [:]
    /// Claude's focus changes, read again only when its log grows.
    @ObservationIgnored private var claudeFocusCache: (logSize: UInt64, changes: [ClaudeFocusChange])?
    /// Antigravity's focus changes, updated when its annotations or opened tasks change.
    @ObservationIgnored private var antigravityFocus: [ClaudeFocusChange] = []
    /// Tasks opened from TokenBar, which count as read as soon as their app shows them.
    @ObservationIgnored private var openedAt: [TokenPlatform: [String: Date]] = [:]
    /// Sessions opened from TokenBar per platform, oldest first. Claude and
    /// Antigravity record the switch to one like a switch the user makes.
    @ObservationIgnored private var opens: [TokenPlatform: [(id: String, at: Date)]] = [:]
    @ObservationIgnored private var releaseChecks: [TokenPlatform: Task<Void, Never>] = [:]
    @ObservationIgnored private var openLagChecks: [TokenPlatform: Task<Void, Never>] = [:]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        claudeTrackerStateURL: URL? = DesktopUnreadTaskMonitor.defaultClaudeTrackerStateURL(),
        antigravityTrackerStateURL: URL? = DesktopUnreadTaskMonitor.defaultAntigravityTrackerStateURL())
    {
        self.reader = DesktopUnreadTaskReader(environment: environment)
        self.claudeTrackerStateURL = claudeTrackerStateURL
        self.antigravityTrackerStateURL = antigravityTrackerStateURL
    }

    public nonisolated static func defaultClaudeTrackerStateURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("claude-unread-state.json", isDirectory: false)
    }

    public nonisolated static func defaultAntigravityTrackerStateURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("antigravity-unread-state.json", isDirectory: false)
    }

    public var counts: [TokenPlatform: Int] {
        self.tasks.mapValues(\.count)
    }

    public func count(for platform: TokenPlatform) -> Int {
        self.tasks[platform]?.count ?? 0
    }

    public nonisolated static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
    public nonisolated static let codexBundleIdentifier = "com.openai.codex"
    public nonisolated static let antigravityBundleIdentifier = "com.google.antigravity"

    /// Hears which app is in front. Claude counts a turn that ends in the
    /// session its window shows as read, even while another app is in front,
    /// so TokenBar keeps such a turn unread until Claude comes to the front on
    /// it. Antigravity suppresses unread in memory while its focused window
    /// shows the finishing conversation without immediately rewriting the
    /// conversation's annotation file.
    public func setFrontmostApplication(_ bundleIdentifier: String?) {
        let platform: TokenPlatform? = switch bundleIdentifier {
        case Self.claudeBundleIdentifier: .claude
        case Self.codexBundleIdentifier: .codex
        case Self.antigravityBundleIdentifier: .antigravity
        default: nil
        }
        let now = Date()
        for (other, history) in self.visits where other != platform {
            guard let last = history.indices.last, history[last].end == nil else { continue }
            self.visits[other]?[last].end = now
            self.releaseChecks.removeValue(forKey: other)?.cancel()
        }
        if let platform, self.visits[platform]?.last.map({ $0.end != nil }) ?? true {
            self.visits[platform] = (self.visits[platform] ?? []).filter {
                now.timeIntervalSince($0.end ?? now) < Self.visitHistoryLimit
            } + [Visit(start: now)]
            self.scheduleReleaseCheck(for: platform)
        }
        let isClaudeActive = platform == .claude
        if isClaudeActive != self.isClaudeActive {
            self.isClaudeActive = isClaudeActive
            self.watcher?.setClaudeActive(isClaudeActive)
        }
        let isAntigravityActive = platform == .antigravity
        if isAntigravityActive != self.isAntigravityActive {
            self.isAntigravityActive = isAntigravityActive
            self.watcher?.setAntigravityActive(isAntigravityActive)
        }
    }

    /// A task opened from TokenBar is read once its app shows it, however
    /// briefly.
    public func markOpened(platform: TokenPlatform, id: String) {
        let now = Date()
        let currentUpdatedAt = self.reported[platform]?.first(where: { $0.id == id })?.updatedAt
            ?? self.held[platform]?[id]?.task.updatedAt
        let effectiveOpenedAt = max(now, currentUpdatedAt ?? .distantPast)
        self.openedAt[platform, default: [:]][id] = effectiveOpenedAt
        if platform == .claude || platform == .antigravity {
            self.opens[platform] = (self.opens[platform] ?? []).filter {
                now.timeIntervalSince($0.at) < Self.visitHistoryLimit
            } + [(id, now)]
        }
        if platform == .antigravity {
            self.antigravityFocus = self.antigravityFocus.filter {
                now.timeIntervalSince($0.at) < Self.visitHistoryLimit
            } + [ClaudeFocusChange(sessionID: id, at: now)]
            self.watcher?.markAntigravityViewed(id: id, at: effectiveOpenedAt)
        }
        _ = self.held[platform]?.removeValue(forKey: id)
        self.publishTasks(for: platform)
        self.scheduleOpenLagCheck(for: platform)
    }

    public func start() {
        guard self.watcher == nil else { return }
        let watcher = DesktopUnreadTaskWatcher(
            reader: self.reader,
            claudeTrackerStateURL: self.claudeTrackerStateURL,
            antigravityTrackerStateURL: self.antigravityTrackerStateURL,
            publish: { [weak self] platform, tasks, existing, focus in
                Task { @MainActor [weak self] in
                    self?.accept(tasks, existing: existing, focus: focus, for: platform)
                }
            },
            publishRunning: { [weak self] platform, tasks in
                Task { @MainActor [weak self] in
                    self?.acceptRunning(tasks, for: platform)
                }
            })
        self.watcher = watcher
        watcher.setClaudeActive(self.isClaudeActive)
        watcher.setAntigravityActive(self.isAntigravityActive)
        watcher.start()
    }

    public func stop() {
        self.watcher?.stop()
        self.watcher = nil
        self.tasks = [:]
        self.running = [:]
        self.reported = [:]
        self.held = [:]
        self.existing = [:]
        self.openedAt = [:]
        self.opens = [:]
        self.antigravityFocus = []
        for check in self.releaseChecks.values {
            check.cancel()
        }
        self.releaseChecks = [:]
        for check in self.openLagChecks.values {
            check.cancel()
        }
        self.openLagChecks = [:]
    }

    public func refresh() {
        self.watcher?.refresh()
    }

    /// Holds the tasks the app no longer reports, unless opened from TokenBar.
    private func accept(
        _ tasks: [DesktopUnreadTask],
        existing: Set<String>?,
        focus: [ClaudeFocusChange]? = nil,
        for platform: TokenPlatform)
    {
        guard self.watcher != nil else { return }
        let now = Date()
        if platform == .antigravity, let focus {
            self.antigravityFocus = focus
        }
        let ids = Set(tasks.map(\.id))
        let opened = (self.openedAt[platform] ?? [:]).filter { now.timeIntervalSince($0.value) < Self.readLag }
        self.openedAt[platform] = opened
        for task in self.reported[platform] ?? []
            where task.askQuestion == nil && !ids.contains(task.id) && opened[task.id] == nil
        {
            self.held[platform, default: [:]][task.id] = HeldTask(task: task, since: now)
        }
        self.reported[platform] = tasks
        self.existing[platform] = existing
        self.releaseHeld(for: platform, now: now)
        self.publishTasks(for: platform)
    }

    private func acceptRunning(_ tasks: [DesktopRunningTask], for platform: TokenPlatform) {
        guard self.watcher != nil, self.running[platform] != tasks else { return }
        self.running[platform] = tasks
        // A new turn means the user saw the last one.
        if !(self.held[platform] ?? [:]).isEmpty {
            self.publishTasks(for: platform)
        }
    }

    private func claudeFocusChanges() -> [ClaudeFocusChange]? {
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: self.reader.claudeMainLog.path))?[.size] as? NSNumber
        else {
            return nil
        }
        if let cache = self.claudeFocusCache, cache.logSize == size.uint64Value {
            return cache.changes
        }
        guard let changes = self.reader.claudeFocusChanges() else { return nil }
        self.claudeFocusCache = (size.uint64Value, changes)
        return changes
    }

    /// Whether a visit that ended after the task finished read it. Without
    /// focus history, a visit reads every task once it lasts `readDwell`.
    private func seen(
        _ task: DesktopUnreadTask,
        on platform: TokenPlatform,
        focus: [ClaudeFocusChange]?,
        now: Date) -> Bool
    {
        let finishedAt = task.updatedAt ?? .distantPast
        return (self.visits[platform] ?? []).contains { visit in
            guard (visit.end ?? now) >= finishedAt else { return false }
            guard let focus else {
                return (visit.end ?? now).timeIntervalSince(visit.start) >= Self.readDwell
            }
            return self.claudeVisitRead(task.id, on: platform, visit: visit, focus: focus, now: now)
        }
    }

    /// The visit read the session if it showed the session for `readDwell`,
    /// or the user switched to it or away from it. A session opened from
    /// TokenBar replaces the one the window showed before the user saw it.
    private func claudeVisitRead(
        _ id: String,
        on platform: TokenPlatform,
        visit: Visit,
        focus: [ClaudeFocusChange],
        now: Date) -> Bool
    {
        var shown = focus.last { $0.at <= visit.start.addingTimeInterval(-1) }?.sessionID
        var shownSince = visit.start
        var duration: TimeInterval = 0
        for change in Self.changes(during: visit, focus: focus, now: now) {
            let at = max(change.at, visit.start)
            if shown == id {
                duration += at.timeIntervalSince(shownSince)
            }
            if shown == id || change.sessionID == id, !self.isOpenSwitch(change, on: platform) {
                return true
            }
            shown = change.sessionID
            shownSince = at
        }
        if shown == id {
            duration += (visit.end ?? now).timeIntervalSince(shownSince)
        }
        return duration >= Self.readDwell
    }

    /// Claude logs a switch as no session, then the new one, in the same second.
    private func isOpenSwitch(_ change: ClaudeFocusChange, on platform: TokenPlatform) -> Bool {
        (self.opens[platform] ?? []).contains { open in
            (change.sessionID == nil || change.sessionID == open.id)
                && change.at > open.at.addingTimeInterval(-1)
                && change.at < open.at.addingTimeInterval(Self.claudeOpenSwitchLag)
        }
    }

    /// The log counts seconds, so a switch in the second the visit began
    /// belongs to it.
    private static func changes(
        during visit: Visit,
        focus: [ClaudeFocusChange],
        now: Date) -> [ClaudeFocusChange]
    {
        focus.filter { $0.at > visit.start.addingTimeInterval(-1) && $0.at <= (visit.end ?? now) }
    }

    /// Releases the held tasks the user has since seen, and drops those archived.
    private func releaseHeld(for platform: TokenPlatform, now: Date) {
        guard let held = self.held[platform], !held.isEmpty else { return }
        let focus: [ClaudeFocusChange]? = switch platform {
        case .claude:
            self.claudeFocusChanges()
        case .antigravity:
            self.antigravityFocus.isEmpty ? nil : self.antigravityFocus
        default:
            nil
        }
        let existing = self.existing[platform]
        self.held[platform] = held.filter { id, hold in
            now.timeIntervalSince(hold.since) < Self.holdLimit
                && existing?.contains(id) != false
                && !self.seen(hold.task, on: platform, focus: focus, now: now)
        }
    }

    /// Checks once when the visit reaches `readDwell`. A switch the user makes
    /// in Claude rewrites the session records, and the recount that follows
    /// releases what it read.
    private func scheduleReleaseCheck(for platform: TokenPlatform) {
        guard let held = self.held[platform], !held.isEmpty,
              let visit = self.visits[platform]?.last,
              visit.end == nil
        else {
            return
        }
        let remaining = Self.readDwell - Date().timeIntervalSince(visit.start)
        guard remaining > 0 else { return }
        let delay = remaining + 0.1
        self.releaseChecks[platform]?.cancel()
        self.releaseChecks[platform] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.releaseChecks[platform] = nil
            self.releaseHeld(for: platform, now: Date())
            self.publishTasks(for: platform)
        }
    }

    /// Publishes the reported tasks and the held ones that are neither
    /// reported again nor running a new turn. Tasks just opened from TokenBar
    /// clear immediately unless a newer turn finished after the click.
    private func publishTasks(for platform: TokenPlatform) {
        let now = Date()
        let opened = (self.openedAt[platform] ?? [:]).filter {
            now.timeIntervalSince($0.value) < Self.readLag
        }
        self.openedAt[platform] = opened
        let reported = (self.reported[platform] ?? []).filter { task in
            if task.askQuestion != nil {
                return true
            }
            guard let openedAt = opened[task.id] else { return true }
            return (task.updatedAt ?? .distantPast) > openedAt
        }
        let excluded = Set((self.reported[platform] ?? []).map(\.id) + (self.running[platform] ?? []).map(\.id))
        let held = (self.held[platform] ?? [:]).filter { !excluded.contains($0.key) && opened[$0.key] == nil }
        self.held[platform] = held
        let tasks = held.isEmpty ? reported : (reported + held.values.map(\.task)).sorted {
            ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id)
        }
        if !held.isEmpty {
            self.scheduleReleaseCheck(for: platform)
        }
        guard self.tasks[platform] != tasks else { return }
        self.tasks[platform] = tasks
    }

    private func scheduleOpenLagCheck(for platform: TokenPlatform) {
        guard let latest = self.openedAt[platform]?.values.max() else { return }
        let remaining = max(0.1, Self.readLag - Date().timeIntervalSince(latest) + 0.1)
        self.openLagChecks[platform]?.cancel()
        self.openLagChecks[platform] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.openLagChecks[platform] = nil
            self.publishTasks(for: platform)
        }
    }
}

struct DesktopUnreadTaskReader: Sendable {
    static let platforms: [TokenPlatform] = [.codex, .claude, .antigravity]

    let codexHome: URL
    let claudeSupportDirectory: URL
    let claudeProjectsDirectory: URL
    let claudeMainLog: URL
    let antigravityHome: URL
    let backgroundTasksDirectory: URL

    init(
        codexHome: URL,
        claudeSupportDirectory: URL,
        claudeProjectsDirectory: URL,
        claudeMainLog: URL,
        antigravityHome: URL = AntigravityQuotaService.antigravityHomeURL(environment: [:]),
        backgroundTasksDirectory: URL = CodexBackgroundTaskReader.directory(environment: [:]))
    {
        self.codexHome = codexHome
        self.claudeSupportDirectory = claudeSupportDirectory
        self.claudeProjectsDirectory = claudeProjectsDirectory
        self.claudeMainLog = claudeMainLog
        self.antigravityHome = antigravityHome
        self.backgroundTasksDirectory = backgroundTasksDirectory
    }

    init(environment: [String: String]) {
        let fileManager = FileManager.default
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let claudeConfigDirectory = environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        self.init(
            codexHome: CodexAuthStore.codexHomeURL(environment: environment),
            claudeSupportDirectory: applicationSupport
                .appendingPathComponent("Claude", isDirectory: true),
            claudeProjectsDirectory: claudeConfigDirectory
                .appendingPathComponent("projects", isDirectory: true),
            claudeMainLog: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Claude/main.log", isDirectory: false),
            antigravityHome: AntigravityQuotaService.antigravityHomeURL(environment: environment),
            backgroundTasksDirectory: CodexBackgroundTaskReader.directory(environment: environment))
    }

    // MARK: Codex

    /// Codex Desktop stores unread thread IDs per signed-in identity and execution
    /// host in `.codex-global-state.json`. The list also keeps subagent threads the
    /// sidebar never shows, so IDs are checked against the local thread database.
    /// Threads with an unanswered question (`waiting`) stay in the list even
    /// while running or before `.codex-global-state.json` marks them unread.
    func codexUnreadTasks(
        turns: DesktopUnreadTurnReader,
        waiting: [String: (question: String, askedAt: Date?)] = [:]) -> [DesktopUnreadTask]
    {
        var threadIDs = Set(waiting.keys)
        let stateURL = self.codexHome.appendingPathComponent(
            ".codex-global-state.json",
            isDirectory: false)
        if let data = try? Data(contentsOf: stateURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let readState = object["electron-thread-read-state-v1"] as? [String: Any],
           let identities = readState["unreadByIdentity"] as? [String: Any]
        {
            let hostMaps: [Any] = if let identity = self.codexIdentityKey() {
                identities[identity].map { [$0] } ?? []
            } else {
                Array(identities.values)
            }
            for case let hosts as [String: Any] in hostMaps {
                for (hostKey, ids) in hosts where hostKey.hasPrefix("local:") {
                    for case let id as String in ids as? [Any] ?? [] {
                        threadIDs.insert(id)
                    }
                }
            }
        }
        guard !threadIDs.isEmpty else { return [] }
        return self.visibleCodexThreads(.ids(threadIDs)).map { thread in
            let turn = thread.rolloutPath.map {
                turns.codexTurn(rolloutURL: URL(fileURLWithPath: $0))
            }
            let pending = waiting[thread.id]
            let updatedAt: Date? = switch (thread.updatedAt, pending?.askedAt) {
            case let (lhs?, rhs?): max(lhs, rhs)
            case let (lhs?, nil): lhs
            case let (nil, rhs?): rhs
            case (nil, nil): nil
            }
            return DesktopUnreadTask(
                platform: .codex,
                id: thread.id,
                title: thread.title,
                prompt: turn?.prompt ?? thread.firstPrompt,
                reply: turn?.reply,
                askQuestion: pending?.question,
                turnDuration: turn?.duration,
                workspacePath: thread.workspacePath,
                updatedAt: updatedAt)
        }.sorted {
            ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id)
        }
    }

    /// Codex Desktop keys ChatGPT sign-ins by
    /// `sha256(JSON.stringify(["chatgpt", accountId, userId]))`.
    private func codexIdentityKey() -> String? {
        let authURL = self.codexHome.appendingPathComponent("auth.json", isDirectory: false)
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = Self.jwtClaims(idToken)
        else {
            return nil
        }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        guard let accountID = (tokens["account_id"] as? String)
            ?? (auth?["chatgpt_account_id"] as? String),
            let userID = (auth?["chatgpt_user_id"] as? String)
            ?? (auth?["user_id"] as? String),
            let identity = try? JSONSerialization.data(
                withJSONObject: ["chatgpt", accountID, userID],
                options: [.withoutEscapingSlashes])
        else {
            return nil
        }
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private struct CodexThread {
        let id: String
        let title: String?
        let firstPrompt: String?
        let workspacePath: String?
        let rolloutPath: String?
        let updatedAt: Date?
    }

    /// Codex threads that ran a turn since a moment, which includes every
    /// thread still running one, and the rollouts their next turn writes to.
    func codexRunningTasks(
        states: CodexTurnStateReader,
        waitingIDs: Set<String> = [],
        now: Date)
        -> (
            tasks: [DesktopRunningTask],
            waiting: [String: (question: String, askedAt: Date?)],
            rollouts: Set<String>
        )
    {
        let background = CodexBackgroundTaskReader(directory: self.backgroundTasksDirectory).tasks(now: now)
        var threads = self.visibleCodexThreads(.updatedSince(now.addingTimeInterval(-24 * 60 * 60)))
        let olderIDs = Set(background.keys).union(waitingIDs).subtracting(threads.map(\.id))
        if !olderIDs.isEmpty {
            threads += self.visibleCodexThreads(.ids(olderIDs))
        }
        let rollouts = Set(threads.compactMap(\.rolloutPath))
        states.forget(except: rollouts)
        var waiting: [String: (question: String, askedAt: Date?)] = [:]
        let tasks = threads.compactMap { thread -> DesktopRunningTask? in
            let backgroundTask = background[thread.id].map { task in
                DesktopRunningTask(
                    platform: .codex, id: thread.id, title: thread.title ?? task.name,
                    startedAt: task.startedAt, activity: task.activity,
                    isInBackground: true, isInterrupted: task.isInterrupted)
            }
            guard let path = thread.rolloutPath,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modifiedAt = attributes[.modificationDate] as? Date
            else {
                return backgroundTask
            }
            let isRecent = now.timeIntervalSince(modifiedAt) < DesktopRunningTaskLiveness.quietLimit
            guard isRecent || waitingIDs.contains(thread.id) else {
                return backgroundTask
            }
            let state = states.state(of: URL(fileURLWithPath: path), size: size)
            if let question = state.askQuestion {
                waiting[thread.id] = (question, state.askedAt ?? modifiedAt)
            }
            guard isRecent, state.isRunning else { return backgroundTask }
            return DesktopRunningTask(
                platform: .codex,
                id: thread.id,
                title: thread.title,
                startedAt: state.startedAt,
                activity: state.activity)
        }
        return (tasks, waiting, rollouts)
    }

    private enum CodexThreadFilter {
        case ids(Set<String>)
        case updatedSince(Date)
    }

    private func visibleCodexThreads(_ filter: CodexThreadFilter) -> [CodexThread] {
        guard let databaseURL = self.codexStateDatabaseURL() else { return [] }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_busy_timeout(database, 1000)

        // Older thread databases lack the columns Codex added later, such as the
        // generated `name` the sidebar shows in place of the first prompt.
        let columns = Self.columnNames(of: "threads", in: database)
        func column(_ name: String) -> String {
            columns.contains(name) ? name : "NULL"
        }
        let updatedAt = "COALESCE(\(column("updated_at_ms")), \(column("updated_at")) * 1000)"
        let condition = switch filter {
        case let .ids(ids):
            "id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))"
        case .updatedSince:
            "\(updatedAt) >= ?"
        }
        let sql = """
            SELECT id, \(column("name")), \(column("title")), \(column("cwd")),
                   \(column("rollout_path")), \(updatedAt)
            FROM threads
            WHERE archived = 0
              AND COALESCE(source, '') NOT LIKE '{"subagent"%'
              AND \(condition)
            ORDER BY 6 DESC
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        switch filter {
        case let .ids(ids):
            for (index, id) in ids.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), id, -1, Self.sqliteTransient)
            }
        case let .updatedSince(date):
            sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970 * 1000))
        }
        var threads: [CodexThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.text(statement, 0) else { continue }
            let firstPrompt = Self.text(statement, 2).flatMap(DesktopUnreadTurnReader.flattened)
            let updatedAtMs = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 5)
            threads.append(CodexThread(
                id: id,
                title: Self.text(statement, 1).flatMap(DesktopUnreadTurnReader.flattened) ?? firstPrompt,
                firstPrompt: firstPrompt,
                workspacePath: Self.text(statement, 3),
                rolloutPath: Self.text(statement, 4),
                updatedAt: updatedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }))
        }
        return threads
    }

    private static func columnNames(of table: String, in database: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = Self.text(statement, 1) {
                names.insert(name)
            }
        }
        return names
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    func codexStateDatabaseURL() -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: self.codexHome.path) else {
            return nil
        }
        let newest = names.compactMap { name -> (version: Int, name: String)? in
            guard name.hasPrefix("state_"),
                  name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst("state_".count).dropLast(".sqlite".count))
            else {
                return nil
            }
            return (version, name)
        }.max { $0.version < $1.version }
        return newest.map { self.codexHome.appendingPathComponent($0.name, isDirectory: false) }
    }

    func visibleCodexThreadIDs() -> Set<String>? {
        guard let databaseURL = self.codexStateDatabaseURL() else { return nil }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(database, 1000)
        let sql = """
            SELECT id
            FROM threads
            WHERE archived = 0
              AND COALESCE(source, '') NOT LIKE '{"subagent"%'
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        var ids = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = Self.text(statement, 0) {
                ids.insert(id)
            }
        }
        return ids
    }

    // MARK: Claude

    private struct ClaudeSessionRecord: Decodable {
        struct PendingStart: Decodable {
            let since: Int64?
        }

        let completedTurns: Int?
        let lastFocusedAt: Int64?
        let lastActivityAt: Int64?
        let lastTurnEdgeAt: Int64?
        let isArchived: Bool?
        let title: String?
        let cwd: String?
        let cliSessionId: String?
        let pendingFirstStart: PendingStart?
    }

    private var claudeLocalStorageDirectory: URL {
        self.claudeSupportDirectory
            .appendingPathComponent("Local Storage", isDirectory: true)
            .appendingPathComponent("leveldb", isDirectory: true)
    }

    /// Claude Desktop keeps its sidebar unread state in the claude.ai renderer's
    /// localStorage entry `epitaxy-unread-v1`. Chromium commits localStorage to disk
    /// in batches, so this set can trail the app by more than a minute.
    func claudeUnreadStore() -> Set<String> {
        let storageKey = Array("_https://claude.ai".utf8) + [0, 1] + Array("epitaxy-unread-v1".utf8)
        guard let raw = LevelDBSnapshotReader.latestValue(
            forKey: storageKey,
            in: self.claudeLocalStorageDirectory),
              let json = Self.chromiumLocalStorageString(raw),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let state = object["state"] as? [String: Any]
        else {
            return []
        }

        var sessionIDs = Set<String>()
        for field in ["unreadIds", "explicitUnreadIds"] {
            for case let id as String in state[field] as? [Any] ?? [] {
                sessionIDs.insert(id)
            }
        }
        return sessionIDs
    }

    /// When Chromium last committed localStorage. Each commit appends every
    /// change the renderer made so far to the LevelDB write-ahead log, while
    /// compactions only write tables, and claude.ai is the only origin there.
    func claudeStoreCommittedAt() -> Date {
        let logs = (try? FileManager.default.contentsOfDirectory(
            at: self.claudeLocalStorageDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return logs
            .filter { $0.pathExtension == "log" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? .distantPast
    }

    /// Claude Desktop logs the session its window shows, or `null` while it
    /// shows something else, such as a new session or Settings. The sidebar
    /// keeps a session read when a turn finishes there.
    func claudeShownSession() -> ClaudeShownSession {
        let marker = Data("LocalSessions.setFocusedSession: sessionId=".utf8)
        guard let handle = try? FileHandle(forReadingFrom: self.claudeMainLog) else { return .unknown }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return .unknown }
        let tailLength: UInt64 = 256 << 10
        guard (try? handle.seek(toOffset: end > tailLength ? end - tailLength : 0)) != nil,
              let tail = try? handle.readToEnd(),
              let range = tail.range(of: marker, options: .backwards)
        else {
            return .unknown
        }
        let value = tail[range.upperBound...].prefix { byte in
            byte != 0x0A && byte != 0x0D && byte != 0x20 && byte != 0x2C
        }
        guard let id = String(data: Data(value), encoding: .utf8), !id.isEmpty else { return .unknown }
        return id == "null" ? .none : .session(id)
    }

    /// The sessions Claude Desktop's window showed, oldest first, from the end
    /// of its log, which notes each change to the second.
    func claudeFocusChanges() -> [ClaudeFocusChange]? {
        let marker = Data("LocalSessions.setFocusedSession: sessionId=".utf8)
        guard let handle = try? FileHandle(forReadingFrom: self.claudeMainLog) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let tailLength: UInt64 = 256 << 10
        guard (try? handle.seek(toOffset: end > tailLength ? end - tailLength : 0)) != nil,
              let tail = try? handle.readToEnd()
        else {
            return nil
        }
        return tail.split(separator: 0x0A).compactMap { line -> ClaudeFocusChange? in
            guard let range = line.range(of: marker),
                  let at = Self.claudeLogDate(line.prefix(19))
            else {
                return nil
            }
            let value = line[range.upperBound...].prefix { byte in
                byte != 0x0D && byte != 0x20 && byte != 0x2C
            }
            guard let id = String(data: Data(value), encoding: .utf8), !id.isEmpty else { return nil }
            return ClaudeFocusChange(sessionID: id == "null" ? nil : id, at: at)
        }
    }

    /// `yyyy-MM-dd HH:mm:ss` in local time.
    private static func claudeLogDate(_ text: Data.SubSequence) -> Date? {
        let fields = String(decoding: text, as: UTF8.self)
            .split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" })
            .compactMap { Int($0) }
        guard fields.count == 6 else { return nil }
        return Calendar.current.date(from: DateComponents(
            year: fields[0], month: fields[1], day: fields[2],
            hour: fields[3], minute: fields[4], second: fields[5]))
    }

    /// The running Claude Desktop's process and when it launched.
    struct ClaudeLaunch: Equatable, Sendable {
        let pid: pid_t
        let startedAt: Date
    }

    /// The running Claude Desktop. The tasks its sessions run in the background
    /// end when it quits. Checking the known process is one lookup, while
    /// finding a new one goes through every process.
    func claudeLaunch(reusing known: ClaudeLaunch?) -> ClaudeLaunch? {
        Self.appLaunch(executableName: "Claude", reusing: known)
    }

    func antigravityLaunch(reusing known: ClaudeLaunch?) -> ClaudeLaunch? {
        Self.appLaunch(executableName: "Antigravity", reusing: known)
    }

    private static func appLaunch(executableName: String, reusing known: ClaudeLaunch?) -> ClaudeLaunch? {
        if let known, Self.processStartedAt(known.pid) == known.startedAt {
            return known
        }
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        // Leave room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let suffix = ".app/Contents/MacOS/\(executableName)"
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == executableName,
                  proc_pidpath(process.kp_proc.p_pid, &path, UInt32(path.count)) > 0,
                  String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                      .hasSuffix(suffix)
            else {
                continue
            }
            return ClaudeLaunch(pid: process.kp_proc.p_pid, startedAt: Self.startedAt(process))
        }
        return nil
    }

    private static func processStartedAt(_ pid: pid_t) -> Date? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &process, &size, nil, 0) == 0, size > 0 else { return nil }
        return self.startedAt(process)
    }

    private static func startedAt(_ process: kinfo_proc) -> Date {
        let started = process.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }

    /// Chromium prefixes localStorage values with 0 for UTF-16LE or 1 for Latin-1.
    private static func chromiumLocalStorageString(_ raw: [UInt8]) -> String? {
        guard let format = raw.first else { return nil }
        let payload = Data(raw.dropFirst())
        switch format {
        case 0:
            return String(data: payload, encoding: .utf16LittleEndian)
        case 1:
            return String(data: payload, encoding: .isoLatin1)
        default:
            return nil
        }
    }

    /// Claude Desktop rewrites a session record as soon as a turn finishes or the
    /// session is shown. Only records whose modification date changed are decoded.
    func claudeSessions(
        reusing known: [String: ClaudeSessionSnapshot]) -> [String: ClaudeSessionSnapshot]
    {
        let root = self.claudeSupportDirectory
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
        var sessions: [String: ClaudeSessionSnapshot] = [:]
        for directory in Self.subdirectories(of: root).flatMap({ Self.subdirectories(of: $0) }) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                guard let modifiedAt = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate
                else {
                    continue
                }
                if let existing = sessions[id], existing.modifiedAt >= modifiedAt {
                    continue
                }
                if let cached = known[id], cached.modifiedAt == modifiedAt {
                    sessions[id] = cached
                } else if let data = try? Data(contentsOf: file),
                          let record = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data)
                {
                    sessions[id] = ClaudeSessionSnapshot(
                        completedTurns: record.completedTurns ?? 0,
                        lastFocusedAt: record.lastFocusedAt ?? 0,
                        isArchived: record.isArchived == true,
                        modifiedAt: modifiedAt,
                        title: record.title.flatMap(DesktopUnreadTurnReader.flattened),
                        workspacePath: record.cwd,
                        cliSessionID: record.cliSessionId,
                        lastActivityAt: record.lastActivityAt.map {
                            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
                        },
                        lastTurnEdgeAt: record.lastTurnEdgeAt.map {
                            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
                        },
                        startingSince: record.pendingFirstStart.map {
                            $0.since.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? modifiedAt
                        })
                }
            }
        }
        return sessions
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    // MARK: Antigravity

    func antigravityTranscriptURL(conversationID: String) -> URL? {
        guard !conversationID.isEmpty,
              !conversationID.contains("/"),
              !conversationID.contains("..")
        else {
            return nil
        }
        return self.antigravityHome
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(conversationID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl", isDirectory: false)
    }

    func antigravityConversationDatabaseURL(conversationID: String) -> URL? {
        guard !conversationID.isEmpty,
              !conversationID.contains("/"),
              !conversationID.contains("..")
        else {
            return nil
        }
        return self.antigravityHome
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent(conversationID + ".db", isDirectory: false)
    }

    /// Whether the step Antigravity created after `stepIndex` in `conversations/<id>.db`
    /// is still pending (`1`), running (`2`), or waiting for the user (`9`).
    func antigravityIsStepWaiting(conversationID: String, after stepIndex: Int?) -> Bool {
        guard let url = self.antigravityConversationDatabaseURL(conversationID: conversationID),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return true
        }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard Self.openReadonlySQLite(at: url, probeTable: "steps", into: &database) else {
            return true
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT status FROM steps WHERE idx > ? ORDER BY idx DESC LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return true
        }
        sqlite3_bind_int64(statement, 1, Int64(stepIndex ?? -1))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return true
        }
        let status = sqlite3_column_int64(statement, 0)
        return status == 1 || status == 2 || status == 9
    }

    /// Whether the last step recorded in `conversations/<id>.db` was cancelled (`6`)
    /// or interrupted (`12`) by the user.
    func antigravityIsLastStepCancelled(conversationID: String) -> Bool {
        guard let url = self.antigravityConversationDatabaseURL(conversationID: conversationID),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return false
        }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard Self.openReadonlySQLite(at: url, probeTable: "steps", into: &database) else {
            return false
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT status FROM steps ORDER BY idx DESC LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else {
            return false
        }
        let status = sqlite3_column_int64(statement, 0)
        return status == 6 || status == 12
    }

    /// Reads Antigravity's conversation summary database and per-conversation
    /// `.pbtxt` annotations, rolling subagent run state up to each root
    /// conversation the Hub sidebar displays.
    func antigravitySessions(
        reusingSessions knownSessions: [String: AntigravitySessionSnapshot] = [:],
        reusingAnnotations knownAnnotations: [String: AntigravityAnnotation])
        -> (
            sessions: [String: AntigravitySessionSnapshot],
            annotations: [String: AntigravityAnnotation],
            needsRetry: Bool
        )
    {
        let annotations = self.antigravityAnnotations(reusing: knownAnnotations)
        let databaseURL = self.antigravityHome.appendingPathComponent("conversation_summaries.db", isDirectory: false)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return ([:], annotations, false)
        }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard Self.openReadonlySQLite(at: databaseURL, probeTable: "conversation_summaries", into: &database) else {
            return (knownSessions, annotations, true)
        }

        let columns = Self.columnNames(of: "conversation_summaries", in: database)
        guard columns.contains("conversation_id") else {
            return (knownSessions, annotations, true)
        }
        func column(_ name: String) -> String {
            columns.contains(name) ? name : "NULL"
        }

        let archivedFromFTS = Self.antigravityArchivedIDs(in: database)
        let sql = """
            SELECT conversation_id, \(column("title")), \(column("preview")),
                   \(column("step_count")), \(column("last_modified_time")),
                   \(column("last_user_input_time")), \(column("workspace_uris")),
                   \(column("status")), \(column("agent_name")),
                   \(column("parent_conversation_id")), \(column("nesting_depth")),
                   \(column("not_fully_idle")), \(column("killed"))
            FROM conversation_summaries
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return (knownSessions, annotations, true)
        }

        struct RawSummary {
            let id: String
            let title: String?
            let preview: String?
            let stepCount: Int
            let lastModifiedAt: Date?
            let lastUserInputAt: Date?
            let workspacePath: String?
            let hasActiveRunStatus: Bool
            let agentName: String?
            let parentID: String?
            let nestingDepth: Int
            let notFullyIdle: Bool
            let isKilled: Bool
        }

        var rows: [String: RawSummary] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = Self.text(statement, 0) else { continue }
            let status = Self.text(statement, 7) ?? ""
            let hasActiveRunStatus = switch status {
            case "CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING":
                true
            default:
                false
            }
            rows[id] = RawSummary(
                id: id,
                title: Self.text(statement, 1).flatMap(DesktopUnreadTurnReader.flattened),
                preview: Self.text(statement, 2),
                stepCount: Int(sqlite3_column_int64(statement, 3)),
                lastModifiedAt: Self.text(statement, 4).flatMap(Self.antigravitySQLiteDate),
                lastUserInputAt: Self.text(statement, 5).flatMap(Self.antigravitySQLiteDate),
                workspacePath: Self.text(statement, 6).flatMap(Self.antigravityWorkspacePath),
                hasActiveRunStatus: hasActiveRunStatus,
                agentName: Self.text(statement, 8).flatMap(DesktopUnreadTurnReader.flattened),
                parentID: Self.text(statement, 9),
                nestingDepth: Int(sqlite3_column_int64(statement, 10)),
                notFullyIdle: sqlite3_column_int64(statement, 11) != 0,
                isKilled: sqlite3_column_int64(statement, 12) != 0)
        }

        var foregroundSubagents = Set<String>()
        var backgroundSubagents = Set<String>()
        var subagentActivities: [String: [String]] = [:]
        var subagentStartedAt: [String: Date] = [:]
        for row in rows.values where row.parentID != nil && !row.isKilled {
            guard row.hasActiveRunStatus || row.notFullyIdle else { continue }
            var current = row.id
            var hops = 0
            while let parent = rows[current]?.parentID, hops < 16 {
                current = parent
                hops += 1
            }
            guard current != row.id else { continue }
            if row.hasActiveRunStatus {
                foregroundSubagents.insert(current)
            } else {
                backgroundSubagents.insert(current)
            }
            if let startedAt = row.lastUserInputAt ?? row.lastModifiedAt {
                if let existing = subagentStartedAt[current] {
                    subagentStartedAt[current] = min(existing, startedAt)
                } else {
                    subagentStartedAt[current] = startedAt
                }
            }
            if let label = row.agentName ?? row.title {
                let text = "Subagent · \(label)"
                if subagentActivities[current]?.contains(text) != true {
                    subagentActivities[current, default: []].append(text)
                }
            }
        }

        var sessions: [String: AntigravitySessionSnapshot] = [:]
        for row in rows.values
            where row.parentID == nil
                && row.nestingDepth == 0
                && (row.stepCount > 0 || row.hasActiveRunStatus || row.notFullyIdle)
        {
            let annotation = annotations[row.id]
            let lastModifiedSeconds = row.lastModifiedAt.map { Int64(floor($0.timeIntervalSince1970)) } ?? 0
            sessions[row.id] = AntigravitySessionSnapshot(
                id: row.id,
                title: annotation?.title ?? row.title,
                preview: row.preview,
                workspacePath: row.workspacePath,
                lastModifiedAt: row.lastModifiedAt,
                lastModifiedSeconds: lastModifiedSeconds,
                lastUserInputAt: row.lastUserInputAt,
                lastUserViewAt: annotation?.lastUserViewAt,
                lastUserViewSeconds: annotation?.lastUserViewSeconds,
                lastUserViewMillis: annotation?.lastUserViewMillis,
                annotationModifiedAt: annotation?.modifiedAt,
                hasAnnotation: annotation != nil,
                markedAsUnread: annotation?.markedAsUnread == true,
                isArchived: archivedFromFTS.contains(row.id) || annotation?.isArchived == true,
                isKilled: row.isKilled,
                hasActiveRunStatus: row.hasActiveRunStatus,
                notFullyIdle: row.notFullyIdle,
                hasForegroundSubagents: foregroundSubagents.contains(row.id),
                hasBackgroundSubagents: backgroundSubagents.contains(row.id),
                subagentActivity: subagentActivities[row.id].map { $0.joined(separator: " · ") },
                subagentStartedAt: subagentStartedAt[row.id])
        }
        return (sessions, annotations, false)
    }

    private func antigravityAnnotations(
        reusing known: [String: AntigravityAnnotation]) -> [String: AntigravityAnnotation]
    {
        let directory = self.antigravityHome.appendingPathComponent("annotations", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        var annotations: [String: AntigravityAnnotation] = [:]
        for file in files where file.pathExtension == "pbtxt" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate,
                  (values.fileSize ?? .max) <= 256 * 1024
            else {
                continue
            }
            if let cached = known[id], cached.modifiedAt == modifiedAt {
                annotations[id] = cached
            } else if let data = try? Data(contentsOf: file),
                      let text = String(data: data, encoding: .utf8)
            {
                annotations[id] = Self.parseAntigravityAnnotation(text, modifiedAt: modifiedAt)
            }
        }
        return annotations
    }

    static func parseAntigravityAnnotation(_ text: String, modifiedAt: Date) -> AntigravityAnnotation {
        var title: String?
        if let match = text.firstMatch(of: #/(?:^|\s)title\s*:\s*"((?:\\.|[^"\\])*)"/#) {
            title = Self.unescapePbtxtString(String(match.output.1)).flatMap(DesktopUnreadTurnReader.flattened)
        }
        var lastUserViewSeconds: Int64?
        var lastUserViewMillis: Int64?
        var lastUserViewAt: Date?
        if let match = text.firstMatch(
            of: #/last_user_view_time\s*:\s*\{[^}]*\bseconds\s*:\s*(-?\d+)(?:\s+nanos\s*:\s*(-?\d+))?[^}]*\}/#)
        {
            if let seconds = Int64(match.output.1) {
                let nanos = match.output.2.flatMap { Int64($0) } ?? 0
                lastUserViewSeconds = seconds
                lastUserViewMillis = seconds * 1_000 + nanos / 1_000_000
                lastUserViewAt = Date(
                    timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
            }
        }
        let markedAsUnread = text.contains(#/marked_as_unread\s*:\s*true\b/#)
        let isArchived = text.contains(#/\barchived\s*:\s*true\b/#)
        return AntigravityAnnotation(
            modifiedAt: modifiedAt,
            title: title,
            lastUserViewSeconds: lastUserViewSeconds,
            lastUserViewMillis: lastUserViewMillis,
            lastUserViewAt: lastUserViewAt,
            markedAsUnread: markedAsUnread,
            isArchived: isArchived)
    }

    private static func unescapePbtxtString(_ escaped: String) -> String? {
        var bytes: [UInt8] = []
        var index = escaped.startIndex
        while index < escaped.endIndex {
            let char = escaped[index]
            guard char == "\\" else {
                bytes.append(contentsOf: String(char).utf8)
                index = escaped.index(after: index)
                continue
            }
            let next = escaped.index(after: index)
            guard next < escaped.endIndex else { break }
            let code = escaped[next]
            switch code {
            case "n":
                bytes.append(0x0A)
                index = escaped.index(after: next)
            case "r":
                bytes.append(0x0D)
                index = escaped.index(after: next)
            case "t":
                bytes.append(0x09)
                index = escaped.index(after: next)
            case "\"":
                bytes.append(0x22)
                index = escaped.index(after: next)
            case "'":
                bytes.append(0x27)
                index = escaped.index(after: next)
            case "\\":
                bytes.append(0x5C)
                index = escaped.index(after: next)
            case "0" ... "7":
                var end = next
                var count = 0
                while end < escaped.endIndex, ("0" ... "7").contains(escaped[end]), count < 3 {
                    end = escaped.index(after: end)
                    count += 1
                }
                if let value = UInt8(escaped[next ..< end], radix: 8) {
                    bytes.append(value)
                }
                index = end
            default:
                bytes.append(contentsOf: String(code).utf8)
                index = escaped.index(after: next)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func openReadonlySQLite(
        at url: URL,
        probeTable: String,
        into handle: inout OpaquePointer?) -> Bool
    {
        let openCode = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        if openCode == SQLITE_OK {
            sqlite3_busy_timeout(handle, 1000)
            if !self.columnNames(of: probeTable, in: handle).isEmpty {
                return true
            }
            let prepareCode = sqlite3_errcode(handle)
            sqlite3_close(handle)
            handle = nil
            // Only fall back to `immutable=1` when a sandbox blocks `-shm` access;
            // falling back on transient lock errors would hide fresh `-wal` frames.
            guard prepareCode == SQLITE_CANTOPEN || prepareCode == SQLITE_READONLY else {
                return false
            }
        } else {
            sqlite3_close(handle)
            handle = nil
            guard openCode == SQLITE_CANTOPEN || openCode == SQLITE_READONLY else {
                return false
            }
        }
        let immutableURI = url.absoluteString + "?immutable=1"
        guard sqlite3_open_v2(
            immutableURI,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            handle = nil
            return false
        }
        return true
    }

    private static func antigravityArchivedIDs(in database: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT DISTINCT conversation_id FROM conversations_fts WHERE archived != 0"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var ids = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = Self.text(statement, 0) {
                ids.insert(id)
            }
        }
        return ids
    }

    static func antigravitySQLiteDate(_ raw: String) -> Date? {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let space = normalized.firstIndex(of: " ") {
            normalized.replaceSubrange(space ... space, with: "T")
        }
        if let tIndex = normalized.firstIndex(of: "T") {
            let timePart = normalized[normalized.index(after: tIndex)...]
            if !timePart.hasSuffix("Z"),
               !timePart.hasSuffix("z"),
               !timePart.contains("+"),
               !timePart.contains("-")
            {
                normalized.append("Z")
            }
        }
        return (try? Date(normalized, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(normalized, strategy: Date.ISO8601FormatStyle()))
    }

    static func antigravityWorkspacePath(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let uris = try? JSONDecoder().decode([String].self, from: data),
              let first = uris.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty
        else {
            return nil
        }
        if let url = URL(string: first), url.isFileURL {
            return url.path.isEmpty ? nil : url.path
        }
        let stripped = first.hasPrefix("file://") ? String(first.dropFirst("file://".count)) : first
        return stripped.isEmpty ? nil : stripped
    }
}

enum ClaudeShownSession: Equatable, Sendable {
    case unknown
    case none
    case session(String)
}

/// Claude Desktop's or Antigravity's window started showing a session, or `nil` for anything else.
struct ClaudeFocusChange: Codable, Equatable, Sendable {
    let sessionID: String?
    let at: Date
}

struct ClaudeSessionSnapshot: Equatable, Sendable {
    let completedTurns: Int
    let lastFocusedAt: Int64
    let isArchived: Bool
    let modifiedAt: Date
    let title: String?
    let workspacePath: String?
    let cliSessionID: String?
    let lastActivityAt: Date?
    /// When the session last started or finished a turn.
    let lastTurnEdgeAt: Date?
    /// Claude is still setting up a new session, such as creating its
    /// worktree, and has not started its first turn or written a transcript.
    var startingSince: Date? = nil
}

struct AntigravityAnnotation: Equatable, Sendable {
    let modifiedAt: Date
    let title: String?
    let lastUserViewSeconds: Int64?
    let lastUserViewMillis: Int64?
    let lastUserViewAt: Date?
    let markedAsUnread: Bool
    let isArchived: Bool
}

struct AntigravitySessionSnapshot: Equatable, Sendable {
    let id: String
    let title: String?
    let preview: String?
    let workspacePath: String?
    let lastModifiedAt: Date?
    let lastModifiedSeconds: Int64
    let lastUserInputAt: Date?
    let lastUserViewAt: Date?
    let lastUserViewSeconds: Int64?
    var lastUserViewMillis: Int64? = nil
    var annotationModifiedAt: Date? = nil
    let hasAnnotation: Bool
    let markedAsUnread: Bool
    let isArchived: Bool
    let isKilled: Bool
    let hasActiveRunStatus: Bool
    let notFullyIdle: Bool
    let hasForegroundSubagents: Bool
    let hasBackgroundSubagents: Bool
    let subagentActivity: String?
    var subagentStartedAt: Date? = nil

    func focusAt(includingInput: Bool) -> Date? {
        let viewAt = self.lastUserViewAt ?? .distantPast
        let inputAt = includingInput ? (self.lastUserInputAt ?? .distantPast) : .distantPast
        let latest = max(viewAt, inputAt)
        return latest > .distantPast ? latest : nil
    }

    func focusMillis(includingInput: Bool) -> Int64 {
        let viewMillis = self.lastUserViewMillis
            ?? self.lastUserViewAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
            ?? 0
        guard includingInput else { return viewMillis }
        let inputMillis = self.lastUserInputAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0
        return max(viewMillis, inputMillis)
    }
}

/// Tracks Antigravity's unread conversations. Antigravity writes
/// `last_user_view_time` to `annotations/<id>.pbtxt` when switching views or
/// focusing its window, and suppresses unread in memory while the user stays in
/// the focused window watching the active conversation finish. Recording the
/// `lastModifiedSeconds` observed on that active conversation while Antigravity
/// is in front keeps it from flashing unread, without hiding turns that finish
/// in other conversations or while Antigravity is in the background.
struct AntigravityUnreadTracker {
    static let openSwitchLag: TimeInterval = 10
    static let focusHistoryLimit: TimeInterval = 4 * 60 * 60

    struct Progress: Codable, Equatable {
        var lastModifiedSeconds: Int64
        var isWorking: Bool
        var lastFocusMillis: Int64? = nil
    }

    struct State: Codable, Equatable {
        var progress: [String: Progress] = [:]
        var viewedSeconds: [String: Int64] = [:]
        /// `last_user_view_time` values (in milliseconds) written while the
        /// user did not actually view the conversation — such as when
        /// Antigravity rewrites the outgoing conversation's annotation while
        /// TokenBar switches the window to another conversation.
        var unseenViewMillis: [String: Int64] = [:]
        var waitingUnreadIDs: Set<String> = []
        var shownSessionID: String? = nil
        var focusChanges: [ClaudeFocusChange] = []

        init(
            progress: [String: Progress] = [:],
            viewedSeconds: [String: Int64] = [:],
            unseenViewMillis: [String: Int64] = [:],
            waitingUnreadIDs: Set<String> = [],
            shownSessionID: String? = nil,
            focusChanges: [ClaudeFocusChange] = [])
        {
            self.progress = progress
            self.viewedSeconds = viewedSeconds
            self.unseenViewMillis = unseenViewMillis
            self.waitingUnreadIDs = waitingUnreadIDs
            self.shownSessionID = shownSessionID
            self.focusChanges = focusChanges
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.progress = try container.decodeIfPresent([String: Progress].self, forKey: .progress) ?? [:]
            self.viewedSeconds = try container.decodeIfPresent([String: Int64].self, forKey: .viewedSeconds) ?? [:]
            self.unseenViewMillis = try container.decodeIfPresent([String: Int64].self, forKey: .unseenViewMillis) ?? [:]
            self.waitingUnreadIDs = try container.decodeIfPresent(Set<String>.self, forKey: .waitingUnreadIDs) ?? []
            self.shownSessionID = try container.decodeIfPresent(String.self, forKey: .shownSessionID)
            self.focusChanges = try container.decodeIfPresent([ClaudeFocusChange].self, forKey: .focusChanges) ?? []
        }
    }

    private struct PendingOpen: Equatable {
        let id: String
        let at: Date
        let atMillis: Int64
        let baselineViewMillis: Int64
        var switchedAtMillis: Int64?
    }

    private(set) var sessions: [String: AntigravitySessionSnapshot] = [:]
    private(set) var state: State
    private var hasBaseline: Bool
    private var pendingOpen: PendingOpen?
    private var waiting: Set<String> = []

    init(restoring state: State? = nil) {
        self.state = state ?? State()
        self.hasBaseline = state != nil
    }

    mutating func update(
        sessions: [String: AntigravitySessionSnapshot],
        foregroundRunningIDs: Set<String>,
        waiting: Set<String> = [],
        isAntigravityActive: Bool,
        now: Date) -> Set<String>
    {
        if let pending = self.pendingOpen {
            if now.timeIntervalSince(pending.at) >= Self.openSwitchLag {
                self.pendingOpen = nil
            } else if pending.switchedAtMillis == nil,
                      let targetViewMillis = sessions[pending.id]?.focusMillis(includingInput: false),
                      targetViewMillis > pending.baselineViewMillis
            {
                self.pendingOpen?.switchedAtMillis = targetViewMillis
            }
        }

        func isOpenSwitchSideEffect(id: String, viewMillis: Int64) -> Bool {
            guard let pending = self.pendingOpen,
                  pending.id != id,
                  now.timeIntervalSince(pending.at) < Self.openSwitchLag
            else {
                return false
            }
            if let switchedAt = pending.switchedAtMillis {
                return viewMillis <= switchedAt + 100
            }
            return viewMillis <= pending.atMillis + 3_000
        }

        if !self.hasBaseline {
            if self.state.shownSessionID == nil,
               let initial = Self.initialShownSession(in: sessions)
            {
                self.state.shownSessionID = initial.id
                if self.state.focusChanges.isEmpty {
                    self.state.focusChanges = [ClaudeFocusChange(sessionID: initial.id, at: initial.at)]
                }
            }
        } else {
            for (id, session) in sessions where !session.isArchived {
                let previousFocusMillis = self.state.progress[id]?.lastFocusMillis
                    ?? self.sessions[id]?.focusMillis(includingInput: true)
                    ?? 0
                let previousAnnotationSeconds: Int64 = if let unseen = self.state.unseenViewMillis[id],
                                                         previousFocusMillis <= unseen
                {
                    0
                } else {
                    previousFocusMillis / 1_000
                }
                let previousEffectiveViewed = max(
                    previousAnnotationSeconds,
                    self.state.viewedSeconds[id] ?? 0)
                let hadUnreadTurn = session.markedAsUnread
                    || session.lastModifiedSeconds > previousEffectiveViewed
                let currentViewMillis = session.focusMillis(includingInput: false)
                if hadUnreadTurn, currentViewMillis > previousFocusMillis {
                    let isWorking = foregroundRunningIDs.contains(id)
                    let turnAdvancedInBackground = !isAntigravityActive
                        && (self.state.progress[id].map { previous in
                            session.lastModifiedSeconds > previous.lastModifiedSeconds
                                || (previous.isWorking && !isWorking)
                        } ?? false)
                    if isOpenSwitchSideEffect(id: id, viewMillis: currentViewMillis) || turnAdvancedInBackground {
                        self.state.unseenViewMillis[id] = max(
                            self.state.unseenViewMillis[id] ?? 0,
                            currentViewMillis)
                    }
                }
            }

            let currentShownID = self.state.shownSessionID
            let pendingID = self.pendingOpen?.id
            let advancedCandidates = sessions.values.compactMap { session
                -> (id: String, at: Date, millis: Int64, previousMillis: Int64)? in
                guard !session.isArchived,
                      let at = session.focusAt(includingInput: isAntigravityActive)
                else {
                    return nil
                }
                let millis = session.focusMillis(includingInput: isAntigravityActive)
                let previousMillis = self.state.progress[session.id]?.lastFocusMillis
                    ?? self.sessions[session.id]?.focusMillis(includingInput: true)
                    ?? 0
                guard millis > previousMillis,
                      !isOpenSwitchSideEffect(id: session.id, viewMillis: millis)
                else {
                    return nil
                }
                return (session.id, at, millis, previousMillis)
            }
            if let nextShown = advancedCandidates.max(by: { lhs, rhs in
                let lhsIsPending = lhs.id == pendingID
                let rhsIsPending = rhs.id == pendingID
                if lhsIsPending != rhsIsPending {
                    return !lhsIsPending
                }
                let lhsIsSwitch = lhs.id != currentShownID
                let rhsIsSwitch = rhs.id != currentShownID
                if lhsIsSwitch != rhsIsSwitch {
                    return !lhsIsSwitch
                }
                if lhs.millis != rhs.millis {
                    return lhs.millis < rhs.millis
                }
                return lhs.previousMillis > rhs.previousMillis
            }) {
                self.recordFocusChange(to: nextShown.id, at: nextShown.at, now: now)
            }
        }

        let activeShownID = isAntigravityActive
            ? (self.state.shownSessionID ?? Self.initialShownSession(in: sessions)?.id)
            : nil
        for id in self.waiting.subtracting(waiting) where !foregroundRunningIDs.contains(id) {
            if let session = sessions[id], session.lastModifiedSeconds > 0 {
                self.state.viewedSeconds[id] = max(
                    self.state.viewedSeconds[id] ?? 0,
                    session.lastModifiedSeconds)
                self.state.unseenViewMillis.removeValue(forKey: id)
            }
        }
        for id in waiting.subtracting(self.waiting) where id != activeShownID {
            self.state.waitingUnreadIDs.insert(id)
        }
        self.state.waitingUnreadIDs.formIntersection(waiting)
        if let activeShownID {
            self.state.waitingUnreadIDs.remove(activeShownID)
        }

        if self.hasBaseline,
           isAntigravityActive,
           let shownID = activeShownID,
           let shown = sessions[shownID]
        {
            let isWorking = foregroundRunningIDs.contains(shownID)
            let advanced = self.state.progress[shownID].map { previous in
                shown.lastModifiedSeconds > previous.lastModifiedSeconds
                    || (previous.isWorking && !isWorking)
            } ?? true
            if !isWorking || advanced, shown.lastModifiedSeconds > 0 {
                self.state.viewedSeconds[shownID] = max(
                    self.state.viewedSeconds[shownID] ?? 0,
                    shown.lastModifiedSeconds)
                self.state.unseenViewMillis.removeValue(forKey: shownID)
            }
        }

        self.sessions = sessions
        self.waiting = waiting
        self.state.progress = Dictionary(uniqueKeysWithValues: sessions.map { id, session in
            (
                id,
                Progress(
                    lastModifiedSeconds: session.lastModifiedSeconds,
                    isWorking: foregroundRunningIDs.contains(id),
                    lastFocusMillis: session.focusMillis(includingInput: true))
            )
        })
        self.state.unseenViewMillis = self.state.unseenViewMillis.filter { id, unseen in
            guard let session = sessions[id], !session.isArchived else { return false }
            let viewMillis = session.focusMillis(includingInput: false)
            guard viewMillis > 0, viewMillis <= unseen else { return false }
            return (self.state.viewedSeconds[id] ?? 0) < session.lastModifiedSeconds
        }
        self.state.viewedSeconds = self.state.viewedSeconds.filter { id, viewed in
            guard let session = sessions[id], !session.isArchived else { return false }
            let annotationSeconds = Self.effectiveAnnotationViewSeconds(
                for: session,
                unseenViewMillis: self.state.unseenViewMillis[id])
            return annotationSeconds < viewed
        }
        self.state.focusChanges = self.state.focusChanges.filter {
            now.timeIntervalSince($0.at) < Self.focusHistoryLimit
        }
        self.hasBaseline = true

        return Set(sessions.compactMap { id, session -> String? in
            guard !session.isArchived else { return nil }
            if waiting.contains(id) || session.markedAsUnread || self.state.waitingUnreadIDs.contains(id) {
                return id
            }
            guard !foregroundRunningIDs.contains(id) else { return nil }
            if !session.hasAnnotation {
                guard let modifiedAt = session.lastModifiedAt,
                      now.timeIntervalSince(modifiedAt) < 7 * 24 * 60 * 60
                else {
                    return nil
                }
            }
            let annotationSeconds = Self.effectiveAnnotationViewSeconds(
                for: session,
                unseenViewMillis: self.state.unseenViewMillis[id])
            let viewed = max(annotationSeconds, self.state.viewedSeconds[id] ?? 0)
            return session.lastModifiedSeconds > viewed ? id : nil
        })
    }

    mutating func markViewed(id: String, at effectiveOpenedAt: Date, now: Date = Date()) {
        let effectiveSeconds = Int64(floor(effectiveOpenedAt.timeIntervalSince1970))
        let sessionModified = self.sessions[id]?.lastModifiedSeconds ?? 0
        self.state.viewedSeconds[id] = max(
            self.state.viewedSeconds[id] ?? 0,
            max(sessionModified, effectiveSeconds))
        self.state.unseenViewMillis.removeValue(forKey: id)
        self.state.waitingUnreadIDs.remove(id)
        let nowMillis = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let baselineViewMillis = self.sessions[id]?.focusMillis(includingInput: false) ?? 0
        self.pendingOpen = PendingOpen(
            id: id,
            at: now,
            atMillis: nowMillis,
            baselineViewMillis: baselineViewMillis,
            switchedAtMillis: nil)
        self.recordFocusChange(to: id, at: now, now: now, forceAppend: true)
    }

    mutating func markCancelledViewed(id: String, lastModifiedSeconds: Int64) {
        guard lastModifiedSeconds > 0 else { return }
        self.state.viewedSeconds[id] = max(self.state.viewedSeconds[id] ?? 0, lastModifiedSeconds)
        self.state.unseenViewMillis.removeValue(forKey: id)
        self.state.waitingUnreadIDs.remove(id)
    }

    private mutating func recordFocusChange(
        to sessionID: String,
        at: Date,
        now: Date,
        forceAppend: Bool = false)
    {
        let changed = self.state.shownSessionID != sessionID
        self.state.shownSessionID = sessionID
        guard changed || forceAppend || self.state.focusChanges.isEmpty else { return }
        self.state.focusChanges = self.state.focusChanges.filter {
            now.timeIntervalSince($0.at) < Self.focusHistoryLimit
        } + [ClaudeFocusChange(sessionID: sessionID, at: at)]
    }

    private static func effectiveAnnotationViewSeconds(
        for session: AntigravitySessionSnapshot,
        unseenViewMillis: Int64?) -> Int64
    {
        if let unseenViewMillis, session.focusMillis(includingInput: false) <= unseenViewMillis {
            return 0
        }
        return session.lastUserViewSeconds ?? 0
    }

    private static func initialShownSession(
        in sessions: [String: AntigravitySessionSnapshot]) -> (id: String, at: Date, millis: Int64)?
    {
        sessions.values
            .filter { !$0.isArchived }
            .compactMap { session -> (id: String, at: Date, millis: Int64, inputAt: Date, modifiedAt: Date)? in
                guard let at = session.focusAt(includingInput: true) else { return nil }
                return (
                    session.id,
                    at,
                    session.focusMillis(includingInput: true),
                    session.lastUserInputAt ?? .distantPast,
                    session.annotationModifiedAt ?? .distantPast
                )
            }
            .max {
                if $0.millis != $1.millis {
                    return $0.millis < $1.millis
                }
                if $0.inputAt != $1.inputAt {
                    return $0.inputAt < $1.inputAt
                }
                return $0.modifiedAt < $1.modifiedAt
            }
            .map { ($0.id, $0.at, $0.millis) }
    }
}

/// Combines Claude's lagging unread store with the session records the app writes
/// immediately. Like the Claude sidebar, a finished turn in a session other than
/// the one the window shows counts as unread, and showing a session counts as
/// read. Each guess lasts until the store agrees, Chromium commits the store after
/// the event, or it expires.
struct ClaudeUnreadTracker {
    struct Override: Codable, Equatable {
        var isUnread: Bool
        var since: Date
        /// For a turn the transcript shows ended: the turns Claude had recorded
        /// then. Claude records the turn and updates its store only after the
        /// session's stop hooks run, so until then the store cannot overrule it.
        var recordedTurns: Int?
        /// The turn ended in the session Claude's window showed while another
        /// app was in front. Claude counts that as read, so the session stays
        /// unread until Claude comes to the front on it or the user opens it.
        var untilSeen: Bool?
    }

    /// The parts of a session record whose changes are read or unread events.
    struct Progress: Codable, Equatable {
        var completedTurns: Int
        var lastFocusedAt: Int64
    }

    /// Kept across launches, so a guess the store has not caught up with and a
    /// turn that finished while TokenBar was not running still count.
    struct State: Codable, Equatable {
        var progress: [String: Progress] = [:]
        var overrides: [String: Override] = [:]
    }

    /// A commit this long after an event already includes it.
    static let storeCommitMargin: TimeInterval = 2
    /// Chromium can hold localStorage commits back for over a minute; this only
    /// bounds a guess the store never confirms or replaces.
    static let overrideLifetime: TimeInterval = 600

    private(set) var sessions: [String: ClaudeSessionSnapshot] = [:]
    private(set) var state: State
    private var hasBaseline: Bool
    /// Sessions whose turn waits for the user. Claude neither records such a
    /// turn nor marks the session unread, so a guess about one holds while it
    /// waits.
    private var waiting: Set<String> = []

    init(restoring state: State? = nil) {
        self.state = state ?? State()
        self.hasBaseline = state != nil
    }

    var nextExpiry: Date? {
        self.state.overrides
            .filter { !self.waiting.contains($0.key) && $0.value.untilSeen != true }
            .values.map { $0.since.addingTimeInterval(Self.overrideLifetime) }.min()
    }

    /// Returns the IDs of the sessions the sidebar shows as unread.
    /// `finishedTurns` are sessions whose transcript just finished a turn,
    /// which Claude records only after the session's stop hooks run, or paused
    /// it to wait for the user, which `waiting` lists. `isClaudeActive` tells
    /// whether Claude is the app in front.
    mutating func update(
        store: Set<String>,
        storeCommittedAt: Date,
        sessions: [String: ClaudeSessionSnapshot],
        finishedTurns: Set<String> = [],
        waiting: Set<String> = [],
        isClaudeActive: Bool = true,
        shownSession: () -> ClaudeShownSession,
        now: Date) -> Set<String>
    {
        if self.hasBaseline {
            self.recordEvents(
                in: sessions,
                finishedTurns: finishedTurns,
                isClaudeActive: isClaudeActive,
                shownSession: shownSession,
                now: now)
        }
        if isClaudeActive,
           self.state.overrides.values.contains(where: { $0.untilSeen == true }),
           case let .session(id) = shownSession(),
           self.state.overrides[id]?.untilSeen == true
        {
            self.state.overrides[id] = Override(isUnread: false, since: now)
        }
        self.sessions = sessions
        self.state.progress = sessions.mapValues {
            Progress(completedTurns: $0.completedTurns, lastFocusedAt: $0.lastFocusedAt)
        }
        self.hasBaseline = true
        self.waiting = waiting

        let overrides = self.state.overrides.filter { id, override in
            if override.untilSeen == true {
                return sessions[id] != nil
            }
            guard override.isUnread != store.contains(id) else { return false }
            if waiting.contains(id) {
                return true
            }
            guard now < override.since.addingTimeInterval(Self.overrideLifetime) else { return false }
            if let recordedTurns = override.recordedTurns,
               (sessions[id]?.completedTurns ?? .max) <= recordedTurns
            {
                return true
            }
            return storeCommittedAt <= override.since.addingTimeInterval(Self.storeCommitMargin)
        }
        self.state.overrides = overrides
        return store.union(overrides.keys).union(waiting).filter { id in
            guard let session = sessions[id], !session.isArchived else { return false }
            if waiting.contains(id) {
                return true
            }
            return overrides[id]?.isUnread ?? store.contains(id)
        }
    }

    private mutating func recordEvents(
        in sessions: [String: ClaudeSessionSnapshot],
        finishedTurns: Set<String>,
        isClaudeActive: Bool,
        shownSession: () -> ClaudeShownSession,
        now: Date)
    {
        let completedTurn = sessions.contains { id, session in
            session.completedTurns > (self.state.progress[id]?.completedTurns ?? .max)
        }
        // Without Claude's log, assume the window still shows the session
        // shown last.
        let shownID: String? = switch completedTurn || !finishedTurns.isEmpty ? shownSession() : .unknown {
        case let .session(id): id
        case .none: nil
        case .unknown:
            sessions
                .filter { !$0.value.isArchived }
                .max { $0.value.lastFocusedAt < $1.value.lastFocusedAt }?
                .key
        }
        for (id, session) in sessions {
            guard let previous = self.state.progress[id] else { continue }
            if session.lastFocusedAt > previous.lastFocusedAt {
                self.state.overrides[id] = Override(
                    isUnread: false,
                    since: Date(timeIntervalSince1970: TimeInterval(session.lastFocusedAt) / 1000))
            }
            let isUnseen = id == shownID && !isClaudeActive
            if session.completedTurns > previous.completedTurns {
                self.state.overrides[id] = Override(
                    isUnread: id != shownID || isUnseen,
                    since: session.modifiedAt,
                    untilSeen: isUnseen ? true : nil)
            } else if finishedTurns.contains(id) {
                self.state.overrides[id] = Override(
                    isUnread: id != shownID || isUnseen,
                    since: now,
                    recordedTurns: session.completedTurns,
                    untilSeen: isUnseen ? true : nil)
            }
        }
    }
}

/// Watches the Codex home and Claude support directories and recounts the
/// platform whose unread source changed. All mutable state stays on `queue`.
final class DesktopUnreadTaskWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TokenBar.DesktopUnreadTasks", qos: .utility)
    private let reader: DesktopUnreadTaskReader
    /// Running tasks are also rechecked on this interval, which catches an app
    /// that quit mid-turn and never wrote the turn's end.
    private static let runningRefreshInterval: TimeInterval = 60
    /// A turn appends to its rollout or transcript many times a second.
    private static let appendCoalescingDelay: TimeInterval = 0.3

    /// Publishes the unread tasks, the sessions that still exist unarchived
    /// when the platform tells, and focus changes when tracked by the watcher.
    private let publish: @Sendable (TokenPlatform, [DesktopUnreadTask], Set<String>?, [ClaudeFocusChange]?) -> Void
    private let publishRunning: @Sendable (TokenPlatform, [DesktopRunningTask]) -> Void
    private let claudeTrackerStateURL: URL?
    private let antigravityTrackerStateURL: URL?
    private let turns = DesktopUnreadTurnReader()
    private let codexTurnStates = CodexTurnStateReader()
    private let claudeBackgroundTasks = ClaudeBackgroundTaskReader()
    private let claudeActivities = ClaudeActivityReader()
    private let antigravityActivities = AntigravityActivityReader()
    private var stream: FSEventStreamRef?
    private var codexRootPrefix: String?
    private var codexPaths: Set<String> = []
    private var codexSessionsPrefix: String?
    private var backgroundTasksPrefix: String?
    private var claudePrefixes: [String] = []
    private var antigravitySummaryDBPath: String?
    private var antigravitySummaryProtoPath: String?
    private var antigravityAnnotationsPrefix: String?
    private var antigravityBrainPrefix: String?
    private var antigravityConversationsPrefix: String?
    private var claudeTracker = ClaudeUnreadTracker()
    private var savedClaudeTrackerState: ClaudeUnreadTracker.State?
    private var antigravityTracker = AntigravityUnreadTracker()
    private var savedAntigravityTrackerState: AntigravityUnreadTracker.State?
    private var antigravityAnnotations: [String: AntigravityAnnotation] = [:]
    private var claudeRecountScheduledAt: Date?
    private var claudeRereadScheduled = false
    private var codexStateRecountScheduled = false
    private var antigravityStateRecountScheduled = false
    private var antigravityRetryScheduled = false
    private var codexRunningIDs: Set<String> = []
    private var codexWaiting: [String: (question: String, askedAt: Date?)] = [:]
    private var claudeRunningIDs: Set<String> = []
    private var claudeWaiting: [String: String] = [:]
    private var claudeBackgroundIDs: Set<String> = []
    private var antigravityRunningIDs: Set<String> = []
    private var antigravityWaiting: [String: String] = [:]
    private var isClaudeActive = true
    private var isAntigravityActive = true
    private var claudeLaunch: DesktopUnreadTaskReader.ClaudeLaunch?
    private var antigravityLaunch: DesktopUnreadTaskReader.ClaudeLaunch?
    private lazy var codexRollouts = AppendedFileWatcher(queue: self.queue) { [weak self] in
        self?.scheduleAppendRecount(of: .codex)
    }
    private lazy var codexStateFiles = AppendedFileWatcher(queue: self.queue) { [weak self] in
        self?.scheduleCodexStateRecount()
    }
    private lazy var claudeTranscripts = AppendedFileWatcher(queue: self.queue) { [weak self] in
        self?.scheduleAppendRecount(of: .claude)
    }
    private lazy var antigravityTranscripts = AppendedFileWatcher(queue: self.queue) { [weak self] in
        self?.scheduleAppendRecount(of: .antigravity)
    }
    private lazy var antigravityStateFiles = AppendedFileWatcher(queue: self.queue) { [weak self] in
        self?.scheduleAntigravityStateRecount()
    }
    private var appendRecountsScheduled: Set<TokenPlatform> = []
    private var isStopped = false

    init(
        reader: DesktopUnreadTaskReader,
        claudeTrackerStateURL: URL?,
        antigravityTrackerStateURL: URL? = nil,
        publish: @escaping @Sendable (TokenPlatform, [DesktopUnreadTask], Set<String>?, [ClaudeFocusChange]?) -> Void,
        publishRunning: @escaping @Sendable (TokenPlatform, [DesktopRunningTask]) -> Void)
    {
        self.reader = reader
        self.claudeTrackerStateURL = claudeTrackerStateURL
        self.antigravityTrackerStateURL = antigravityTrackerStateURL
        self.publish = publish
        self.publishRunning = publishRunning
    }

    func start() {
        self.queue.async {
            self.restoreClaudeTracker()
            self.restoreAntigravityTracker()
            self.startStream()
            self.recountCodexRunning()
            self.recount(DesktopUnreadTaskReader.platforms)
            self.scheduleRunningRefresh()
        }
    }

    func stop() {
        self.queue.sync {
            self.isStopped = true
            self.codexRollouts.watch([])
            self.codexStateFiles.watch([])
            self.claudeTranscripts.watch([])
            self.antigravityTranscripts.watch([])
            self.antigravityStateFiles.watch([])
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func refresh() {
        self.queue.async {
            self.recount(DesktopUnreadTaskReader.platforms)
        }
    }

    func markAntigravityViewed(id: String, at now: Date) {
        self.queue.async {
            guard !self.isStopped else { return }
            self.antigravityTracker.markViewed(id: id, at: now)
            self.saveAntigravityTracker()
            self.recount([.antigravity])
        }
    }

    /// Claude coming to the front shows the user the session in its window.
    func setClaudeActive(_ isActive: Bool) {
        self.queue.async {
            guard isActive != self.isClaudeActive else { return }
            self.isClaudeActive = isActive
            if isActive, !self.isStopped {
                self.recount([.claude])
            }
        }
    }

    func setAntigravityActive(_ isActive: Bool) {
        self.queue.async {
            guard isActive != self.isAntigravityActive else { return }
            self.isAntigravityActive = isActive
            if isActive, !self.isStopped {
                self.recount([.antigravity])
            }
        }
    }

    private func startStream() {
        guard self.stream == nil else { return }
        var roots: [String] = []
        do {
            try FileManager.default.createDirectory(
                at: self.reader.backgroundTasksDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if let root = Self.canonicalPath(self.reader.backgroundTasksDirectory) {
                roots.append(root)
                self.backgroundTasksPrefix = root + "/"
            }
        } catch {
            NSLog("TokenBar could not watch background task snapshots: %@", String(describing: error))
        }
        if let codexRoot = Self.canonicalPath(self.reader.codexHome) {
            roots.append(codexRoot)
            self.codexRootPrefix = codexRoot + "/"
            self.codexPaths = [
                codexRoot + "/.codex-global-state.json",
                codexRoot + "/auth.json",
            ]
            self.codexSessionsPrefix = codexRoot + "/sessions/"
        }
        if let claudeRoot = Self.canonicalPath(self.reader.claudeSupportDirectory) {
            roots.append(claudeRoot)
            self.claudePrefixes = [
                claudeRoot + "/Local Storage/leveldb/",
                claudeRoot + "/claude-code-sessions/",
            ]
        }
        if let antigravityRoot = Self.canonicalPath(self.reader.antigravityHome) {
            roots.append(antigravityRoot)
            self.antigravitySummaryDBPath = antigravityRoot + "/conversation_summaries.db"
            self.antigravitySummaryProtoPath = antigravityRoot + "/agyhub_summaries_proto.pb"
            self.antigravityAnnotationsPrefix = antigravityRoot + "/annotations/"
            self.antigravityBrainPrefix = antigravityRoot + "/brain/"
            self.antigravityConversationsPrefix = antigravityRoot + "/conversations/"
        }
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<DesktopUnreadTaskWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<DesktopUnreadTaskWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DesktopUnreadTaskWatcher>.fromOpaque(info).takeUnretainedValue()
            let changedPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(changedPaths, flags: UnsafeBufferPointer(start: flags, count: count))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, self.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func handle(_ paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped)
        var changed = Set<TokenPlatform>()
        var codexRolloutChanged = false
        var antigravityTranscriptChanged = false
        for (index, path) in paths.enumerated() {
            if index < flags.count, flags[index] & rescanFlags != 0 {
                changed.formUnion(DesktopUnreadTaskReader.platforms)
                codexRolloutChanged = true
                antigravityTranscriptChanged = true
                break
            }
            if self.codexPaths.contains(path) {
                changed.insert(.codex)
            } else if let codexRoot = self.codexRootPrefix,
                      path.hasPrefix(codexRoot),
                      let name = path.dropFirst(codexRoot.count).split(separator: "/").first,
                      name.hasPrefix("state_"),
                      name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal")
            {
                changed.insert(.codex)
            } else if let prefix = self.codexSessionsPrefix, path.hasPrefix(prefix) {
                codexRolloutChanged = true
            } else if let prefix = self.backgroundTasksPrefix,
                      path.hasPrefix(prefix) || path == String(prefix.dropLast())
            {
                codexRolloutChanged = true
                antigravityTranscriptChanged = true
            } else if self.claudePrefixes.contains(where: { path.hasPrefix($0) }) {
                changed.insert(.claude)
            } else if let summaryDB = self.antigravitySummaryDBPath,
                      path == summaryDB || path.hasPrefix(summaryDB + "-")
            {
                changed.insert(.antigravity)
            } else if let summaryProto = self.antigravitySummaryProtoPath,
                      path == summaryProto
            {
                changed.insert(.antigravity)
            } else if let annotations = self.antigravityAnnotationsPrefix,
                      path.hasPrefix(annotations) || path == String(annotations.dropLast())
            {
                changed.insert(.antigravity)
            } else if let conversations = self.antigravityConversationsPrefix,
                      path.hasPrefix(conversations) || path == String(conversations.dropLast())
            {
                changed.insert(.antigravity)
            } else if let brain = self.antigravityBrainPrefix,
                      path.hasPrefix(brain),
                      path.hasSuffix("/transcript.jsonl") || path.hasSuffix("/transcript_full.jsonl")
            {
                antigravityTranscriptChanged = true
            }
        }
        self.recount(DesktopUnreadTaskReader.platforms.filter { changed.contains($0) })
        // Codex marks a thread unread as its turn ends, and a new thread
        // creates its rollout before the vnode watch covers it.
        if changed.contains(.codex) || codexRolloutChanged {
            self.recountCodexRunning()
        }
        if !changed.contains(.antigravity), antigravityTranscriptChanged {
            self.recountAntigravityRunning()
        }
        if changed.contains(.claude) {
            self.scheduleClaudeReread()
        }
    }

    /// A read can land while Chromium is still writing a LevelDB record and
    /// see the previous value, and the next write may be a minute away.
    private func scheduleClaudeReread() {
        guard !self.claudeRereadScheduled else { return }
        self.claudeRereadScheduled = true
        self.queue.asyncAfter(deadline: .now() + 2) {
            self.claudeRereadScheduled = false
            self.recount([.claude])
        }
    }

    private func scheduleCodexStateRecount() {
        guard !self.codexStateRecountScheduled else { return }
        self.codexStateRecountScheduled = true
        self.queue.asyncAfter(deadline: .now() + 0.25) {
            self.codexStateRecountScheduled = false
            self.recount([.codex])
        }
    }

    private func scheduleAntigravityStateRecount() {
        guard !self.antigravityStateRecountScheduled else { return }
        self.antigravityStateRecountScheduled = true
        self.queue.asyncAfter(deadline: .now() + 0.25) {
            self.antigravityStateRecountScheduled = false
            self.recount([.antigravity])
        }
    }

    private func scheduleAntigravityRetry() {
        guard !self.antigravityRetryScheduled else { return }
        self.antigravityRetryScheduled = true
        self.queue.asyncAfter(deadline: .now() + 0.5) {
            self.antigravityRetryScheduled = false
            self.recount([.antigravity])
        }
    }

    private func watchCodexStateFiles() {
        guard let dbURL = self.reader.codexStateDatabaseURL() else {
            self.codexStateFiles.watch([])
            return
        }
        let candidates = [dbURL.path, dbURL.path + "-wal"]
        self.codexStateFiles.watch(Set(candidates.filter { FileManager.default.fileExists(atPath: $0) }))
    }

    private func watchAntigravityStateFiles() {
        let candidates = [
            self.reader.antigravityHome.appendingPathComponent("conversation_summaries.db").path,
            self.reader.antigravityHome.appendingPathComponent("conversation_summaries.db-wal").path,
            self.reader.antigravityHome.appendingPathComponent("agyhub_summaries_proto.pb").path,
        ]
        self.antigravityStateFiles.watch(Set(candidates.filter { FileManager.default.fileExists(atPath: $0) }))
    }

    private func scheduleAppendRecount(of platform: TokenPlatform) {
        guard self.appendRecountsScheduled.insert(platform).inserted else { return }
        self.queue.asyncAfter(deadline: .now() + Self.appendCoalescingDelay) {
            self.appendRecountsScheduled.remove(platform)
            switch platform {
            case .codex:
                self.recountCodexRunning()
            case .claude:
                self.recountClaudeRunning()
            case .antigravity:
                self.recountAntigravityRunning()
            default:
                break
            }
        }
    }

    private func recount(_ platforms: [TokenPlatform]) {
        guard !self.isStopped else { return }
        for platform in platforms {
            switch platform {
            case .codex:
                self.watchCodexStateFiles()
                self.publish(
                    .codex,
                    self.reader.codexUnreadTasks(turns: self.turns, waiting: self.codexWaiting),
                    self.reader.visibleCodexThreadIDs(),
                    nil)
            case .claude:
                self.recountClaude(sessions: self.reader.claudeSessions(reusing: self.claudeTracker.sessions))
            case .antigravity:
                let (sessions, annotations, needsRetry) = self.reader.antigravitySessions(
                    reusingSessions: self.antigravityTracker.sessions,
                    reusingAnnotations: self.antigravityAnnotations)
                self.antigravityAnnotations = annotations
                self.watchAntigravityStateFiles()
                self.recountAntigravity(sessions: sessions)
                if needsRetry {
                    self.scheduleAntigravityRetry()
                }
            default:
                continue
            }
        }
    }

    /// A finished turn is when Codex notifies and marks the thread unread, so
    /// the unread state is read then and once more after Codex writes it.
    private func recountCodexRunning() {
        guard !self.isStopped else { return }
        let (running, waiting, rollouts) = self.reader.codexRunningTasks(
            states: self.codexTurnStates,
            waitingIDs: Set(self.codexWaiting.keys),
            now: Date())
        self.codexRollouts.watch(rollouts)
        let runningIDs = Set(running.map(\.id))
        let finishedTurn = !self.codexRunningIDs.subtracting(runningIDs).isEmpty
        let waitingChanged = waiting.count != self.codexWaiting.count
            || waiting.contains { key, value in
                guard let previous = self.codexWaiting[key] else { return true }
                return previous.question != value.question || previous.askedAt != value.askedAt
            }
        self.codexRunningIDs = runningIDs
        self.codexWaiting = waiting
        self.publishRunning(.codex, running)
        guard finishedTurn || waitingChanged else { return }
        self.recount([.codex])
        if finishedTurn {
            self.queue.asyncAfter(deadline: .now() + 1.5) {
                self.recount([.codex])
            }
        }
    }

    private func recountClaude(sessions: [String: ClaudeSessionSnapshot]) {
        let now = Date()
        let (running, waiting, transcripts) = self.claudeRunningTasks(sessions, now: now)
        let waitingIDs = Set(waiting.keys)
        let ids = self.claudeTracker.update(
            store: self.reader.claudeUnreadStore(),
            storeCommittedAt: self.reader.claudeStoreCommittedAt(),
            sessions: sessions,
            finishedTurns: self.claudeFinishedTurns(
                running: running,
                waiting: waitingIDs,
                transcripts: transcripts),
            waiting: waitingIDs,
            isClaudeActive: self.isClaudeActive,
            shownSession: self.reader.claudeShownSession,
            now: now)
        self.claudeTranscripts.watch(Set(transcripts.values.map(\.path)))
        self.claudeBackgroundTasks.forget(except: Set(transcripts.values.map(\.path)))
        self.claudeActivities.forget(except: Set(transcripts.values.map(\.path)))
        self.claudeRunningIDs = Set(running.map(\.id))
        self.claudeBackgroundIDs = Set(running.filter(\.isInBackground).map(\.id))
        self.claudeWaiting = waiting
        self.publish(
            .claude,
            self.claudeTasks(ids, waiting: waiting, sessions: sessions),
            Set(sessions.filter { !$0.value.isArchived }.keys),
            nil)
        self.publishRunning(.claude, running)
        self.saveClaudeTracker()
        self.scheduleClaudeExpiryRecount()
    }

    /// Transcripts change throughout a turn, so they are read against the
    /// session records already loaded, and the unread state is recounted only
    /// when a turn ends or starts or stops waiting for the user.
    private func recountClaudeRunning() {
        guard !self.isStopped else { return }
        let sessions = self.claudeTracker.sessions
        let (running, waiting, transcripts) = self.claudeRunningTasks(sessions, now: Date())
        guard self.claudeFinishedTurns(
            running: running,
            waiting: Set(waiting.keys),
            transcripts: transcripts).isEmpty,
            waiting == self.claudeWaiting
        else {
            self.recountClaude(sessions: sessions)
            return
        }
        self.claudeRunningIDs = Set(running.map(\.id))
        self.claudeBackgroundIDs = Set(running.filter(\.isInBackground).map(\.id))
        self.publishRunning(.claude, running)
    }

    /// Sessions that were running and whose transcript now ends their turn,
    /// unlike one that paused to wait for the user, went quiet, or was archived.
    private func claudeFinishedTurns(
        running: [DesktopRunningTask],
        waiting: Set<String>,
        transcripts: [String: URL]) -> Set<String>
    {
        self.claudeRunningIDs
            .subtracting(running.map(\.id))
            .subtracting(waiting)
            .filter { transcripts[$0] != nil }
    }

    private func scheduleRunningRefresh() {
        self.queue.asyncAfter(deadline: .now() + Self.runningRefreshInterval) {
            guard !self.isStopped else { return }
            self.recountCodexRunning()
            self.recountClaudeRunning()
            self.recountAntigravityRunning()
            self.scheduleRunningRefresh()
        }
    }

    private func recountAntigravity(sessions: [String: AntigravitySessionSnapshot]) {
        let now = Date()
        let (running, waiting, transcripts) = self.antigravityRunningTasks(sessions, now: now)
        let foregroundIDs = Set(running.filter { !$0.isInBackground }.map(\.id))
        var unreadIDs = self.antigravityTracker.update(
            sessions: sessions,
            foregroundRunningIDs: foregroundIDs,
            waiting: Set(waiting.keys),
            isAntigravityActive: self.isAntigravityActive,
            now: now)
        for id in Array(unreadIDs) where waiting[id] == nil && sessions[id]?.markedAsUnread != true {
            if self.reader.antigravityIsLastStepCancelled(conversationID: id) {
                self.antigravityTracker.markCancelledViewed(
                    id: id,
                    lastModifiedSeconds: sessions[id]?.lastModifiedSeconds ?? 0)
                unreadIDs.remove(id)
            }
        }
        let watchedPaths = Set(transcripts.values.map(\.path))
        self.antigravityTranscripts.watch(watchedPaths)
        self.antigravityActivities.forget(except: watchedPaths)
        self.antigravityRunningIDs = Set(running.map(\.id))
        self.antigravityWaiting = waiting
        self.publish(
            .antigravity,
            self.antigravityTasks(unreadIDs, waiting: waiting, sessions: sessions),
            Set(sessions.filter { !$0.value.isArchived }.keys),
            self.antigravityTracker.state.focusChanges)
        self.publishRunning(.antigravity, running)
        self.saveAntigravityTracker()
    }

    private func recountAntigravityRunning() {
        self.recount([.antigravity])
    }

    private func antigravityRunningTasks(
        _ sessions: [String: AntigravitySessionSnapshot],
        now: Date) -> (tasks: [DesktopRunningTask], waiting: [String: String], transcripts: [String: URL])
    {
        var waiting: [String: String] = [:]
        var transcripts: [String: URL] = [:]
        let externalBackground = CodexBackgroundTaskReader(directory: self.reader.backgroundTasksDirectory)
            .tasks(platform: TokenPlatform.antigravity.rawValue, now: now)
        self.antigravityLaunch = self.reader.antigravityLaunch(reusing: self.antigravityLaunch)
        let antigravityLaunchedAt = self.antigravityLaunch?.startedAt
        let isAppRunning = antigravityLaunchedAt != nil

        let tasks = sessions.compactMap { id, session -> DesktopRunningTask? in
            guard !session.isArchived else { return nil }
            let externalTask = externalBackground[id].map { task in
                DesktopRunningTask(
                    platform: .antigravity,
                    id: id,
                    title: session.title ?? task.name,
                    startedAt: task.startedAt,
                    activity: task.activity,
                    isInBackground: true,
                    isInterrupted: task.isInterrupted)
            }
            guard isAppRunning, !session.isKilled else {
                return externalTask
            }
            let wantsStatusCheck = session.hasActiveRunStatus
                || session.notFullyIdle
                || session.hasForegroundSubagents
                || session.hasBackgroundSubagents
                || self.antigravityWaiting[id] != nil
                || session.lastModifiedAt.map({ now.timeIntervalSince($0) < 6 * 60 * 60 }) == true
            guard wantsStatusCheck else {
                return externalTask
            }

            var transcriptActivity: String?
            var backgroundTask: (startedAt: Date, activity: String?)?
            var transcriptModifiedAt: Date?
            if let transcript = self.reader.antigravityTranscriptURL(conversationID: id),
               let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.path),
               let size = (attributes[.size] as? NSNumber)?.uint64Value,
               let modifiedAt = attributes[.modificationDate] as? Date
            {
                transcriptModifiedAt = modifiedAt
                if session.hasActiveRunStatus || session.notFullyIdle || session.hasForegroundSubagents
                    || session.hasBackgroundSubagents
                    || now.timeIntervalSince(modifiedAt) < DesktopRunningTaskLiveness.quietLimit
                {
                    transcripts[id] = transcript
                }
                if session.hasActiveRunStatus,
                   let candidate = self.turns.antigravityWaitingQuestion(
                       transcript: transcript,
                       size: size,
                       modifiedAt: modifiedAt),
                   self.reader.antigravityIsStepWaiting(
                       conversationID: id,
                       after: candidate.stepIndex)
                {
                    waiting[id] = candidate.question
                    return externalTask
                }
                if session.hasActiveRunStatus || session.notFullyIdle
                    || session.hasForegroundSubagents || session.hasBackgroundSubagents
                {
                    transcriptActivity = self.antigravityActivities.activity(in: transcript, size: size)
                }
                if session.notFullyIdle, let antigravityLaunchedAt {
                    backgroundTask = self.antigravityActivities.runningBackgroundTasks(
                        in: transcript,
                        size: size,
                        after: antigravityLaunchedAt)
                }
            }

            let latestActivityAt = max(
                session.lastModifiedAt ?? .distantPast,
                transcriptModifiedAt ?? .distantPast)
            if session.hasActiveRunStatus || session.hasForegroundSubagents,
               now.timeIntervalSince(latestActivityAt) < DesktopRunningTaskLiveness.quietLimit
            {
                return DesktopRunningTask(
                    platform: .antigravity,
                    id: id,
                    title: session.title,
                    startedAt: session.lastUserInputAt ?? session.lastModifiedAt,
                    activity: transcriptActivity ?? session.subagentActivity)
            }

            if session.notFullyIdle || session.hasBackgroundSubagents {
                let backgroundActivities = [
                    session.subagentActivity,
                    backgroundTask?.activity ?? (session.subagentActivity == nil ? transcriptActivity : nil),
                ].compactMap { $0 }
                return DesktopRunningTask(
                    platform: .antigravity,
                    id: id,
                    title: session.title,
                    startedAt: backgroundTask?.startedAt
                        ?? session.subagentStartedAt
                        ?? session.lastUserInputAt
                        ?? session.lastModifiedAt,
                    activity: backgroundActivities.isEmpty ? nil : backgroundActivities.joined(separator: " · "),
                    isInBackground: true)
            }

            return externalTask
        }.sorted {
            ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id)
        }
        return (tasks, waiting, transcripts)
    }

    private func antigravityTasks(
        _ ids: Set<String>,
        waiting: [String: String],
        sessions: [String: AntigravitySessionSnapshot]) -> [DesktopUnreadTask]
    {
        ids.compactMap { id -> DesktopUnreadTask? in
            guard let session = sessions[id] else { return nil }
            let turn = self.reader.antigravityTranscriptURL(conversationID: id).map {
                self.turns.antigravityTurn(transcriptURL: $0, fallbackPreview: session.preview)
            }
            return DesktopUnreadTask(
                platform: .antigravity,
                id: id,
                title: session.title,
                prompt: turn?.prompt,
                reply: turn?.reply,
                askQuestion: waiting[id],
                turnDuration: turn?.duration,
                workspacePath: session.workspacePath,
                updatedAt: session.lastModifiedAt)
        }.sorted {
            ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id)
        }
    }

    /// Claude Desktop records only when a session last started or finished a
    /// turn, so its transcript tells which one it was. A turn longer than the
    /// candidate window is still caught while its transcript keeps growing.
    /// A session whose turn ended runs while tasks it started in the
    /// background do. Also returns the sessions whose turn waits for the user;
    /// both are followed however long they wait. And returns the transcripts
    /// of recently active sessions, which a turn that starts or ends there
    /// writes to.
    private func claudeRunningTasks(
        _ sessions: [String: ClaudeSessionSnapshot],
        now: Date) -> (tasks: [DesktopRunningTask], waiting: [String: String], transcripts: [String: URL])
    {
        var waiting: [String: String] = [:]
        var transcripts: [String: URL] = [:]
        lazy var claudeLaunchedAt: Date? = {
            self.claudeLaunch = self.reader.claudeLaunch(reusing: self.claudeLaunch)
            return self.claudeLaunch?.startedAt
        }()
        let tasks = sessions.compactMap { id, session -> DesktopRunningTask? in
            // A new session runs while Claude sets it up, which can take
            // minutes for the worktree of a large repository.
            if let startingSince = session.startingSince {
                guard !session.isArchived, claudeLaunchedAt != nil else { return nil }
                return DesktopRunningTask(
                    platform: .claude,
                    id: id,
                    title: session.title,
                    startedAt: startingSince,
                    activity: "Starting")
            }
            guard !session.isArchived,
                  let edge = session.lastTurnEdgeAt ?? session.lastActivityAt,
                  now.timeIntervalSince(edge) < 6 * 60 * 60,
                  let transcript = session.cliSessionID.flatMap({
                      self.turns.claudeTranscriptURL(
                          cliSessionID: $0,
                          workspacePath: session.workspacePath,
                          activeAt: session.lastActivityAt,
                          projectsDirectory: self.reader.claudeProjectsDirectory)
                  }),
                  // The transcript URL is cached, and a URL caches its resource
                  // values, so its size and modification date come from the
                  // file system.
                  let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let activeAt = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(activeAt) < DesktopRunningTaskLiveness.quietLimit
                      || self.claudeWaiting[id] != nil
                      || self.claudeBackgroundIDs.contains(id)
            else {
                return nil
            }
            transcripts[id] = transcript
            switch self.turns.claudeTurnState(transcript: transcript, size: size, modifiedAt: activeAt) {
            case .running:
                return DesktopRunningTask(
                    platform: .claude,
                    id: id,
                    title: session.title,
                    startedAt: session.lastTurnEdgeAt,
                    activity: self.claudeActivities.activity(in: transcript, size: size))
            case let .waitingForUser(question):
                waiting[id] = question
                return nil
            case .ended:
                guard let claudeLaunchedAt,
                      let background = self.claudeBackgroundTasks.runningTasks(
                          in: transcript,
                          size: size,
                          after: claudeLaunchedAt)
                else {
                    return nil
                }
                return DesktopRunningTask(
                    platform: .claude,
                    id: id,
                    title: session.title,
                    startedAt: background.startedAt,
                    activity: background.activity,
                    isInBackground: true)
            }
        }.sorted {
            ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id)
        }
        return (tasks, waiting, transcripts)
    }

    private func claudeTasks(
        _ ids: Set<String>,
        waiting: [String: String],
        sessions: [String: ClaudeSessionSnapshot]) -> [DesktopUnreadTask]
    {
        ids.compactMap { id -> DesktopUnreadTask? in
            guard let session = sessions[id] else { return nil }
            let turn = session.cliSessionID.map {
                self.turns.claudeTurn(
                    cliSessionID: $0,
                    workspacePath: session.workspacePath,
                    activeAt: session.lastActivityAt,
                    projectsDirectory: self.reader.claudeProjectsDirectory)
            }
            return DesktopUnreadTask(
                platform: .claude,
                id: id,
                title: session.title,
                prompt: turn?.prompt,
                reply: turn?.reply,
                askQuestion: waiting[id],
                turnDuration: turn?.duration,
                workspacePath: session.workspacePath,
                updatedAt: session.lastActivityAt ?? session.modifiedAt)
        }.sorted {
            ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id)
        }
    }

    private func scheduleClaudeExpiryRecount() {
        guard let expiry = self.claudeTracker.nextExpiry,
              self.claudeRecountScheduledAt.map({ expiry < $0 }) ?? true
        else {
            return
        }
        self.claudeRecountScheduledAt = expiry
        self.queue.asyncAfter(deadline: .now() + max(0, expiry.timeIntervalSinceNow) + 0.1) {
            self.claudeRecountScheduledAt = nil
            self.recount([.claude])
        }
    }

    private func restoreClaudeTracker() {
        guard let url = self.claudeTrackerStateURL,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ClaudeUnreadTracker.State.self, from: data)
        else {
            return
        }
        self.claudeTracker = ClaudeUnreadTracker(restoring: state)
        self.savedClaudeTrackerState = state
    }

    private func saveClaudeTracker() {
        guard let url = self.claudeTrackerStateURL,
              self.claudeTracker.state != self.savedClaudeTrackerState
        else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(self.claudeTracker.state).write(to: url, options: [.atomic])
            self.savedClaudeTrackerState = self.claudeTracker.state
        } catch {
            NSLog("TokenBar could not save the Claude unread state: %@", String(describing: error))
        }
    }

    private func restoreAntigravityTracker() {
        guard let url = self.antigravityTrackerStateURL,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(AntigravityUnreadTracker.State.self, from: data)
        else {
            return
        }
        self.antigravityTracker = AntigravityUnreadTracker(restoring: state)
        self.savedAntigravityTrackerState = state
    }

    private func saveAntigravityTracker() {
        guard let url = self.antigravityTrackerStateURL,
              self.antigravityTracker.state != self.savedAntigravityTrackerState
        else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(self.antigravityTracker.state).write(to: url, options: [.atomic])
            self.savedAntigravityTrackerState = self.antigravityTracker.state
        } catch {
            NSLog("TokenBar could not save the Antigravity unread state: %@", String(describing: error))
        }
    }

    private static func canonicalPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Watches files that an app appends to while keeping them open, such as Codex
/// rollouts. FSEvents reports those writes only once the file is closed, while a
/// vnode source sees each one.
final class AppendedFileWatcher {
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]

    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    /// Watches exactly `paths`. Call on `queue`.
    func watch(_ paths: Set<String>) {
        for (path, source) in self.sources where !paths.contains(path) {
            source.cancel()
            self.sources[path] = nil
        }
        for path in paths where self.sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename],
                queue: self.queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                // A replaced file is watched again by path on the next call.
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    source.cancel()
                    self.sources[path] = nil
                }
                self.onChange()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            self.sources[path] = source
        }
    }
}
