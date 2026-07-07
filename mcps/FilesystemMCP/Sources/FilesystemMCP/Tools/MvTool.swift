import MCP
import Foundation

enum MvTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "mv",
            description: "Move or rename a file or directory.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "src": obj([
                        "type": "string",
                        "description": "Source path. \(Workdir.shared.pathDescription)"
                    ]),
                    "dst": obj([
                        "type": "string",
                        "description": "Destination path. \(Workdir.shared.pathDescription)"
                    ])
                ]),
                "required": arr("src", "dst")
            ])
        ),
        handler: { args in
            let src = try requireString(args, "src")
            let dst = try requireString(args, "dst")
            let resolvedSrc = try Workdir.shared.resolve(src)
            let resolvedDst = try Workdir.shared.resolve(dst)
            try FileManager.default.moveItem(atPath: resolvedSrc, toPath: resolvedDst)
            return textContent("Moved \(src) to \(dst)")
        }
    )
}
