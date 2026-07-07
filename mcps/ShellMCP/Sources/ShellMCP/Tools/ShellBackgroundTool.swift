import MCP
import Foundation

enum ShellBackgroundTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "shell_background",
            description: "Start a long-running command in the background and return a handle (for read_output) and the system PID. Runs in \(ShellTool.shellPath).",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "command": obj([
                        "type": "string",
                        "description": "The shell command to execute in the background. Runs in \(ShellTool.shellPath)."
                    ]),
                    "cwd": obj([
                        "type": "string",
                        "description": "Optional working directory (absolute or relative to the current directory). Defaults to the current directory (\(WorkdirConfig.currentDirectory))."
                    ])
                ]),
                "required": arr("command")
            ])
        ),
        handler: { args in
            let command = try requireString(args, "command")
            let cwd = optionalString(args, "cwd") ?? WorkdirConfig.default

            let result = try await BackgroundRegistry.shared.spawn(
                command: command,
                cwd: cwd,
                shell: ShellTool.shellPath
            )
            return textContent("handle: \(result.handle)\npid: \(result.pid)")
        }
    )
}
