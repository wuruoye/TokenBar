import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

@MainActor
@Suite("Session launcher")
struct SessionLauncherTests {
    @Test("builds a Codex desktop thread deep link")
    func codexDeepLink() throws {
        let url = try SessionLauncher.deepLink(for: self.session(
            id: "019f9344-f590-78d0-868f-903feede981f",
            platform: .codex))

        #expect(url.absoluteString == "codex://threads/019f9344-f590-78d0-868f-903feede981f")
    }

    @Test("extracts the Codex thread UUID from a rollout identifier")
    func codexRolloutDeepLink() throws {
        let url = try SessionLauncher.deepLink(for: self.session(
            id: "rollout-2026-07-24T16-36-37-019f9344-f590-78d0-868f-903feede981f",
            platform: .codex))

        #expect(url.absoluteString == "codex://threads/019f9344-f590-78d0-868f-903feede981f")
    }

    @Test("builds a Claude desktop session deep link without importing it")
    func claudeDeepLink() throws {
        let url = try SessionLauncher.deepLink(for: self.session(
            id: "019f9344-f590-78d0-868f-903feede981f",
            platform: .claude),
            claudeDesktopSessionID: "local_c4cfef91-6808-49af-aa67-e7a01512afca")

        #expect(
            url.absoluteString
                == "claude://claude.ai/claude-code-desktop/local_c4cfef91-6808-49af-aa67-e7a01512afca")
    }

    @Test("falls back to Claude local sessions without importing an unindexed CLI session")
    func claudeLocalSessionsFallback() throws {
        let url = try SessionLauncher.deepLink(for: self.session(
            id: "019f9344-f590-78d0-868f-903feede981f",
            platform: .claude))

        #expect(url.absoluteString == "claude://claude.ai/local_sessions")
    }

    @Test("opens the desktop deep link")
    func opensDesktopDeepLink() throws {
        var openedURL: URL?
        let launcher = SessionLauncher {
            openedURL = $0
            return true
        }

        try launcher.open(self.session(
            id: "019f9344-f590-78d0-868f-903feede981f",
            platform: .codex))

        #expect(
            openedURL?.absoluteString
                == "codex://threads/019f9344-f590-78d0-868f-903feede981f")
    }

    @Test("resolves a Claude CLI session to the best existing desktop session")
    func resolvesClaudeDesktopSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBarClaudeSessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let cliID = "019f9344-f590-78d0-868f-903feede981f"
        let duplicate = directory.appendingPathComponent("duplicate.json")
        let existing = directory.appendingPathComponent("existing.json")
        try Data(
            """
            {"sessionId":"local_\(cliID)","cliSessionId":"\(cliID)","title":"General coding session","completedTurns":10,"createdAt":20}
            """.utf8).write(to: duplicate)
        try Data(
            """
            {"sessionId":"local_existing","cliSessionId":"\(cliID)","title":"Existing thread","completedTurns":4,"createdAt":10}
            """.utf8).write(to: existing)

        let resolved = ClaudeDesktopSessionResolver(sessionsRoot: directory)
            .desktopSessionID(for: cliID)

        #expect(resolved == "local_existing")
    }

    @Test("opening Claude resolves an existing desktop session")
    func opensResolvedClaudeSession() throws {
        var openedURL: URL?
        let launcher = SessionLauncher(
            openURL: {
                openedURL = $0
                return true
            },
            resolveClaudeDesktopSessionID: { _ in "local_existing" })

        try launcher.open(self.session(
            id: "019f9344-f590-78d0-868f-903feede981f",
            platform: .claude))

        #expect(
            openedURL?.absoluteString
                == "claude://claude.ai/claude-code-desktop/local_existing")
    }

    @Test("opening Grok resumes the local session in its workspace")
    func opensGrokSession() throws {
        var launchedSession: SessionSummary?
        let launcher = SessionLauncher(
            launchGrokSession: {
                launchedSession = $0
                return true
            })
        let session = SessionSummary(
            id: "019f9344-f590-78d0-868f-903feede981f",
            workspaceLabel: "TokenBar",
            startedAtMs: 0,
            endedAtMs: 1,
            tokens: .zero,
            costUsd: 0,
            models: [],
            requests: [],
            workspacePath: "/tmp/TokenBar",
            platform: .grok)

        try launcher.open(session)

        #expect(launchedSession == session)
    }

    @Test("opening Antigravity reopens the recorded workspace folder")
    func opensAntigravityWorkspace() throws {
        var openedWorkspace: String?
        let launcher = SessionLauncher(
            launchAntigravityWorkspace: {
                openedWorkspace = $0
                return true
            })

        try launcher.open(SessionSummary(
            id: "96d309be-7ede-4c0d-8b01-f2b6bf6fd48e",
            workspaceLabel: "TokenBar",
            startedAtMs: 0,
            endedAtMs: 1,
            tokens: .zero,
            costUsd: 0,
            models: [],
            requests: [],
            workspacePath: "/tmp/TokenBar",
            platform: .antigravity))

        #expect(openedWorkspace == "/tmp/TokenBar")
    }

    @Test("an Antigravity session without a workspace reports why it cannot open")
    func antigravitySessionWithoutWorkspace() {
        let launcher = SessionLauncher(launchAntigravityWorkspace: { _ in true })

        #expect(throws: SessionLauncherError.self) {
            try launcher.open(self.session(
                id: "96d309be-7ede-4c0d-8b01-f2b6bf6fd48e",
                platform: .antigravity))
        }
    }

    private func session(
        id: String,
        platform: TokenPlatform) -> SessionSummary
    {
        SessionSummary(
            id: id,
            workspaceLabel: "TokenBar",
            startedAtMs: 0,
            endedAtMs: 1,
            tokens: .zero,
            costUsd: 0,
            models: [],
            requests: [],
            platform: platform)
    }
}
