import MCP
import Foundation

enum Base64EncodeTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "base64_encode",
            description: "Encode a UTF-8 string to base64.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "input": obj([
                        "type": "string",
                        "description": "The string to encode."
                    ])
                ]),
                "required": arr("input")
            ])
        ),
        handler: { args in
            let input = try requireString(args, "input")
            guard let data = input.data(using: .utf8) else {
                throw ToolError.invalidArgument("input", "could not encode as UTF-8")
            }
            return textContent(data.base64EncodedString())
        }
    )
}
