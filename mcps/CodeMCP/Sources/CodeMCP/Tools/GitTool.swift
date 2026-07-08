import MCP
import Foundation
import ProcessExit

enum GitTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "git",
            description: "Run a git command with the provided arguments. Arguments are passed directly to git.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "args": obj([
                        "type": "array",
                        "items": obj(["type": "string"]),
                        "description": "Arguments to pass to git, e.g. [\"status\", \"--short\"] or [\"add\", \"src/App.swift\"]."
                    ])
                ]),
                "required": arr("args")
            ])
        ),
        handler: { args in
            // Extract the args array from the Value.
            guard let v = args["args"], case .array(let arr) = v else {
                throw ToolError.missingArgument("args")
            }
            let gitArgs: [String] = arr.compactMap { $0.stringValue }
            if gitArgs.isEmpty {
                throw ToolError.invalidArgument("args", "must not be empty")
            }
            // Reject null bytes (defensive; no shell injection risk since we
            // pass args directly to Process).
            if gitArgs.contains(where: { $0.contains("\0") }) {
                throw ToolError.invalidArgument("args", "must not contain null bytes")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = gitArgs
            process.currentDirectoryURL = URL(fileURLWithPath: Workdir.shared.defaultCwd)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            await awaitProcessExit(process)

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let exitCode = process.terminationStatus

            if exitCode == 0 {
                return textContent(stdout)
            } else {
                return textContent("\(stdout)\(stderr)\n[exit code: \(exitCode)]")
            }
        }
    )
}
