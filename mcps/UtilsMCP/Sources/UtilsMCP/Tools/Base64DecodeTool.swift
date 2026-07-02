import MCP
import Foundation

enum Base64DecodeTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "base64_decode",
            description: "Decode a base64 string to UTF-8 text.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "input": obj([
                        "type": "string",
                        "description": "The base64 string to decode."
                    ])
                ]),
                "required": arr("input")
            ])
        ),
        handler: { args in
            let input = try requireString(args, "input")
            guard let data = Data(base64Encoded: input) else {
                throw ToolError.invalidArgument("input", "not valid base64")
            }
            guard let s = String(data: data, encoding: .utf8) else {
                throw ToolError.invalidArgument("input", "decoded bytes are not valid UTF-8")
            }
            return textContent(s)
        }
    )
}
