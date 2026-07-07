import MCP
import Foundation

enum MkdirTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "mkdir",
            description: "Create a directory (recursive). Parent directories are created as needed.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "path": obj([
                        "type": "string",
                        "description": "Directory path to create. \(Workdir.shared.pathDescription)"
                    ])
                ]),
                "required": arr("path")
            ])
        ),
        handler: { args in
            let path = try requireString(args, "path")
            let resolved = try Workdir.shared.resolve(path)
            try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true)
            return textContent("Created directory \(path)")
        }
    )
}
