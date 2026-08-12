import Foundation
import Testing

@testable import iCanHazAI

/// Probe for the `ichai-test` ssh host used by the integration suite. When
/// the host isn't configured/reachable, the whole suite is skipped.
private enum SSHIntegrationSupport {
    static let host = "ichai-test"

    /// One-shot synchronous probe: `ssh -o BatchMode=yes -o ConnectTimeout=5 ichai-test true`.
    static let hostAvailable: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return false
        }
        // Bound the wait so a network hang can't wedge test discovery.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { p.terminate() }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()
}

extension AllAppTests {

    /// Live round-trips of the SSH-backed builtin tools against a real ssh
    /// host (`ssh ichai-test`). Everything happens inside a per-test
    /// temporary directory under the remote /tmp, which is removed at the
    /// end of each test — nothing else on the server is touched.
    ///
    /// Nested under `AllAppTests` so its `.serialized` trait keeps these
    /// sequential with the rest of the app suites.
    @Suite("SSH integration", .enabled(if: SSHIntegrationSupport.hostAvailable))
    struct SSHIntegrationTests {
        private static let host = SSHIntegrationSupport.host
        private static let fs = BuiltinTools.filesystemGroup
        private static let sh = BuiltinTools.shellGroup

        /// Sockets go to a throwaway local directory, not the real app cache.
        /// Kept short on purpose: ssh appends a random suffix to the control
        /// path when creating the socket, and sun_path is capped at 104 bytes
        /// (so NSTemporaryDirectory, deep under /var/folders, is unusable).
        init() {
            BuiltinToolsSSH.manager = SSHManager(cacheDir: "/tmp/ichai-test-socks")
        }

        private static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir) async -> (
            text: String, isError: Bool
        ) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(
                name: name, arguments: arguments, callID: "test", group: group, workdir: workdir,
                chatFilename: "test.json")
            return (result.content, result.isError)
        }

        /// One chat identity for the whole suite: all tests share a single
        /// control-master connection (mux), which keeps the suite fast and
        /// mirrors real per-chat usage.
        private static let chatID = UUID().uuidString

        /// A workdir rooted at a fresh remote temp directory (created on
        /// first write; remote paths are absolute).
        private static func makeContext() -> (wd: Workdir, remote: String) {
            let remote = "/tmp/ichai-tests-\(UUID().uuidString.prefix(8))"
            let wd = Workdir(root: "\(host):\(remote)", isolated: false, chatID: chatID)
            return (wd, remote)
        }

        private static func destroy(_ wd: Workdir, _ remote: String) async {
            _ = await call("rm", fs, ["path": remote, "recursive": true], workdir: wd)
        }

        @Test("write_file creates parents and read_file round-trips")
        func writeReadRoundtrip() async {
            let (wd, remote) = Self.makeContext()
            let (wText, wErr) = await Self.call(
                "write_file", Self.fs, ["path": "sub/dir/hello.txt", "content": "line1\nline2\n"], workdir: wd)
            #expect(!wErr)
            #expect(wText.contains("Wrote 12 bytes"))

            let (rText, rErr) = await Self.call("read_file", Self.fs, ["path": "sub/dir/hello.txt"], workdir: wd)
            #expect(!rErr)
            #expect(rText.contains("line1"))
            #expect(rText.contains("line2"))
            // Line-numbered output ('N|content' gutter).
            #expect(rText.contains("1|line1"))

            await Self.destroy(wd, remote)
        }

        @Test("read_file honors offset/limit and errors on missing paths")
        func readFileRanges() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("write_file", Self.fs, ["path": "f.txt", "content": "a\nb\nc\nd\ne\n"], workdir: wd)

            let (text, isError) = await Self.call(
                "read_file", Self.fs, ["path": "f.txt", "offset": 2, "limit": 2], workdir: wd)
            #expect(!isError)
            #expect(text.contains("2|b"))
            #expect(text.contains("3|c"))
            #expect(!text.contains("4|d"))

            let (missing, missingErr) = await Self.call("read_file", Self.fs, ["path": "nope.txt"], workdir: wd)
            #expect(missingErr)
            #expect(missing.contains("not found"))

            let (dir, dirErr) = await Self.call("read_file", Self.fs, ["path": "."], workdir: wd)
            #expect(dirErr)
            #expect(dir.contains("is a directory"))

            await Self.destroy(wd, remote)
        }

        @Test("ls lists flat and recursively, skipping hidden entries")
        func lsVariants() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("write_file", Self.fs, ["path": "top.txt", "content": "x"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": "a/b/c.txt", "content": "x"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": ".hidden", "content": "x"], workdir: wd)

            let (flat, flatErr) = await Self.call("ls", Self.fs, ["path": "."], workdir: wd)
            #expect(!flatErr)
            #expect(flat.contains("top.txt"))
            #expect(flat.contains("a/"))
            // Hidden entries are skipped by default in both modes (local parity).
            #expect(!flat.contains(".hidden"))

            let (rec, recErr) = await Self.call("ls", Self.fs, ["path": ".", "recursive": true], workdir: wd)
            #expect(!recErr)
            #expect(rec.contains("a/"))
            #expect(rec.contains("a/b/"))
            // Depth is capped at children + one level into subdirectories
            // (local parity), so the depth-3 file and hidden entries are out.
            #expect(!rec.contains("c.txt"))
            #expect(!rec.contains(".hidden"))

            // include_hidden opts back in, in both modes.
            let (flatH, _) = await Self.call("ls", Self.fs, ["path": ".", "include_hidden": true], workdir: wd)
            #expect(flatH.contains(".hidden"))
            let (recH, _) = await Self.call(
                "ls", Self.fs, ["path": ".", "recursive": true, "include_hidden": true], workdir: wd)
            #expect(recH.contains(".hidden"))

            let (missing, missingErr) = await Self.call("ls", Self.fs, ["path": "no-such-dir"], workdir: wd)
            #expect(missingErr)
            #expect(missing.contains("not found"))

            await Self.destroy(wd, remote)
        }

        @Test("mkdir, stat and pwd agree on the remote layout")
        func mkdirStatPwd() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("mkdir", Self.fs, ["path": "d/e"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": "d/f.bin", "content": "hello world\n"], workdir: wd)

            let (dirStat, dirErr) = await Self.call("stat", Self.fs, ["path": "d/e"], workdir: wd)
            #expect(!dirErr)
            #expect(dirStat.contains("\"type\":\"dir\""))

            let (fileStat, fileErr) = await Self.call("stat", Self.fs, ["path": "d/f.bin"], workdir: wd)
            #expect(!fileErr)
            #expect(fileStat.contains("\"type\":\"file\""))
            #expect(fileStat.contains("\"size\":\"12\""))
            #expect(fileStat.contains("\"modified\":\""))

            let (pwdText, pwdErr) = await Self.call("pwd", Self.fs, [:], workdir: wd)
            #expect(!pwdErr)
            #expect(pwdText.trimmingCharacters(in: .whitespacesAndNewlines) == remote)

            await Self.destroy(wd, remote)
        }

        @Test("mv renames and rm enforces the recursive flag")
        func mvAndRm() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("write_file", Self.fs, ["path": "a.txt", "content": "data"], workdir: wd)

            let (mvText, mvErr) = await Self.call("mv", Self.fs, ["src": "a.txt", "dst": "b.txt"], workdir: wd)
            #expect(!mvErr)
            #expect(mvText.contains("Moved a.txt to b.txt"))

            let (read, _) = await Self.call("read_file", Self.fs, ["path": "b.txt"], workdir: wd)
            #expect(read.contains("data"))

            let (rmFile, rmFileErr) = await Self.call("rm", Self.fs, ["path": "b.txt"], workdir: wd)
            #expect(!rmFileErr)
            #expect(rmFile.contains("Deleted b.txt"))

            // A non-empty directory requires the recursive flag...
            _ = await Self.call("write_file", Self.fs, ["path": "keep.txt", "content": "x"], workdir: wd)
            let (dir, dirErr) = await Self.call("rm", Self.fs, ["path": "."], workdir: wd)
            #expect(dirErr)
            #expect(dir.contains("recursive"))

            // ...while an empty one is removed without it.
            _ = await Self.call("rm", Self.fs, ["path": "b.txt"], workdir: wd)
            _ = await Self.call("mkdir", Self.fs, ["path": "emptydir"], workdir: wd)
            let (rmd, rmdErr) = await Self.call("rm", Self.fs, ["path": "emptydir"], workdir: wd)
            #expect(!rmdErr)
            #expect(rmd.contains("Deleted emptydir"))

            await Self.destroy(wd, remote)
        }

        @Test("find_file matches globs and find_text greps contents")
        func findTools() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call(
                "write_file", Self.fs, ["path": "f1.swift", "content": "let needle = 1\n"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": "f2.md", "content": "nothing here\n"], workdir: wd)

            let (found, foundErr) = await Self.call("find_file", Self.fs, ["pattern": "*.swift"], workdir: wd)
            #expect(!foundErr)
            #expect(found.contains("f1.swift"))
            #expect(!found.contains("f2.md"))

            let (grep, grepErr) = await Self.call("find_text", Self.fs, ["regex": "needle"], workdir: wd)
            #expect(!grepErr)
            #expect(grep.contains("f1.swift:1:let needle = 1"))

            await Self.destroy(wd, remote)
        }

        @Test("find_text pins ERE and sorts before max_results")
        func findTextEREAndDeterministicCap() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("write_file", Self.fs, ["path": "d/weed.txt", "content": "weed\n"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": "d/wed.txt", "content": "wed\n"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": "d/ctx.txt", "content": "a\nmatch\nb\n"], workdir: wd)

            // ERE-only constructs: {n} intervals, alternation, +, groups.
            let (interval, intervalErr) = await Self.call(
                "find_text", Self.fs, ["path": "d", "regex": "we{2}d"], workdir: wd)
            #expect(!intervalErr)
            #expect(interval.contains("weed.txt"))
            #expect(!interval.contains("wed.txt"))
            let (alt, altErr) = await Self.call("find_text", Self.fs, ["path": "d", "regex": "w(e|a)+d"], workdir: wd)
            #expect(!altErr)
            #expect(alt.contains("weed.txt"))
            #expect(alt.contains("wed.txt"))

            // Invalid ERE surfaces grep's own error message.
            let (bad, badErr) = await Self.call("find_text", Self.fs, ["path": "d", "regex": "[unclosed"], workdir: wd)
            #expect(badErr)
            #expect(!bad.isEmpty)

            // Context groups survive intact.
            let (ctx, ctxErr) = await Self.call(
                "find_text", Self.fs, ["path": "d", "regex": "match", "context": 1], workdir: wd)
            #expect(!ctxErr)
            #expect(ctx.contains("-1-a"))
            #expect(ctx.contains(":2:match"))
            #expect(ctx.contains("-3-b"))

            // max_results drops the lexicographically last matches, not
            // arbitrary traversal-order ones.
            for i in 1...5 {
                _ = await Self.call(
                    "write_file", Self.fs, ["path": "many/many_\(i).txt", "content": "needle\n"], workdir: wd)
            }
            let (capped, cappedErr) = await Self.call(
                "find_text", Self.fs, ["path": "many", "regex": "needle", "max_results": 2], workdir: wd)
            #expect(!cappedErr)
            #expect(capped.contains("many_1.txt"))
            #expect(capped.contains("many_2.txt"))
            #expect(!capped.contains("many_3.txt"))
            #expect(capped.contains("truncated at 2 results"))

            await Self.destroy(wd, remote)
        }

        @Test("find_file and find_text exclude_paths prune remote directories and files")
        func findToolsExcludePaths() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("write_file", Self.fs, ["path": "src/a.swift", "content": "needle\n"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": "build/b.swift", "content": "needle\n"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": "notes.txt", "content": "needle\n"], workdir: wd)

            let (ff, ffErr) = await Self.call(
                "find_file", Self.fs, ["pattern": "*.swift", "exclude_paths": ["build"]], workdir: wd)
            #expect(!ffErr)
            #expect(ff.contains("src/a.swift"))
            #expect(!ff.contains("build"))

            // A trailing slash still excludes the whole directory.
            let (ffT, _) = await Self.call(
                "find_file", Self.fs, ["pattern": "*", "exclude_paths": ["build/"]], workdir: wd)
            #expect(!ffT.contains("build"))

            let (ft, ftErr) = await Self.call(
                "find_text", Self.fs, ["regex": "needle", "exclude_paths": ["build", "notes.txt"]], workdir: wd)
            #expect(!ftErr)
            #expect(ft.contains("src/a.swift"))
            #expect(!ft.contains("build"))
            #expect(!ft.contains("notes.txt"))

            await Self.destroy(wd, remote)
        }

        @Test("find_text exclude_paths honors the jail when isolated")
        func findTextExcludeIsolated() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("write_file", Self.fs, ["path": "src/a.txt", "content": "needle\n"], workdir: wd)
            _ = await Self.call("write_file", Self.fs, ["path": "build/b.txt", "content": "needle\n"], workdir: wd)

            let jail = Workdir(root: "\(Self.host):\(remote)", isolated: true, chatID: Self.chatID)
            let (ft, ftErr) = await Self.call(
                "find_text", Self.fs, ["regex": "needle", "exclude_paths": ["/build"]], workdir: jail)
            #expect(!ftErr)
            #expect(ft.contains("/src/a.txt"))
            #expect(!ft.contains("build"))
            // Escaping the jail is rejected like any other path.
            let (escape, escapeErr) = await Self.call(
                "find_text", Self.fs, ["regex": "needle", "exclude_paths": ["../.."]], workdir: jail)
            #expect(escapeErr)
            #expect(escape.contains("escapes"))

            await Self.destroy(wd, remote)
        }

        @Test("write_file diff preview reflects the remote before-state")
        func writeFileDiffPreview() async throws {
            let (wd, remote) = Self.makeContext()
            let ssh = try #require(wd.ssh)
            _ = await Self.call("write_file", Self.fs, ["path": "f.txt", "content": "alpha\nbeta\n"], workdir: wd)

            let args = #"{"path":"f.txt","content":"alpha\ngamma\n"}"#
            let diff = try await BuiltinToolsSSH.diffForWriteFile(arguments: args, workdir: wd, ssh: ssh)
            let d = try #require(diff)
            #expect(d.contains("--- f.txt"))
            #expect(d.contains("+++ f.txt"))
            #expect(d.contains("-beta"))
            #expect(d.contains("+gamma"))

            // A new file diffs as pure additions against an empty before-state.
            let newDiff = try await BuiltinToolsSSH.diffForWriteFile(
                arguments: #"{"path":"new.txt","content":"fresh\n"}"#, workdir: wd, ssh: ssh)
            #expect(newDiff?.contains("+fresh") == true)

            // Identical content → empty diff (nothing to show).
            let sameDiff = try await BuiltinToolsSSH.diffForWriteFile(
                arguments: #"{"path":"f.txt","content":"alpha\nbeta\n"}"#, workdir: wd, ssh: ssh)
            #expect(sameDiff == "")

            // Invalid arguments → nil (the engine relays the fail-fast error).
            let bad = try await BuiltinToolsSSH.diffForWriteFile(
                arguments: #"{"path":"only-path"}"#, workdir: wd, ssh: ssh)
            #expect(bad == nil)

            await Self.destroy(wd, remote)
        }

        @Test("shell runs commands remotely with cwd and exit codes")
        func shellBasics() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("mkdir", Self.fs, ["path": "sub"], workdir: wd)

            let (echo, echoErr) = await Self.call("shell", Self.sh, ["command": "echo hi"], workdir: wd)
            #expect(!echoErr)
            #expect(echo.contains("hi"))
            #expect(echo.contains("[exit code: 0]"))

            // Default cwd is the workdir root.
            let (pwdDefault, _) = await Self.call("shell", Self.sh, ["command": "pwd"], workdir: wd)
            #expect(pwdDefault.contains(remote))

            let (pwdSub, _) = await Self.call("shell", Self.sh, ["command": "pwd", "cwd": "sub"], workdir: wd)
            #expect(pwdSub.contains("\(remote)/sub"))

            let (fail, _) = await Self.call("shell", Self.sh, ["command": "exit 3"], workdir: wd)
            #expect(!fail.contains("[exit code: 0]"))
            #expect(fail.contains("[exit code: 3]"))

            await Self.destroy(wd, remote)
        }

        @Test("shell honors an explicit timeout")
        func shellTimeout() async {
            let (wd, remote) = Self.makeContext()
            // The workdir root must exist for the shell's default cd.
            _ = await Self.call("mkdir", Self.fs, ["path": "."], workdir: wd)
            let (text, _) = await Self.call("shell", Self.sh, ["command": "sleep 10", "timeout": 1], workdir: wd)
            #expect(text.contains("timed out after 1s"))
            await Self.destroy(wd, remote)
        }

        @Test("isolated mode maps / onto the remote root and blocks escapes")
        func isolatedMode() async {
            let remote = "/tmp/ichai-tests-\(UUID().uuidString.prefix(8))"
            let wd = Workdir(root: "\(Self.host):\(remote)", isolated: true, chatID: Self.chatID)

            let (_, wErr) = await Self.call("write_file", Self.fs, ["path": "/a.txt", "content": "iso"], workdir: wd)
            #expect(!wErr)
            let (ls, _) = await Self.call("ls", Self.fs, ["path": "/"], workdir: wd)
            #expect(ls.contains("a.txt"))
            let (pwd, _) = await Self.call("pwd", Self.fs, [:], workdir: wd)
            #expect(pwd.trimmingCharacters(in: .whitespacesAndNewlines) == "/")

            let (escape, escapeErr) = await Self.call("read_file", Self.fs, ["path": "/../etc/hostname"], workdir: wd)
            #expect(escapeErr)
            #expect(escape.contains("escapes the workdir"))

            await Self.destroy(wd, remote)
        }

        /// Cleanup for isolated workdirs: an isolated rm would jail the
        /// absolute temp path, so go through a non-isolated lens.
        private static func destroyIsolated(_ remote: String) async {
            let cleanup = Workdir(root: "\(host):/", isolated: false, chatID: chatID)
            _ = await call("rm", fs, ["path": remote, "recursive": true], workdir: cleanup)
        }

        @Test("isolated find_text shows jail paths and never the remote root")
        func isolatedFindText() async {
            let remote = "/tmp/ichai-tests-\(UUID().uuidString.prefix(8))"
            let wd = Workdir(root: "\(Self.host):\(remote)", isolated: true, chatID: Self.chatID)

            _ = await Self.call(
                "write_file", Self.fs, ["path": "/sub/note.txt", "content": "before\nhello ssh jail\nafter\n"],
                workdir: wd)
            _ = await Self.call(
                "write_file", Self.fs, ["path": "/top.txt", "content": "hello from the top\n"], workdir: wd)

            // Default search root (the jail "/").
            let (text, err) = await Self.call("find_text", Self.fs, ["regex": "hello"], workdir: wd)
            #expect(!err)
            #expect(text.contains("/sub/note.txt:2:hello ssh jail"))
            #expect(text.contains("/top.txt:1:hello from the top"))
            #expect(!text.contains(remote))

            // Context lines get the same jail spelling.
            let (ctx, ctxErr) = await Self.call("find_text", Self.fs, ["regex": "hello", "context": 1], workdir: wd)
            #expect(!ctxErr)
            #expect(ctx.contains("/sub/note.txt-1-before"))
            #expect(ctx.contains("/sub/note.txt-3-after"))
            #expect(!ctx.contains(remote))

            // A single file as the search root.
            let (file, fileErr) = await Self.call(
                "find_text", Self.fs, ["regex": "hello", "path": "/sub/note.txt"], workdir: wd)
            #expect(!fileErr)
            #expect(file.contains("/sub/note.txt:2:hello ssh jail"))
            #expect(!file.contains(remote))

            // grep's own errors (missing search root) are scrubbed too.
            let (missing, missingErr) = await Self.call(
                "find_text", Self.fs, ["regex": "x", "path": "/no-such-dir"], workdir: wd)
            #expect(missingErr)
            #expect(missing.contains("/no-such-dir"))
            #expect(!missing.contains(remote))

            // Lexical escapes are rejected before anything runs remotely.
            let (escape, escapeErr) = await Self.call(
                "find_text", Self.fs, ["regex": "x", "path": "/../.."], workdir: wd)
            #expect(escapeErr)
            #expect(escape.contains("escapes the workdir"))

            await Self.destroyIsolated(remote)
        }

        @Test("no isolated tool output leaks the remote root path")
        func isolatedNoRemotePathLeaks() async {
            let remote = "/tmp/ichai-tests-\(UUID().uuidString.prefix(8))"
            let wd = Workdir(root: "\(Self.host):\(remote)", isolated: true, chatID: Self.chatID)
            let fs = Self.fs

            _ = await Self.call("write_file", fs, ["path": "/sub/note.txt", "content": "sweep content\n"], workdir: wd)

            var outputs: [(label: String, text: String)] = []
            func collect(_ label: String, _ result: (text: String, isError: Bool)) {
                outputs.append((label, result.text))
            }

            collect("ls flat", await Self.call("ls", fs, ["path": "/"], workdir: wd))
            collect("ls recursive", await Self.call("ls", fs, ["path": "/", "recursive": true], workdir: wd))
            collect("read_file", await Self.call("read_file", fs, ["path": "/sub/note.txt"], workdir: wd))
            collect("read_file missing", await Self.call("read_file", fs, ["path": "/missing.txt"], workdir: wd))
            collect("find_file", await Self.call("find_file", fs, ["pattern": "*.txt"], workdir: wd))
            collect("find_text", await Self.call("find_text", fs, ["regex": "sweep"], workdir: wd))
            collect("mkdir", await Self.call("mkdir", fs, ["path": "/newdir"], workdir: wd))
            collect("mv", await Self.call("mv", fs, ["src": "/sub/note.txt", "dst": "/newdir/b.txt"], workdir: wd))
            collect("mv missing", await Self.call("mv", fs, ["src": "/missing.txt", "dst": "/x.txt"], workdir: wd))
            collect("rm missing", await Self.call("rm", fs, ["path": "/missing.txt"], workdir: wd))
            collect("rm non-empty dir", await Self.call("rm", fs, ["path": "/newdir"], workdir: wd))
            collect("stat", await Self.call("stat", fs, ["path": "/newdir/b.txt"], workdir: wd))
            collect("stat missing", await Self.call("stat", fs, ["path": "/missing.txt"], workdir: wd))
            collect("pwd", await Self.call("pwd", fs, [:], workdir: wd))

            for (label, text) in outputs {
                #expect(!text.contains(remote), "\(label) leaked the remote root: \(text)")
            }

            // stat's not-found error names the caller's path, not the resolved one.
            let statMissing = outputs.first { $0.label == "stat missing" }?.text ?? ""
            #expect(statMissing.contains("not found: /missing.txt"))

            await Self.destroyIsolated(remote)
        }

        @Test("connection failure surfaces a tool error after 3 attempts")
        func invalidHost() async {
            let wd = Workdir(root: "ichai-test-nonexistent.invalid:/tmp/x", isolated: false, chatID: UUID().uuidString)
            let (text, isError) = await Self.call("shell", Self.sh, ["command": "echo hi"], workdir: wd)
            #expect(isError)
            #expect(text.contains("SSH connection"))
            #expect(text.contains("failed after 3 attempts"))
        }

        @Test("idle watchdog kills silent commands")
        func idleTimeout() async throws {
            let mgr = SSHManager(cacheDir: "/tmp/ichai-test-socks-idle")
            let ctx = SSHContext(host: Self.host, chatID: UUID().uuidString)
            let r = try await mgr.exec(
                ctx, stdin: Data("sleep 30\n".utf8), hardTimeout: TimeInterval?.none, idleTimeout: TimeInterval(1))
            guard case .idleTimeout = r.failure else {
                Issue.record("expected an idle-timeout kill, got \(String(describing: r.failure))")
                return
            }
        }

        @Test("hard timeout kills regardless of activity")
        func hardTimeout() async throws {
            let mgr = SSHManager(cacheDir: "/tmp/ichai-test-socks-hard")
            let ctx = SSHContext(host: Self.host, chatID: UUID().uuidString)
            let r = try await mgr.exec(
                ctx, stdin: Data("yes\n".utf8), hardTimeout: TimeInterval(1), idleTimeout: TimeInterval?.none)
            guard case .hardTimeout = r.failure else {
                Issue.record("expected a hard-timeout kill, got \(String(describing: r.failure))")
                return
            }
        }
    }
}
