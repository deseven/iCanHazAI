// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// SSH-backed implementations of the Filesystem, Code, and Shell builtin
/// tools, used when the chat's working directory is an `ssh::host/path` spec
/// (see [`Workdir`](src/BuiltinTools.swift:11) and
/// [`SSHManager`](src/SSHManager.swift:47)).
///
/// Every tool is a small POSIX sh script piped into `ssh -T -S <sock> host`
/// stdin (no remote command argv, so there is exactly one shell-quoting
/// layer). Remote paths are escaped with POSIX single-quote rules via `q()`.
/// The script's exit code is the last command's, which doubles as the tool's
/// success signal; scripts print user-facing reasons to stderr before
/// exiting non-zero, mirroring the local tools' error messages.
enum BuiltinToolsSSH {

    /// Per-call ceiling for filesystem/code operations. The shell tool has
    /// its own timeout policy (explicit timeout, or an idle watchdog).
    private static let fileOpTimeout: TimeInterval = 30

    /// Idle watchdog for the shell tool when the caller didn't pass an
    /// explicit timeout: killed after this long without stdout/stderr output.
    static let shellIdleTimeout: TimeInterval = 120

    /// The connection manager backing all remote exec. A `var` so tests can
    /// point it at a throwaway socket directory (the test suite is
    /// serialized, so swapping is race-free).
    nonisolated(unsafe) static var manager = SSHManager.shared

    // MARK: - Script plumbing

    /// POSIX single-quote escaping: wrap in quotes, turn embedded `'` into
    /// `'\''` (close, escaped quote, reopen).
    static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// String-only dirname for remote paths (never touches the local FS).
    static func posixDirname(_ path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "." }
        if idx == path.startIndex { return "/" }
        return String(path[path.startIndex..<idx])
    }

    private static func run(_ ssh: SSHContext, script: String, stdin: Data? = nil,
                            hardTimeout: TimeInterval? = fileOpTimeout,
                            idleTimeout: TimeInterval? = nil) async throws -> SSHManager.RunResult {
        var data = Data(script.utf8)
        if !script.hasSuffix("\n") { data.append(0x0A) }
        if let stdin { data.append(stdin) }
        return try await manager.exec(ssh, stdin: data, hardTimeout: hardTimeout, idleTimeout: idleTimeout)
    }

    /// Maps timeout kills and non-zero exits to tool errors. stderr carries
    /// the reason — either the script's own message or ssh's (exit 255).
    private static func requireSuccess(_ r: SSHManager.RunResult) throws {
        if let failure = r.failure {
            switch failure {
            case .hardTimeout(let t):
                throw BuiltinToolError("remote command timed out after \(Int(t))s")
            case .idleTimeout(let t):
                throw BuiltinToolError("remote command produced no output for \(Int(t))s and was killed")
            }
        }
        guard r.exitCode == 0 else {
            let err = r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BuiltinToolError(err.isEmpty ? "remote command failed (exit code \(r.exitCode))" : err)
        }
    }

    // MARK: - Dispatch

    static func filesystem(name: String, args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        switch name {
        case "ls": return try await ls(args, workdir: workdir, ssh: ssh)
        case "read_file": return try await readFile(args, workdir: workdir, ssh: ssh)
        case "write_file": return try await writeFile(args, workdir: workdir, ssh: ssh)
        case "find_file": return try await findFile(args, workdir: workdir, ssh: ssh)
        case "find_text": return try await findText(args, workdir: workdir, ssh: ssh)
        case "mkdir": return try await mkdir(args, workdir: workdir, ssh: ssh)
        case "mv": return try await mv(args, workdir: workdir, ssh: ssh)
        case "rm": return try await rm(args, workdir: workdir, ssh: ssh)
        case "stat": return try await stat(args, workdir: workdir, ssh: ssh)
        case "pwd": return try await pwd(workdir: workdir, ssh: ssh)
        default:
            throw BuiltinToolError("Unknown tool \"\(name)\" in group \"Filesystem\".")
        }
    }

    static func code(name: String, args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        switch name {
        case "apply_patch": return try await applyPatch(args, workdir: workdir, ssh: ssh)
        case "git": return try await git(args, workdir: workdir, ssh: ssh)
        default:
            throw BuiltinToolError("Unknown tool \"\(name)\" in group \"Code\".")
        }
    }

    // MARK: - Filesystem tools

    private static func ls(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let recursive = BuiltinTools.optionalBool(args, "recursive") ?? false
        let resolved = try workdir.resolve(path)

        let script: String
        if recursive {
            // Mirrors the local semantics: direct children plus one level
            // into subdirectories, hidden entries skipped, paths relative to
            // the listed root, directories suffixed with '/'.
            script = """
            if [ ! -e \(q(resolved)) ]; then printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
            if [ ! -d \(q(resolved)) ]; then printf 'not a directory: %s\\n' \(q(path)) >&2; exit 1; fi
            command -v find >/dev/null 2>&1 || { echo 'find: command not found on the remote host' >&2; exit 127; }
            cd \(q(resolved)) && find . -mindepth 1 -maxdepth 2 \\( -name '.*' ! -name . -prune \\) -o -print | while IFS= read -r p; do if [ -d "$p" ]; then printf '%s/\\n' "${p#./}"; else printf '%s\\n' "${p#./}"; fi; done
            """
        } else {
            script = """
            if [ ! -e \(q(resolved)) ]; then printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
            if [ ! -d \(q(resolved)) ]; then printf 'not a directory: %s\\n' \(q(path)) >&2; exit 1; fi
            ls -1Ap \(q(resolved))
            """
        }
        let r = try await run(ssh, script: script)
        try requireSuccess(r)
        let lines = r.stdoutString.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines.prefix(1000).joined(separator: "\n"), false)
    }

    private static func readFile(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let offset = BuiltinTools.optionalInt(args, "offset") ?? 1
        let limit = BuiltinTools.optionalInt(args, "limit") ?? 2000
        let resolved = try workdir.resolve(path)

        let script = """
        if [ ! -e \(q(resolved)) ]; then printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
        if [ -d \(q(resolved)) ]; then printf 'is a directory: %s\\n' \(q(path)) >&2; exit 1; fi
        cat \(q(resolved))
        """
        let r = try await run(ssh, script: script)
        try requireSuccess(r)
        return try BuiltinTools.formatFileContent(r.stdout, path: path, offset: offset, limit: limit)
    }

    private static func writeFile(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let content = try BuiltinTools.requireString(args, "content")
        let resolved = try workdir.resolve(path)

        // `cat >` consumes the raw bytes from the same stdin stream right
        // after the script line; EOF terminates it — no heredoc markers.
        let script = "mkdir -p \(q(posixDirname(resolved))) && cat > \(q(resolved))"
        let r = try await run(ssh, script: script, stdin: Data(content.utf8))
        try requireSuccess(r)
        return ("Wrote \(content.utf8.count) bytes to \(path)", false)
    }

    private static func findFile(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let pattern = try BuiltinTools.requireString(args, "pattern")
        let searchRoot = BuiltinTools.optionalString(args, "path") ?? workdir.root ?? "."
        let resolved = try workdir.resolve(searchRoot)

        let script = """
        if [ ! -d \(q(resolved)) ]; then printf 'not a directory: %s\\n' \(q(searchRoot)) >&2; exit 1; fi
        cd \(q(resolved)) && find . \\( -name '.*' ! -name . -prune \\) -o -name \(q(pattern)) -print
        """
        let r = try await run(ssh, script: script)
        try requireSuccess(r)
        let matches = r.stdoutString.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
            let s = String(line)
            return s.hasPrefix("./") ? String(s.dropFirst(2)) : s
        }
        var out = matches.prefix(200).joined(separator: "\n")
        if matches.count > 200 { out += "\n... (truncated at 200 results)" }
        return (out, false)
    }

    private static func findText(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let regex = try BuiltinTools.requireString(args, "regex")
        let searchRoot = BuiltinTools.optionalString(args, "path") ?? workdir.root ?? "."
        let filePattern = BuiltinTools.optionalString(args, "file_pattern")
        let resolved = try workdir.resolve(searchRoot)

        var script = "grep -RIn"
        if let filePattern { script += " --include=\(q(filePattern))" }
        script += " \(q(regex)) \(q(resolved))"

        let r = try await run(ssh, script: script)
        if r.failure != nil || r.exitCode >= 2 {
            // grep: 0 = matches, 1 = none. Anything else (bad regex, missing
            // directory, grep not installed → 127, ssh failure → 255) is a
            // real error and surfaces its stderr to the model.
            try requireSuccess(r)
        }
        let output = r.stdoutString
        let cap = 64 * 1024
        if output.utf8.count > cap {
            let truncated = String(decoding: output.utf8.prefix(cap), as: UTF8.self)
            return (truncated + "\n... (truncated)", false)
        }
        return (output, false)
    }

    private static func mkdir(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let resolved = try workdir.resolve(path)
        let r = try await run(ssh, script: "mkdir -p \(q(resolved))")
        try requireSuccess(r)
        return ("Created directory \(path)", false)
    }

    private static func mv(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let src = try BuiltinTools.requireString(args, "src")
        let dst = try BuiltinTools.requireString(args, "dst")
        let resolvedSrc = try workdir.resolve(src)
        let resolvedDst = try workdir.resolve(dst)
        let r = try await run(ssh, script: "mv \(q(resolvedSrc)) \(q(resolvedDst))")
        try requireSuccess(r)
        return ("Moved \(src) to \(dst)", false)
    }

    private static func rm(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let recursive = BuiltinTools.optionalBool(args, "recursive") ?? false
        let resolved = try workdir.resolve(path)

        // Empty directories are removed with rmdir (rm without -r refuses
        // them), matching the local tool where a non-recursive delete of an
        // empty directory succeeds.
        let script = """
        if [ ! -e \(q(resolved)) ] && [ ! -L \(q(resolved)) ]; then printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
        if [ -d \(q(resolved)) ] && [ ! -L \(q(resolved)) ]; then
          if [ \(recursive ? 1 : 0) -eq 0 ]; then
            if [ -n "$(ls -A \(q(resolved)) 2>/dev/null)" ]; then printf 'directory is not empty; use recursive: true to delete it\\n' >&2; exit 1; fi
            rmdir \(q(resolved))
          else
            rm -r \(q(resolved))
          fi
        else
          rm \(q(resolved))
        fi
        """
        let r = try await run(ssh, script: script)
        try requireSuccess(r)
        return ("Deleted \(path)", false)
    }

    private static func stat(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let resolved = try workdir.resolve(path)

        // Portable metadata: try GNU stat, fall back to BSD. The header lines
        // are parsed back in Swift, which also assembles the JSON (so `file`
        // output never needs shell-side JSON escaping).
        let script = """
        p=\(q(resolved))
        if [ -L "$p" ]; then t=symlink; elif [ -d "$p" ]; then t=dir; elif [ -e "$p" ]; then t=file; else printf 'not found: %s\\n' "$p" >&2; exit 1; fi
        meta=$(stat -c '%s %Y %W' "$p" 2>/dev/null) || meta=$(stat -f '%z %m %B' "$p" 2>/dev/null) || meta=
        printf 'ICHAI-TYPE %s\\nICHAI-META %s\\nICHAI-FILE ' "$t" "$meta"
        file -b "$p" 2>/dev/null || true
        """
        let r = try await run(ssh, script: script)
        try requireSuccess(r)

        var type = "file"
        var size: Int64 = 0
        var mtime: TimeInterval = 0
        var birth: TimeInterval = 0
        var fileOut = ""

        let output = r.stdoutString
        let lines = output.components(separatedBy: "\n")
        var idx = 0
        if idx < lines.count, lines[idx].hasPrefix("ICHAI-TYPE ") {
            type = String(lines[idx].dropFirst("ICHAI-TYPE ".count))
            idx += 1
        }
        if idx < lines.count, lines[idx].hasPrefix("ICHAI-META ") {
            let fields = lines[idx].dropFirst("ICHAI-META ".count).split(separator: " ")
            if fields.count >= 1 { size = Int64(fields[0]) ?? 0 }
            if fields.count >= 2 { mtime = TimeInterval(fields[1]) ?? 0 }
            if fields.count >= 3 { birth = TimeInterval(fields[2]) ?? 0 }
            idx += 1
        }
        if idx < lines.count, lines[idx].hasPrefix("ICHAI-FILE ") {
            var rest = String(lines[idx].dropFirst("ICHAI-FILE ".count))
            if lines.count > idx + 1 {
                rest += "\n" + lines[(idx + 1)...].joined(separator: "\n")
            }
            fileOut = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let iso = ISO8601DateFormatter()
        var json: [String: String] = [
            "type": type,
            "size": "\(size)",
            "file": fileOut,
        ]
        if mtime > 0 { json["modified"] = iso.string(from: Date(timeIntervalSince1970: mtime)) }
        if birth > 0 { json["created"] = iso.string(from: Date(timeIntervalSince1970: birth)) }

        let sorted = json.sorted { $0.key < $1.key }
        let parts = sorted.map { "\"\($0.key)\":\"\(jsonEscape($0.value))\"" }
        return ("{\(parts.joined(separator: ","))}", false)
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func pwd(workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        // Isolated mode presents the root as the virtual "/" (local parity).
        if workdir.isolated { return ("/", false) }
        let script = workdir.root.map { "cd \(q($0)) && pwd" } ?? "pwd"
        let r = try await run(ssh, script: script)
        try requireSuccess(r)
        return (r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }

    // MARK: - Code tools

    /// Remote apply_patch: pre-fetch the content of every touched file,
    /// run the shared in-memory planner against that snapshot, then write the
    /// results back file by file. Read-modify-write without locking — a
    /// concurrent remote change between read and write would be silently
    /// clobbered; accepted for a single-user utility.
    private static func applyPatch(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let patch = try BuiltinTools.requireString(args, "patch")

        let ops: [PlannedPatchOp]
        do {
            let parsed = try PatchParser.parse(patch)

            var resolvedPaths: [String] = []
            for hunk in parsed.hunks {
                let path: String
                switch hunk {
                case .addFile(let p, _): path = p
                case .deleteFile(let p): path = p
                case .updateFile(let p, _, _): path = p
                }
                let resolved = try workdir.resolve(path)
                if !resolvedPaths.contains(resolved) { resolvedPaths.append(resolved) }
            }

            var remote: [String: (exists: Bool, data: Data?)] = [:]
            for resolved in resolvedPaths {
                remote[resolved] = try await fetchFile(ssh, resolved: resolved)
            }

            ops = try PatchApplier.plan(
                hunks: parsed.hunks,
                workdir: workdir,
                fileExists: { remote[$0]?.exists ?? false },
                fileContent: { resolved in
                    guard let f = remote[resolved], f.exists, let data = f.data else { return nil }
                    guard let s = String(data: data, encoding: .utf8) else {
                        throw ApplyPatchError(message: "\(resolved) is not readable as UTF-8")
                    }
                    return s
                }
            )
        } catch let e as PatchParseError {
            return ("Invalid apply_patch format: \(e.description)", true)
        } catch let e as ApplyPatchError {
            return ("Failed to apply patch: \(e.description)", true)
        } catch let e as BuiltinToolError {
            return ("Error: \(e.description)", true)
        }

        var summary: [String] = []
        for op in ops {
            switch op {
            case .addFile(let path, let resolved, let contents):
                try await remoteWrite(ssh, resolved: resolved, contents: contents)
                summary.append("Added: \(path)")
            case .deleteFile(let path, let resolved, _):
                let r = try await run(ssh, script: "rm \(q(resolved))")
                try requireSuccess(r)
                summary.append("Deleted: \(path)")
            case .updateFile(let path, let resolved, let movePath, let moveResolved, let chunkCount, _, let newContent):
                if let movePath, let moveResolved {
                    try await remoteWrite(ssh, resolved: moveResolved, contents: newContent)
                    let r = try await run(ssh, script: "rm \(q(resolved))")
                    try requireSuccess(r)
                    summary.append("Updated: \(path) → \(movePath) (\(chunkCount) hunks)")
                } else {
                    try await remoteWrite(ssh, resolved: resolved, contents: newContent)
                    summary.append("Updated: \(path) (\(chunkCount) hunks)")
                }
            }
        }
        return (summary.joined(separator: "\n"), false)
    }

    /// Fetches one remote file for the patch planner. The first stdout line
    /// is a status header (`<marker> file|dir|missing`); file bytes follow.
    private static func fetchFile(_ ssh: SSHContext, resolved: String) async throws -> (exists: Bool, data: Data?) {
        let marker = "ICHAI-\(UUID().uuidString)"
        let script = """
        if [ -e \(q(resolved)) ] || [ -L \(q(resolved)) ]; then
          if [ -d \(q(resolved)) ]; then printf '%s dir\\n' \(q(marker)); else printf '%s file\\n' \(q(marker)); cat \(q(resolved)); fi
        else
          printf '%s missing\\n' \(q(marker))
        fi
        """
        let r = try await run(ssh, script: script)
        try requireSuccess(r)

        let stdout = r.stdout
        guard let nl = stdout.firstIndex(of: 0x0A) else {
            throw BuiltinToolError("unexpected remote response while reading \(resolved)")
        }
        let header = String(decoding: stdout[stdout.startIndex..<nl], as: UTF8.self)
        if header == "\(marker) file" {
            return (true, Data(stdout[stdout.index(after: nl)...]))
        }
        if header == "\(marker) dir" { return (true, nil) }
        return (false, nil)
    }

    private static func remoteWrite(_ ssh: SSHContext, resolved: String, contents: String) async throws {
        let script = "mkdir -p \(q(posixDirname(resolved))) && cat > \(q(resolved))"
        let r = try await run(ssh, script: script, stdin: Data(contents.utf8))
        try requireSuccess(r)
    }

    private static func git(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let gitArgs = try BuiltinTools.requireStringArray(args, "args")
        if gitArgs.isEmpty {
            throw BuiltinToolError("invalid argument 'args': must not be empty")
        }
        if gitArgs.contains(where: { $0.contains("\0") }) {
            throw BuiltinToolError("invalid argument 'args': must not contain null bytes")
        }

        var script = workdir.root.map { "cd \(q($0)) && " } ?? ""
        script += "git"
        for a in gitArgs { script += " \(q(a))" }

        let r = try await run(ssh, script: script, hardTimeout: 120)
        try requireSuccess(SSHManager.RunResult(exitCode: r.exitCode == 255 ? r.exitCode : 0, stdout: r.stdout, stderr: r.stderr, failure: r.failure))

        if r.exitCode == 0 {
            return (r.stdoutString, false)
        }
        return ("\(r.stdoutString)\(r.stderrString)\n[exit code: \(r.exitCode)]", false)
    }

    // MARK: - Shell tool

    static func shell(args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let command = try BuiltinTools.requireString(args, "command")
        let timeout = BuiltinTools.optionalInt(args, "timeout").map { TimeInterval($0) }

        // `cd ... || exit 1` (not `cd ... &&`): a failed cd must abort the
        // whole script instead of running the command in the wrong directory,
        // and grouping isn't needed since exit stops everything anyway. The
        // script's exit code remains the command's.
        var script = ""
        let cwd = BuiltinTools.optionalString(args, "cwd") ?? workdir.root
        if let cwd, !cwd.isEmpty {
            let resolved = try workdir.resolve(cwd)
            script += "cd \(q(resolved)) || exit 1\n"
        }
        script += command

        // An explicit timeout is a hard kill (local semantics). Without one,
        // an idle watchdog kills the call after a stretch of output silence,
        // so a hung network can't hang the tool call indefinitely.
        let r = try await run(ssh, script: script,
                              hardTimeout: timeout,
                              idleTimeout: timeout == nil ? shellIdleTimeout : nil)

        var text = r.stdoutString
        switch r.failure {
        case .hardTimeout(let t):
            if !r.stderrString.isEmpty { text += r.stderrString }
            text += "\n[exit code: timed out after \(Int(t))s]"
            return (text, false)
        case .idleTimeout(let t):
            if !r.stderrString.isEmpty { text += r.stderrString }
            text += "\n[exit code: killed after \(Int(t))s without output; pass an explicit timeout for long-running silent commands]"
            return (text, false)
        case nil:
            break
        }

        if r.exitCode == 0 {
            return ("\(text)\n[exit code: 0]", false)
        }
        return ("\(text)\(r.stderrString)\n[exit code: \(r.exitCode)]", false)
    }
}
