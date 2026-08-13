// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import LoginShell
import ProcessExit

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
            // `~` is the virtual home: the root itself (pwd reports "/").
            let p = try Self.strippingTildeForIsolated(path)
            let relative = p.hasPrefix("/") ? String(p.dropFirst()) : p
            let joined = (root as NSString).appendingPathComponent(relative)
            let standardized = (joined as NSString).standardizingPath
            let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
            guard resolved == root || resolved.hasPrefix(root + "/") else {
                throw BuiltinToolError("path escapes the workdir")
            }
            return resolved
        } else {
            var p = path
            if p.hasPrefix("~") {
                p = (p as NSString).expandingTildeInPath
                // expandingTildeInPath leaves an unknown `~user` untouched;
                // joining that onto the base would silently produce garbage.
                if p.hasPrefix("~") {
                    throw BuiltinToolError("cannot expand tilde in \"\(path)\" (unknown user?)")
                }
            }
            if p.hasPrefix("/") {
                return (p as NSString).standardizingPath
            }
            let joined = (base as NSString).appendingPathComponent(p)
            return (joined as NSString).standardizingPath
        }
    }

    /// Maps an isolated-mode tilde path onto the jail: `~` and `~/...` are the
    /// virtual home (the root), `~user` has no meaning inside the jail.
    private static func strippingTildeForIsolated(_ path: String) throws -> String {
        if path == "~" { return "/" }
        if path.hasPrefix("~/") { return String(path.dropFirst(1)) }
        if path.hasPrefix("~") {
            throw BuiltinToolError("\"~user\" paths are not supported in an isolated working directory")
        }
        return path
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
            // `~` is the virtual home: the root itself (pwd reports "/").
            let p = try Self.strippingTildeForIsolated(path)
            let relative = p.hasPrefix("/") ? String(p.dropFirst()) : p
            // Root "/" contains every absolute path by definition.
            if root == "/" { return Self.posixNormalize("/" + relative) }
            let joined = root + "/" + relative
            let normalized = Self.posixNormalize(joined)
            guard normalized == root || normalized.hasPrefix(root + "/") else {
                throw BuiltinToolError("path escapes the workdir")
            }
            return normalized
        }
        // A leading `~` refers to the remote user's home. The remote
        // filesystem is never queried during resolution, so the tilde stays
        // as a literal prefix and is expanded by the remote shell at exec
        // time (see BuiltinToolsSSH.qp). Home is independent of the root.
        if path.hasPrefix("~") {
            guard let slash = path.firstIndex(of: "/") else { return path }
            let prefix = path[..<slash]
            let rest = Self.posixNormalize(String(path[path.index(after: slash)...]))
            return rest == "." ? String(prefix) : prefix + "/" + rest
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
    static let searchRootDescription =
        "Directory to search in (absolute or relative to the current working directory). Defaults to the current working directory."
    static let excludePathsDescription =
        "Exact file or directory paths to exclude from the search, each resolved like 'path'. Excluding a directory prunes its entire subtree. Example: [\"node_modules\", \"/tmp/scratch\"]."
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

/// The output of a builtin tool. Most tools produce only `content` + `isError`;
/// `read_file` on an image additionally carries a processed image (resized/
/// re-encoded) plus its classification/OCR fallback, so the request builders
/// can send the image to vision-capable connections and the fallback text to
/// vision-incapable ones — exactly like user-attached images.
struct ToolOutput {
    var content: String
    var isError: Bool
    /// Present when `read_file` read an image. The processed image bytes are
    /// stored on the `ToolResult` (no attachment file is written to disk); the
    /// renderer loads them via the `ichai://` scheme handler, which serves
    /// from the chat data. `fallback` carries the classification+OCR text used
    /// in place of the image on vision-incapable connections.
    var image: ProcessedToolImage?

    init(content: String, isError: Bool, image: ProcessedToolImage? = nil) {
        self.content = content
        self.isError = isError
        self.image = image
    }
}

/// A processed image produced by `read_file`: the resized/re-encoded image
/// bytes, the media type, and the classification+OCR fallback text. The request
/// builders pick between the image block and the fallback text based on the
/// connection's vision capability, just like user-attached images. Unlike
/// attachments, no file is written to disk — the bytes live on the `ToolResult`
/// and are served to the renderer via the `ichai://` scheme handler (which
/// looks them up from the chat data).
struct ProcessedToolImage: Sendable {
    /// The processed image bytes (resized/re-encoded).
    let data: Data
    /// The media type for the API, e.g. "image/png".
    let mimeType: String
    /// The classification+OCR fallback text, used on vision-incapable
    /// connections in place of the image block.
    let fallback: String
}

// MARK: - BuiltinTools

/// In-process tools.
/// Each chat's tools run with a `Workdir` derived from the chat's
/// effective working directory and the role's per-group isolation flag.
enum BuiltinTools {

    static let utilsGroup = "Utils"
    static let filesystemGroup = "Filesystem"
    static let codeGroup = "Code"
    static let shellGroup = "Shell"
    static let webGroup = "Web"

    static let allGroups: Set<String> = [utilsGroup, filesystemGroup, codeGroup, shellGroup, webGroup]
    static let groupOrder: [String] = [utilsGroup, filesystemGroup, codeGroup, shellGroup, webGroup]
    static let workdirCapableGroups: Set<String> = [filesystemGroup, codeGroup, shellGroup]
    static let isolationCapableGroups: Set<String> = [filesystemGroup, codeGroup]
    /// Groups whose tools operate on files and therefore require a working
    /// directory (pre-set by the role or picked once per chat by the user).
    /// Shell is excluded — it defaults to the user's home when no directory
    /// is set.
    static let directoryRelevantGroups: Set<String> = [filesystemGroup, codeGroup]

    /// Tools that only make sense against the local machine (macOS
    /// automation) and are not advertised when the chat's working directory
    /// is an SSH path.
    static let sshUnavailableToolNames: Set<String> = ["applescript"]

    private static let shellPath = LoginShell.path()

    // MARK: - Tool definitions per group

    private static let utilsToolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(
            name: "calc",
            description:
                "Evaluate a mathematical expression using bc syntax. Loads the bc math library so sqrt, s, c, l, e are available.",
            schema:
                #"{"type":"object","properties":{"expression":{"type":"string","description":"The mathematical expression to evaluate, e.g. '2+2*3' or 'sqrt(16)'."}},"required":["expression"]}"#
        ),
        BuiltinToolDef(
            name: "datetime",
            description: "Return the current local date and time as YYYY-MM-DD HH:mm:ss (24-hour, zero-padded).",
            schema: #"{"type":"object","properties":{},"required":[]}"#),
        BuiltinToolDef(
            name: "uuid",
            description: "Generate a new random UUID.",
            schema: #"{"type":"object","properties":{},"required":[]}"#),
        BuiltinToolDef(
            name: "hash",
            description: "Compute a cryptographic hash of a string. Returns a lowercase hex digest.",
            schema:
                #"{"type":"object","properties":{"input":{"type":"string","description":"The string to hash."},"algorithm":{"type":"string","enum":["sha256","sha1","md5"],"description":"Hash algorithm. Defaults to sha256."}},"required":["input"]}"#
        ),
        BuiltinToolDef(
            name: "base64_encode",
            description: "Encode a UTF-8 string to base64.",
            schema:
                #"{"type":"object","properties":{"input":{"type":"string","description":"The string to encode."}},"required":["input"]}"#
        ),
        BuiltinToolDef(
            name: "base64_decode",
            description: "Decode a base64 string to UTF-8 text.",
            schema:
                #"{"type":"object","properties":{"input":{"type":"string","description":"The base64 string to decode."}},"required":["input"]}"#
        ),
        BuiltinToolDef(
            name: "sleep",
            description: "Pause for a number of seconds. Useful for polling workflows. Clamped to [0, 3600].",
            schema:
                #"{"type":"object","properties":{"seconds":{"type":"number","description":"Number of seconds to sleep. Must be between 0 and 3600."}},"required":["seconds"]}"#
        ),
        BuiltinToolDef(
            name: "rand",
            description:
                "Generate a random integer in the inclusive range [min, max]. Defaults to 0–100. Uses the system's cryptographically secure random number generator.",
            schema:
                #"{"type":"object","properties":{"min":{"type":"integer","description":"Lower bound (inclusive). Default 0."},"max":{"type":"integer","description":"Upper bound (inclusive). Default 100."}},"required":[]}"#
        ),
    ]

    private static let filesystemToolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(
            name: "ls",
            description:
                "List files and directories at a path. Returns one entry per line, directories suffixed with '/'.",
            schema:
                #"{"type":"object","properties":{"path":{"type":"string","description":"Directory path to list. \#(Workdir.pathDescription)"},"recursive":{"type":"boolean","description":"If true, list recursively to a fixed depth of 1 (direct children plus one level into subdirectories) with a cap of 1000 entries. Default false."},"include_hidden":{"type":"boolean","description":"Include hidden files and directories (names starting with '.'). Default false."}},"required":["path"]}"#
        ),
        BuiltinToolDef(
            name: "read_file",
            description:
                "Read a file and return its contents in a format that you can process. Use this as a main tool for reading individual files. Supports plain text and any other textual formats, document binaries (docx, doc, odt, rtf, pdf and similar) and image files. Text files are returned as a '[path#TAG]' header followed by 'N:content' numbered lines: #TAG is a file-version hash — copy it verbatim into edit_file to prove the file hasn't changed. The 'N:' prefix is display metadata, not file content — never include it in write_file content or edit_file body rows. Document binaries are returned as extracted plain text with no headers or line numbers and cannot be edited via edit_file.",
            schema:
                #"{"type":"object","properties":{"path":{"type":"string","description":"File path to read. \#(Workdir.pathDescription)"},"offset":{"type":"integer","description":"1-based starting line number. Defaults to 1."},"limit":{"type":"integer","description":"Maximum number of lines to read. Defaults to 2000."}},"required":["path"]}"#
        ),
        BuiltinToolDef(
            name: "write_file",
            description:
                "Write text content to a file (creates or overwrites). Parent directories are created as needed. ALWAYS provide the COMPLETE intended content of the file — partial updates or placeholders like '// rest unchanged' are forbidden. Pasted read_file output (headers and line numbers) is automatically stripped. For targeted edits to existing files, use edit_file instead.",
            schema:
                #"{"type":"object","properties":{"path":{"type":"string","description":"File path to write. \#(Workdir.pathDescription)"},"content":{"type":"string","description":"The complete text content to write, without line numbers or truncation."}},"required":["path","content"]}"#
        ),
        BuiltinToolDef(
            name: "find_file",
            description:
                "Find files by name (glob) within a directory tree. Results are sorted and capped at 200 entries.",
            schema:
                #"{"type":"object","properties":{"path":{"type":"string","description":"\#(Workdir.searchRootDescription)"},"pattern":{"type":"string","description":"Glob pattern, e.g. '*.swift' or '**/test_*.py'. Supports * (any run within a path component), ? (single character), [...] (character class) and ** (any number of directories). A pattern with no '/' matches the filename of every entry anywhere in the tree ('*.swift' finds every Swift file); a pattern containing '/' is matched against the entry's path relative to the search root, so 'src/*.py' only matches directly inside 'src/' and '**/test_*.py' matches in any directory."},"case_insensitive":{"type":"boolean","description":"Match without regard to case. Default false."},"include_hidden":{"type":"boolean","description":"Also search hidden files and directories (names starting with '.'). Default false."},"exclude_paths":{"type":"array","items":{"type":"string"},"description":"\#(Workdir.excludePathsDescription)"}},"required":["pattern"]}"#
        ),
        BuiltinToolDef(
            name: "find_text",
            description:
                "Search file contents with a regular expression across a directory tree. Returns a '[path#TAG]' header per file followed by 'N:content' for each matching line (context lines use '-' separators, groups are split by '--'), sorted deterministically; lines longer than 300 characters are truncated. #TAG is the file-version hash — copy it verbatim into edit_file. Binary files are skipped.",
            schema:
                #"{"type":"object","properties":{"path":{"type":"string","description":"\#(Workdir.searchRootDescription)"},"regex":{"type":"string","description":"Regular expression to search for in file contents. The full regex syntax is supported (\\d \\w \\s, quantifiers, alternation, groups, anchors); in some environments it is POSIX ERE (grep -E: alternation, groups, + ? {n,m} quantifiers, but no \\d \\w \\s shorthands — use [[:digit:]] etc.). Invalid patterns are reported as errors."},"file_pattern":{"type":"string","description":"Optional glob to filter files by name, e.g. '*.swift'. Same glob syntax as find_file."},"case_insensitive":{"type":"boolean","description":"Match without regard to case. Default false."},"include_hidden":{"type":"boolean","description":"Also search hidden files and directories (names starting with '.'). Default false."},"exclude_paths":{"type":"array","items":{"type":"string"},"description":"\#(Workdir.excludePathsDescription)"},"max_results":{"type":"integer","description":"Maximum number of matching lines to return (1-1000), applied after sorting so truncation is deterministic. Default 200."},"context":{"type":"integer","description":"Lines of context before and after each match (0-25), grep-style. Default 0."}},"required":["regex"]}"#
        ),
        BuiltinToolDef(
            name: "mkdir",
            description: "Create a directory (recursive). Parent directories are created as needed.",
            schema:
                #"{"type":"object","properties":{"path":{"type":"string","description":"Directory path to create. \#(Workdir.pathDescription)"}},"required":["path"]}"#
        ),
        BuiltinToolDef(
            name: "mv",
            description: "Move or rename a file or directory.",
            schema:
                #"{"type":"object","properties":{"src":{"type":"string","description":"Source path. \#(Workdir.pathDescription)"},"dst":{"type":"string","description":"Destination path. \#(Workdir.pathDescription)"}},"required":["src","dst"]}"#
        ),
        BuiltinToolDef(
            name: "rm",
            description:
                "Delete a file or directory. For directories, recursive must be true unless the directory is empty.",
            schema:
                #"{"type":"object","properties":{"path":{"type":"string","description":"Path to delete. \#(Workdir.pathDescription)"},"recursive":{"type":"boolean","description":"If true and path is a directory, delete recursively. Default false."}},"required":["path"]}"#
        ),
        BuiltinToolDef(
            name: "stat",
            description:
                "Return file metadata (type, size, modified/created timestamps, and a human-readable type from the `file` command) without reading contents.",
            schema:
                #"{"type":"object","properties":{"path":{"type":"string","description":"Path to inspect. \#(Workdir.pathDescription)"}},"required":["path"]}"#
        ),
        BuiltinToolDef(
            name: "pwd",
            description: "Return the current working directory.",
            schema: #"{"type":"object","properties":{},"required":[]}"#),
    ]

    private static let codeToolDefs: [BuiltinToolDef] = [
        BuiltinToolDef(
            name: "edit_file",
            description:
                "Edit existing text files using the hashline patch format. The 'input' is a patch beginning with '*** Begin Patch' and ending with '*** End Patch', containing one or more '[path#TAG]' sections. Copy '[path#TAG]' verbatim from read_file or find_text output: the #TAG proves you saw the current file state, and the edit is rejected with a re-read instruction if the file changed since. Operations per section: 'PUT N.=M:' replaces original inclusive lines N-M with the following '+TEXT' body rows; 'PUT <N:' / 'PUT >N:' insert body rows before/after line N ('<1' = file head, '>$' = file tail); 'CUT N.=M' deletes original inclusive lines N-M; 'REM' deletes the file; 'MV DEST' moves/renames the file (quote paths with spaces). Body rows are verbatim file content — '+' alone is a blank line, '+TEXT' is a literal line (leading whitespace preserved); never use '-' or context rows: the range deletes, the body is final content. Only UTF-8 text files can be edited; use write_file to replace other files entirely. The result reports the new '[path#NEWTAG]' for each edited file so you can chain edits without re-reading.",
            schema:
                #"{"type":"object","properties":{"input":{"type":"string","description":"Hashline patch text. Begins with '*** Begin Patch' and ends with '*** End Patch'. Contains one or more [path#TAG] sections with PUT/CUT/REM/MV operations."}},"required":["input"]}"#
        )
    ]

    private static let shellToolDefs: [BuiltinToolDef] = {
        let shellDesc =
            "Execute a command in the user's login shell (\(shellPath) -l). Returns stdout, and stderr on non-zero exit. Runs in current directory. Only use if other available tools can't achieve the desired results at all or effectively enough."
        let commandDesc = "The shell command to execute. Could be a full multiline script as well."
        return [
            BuiltinToolDef(
                name: "shell",
                description: shellDesc,
                schema:
                    #"{"type":"object","properties":{"command":{"type":"string","description":"__COMMAND_DESC__"},"cwd":{"type":"string","description":"Optional working directory for the command (absolute or relative to the current directory). Defaults to the current working directory."},"timeout":{"type":"integer","description":"Optional timeout in seconds. The command is killed if it exceeds this. Default: no timeout."}},"required":["command"]}"#
                    .replacingOccurrences(of: "__COMMAND_DESC__", with: commandDesc)),
            BuiltinToolDef(
                name: "applescript",
                description: "Execute an AppleScript and return its result.",
                schema:
                    #"{"type":"object","properties":{"script":{"type":"string","description":"The AppleScript source to execute."}},"required":["script"]}"#
            ),
        ]
    }()

    static func tools(for group: String) -> [BuiltinToolDef] {
        switch group {
        case utilsGroup: return utilsToolDefs
        case filesystemGroup: return filesystemToolDefs
        case codeGroup: return codeToolDefs
        case shellGroup: return shellToolDefs
        case webGroup: return BuiltinToolsWeb.toolDefs
        default: return []
        }
    }

    static func toolDefinitions(for groups: Set<String>) -> [ToolDefinition] {
        var defs: [ToolDefinition] = []
        for group in groupOrder where groups.contains(group) {
            for tool in tools(for: group) {
                defs.append(
                    ToolDefinition(
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

    static func call(
        name: String, arguments: String, callID: String, group: String, workdir: Workdir, chatFilename: String
    ) async -> ToolResult {
        do {
            let args = try argsDict(arguments)
            let output = try await dispatch(
                name: name, group: group, args: args, workdir: workdir, chatFilename: chatFilename)
            var result = ToolResult(callID: callID, content: output.content, isError: output.isError)
            if let image = output.image {
                result.image = ToolResultImage(
                    data: image.data.base64EncodedString(), mimeType: image.mimeType, fallback: image.fallback)
            }
            return result
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

    private static func dispatch(
        name: String, group: String, args: [String: Any], workdir: Workdir, chatFilename: String
    ) async throws -> ToolOutput {
        // SSH workdir: route workdir-capable tools to the remote
        // implementations. Utils and applescript always run locally.
        if let ssh = workdir.ssh {
            switch (group, name) {
            case (filesystemGroup, _):
                return try await BuiltinToolsSSH.filesystem(
                    name: name, args: args, workdir: workdir, ssh: ssh, chatFilename: chatFilename)
            case (codeGroup, _):
                return try await BuiltinToolsSSH.code(
                    name: name, args: args, workdir: workdir, ssh: ssh, chatFilename: chatFilename)
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
        case (utilsGroup, "rand"): return try randTool(args)
        // Filesystem
        case (filesystemGroup, "ls"): return try ls(args, workdir: workdir)
        case (filesystemGroup, "read_file"): return try readFile(args, workdir: workdir, chatFilename: chatFilename)
        case (filesystemGroup, "write_file"): return try writeFile(args, workdir: workdir)
        case (filesystemGroup, "find_file"): return try findFile(args, workdir: workdir)
        case (filesystemGroup, "find_text"): return try await findText(args, workdir: workdir)
        case (filesystemGroup, "mkdir"): return try mkdir(args, workdir: workdir)
        case (filesystemGroup, "mv"): return try mv(args, workdir: workdir)
        case (filesystemGroup, "rm"): return try rm(args, workdir: workdir)
        case (filesystemGroup, "stat"): return try await stat(args, workdir: workdir)
        case (filesystemGroup, "pwd"): return pwd(workdir)
        // Code
        case (codeGroup, "edit_file"): return try editFile(args, workdir: workdir)
        // Shell
        case (shellGroup, "shell"): return try await shell(args, workdir: workdir)
        case (shellGroup, "applescript"): return try await applescript(args)
        // Web
        case (webGroup, "web_search"): return try await BuiltinToolsWeb.search(args)
        case (webGroup, "web_extract"): return try await BuiltinToolsWeb.extract(args)
        case (webGroup, "web_fetch"): return try await BuiltinToolsWeb.fetch(args)
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

    /// Optional string array, rejecting non-string elements so a mistyped
    /// exclusion can't pass silently instead of being dropped.
    static func optionalStringArray(_ args: [String: Any], _ key: String) throws -> [String]? {
        guard let v = args[key] else { return nil }
        guard let arr = v as? [Any] else {
            throw BuiltinToolError("invalid argument '\(key)': expected an array of strings")
        }
        var out: [String] = []
        for el in arr {
            guard let s = el as? String else {
                throw BuiltinToolError("invalid argument '\(key)': expected an array of strings")
            }
            out.append(s)
        }
        return out
    }

    // MARK: - Process helper

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(
        launchPath: String, arguments: [String] = [], stdin: String? = nil, cwd: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> RunResult {
        let result = await ProcessRunner.run(
            executable: launchPath,
            arguments: arguments,
            stdin: stdin.map { Data($0.utf8) },
            cwd: cwd,
            timeout: timeout,
            outputMode: .separate
        )
        return RunResult(
            exitCode: result.exitCode,
            stdout: result.stdoutString,
            stderr: result.stderrString
        )
    }

    // MARK: - File helpers

    static func isText(_ data: Data) -> Bool {
        let sample = data.prefix(1024)
        if sample.isEmpty { return true }
        var nonText = 0
        for byte in sample {
            if byte == 0 { return false }
            if (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) || byte == 0x7F {
                nonText += 1
            }
        }
        return Double(nonText) / Double(sample.count) <= 0.3
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

    /// Set of canonical resolved paths to skip in a directory walk, built
    /// from `exclude_paths` entries resolved like `path`. Entries that don't
    /// exist (e.g. a worktree-relative exclusion in a directory that lacks
    /// it) are dropped; the residual plain `rel` values then can't match
    /// anything.
    static func excludePathSet(_ args: [String: Any], workdir: Workdir) throws -> Set<String>? {
        guard let raw = try optionalStringArray(args, "exclude_paths"), !raw.isEmpty else { return nil }
        var excluded: Set<String> = []
        for e in raw {
            guard !e.isEmpty else { continue }
            let r = try workdir.resolve(e)
            excluded.insert(canonicalPath(r))
        }
        return excluded.isEmpty ? nil : excluded
    }

    /// An excluded directory (or any ancestor of one) doesn't need its
    /// children visited — prune the whole subtree instead of filtering every
    /// descendant individually.
    static func shouldSkip(_ canonical: String, _ excluded: Set<String>) -> Bool {
        if excluded.contains(canonical) { return true }
        var parent = (canonical as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if excluded.contains(parent) { return true }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return parent == "/" && excluded.contains("/")
    }

    /// Strips ANSI/VT100 escape sequences (colors, cursor moves, OSC title
    /// setters) from captured process output so the model sees plain text.
    /// Used by the shell tool for both local and SSH execution.
    static let ansiRegex: NSRegularExpression = {
        // CSI (ESC [ ... final) | OSC (ESC ] ... BEL/ST) | other 2-char ESC seqs.
        let pattern =
            "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)|\u{001B}\\[[0-?]*[ -/]*[@-~]|\u{001B}[@-Z\\\\-_]"
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func stripAnsi(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return ansiRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private static let maxShellOutput = 10000
    private static let shellOutputHead = 1000
    private static let shellOutputTail = 9000

    /// Truncates shell output to `maxShellOutput` characters, keeping the
    /// first `shellOutputHead` and last `shellOutputTail` characters with a
    /// marker at the cut point so the model knows output was elided.
    static func truncateOutput(_ text: String) -> String {
        guard text.count > maxShellOutput else { return text }
        let head = text.prefix(shellOutputHead)
        let tail = text.suffix(shellOutputTail)
        return "\(head)...\n[truncated to \(maxShellOutput) chars]\n...\(tail)"
    }

    /// POSIX permission bits (0o0000–0o7777) of an existing path, or nil when
    /// the path doesn't exist. Used to preserve the executable bit (and any
    /// custom mode) across the inode swap that `Data.write(.atomic)` performs.
    static func filePermissions(at path: String) -> UInt16? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let mode = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return UInt16(truncating: mode) & 0o7777
    }

    /// Glob matcher for `find_file` and `find_text`'s `file_pattern`. Supports
    /// `*` (any run within one path component), `?` (single character),
    /// `[...]` (character class, `!` or `^` negates) and `**` (any number of
    /// path components). Patterns containing `/` match the entry's path
    /// relative to the search root, otherwise the filename of every entry.
    struct GlobMatcher {
        private let regex: NSRegularExpression
        let isPathPattern: Bool

        init(pattern: String, caseInsensitive: Bool = false) throws {
            isPathPattern = pattern.contains("/")
            regex = try NSRegularExpression(
                pattern: Self.toRegex(pattern),
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
                        if chars[j] == "]" {
                            closed = true
                            j += 1
                            break
                        }
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
        return ToolOutput(content: trimmed, isError: false)
    }

    private static func datetime() -> ToolOutput {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return ToolOutput(content: f.string(from: Date()), isError: false)
    }

    private static func uuid() -> ToolOutput {
        ToolOutput(content: UUID().uuidString, isError: false)
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
        return ToolOutput(content: digest, isError: false)
    }

    private static func base64Encode(_ args: [String: Any]) throws -> ToolOutput {
        let input = try requireString(args, "input")
        guard let data = input.data(using: .utf8) else {
            throw BuiltinToolError("invalid argument 'input': could not encode as UTF-8")
        }
        return ToolOutput(content: data.base64EncodedString(), isError: false)
    }

    private static func base64Decode(_ args: [String: Any]) throws -> ToolOutput {
        let input = try requireString(args, "input")
        guard let data = Data(base64Encoded: input) else {
            throw BuiltinToolError("invalid argument 'input': not valid base64")
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw BuiltinToolError("invalid argument 'input': decoded bytes are not valid UTF-8")
        }
        return ToolOutput(content: s, isError: false)
    }

    private static func sleepTool(_ args: [String: Any]) async throws -> ToolOutput {
        var seconds = try requireDouble(args, "seconds")
        seconds = min(max(seconds, 0), 3600)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return ToolOutput(content: "Slept for \(seconds) seconds.", isError: false)
    }

    private static func randTool(_ args: [String: Any]) throws -> ToolOutput {
        let minVal = optionalInt(args, "min") ?? 0
        let maxVal = optionalInt(args, "max") ?? 100
        guard minVal <= maxVal else {
            throw BuiltinToolError("invalid argument 'min': must be <= max")
        }
        return ToolOutput(content: "\(Int.random(in: minVal...maxVal))", isError: false)
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
            guard
                let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isDirectoryKey],
                    options: enumOptions)
            else {
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
            let urls =
                (try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isDirectoryKey],
                    options: enumOptions)) ?? []
            for url in urls {
                let name = url.lastPathComponent
                let isD = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                lines.append(isD ? "\(name)/" : name)
            }
            lines.sort()
        }
        return ToolOutput(content: lines.prefix(maxEntries).joined(separator: "\n"), isError: false)
    }

    private static func readFile(_ args: [String: Any], workdir: Workdir, chatFilename: String) throws -> ToolOutput {
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
        return try formatFileContent(data, path: path, offset: offset, limit: limit, chatFilename: chatFilename)
    }

    /// Shared read_file formatting pipeline (classification, document/image
    /// extraction, text slicing with line numbers, truncation), used by both
    /// the local and the SSH-backed implementations once the raw bytes are in
    /// hand. Text files are returned with line numbers; document binaries
    /// (docx/odt/rtf/pdf) are extracted to text first; images are processed
    /// (resized/re-encoded) and returned with a classification+OCR fallback so
    /// the request builders can send them as image blocks on vision-capable
    /// connections and the fallback text on vision-incapable ones — exactly
    /// like user-attached images.
    static func formatFileContent(_ data: Data, path: String, offset: Int, limit: Int, chatFilename: String) throws
        -> ToolOutput
    {
        let hint = DocumentTypeHint(filename: path)
        let kind = DocumentClassifier.classify(data: data, hint: hint)

        switch kind {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                throw BuiltinToolError("invalid argument 'path': file is not valid UTF-8: \(path)")
            }
            return formatTextLines(text, path: path, offset: offset, limit: limit)

        case .document(let format):
            switch DocumentExtractor.extract(data: data, format: format) {
            case .success(let extraction):
                // Extracted text is not the file on disk — a hash tag would be
                // meaningless and line numbers misleading, so return as-is.
                let slice = sliceText(extraction.text, offset: offset, limit: limit)
                var doc = slice.lines.joined(separator: "\n")
                if slice.truncated {
                    doc += "\n... (truncated at 2000 lines)"
                }
                return ToolOutput(content: doc, isError: false)
            case .unsupported(_, let reason):
                return ToolOutput(content: "Could not extract \(path): \(reason)", isError: false)
            case .failed(let reason):
                return ToolOutput(content: "Failed to extract \(path): \(reason)", isError: false)
            }

        case .image:
            return formatImageContent(data, path: path)

        case .unsupportedBinary:
            return ToolOutput(
                content:
                    "Binary file \(path) is not a supported format. Only text, document (docx/doc/odt/rtf/pdf), and image files can be read.",
                isError: false)
        }
    }

    /// Processes an image read by `read_file`: resizes/re-encodes it and
    /// generates the classification+OCR fallback. The processed image bytes
    /// are returned on the `ToolOutput` (no attachment file is written to
    /// disk); the request builders send them as an image block on
    /// vision-capable connections and the fallback text on vision-incapable
    /// ones. The `content` is the fallback text (classification + OCR), so a
    /// vision-incapable connection gets a useful textual description directly
    /// in the tool result.
    private static func formatImageContent(_ data: Data, path: String) -> ToolOutput {
        guard let processed = ImageProcessor.process(data) else {
            return ToolOutput(
                content: "Could not process image \(path): unsupported or undecodable image format.", isError: false)
        }
        let mimeType = imageMimeType(for: processed.data) ?? "image/\(processed.ext)"
        let fallback = ImageFallbackSynthesizer.fallback(for: data)
        let image = ProcessedToolImage(data: processed.data, mimeType: mimeType, fallback: fallback)
        return ToolOutput(content: fallback, isError: false, image: image)
    }

    /// Slices text into an offset/limit window. Returns the windowed lines and
    /// whether more content follows beyond the hard 2000-line cap. A lone empty
    /// line (a file containing just a newline) stays addressable: the file has
    /// no lines only when the text itself is empty.
    private static func sliceText(_ text: String, offset: Int, limit: Int) -> (lines: [String], truncated: Bool) {
        if text.isEmpty { return ([], false) }
        let lines = text.components(separatedBy: "\n")
        let cleaned: [String] = lines.last?.isEmpty ?? false ? Array(lines.dropLast()) : lines

        let hardLimit = 2000
        let effectiveLimit = min(limit, hardLimit)
        let startIdx = offset - 1
        guard startIdx < cleaned.count else {
            return ([], false)
        }
        let endIdx = min(startIdx + effectiveLimit, cleaned.count)
        return (Array(cleaned[startIdx..<endIdx]), endIdx - startIdx == hardLimit && cleaned.count > endIdx)
    }

    /// Formats text as hashline output: a `[path#TAG]` header (tag computed
    /// from the full file text, so partial reads still anchor edits to the
    /// whole file) followed by unpadded `N:content` lines. The hash comes from
    /// the full `text`, not the visible slice.
    private static func formatTextLines(_ text: String, path: String, offset: Int, limit: Int) -> ToolOutput {
        let slice = sliceText(text, offset: offset, limit: limit)
        guard !slice.lines.isEmpty else {
            return ToolOutput(content: "", isError: false)
        }
        let tag = HashlineFormat.computeFileHash(text)
        var out: [String] = []
        out.append(HashlineFormat.formatHashlineHeader(path: path, fileHash: tag))
        for (i, line) in slice.lines.enumerated() {
            out.append(HashlineFormat.formatNumberedLine(lineNumber: offset + i, content: line))
        }
        if slice.truncated {
            out.append("... (truncated at 2000 lines)")
        }
        return ToolOutput(content: out.joined(separator: "\n"), isError: false)
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
        let content = HashlineFormat.stripPastedPrefixes(try requireString(args, "content"))
        let resolved = try workdir.resolve(path)

        let fm = FileManager.default
        let dir = (resolved as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // Atomic write swaps the inode, which resets the mode to the umask
        // default — preserve the existing file's permissions (e.g. the
        // executable bit) across the swap.
        let savedMode = filePermissions(at: resolved)
        let data = Data(content.utf8)
        try data.write(to: URL(fileURLWithPath: resolved), options: .atomic)
        if let savedMode {
            try? fm.setAttributes([.posixPermissions: savedMode], ofItemAtPath: resolved)
        }
        return ToolOutput(content: "Wrote \(data.count) bytes to \(path)", isError: false)
    }

    /// Edits existing text files with a hashline patch. The #TAG in each
    /// section header is validated against the file's current content, then
    /// line edits are applied and written back with a direct (non-atomic)
    /// write — the inode survives, so permissions, owner, and extended
    /// attributes are preserved without a save/restore dance. Only UTF-8
    /// text files are editable; everything else must be replaced via
    /// `write_file`.
    private static func editFile(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let input = try requireString(args, "input")
        let patch = try HashlineEdit.parse(input)

        var summaries: [String] = []
        for section in patch.sections {
            let resolved = try workdir.resolve(section.path)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
                throw BuiltinToolError("invalid argument 'input': file not found: \(section.path)")
            }
            if isDir.boolValue {
                throw BuiltinToolError("invalid argument 'input': is a directory: \(section.path)")
            }
            guard let data = fm.contents(atPath: resolved) else {
                throw BuiltinToolError("invalid argument 'input': could not read: \(section.path)")
            }
            guard let currentContent = String(data: data, encoding: .utf8) else {
                throw BuiltinToolError(
                    "File \(section.path) is not a text file and cannot be edited with edit_file. Use write_file to replace it entirely."
                )
            }

            let result: ApplyResult
            do {
                result = try HashlineEdit.applySection(section, fileContent: currentContent)
            } catch let err as HashlineEditError {
                if case .noop(let path) = err {
                    summaries.append("No changes to \(path).")
                    continue
                }
                throw BuiltinToolError(err.localizedDescription)
            }

            switch section.fileOp {
            case .rem:
                // Hash validated above; delete the file outright.
                try fm.removeItem(atPath: resolved)
                summaries.append("Deleted: \(section.path)")
            case .move(let dest):
                let resolvedDest = try workdir.resolve(dest)
                let destDir = (resolvedDest as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: destDir) {
                    try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
                }
                try Data(result.text.utf8).write(to: URL(fileURLWithPath: resolvedDest))
                try fm.removeItem(atPath: resolved)
                let newTag = HashlineFormat.computeFileHash(result.text)
                summaries.append("Updated: \(section.path) [\(dest)#\(newTag)]")
            case nil:
                try Data(result.text.utf8).write(to: URL(fileURLWithPath: resolved))
                let newTag = HashlineFormat.computeFileHash(result.text)
                summaries.append("Updated: \(section.path) [\(section.path)#\(newTag)]")
            }
        }
        return ToolOutput(content: summaries.joined(separator: "\n"), isError: false)
    }

    private static func findFile(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let pattern = try requireString(args, "pattern")
        let searchRoot = optionalString(args, "path") ?? workdir.defaultRoot
        let caseInsensitive = optionalBool(args, "case_insensitive") ?? false
        let includeHidden = optionalBool(args, "include_hidden") ?? false
        let resolved = try workdir.resolve(searchRoot)
        let excluded = try excludePathSet(args, workdir: workdir)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            throw BuiltinToolError("invalid argument 'path': not a directory: \(searchRoot)")
        }

        let glob = try GlobMatcher(pattern: pattern, caseInsensitive: caseInsensitive)
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard
            let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isDirectoryKey], options: options)
        else {
            throw BuiltinToolError("invalid argument 'path': failed to enumerate: \(searchRoot)")
        }
        // Matches are collected fully, then sorted, so the 200-cap truncation
        // is deterministic instead of raw walk order. The enumerator returns
        // symlink-resolved paths (/var → /private/var on macOS), so relativize
        // against the canonical root.
        let root = canonicalPath(resolved)
        var matches: [String] = []
        for case let url as URL in enumerator {
            if let excluded, shouldSkip(url.path, excluded) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let rel = relativize(url.path, root: root)
            if glob.matches(filename: url.lastPathComponent, relativePath: rel) {
                matches.append(rel)
            }
        }
        matches.sort()
        var out = matches.prefix(200).joined(separator: "\n")
        if matches.count > 200 { out += "\n... (truncated at 200 results)" }
        return ToolOutput(content: out, isError: false)
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
        let excluded = try excludePathSet(args, workdir: workdir)

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
            guard
                let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: resolved),
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: options)
            else {
                throw BuiltinToolError("invalid argument 'path': failed to enumerate: \(searchRoot)")
            }
            let root = canonicalPath(resolved)
            let jailBase = workdir.isolated ? workdir.displayPath(forResolved: resolved) : nil
            while let url = enumerator.nextObject() as? URL {
                if let excluded, shouldSkip(url.path, excluded) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
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
            if !(excluded?.contains(canonicalPath(resolved)) ?? false) {
                files = [(resolved, workdir.displayPath(forResolved: resolved))]
            }
        }

        var out: [String] = []
        var matchCount = 0
        var outBytes = 0
        var hitResultCap = false
        var hitByteCap = false

        fileLoop: for (file, display) in files {
            guard let data = fm.contents(atPath: file), isText(data),
                let text = String(data: data, encoding: .utf8)
            else { continue }
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

            // One hashline header per file, then 'N:content' lines for matches
            // and context (context uses '-', matching lines ':').
            let tag = HashlineFormat.computeFileHash(text)
            let header = HashlineFormat.formatHashlineHeader(path: display, fileHash: tag)
            var headerEmitted = false
            for group in groups {
                if context > 0, !out.isEmpty {
                    out.append("--")
                    outBytes += 3
                }
                if !headerEmitted {
                    out.append(header)
                    outBytes += header.utf8.count + 1
                    headerEmitted = true
                }
                for i in group.range {
                    let isMatch = matching.contains(i)
                    if isMatch {
                        if matchCount >= maxResults {
                            hitResultCap = true
                            break fileLoop
                        }
                        matchCount += 1
                    }
                    if outBytes >= Self.findTextMaxOutputBytes {
                        hitByteCap = true
                        break fileLoop
                    }
                    let content = truncateMatchLine(lines[i])
                    let line = "\(i + 1)\(isMatch ? ":" : "-")\(content)"
                    out.append(line)
                    outBytes += line.utf8.count + 1
                }
            }
        }

        var result = out.joined(separator: "\n")
        if hitResultCap {
            result += "\n... (truncated at \(maxResults) results)"
        } else if hitByteCap {
            result += "\n... (truncated, output size limit)"
        }
        return ToolOutput(content: result, isError: false)
    }

    private static func mkdir(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let path = try requireString(args, "path")
        let resolved = try workdir.resolve(path)
        try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true)
        return ToolOutput(content: "Created directory \(path)", isError: false)
    }

    private static func mv(_ args: [String: Any], workdir: Workdir) throws -> ToolOutput {
        let src = try requireString(args, "src")
        let dst = try requireString(args, "dst")
        let resolvedSrc = try workdir.resolve(src)
        let resolvedDst = try workdir.resolve(dst)
        try FileManager.default.moveItem(atPath: resolvedSrc, toPath: resolvedDst)
        return ToolOutput(content: "Moved \(src) to \(dst)", isError: false)
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
                throw BuiltinToolError(
                    "invalid argument 'path': directory is not empty; use recursive: true to delete it")
            }
        }
        try fm.removeItem(atPath: resolved)
        return ToolOutput(content: "Deleted \(path)", isError: false)
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
        return ToolOutput(content: "{\(parts.joined(separator: ","))}", isError: false)
    }

    private static func pwd(_ workdir: Workdir) -> ToolOutput {
        ToolOutput(content: workdir.currentDirectory, isError: false)
    }

    // MARK: - Shell tools

    private static func shell(_ args: [String: Any], workdir: Workdir) async throws -> ToolOutput {
        let command = try requireString(args, "command")
        let cwd = try workdir.resolve(optionalString(args, "cwd") ?? workdir.defaultCwd)
        let timeout = optionalInt(args, "timeout").map { TimeInterval($0) }

        let input = "cd \"\(cwd)\"\n\(command)\n"
        let result = await ProcessRunner.run(
            executable: shellPath,
            arguments: ["-l"],
            stdin: Data(input.utf8),
            cwd: cwd,
            timeout: timeout,
            outputMode: .merged
        )
        let text = truncateOutput(stripAnsi(result.stdoutString))
        if result.exitCode == -1, let timeout {
            return ToolOutput(content: "\(text)\n[exit code: timed out after \(Int(timeout))s]", isError: false)
        }
        return ToolOutput(content: "\(text)\n[exit code: \(result.exitCode)]", isError: false)
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
            return ToolOutput(content: "AppleScript error: \(errorMessage) (number \(number))", isError: false)
        }
        return ToolOutput(content: result.output ?? "", isError: false)
    }
}
