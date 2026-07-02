import MCP
import Foundation

enum DateTimeTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "datetime",
            description: "Return the current local date and time as YYYY-MM-DD HH:mm:ss (24-hour, zero-padded).",
            inputSchema: obj([
                "type": "object",
                "properties": obj([:]),
                "required": arr()
            ])
        ),
        handler: { _ in
            let f = DateFormatter()
            f.locale = Locale.current
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return textContent(f.string(from: Date()))
        }
    )
}
