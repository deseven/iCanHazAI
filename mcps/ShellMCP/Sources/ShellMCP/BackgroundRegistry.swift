import Foundation
import ProcessExit

/// Owns background shell processes keyed by an incrementing integer handle.
/// Each entry holds the `Process`, an accumulating output buffer, and (once the
/// process exits) its termination status.
actor BackgroundRegistry {
    struct Entry {
        let process: Process
        var output: Data
        var exitCode: Int32?
        var finished: Bool
    }

    static let shared = BackgroundRegistry()

    private var entries: [Int: Entry] = [:]
    private var nextHandle: Int = 1

    /// Result of spawning a background process: the internal handle and the
    /// system PID (so the model can kill it externally if needed).
    struct SpawnResult {
        let handle: Int
        let pid: Int32
    }

    /// Spawn a command in the detected shell, writing the command to stdin with
    /// a prepended `cd` line. Returns the assigned handle and system PID.
    func spawn(command: String, cwd: String, shell: String) throws -> SpawnResult {
        let handle = nextHandle
        nextHandle += 1

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        try process.run()

        // Write the cd + command to stdin, then close so the shell exits.
        let input = "cd \"\(cwd)\"\n\(command)\n"
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdinPipe.fileHandleForWriting.close()

        let entry = Entry(process: process, output: Data(), exitCode: nil, finished: false)
        entries[handle] = entry

        // Drain stdout/stderr in the background.
        Task { [weak self] in
            await self?.drain(handle: handle, stdout: stdoutPipe, stderr: stderrPipe)
        }

        return SpawnResult(handle: handle, pid: process.processIdentifier)
    }

    private func drain(handle: Int, stdout: Pipe, stderr: Pipe) async {
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading

        // Read stdout to end.
        let stdoutData = stdoutHandle.readDataToEndOfFile()
        let stderrData = stderrHandle.readDataToEndOfFile()

        guard var entry = entries[handle] else { return }
        entry.output.append(stdoutData)
        entry.output.append(stderrData)
        await awaitProcessExit(entry.process)
        entry.exitCode = entry.process.terminationStatus
        entry.finished = true
        entries[handle] = entry
    }

    struct ReadResult {
        let output: String
        let finished: Bool
        let exitCode: Int32?
    }

    /// Read accumulated output for a handle. If `wait` is true, block (up to a
    /// reasonable timeout) until the process finishes.
    func read(handle: Int, wait: Bool) async -> ReadResult? {
        if wait {
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if let e = entries[handle], e.finished { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard let entry = entries[handle] else { return nil }
        return ReadResult(
            output: String(data: entry.output, encoding: .utf8) ?? "",
            finished: entry.finished,
            exitCode: entry.exitCode
        )
    }
}
