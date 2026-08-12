import Foundation

/// Result of running a process to completion via ``ProcessRunner``.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// How to arrange the stdout and stderr streams of a process.
public enum ProcessOutputMode: Sendable {
    /// stdout and stderr are captured as separate `Data` buffers.
    case separate
    /// stderr is merged into stdout (terminal-like interleaved ordering).
    case merged
}

/// General-purpose process runner that drains output pipes concurrently,
/// avoiding the pipe-buffer deadlock that occurs when output exceeds the
/// OS pipe capacity (~64 KB on macOS) and nobody reads until after the
/// process exits.
///
/// Uses the same proven drain pattern as `SSHManager.runSSH`:
/// `Task.detached` reader loops feeding a thread-safe accumulator, with a
/// short breaker to handle killed processes whose far-end pipe stays open.
public enum ProcessRunner {

    /// Run a process to completion, draining pipes concurrently.
    ///
    /// - Parameters:
    ///   - executable: Path to the executable.
    ///   - arguments: Arguments to pass.
    ///   - stdin: Optional data to write to the process's stdin.
    ///   - cwd: Optional working directory.
    ///   - timeout: Optional wall-clock timeout. If exceeded, the process
    ///     is terminated and the result's `exitCode` is `-1` with stderr
    ///     set to a timeout message.
    ///   - outputMode: `.separate` (default) or `.merged`.
    /// - Returns: A ``ProcessResult`` with the exit code and captured output.
    public static func run(
        executable: String,
        arguments: [String] = [],
        stdin: Data? = nil,
        cwd: String? = nil,
        timeout: TimeInterval? = nil,
        outputMode: ProcessOutputMode = .separate
    ) async -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let stdoutPipe = Pipe()
        let stderrPipe: Pipe?
        switch outputMode {
        case .separate:
            process.standardOutput = stdoutPipe
            let sp = Pipe()
            process.standardError = sp
            stderrPipe = sp
        case .merged:
            process.standardOutput = stdoutPipe
            process.standardError = stdoutPipe
            stderrPipe = nil
        }

        let stdinPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            stdinPipe = p
        } else {
            stdinPipe = nil
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }

        let box = IOBox()
        let drains = DrainWaiter(channelCount: outputMode == .merged ? 1 : 2)

        // Drain stdout (and merged stderr) concurrently.
        Task.detached {
            while let d = try? stdoutPipe.fileHandleForReading.read(upToCount: 65536), !d.isEmpty {
                box.appendStdout(d)
            }
            drains.drainFinished()
        }
        if let stderrPipe {
            Task.detached {
                while let d = try? stderrPipe.fileHandleForReading.read(upToCount: 65536), !d.isEmpty {
                    box.appendStderr(d)
                }
                drains.drainFinished()
            }
        }

        // Write stdin from a side task so a slow/blocked reader never
        // deadlocks the watchdog (pipe buffer backpressure).
        if let stdin, let stdinPipe {
            Task.detached {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                timedOut = true
                box.setFailure("timed out after \(timeout) seconds")
                process.terminate()
            }
        }

        await awaitProcessExit(process)

        // EOF on the pipes normally arrives with process death, so awaiting
        // the drains costs nothing in the common case. A killed process may
        // leave the far end open (no pty → no SIGHUP), so a breaker bounds
        // the wait.
        let breaker = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            drains.breakerFired()
        }
        await drains.wait()
        breaker.cancel()

        if timedOut {
            return ProcessResult(exitCode: -1, stdout: box.stdout, stderr: Data((box.failureMessage ?? "timed out").utf8))
       }
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: box.stdout,
            stderr: box.stderr
        )
    }
}

// MARK: - Thread-safe accumulator

private final class IOBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var failure: String?

    var stdout: Data { lock.withLock { out } }
   var stderr: Data { lock.withLock { err } }

   func appendStdout(_ d: Data) { lock.withLock { out.append(d) } }
   func appendStderr(_ d: Data) { lock.withLock { err.append(d) } }
    func setFailure(_ msg: String) { lock.withLock { if failure == nil { failure = msg } } }
    var failureMessage: String? { lock.withLock { failure } }
}

// MARK: - Drain waiter

/// One-shot wait for all drain loops to hit EOF. Resumes when all drains
/// finish or when the breaker fires, whichever comes first.
private final class DrainWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var continuation: CheckedContinuation<Void, Never>?

    init(channelCount: Int) { remaining = channelCount }

    private func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    func drainFinished() {
        lock.lock()
        remaining -= 1
        let done = remaining <= 0
        lock.unlock()
        if done { resume() }
    }

    func breakerFired() { resume() }

    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if remaining <= 0 {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}
