import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ProcessRunResult: Sendable {
    public let stdout: Data
    public let stderr: Data

    public init(stdout: Data, stderr: Data) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: LocalizedError, Sendable {
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case outputTooLarge(stream: String, limitBytes: Int)
    case nonZeroExit(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            "Executable not found: \(path)"
        case let .launchFailed(message):
            "Could not launch process: \(message)"
        case let .timedOut(timeout):
            "Process timed out after \(timeout) seconds."
        case let .outputTooLarge(stream, limitBytes):
            "Process \(stream) exceeded the \(limitBytes)-byte capture limit."
        case let .nonZeroExit(code, stderr):
            stderr.isEmpty ? "Process exited with status \(code)." : "Process exited with status \(code): \(stderr)"
        }
    }
}

public enum ProcessRunner {
    public static let defaultMaximumOutputBytes = 32 * 1024 * 1024

    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        acceptsNonZeroExit: Bool = false,
        maximumOutputBytes: Int = ProcessRunner.defaultMaximumOutputBytes) async throws -> ProcessRunResult
    {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessRunnerError.executableNotFound(executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let captureLimit = max(0, maximumOutputBytes)
        let stdoutCapture = BoundedPipeCapture(pipe: stdoutPipe, maximumBytes: captureLimit)
        let stderrCapture = BoundedPipeCapture(pipe: stderrPipe, maximumBytes: captureLimit)
        stdoutCapture.start()
        stderrCapture.start()

        let completion = ProcessCompletion()
        let race = ProcessWaitRace()
        process.terminationHandler = { completedProcess in
            let status = completedProcess.terminationStatus
            completion.resolve(status)
            race.resolve(.exited(status))
        }

        do {
            try process.run()
        } catch {
            stdoutCapture.stop()
            stderrCapture.stop()
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let control = ProcessControl(process: process)
        var timeoutTask: Task<Void, Never>?
        if timeout.isFinite {
            timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(max(0, timeout)))
                } catch {
                    return
                }
                if race.resolve(.timedOut) {
                    control.terminate()
                }
            }
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            if race.resolve(.cancelled) {
                control.terminate()
            }
        }
        if let timeoutTask {
            timeoutTask.cancel()
            await timeoutTask.value
        }

        switch outcome {
        case .timedOut, .cancelled:
            await control.terminateAndWait(completion: completion)
            stdoutCapture.stop()
            stderrCapture.stop()
            if case .cancelled = outcome {
                throw CancellationError()
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ProcessRunnerError.timedOut(timeout)
        case let .exited(status):
            let stdout = stdoutCapture.finish()
            let stderr = stderrCapture.finish()
            try Task.checkCancellation()

            if stdout.wasTruncated {
                throw ProcessRunnerError.outputTooLarge(
                    stream: "stdout",
                    limitBytes: captureLimit)
            }
            if stderr.wasTruncated {
                throw ProcessRunnerError.outputTooLarge(
                    stream: "stderr",
                    limitBytes: captureLimit)
            }
            if status != 0, !acceptsNonZeroExit {
                throw ProcessRunnerError.nonZeroExit(
                    code: status,
                    stderr: String(decoding: stderr.data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return ProcessRunResult(stdout: stdout.data, stderr: stderr.data)
        }
    }
}

enum ProcessWaitOutcome: Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
}

final class ProcessWaitRace: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: ProcessWaitOutcome?
    private var continuation: CheckedContinuation<ProcessWaitOutcome, Never>?

    @discardableResult
    func resolve(_ outcome: ProcessWaitOutcome) -> Bool {
        self.lock.lock()
        guard self.outcome == nil else {
            self.lock.unlock()
            return false
        }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: outcome)
        return true
    }

    func wait() async -> ProcessWaitOutcome {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if let outcome = self.outcome {
                self.lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }
}

final class ProcessControl: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()

    init(process: Process) {
        self.process = process
    }

    func terminate() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.process.isRunning else { return }
        self.process.terminate()
    }

    func terminateAndWait(
        completion: ProcessCompletion,
        grace: Duration = .milliseconds(250)) async
    {
        self.terminate()
        if await completion.waitForExit(for: grace) {
            return
        }
        self.forceKill()
        _ = await completion.wait()
    }

    private func forceKill() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.process.isRunning else { return }
        #if canImport(Darwin)
        Darwin.kill(self.process.processIdentifier, SIGKILL)
        #endif
    }
}

final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func resolve(_ status: Int32) {
        self.lock.lock()
        guard self.status == nil else {
            self.lock.unlock()
            return
        }
        self.status = status
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if let status = self.status {
                self.lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }

    func waitForExit(for duration: Duration) async -> Bool {
        if self.currentStatus != nil { return true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if Task.isCancelled { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
            if self.currentStatus != nil { return true }
        }
        return self.currentStatus != nil
    }

    private var currentStatus: Int32? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.status
    }
}

private struct PipeCaptureSnapshot: Sendable {
    let data: Data
    let wasTruncated: Bool
}

private final class BoundedPipeCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let maximumBytes: Int
    private let condition = NSCondition()
    private var data = Data()
    private var wasTruncated = false
    private var activeCallbacks = 0
    private var reachedEOF = false
    private var stopping = false

    init(pipe: Pipe, maximumBytes: Int) {
        self.handle = pipe.fileHandleForReading
        self.maximumBytes = maximumBytes
    }

    func start() {
        self.handle.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
    }

    func finish() -> PipeCaptureSnapshot {
        let deadline = Date().addingTimeInterval(0.5)
        self.condition.lock()
        while !self.reachedEOF, !self.stopping, Date() < deadline {
            _ = self.condition.wait(until: deadline)
        }
        self.condition.unlock()
        return self.stopAndSnapshot()
    }

    func stop() {
        _ = self.stopAndSnapshot()
    }

    private func consume(_ chunk: Data) {
        self.condition.lock()
        guard !self.stopping else {
            self.condition.unlock()
            return
        }
        self.activeCallbacks += 1
        self.condition.unlock()

        self.condition.lock()
        if chunk.isEmpty {
            self.reachedEOF = true
        } else {
            let remaining = max(0, self.maximumBytes - self.data.count)
            if remaining > 0 {
                self.data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                self.wasTruncated = true
            }
        }
        self.activeCallbacks -= 1
        self.condition.broadcast()
        self.condition.unlock()

        if chunk.isEmpty {
            self.handle.readabilityHandler = nil
        }
    }

    private func stopAndSnapshot() -> PipeCaptureSnapshot {
        self.handle.readabilityHandler = nil
        self.condition.lock()
        self.stopping = true
        while self.activeCallbacks > 0 {
            self.condition.wait()
        }
        let snapshot = PipeCaptureSnapshot(
            data: self.data,
            wasTruncated: self.wasTruncated)
        self.condition.unlock()
        return snapshot
    }
}
