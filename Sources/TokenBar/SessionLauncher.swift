import AppKit
import Foundation
import TokenBarCore

enum SessionLauncherError: LocalizedError {
    case invalidSessionID
    case unsupportedPlatform(TokenPlatform)
    case applicationUnavailable(TokenPlatform)

    var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            "The session does not have a valid identifier."
        case let .unsupportedPlatform(platform):
            "Opening \(platform.displayName) sessions is not supported."
        case let .applicationUnavailable(platform):
            "macOS could not open this session in the \(platform.displayName) app."
        }
    }
}

@MainActor
struct SessionLauncher {
    private let openURL: (URL) -> Bool
    private let resolveClaudeDesktopSessionID: (String) -> String?

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        resolveClaudeDesktopSessionID: @escaping (String) -> String? = {
            ClaudeDesktopSessionResolver().desktopSessionID(for: $0)
        })
    {
        self.openURL = openURL
        self.resolveClaudeDesktopSessionID = resolveClaudeDesktopSessionID
    }

    func open(_ session: SessionSummary) throws {
        let claudeDesktopSessionID = session.platformID == .claude
            ? self.resolveClaudeDesktopSessionID(session.id)
            : nil
        let url = try Self.deepLink(
            for: session,
            claudeDesktopSessionID: claudeDesktopSessionID)
        guard self.openURL(url) else {
            throw SessionLauncherError.applicationUnavailable(session.platformID)
        }
    }

    static func deepLink(
        for session: SessionSummary,
        claudeDesktopSessionID: String? = nil) throws -> URL
    {
        let sessionID = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty,
              !sessionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw SessionLauncherError.invalidSessionID
        }

        var components = URLComponents()
        switch session.platformID {
        case .codex:
            guard let threadID = self.codexThreadID(from: sessionID) else {
                throw SessionLauncherError.invalidSessionID
            }
            components.scheme = "codex"
            components.host = "threads"
            components.path = "/\(threadID)"
        case .claude:
            components.scheme = "claude"
            components.host = "claude.ai"
            if let desktopSessionID = claudeDesktopSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            {
                guard Self.isSafePathIdentifier(desktopSessionID) else {
                    throw SessionLauncherError.invalidSessionID
                }
                components.path = "/claude-code-desktop/\(desktopSessionID)"
            } else {
                components.path = "/local_sessions"
            }
        default:
            throw SessionLauncherError.unsupportedPlatform(session.platformID)
        }

        guard let url = components.url else {
            throw SessionLauncherError.invalidSessionID
        }
        return url
    }

    private static func codexThreadID(from sessionID: String) -> String? {
        if UUID(uuidString: sessionID) != nil {
            return sessionID
        }
        guard sessionID.count >= 36 else { return nil }
        let suffix = String(sessionID.suffix(36))
        return UUID(uuidString: suffix) == nil ? nil : suffix
    }

    private static func isSafePathIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }
}

struct ClaudeDesktopSessionResolver {
    private struct Record: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let title: String?
        let completedTurns: Int?
        let lastActivityAt: Int64?
        let createdAt: Int64?
        let isArchived: Bool?

        var hasTitle: Bool {
            !(self.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        var isResumeImportAlias: Bool {
            self.cliSessionId.map { self.sessionId == "local_\($0)" } ?? false
        }
    }

    private let sessionsRoot: URL

    init(sessionsRoot: URL = Self.defaultSessionsRoot()) {
        self.sessionsRoot = sessionsRoot
    }

    func desktopSessionID(for cliSessionID: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: self.sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        var matches: [Record] = []
        for case let fileURL as URL in enumerator
            where fileURL.pathExtension == "json"
        {
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.cliSessionId == cliSessionID,
                  Self.isSafeSessionID(record.sessionId)
            else {
                continue
            }
            matches.append(record)
        }

        return matches.sorted(by: Self.isPreferred).first?.sessionId
    }

    private static func isPreferred(_ lhs: Record, _ rhs: Record) -> Bool {
        let lhsActive = lhs.isArchived != true
        let rhsActive = rhs.isArchived != true
        if lhsActive != rhsActive {
            return lhsActive
        }
        if lhs.isResumeImportAlias != rhs.isResumeImportAlias {
            return !lhs.isResumeImportAlias
        }
        if lhs.hasTitle != rhs.hasTitle {
            return lhs.hasTitle
        }
        let lhsTurns = lhs.completedTurns ?? 0
        let rhsTurns = rhs.completedTurns ?? 0
        if lhsTurns != rhsTurns {
            return lhsTurns > rhsTurns
        }
        let lhsActivity = lhs.lastActivityAt ?? 0
        let rhsActivity = rhs.lastActivityAt ?? 0
        if lhsActivity != rhsActivity {
            return lhsActivity > rhsActivity
        }
        return (lhs.createdAt ?? .max) < (rhs.createdAt ?? .max)
    }

    private static func isSafeSessionID(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }

    private static func defaultSessionsRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
    }
}
