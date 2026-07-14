import Foundation
import Testing
@testable import TokenBarCore
#if canImport(Darwin)
import Darwin
#endif

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("captures stdout and stderr without a helper dependency")
    func capturesOutput() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf stdout; printf stderr >&2"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 2)

        #expect(String(decoding: result.stdout, as: UTF8.self) == "stdout")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "stderr")
    }

    @Test("reports non-zero exits with captured stderr")
    func reportsFailure() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf failed >&2; exit 7"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 2)
        }
    }

    @Test("reports an exact timeout and force-kills a process that ignores TERM")
    func timesOutAndForceKills() async {
        let started = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 0.05)
            Issue.record("Expected the process to time out")
        } catch let ProcessRunnerError.timedOut(timeout) {
            #expect(timeout == 0.05)
        } catch {
            Issue.record("Expected ProcessRunnerError.timedOut, got \(error)")
        }
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("cancellation force-kills a process that ignores TERM")
    func cancellationForceKills() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-process-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let task = Task {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; printf '%s' $$ > \"$1\"; while :; do :; done",
                    "tokenbar-test",
                    pidFile.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                timeout: .infinity)
        }

        let pid = try await Self.waitForPID(at: pidFile)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #if canImport(Darwin)
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        #endif
    }

    @Test("reports output truncation explicitly")
    func outputTooLarge() async {
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["123456789"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 2,
                maximumOutputBytes: 8)
            Issue.record("Expected outputTooLarge")
        } catch let ProcessRunnerError.outputTooLarge(stream, limitBytes) {
            #expect(stream == "stdout")
            #expect(limitBytes == 8)
        } catch {
            Issue.record("Expected ProcessRunnerError.outputTooLarge, got \(error)")
        }
    }

    private static func waitForPID(at url: URL) async throws -> Int32 {
        for _ in 0 ..< 200 {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProcessRunnerTestError.pidWasNotWritten
    }
}

private enum ProcessRunnerTestError: Error {
    case pidWasNotWritten
}
