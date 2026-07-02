import Foundation

/// Result of running a subprocess synchronously.
struct RunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs a subprocess synchronously, capturing stdout/stderr. Optionally pipes
/// data to stdin and applies a timeout (in seconds).
enum ShellRunner {
    static func run(
        launchPath: String,
        arguments: [String] = [],
        stdin: String? = nil,
        environment: [String: String]? = nil,
        cwd: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let environment { process.environment = environment }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let stdinPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            stdinPipe = p
        } else {
            stdinPipe = nil
        }

        try process.run()

        if let stdin, let stdinPipe {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try stdinPipe.fileHandleForWriting.close()
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                _ = try? process.waitUntilExit()
                return RunResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: "timed out after \(timeout) seconds"
                )
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
