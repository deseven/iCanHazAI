import MCP
import Foundation

enum FindFileTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "find_file",
            description: "Find files by name (glob) within a directory tree. Matches filenames against the pattern. Caps results at 200 entries.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "path": obj([
                        "type": "string",
                        "description": .string(Workdir.shared.searchRootDescription)
                    ]),
                    "pattern": obj([
                        "type": "string",
                        "description": "Glob pattern for the filename, e.g. '*.swift' or 'config*'. Supports * and ? wildcards."
                    ])
                ]),
                "required": arr("pattern")
            ])
        ),
        handler: { args in
            let pattern = try requireString(args, "pattern")
            let searchRoot = optionalString(args, "path") ?? Workdir.shared.defaultRoot
            let resolved = try Workdir.shared.resolve(searchRoot)

            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
                throw ToolError.invalidArgument("path", "not a directory: \(searchRoot)")
            }

            let regex = try globToRegex(pattern)
            let root = resolved
            var matches: [String] = []
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [], options: [.skipsHiddenFiles]) else {
                throw ToolError.invalidArgument("path", "failed to enumerate: \(searchRoot)")
            }
            let allURLs = enumerator.allObjects.compactMap { $0 as? URL }
            for url in allURLs {
                let name = url.lastPathComponent
                if regex.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil {
                    matches.append(relativize(url.path, root: root))
                    if matches.count >= 200 { break }
                }
            }
            var out = matches.joined(separator: "\n")
            if matches.count >= 200 { out += "\n... (truncated at 200 results)" }
            return textContent(out)
        }
    )
}

/// Convert a glob pattern (* and ?) to a case-sensitive NSRegularExpression.
func globToRegex(_ glob: String) throws -> NSRegularExpression {
    var escaped = ""
    for ch in glob {
        switch ch {
        case "*": escaped += ".*"
        case "?": escaped += "."
        case ".", "(", ")", "[", "]", "{", "}", "+", "^", "$", "\\", "|":
            escaped += "\\\(ch)"
        default: escaped.append(ch)
        }
    }
    escaped = "^\(escaped)$"
    return try NSRegularExpression(pattern: escaped, options: [])
}
