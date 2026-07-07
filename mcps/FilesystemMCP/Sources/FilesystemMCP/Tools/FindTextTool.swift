import MCP
import Foundation

enum FindTextTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "find_text",
            description: "Search file contents by regex across a directory tree using grep -R. Returns file:line:match lines.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "path": obj([
                        "type": "string",
                        "description": .string(Workdir.shared.searchRootDescription)
                    ]),
                    "regex": obj([
                        "type": "string",
                        "description": "Regular expression to search for in file contents."
                    ]),
                    "file_pattern": obj([
                        "type": "string",
                        "description": "Optional glob to filter files by name, e.g. '*.swift'."
                    ])
                ]),
                "required": arr("regex")
            ])
        ),
        handler: { args in
            let regex = try requireString(args, "regex")
            let searchRoot = optionalString(args, "path") ?? Workdir.shared.defaultRoot
            let filePattern = optionalString(args, "file_pattern")
            let resolved = try Workdir.shared.resolve(searchRoot)

            var arguments = ["-RIn"]
            if let filePattern {
                arguments.append("--include=\(filePattern)")
            }
            arguments.append(contentsOf: [regex, resolved])

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = arguments
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()
            try process.run()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(data: data, encoding: .utf8) ?? ""
            let cap = 64 * 1024
            if output.utf8.count > cap {
                let truncated = String(decoding: output.utf8.prefix(cap), as: UTF8.self)
                return textContent(truncated + "\n... (truncated)")
            }
            return textContent(output)
        }
    )
}
