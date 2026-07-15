import Foundation
import Testing
@testable import TokenBarCore
#if canImport(Darwin)
import Darwin
#endif

private struct StubRateLimitsRequester: CodexRateLimitsRequesting {
    let result: Result<Data, any Error & Sendable>

    func fetchRateLimitsResult() async throws -> Data {
        try self.result.get()
    }
}

private actor LoginPathCaptureCounter {
    private(set) var count = 0
    let paths: [String]

    init(paths: [String]) {
        self.paths = paths
    }

    func capture(_: [String: String]) -> [String] {
        self.count += 1
        return self.paths
    }
}

@Suite("Codex app-server quota client")
struct CodexAppServerQuotaClientTests {
    @Test("performs the initialize notification and rate-limit request over JSON lines")
    func appServerWireRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        let rpcLog = directory.appendingPathComponent("rpc.jsonl")
        let script = Data(
            """
            #!/bin/sh
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> "$TOKENBAR_RPC_LOG"
              case "$line" in
                *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
                *'"id":2'*) printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1800000300},"secondary":null}}}' ;;
              esac
            done
            """.utf8)
        try script.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CodexAppServerQuotaClient(
            environment: [
                "CODEX_CLI_PATH": executable.path,
                "PATH": "/usr/bin:/bin",
                "TOKENBAR_RPC_LOG": rpcLog.path,
            ])

        let snapshot = try await client.fetchQuota()

        #expect(snapshot.session?.usedPercent == 7)
        #expect(snapshot.session?.windowMinutes == 300)
        #expect(snapshot.weekly == nil)

        let messages = try String(contentsOf: rpcLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { line in
                try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        #expect(messages.count == 3)
        #expect(messages[0]["method"] as? String == "initialize")
        let initializeParams = try #require(messages[0]["params"] as? [String: Any])
        let clientInfo = try #require(initializeParams["clientInfo"] as? [String: String])
        #expect(clientInfo["name"] == "tokenbar")
        #expect(messages[1]["method"] as? String == "initialized")
        #expect(messages[1]["id"] == nil)
        #expect(messages[2]["method"] as? String == "account/rateLimits/read")
        #expect(messages[2]["id"] as? Int == 2)
    }

    @Test("maps app-server primary and secondary windows")
    func mapsWindows() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let requester = StubRateLimitsRequester(result: .success(Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 25.5,
                  "windowDurationMins": 300,
                  "resetsAt": 1800000300
                },
                "secondary": {
                  "usedPercent": 40,
                  "windowDurationMins": 10080,
                  "resetsAt": 1800604800
                }
              }
            }
            """.utf8)))
        let client = CodexAppServerQuotaClient(requester: requester, now: { now })

        let snapshot = try await client.fetchQuota()

        #expect(snapshot.session?.usedPercent == 25.5)
        #expect(snapshot.session?.windowMinutes == 300)
        #expect(snapshot.session?.resetsAt == Date(timeIntervalSince1970: 1_800_000_300))
        #expect(snapshot.weekly?.usedPercent == 40)
        #expect(snapshot.weekly?.windowMinutes == 10_080)
        #expect(snapshot.updatedAt == now)
    }

    @Test("accepts snake-case quota fields and a missing 5-hour window")
    func acceptsSnakeCaseAndMissingSession() async throws {
        let requester = StubRateLimitsRequester(result: .success(Data(
            """
            {
              "rateLimits": {
                "primary": null,
                "secondary": {
                  "used_percent": 12,
                  "window_duration_mins": 10080,
                  "resets_at": 1800604800
                }
              }
            }
            """.utf8)))
        let client = CodexAppServerQuotaClient(requester: requester)

        let snapshot = try await client.fetchQuota()

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.usedPercent == 12)
    }

    @Test("classifies a lone primary seven-day window as weekly")
    func classifiesPrimaryWeeklyOnly() async throws {
        let requester = StubRateLimitsRequester(result: .success(Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 3,
                  "windowDurationMins": 10080,
                  "resetsAt": 1800597600
                },
                "secondary": null
              }
            }
            """.utf8)))

        let snapshot = try await CodexAppServerQuotaClient(requester: requester).fetchQuota()

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.usedPercent == 3)
        #expect(snapshot.weekly?.remainingPercent == 97)
        #expect(snapshot.weekly?.windowMinutes == 10_080)
        #expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1_800_597_600))
    }

    @Test("classifies reversed app-server windows by duration")
    func classifiesReversedWindows() async throws {
        let requester = StubRateLimitsRequester(result: .success(Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 3,
                  "windowDurationMins": 10080,
                  "resetsAt": 1800597600
                },
                "secondary": {
                  "usedPercent": 40,
                  "windowDurationMins": 300,
                  "resetsAt": 1800000300
                }
              }
            }
            """.utf8)))

        let snapshot = try await CodexAppServerQuotaClient(requester: requester).fetchQuota()

        #expect(snapshot.session?.usedPercent == 40)
        #expect(snapshot.session?.windowMinutes == 300)
        #expect(snapshot.weekly?.usedPercent == 3)
        #expect(snapshot.weekly?.windowMinutes == 10_080)
    }

    @Test("keeps positional fallback for unknown window durations")
    func keepsUnknownDurationFallback() async throws {
        let requester = StubRateLimitsRequester(result: .success(Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 10,
                  "windowDurationMins": 540
                },
                "secondary": {
                  "usedPercent": 20,
                  "windowDurationMins": 1440
                }
              }
            }
            """.utf8)))

        let snapshot = try await CodexAppServerQuotaClient(requester: requester).fetchQuota()

        #expect(snapshot.session?.usedPercent == 10)
        #expect(snapshot.session?.windowMinutes == 540)
        #expect(snapshot.weekly?.usedPercent == 20)
        #expect(snapshot.weekly?.windowMinutes == 1_440)
    }

    @Test("keeps a valid weekly lane when the 5-hour lane is malformed")
    func toleratesOneMalformedLane() async throws {
        let requester = StubRateLimitsRequester(result: .success(Data(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": "invalid"},
                "secondary": {
                  "usedPercent": 34,
                  "windowDurationMins": 10080,
                  "resetsAt": 1800604800
                }
              }
            }
            """.utf8)))

        let snapshot = try await CodexAppServerQuotaClient(requester: requester).fetchQuota()

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.usedPercent == 34)
        #expect(snapshot.weekly?.windowMinutes == 10_080)
    }

    @Test("recovers quota windows from a Codex RPC decode-error body")
    func recoversRateLimitErrorBody() async throws {
        let requester = StubRateLimitsRequester(result: .failure(
            CodexAppServerError.requestFailed(Self.decodeMismatchBodyMessage)))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = try await CodexAppServerQuotaClient(
            requester: requester,
            now: { now }).fetchQuota()

        #expect(snapshot.session?.usedPercent == 4)
        #expect(snapshot.session?.windowMinutes == 300)
        #expect(snapshot.session?.resetsAt == Date(timeIntervalSince1970: 1_776_216_359))
        #expect(snapshot.weekly?.usedPercent == 19)
        #expect(snapshot.weekly?.windowMinutes == 10_080)
        #expect(snapshot.updatedAt == now)
    }

    @Test("classifies a recovered primary seven-day window as weekly")
    func recoversPrimaryWeeklyOnly() async throws {
        let message = """
        failed to fetch codex rate limits: Decode error; body={
          "rate_limit": {
            "primary_window": {
              "used_percent": 3,
              "limit_window_seconds": 604800,
              "reset_at": 1800597600
            },
            "secondary_window": null
          }
        }
        """
        let requester = StubRateLimitsRequester(result: .failure(
            CodexAppServerError.requestFailed(message)))

        let snapshot = try await CodexAppServerQuotaClient(requester: requester).fetchQuota()

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.usedPercent == 3)
        #expect(snapshot.weekly?.remainingPercent == 97)
        #expect(snapshot.weekly?.windowMinutes == 10_080)
    }

    @Test("rejects a response with no quota windows")
    func rejectsMissingWindows() async {
        let requester = StubRateLimitsRequester(result: .success(Data(
            #"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8)))
        let client = CodexAppServerQuotaClient(requester: requester)

        await #expect(throws: CodexQuotaServiceError.self) {
            _ = try await client.fetchQuota()
        }
    }

    @Test("wire parser ignores notifications and unrelated response ids")
    func wireParserRoutesByID() throws {
        let notification = Data(#"{"method":"account/updated","params":{}}"#.utf8)
        let unrelated = Data(#"{"id":8,"result":{"value":8}}"#.utf8)
        let matching = Data(#"{"id":9,"result":{"value":9}}"#.utf8)

        #expect(try CodexJSONRPCWire.result(from: notification, matchingID: 9) == nil)
        #expect(try CodexJSONRPCWire.result(from: unrelated, matchingID: 9) == nil)
        let result = try #require(try CodexJSONRPCWire.result(from: matching, matchingID: 9))
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Int])
        #expect(object["value"] == 9)
    }

    @Test("wire parser surfaces matching RPC errors")
    func wireParserSurfacesErrors() {
        let line = Data(#"{"id":4,"error":{"message":"not signed in"}}"#.utf8)

        #expect(throws: CodexAppServerError.self) {
            _ = try CodexJSONRPCWire.result(from: line, matchingID: 4)
        }
    }

    @Test("app-server timeout is stable and force-kills a process that ignores TERM")
    func appServerTimeoutForceKills() async throws {
        let fixture = try Self.makeHangingCodex()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let client = CodexAppServerQuotaClient(
            environment: fixture.environment,
            initializeTimeout: 2,
            requestTimeout: 0.05)

        do {
            _ = try await client.fetchQuota()
            Issue.record("Expected an app-server timeout")
        } catch let CodexAppServerError.timedOut(method) {
            #expect(method == "account/rateLimits/read")
        } catch {
            Issue.record("Expected CodexAppServerError.timedOut, got \(error)")
        }

        let pid = try await Self.waitForPID(at: fixture.pidFile)
        Self.expectProcessIsGone(pid)
    }

    @Test("app-server cancellation force-kills a process that ignores TERM")
    func appServerCancellationForceKills() async throws {
        let fixture = try Self.makeHangingCodex()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let client = CodexAppServerQuotaClient(
            environment: fixture.environment,
            initializeTimeout: 2,
            requestTimeout: 60)
        let task = Task { try await client.fetchQuota() }
        let pid = try await Self.waitForPID(at: fixture.pidFile)

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        Self.expectProcessIsGone(pid)
    }

    @Test("resolver finds Codex in login-shell and common Node manager paths")
    func resolvesShellAndManagerPaths() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let shellBin = home.appendingPathComponent("shell-bin", isDirectory: true)
        let shellCodex = shellBin.appendingPathComponent("codex")
        try Self.makeExecutable(at: shellCodex)

        let shellResolved = CodexBinaryResolver.resolve(
            environment: ["HOME": home.path, "PATH": ""],
            loginShellPaths: [shellBin.path])
        #expect(shellResolved == shellCodex.standardizedFileURL)

        try FileManager.default.removeItem(at: shellCodex)
        let nvmCodex = home
            .appendingPathComponent(".nvm/versions/node/v22.0.0/bin", isDirectory: true)
            .appendingPathComponent("codex")
        try Self.makeExecutable(at: nvmCodex)
        let managerResolved = CodexBinaryResolver.resolve(
            environment: ["HOME": home.path, "PATH": ""],
            loginShellPaths: [])
        #expect(managerResolved == nvmCodex.standardizedFileURL)
    }

    @Test("login-shell PATH capture is cached and rejects an untrusted shell path")
    func cachesLoginShellPathSafely() async throws {
        let counter = LoginPathCaptureCounter(paths: ["/fixture/bin"])
        let cache = CodexLoginShellPathCache(capture: { environment in
            await counter.capture(environment)
        })
        let environment = ["HOME": "/fixture", "PATH": "/usr/bin", "SHELL": "/bin/zsh"]

        #expect(await cache.paths(environment: environment) == ["/fixture/bin"])
        #expect(await cache.paths(environment: environment) == ["/fixture/bin"])
        #expect(await counter.count == 1)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-untrusted-shell-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let untrustedShell = directory.appendingPathComponent("zsh")
        try Self.makeExecutable(at: untrustedShell)
        let selected = try #require(CodexLoginShellPathCapturer.supportedShellURL(
            environment: ["SHELL": untrustedShell.path]))
        #expect(selected != untrustedShell.standardizedFileURL)
        #expect(selected.path == "/bin/zsh" || selected.path == "/bin/bash")
    }

    private static let decodeMismatchBodyMessage = """
    failed to fetch codex rate limits: Decode error; body={
      "plan_type": "prolite",
      "note": "a brace inside a string: }",
      "rate_limit": {
        "primary_window": {
          "used_percent": 4,
          "limit_window_seconds": 18000,
          "reset_at": 1776216359
        },
        "secondary_window": {
          "used_percent": 19,
          "limit_window_seconds": 604800,
          "reset_at": 1776395384
        }
      }
    }
    """

    private static func makeHangingCodex() throws -> (
        directory: URL,
        pidFile: URL,
        environment: [String: String])
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-hanging-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        let pidFile = directory.appendingPathComponent("pid")
        let script = Data(
            """
            #!/bin/sh
            while IFS= read -r line; do
              case "$line" in
                *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
                *'"id":2'*)
                  trap '' TERM
                  printf '%s' $$ > "$TOKENBAR_TEST_PID_FILE"
                  while :; do :; done
                  ;;
              esac
            done
            """.utf8)
        try script.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (
            directory,
            pidFile,
            [
                "CODEX_CLI_PATH": executable.path,
                "PATH": "/usr/bin:/bin",
                "TOKENBAR_TEST_PID_FILE": pidFile.path,
            ])
    }

    private static func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\\nexit 0\\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func waitForPID(at url: URL) async throws -> Int32 {
        for _ in 0 ..< 400 {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CodexAppServerTestError.pidWasNotWritten
    }

    private static func expectProcessIsGone(_ pid: Int32) {
        #if canImport(Darwin)
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        #endif
    }
}

private enum CodexAppServerTestError: Error {
    case pidWasNotWritten
}
