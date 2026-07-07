import MCP
import Foundation

enum RmTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "rm",
            description: "Delete a file or directory. For directories, recursive must be true unless the directory is empty.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "path": obj([
                        "type": "string",
                        "description": "Path to delete. \(Workdir.shared.pathDescription)"
                    ]),
                    "recursive": obj([
                        "type": "boolean",
                        "description": "If true and path is a directory, delete recursively. Default false."
                    ])
                ]),
                "required": arr("path")
            ])
        ),
        handler: { args in
            let path = try requireString(args, "path")
            let recursive = optionalBool(args, "recursive") ?? false
            let resolved = try Workdir.shared.resolve(path)

            let fm = FileManager.default
            guard fm.fileExists(atPath: resolved) else {
                throw ToolError.invalidArgument("path", "not found: \(path)")
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: resolved, isDirectory: &isDir)
            if isDir.boolValue && !recursive {
                let contents = (try? fm.contentsOfDirectory(atPath: resolved)) ?? []
                guard contents.isEmpty else {
                    throw ToolError.invalidArgument("path", "directory is not empty; use recursive: true to delete it")
                }
            }
            try fm.removeItem(atPath: resolved)
            return textContent("Deleted \(path)")
        }
    )
}
