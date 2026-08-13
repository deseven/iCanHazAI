// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// SSH-backed implementations of the Filesystem, Code, and Shell builtin
/// tools, used when the chat's working directory is an scp-style `host:/path`
/// spec
/// (see [`Workdir`](src/Tools/BuiltinTools.swift:11) and
/// [`SSHManager`](src/SSH/SSHManager.swift:47)).
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

    /// Maximum remote file size pulled over SSH for read_file before
    /// extraction. Matches the extractor's input ceiling so a remote binary
    /// document can't flood the SSH channel or local memory.
    static let readFileSizeLimit: Int = 256 * 1024 * 1024

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

    /// Quotes a resolved remote path like `q()`, but leaves a leading
    /// `~`/`~user` prefix unquoted so the remote shell performs tilde
    /// expansion (single quotes would freeze it). Resolution keeps the tilde
    /// as a literal prefix precisely so the remote side can expand it against
    /// the remote home — see [`Workdir.resolveRemote`](src/Tools/BuiltinTools.swift:120).
    static func qp(_ path: String) -> String {
        guard path.hasPrefix("~") else { return q(path) }
        guard let slash = path.firstIndex(of: "/") else { return path }
        let prefix = path[..<slash]
        let rest = path[path.index(after: slash)...]
        return prefix + "/" + q(String(rest))
    }

    /// String-only dirname for remote paths (never touches the local FS).
    static func posixDirname(_ path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "." }
        if idx == path.startIndex { return "/" }
        return String(path[path.startIndex..<idx])
    }

    /// `find` predicate excluding `exclude_paths` entries from a `cd <root>;
    /// find . ...` walk. Each entry is resolved like `path` (which enforces
    /// the jail, so escapes are rejected) and then expressed relative to the
    /// resolved search root. `-path` matches each path itself and the `/*`
    /// variant its whole subtree — no glob support, so excluding a directory
    /// always prunes it entirely. Entries outside the search root can never
    /// match and are dropped. Empty when there are no usable exclusions.
    static func findExcludePredicate(
        _ args: [String: Any], workdir: Workdir, resolvedRoot: String, caseInsensitive: Bool
    ) throws -> String {
        guard let excluded = try BuiltinTools.optionalStringArray(args, "exclude_paths") else { return "" }
        var frags: [String] = []
        for e in excluded where !e.isEmpty {
            var rel = try workdir.resolve(e)
            while rel.hasSuffix("/") { rel.removeLast() }
            // Relativize against the search root; outside entries can't
            // match anything in the walk.
            if rel == resolvedRoot {
                rel = ""
            } else if rel.hasPrefix(resolvedRoot + "/") {
                rel = String(rel.dropFirst(resolvedRoot.count + 1))
            } else {
                continue
            }
            if rel.isEmpty { continue }
            let flag = caseInsensitive ? "-ipath" : "-path"
            frags.append("\(flag) \(q("./" + rel)) -o \(flag) \(q("./" + rel + "/*"))")
        }
        return frags.isEmpty ? "" : "-not \\( " + frags.joined(separator: " -o ") + " \\) "
    }

    private static func run(
        _ ssh: SSHContext, script: String, stdin: Data? = nil,
        hardTimeout: TimeInterval? = fileOpTimeout,
        idleTimeout: TimeInterval? = nil
    ) async throws -> SSHManager.RunResult {
        var data = Data(script.utf8)
        if !script.hasSuffix("\n") { data.append(0x0A) }
        if let stdin { data.append(stdin) }
        return try await manager.exec(ssh, stdin: data, hardTimeout: hardTimeout, idleTimeout: idleTimeout)
    }

    /// Maps timeout kills and non-zero exits to tool errors. stderr carries
    /// the reason — either the script's own message or ssh's (exit 255).
    /// `scrubbing` rewrites resolved remote paths in the error text to their
    /// display spelling, so isolated mode never leaks the real remote layout
    /// through a remote binary's stderr (mv/rm/mkdir/grep all embed paths).
    private static func requireSuccess(
        _ r: SSHManager.RunResult, scrubbing paths: [(resolved: String, display: String)] = []
    ) throws {
        if let failure = r.failure {
            switch failure {
            case .hardTimeout(let t):
                throw BuiltinToolError("remote command timed out after \(Int(t))s")
            case .idleTimeout(let t):
                throw BuiltinToolError("remote command produced no output for \(Int(t))s and was killed")
            }
        }
        guard r.exitCode == 0 else {
            var err = r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            for (resolved, display) in paths where resolved != display {
                err = err.replacingOccurrences(of: resolved, with: display)
            }
            throw BuiltinToolError(err.isEmpty ? "remote command failed (exit code \(r.exitCode))" : err)
        }
    }

    // MARK: - Dispatch

    static func filesystem(name: String, args: [String: Any], workdir: Workdir, ssh: SSHContext, chatFilename: String)
        async throws -> ToolOutput
    {
        switch name {
        case "ls": return try await ls(args, workdir: workdir, ssh: ssh)
        case "read_file": return try await readFile(args, workdir: workdir, ssh: ssh, chatFilename: chatFilename)
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

    static func code(name: String, args: [String: Any], workdir: Workdir, ssh: SSHContext, chatFilename: String)
        async throws -> ToolOutput
    {
        switch name {
        case "edit_file": return try await editFile(args, workdir: workdir, ssh: ssh)
        default:
            throw BuiltinToolError("Unknown tool \"\(name)\" in group \"Code\".")
        }
    }

    // MARK: - Filesystem tools

    private static func ls(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let recursive = BuiltinTools.optionalBool(args, "recursive") ?? false
        let includeHidden = BuiltinTools.optionalBool(args, "include_hidden") ?? false
        let resolved = try workdir.resolve(path)

        let script: String
        if recursive {
            // Mirrors the local semantics: direct children plus one level
            // into subdirectories, hidden entries (dotfiles — POSIX remotes
            // have no UF_HIDDEN) skipped unless requested, paths relative to
            // the listed root, directories suffixed with '/', sorted so the
            // 1000-entry cap is deterministic.
            let prune = includeHidden ? "" : "\\( -name '.*' ! -name . -prune \\) -o "
            script = """
                if [ ! -e \(qp(resolved)) ]; then printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
                if [ ! -d \(qp(resolved)) ]; then printf 'not a directory: %s\\n' \(q(path)) >&2; exit 1; fi
                command -v find >/dev/null 2>&1 || { echo 'find: command not found on the remote host' >&2; exit 127; }
                cd \(qp(resolved)) && find . -mindepth 1 -maxdepth 2 \(prune)-print | while IFS= read -r p; do if [ -d "$p" ]; then printf '%s/\\n' "${p#./}"; else printf '%s\\n' "${p#./}"; fi; done | sort
                """
        } else {
            script = """
                if [ ! -e \(qp(resolved)) ]; then printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
                if [ ! -d \(qp(resolved)) ]; then printf 'not a directory: %s\\n' \(q(path)) >&2; exit 1; fi
                ls -1\(includeHidden ? "A" : "")p \(qp(resolved))
                """
        }
        let r = try await run(ssh, script: script)
        try requireSuccess(r, scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
        let lines = r.stdoutString.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return ToolOutput(content: lines.prefix(1000).joined(separator: "\n"), isError: false)
    }

    private static func readFile(_ args: [String: Any], workdir: Workdir, ssh: SSHContext, chatFilename: String)
        async throws -> ToolOutput
    {
        let path = try BuiltinTools.requireString(args, "path")
        let offset = BuiltinTools.optionalInt(args, "offset") ?? 1
        let limit = BuiltinTools.optionalInt(args, "limit") ?? 2000
        let resolved = try workdir.resolve(path)

        // Stat the remote file first and refuse oversized files before
        // pulling bytes for extraction. GNU stat uses -c, BSD stat uses -f;
        // the first that succeeds wins. The size is printed to stdout on a
        // marker line, then cat follows on the same stream.
        let script = """
            if [ ! -e \(qp(resolved)) ]; then printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
            if [ -d \(qp(resolved)) ]; then printf 'is a directory: %s\\n' \(q(path)) >&2; exit 1; fi
            sz=$(stat -c '%s' \(qp(resolved)) 2>/dev/null || stat -f '%z' \(qp(resolved)) 2>/dev/null || echo 0)
            if [ "$sz" -gt \(readFileSizeLimit) ]; then printf 'file is %s bytes; exceeds the %s byte read limit\\n' "$sz" "\(readFileSizeLimit)" >&2; exit 1; fi
            cat \(qp(resolved))
            """
        let r = try await run(ssh, script: script)
        try requireSuccess(r, scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
        return try BuiltinTools.formatFileContent(
            r.stdout, path: path, offset: offset, limit: limit, chatFilename: chatFilename)
    }

    private static func writeFile(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let content = HashlineFormat.stripPastedPrefixes(try BuiltinTools.requireString(args, "content"))
        let resolved = try workdir.resolve(path)

        // `cat >` consumes the raw bytes from the same stdin stream right
        // after the script line; EOF terminates it — no heredoc markers.
        let script = "mkdir -p \(qp(posixDirname(resolved))) && cat > \(qp(resolved))"
        let r = try await run(ssh, script: script, stdin: Data(content.utf8))
        try requireSuccess(r, scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
        return ToolOutput(content: "Wrote \(content.utf8.count) bytes to \(path)", isError: false)
    }

    /// Edits a remote text file with a hashline patch. Hash computation and
    /// edit application are local operations on the fetched content — only
    /// the read (`cat`) and the write-back (`cat >`) go over SSH, keeping
    /// latency to two round-trips per file. `REM`/`MV` still validate the
    /// #TAG against the source file before touching it.
    private static func editFile(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let input = try BuiltinTools.requireString(args, "input")
        let patch = try HashlineEdit.parse(input)

        var summaries: [String] = []
        for section in patch.sections {
            let resolved = try workdir.resolve(section.path)

            let remote = try await fetchFile(ssh, resolved: resolved)
            guard remote.exists, let data = remote.data else {
                throw BuiltinToolError("invalid argument 'input': file not found: \(section.path)")
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
                try requireSuccess(
                    try await run(ssh, script: "rm \(qp(resolved))"),
                    scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
                summaries.append("Deleted: \(section.path)")
            case .move(let dest):
                let resolvedDest = try workdir.resolve(dest)
                let write = try await run(
                    ssh,
                    script: "mkdir -p \(qp(posixDirname(resolvedDest))) && cat > \(qp(resolvedDest))",
                    stdin: Data(result.text.utf8))
                try requireSuccess(
                    write, scrubbing: [(resolvedDest, workdir.displayPath(forResolved: resolvedDest))])
                try requireSuccess(
                    try await run(ssh, script: "rm \(qp(resolved))"),
                    scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
                let newTag = HashlineFormat.computeFileHash(result.text)
                summaries.append("Updated: \(section.path) [\(dest)#\(newTag)]")
            case nil:
                let write = try await run(
                    ssh, script: "cat > \(qp(resolved))", stdin: Data(result.text.utf8))
                try requireSuccess(
                    write, scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
                let newTag = HashlineFormat.computeFileHash(result.text)
                summaries.append("Updated: \(section.path) [\(section.path)#\(newTag)]")
            }
        }
        return ToolOutput(content: summaries.joined(separator: "\n"), isError: false)
    }

    private static func findFile(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let pattern = try BuiltinTools.requireString(args, "pattern")
        // Default search root: the jail "/" when isolated (passing the raw
        // remote root through resolve would double it), else the root itself.
        let searchRoot = BuiltinTools.optionalString(args, "path") ?? (workdir.isolated ? "/" : workdir.root ?? ".")
        let caseInsensitive = BuiltinTools.optionalBool(args, "case_insensitive") ?? false
        let includeHidden = BuiltinTools.optionalBool(args, "include_hidden") ?? false
        let resolved = try workdir.resolve(searchRoot)

        let exclude = try findExcludePredicate(
            args, workdir: workdir, resolvedRoot: resolved, caseInsensitive: caseInsensitive)

        // find's fnmatch natively supports *, ? and [...]; with -path its
        // wildcards also cross '/', which approximates '**' (zero-or-more
        // components is handled by additionally matching with '**/' removed).
        let predicate: String
        if pattern.contains("/") {
            var variants = ["./" + pattern]
            if pattern.contains("**/") {
                variants.append("./" + pattern.replacingOccurrences(of: "**/", with: ""))
            }
            let flag = caseInsensitive ? "-ipath" : "-path"
            predicate = "\\( " + variants.map { "\(flag) \(q($0))" }.joined(separator: " -o ") + " \\)"
        } else {
            let flag = caseInsensitive ? "-iname" : "-name"
            predicate = "\(flag) \(q(pattern))"
        }
        let prune = includeHidden ? "" : "\\( -name '.*' ! -name . -prune \\) -o "

        let script = """
            if [ ! -d \(qp(resolved)) ]; then printf 'not a directory: %s\\n' \(q(searchRoot)) >&2; exit 1; fi
            cd \(qp(resolved)) && find . \(prune)\(exclude)\(predicate) -print | sort
            """
        let r = try await run(ssh, script: script)
        try requireSuccess(r, scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
        let matches = r.stdoutString.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
            let s = String(line)
            return s.hasPrefix("./") ? String(s.dropFirst(2)) : s
        }
        var out = matches.prefix(200).joined(separator: "\n")
        if matches.count > 200 { out += "\n... (truncated at 200 results)" }
        return ToolOutput(content: out, isError: false)
    }

    /// First `[:-]digits[:-]` run decides whether a grep -n output line is a
    /// match (`path:12:...`) or context (`path-12-...`). Only used for the
    /// max_results count; content passes through untouched either way.
    private static func grepOutputLineIsMatch(_ line: String) -> Bool {
        guard let m = grepLineSeparatorRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let range = Range(m.range, in: line)
        else { return true }
        return line[range].hasPrefix(":")
    }
    private static let grepLineSeparatorRegex = try! NSRegularExpression(pattern: #"[:-][0-9]+[:-]"#)

    /// grep's fatal diagnostics ("grep: Unmatched [") carry no file prefix;
    /// per-file warnings ("grep: ./x: Permission denied") do. Fatal when the
    /// first `": "` doesn't look like it follows a path (heuristic: fatal
    /// messages contain a space before the colon, path prefixes don't).
    private static func grepStderrLineIsFatal(_ line: String) -> Bool {
        guard line.hasPrefix("grep: ") else { return true }
        let rest = line.dropFirst("grep: ".count)
        // "grep: <msg>" — the msg itself contains no path separator.
        // "grep: <path>: <msg>" — path may contain spaces but always a '/'.
        guard let colonRange = rest.range(of: ": ") else { return true }
        return !rest[..<colonRange.lowerBound].contains("/")
    }

    private static func findText(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let regex = try BuiltinTools.requireString(args, "regex")
        // Default search root: same jail-aware defaulting as findFile.
        let searchRoot = BuiltinTools.optionalString(args, "path") ?? (workdir.isolated ? "/" : workdir.root ?? ".")
        let caseInsensitive = BuiltinTools.optionalBool(args, "case_insensitive") ?? false
        let includeHidden = BuiltinTools.optionalBool(args, "include_hidden") ?? false
        let maxResults = min(max(BuiltinTools.optionalInt(args, "max_results") ?? 200, 1), 1000)
        let context = min(max(BuiltinTools.optionalInt(args, "context") ?? 0, 0), 25)
        let resolved = try workdir.resolve(searchRoot)
        // Every grep output line carries the path grep opened; the rewrite
        // below swaps the resolved prefix for the display spelling, so in
        // isolated mode the real remote layout never leaks.
        let displayBase = workdir.displayPath(forResolved: resolved)

        let exclude = try findExcludePredicate(args, workdir: workdir, resolvedRoot: resolved, caseInsensitive: false)

        // ERE (`grep -E`) gives the remote side real alternation, groups and
        // quantifiers; \d-style classes don't exist in POSIX ERE, which the
        // tool description calls out. When the search root is a directory the
        // file list comes from `find` (hidden entries and exclude_paths
        // pruned during the walk, -exec grep {} + batching the invocation) —
        // grep's own --exclude-dir only matches bare basenames, so it can't
        // express path or subtree exclusions. -H forces the filename prefix,
        // keeping it even for a single-file search root (local parity, and
        // the isolated path rewrite below keys off it). The output-capping
        // pipe would mask grep's own exit code, so it's echoed to stderr as
        // a marker and parsed back here.
        var grepArgs = "-EInH"
        if caseInsensitive { grepArgs += "i" }
        if context > 0 { grepArgs += " -C \(context)" }
        let prune = includeHidden ? "" : "\\( -name '.*' ! -name . -prune \\) -o "
        var findPred = "-type f"
        if let filePattern = BuiltinTools.optionalString(args, "file_pattern") {
            let flag = caseInsensitive ? "-iname" : "-name"
            findPred = "\(flag) \(q(filePattern)) -a \(findPred)"
        }
        let dirCommand =
            "cd \(qp(resolved)) && find . \(prune)\(exclude)\(findPred) -exec grep \(grepArgs) -- \(q(regex)) {} +"
        // Missing search roots error with the caller's spelling (scrubbed
        // below), mirroring the local tool instead of grep's own message.
        let script = """
            if [ ! -e \(qp(resolved)) ]; then printf 'not found: %s\\n' \(q(searchRoot)) >&2; exit 1; fi
            if [ -d \(qp(resolved)) ]; then \(dirCommand); else grep \(grepArgs) -- \(q(regex)) \(qp(resolved)); fi
            """
        let wrapped = "{ \(script); printf 'ICHAI-GREP-EXIT %s\\n' \"$?\" >&2; } | head -c 1048576"

        let r = try await run(ssh, script: wrapped)
        if r.failure != nil { try requireSuccess(r, scrubbing: [(resolved, displayBase)]) }

        var grepExit = 0
        var errLines: [String] = []
        for line in r.stderrString.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("ICHAI-GREP-EXIT ") {
                grepExit = Int(line.dropFirst("ICHAI-GREP-EXIT ".count)) ?? 0
            } else {
                errLines.append(String(line))
            }
        }
        // Fatal grep failures (bad regex, bad options) are reported without a
        // file prefix ("grep: Unmatched ["); per-file warnings carry one
        // ("grep: ./x: Permission denied"). `find -exec {} +` collapses the
        // 1-vs-2 exit distinction, so the stderr shape is the discriminator.
        // Per-file warnings pass through silently, matching the local tool
        // skipping files it can't open.
        let fatal = errLines.filter { Self.grepStderrLineIsFatal($0) }
        if !fatal.isEmpty {
            var msg = fatal.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if displayBase != resolved {
                msg = msg.replacingOccurrences(of: resolved, with: displayBase)
            }
            throw BuiltinToolError(msg.isEmpty ? "grep failed (exit code \(grepExit))" : msg)
        }

        // Traversal emits raw walk order, which would make the max_results
        // cut arbitrary. Sort first: with context, blocks (separated by `--`)
        // are the sort unit and stay intact; without, each line is a block.
        var blocks: [(key: String, lines: [String], matches: Int)] = []
        var cur: [String] = []
        var curMatches = 0
        var curKey: String?
        for rawLine in r.stdoutString.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if displayBase != resolved, line.hasPrefix(resolved) {
                line = displayBase + line.dropFirst(resolved.count)
            }
            // Every grep -n output line carries a path:line: prefix, so a
            // truly empty line is just the trailing-newline artifact.
            if line.isEmpty { continue }
            if context == 0 {
                blocks.append((line, [line], 1))
                continue
            }
            if line == "--" {
                if !cur.isEmpty { blocks.append((curKey ?? cur[0], cur, curMatches)) }
                cur = []
                curMatches = 0
                curKey = nil
                continue
            }
            if grepOutputLineIsMatch(line) {
                curMatches += 1
                if curKey == nil { curKey = line }
            }
            cur.append(line)
        }
        if !cur.isEmpty { blocks.append((curKey ?? cur[0], cur, curMatches)) }
        blocks.sort { $0.key < $1.key }

        var out: [String] = []
        var matchCount = 0
        var outBytes = 0
        var hitResultCap = false
        var hitByteCap = grepExit == 141
        for block in blocks {
            if matchCount >= maxResults {
                hitResultCap = true
                break
            }
            if outBytes >= BuiltinTools.findTextMaxOutputBytes {
                hitByteCap = true
                break
            }
            if context > 0, !out.isEmpty {
                out.append("--")
                outBytes += 3
            }
            for line in block.lines {
                let trimmed = BuiltinTools.truncateMatchLine(line)
                out.append(trimmed)
                outBytes += trimmed.utf8.count + 1
            }
            matchCount += block.matches
        }
        var result = out.joined(separator: "\n")
        if hitResultCap {
            result += "\n... (truncated at \(maxResults) results)"
        } else if hitByteCap {
            result += "\n... (truncated, output size limit)"
        }
        return ToolOutput(content: result, isError: false)
    }

    private static func mkdir(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let resolved = try workdir.resolve(path)
        let r = try await run(ssh, script: "mkdir -p \(qp(resolved))")
        try requireSuccess(r, scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
        return ToolOutput(content: "Created directory \(path)", isError: false)
    }

    private static func mv(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let src = try BuiltinTools.requireString(args, "src")
        let dst = try BuiltinTools.requireString(args, "dst")
        let resolvedSrc = try workdir.resolve(src)
        let resolvedDst = try workdir.resolve(dst)
        let r = try await run(ssh, script: "mv \(qp(resolvedSrc)) \(qp(resolvedDst))")
        try requireSuccess(
            r,
            scrubbing: [
                (resolvedSrc, workdir.displayPath(forResolved: resolvedSrc)),
                (resolvedDst, workdir.displayPath(forResolved: resolvedDst)),
            ])
        return ToolOutput(content: "Moved \(src) to \(dst)", isError: false)
    }

    private static func rm(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let recursive = BuiltinTools.optionalBool(args, "recursive") ?? false
        let resolved = try workdir.resolve(path)

        // Empty directories are removed with rmdir (rm without -r refuses
        // them), matching the local tool where a non-recursive delete of an
        // empty directory succeeds.
        let script = """
            if [ ! -e \(qp(resolved)) ] && [ ! -L \(qp(resolved)) ]; then printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
            if [ -d \(qp(resolved)) ] && [ ! -L \(qp(resolved)) ]; then
              if [ \(recursive ? 1 : 0) -eq 0 ]; then
                if [ -n "$(ls -A \(qp(resolved)) 2>/dev/null)" ]; then printf 'directory is not empty; use recursive: true to delete it\\n' >&2; exit 1; fi
                rmdir \(qp(resolved))
              else
                rm -r \(qp(resolved))
              fi
            else
              rm \(qp(resolved))
            fi
            """
        let r = try await run(ssh, script: script)
        try requireSuccess(r, scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])
        return ToolOutput(content: "Deleted \(path)", isError: false)
    }

    private static func stat(_ args: [String: Any], workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        let path = try BuiltinTools.requireString(args, "path")
        let resolved = try workdir.resolve(path)

        // Portable metadata: try GNU stat, fall back to BSD. The header lines
        // are parsed back in Swift, which also assembles the JSON (so `file`
        // output never needs shell-side JSON escaping).
        let script = """
            p=\(qp(resolved))
            if [ -L "$p" ]; then t=symlink; elif [ -d "$p" ]; then t=dir; elif [ -e "$p" ]; then t=file; else printf 'not found: %s\\n' \(q(path)) >&2; exit 1; fi
            meta=$(stat -c '%s %Y %W' "$p" 2>/dev/null) || meta=$(stat -f '%z %m %B' "$p" 2>/dev/null) || meta=
            printf 'ICHAI-TYPE %s\\nICHAI-META %s\\nICHAI-FILE ' "$t" "$meta"
            file -b "$p" 2>/dev/null || true
            """
        let r = try await run(ssh, script: script)
        try requireSuccess(r, scrubbing: [(resolved, workdir.displayPath(forResolved: resolved))])

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
        return ToolOutput(content: "{\(parts.joined(separator: ","))}", isError: false)
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func pwd(workdir: Workdir, ssh: SSHContext) async throws -> ToolOutput {
        // Isolated mode presents the root as the virtual "/" (local parity).
        if workdir.isolated { return ToolOutput(content: "/", isError: false) }
        let script = workdir.root.map { "cd \(qp($0)) && pwd" } ?? "pwd"
        let r = try await run(ssh, script: script)
        try requireSuccess(r)
        return ToolOutput(content: r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), isError: false)
    }

    /// Fetches one remote file. The first stdout line is a status header
    /// (`<marker> file|dir|missing`); file bytes follow.
    private static func fetchFile(_ ssh: SSHContext, resolved: String) async throws -> (exists: Bool, data: Data?) {
        let marker = "ICHAI-\(UUID().uuidString)"
        let script = """
            if [ -e \(qp(resolved)) ] || [ -L \(qp(resolved)) ]; then
              if [ -d \(qp(resolved)) ]; then printf '%s dir\\n' \(q(marker)); else printf '%s file\\n' \(q(marker)); cat \(qp(resolved)); fi
            else
              printf '%s missing\\n' \(q(marker))
            fi
            """
        let r = try await run(ssh, script: script)
        try requireSuccess(r)

        let stdout = r.stdout
        guard let nl = stdout.firstIndex(of: 0x0A) else {
            throw BuiltinToolError("unexpected remote response while reading a remote file")
        }
        let header = String(decoding: stdout[stdout.startIndex..<nl], as: UTF8.self)
        if header == "\(marker) file" {
            return (true, Data(stdout[stdout.index(after: nl)...]))
        }
        if header == "\(marker) dir" { return (true, nil) }
        return (false, nil)
    }

    // MARK: - Pre-execution diff previews

    /// SSH counterpart of [`DiffBuilder.diffForWriteFile`](src/Tools/DiffBuilder.swift:39):
    /// the "before" content is fetched over SSH, the diff itself is computed
    /// locally. Returns nil when the arguments are invalid so the caller can
    /// fail fast exactly like the local path. Transport failures throw — the
    /// caller skips the preview and lets the tool itself report the error.
    static func diffForWriteFile(arguments: String, workdir: Workdir, ssh: SSHContext) async throws -> String? {
        guard let data = arguments.data(using: .utf8),
            let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let path = args["path"] as? String,
            let content = args["content"] as? String
        else { return nil }
        let resolved = try workdir.resolve(path)
        let remote = try await fetchFile(ssh, resolved: resolved)
        let old = (remote.exists ? remote.data.flatMap { String(data: $0, encoding: .utf8) } : nil) ?? ""
        return DiffBuilder.unifiedDiff(old: old, new: content, oldPath: path, newPath: path)
    }

    /// SSH counterpart of [`DiffBuilder.preflightEditFile`](src/Tools/DiffBuilder.swift:59):
    /// fetch the remote "before" content, apply the hashline edits locally, and
    /// generate the diff locally — no remote-side hashing. Returns nil when the
    /// arguments are invalid so the caller can fail fast exactly like the local
    /// path; transport failures and hash/parse mismatches throw.
    static func diffForEditFile(arguments: String, workdir: Workdir, ssh: SSHContext) async throws -> String? {
        guard let data = arguments.data(using: .utf8),
            let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let input = args["input"] as? String
        else { return nil }
        let patch = try HashlineEdit.parse(input)
        var diffs: [String] = []
        for section in patch.sections {
            let resolved = try workdir.resolve(section.path)
            let remote = try await fetchFile(ssh, resolved: resolved)
            guard remote.exists, let fileData = remote.data else {
                throw BuiltinToolError("invalid argument 'input': file not found: \(section.path)")
            }
            guard let old = String(data: fileData, encoding: .utf8) else {
                throw BuiltinToolError(
                    "File \(section.path) is not a text file and cannot be edited with edit_file. Use write_file to replace it entirely."
                )
            }
            let result = try HashlineEdit.applySection(section, fileContent: old)
            switch section.fileOp {
            case .rem:
                diffs.append(DiffBuilder.unifiedDiff(old: old, new: "", oldPath: section.path, newPath: nil))
            case .move(let dest):
                diffs.append(
                    DiffBuilder.unifiedDiff(old: old, new: result.text, oldPath: section.path, newPath: dest))
            case nil:
                diffs.append(
                    DiffBuilder.unifiedDiff(old: old, new: result.text, oldPath: section.path, newPath: section.path))
            }
        }
        let joined = diffs.filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
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
            script += "cd \(qp(resolved)) || exit 1\n"
        }
        // Merge stderr into stdout for the rest of the script so the model
        // sees output in the order it was written, emulating a terminal. The
        // SSH transport keeps stdout/stderr as separate channels (see IOBox),
        // so without this the two streams can't be interleaved correctly.
        script += "exec 2>&1\n"
        script += command

        // An explicit timeout is a hard kill (local semantics). Without one,
        // an idle watchdog kills the call after a stretch of output silence,
        // so a hung network can't hang the tool call indefinitely.
        let r = try await run(
            ssh, script: script,
            hardTimeout: timeout,
            idleTimeout: timeout == nil ? shellIdleTimeout : nil)

        // With `exec 2>&1` everything lands on stdout; stderr is empty unless
        // the redirect itself failed (ssh transport errors surface via
        // `failure`). Strip ANSI color codes from the merged output.
        var text = BuiltinTools.stripAnsi(r.stdoutString)
        switch r.failure {
        case .hardTimeout(let t):
            if !r.stderrString.isEmpty { text += BuiltinTools.stripAnsi(r.stderrString) }
            text += "\n[exit code: timed out after \(Int(t))s]"
            return ToolOutput(content: text, isError: false)
        case .idleTimeout(let t):
            if !r.stderrString.isEmpty { text += BuiltinTools.stripAnsi(r.stderrString) }
            text +=
                "\n[exit code: killed after \(Int(t))s without output; pass an explicit timeout for long-running silent commands]"
            return ToolOutput(content: text, isError: false)
        case nil:
            break
        }

        return ToolOutput(content: "\(text)\n[exit code: \(r.exitCode)]", isError: false)
    }
}
