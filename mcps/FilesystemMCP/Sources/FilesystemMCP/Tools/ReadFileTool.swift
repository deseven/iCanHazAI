import MCP
import Foundation
import ImageTools

enum ReadFileTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "read_file",
            description: "Read a file. Text files support offset/limit line ranges and are returned with line numbers. From binary files only images are supported.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "path": obj([
                        "type": "string",
                        "description": "File path to read. \(Workdir.shared.pathDescription)"
                    ]),
                    "offset": obj([
                        "type": "integer",
                        "description": "1-based starting line number for text files. Defaults to 1."
                    ]),
                    "limit": obj([
                        "type": "integer",
                        "description": "Maximum number of lines to read for text files. Defaults to 2000."
                    ])
                ]),
                "required": arr("path")
            ])
        ),
        handler: { args in
            let path = try requireString(args, "path")
            let offset = optionalInt(args, "offset") ?? 1
            let limit = optionalInt(args, "limit") ?? 2000
            if offset < 1 {
                throw ToolError.invalidArgument("offset", "must be >= 1")
            }
            let resolved = try Workdir.shared.resolve(path)

            let fm = FileManager.default
            guard fm.fileExists(atPath: resolved) else {
                throw ToolError.invalidArgument("path", "not found: \(path)")
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: resolved, isDirectory: &isDir)
            if isDir.boolValue {
                throw ToolError.invalidArgument("path", "is a directory: \(path)")
            }

            guard let data = fm.contents(atPath: resolved) else {
                throw ToolError.invalidArgument("path", "could not read: \(path)")
            }

            // Detect text vs image vs binary by content.
            if ImageProcessor.isSupported(data) {
                guard let processed = ImageProcessor.process(data) else {
                    throw ToolError.invalidArgument("path", "failed to process image: \(path)")
                }
                let mimeType = processed.ext == "png" ? "image/png" : "image/jpeg"
                let b64 = processed.data.base64EncodedString()
                return [.image(data: b64, mimeType: mimeType, annotations: nil, _meta: nil)]
            }

            if !isText(data) {
                return textContent("Binary file \(path) is not a supported format. Only text and image files can be read.")
            }

            guard let text = String(data: data, encoding: .utf8) else {
                throw ToolError.invalidArgument("path", "file is not valid UTF-8: \(path)")
            }
            let lines = text.components(separatedBy: "\n")
            // Drop trailing empty element from a final newline.
            let cleaned: [String] = lines.last?.isEmpty ?? false ? lines.dropLast() : lines

            let hardLimit = 2000
            let effectiveLimit = min(limit, hardLimit)
            let startIdx = offset - 1
            guard startIdx < cleaned.count else {
                return textContent("")
            }
            let endIdx = min(startIdx + effectiveLimit, cleaned.count)
            let slice = cleaned[startIdx..<endIdx]

            var out: [String] = []
            out.reserveCapacity(slice.count)
            for (i, line) in slice.enumerated() {
                let lineNo = startIdx + i + 1
                out.append(String(format: "%6d\t%@", lineNo, line as NSString))
            }
            if endIdx - startIdx == hardLimit && cleaned.count > endIdx {
                out.append("... (truncated at \(hardLimit) lines)")
            }
            return textContent(out.joined(separator: "\n"))
        }
    )
}

/// Heuristic: a file is text if the first 8 KB contain no NUL bytes and the
/// whole sample is valid UTF-8.
func isText(_ data: Data) -> Bool {
    let sample = data.count > 8192 ? data.prefix(8192) : data
    if sample.contains(0) { return false }
    return String(data: sample, encoding: .utf8) != nil
}
