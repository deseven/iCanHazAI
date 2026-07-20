import Testing
import Foundation
@testable import iCanHazAI

/// Unit tests for the SSH working-directory support: spec parsing, remote
/// path resolution/normalization, shell quoting, and socket-path naming.
/// These never touch the network — see `SSHIntegrationTests` for the live
/// round-trips against a real ssh host.
///
/// Nested under `AllAppTests` so its `.serialized` trait keeps these
/// sequential with the rest of the app suites.
extension AllAppTests {

    @Suite("SSH workdir: spec parsing")
    struct SSHSpecTests {
        @Test("bare host means the remote home directory")
        func bareHost() throws {
            let spec = try SSHSpec.parse("ssh::somehost").get()
            #expect(spec.host == "somehost")
            #expect(spec.path == nil)
        }

        @Test("host with path yields the absolute remote path")
        func hostWithPath() throws {
            let spec = try SSHSpec.parse("ssh::somehost/some/path").get()
            #expect(spec.host == "somehost")
            #expect(spec.path == "/some/path")
        }

        @Test("user@host is accepted")
        func userAtHost() throws {
            let spec = try SSHSpec.parse("ssh::user@somehost/home/user").get()
            #expect(spec.host == "user@somehost")
            #expect(spec.path == "/home/user")
        }

        @Test("trailing slash means the remote root")
        func trailingSlash() throws {
            let spec = try SSHSpec.parse("ssh::somehost/").get()
            #expect(spec.host == "somehost")
            #expect(spec.path == "/")
        }

        @Test("missing prefix is rejected")
        func missingPrefix() {
            #expect(SSHSpec.parse("somehost/path").isFailure)
        }

        @Test("empty host is rejected")
        func emptyHost() {
            #expect(SSHSpec.parse("ssh::").isFailure)
            #expect(SSHSpec.parse("ssh:///abs/path").isFailure)
        }

        @Test("whitespace in host is rejected")
        func whitespaceHost() {
            #expect(SSHSpec.parse("ssh::ho st/path").isFailure)
        }
    }

    @Suite("SSH workdir: Workdir integration")
    struct SSHWorkdirTests {
        @Test("ssh spec sets context and remote root")
        func contextAndRoot() {
            let wd = Workdir(root: "ssh::somehost/home/user/project", isolated: false, chatID: "chat-1")
            #expect(wd.ssh == SSHContext(host: "somehost", chatID: "chat-1"))
            #expect(wd.root == "/home/user/project")
            #expect(wd.sshSpecError == nil)
        }

        @Test("malformed ssh spec surfaces a spec error, not a local path")
        func malformedSpec() async {
            let wd = Workdir(root: "ssh::", isolated: false)
            #expect(wd.ssh == nil)
            #expect(wd.sshSpecError != nil)
            let result = await BuiltinTools.call(name: "ls", arguments: #"{"path":"/"}"#, callID: "t", group: BuiltinTools.filesystemGroup, workdir: wd)
            #expect(result.isError)
            #expect(result.content.contains("invalid SSH working directory"))
        }

        @Test("isolated resolution treats absolute paths as root-relative")
        func isolatedAbsolute() throws {
            let wd = Workdir(root: "ssh::h/a/b", isolated: true)
            #expect(try wd.resolve("/c/d") == "/a/b/c/d")
            #expect(try wd.resolve("c") == "/a/b/c")
            #expect(try wd.resolve("/") == "/a/b")
        }

        @Test("isolated resolution rejects escapes")
        func isolatedEscape() {
            let wd = Workdir(root: "ssh::h/a/b", isolated: true)
            #expect(throws: BuiltinToolError.self) { try wd.resolve("/../x") }
            #expect(throws: Never.self) { try wd.resolve("/../b/ok") }
        }

        @Test("isolated resolution against remote root / allows everything")
        func isolatedRemoteRoot() throws {
            let wd = Workdir(root: "ssh::h/", isolated: true)
            #expect(try wd.resolve("/etc/passwd") == "/etc/passwd")
            #expect(try wd.resolve("tmp") == "/tmp")
            #expect(try wd.resolve("/") == "/")
        }

        @Test("non-isolated resolution joins relative paths with the root")
        func nonIsolated() throws {
            let wd = Workdir(root: "ssh::h/a/b", isolated: false)
            #expect(try wd.resolve("/abs/path") == "/abs/path")
            #expect(try wd.resolve("rel/file.txt") == "/a/b/rel/file.txt")
            #expect(try wd.resolve("../sibling") == "/a/sibling")
        }

        @Test("nil root (remote home) keeps relative paths relative")
        func nilRootRelative() throws {
            let wd = Workdir(root: "ssh::h", isolated: false)
            #expect(wd.root == nil)
            #expect(try wd.resolve("rel/file.txt") == "rel/file.txt")
            #expect(try wd.resolve("/abs") == "/abs")
        }

        @Test("local workdirs are unaffected")
        func localUnaffected() {
            let wd = Workdir(root: "/tmp", isolated: false)
            #expect(wd.ssh == nil)
            #expect(wd.sshSpecError == nil)
        }
    }

    @Suite("SSH workdir: posixNormalize")
    struct SSHPosixNormalizeTests {
        @Test("collapses duplicate slashes and dot segments")
        func basics() {
            #expect(Workdir.posixNormalize("/a//b/./c") == "/a/b/c")
            #expect(Workdir.posixNormalize("a/./b") == "a/b")
            #expect(Workdir.posixNormalize("/a/b/") == "/a/b")
        }

        @Test("resolves dot-dot without touching the filesystem")
        func dotDot() {
            #expect(Workdir.posixNormalize("/a/b/../c") == "/a/c")
            #expect(Workdir.posixNormalize("/..") == "/")
            #expect(Workdir.posixNormalize("/../x") == "/x")
            #expect(Workdir.posixNormalize("a/../../b") == "../b")
        }

        @Test("does not expand tildes")
        func tilde() {
            #expect(Workdir.posixNormalize("~/x") == "~/x")
        }

        @Test("empty and corner inputs")
        func corners() {
            #expect(Workdir.posixNormalize("") == ".")
            #expect(Workdir.posixNormalize("/") == "/")
            #expect(Workdir.posixNormalize(".") == ".")
        }
    }

    @Suite("SSH workdir: shell helpers")
    struct SSHShellHelperTests {
        @Test("single-quote escaping")
        func quoting() {
            #expect(BuiltinToolsSSH.q("plain") == "'plain'")
            #expect(BuiltinToolsSSH.q("") == "''")
            #expect(BuiltinToolsSSH.q("it's") == "'it'\\''s'")
            #expect(BuiltinToolsSSH.q("a b\"c") == "'a b\"c'")
        }

        @Test("posixDirname")
        func dirname() {
            #expect(BuiltinToolsSSH.posixDirname("/a/b/c") == "/a/b")
            #expect(BuiltinToolsSSH.posixDirname("/a") == "/")
            #expect(BuiltinToolsSSH.posixDirname("a/b") == "a")
            #expect(BuiltinToolsSSH.posixDirname("a") == ".")
        }
    }

    @Suite("SSH workdir: socket path naming")
    struct SSHSocketPathTests {
        @Test("contains chat id prefix and sanitized host")
        func naming() {
            let mgr = SSHManager(cacheDir: "/tmp/ichai-sock-test")
            let path = mgr.socketPath(for: SSHContext(host: "user@some host", chatID: "abcdef12-3456-7890-abcd-ef1234567890"))
            #expect(path.hasPrefix("/tmp/ichai-sock-test/ssh-abcdef12-"))
            #expect(path.hasSuffix(".sock"))
            #expect(!path.contains(" "))
        }

        @Test("long hosts fall back to a hash within the unix socket limit")
        func lengthCap() {
            let mgr = SSHManager(cacheDir: "/tmp/ichai-sock-test")
            let longHost = String(repeating: "a", count: 200) + ".example.com"
            let path = mgr.socketPath(for: SSHContext(host: longHost, chatID: "abcdef12-3456-7890-abcd-ef1234567890"))
            // macOS sun_path is 104 bytes and ssh adds a 16-char temp suffix
            // while creating the socket — the visible path must stay under
            // both.
            #expect(path.utf8.count + 17 <= 104)
            #expect(!path.contains(String(repeating: "a", count: 200)))
        }

        @Test("a deep cache dir falls back to /tmp")
        func deepCacheDirFallback() {
            let deep = "/var/folders/99/dtjm1r114blf6b3bsp9lv57m0000gn/T/ichai-test-socks"
            let mgr = SSHManager(cacheDir: deep)
            let path = mgr.socketPath(for: SSHContext(host: "ichai-test", chatID: "0339D0B0-3456-7890-abcd-ef1234567890"))
            #expect(path.utf8.count + 17 <= 104)
            #expect(path.hasPrefix("/tmp/"))
        }

        @Test("different chats get different sockets for the same host")
        func perChat() {
            let mgr = SSHManager(cacheDir: "/tmp/ichai-sock-test")
            let a = mgr.socketPath(for: SSHContext(host: "h", chatID: "11111111-2222-3333-4444-555555555555"))
            let b = mgr.socketPath(for: SSHContext(host: "h", chatID: "66666666-7777-8888-9999-000000000000"))
            #expect(a != b)
        }
    }

    @Suite("SSH workdir: patch planner with injected provider")
    struct SSHPatchPlanTests {
        /// The SSH apply_patch pre-fetches remote contents and plans against
        /// them; this exercises the injectable-provider plan path directly.
        @Test("update applies against provided content")
        func updateViaProvider() throws {
            let wd = Workdir(root: "/remote", isolated: false)
            let patch = """
            *** Begin Patch
            *** Update File: f.txt
            @@
            -old
            +new
            *** End Patch
            """
            let parsed = try PatchParser.parse(patch)
            let ops = try PatchApplier.plan(
                hunks: parsed.hunks,
                workdir: wd,
                fileExists: { $0 == "/remote/f.txt" },
                fileContent: { $0 == "/remote/f.txt" ? "old\n" : nil }
            )
            guard ops.count == 1, case .updateFile(_, _, _, _, _, _, let newContent) = ops[0] else {
                Issue.record("expected a single updateFile op")
                return
            }
            #expect(newContent == "new\n")
        }

        @Test("add on an existing (provided) file fails")
        func addExistingFails() throws {
            let wd = Workdir(root: "/remote", isolated: false)
            let patch = """
            *** Begin Patch
            *** Add File: f.txt
            +content
            *** End Patch
            """
            let parsed = try PatchParser.parse(patch)
            #expect(throws: ApplyPatchError.self) {
                try PatchApplier.plan(
                    hunks: parsed.hunks,
                    workdir: wd,
                    fileExists: { _ in true },
                    fileContent: { _ in "existing\n" }
                )
            }
        }

        @Test("delete on a missing file fails")
        func deleteMissingFails() throws {
            let wd = Workdir(root: "/remote", isolated: false)
            let patch = """
            *** Begin Patch
            *** Delete File: gone.txt
            *** End Patch
            """
            let parsed = try PatchParser.parse(patch)
            #expect(throws: ApplyPatchError.self) {
                try PatchApplier.plan(
                    hunks: parsed.hunks,
                    workdir: wd,
                    fileExists: { _ in false },
                    fileContent: { _ in nil }
                )
            }
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
