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
///
/// A root in scp form `host:/path` (see [`SSHSpec`](src/SSH/SSHManager.swift:17))
/// switches the chat's workdir-capable tools to remote execution over SSH. In
/// that case `root` holds the remote absolute path (nil = remote home) and all
/// path handling is string-based POSIX normalization — the remote filesystem
/// is never touched during resolution (symlink escapes on the remote side are
/// explicitly the user's problem).
struct Workdir: Sendable {
    let root: String?
    let isolated: Bool
    let ssh: SSHContext?
    /// Set when the root looked like an SSH spec (a `:` before the first `/`)
    /// but failed to parse; surfaced as a tool error instead of silently
    /// treating it as local.
    let sshSpecError: String?

    init(root: String?, isolated: Bool, chatID: String? = nil) {
        if let root, SSHSpec.isSSH(root) {
            switch SSHSpec.parse(root) {
            case .success(let spec):
                self.root = spec.path
                self.ssh = SSHContext(host: spec.host, chatID: chatID ?? "shared")
                self.sshSpecError = nil
            case .failure(let reason):
                self.root = nil
                self.ssh = nil
                self.sshSpecError = "invalid SSH working directory \"\(root)\": \(reason)"
            }
            self.isolated = isolated
            return
        }
        if let root, !root.isEmpty {
            let standardized = (root as NSString).standardizingPath
            self.root = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        } else {
            self.root = nil
        }
        self.isolated = isolated
        self.ssh = nil
        self.sshSpecError = nil
    }

    var currentDirectory: String {
        if isolated { return "/" }
        return root ?? NSHomeDirectory()
    }

    private var base: String { root ?? NSHomeDirectory() }

    var defaultRoot: String { currentDirectory }
    var defaultCwd: String { root ?? NSHomeDirectory() }

    func resolve(_ path: String) throws -> String {
        if ssh != nil { return try resolveRemote(path) }
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

    /// Display spelling for a resolved path. In isolated mode the root is
    /// presented as the virtual "/" (matching `pwd`), so the real host/remote
    /// layout never leaks into tool output; otherwise the path passes through.
    func displayPath(forResolved resolved: String) -> String {
        guard isolated, let root else { return resolved }
        if root == "/" { return resolved }
        if resolved == root { return "/" }
        if resolved.hasPrefix(root + "/") { return String(resolved.dropFirst(root.count)) }
        return resolved
    }

    /// Remote path resolution: pure string manipulation, no filesystem access.
    /// A relative path with no root stays relative (resolved by the remote
    /// shell against the login directory, i.e. the remote home).
    private func resolveRemote(_ path: String) throws -> String {
        if isolated, let root {
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            // Root "/" contains every absolute path by definition.
            if root == "/" { return Self.posixNormalize("/" + relative) }
            let joined = root + "/" + relative
            let normalized = Self.posixNormalize(joined)
            guard normalized == root || normalized.hasPrefix(root + "/") else {
                throw BuiltinToolError("path escapes the workdir")
            }
            return normalized
        }
        if path.hasPrefix("/") { return Self.posixNormalize(path) }
        guard let root else { return Self.posixNormalize(path) }
        return Self.posixNormalize(root + "/" + path)
    }

    /// Collapses `.`/`..`/duplicate slashes without touching the filesystem
    /// (unlike `NSString.standardizingPath`, which also expands tildes — wrong
    /// for remote paths where `~` would mean the remote user's home).
    static func posixNormalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var parts: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !isAbsolute {
                    parts.append("..")
                }
            default:
                parts.append(String(segment))
            }
        }
        let joined = parts.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
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

typealias ToolOutput = (content: String, isError: Bool)

// MARK: - BuiltinTools

/// In-process tools. 
/// Each chat's tools run with a `Workdir` derived from the chat's
/// effective working directory and the role's per-group isolation flag.
enum BuiltinTools {

    static let utilsGroup = "Utils"
    static let filesystemGroup = "Filesystem"
    static let codeGroup = "Code"
    static let shellGroup = "Shell"

    static let allGroups: Set<String> = [utilsGroup, filesystemGroup, codeGroup, shellGroup]
    static let groupOrder: [String] = [utilsGroup, filesystemGroup, codeGroup, shellGroup]
    static let workdirCapableGroups: Set<String> = [filesystemGroup, codeGroup, shellGroup]
    static let isolationCapableGroups: Set<String> = [filesystemGroup, codeGroup]

    /// Tools that only make sense against the local machine (macOS
    /// automation) and are not advertised when the chat's working directory
    /// is an SSH path.
    static let sshUnavailableToolNames: Set<String> = ["applescript"]

    private static let shellPath = LoginShell.path()

    // MARK: - Tool definitions per group

    private static let utilsToolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(name: "calc",
            description: "Evaluate a mathematical expression using bc syntax. Loads the bc math library so sqrt, s, c, l, e are available.",
            schema: #"{"type":"object","properties":{"expression":{"type":"string","description":"The mathematical expression to evaluate, e.g. '2+2*3' or 'sqrt(16)'."}},"required":["expression"]}"#),
        BuiltinToolDef(name: "datetime",
            description: "Return the current local date and time as YYYY-MM-DD HH:mm:ss (24-hour, zero-padded).",
            schema: #"{"type":"object","properties":{},"required":[]}"#),
        BuiltinToolDef(name: "uuid",
            description: "Generate a new random UUID.",
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
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"Directory path to list. \#(Workdir.pathDescription)"},"recursive":{"type":"boolean","description":"If true, list recursively to a fixed depth of 1 (direct children plus one level into subdirectories) with a cap of 1000 entries. Default false."},"include_hidden":{"type":"boolean","description":"Include hidden files and directories (names starting with '.'). Default false."}},"required":["path"]}"#),
        BuiltinToolDef(name: "read_file",
            description: "Read a file. Text files support offset/limit line ranges and are returned with line numbers in the format 'N | content' (right-aligned line number, a pipe separator, then the raw line). The 'N | ' prefix is NOT part of the file — never include it when quoting file content, e.g. in apply_patch context lines. From binary files only images are supported.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to read. \#(Workdir.pathDescription)"},"offset":{"type":"integer","description":"1-based starting line number for text files. Defaults to 1."},"limit":{"type":"integer","description":"Maximum number of lines to read for text files. Defaults to 2000."}},"required":["path"]}"#),
        BuiltinToolDef(name: "write_file",
            description: "Write text content to a file (creates or overwrites). Parent directories are created as needed. ALWAYS provide the COMPLETE intended content of the file — partial updates or placeholders like '// rest unchanged' are forbidden. Do NOT include line numbers in the content. For targeted edits to existing files, prefer apply_patch.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"File path to write. \#(Workdir.pathDescription)"},"content":{"type":"string","description":"The complete text content to write, without line numbers or truncation."}},"required":["path","content"]}"#),
        BuiltinToolDef(name: "find_file",
            description: "Find files by name (glob) within a directory tree. Results are sorted and capped at 200 entries.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"\#(Workdir.searchRootDescription)"},"pattern":{"type":"string","description":"Glob pattern, e.g. '*.swift' or '**/test_*.py'. Supports * (any run within a path component), ? (single character), [...] (character class) and ** (any number of directories). Patterns containing '/' match the path relative to the search root, otherwise the bare filename."},"case_insensitive":{"type":"boolean","description":"Match without regard to case. Default false."},"include_hidden":{"type":"boolean","description":"Also search hidden files and directories (names starting with '.'). Default false."}},"required":["pattern"]}"#),
        BuiltinToolDef(name: "find_text",
            description: "Search file contents with a regular expression across a directory tree. Returns path:line:content for each matching line (context lines use '-' separators, groups are split by '--'), sorted deterministically; lines longer than 300 characters are truncated. Binary files are skipped.",
            schema: #"{"type":"object","properties":{"path":{"type":"string","description":"\#(Workdir.searchRootDescription)"},"regex":{"type":"string","description":"Regular expression to search for in file contents. The full regex syntax is supported (\\d \\w \\s, quantifiers, alternation, groups, anchors); in some environments it is POSIX ERE (grep -E: alternation, groups, + ? {n,m} quantifiers, but no \\d \\w \\s shorthands — use [[:digit:]] etc.). Invalid patterns are reported as errors."},"file_pattern":{"type":"string","description":"Optional glob to filter files by name, e.g. '*.swift'. Same glob syntax as find_file."},"case_insensitive":{"type":"boolean","description":"Match without regard to case. Default false."},"include_hidden":{"type":"boolean","description":"Also search hidden files and directories (names starting with '.'). Default false."},"max_results":{"type":"integer","description":"Maximum number of matching lines to return (1-1000), applied after sorting so truncation is deterministic. Default 200."},"context":{"type":"integer","description":"Lines of context before and after each match (0-25), grep-style. Default 0."}},"required":["regex"]}"#),
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

    /// Full apply_patch format documentation, embedded in the tool description
    /// so every role with the code group gets it regardless of its prompt.
    private static let applyPatchDescription = """
    Apply patches to files using the Codex apply_patch format — a stripped-down, file-oriented diff. One call can create, delete, and update multiple files.

    Patch envelope:
    *** Begin Patch
    [ one or more file sections ]
    *** End Patch

    Each file section starts with one of three headers:
    - *** Add File: <path> — create a new file. Every following line is a + line (the initial contents).
    - *** Delete File: <path> — remove an existing file. Nothing follows.
    - *** Update File: <path> — patch an existing file in place. May be immediately followed by *** Move to: <new path> to rename.

    Update File sections contain one or more hunks, each introduced by @@ optionally followed by an anchor: a single line copied verbatim from the file (e.g. a class or function signature) that the hunk body is searched for after. The FIRST hunk of a file may omit @@; every later hunk must start with @@ (a bare @@ with nothing after it is fine). Only ONE @@ line per hunk.

    CRITICAL: within a hunk, EVERY line must start with exactly one prefix character:
    - ' ' (a single space) for context lines (unchanged) — a file line indented with 4 spaces therefore has 5 leading spaces in the patch
    - '-' for lines to remove
    - '+' for lines to add
    Never paste lines copied from read_file output without adding the prefix, and never include the 'N | ' line-number prefix that read_file displays — it is not part of the file.

    Context guidelines:
    - Show 3 lines of context above and below each change.
    - If 3 lines of context cannot uniquely identify the location, use @@ with a class/function anchor.
    - The @@ anchor is not part of the hunk body — never repeat the anchor line as a context line.
    - Hunks must appear in file order and must not overlap; each hunk is searched for after the previous one. Merge adjacent changes into a single hunk.
    - To append to a file, use a hunk containing only + lines (no context, no removals) — it is inserted at end of file.
    - Context lines must match the file exactly — read the file before patching and copy context verbatim.

    Example:
    *** Begin Patch
    *** Add File: hello.txt
    +Hello world
    *** Update File: src/app.py
    *** Move to: src/main.py
    @@ def greet():
     print("starting")
    -print("Hi")
    +print("Hello, world!")
     print("done")
    *** Delete File: obsolete.txt
    *** End Patch
    """

    private static let codeToolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(name: "apply_patch",
            description: applyPatchDescription,
            schema: #"{"type":"object","properties":{"patch":{"type":"string","description":"The patch text in apply_patch format. Begins with '*** Begin Patch' and ends with '*** End Patch'."}},"required":["patch"]}"#),
    ]

    private static let shellToolDefs: [BuiltinToolDef] = {
        let shellDesc = "Execute a command in the user's login shell (\(shellPath) -l). Returns stdout, and stderr on non-zero exit. Runs in current directory."
        let commandDesc = "The shell command to execute. Could be a full multiline script as well."
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
            // Cocoa errors (failed move/remove/write) can embed resolved
            // paths — scrub the root so isolated mode never leaks it.
            var msg = error.localizedDescription
            if workdir.isolated, let root = workdir.root {
                msg = msg.replacingOccurrences(of: root, with: "")
            }
            return ToolResult(callID: callID, content: "Error: \(msg)", isError: true)
        }
    }

    private static func dispatch(name: String, group: String, args: [String: Any], workdir: Workdir) async throws -> ToolOutput {
        // SSH workdir: route workdir-capable tools to the remote
        // implementations. Utils and applescript always run locally.
        if let ssh = workdir.ssh {
            switch (group, name) {
            case (filesystemGroup, _):
                return try await BuiltinToolsSSH.filesystem(name: name, args: args, workdir: workdir, ssh: ssh)
            case (codeGroup, _):
                return try await BuiltinToolsSSH.code(name: name, args: args, workdir: workdir, ssh: ssh)
            case (shellGroup, "shell"):
                return try await BuiltinToolsSSH.shell(args: args, workdir: workdir, ssh: ssh)
            default:
                break
            }
        } else if let specError = workdir.sshSpecError, workdirCapableGroups.contains(group) {
            throw BuiltinToolError(specError)
        }
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

    static func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else {
            throw BuiltinToolError("missing required argument '\(key)'")
        }
        return v
    }

    static func optionalString(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    static func optionalInt(_ args: [String: Any], _ key: String) -> Int? {
        guard let v = args[key] else { return nil }
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    static func optionalBool(_ args: [String: Any], _ key: String) -> Bool? {
        args[key] as? Bool
    }

    private static func requireDouble(_ args: [String: Any], _ key: String) throws -> Double {
        guard let v = args[key] else { throw BuiltinToolError("missing required argument '\(key)'") }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        throw BuiltinToolError("invalid argument '\(key)': expected number")
    }

    static func requireStringArray(_ args: [String: Any], _ key: String) throws -> [String] {
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

    static func isText(_ data: Data) -> Bool {
        let sample = data.count > 8192 ? data.prefix(8192) : data
        if sample.contains(0) { return false }
        return String(data: sample, encoding: .utf8) != nil
    }

    /// Fully symlink-resolved spelling of an existing path (realpath(3)).
    /// Directory enumerators return paths in this spelling (/var →
    /// /private/var on macOS), so relativization roots must match it.
    static func canonicalPath(_ path: String) -> String {
        path.withCString { cstr in
            guard let resolved = realpath(cstr, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    static func relativize(_ absPath: String, root: String) -> String {
        var p = absPath
        if p == root { return "" }
        if p.hasPrefix(root + "/") {
            p = String(p.dropFirst(root.count + 1))
        }
        return p
    }

    /// Glob matcher for `find_file` and `find_text`'s `file_pattern`. Supports
    /// `*` (any run within one path component), `?` (single character),
    /// `[...]` (character class, `!` or `^` negates) and `**` (any number of
    /// path components). Patterns containing `/` match against the path
    /// relative to the search root, otherwise against the bare filename.
    struct GlobMatcher {
        private let regex: NSRegularExpression
        let isPathPattern: Bool

        init(pattern: String, caseInsensitive: Bool = false) throws {
            isPathPattern = pattern.contains("/")
            regex = try NSRegularExpression(pattern: Self.toRegex(pattern),
                                            options: caseInsensitive ? [.caseInsensitive] : [])
        }

        func matches(filename: String, relativePath: String) -> Bool {
            let subject = isPathPattern ? relativePath : filename
            return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        }

        static func toRegex(_ glob: String) -> String {
            let chars = Array(glob)
            var out = "^"
            var i = 0
            while i < chars.count {
                switch chars[i] {
                case "*":
                    if i + 1 < chars.count, chars[i + 1] == "*" {
                        // `**/` crosses (and may skip) path components.
                        if i + 2 < chars.count, chars[i + 2] == "/" {
                            out += "(?:.*/)?"
                            i += 3
                        } else {
                            out += ".*"
                            i += 2
                        }
                    } else {
                        out += "[^/]*"
                        i += 1
                    }
                case "?":
                    out += "[^/]"
                    i += 1
                case "[":
                    var j = i + 1
                    var cls = "["
                    if j < chars.count, chars[j] == "!" || chars[j] == "^" {
                        cls += "^"
                        j += 1
                    }
                    // A ']' right after the opener is a literal member.
                    if j < chars.count, chars[j] == "]" {
                        cls += "\\]"
                        j += 1
                    }
                    var closed = false
                    while j < chars.count {
                        if chars[j] == "]" { closed = true; j += 1; break }
                        cls += chars[j] == "\\" ? "\\\\" : String(chars[j])
                        j += 1
                    }
                    if closed {
                        out += cls + "]"
                        i = j
                    } else {
                        // Unterminated '[' is a literal.
                        out += "\\["
                        i += 1
                    }
                case let c where "\\.^$+{}()|]".contains(c):
                    out += "\\\(c)"
                    i += 1
                default:
                    out.append(chars[i])
                    i += 1
                }
            }
            return out + "$"
        }
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
        let includeHidden = optionalBool(args, "include_hidden") ?? false
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

        // `.skipsHiddenFiles` covers both dotfiles and the macOS UF_HIDDEN
        // flag, keeping hidden handling consistent across modes and tools.
        let enumOptions: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        var lines: [String] = []
        if recursive {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isDirectoryKey], options: enumOptions) else {
                throw BuiltinToolError("invalid argument 'path': failed to enumerate: \(path)")
            }
            // The enumerator returns symlink-resolved paths (/var →
            // /private/var on macOS), so relativize against the canonical root.
            let root = canonicalPath(resolved)
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
            }
            lines.sort()
        } else {
            let urls = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isDirectoryKey], options: enumOptions)) ?? []
            for url in urls {
                let name = url.lastPathComponent
                let isD = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                lines.append(isD ? "\(name)/" : name)
            }
            lines.sort()
        }
        return (lines.prefix(maxEntries).joined(separator: "\n"), false)
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
        return try formatFileContent(data, path: path, offset: offset, limit: limit)
    }

    /// Shared read_file formatting pipeline (image detection, text slicing
    /// with line numbers, truncation), used by both the local and the
    /// SSH-backed implementations once the raw bytes are in hand.
    static func formatFileContent(_ data: Data, path: String, offset: Int, limit: Int) throws -> ToolOutput {
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

        // 'N | content' gutter: right-aligned number + visible pipe separator.
        // The pipe (not a tab) makes the boundary between gutter and code
        // indentation unambiguous for models copying context into patches.
        let gutterWidth = String(cleaned.count).count
        var out: [String] = []
        out.reserveCapacity(slice.count)
        for (i, line) in slice.enumerated() {
            let lineNo = startIdx + i + 1
            let num = String(lineNo)
            out.append(String(repeating: " ", count: gutterWidth - num.count) + num + " | " + line)
        }
        if endIdx - startIdx == hardLimit && cleaned.count > endIdx {
            out.append("... (truncated at \(hardLimit) lines)")
        }
        return (out.joined(separator: "\n"), false)
    }

    static func imageMimeType(for data: Data) -> String? {
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
        let caseInsensitive = optionalBool(args, "case_insensitive") ?? false
        let includeHidden = optionalBool(args, "include_hidden") ?? false
        let resolved = try workdir.resolve(searchRoot)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            throw BuiltinToolError("invalid argument 'path': not a directory: \(searchRoot)")
        }

        let glob = try GlobMatcher(pattern: pattern, caseInsensitive: caseInsensitive)
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [], options: options) else {
            throw BuiltinToolError("invalid argument 'path': failed to enumerate: \(searchRoot)")
        }
        // Matches are collected fully, then sorted, so the 200-cap truncation
        // is deterministic instead of raw walk order. The enumerator returns
        // symlink-resolved paths (/var → /private/var on macOS), so relativize
        // against the canonical root.
        let root = canonicalPath(resolved)
        var matches: [String] = []
        for case let url as URL in enumerator {
            let rel = relativize(url.path, root: root)
            if glob.matches(filename: url.lastPathComponent, relativePath: rel) {
                matches.append(rel)
            }
        }
        matches.sort()
        var out = matches.prefix(200).joined(separator: "\n")
        if matches.count > 200 { out += "\n... (truncated at 200 results)" }
        return (out, false)
    }

    /// Matching lines are cut at this length (with an ellipsis) so a single
    /// minified or generated line can't flood the context window.
    static let findTextMaxLineLength = 300
    /// Output safety net on top of max_results (context lines can add up).
    static let findTextMaxOutputBytes = 64 * 1024

    static func truncateMatchLine(_ line: String) -> String {
        if line.count <= findTextMaxLineLength { return line }
        return String(line.prefix(findTextMaxLineLength)) + "…"
    }

    private static func findText(_ args: [String: Any], workdir: Workdir) async throws -> ToolOutput {
        let pattern = try requireString(args, "regex")
        let searchRoot = optionalString(args, "path") ?? workdir.defaultRoot
        let caseInsensitive = optionalBool(args, "case_insensitive") ?? false
        let includeHidden = optionalBool(args, "include_hidden") ?? false
        let maxResults = min(max(optionalInt(args, "max_results") ?? 200, 1), 1000)
        let context = min(max(optionalInt(args, "context") ?? 0, 0), 25)
        let resolved = try workdir.resolve(searchRoot)

        // Native matching via the stdlib regex engine (full syntax, and
        // compile errors surface instead of silently returning nothing) —
        // previously this shelled out to BSD grep, whose default BRE dialect
        // treats most metacharacters as literals.
        let regex: Regex<AnyRegexOutput>
        do {
            regex = try Regex(pattern, as: AnyRegexOutput.self).ignoresCase(caseInsensitive)
        } catch {
            throw BuiltinToolError("invalid argument 'regex': \(error)")
        }
        let fileGlob = try optionalString(args, "file_pattern").map { try GlobMatcher(pattern: $0) }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw BuiltinToolError("invalid argument 'path': not found: \(searchRoot)")
        }

        // Pairs of (filesystem path, display path). The enumerator returns
        // symlink-resolved paths (/var → /private/var on macOS); display paths
        // keep the spelling the caller asked for, or the jail spelling (root
        // as "/") when isolated so the host layout never leaks. The jail
        // spelling is composed from the search root's jail path + rel rather
        // than prefix-matching url.path: resolvingSymlinksInPath (used for
        // the workdir root) doesn't canonicalize /var, so spellings differ.
        var files: [(path: String, display: String)] = []
        if isDir.boolValue {
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isRegularFileKey], options: options) else {
                throw BuiltinToolError("invalid argument 'path': failed to enumerate: \(searchRoot)")
            }
            let root = canonicalPath(resolved)
            let jailBase = workdir.isolated ? workdir.displayPath(forResolved: resolved) : nil
            while let url = enumerator.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let rel = relativize(url.path, root: root)
                if let fileGlob, !fileGlob.matches(filename: url.lastPathComponent, relativePath: rel) { continue }
                let display: String
                if let jailBase {
                    display = jailBase == "/" ? "/" + rel : jailBase + "/" + rel
                } else {
                    display = (resolved as NSString).appendingPathComponent(rel)
                }
                files.append((url.path, display))
            }
            files.sort { $0.display < $1.display }
        } else {
            files = [(resolved, workdir.displayPath(forResolved: resolved))]
        }

        var out: [String] = []
        var matchCount = 0
        var outBytes = 0
        var hitResultCap = false
        var hitByteCap = false

        fileLoop: for (file, display) in files {
            guard let data = fm.contents(atPath: file), isText(data),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // An empty final element is the artifact of a trailing newline.
            if lines.last?.isEmpty == true { lines.removeLast() }
            guard !lines.isEmpty else { continue }

            var matching: Set<Int> = []
            for (i, line) in lines.enumerated() where line.firstMatch(of: regex) != nil {
                matching.insert(i)
            }
            guard !matching.isEmpty else { continue }

            // Merge matches into grep-style groups when context is requested:
            // matches whose context windows touch share one group.
            var groups: [(range: ClosedRange<Int>, matches: Int)] = []
            for idx in matching.sorted() {
                let lo = max(0, idx - context)
                let hi = min(lines.count - 1, idx + context)
                if let last = groups.last, lo <= last.range.upperBound + 1 {
                    groups[groups.count - 1] = (last.range.lowerBound...hi, last.matches + 1)
                } else {
                    groups.append((lo...hi, 1))
                }
            }

            for group in groups {
                if context > 0, !out.isEmpty {
                    out.append("--")
                    outBytes += 3
                }
                for i in group.range {
                    let isMatch = matching.contains(i)
                    if isMatch {
                        if matchCount >= maxResults { hitResultCap = true; break fileLoop }
                        matchCount += 1
                    }
                    if outBytes >= Self.findTextMaxOutputBytes { hitByteCap = true; break fileLoop }
                    let sep = isMatch ? ":" : "-"
                    let line = "\(display)\(sep)\(i + 1)\(sep)\(truncateMatchLine(lines[i]))"
                    out.append(line)
                    outBytes += line.utf8.count + 1
                }
            }
        }

        var result = out.joined(separator: "\n")
        if hitResultCap { result += "\n... (truncated at \(maxResults) results)" }
        else if hitByteCap { result += "\n... (truncated, output size limit)" }
        return (result, false)
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
