import MCP
import Foundation

enum ApplyPatchTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "apply_patch",
            description: "Apply a patch to one or more files using the Codex apply_patch format. Supports Add File, Delete File, and Update File operations with context-anchored matching in a single call.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "patch": obj([
                        "type": "string",
                        "description": "The patch text in apply_patch format. Begins with '*** Begin Patch' and ends with '*** End Patch'."
                    ])
                ]),
                "required": arr("patch")
            ])
        ),
        handler: { args in
            let patch = try requireString(args, "patch")
            let parsed: ApplyPatchArgs
            do {
                parsed = try PatchParser.parse(patch)
            } catch let e as ParseError {
                return textContent("Failed to apply patch: \(e.description)")
            } catch {
                return textContent("Failed to apply patch: \(error)")
            }

            let fm = FileManager.default
            var summary: [String] = []

            for hunk in parsed.hunks {
                switch hunk {
                case .addFile(let path, let contents):
                    let resolved = try Workdir.shared.resolve(path)
                    if fm.fileExists(atPath: resolved) {
                        return textContent("Failed to apply patch: \(path) already exists")
                    }
                    let dir = (resolved as NSString).deletingLastPathComponent
                    if !fm.fileExists(atPath: dir) {
                        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    }
                    try Data(contents.utf8).write(to: URL(fileURLWithPath: resolved), options: .atomic)
                    summary.append("Added: \(path)")

                case .deleteFile(let path):
                    let resolved = try Workdir.shared.resolve(path)
                    guard fm.fileExists(atPath: resolved) else {
                        return textContent("Failed to apply patch: \(path) does not exist")
                    }
                    try fm.removeItem(atPath: resolved)
                    summary.append("Deleted: \(path)")

                case .updateFile(let path, let movePath, let chunks):
                    let resolved = try Workdir.shared.resolve(path)
                    guard fm.fileExists(atPath: resolved) else {
                        return textContent("Failed to apply patch: \(path) does not exist")
                    }
                    let original: String
                    if let data = fm.contents(atPath: resolved),
                       let s = String(data: data, encoding: .utf8) {
                        original = s
                    } else {
                        return textContent("Failed to apply patch: \(path) is not readable as UTF-8")
                    }

                    let newContent: String
                    do {
                        newContent = try PatchApplier.applyChunksToContent(
                            originalContent: original,
                            filePath: path,
                            chunks: chunks
                        )
                    } catch let e as ApplyPatchError {
                        return textContent("Failed to apply patch: \(e.description)")
                    }

                    // Write to temp then rename (atomic).
                    let tempURL = URL(fileURLWithPath: resolved)
                        .deletingLastPathComponent()
                        .appendingPathComponent(".ichai-patch-tmp-\(UUID().uuidString)")
                    try Data(newContent.utf8).write(to: tempURL, options: .atomic)
                    if let movePath {
                        let moveResolved = try Workdir.shared.resolve(movePath)
                        let moveDir = (moveResolved as NSString).deletingLastPathComponent
                        if !fm.fileExists(atPath: moveDir) {
                            try fm.createDirectory(atPath: moveDir, withIntermediateDirectories: true)
                        }
                        _ = try? fm.removeItem(atPath: moveResolved)
                        try fm.moveItem(atPath: tempURL.path, toPath: moveResolved)
                        try fm.removeItem(atPath: resolved)
                        summary.append("Updated: \(path) → \(movePath) (\(chunks.count) hunks)")
                    } else {
                        _ = try? fm.removeItem(atPath: resolved)
                        try fm.moveItem(atPath: tempURL.path, toPath: resolved)
                        summary.append("Updated: \(path) (\(chunks.count) hunks)")
                    }
                }
            }

            return textContent(summary.joined(separator: "\n"))
        }
    )
}
