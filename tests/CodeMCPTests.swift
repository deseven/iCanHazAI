import Testing
import Foundation
import MCP

/// Integration tests for the Code MCP server.
///
/// Three launch modes:
/// - `CodeMCPDefaultTests`: no args (paths relative to `~`, absolute allowed).
/// - `CodeMCPWorkdirTests`: `--workdir <tmp>` (relative paths resolve against
///   the workdir, absolute paths still allowed, git runs with that cwd).
/// - `CodeMCPIsolateTests`: `--workdir <tmp> --isolate` (chroot-like).
///
/// Each suite shares one server process via [`UtilsMCPShared`](MCPTestHarness.swift).
///
/// Nested under `AllMCPTests` (see `AllTests.swift`) so its `.serialized`
/// trait forces these suites to run strictly sequentially with every other
/// bundled-MCP suite, not just internally.
extension AllMCPTests {

@Suite("CodeMCP (default)", .serialized, .timeLimit(.minutes(1)))
struct CodeMCPDefaultTests {

    let harness: MCPTestHarness
    let tmp: TempDir

    init() async throws {
        harness = try await UtilsMCPShared.shared(.code)
        tmp = try TempDir()
    }

    // MARK: - tools/list

    @Test("lists all expected tools")
    func listsTools() async throws {
        let tools = try await harness.listTools()
        let names = Set(tools.map(\.name))
        #expect(names == ["apply_patch", "git"])
    }

    // MARK: - apply_patch: Add File

    @Test("apply_patch adds a new file")
    func patchAddFile() async throws {
        let path = tmp.sub("new.swift")
        let patch = """
        *** Begin Patch
        *** Add File: \(path)
        +let x = 42
        +print(x)
        *** End Patch
        """
        let (text, err) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        #expect(!err)
        #expect(text.contains("Added"))
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("let x = 42"))
    }

    // MARK: - apply_patch: Delete File

    @Test("apply_patch deletes a file")
    func patchDeleteFile() async throws {
        let path = tmp.sub("kill.txt")
        try tmp.write("kill.txt", content: "bye")
        let patch = """
        *** Begin Patch
        *** Delete File: \(path)
        *** End Patch
        """
        let (text, err) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        #expect(!err)
        #expect(text.contains("Deleted"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - apply_patch: Update File

    @Test("apply_patch updates an existing file")
    func patchUpdateFile() async throws {
        let path = tmp.sub("edit.txt")
        try tmp.write("edit.txt", content: "line one\nline two\nline three\n")
        // The apply_patch format uses context lines (prefixed with a space) to
        // anchor the change. The `@@` header is optional context; here we use
        // a plain `@@` with surrounding context lines.
        let patch = """
        *** Begin Patch
        *** Update File: \(path)
        @@
         line one
        -line two
        +line TWO
         line three
        *** End Patch
        """
        // Note: `@@` must have no trailing content; a bare `@@` means no
        // change-context (anchored by the surrounding context lines).
        let (text, _) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        // apply_patch returns failures as text (not isError), so check text.
        #expect(text.contains("Updated"), "patch failed: \(text)")
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("line TWO"))
        #expect(!content.contains("line two\n"))
    }

    @Test("apply_patch errors on missing file for update")
    func patchUpdateMissing() async throws {
        let path = tmp.sub("nope.txt")
        let patch = """
        *** Begin Patch
        *** Update File: \(path)
        @@
        +new
        *** End Patch
        """
        // apply_patch returns failures as text content (isError is false).
        let (text, _) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        #expect(text.contains("does not exist"))
    }

    @Test("apply_patch errors on add when file exists")
    func patchAddExists() async throws {
        let path = tmp.sub("exists.txt")
        try tmp.write("exists.txt", content: "x")
        let patch = """
        *** Begin Patch
        *** Add File: \(path)
        +new
        *** End Patch
        """
        let (text, _) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        #expect(text.contains("already exists"))
    }

    @Test("apply_patch errors on missing patch argument")
    func patchMissing() async throws {
        let (text, err) = try await harness.callTool("apply_patch", [:])
        #expect(err)
        #expect(text.contains("patch"))
    }

    // MARK: - git

    @Test("git runs a command")
    func gitStatus() async throws {
        // git init in tmp, then status via the tool (cwd defaults to ~).
        let (text, err) = try await harness.callTool("git", ["args": .array([.string("--version")])])
        #expect(!err)
        #expect(text.contains("git version"))
    }

    @Test("git errors on missing args")
    func gitMissing() async throws {
        let (text, err) = try await harness.callTool("git", [:])
        #expect(err)
        #expect(text.contains("args"))
    }

    @Test("git errors on empty args")
    func gitEmpty() async throws {
        let (text, err) = try await harness.callTool("git", ["args": .array([])])
        #expect(err)
        #expect(text.contains("empty"))
    }

    // MARK: - unknown tool

    @Test("unknown tool errors")
    func unknownTool() async throws {
        let (text, err) = try await harness.callTool("nope", [:])
        #expect(err)
        #expect(text.contains("unknown tool"))
    }
}

@Suite("CodeMCP (--workdir)", .serialized, .timeLimit(.minutes(1)))
struct CodeMCPWorkdirTests {

    let harness: MCPTestHarness
    let tmp: TempDir

    init() async throws {
        tmp = try TempDir()
        harness = try await UtilsMCPShared.shared(.code, workdir: tmp.path)
    }

    @Test("apply_patch uses relative paths against workdir")
    func patchRelative() async throws {
        let patch = """
        *** Begin Patch
        *** Add File: rel.txt
        +hello workdir
        *** End Patch
        """
        let (_, err) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        #expect(!err)
        #expect(tmp.exists("rel.txt"))
        #expect(try tmp.read("rel.txt").contains("hello workdir"))
    }

    @Test("git runs with workdir as cwd")
    func gitCwd() async throws {
        // Init a repo in the workdir, add a file, commit, then status.
        _ = try await harness.callTool("git", ["args": .array([.string("init")])])
        _ = try await harness.callTool("apply_patch", ["patch": .string("""
        *** Begin Patch
        *** Add File: tracked.txt
        +content
        *** End Patch
        """)])
        _ = try await harness.callTool("git", ["args": .array([.string("add"), .string("tracked.txt")])])
        let (status, _) = try await harness.callTool("git", ["args": .array([.string("status"), .string("--short")])])
        #expect(status.contains("tracked.txt"))
    }
}

@Suite("CodeMCP (--workdir --isolate)", .serialized, .timeLimit(.minutes(1)))
struct CodeMCPIsolateTests {

    let harness: MCPTestHarness
    let tmp: TempDir

    init() async throws {
        tmp = try TempDir()
        harness = try await UtilsMCPShared.shared(.code, workdir: tmp.path, isolate: true)
    }

    @Test("absolute path treated as relative to root")
    func absoluteAsRelative() async throws {
        let patch = """
        *** Begin Patch
        *** Add File: /isolated.txt
        +isolated content
        *** End Patch
        """
        let (_, err) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        #expect(!err)
        #expect(tmp.exists("isolated.txt"))
    }

    @Test("path escape via .. is rejected")
    func escapeRejected() async throws {
        let patch = """
        *** Begin Patch
        *** Add File: ../../escaped.txt
        +bad
        *** End Patch
        """
        let (text, err) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        #expect(err)
        #expect(text.contains("escapes"))
    }

    @Test("relative path works")
    func relativePath() async throws {
        let patch = """
        *** Begin Patch
        *** Add File: rel.txt
        +ok
        *** End Patch
        """
        let (_, err) = try await harness.callTool("apply_patch", ["patch": .string(patch)])
        #expect(!err)
        #expect(tmp.exists("rel.txt"))
    }
}

} // extension AllMCPTests
