import MCP
import Foundation

enum UuidTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "uuid",
            description: "Generate a new random UUID (uppercase, with hyphens).",
            inputSchema: obj([
                "type": "object",
                "properties": obj([:]),
                "required": arr()
            ])
        ),
        handler: { _ in
            textContent(UUID().uuidString)
        }
    )
}
