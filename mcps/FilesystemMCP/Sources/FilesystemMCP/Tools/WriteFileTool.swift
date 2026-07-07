import MCP
import Foundation

enum WriteFileTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "write_file",
            description: "Write text content to a file (creates or overwrites). Parent directories are created as needed.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "path": obj([
                        "type": "string",
                        "description": "File path to write. \(Workdir.shared.pathDescription)"
                    ]),
                    "content": obj([
                        "type": "string",
                        "description": "The text content to write."
                    ])
                ]),
                "required": arr("path", "content")
            ])
        ),
        handler: { args in
            let path = try requireString(args, "path")
            let content = try requireString(args, "content")
            let resolved = try Workdir.shared.resolve(path)

            let fm = FileManager.default
            let dir = (resolved as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            let data = Data(content.utf8)
            try data.write(to: URL(fileURLWithPath: resolved), options: .atomic)
            return textContent("Wrote \(data.count) bytes to \(path)")
        }
    )
}
