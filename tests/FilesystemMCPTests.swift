import Testing
import Foundation
import MCP

/// Integration tests for the Filesystem MCP server.
///
/// Three launch modes are covered by three suites:
/// - `FilesystemMCPDefaultTests`: no args (paths relative to `~`, absolute
///   paths allowed). Uses absolute temp-dir paths.
/// - `FilesystemMCPWorkdirTests`: `--workdir <tmp>` (relative paths resolve
///   against the workdir, absolute paths still allowed).
/// - `FilesystemMCPConfineTests`: `--workdir <tmp> --confine` (chroot-like:
///   absolute paths treated as relative to the root, escapes rejected).
///
/// Each suite shares one server process via [`UtilsMCPShared`](MCPTestHarness.swift)
/// to avoid orphaned swift-sdk clients (see the comment on `SharedHarness`).
///
/// Nested under `AllMCPTests` (see `AllTests.swift`) so its `.serialized`
/// trait forces these suites to run strictly sequentially with every other
/// bundled-MCP suite, not just internally.
extension AllMCPTests {

@Suite("FilesystemMCP (default)", .serialized, .timeLimit(.minutes(1)))
struct FilesystemMCPDefaultTests {

    let harness: MCPTestHarness
    let tmp: TempDir

    init() async throws {
        harness = try await UtilsMCPShared.shared(.filesystem)
        tmp = try TempDir()
    }

    // MARK: - tools/list

    @Test("lists all expected tools")
    func listsTools() async throws {
        let tools = try await harness.listTools()
        let names = Set(tools.map(\.name))
        #expect(names == ["ls", "read_file", "write_file", "find_file", "find_text", "mkdir", "mv", "rm", "stat"])
    }

    // MARK: - write_file / read_file

    @Test("write_file then read_file round-trips")
    func writeReadRoundTrip() async throws {
        let path = tmp.sub("hello.txt")
        let (w, wErr) = try await harness.callTool("write_file", ["path": .string(path), "content": .string("line1\nline2\n")])
        #expect(!wErr)
        #expect(w.contains("Wrote"))

        let (r, rErr) = try await harness.callTool("read_file", ["path": .string(path)])
        #expect(!rErr)
        // read_file adds line numbers: "     1\tline1" etc.
        #expect(r.contains("line1"))
        #expect(r.contains("line2"))
    }

    @Test("read_file supports offset and limit")
    func readOffsetLimit() async throws {
        let path = tmp.sub("offset.txt")
        try tmp.write("offset.txt", content: "a\nb\nc\nd\ne\n")
        let (r, rErr) = try await harness.callTool("read_file", ["path": .string(path), "offset": .int(2), "limit": .int(2)])
        #expect(!rErr)
        #expect(r.contains("b"))
        #expect(r.contains("c"))
        #expect(!r.contains("d"))
    }

    @Test("read_file errors on missing file")
    func readMissing() async throws {
        let (text, isError) = try await harness.callTool("read_file", ["path": .string(tmp.sub("nope.txt"))])
        #expect(isError)
        #expect(text.contains("not found"))
    }

    @Test("read_file errors on directory")
    func readDir() async throws {
        let (text, isError) = try await harness.callTool("read_file", ["path": .string(tmp.path)])
        #expect(isError)
        #expect(text.contains("directory"))
    }

    @Test("write_file creates parent directories")
    func writeCreatesParents() async throws {
        let path = tmp.sub("a/b/c/file.txt")
        let (_, err) = try await harness.callTool("write_file", ["path": .string(path), "content": .string("x")])
        #expect(!err)
        #expect(tmp.exists("a/b/c/file.txt"))
    }

    // MARK: - ls

    @Test("ls lists a directory")
    func lsLists() async throws {
        try tmp.write("alpha.txt", content: "1")
        try tmp.write("beta.txt", content: "2")
        let (text, err) = try await harness.callTool("ls", ["path": .string(tmp.path)])
        #expect(!err)
        #expect(text.contains("alpha.txt"))
        #expect(text.contains("beta.txt"))
    }

    @Test("ls recursive")
    func lsRecursive() async throws {
        try tmp.write("dir/nested.txt", content: "x")
        let (text, err) = try await harness.callTool("ls", ["path": .string(tmp.path), "recursive": .bool(true)])
        #expect(!err)
        #expect(text.contains("nested.txt"))
    }

    @Test("ls errors on missing path")
    func lsMissing() async throws {
        let (text, err) = try await harness.callTool("ls", ["path": .string(tmp.sub("nope"))])
        #expect(err)
        #expect(text.contains("not found"))
    }

    // MARK: - mkdir / mv / rm

    @Test("mkdir creates a directory")
    func mkdirCreates() async throws {
        let path = tmp.sub("newdir")
        let (_, err) = try await harness.callTool("mkdir", ["path": .string(path)])
        #expect(!err)
        #expect(tmp.exists("newdir"))
    }

    @Test("mv moves a file")
    func mvMoves() async throws {
        try tmp.write("src.txt", content: "data")
        let src = tmp.sub("src.txt")
        let dst = tmp.sub("dst.txt")
        let (_, err) = try await harness.callTool("mv", ["src": .string(src), "dst": .string(dst)])
        #expect(!err)
        #expect(!tmp.exists("src.txt"))
        #expect(tmp.exists("dst.txt"))
    }

    @Test("rm deletes a file")
    func rmDeletes() async throws {
        try tmp.write("kill.txt", content: "x")
        let (_, err) = try await harness.callTool("rm", ["path": .string(tmp.sub("kill.txt"))])
        #expect(!err)
        #expect(!tmp.exists("kill.txt"))
    }

    @Test("rm non-recursive directory errors")
    func rmDirNonRecursive() async throws {
        try tmp.write("nonempty/a.txt", content: "x")
        let (text, err) = try await harness.callTool("rm", ["path": .string(tmp.sub("nonempty"))])
        #expect(err)
        #expect(text.contains("recursive"))
    }

    @Test("rm recursive deletes a directory")
    func rmRecursive() async throws {
        try tmp.write("tree/a.txt", content: "x")
        try tmp.write("tree/b.txt", content: "y")
        let (_, err) = try await harness.callTool("rm", ["path": .string(tmp.sub("tree")), "recursive": .bool(true)])
        #expect(!err)
        #expect(!tmp.exists("tree"))
    }

    // MARK: - stat

    @Test("stat returns metadata")
    func statReturns() async throws {
        try tmp.write("stat.txt", content: "hello")
        let (text, err) = try await harness.callTool("stat", ["path": .string(tmp.sub("stat.txt"))])
        #expect(!err)
        #expect(text.contains("\"type\":\"file\""))
        #expect(text.contains("\"size\":\"5\""))
    }

    // MARK: - find_file / find_text

    @Test("find_file matches by glob")
    func findFileGlob() async throws {
        try tmp.write("find/me.swift", content: "x")
        try tmp.write("find/me.txt", content: "y")
        let (text, err) = try await harness.callTool("find_file", ["path": .string(tmp.sub("find")), "pattern": .string("*.swift")])
        #expect(!err)
        #expect(text.contains("me.swift"))
        #expect(!text.contains("me.txt"))
    }

    @Test("find_text searches file contents")
    func findText() async throws {
        try tmp.write("search/a.txt", content: "needle in haystack")
        try tmp.write("search/b.txt", content: "nothing here")
        let (text, err) = try await harness.callTool("find_text", ["path": .string(tmp.sub("search")), "regex": .string("needle")])
        #expect(!err)
        #expect(text.contains("a.txt"))
        #expect(!text.contains("b.txt"))
    }

    // MARK: - unknown tool

    @Test("unknown tool errors")
    func unknownTool() async throws {
        let (text, err) = try await harness.callTool("nope", [:])
        #expect(err)
        #expect(text.contains("unknown tool"))
    }
}

@Suite("FilesystemMCP (--workdir)", .serialized, .timeLimit(.minutes(1)))
struct FilesystemMCPWorkdirTests {

    let harness: MCPTestHarness
    let tmp: TempDir

    init() async throws {
        tmp = try TempDir()
        harness = try await UtilsMCPShared.shared(.filesystem, workdir: tmp.path)
    }

    @Test("relative path resolves against workdir")
    func relativePath() async throws {
        let (_, err) = try await harness.callTool("write_file", ["path": .string("rel.txt"), "content": .string("hi")])
        #expect(!err)
        #expect(tmp.exists("rel.txt"))
    }

    @Test("absolute path is allowed without --confine")
    func absolutePath() async throws {
        let abs = tmp.sub("abs.txt")
        let (_, err) = try await harness.callTool("write_file", ["path": .string(abs), "content": .string("x")])
        #expect(!err)
        #expect(tmp.exists("abs.txt"))
    }

    @Test("ls with relative path")
    func lsRelative() async throws {
        try tmp.write("one.txt", content: "1")
        let (text, err) = try await harness.callTool("ls", ["path": .string(".")])
        #expect(!err)
        #expect(text.contains("one.txt"))
    }

    @Test("find_file defaults to workdir root")
    func findFileDefaultRoot() async throws {
        try tmp.write("deep/needle.swift", content: "x")
        let (text, err) = try await harness.callTool("find_file", ["pattern": .string("needle.swift")])
        #expect(!err)
        #expect(text.contains("needle.swift"))
    }
}

@Suite("FilesystemMCP (--workdir --confine)", .serialized, .timeLimit(.minutes(1)))
struct FilesystemMCPConfineTests {

    let harness: MCPTestHarness
    let tmp: TempDir

    init() async throws {
        tmp = try TempDir()
        harness = try await UtilsMCPShared.shared(.filesystem, workdir: tmp.path, confine: true)
    }

    @Test("absolute path treated as relative to root")
    func absoluteTreatedAsRelative() async throws {
        // With --confine, "/file.txt" means "<workdir>/file.txt".
        let (_, err) = try await harness.callTool("write_file", ["path": .string("/confined.txt"), "content": .string("x")])
        #expect(!err)
        #expect(tmp.exists("confined.txt"))
    }

    @Test("relative path works")
    func relativePath() async throws {
        let (_, err) = try await harness.callTool("write_file", ["path": .string("rel.txt"), "content": .string("y")])
        #expect(!err)
        #expect(tmp.exists("rel.txt"))
    }

    @Test("path escape via .. is rejected")
    func escapeRejected() async throws {
        let (text, err) = try await harness.callTool("write_file", ["path": .string("../../escaped.txt"), "content": .string("z")])
        #expect(err)
        #expect(text.contains("escapes"))
    }

    @Test("ls of / lists workdir root")
    func lsRoot() async throws {
        try tmp.write("visible.txt", content: "x")
        let (text, err) = try await harness.callTool("ls", ["path": .string("/")])
        #expect(!err)
        #expect(text.contains("visible.txt"))
    }
}

} // extension AllMCPTests
