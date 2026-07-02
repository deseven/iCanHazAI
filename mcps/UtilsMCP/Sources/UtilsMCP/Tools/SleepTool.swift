import MCP
import Foundation

enum SleepTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "sleep",
            description: "Pause for a number of seconds. Useful for polling workflows. Clamped to [0, 3600].",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "seconds": obj([
                        "type": "number",
                        "description": "Number of seconds to sleep. Must be between 0 and 3600."
                    ])
                ]),
                "required": arr("seconds")
            ])
        ),
        handler: { args in
            var seconds = try requireDouble(args, "seconds")
            seconds = min(max(seconds, 0), 3600)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return textContent("Slept for \(seconds) seconds.")
        }
    )
}
