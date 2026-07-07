import MCP
import Foundation

enum ListTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "ls",
            description: "List files and directories at a path. Returns one entry per line, directories suffixed with '/'.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "path": obj([
                        "type": "string",
                        "description": "Directory path to list. \(Workdir.shared.pathDescription)"
                    ]),
                    "recursive": obj([
                        "type": "boolean",
                        "description": "If true, list recursively. Default false."
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
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
                throw ToolError.invalidArgument("path", "not found: \(path)")
            }
            guard isDir.boolValue else {
                throw ToolError.invalidArgument("path", "not a directory: \(path)")
            }

            var lines: [String] = []
            if recursive {
                guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                    throw ToolError.invalidArgument("path", "failed to enumerate: \(path)")
                }
                let root = resolved
                let allURLs = enumerator.allObjects.compactMap { $0 as? URL }
                for url in allURLs {
                    let rel = relativize(url.path, root: root)
                    var isD: ObjCBool = false
                    fm.fileExists(atPath: url.path, isDirectory: &isD)
                    lines.append(isD.boolValue ? "\(rel)/" : rel)
                }
            } else {
                let entries = (try? fm.contentsOfDirectory(atPath: resolved)) ?? []
                for e in entries.sorted() {
                    let full = (resolved as NSString).appendingPathComponent(e)
                    var isD: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isD)
                    lines.append(isD.boolValue ? "\(e)/" : e)
                }
            }
            return textContent(lines.joined(separator: "\n"))
        }
    )
}

/// Strip the `root` prefix and any leading slash from an absolute path.
func relativize(_ absPath: String, root: String) -> String {
    var p = absPath
    if p == root { return ""
    }
    if p.hasPrefix(root + "/") {
        p = String(p.dropFirst(root.count + 1))
    }
    return p
}
