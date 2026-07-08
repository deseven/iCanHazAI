import MCP
import Foundation
import ProcessExit

enum StatTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "stat",
            description: "Return file metadata (type, size, modified/created timestamps, and a human-readable type from the `file` command) without reading contents.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "path": obj([
                        "type": "string",
                        "description": "Path to inspect. \(Workdir.shared.pathDescription)"
                    ])
                ]),
                "required": arr("path")
            ])
        ),
        handler: { args in
            let path = try requireString(args, "path")
            let resolved = try Workdir.shared.resolve(path)

            let fm = FileManager.default
            guard fm.fileExists(atPath: resolved) else {
                throw ToolError.invalidArgument("path", "not found: \(path)")
            }

            let attrs = (try? fm.attributesOfItem(atPath: resolved)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs[.modificationDate] as? Date
            let created = attrs[.creationDate] as? Date

            var typeStr = "file"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: resolved, isDirectory: &isDir)
            if isDir.boolValue { typeStr = "dir" }
            if let alias = try? fm.destinationOfSymbolicLink(atPath: resolved) {
                _ = alias
                typeStr = "symlink"
            }

            let isoFormatter = ISO8601DateFormatter()

            // Run `file -b` for a human-readable type description.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
            process.arguments = ["-b", resolved]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let fileOut = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await awaitProcessExit(process)

            var json: [String: String] = [
                "type": typeStr,
                "size": "\(size)",
                "file": fileOut,
            ]
            if let modified { json["modified"] = isoFormatter.string(from: modified) }
            if let created { json["created"] = isoFormatter.string(from: created) }

            let sorted = json.sorted { $0.key < $1.key }
            let parts = sorted.map { "\"\($0.key)\":\"\($0.value)\"" }
            return textContent("{\(parts.joined(separator: ","))}")
        }
    )
}
