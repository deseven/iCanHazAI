import MCP
import Foundation
import ProcessExit
import LoginShell

enum ShellTool {
    static let shellPath = LoginShell.path()

    static func description(for name: String) -> String {
        "Execute a command in the user's login shell (\(shellPath) -l). Returns stdout, and stderr on non-zero exit. The command is written to the shell's stdin with a `cd` line prepended, so the working directory is reliably set."
    }

    static let definition = ToolDefinition(
        tool: Tool(
            name: "shell",
            description: ShellTool.description(for: "shell"),
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "command": obj([
                        "type": "string",
                        "description": "The shell command to execute. Runs in \(shellPath) as a login shell (-l)."
                    ]),
                    "cwd": obj([
                        "type": "string",
                        "description": "Optional working directory for the command (absolute or relative to the current directory). Defaults to the current working directory."
                    ]),
                    "timeout": obj([
                        "type": "integer",
                        "description": "Optional timeout in seconds. The command is killed if it exceeds this. Default: no timeout."
                    ])
                ]),
                "required": arr("command")
            ])
        ),
        handler: { args in
            let command = try requireString(args, "command")
            let cwd = optionalString(args, "cwd") ?? WorkdirConfig.default
            let timeout = optionalInt(args, "timeout").map { TimeInterval($0) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = ["-l"]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdinPipe = Pipe()
            process.standardInput = stdinPipe

            try process.run()

            let input = "cd \"\(cwd)\"\n\(command)\n"
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdinPipe.fileHandleForWriting.close()

            var timedOut = false
            if let timeout {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                    await awaitProcessExit(process)
                }
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !timedOut { await awaitProcessExit(process) }

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let exitCode = process.terminationStatus

            if timedOut {
                var text = stdout
                if !stderr.isEmpty { text += stderr }
                text += "\n[exit code: timed out after \(Int(timeout!))s]"
                return textContent(text)
            }

            if exitCode == 0 {
                return textContent("\(stdout)\n[exit code: 0]")
            } else {
                return textContent("\(stdout)\(stderr)\n[exit code: \(exitCode)]")
            }
        }
    )
}
