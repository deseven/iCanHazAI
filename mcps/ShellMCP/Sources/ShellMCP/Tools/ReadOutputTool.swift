import MCP
import Foundation

enum ReadOutputTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "read_output",
            description: "Read the accumulated output of a background command started by shell_background. The output buffer is not cleared on read, so subsequent calls return the full accumulated output (useful for polling).",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "handle": obj([
                        "type": "integer",
                        "description": "The handle returned by shell_background."
                    ]),
                    "wait": obj([
                        "type": "boolean",
                        "description": "If true, block until the command finishes before returning output. Default false."
                    ])
                ]),
                "required": arr("handle")
            ])
        ),
        handler: { args in
            guard let handle = optionalInt(args, "handle") else {
                throw ToolError.missingArgument("handle")
            }
            let wait = optionalBool(args, "wait") ?? false

            guard let result = await BackgroundRegistry.shared.read(handle: handle, wait: wait) else {
                return textContent("Error: no background command with handle \(handle)")
            }

            if result.finished {
                let exitCode = result.exitCode ?? -1
                return textContent("\(result.output)\n[exit code: \(exitCode)]")
            } else {
                return textContent("\(result.output)\n[still running]")
            }
        }
    )
}
