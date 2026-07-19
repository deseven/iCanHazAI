// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CryptoKit
import ProcessExit
import LoginShell

// MARK: - Workdir

/// Per-chat working directory context for builtin tool execution. Carries the
/// resolved root path and isolation flag so Filesystem/Code tools resolve paths
/// correctly. When `isolated` is true, absolute paths are treated as relative
/// to the root (chroot-like) and path escapes are rejected.
struct Workdir: Sendable {
    let root: String?
    let isolated: Bool

    init(root: String?, isolated: Bool) {
        if let root, !root.isEmpty {
            let standardized = (root as NSString).standardizingPath
            self.root = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        } else {
            self.root = nil
        }
        self.isolated = isolated
    }

    var currentDirectory: String {
        if isolated { return "/" }
        return root ?? NSHomeDirectory()
    }

    private var base: String { root ?? NSHomeDirectory() }

    var defaultRoot: String { currentDirectory }
    var defaultCwd: String { root ?? NSHomeDirectory() }

    func resolve(_ path: String) throws -> String {
        if isolated, let root {
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let joined = (root as NSString).appendingPathComponent(relative)
            let standardized = (joined as NSString).standardizingPath
            let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
            guard resolved == root || resolved.hasPrefix(root + "/") else {
                throw BuiltinToolError("path escapes the workdir")
            }
            return resolved
        } else {
            if path.hasPrefix("/") {
                return (path as NSString).standardizingPath
            }
            let joined = (base as NSString).appendingPathComponent(path)
            return (joined as NSString).standardizingPath
        }
    }

    static let none = Workdir(root: nil, isolated: false)
    static let pathDescription = "Absolute or relative path, resolved against the current working directory."
    static let searchRootDescription = "Directory to search in (absolute or relative to the current working directory). Defaults to the current working directory."
}

// MARK: - Errors

struct BuiltinToolError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - Tool definition

struct BuiltinToolDef: Sendable {
    let name: String
    let description: String
    let schema: String
}

private typealias ToolOutput = (content: String, isError: Bool)

// MARK: - BuiltinTools

/// In-process tools ported from the four bundled MCP servers (Utils,
/// Filesystem, Code, Shell). Unlike the former subprocess-based MCPs, these run
/// directly inside the app — no process lifecycle, no stdio transport, no
/// per-chat copies. Each chat's tools run with a `Workdir` derived from the
/// chat's effective working directory and the role's per-group isolation flag.
enum BuiltinTools {

    static let utilsGroup = "Utils"
    static let filesystemGroup = "Filesystem"
    static let codeGroup = "Code"
    static let shellGroup = "Shell"

    static let allGroups: Set<String> = [utilsGroup, filesystemGroup, codeGroup, shellGroup]
    static let groupOrder: [String] = [utilsGroup, filesystemGroup, codeGroup, shellGroup]
    static let workdirCapableGroups: Set<String> = [filesystemGroup, codeGroup, shellGroup]
    static let isolationCapableGroups: Set<String> = [filesystemGroup, codeGroup]

    private static let shellPath = LoginShell.path()

    // MARK: - Tool definitions per group

    private static let utilsToolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(name: "calc",
            description: "Evaluate a mathematical expression using bc syntax (e.g. '2+2*3' or 'sqrt(16)'). Loads the bc math library so sqrt, s, c, l, e are available.",
            schema: #"{"type":"object","properties":{"expression":{"type":"string","description":"The mathematical expression to evaluate, e.g. '2+2*3' or 'sqrt(16)'. Uses bc syntax."}},"required":["expression"]}"#),
        BuiltinToolDef(name: "datetime",
            description: "Return the current local date and time as YYYY-MM-DD HH:mm:ss (24-hour, zero-padded).",
            schema: #"{"type":"object","properties":{},"required":[]}"#),
        BuiltinToolDef(name: "uuid",
            description: "Generate a new random UUID (uppercase, with hyphens).",
            schema: #"{"type":"object","properties":{},"required":[]}"#),
        BuiltinToolDef(name: "hash",
            description: "Compute a cryptographic hash of a string. Returns a lowercase hex digest.",
            schema: #"{"type":"object","properties":{"input":{"type":"string","description":"The string to hash."},"algorithm":{"type":"string","enum":["sha256","sha1","md5"],"description":"Hash algorithm. Defaults to sha256."}},"required":["input"]}"#),
        BuiltinToolDef(name: "base64_encode",
            description: "Encode a UTF-8 string to base64.",
            schema: #"{"type":"object","properties":{"input":{"type":"string","description":"The string to encode."}},"required":["input"]}"#),
        BuiltinToolDef(name: "base64_decode",
            description: "Decode a base64 string to UTF-8 text.",
            schema: #"{"type":"object","properties":{"input":{"type":"string","description":"The base64 string to decode."}},"required":["input"]}"#),
        BuiltinToolDef(name: "sleep",
            description: "Pause for a number of seconds. Useful for polling workflows. Clamped to [0, 3600].",
            schema: #"{"type":"object","properties":{"seconds":{"type":"number","description":"Number of seconds to sleep. Must be between 0 and 3600."}},"required":["seconds"]}"#),
    ]

    private static let filesystemToolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(name: "ls",
            description: "List files and directories at a path. Returns one entry per line, directories suffixed with '/'.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"Directory path to list. \#(Workdir.pathDescription)"},"recursive":{"type":"boolean","description":"If true, list recursively to a fixed depth of 1 (direct children plus one level into subdirectories) with a cap of 1000 entries. Default false."}},"required":["path"]}"#),
        BuiltinToolDef(name: "read_file",
            description: "Read a file. Text files support offset/limit line ranges and are returned with line numbers. From binary files only images are supported.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to read. \#(Workdir.pathDescription)"},"offset":{"type":"integer","description":"1-based starting line number for text files. Defaults to 1."},"limit":{"type":"integer","description":"Maximum number of lines to read for text files. Defaults to 2000."}},"required":["path"]}"#),
        BuiltinToolDef(name: "write_file",
            description: "Write text content to a file (creates or overwrites). Parent directories are created as needed.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to write. \#(Workdir.pathDescription)"},"content":{"type":"string","description":"The text content to write."}},"required":["path","content"]}"#),
        BuiltinToolDef(name: "find_file",
            description: "Find files by name (glob) within a directory tree. Matches filenames against the pattern. Caps results at 200 entries.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"\#(Workdir.searchRootDescription)"},"pattern":{"type":"string","description":"Glob pattern for the filename, e.g. '*.swift' or 'config*'. Supports * and ? wildcards."}},"required":["pattern"]}"#),
        BuiltinToolDef(name: "find_text",
            description: "Search file contents by regex across a directory tree using grep -R. Returns file:line:match lines.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"\#(Workdir.searchRootDescription)"},"regex":{"type":"string","description":"Regular expression to search for in file contents."},"file_pattern":{"type":"string","description":"Optional glob to filter files by name, e.g. '*.swift'."}},"required":["regex"]}"#),
        BuiltinToolDef(name: "mkdir",
            description: "Create a directory (recursive). Parent directories are created as needed.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"Directory path to create. \#(Workdir.pathDescription)"}},"required":["path"]}"#),
        BuiltinToolDef(name: "mv",
            description: "Move or rename a file or directory.",
            schema: #"{"type":"object","properties":{"src":{"type":"string","description":"Source path. \#(Workdir.pathDescription)"},"dst":{"type":"string","description":"Destination path. \#(Workdir.pathDescription)"}},"required":["src","dst"]}"#),
        BuiltinToolDef(name: "rm",
            description: "Delete a file or directory. For directories, recursive must be true unless the directory is empty.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"Path to delete. \#(Workdir.pathDescription)"},"recursive":{"type":"boolean","description":"If true and path is a directory, delete recursively. Default false."}},"required":["path"]}"#),
        BuiltinToolDef(name: "stat",
            description: "Return file metadata (type, size, modified/created timestamps, and a human-readable type from the `file` command) without reading contents.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"Path to inspect. \#(Workdir.pathDescription)"}},"required":["path"]}"#),
        BuiltinToolDef(name: "pwd",
            description: "Return the current working directory.",
            schema: #"{"type":"object","properties":{},"required":[]}"#),
    ]

    private static let codeToolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(name: "apply_patch",
            description: "Apply a patch to one or more files using the Codex apply_patch format. Supports Add File, Delete File, and Update File operations with context-anchored matching in a single call.",
            schema: #"{"type":"object","properties":{"patch":{"type":"string","description":"The patch text in apply_patch format. Begins with '*** Begin Patch' and ends with '*** End Patch'."}},"required":["patch"]}"#),
        BuiltinToolDef(name: "git",
            description: "Run a git command with the provided arguments. Arguments are passed directly to git.",
            schema: #"{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"description":"Arguments to pass to git, e.g. [\"status\", \"--short\"] or [\"add\", \"src/App.swift\"]."}},"required":["args"]}"#),
    ]

    private static let shellToolDefs: [BuiltinToolDef] = {
        let shellDesc = "Execute a command in the user's login shell (\(shellPath) -l). Returns stdout, and stderr on non-zero exit. The command is written to the shell's stdin with a `cd` line prepended, so the working directory is reliably set."
        let commandDesc = "The shell command to execute. Runs in \(shellPath) as a login shell (-l)."
        return [
            BuiltinToolDef(name: "shell",
                description: shellDesc,
                schema: #"{"type":"object","properties":{"command":{"type":"string","description":"__COMMAND_DESC__"},"cwd":{"type":"string","description":"Optional working directory for the command (absolute or relative to the current directory). Defaults to the current working directory."},"timeout":{"type":"integer","description":"Optional timeout in seconds. The command is killed if it exceeds this. Default: no timeout."}},"required":["command"]}"#.replacingOccurrences(of: "__COMMAND_DESC__", with: commandDesc)),
            BuiltinToolDef(name: "applescript",
                description: "Execute an AppleScript and return its result.",
                schema: #"{"type":"object","properties":{"script":{"type":"string","description":"The AppleScript source to execute."}},"required":["script"]}"#),
        ]
    }()

    static func tools(for group: String) -> [BuiltinToolDef] {
        switch group {
        case utilsGroup: return utilsToolDefs
        case filesystemGroup: return filesystemToolDefs
        case codeGroup: return codeToolDefs
        case shellGroup: return shellToolDefs
        default: return []
        }
    }

    static func toolDefinitions(for groups: Set<String>) -> [ToolDefinition] {
        var defs: [ToolDefinition] = []
        for group in groupOrder where groups.contains(group) {
            for tool in tools(for: group) {
                defs.append(ToolDefinition(
                    serverName: group,
                    prefix: "",
                    name: tool.name,
                    description: tool.description,
                    inputSchema: tool.schema
                ))
            }
        }
        return defs
    }

    static func group(for toolName: String) -> String? {
        for group in allGroups {
            if tools(for: group).contains(where: { $0.name == toolName }) {
                return group
            }
        }
        return nil
    }

    static let allToolNames: Set<String> = {
        var names: Set<String> = []
        for group in allGroups {
            names.formUnion(tools(for: group).map(\.name))
        }
        return names
    }()

    // MARK: - Dispatch

    static func call(name: String, arguments: String, callID: String, group: String, workdir: Workdir) async -> ToolResult {
        do {
            let args = try argsDict(arguments)
            let output = try await dispatch(name: name, group: group, args: args, workdir: workdir)
            return ToolResult(callID: callID, content: output.content, isError: output.isError)
        } catch let err as BuiltinToolError {
            return ToolResult(callID: callID, content: "Error: \(err.description)", isError: true)
        } catch {
            return ToolResult(callID: callID, content: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private static func dispatch(name: String, group: String, args: [String: Any], workdir: Workdir) async throws -> ToolOutput {
        switch (group, name) {
        // Utils
        case (utilsGroup, "calc"): return try await calc(args)
        case (utilsGroup, "datetime"): return datetime()
        case (utilsGroup, "uuid"): return uuid()
        case (utilsGroup, "hash"): return try hashTool(args)
        case (utilsGroup, "base64_encode"): return try base64Encode(args)
        case (utilsGroup, "base64_decode"): return try base64Decode(args)
        case (utilsGroup, "sleep"): return try await sleepTool(args)
        // Filesystem
        case (filesystemGroup, "ls"): return try ls(args, workdir: workdir)
        case (filesystemGroup, "read_file"): return try readFile(args, workdir: workdir)
        case (filesystemGroup, "write_file"): return try writeFile(args, workdir: workdir)
        case (filesystemGroup, "find_file"): return try findFile(args, workdir: workdir)
        case (filesystemGroup, "find_text"): return try await findText(args, workdir: workdir)
        case (filesystemGroup, "mkdir"): return try mkdir(args, workdir: workdir)
        case (filesystemGroup, "mv"): return try mv(args, workdir: workdir)
        case (filesystemGroup, "rm"): return try rm(args, workdir: workdir)
        case (filesystemGroup, "stat"): return try await stat(args, workdir: workdir)
        case (filesystemGroup, "pwd"): return pwd(workdir)
        // Code
        case (codeGroup, "apply_patch"): return try applyPatch(args, workdir: workdir)
        case (codeGroup, "git"): return try await git(args, workdir: workdir)
        // Shell
        case (shellGroup, "shell"): return try await shell(args, workdir: workdir)
        case (shellGroup, "applescript"): return try await applescript(args)
        default:
            throw BuiltinToolError("Unknown tool \"\(name)\" in group \"\(group)\".")
        }
    }

    // MARK: - Argument helpers

    private static func argsDict(_ arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8) else {
            throw BuiltinToolError("Invalid arguments (not UTF-8).")
        }
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuiltinToolError("Invalid arguments JSON.")
        }
        return obj
    }

    private static func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else {
            throw BuiltinToolError("missing required argument '\(key)'")
        }
        return v
    }

    private static func optionalString(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    private static func optionalInt(_ args: [String: Any], _ key: String) -> Int? {
        guard let v = args[key] else { return nil }
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    private static func optionalBool(_ args: [String: Any], _ key: String) -> Bool? {
        args[key] as? Bool
    }

    private static func requireDouble(_ args: [String: Any], _ key: String) throws -> Double {
        guard let v = args[key] else { throw BuiltinToolError("missing required argument '\(key)'") }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        throw BuiltinToolError("invalid argument '\(key)': expected number")
    }

    private static func requireStringArray(_ args: [String: Any], _ key: String) throws -> [String] {
        guard let v = args[key], let arr = v as? [Any] else {
            throw BuiltinToolError("missing required argument '\(key)'")
        }
        return arr.compactMap { $0 as? String }
    }

    // MARK: - Process helper

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(launchPath: String, arguments: [String] = [], stdin: String? = nil, cwd: String? = nil, timeout: TimeInterval? = nil) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let stdinPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            stdinPipe = p
        } else {
            stdinPipe = nil
        }

        try process.run()

        if let stdin, let stdinPipe {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try stdinPipe.fileHandleForWriting.close()
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                await awaitProcessExit(process)
                return RunResult(exitCode: -1, stdout: "", stderr: "timed out after \(timeout) seconds")
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        await awaitProcessExit(process)

        return RunResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - File helpers

    private static func isText(_ data: Data) -> Bool {
        let sample = data.count > 8192 ? data.prefix(8192) : data
        if sample.contains(0) { return false }
        return String(data: sample, encoding: .utf8) != nil
    }

    private static func relativize(_ absPath: String, root: String) -> String {
        var p = absPath
        if p == root { return "" }
        if p.hasPrefix(root + "/") {
            p = String(p.dropFirst(root.count + 1))
        }
        return p
    }

    private static func globToRegex(_ glob: String) throws -> NSRegularExpression {
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

    // MARK: - Utils tools

    private static func calc(_ args: [String: Any]) async throws -> ToolOutput {
        let expression = try requireString(args, "expression")
        let result = try await runProcess(launchPath: "/usr/bin/bc", arguments: ["-l"], stdin: expression + "\n")
        if result.exitCode != 0 {
            throw BuiltinToolError("invalid argument 'expression': bc failed: \(result.stderr)")
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw BuiltinToolError("invalid argument 'expression': bc returned no output")
        }
        return (trimmed, false)
    }

    private static func datetime() -> ToolOutput {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return (f.string(from: Date()), false)
    }

    private static func uuid() -> ToolOutput {
        (UUID().uuidString, false)
    }

    private static func hashTool(_ args: [String: Any]) throws -> ToolOutput {
        let input = try requireString(args, "input")
        let algorithm = optionalString(args, "algorithm") ?? "sha256"
        let data = Data(input.utf8)
        let digest: String
        switch algorithm.lowercased() {
        case "sha256":
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha1":
            digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "md5":
            digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            throw BuiltinToolError("invalid argument 'algorithm': must be sha256, sha1, or md5")
        }
        return (digest, false)
    }

    private static func base64Encode(_ args: [String: Any]) throws -> ToolOutput {
        let input = try requireString(args, "input")
        guard let data = input.data(using: .utf8) else {
            throw BuiltinToolError("invalid argument 'input': could not encode as UTF-8")
        }
        return (data.base64EncodedString(), false)
    }

    private static func base64Decode(_ args: [String: Any]) throws -> ToolOutput {
        let input = try requireString(args, "input")
        guard let data = Data(base64Encoded: input) else {
            throw BuiltinToolError("invalid argument 'input': not valid base64")
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw BuiltinToolError("invalid argument 'input': decoded bytes are not valid UTF-8")
        }
        return (s, false)
    }

    private static func sleepTool(_ args: [String: Any]) async throws -> ToolOutput {
        var seconds = try requireDouble(args, "seconds")
        seconds = min(max(seconds, 0), 3600)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return ("Slept for \(seconds) seconds.", false)
    }

    // MARK: - Filesystem tools

    private static func ls(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let path = try requireString(args, "path")
        let recursive = optionalBool(args, "recursive") ?? false
        let resolved = try workdir.resolve(path)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw BuiltinToolError("invalid argument 'path': not found: \(path)")
        }
        guard isDir.boolValue else {
            throw BuiltinToolError("invalid argument 'path': not a directory: \(path)")
        }

        // Recursive listing is capped at a fixed depth of 1 (direct children
        // plus one level into subdirectories) and a total of 1000 entries, to
        // keep output bounded for large trees (e.g. node_modules).
        let maxDepth = 1
        let maxEntries = 1000

        var lines: [String] = []
        if recursive {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                throw BuiltinToolError("invalid argument 'path': failed to enumerate: \(path)")
            }
            let root = resolved
            while let item = enumerator.nextObject() {
                guard let url = item as? URL else { continue }
                let level = enumerator.level
                if level > maxDepth + 1 { continue }
                let rel = relativize(url.path, root: root)
                var isD: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isD)
                lines.append(isD.boolValue ? "\(rel)/" : rel)
                if isD.boolValue && level >= maxDepth + 1 {
                    enumerator.skipDescendants()
                }
                if lines.count >= maxEntries { break }
            }
        } else {
            let entries = (try? fm.contentsOfDirectory(atPath: resolved)) ?? []
            for e in entries.sorted() {
                let full = (resolved as NSString).appendingPathComponent(e)
                var isD: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isD)
                lines.append(isD.boolValue ? "\(e)/" : e)
                if lines.count >= maxEntries { break }
            }
        }
        return (lines.joined(separator: "\n"), false)
    }

    private static func readFile(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let path = try requireString(args, "path")
        let offset = optionalInt(args, "offset") ?? 1
        let limit = optionalInt(args, "limit") ?? 2000
        if offset < 1 {
            throw BuiltinToolError("invalid argument 'offset': must be >= 1")
        }
        let resolved = try workdir.resolve(path)

        let fm = FileManager.default
        guard fm.fileExists(atPath: resolved) else {
            throw BuiltinToolError("invalid argument 'path': not found: \(path)")
        }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: resolved, isDirectory: &isDir)
        if isDir.boolValue {
            throw BuiltinToolError("invalid argument 'path': is a directory: \(path)")
        }

        guard let data = fm.contents(atPath: resolved) else {
            throw BuiltinToolError("invalid argument 'path': could not read: \(path)")
        }

        if ImageProcessor.isSupported(data) {
            let mimeType = imageMimeType(for: data) ?? "image"
            return ("[image: \(mimeType)]", false)
        }

        if !isText(data) {
            return ("Binary file \(path) is not a supported format. Only text and image files can be read.", false)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw BuiltinToolError("invalid argument 'path': file is not valid UTF-8: \(path)")
        }
        let lines = text.components(separatedBy: "\n")
        let cleaned: [String] = lines.last?.isEmpty ?? false ? Array(lines.dropLast()) : lines

        let hardLimit = 2000
        let effectiveLimit = min(limit, hardLimit)
        let startIdx = offset - 1
        guard startIdx < cleaned.count else {
            return ("", false)
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
        return (out.joined(separator: "\n"), false)
    }

    private static func imageMimeType(for data: Data) -> String? {
        guard let uti = ImageProcessor.typeIdentifier(for: data) else { return nil }
        switch uti {
        case "public.png": return "image/png"
        case "public.jpeg": return "image/jpeg"
        case "org.webmproject.webp": return "image/webp"
        case "public.heif", "public.heic": return "image/heic"
        case "public.tiff": return "image/tiff"
        case "com.microsoft.bmp", "public.bitmap": return "image/bmp"
        default: return "image/\(uti)"
        }
    }

    private static func writeFile(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let path = try requireString(args, "path")
        let content = try requireString(args, "content")
        let resolved = try workdir.resolve(path)

        let fm = FileManager.default
        let dir = (resolved as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let data = Data(content.utf8)
        try data.write(to: URL(fileURLWithPath: resolved), options: .atomic)
        return ("Wrote \(data.count) bytes to \(path)", false)
    }

    private static func findFile(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let pattern = try requireString(args, "pattern")
        let searchRoot = optionalString(args, "path") ?? workdir.defaultRoot
        let resolved = try workdir.resolve(searchRoot)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            throw BuiltinToolError("invalid argument 'path': not a directory: \(searchRoot)")
        }

        let regex = try globToRegex(pattern)
        let root = resolved
        var matches: [String] = []
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [], options: [.skipsHiddenFiles]) else {
            throw BuiltinToolError("invalid argument 'path': failed to enumerate: \(searchRoot)")
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
        return (out, false)
    }

    private static func findText(_ args: [String: Any], workdir: Workdir) async throws -> ToolOutput {
        let regex = try requireString(args, "regex")
        let searchRoot = optionalString(args, "path") ?? workdir.defaultRoot
        let filePattern = optionalString(args, "file_pattern")
        let resolved = try workdir.resolve(searchRoot)

        var arguments = ["-RIn"]
        if let filePattern {
            arguments.append("--include=\(filePattern)")
        }
        arguments.append(contentsOf: [regex, resolved])

        let result = try await runProcess(launchPath: "/usr/bin/grep", arguments: arguments)
        let output = result.stdout
        let cap = 64 * 1024
        if output.utf8.count > cap {
            let truncated = String(decoding: output.utf8.prefix(cap), as: UTF8.self)
            return (truncated + "\n... (truncated)", false)
        }
        return (output, false)
    }

    private static func mkdir(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let path = try requireString(args, "path")
        let resolved = try workdir.resolve(path)
        try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true)
        return ("Created directory \(path)", false)
    }

    private static func mv(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let src = try requireString(args, "src")
        let dst = try requireString(args, "dst")
        let resolvedSrc = try workdir.resolve(src)
        let resolvedDst = try workdir.resolve(dst)
        try FileManager.default.moveItem(atPath: resolvedSrc, toPath: resolvedDst)
        return ("Moved \(src) to \(dst)", false)
    }

    private static func rm(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let path = try requireString(args, "path")
        let recursive = optionalBool(args, "recursive") ?? false
        let resolved = try workdir.resolve(path)

        let fm = FileManager.default
        guard fm.fileExists(atPath: resolved) else {
            throw BuiltinToolError("invalid argument 'path': not found: \(path)")
        }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: resolved, isDirectory: &isDir)
        if isDir.boolValue && !recursive {
            let contents = (try? fm.contentsOfDirectory(atPath: resolved)) ?? []
            guard contents.isEmpty else {
                throw BuiltinToolError("invalid argument 'path': directory is not empty; use recursive: true to delete it")
            }
        }
        try fm.removeItem(atPath: resolved)
        return ("Deleted \(path)", false)
    }

    private static func stat(_ args: [String: Any], workdir: Workdir) async throws -> ToolOutput {
        let path = try requireString(args, "path")
        let resolved = try workdir.resolve(path)

        let fm = FileManager.default
        guard fm.fileExists(atPath: resolved) else {
            throw BuiltinToolError("invalid argument 'path': not found: \(path)")
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

        let result = try await runProcess(launchPath: "/usr/bin/file", arguments: ["-b", resolved])
        let fileOut = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        var json: [String: String] = [
            "type": typeStr,
            "size": "\(size)",
            "file": fileOut,
        ]
        if let modified { json["modified"] = isoFormatter.string(from: modified) }
        if let created { json["created"] = isoFormatter.string(from: created) }

        let sorted = json.sorted { $0.key < $1.key }
        let parts = sorted.map { "\"\($0.key)\":\"\($0.value)\"" }
        return ("{\(parts.joined(separator: ","))}", false)
    }

    private static func pwd(_ workdir: Workdir) -> ToolOutput {
        (workdir.currentDirectory, false)
    }

    // MARK: - Code tools

    /// Outcome of dry-running an apply_patch call: planned operations ready to
    /// execute, or the exact user-facing error message the tool would report.
    enum ApplyPatchPlan {
        case success([PlannedPatchOp])
        case failure(String)
    }

    /// Parses an apply_patch call and dry-runs it against the workdir (no
    /// writes). On success returns the planned file operations; on failure
    /// returns the exact error message the tool would report, so callers doing
    /// a pre-approval check can fail fast with a useful message.
    static func planApplyPatch(args: [String: Any], workdir: Workdir) -> ApplyPatchPlan {
        do {
            let patch = try requireString(args, "patch")
            let parsed = try PatchParser.parse(patch)
            return .success(try PatchApplier.plan(hunks: parsed.hunks, workdir: workdir))
        } catch let e as PatchParseError {
            return .failure("Invalid apply_patch format: \(e.description)")
        } catch let e as ApplyPatchError {
            return .failure("Failed to apply patch: \(e.description)")
        } catch let e as BuiltinToolError {
            return .failure("Error: \(e.description)")
        } catch {
            return .failure("Error: \(error.localizedDescription)")
        }
    }

    private static func applyPatch(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let ops: [PlannedPatchOp]
        switch planApplyPatch(args: args, workdir: workdir) {
        case .success(let planned): ops = planned
        case .failure(let message): return (message, true)
        }

        let fm = FileManager.default
        var summary: [String] = []

        for op in ops {
            switch op {
            case .addFile(let path, let resolved, let contents):
                let dir = (resolved as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: dir) {
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                }
                try Data(contents.utf8).write(to: URL(fileURLWithPath: resolved), options: .atomic)
                summary.append("Added: \(path)")

            case .deleteFile(let path, let resolved, _):
                try fm.removeItem(atPath: resolved)
                summary.append("Deleted: \(path)")

            case .updateFile(let path, let resolved, let movePath, let moveResolved, let chunkCount, _, let newContent):
                let tempURL = URL(fileURLWithPath: resolved)
                    .deletingLastPathComponent()
                    .appendingPathComponent(".ichai-patch-tmp-\(UUID().uuidString)")
                try Data(newContent.utf8).write(to: tempURL, options: .atomic)
                if let movePath, let moveResolved {
                    let moveDir = (moveResolved as NSString).deletingLastPathComponent
                    if !fm.fileExists(atPath: moveDir) {
                        try fm.createDirectory(atPath: moveDir, withIntermediateDirectories: true)
                    }
                    _ = try? fm.removeItem(atPath: moveResolved)
                    try fm.moveItem(atPath: tempURL.path, toPath: moveResolved)
                    try fm.removeItem(atPath: resolved)
                    summary.append("Updated: \(path) → \(movePath) (\(chunkCount) hunks)")
                } else {
                    _ = try? fm.removeItem(atPath: resolved)
                    try fm.moveItem(atPath: tempURL.path, toPath: resolved)
                    summary.append("Updated: \(path) (\(chunkCount) hunks)")
                }
            }
        }

        return (summary.joined(separator: "\n"), false)
    }

    private static func git(_ args: [String: Any], workdir: Workdir) async throws -> ToolOutput {
        let gitArgs = try requireStringArray(args, "args")
        if gitArgs.isEmpty {
            throw BuiltinToolError("invalid argument 'args': must not be empty")
        }
        if gitArgs.contains(where: { $0.contains("\0") }) {
            throw BuiltinToolError("invalid argument 'args': must not contain null bytes")
        }

        let result = try await runProcess(
            launchPath: "/usr/bin/git",
            arguments: gitArgs,
            cwd: workdir.defaultCwd
        )

        if result.exitCode == 0 {
            return (result.stdout, false)
        } else {
            return ("\(result.stdout)\(result.stderr)\n[exit code: \(result.exitCode)]", false)
        }
    }

    // MARK: - Shell tools

    private static func shell(_ args: [String: Any], workdir: Workdir) async throws -> ToolOutput {
        let command = try requireString(args, "command")
        let cwd = optionalString(args, "cwd") ?? workdir.defaultCwd
        let timeout = optionalInt(args, "timeout").map { TimeInterval($0) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()

        let input = "cd \"\(cwd)\"\n\(command)\n"
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdinPipe.fileHandleForWriting.close()

        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
                await awaitProcessExit(process)
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !timedOut { await awaitProcessExit(process) }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        if timedOut {
            var text = stdout
            if !stderr.isEmpty { text += stderr }
            text += "\n[exit code: timed out after \(Int(timeout!))s]"
            return (text, false)
        }

        if exitCode == 0 {
            return ("\(stdout)\n[exit code: 0]", false)
        } else {
            return ("\(stdout)\(stderr)\n[exit code: \(exitCode)]", false)
        }
    }

    private static func applescript(_ args: [String: Any]) async throws -> ToolOutput {
        let script = try requireString(args, "script")
        // NSAppleScript must run on the main actor. We extract the primitive
        // values (String/Int) before leaving the main actor to avoid Sendable
        // issues with NSAppleEventDescriptor/NSDictionary.
        let result: (output: String?, errorMessage: String?, errorNumber: Int?) = await MainActor.run {
            let appleScript = NSAppleScript(source: script)
            var errorInfo: NSDictionary?
            let output = appleScript?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
                let num = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
                return (output?.stringValue, msg, num)
            }
            return (output?.stringValue, nil as String?, nil as Int?)
        }
        if let errorMessage = result.errorMessage {
            let number = result.errorNumber ?? -1
            return ("AppleScript error: \(errorMessage) (number \(number))", false)
        }
        return (result.output ?? "", false)
    }
}
