import Testing
import Foundation
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
        private static let code = BuiltinTools.codeGroup
        private static let sh = BuiltinTools.shellGroup

        /// Sockets go to a throwaway local directory, not the real app cache.
        /// Kept short on purpose: ssh appends a random suffix to the control
        /// path when creating the socket, and sun_path is capped at 104 bytes
        /// (so NSTemporaryDirectory, deep under /var/folders, is unusable).
        init() {
            BuiltinToolsSSH.manager = SSHManager(cacheDir: "/tmp/ichai-test-socks")
        }

        private static func call(_ name: String, _ group: String, _ args: [String: Any], workdir: Workdir) async -> (text: String, isError: Bool) {
            let arguments = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
            let result = await BuiltinTools.call(name: name, arguments: arguments, callID: "test", group: group, workdir: workdir)
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
            let wd = Workdir(root: "ssh::\(host)\(remote)", isolated: false, chatID: chatID)
            return (wd, remote)
        }

        private static func destroy(_ wd: Workdir, _ remote: String) async {
            _ = await call("rm", fs, ["path": remote, "recursive": true], workdir: wd)
        }

        @Test("write_file creates parents and read_file round-trips")
        func writeReadRoundtrip() async {
            let (wd, remote) = Self.makeContext()
            let (wText, wErr) = await Self.call("write_file", Self.fs, ["path": "sub/dir/hello.txt", "content": "line1\nline2\n"], workdir: wd)
            #expect(!wErr)
            #expect(wText.contains("Wrote 12 bytes"))

            let (rText, rErr) = await Self.call("read_file", Self.fs, ["path": "sub/dir/hello.txt"], workdir: wd)
            #expect(!rErr)
            #expect(rText.contains("line1"))
            #expect(rText.contains("line2"))
            // Line-numbered output.
            #expect(rText.contains("1\tline1"))

            await Self.destroy(wd, remote)
        }

        @Test("read_file honors offset/limit and errors on missing paths")
        func readFileRanges() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("write_file", Self.fs, ["path": "f.txt", "content": "a\nb\nc\nd\ne\n"], workdir: wd)

            let (text, isError) = await Self.call("read_file", Self.fs, ["path": "f.txt", "offset": 2, "limit": 2], workdir: wd)
            #expect(!isError)
            #expect(text.contains("2\tb"))
            #expect(text.contains("3\tc"))
            #expect(!text.contains("4\td"))

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
            // Flat listing includes dotfiles (local parity).
            #expect(flat.contains(".hidden"))

            let (rec, recErr) = await Self.call("ls", Self.fs, ["path": ".", "recursive": true], workdir: wd)
            #expect(!recErr)
            #expect(rec.contains("a/"))
            #expect(rec.contains("a/b/"))
            // Depth is capped at children + one level into subdirectories
            // (local parity), so the depth-3 file and hidden entries are out.
            #expect(!rec.contains("c.txt"))
            #expect(!rec.contains(".hidden"))

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
            _ = await Self.call("write_file", Self.fs, ["path": "f1.swift", "content": "let needle = 1\n"], workdir: wd)
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

        @Test("apply_patch adds and updates remote files")
        func applyPatch() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("write_file", Self.fs, ["path": "orig.txt", "content": "alpha\nbeta\n"], workdir: wd)

            let patch = """
            *** Begin Patch
            *** Update File: orig.txt
            @@
            -beta
            +gamma
            *** Add File: added.txt
            +fresh
            *** End Patch
            """
            let (text, isError) = await Self.call("apply_patch", Self.code, ["patch": patch], workdir: wd)
            #expect(!isError)
            #expect(text.contains("Updated: orig.txt"))
            #expect(text.contains("Added: added.txt"))

            let (orig, _) = await Self.call("read_file", Self.fs, ["path": "orig.txt"], workdir: wd)
            #expect(orig.contains("gamma"))
            #expect(!orig.contains("beta"))
            let (added, _) = await Self.call("read_file", Self.fs, ["path": "added.txt"], workdir: wd)
            #expect(added.contains("fresh"))

            let (fail, failErr) = await Self.call("apply_patch", Self.code, ["patch": "*** Begin Patch\n*** Update File: ghost.txt\n@@\n-x\n+y\n*** End Patch\n"], workdir: wd)
            #expect(failErr)
            #expect(fail.contains("ghost.txt does not exist"))

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

        @Test("git runs remotely")
        func gitVersion() async {
            let (wd, remote) = Self.makeContext()
            _ = await Self.call("mkdir", Self.fs, ["path": "."], workdir: wd)
            let (text, isError) = await Self.call("git", Self.code, ["args": ["--version"]], workdir: wd)
            #expect(!isError)
            #expect(text.contains("git version"))
            await Self.destroy(wd, remote)
        }

        @Test("isolated mode maps / onto the remote root and blocks escapes")
        func isolatedMode() async {
            let remote = "/tmp/ichai-tests-\(UUID().uuidString.prefix(8))"
            let wd = Workdir(root: "ssh::\(Self.host)\(remote)", isolated: true, chatID: Self.chatID)

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

        @Test("connection failure surfaces a tool error after 3 attempts")
        func invalidHost() async {
            let wd = Workdir(root: "ssh::ichai-test-nonexistent.invalid/tmp/x", isolated: false, chatID: UUID().uuidString)
            let (text, isError) = await Self.call("shell", Self.sh, ["command": "echo hi"], workdir: wd)
            #expect(isError)
            #expect(text.contains("SSH connection"))
            #expect(text.contains("failed after 3 attempts"))
        }

        @Test("idle watchdog kills silent commands")
        func idleTimeout() async throws {
            let mgr = SSHManager(cacheDir: "/tmp/ichai-test-socks-idle")
            let ctx = SSHContext(host: Self.host, chatID: UUID().uuidString)
            let r = try await mgr.exec(ctx, stdin: Data("sleep 30\n".utf8), hardTimeout: TimeInterval?.none, idleTimeout: TimeInterval(1))
            guard case .idleTimeout = r.failure else {
                Issue.record("expected an idle-timeout kill, got \(String(describing: r.failure))")
                return
            }
        }

        @Test("hard timeout kills regardless of activity")
        func hardTimeout() async throws {
            let mgr = SSHManager(cacheDir: "/tmp/ichai-test-socks-hard")
            let ctx = SSHContext(host: Self.host, chatID: UUID().uuidString)
            let r = try await mgr.exec(ctx, stdin: Data("yes\n".utf8), hardTimeout: TimeInterval(1), idleTimeout: TimeInterval?.none)
            guard case .hardTimeout = r.failure else {
                Issue.record("expected a hard-timeout kill, got \(String(describing: r.failure))")
                return
            }
        }
    }
}
