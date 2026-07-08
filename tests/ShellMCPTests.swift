import Testing
import Foundation
import MCP

/// Integration tests for the Shell MCP server.
///
/// Two launch modes:
/// - `ShellMCPDefaultTests`: no args (commands run with cwd `~`).
/// - `ShellMCPWorkdirTests`: `--workdir <tmp>` (commands run with that cwd;
///   no path confinement — `--confine` is not supported by Shell MCP).
///
/// Each suite shares one server process via [`UtilsMCPShared`](MCPTestHarness.swift).
/// Nested under `AllMCPTests` (see `AllTests.swift`) so its `.serialized`
/// trait forces this suite to run strictly sequentially with every other
/// bundled-MCP suite, not just internally.
extension AllMCPTests {

@Suite("ShellMCP (default)", .serialized, .timeLimit(.minutes(1)))
struct ShellMCPDefaultTests {

    let harness: MCPTestHarness

    init() async throws {
        harness = try await UtilsMCPShared.shared(.shell)
    }

    // MARK: - tools/list

    @Test("lists all expected tools")
    func listsTools() async throws {
        let tools = try await harness.listTools()
        let names = Set(tools.map(\.name))
        #expect(names == ["shell", "applescript", "shell_background", "read_output"])
    }

    // MARK: - shell

    @Test("shell runs a command and returns stdout")
    func shellEcho() async throws {
        let (text, err) = try await harness.callTool("shell", ["command": .string("echo hello-shell")])
        #expect(!err)
        #expect(text.contains("hello-shell"))
        #expect(text.contains("[exit code: 0]"))
    }

    @Test("shell returns non-zero exit code")
    func shellNonZero() async throws {
        let (text, err) = try await harness.callTool("shell", ["command": .string("exit 3")])
        #expect(!err)
        #expect(text.contains("[exit code: 3]"))
    }

    @Test("shell errors on missing command")
    func shellMissing() async throws {
        let (text, err) = try await harness.callTool("shell", [:])
        #expect(err)
        #expect(text.contains("command"))
    }

    @Test("shell respects a cwd argument")
    func shellCwd() async throws {
        let tmp = try TempDir()
        let (text, err) = try await harness.callTool("shell", ["command": .string("pwd"), "cwd": .string(tmp.path)])
        #expect(!err)
        #expect(text.contains(tmp.path))
    }

    @Test("shell timeout kills a long command")
    func shellTimeout() async throws {
        let (text, err) = try await harness.callTool("shell", ["command": .string("sleep 30"), "timeout": .int(1)])
        #expect(!err)
        #expect(text.contains("timed out"))
    }

    // MARK: - applescript

    @Test("applescript returns a result")
    func applescript() async throws {
        let (text, err) = try await harness.callTool("applescript", ["script": .string("return 1 + 1")])
        #expect(!err)
        #expect(text.contains("2"))
    }

    @Test("applescript errors on bad script")
    func applescriptBad() async throws {
        let (text, err) = try await harness.callTool("applescript", ["script": .string("this is not applescript")])
        #expect(!err)
        #expect(text.contains("AppleScript error"))
    }

    @Test("applescript errors on missing script")
    func applescriptMissing() async throws {
        let (text, err) = try await harness.callTool("applescript", [:])
        #expect(err)
        #expect(text.contains("script"))
    }

    // MARK: - shell_background / read_output

    @Test("shell_background then read_output returns output")
    func backgroundThenRead() async throws {
        let (spawn, spawnErr) = try await harness.callTool("shell_background", ["command": .string("echo bg-hello")])
        #expect(!spawnErr)
        #expect(spawn.contains("handle:"))

        // Parse the handle integer.
        let handleLine = spawn.split(separator: "\n").first(where: { $0.hasPrefix("handle:") }) ?? ""
        let handleStr = handleLine.replacingOccurrences(of: "handle:", with: "").trimmingCharacters(in: .whitespaces)
        guard let handle = Int(handleStr) else {
            Issue.record("could not parse handle from: \(spawn)")
            return
        }

        let (text, err) = try await harness.callTool("read_output", ["handle": .int(handle), "wait": .bool(true)])
        #expect(!err)
        #expect(text.contains("bg-hello"))
        #expect(text.contains("[exit code: 0]"))
    }

    @Test("read_output on unknown handle returns error text")
    func readUnknownHandle() async throws {
        let (text, err) = try await harness.callTool("read_output", ["handle": .int(99999)])
        #expect(!err)
        #expect(text.contains("no background command"))
    }

    @Test("read_output errors on missing handle")
    func readMissingHandle() async throws {
        let (text, err) = try await harness.callTool("read_output", [:])
        #expect(err)
        #expect(text.contains("handle"))
    }

    // MARK: - unknown tool

    @Test("unknown tool errors")
    func unknownTool() async throws {
        let (text, err) = try await harness.callTool("nope", [:])
        #expect(err)
        #expect(text.contains("unknown tool"))
    }
}

@Suite("ShellMCP (--workdir)", .serialized, .timeLimit(.minutes(1)))
struct ShellMCPWorkdirTests {

    let harness: MCPTestHarness
    let tmp: TempDir

    init() async throws {
        tmp = try TempDir()
        harness = try await UtilsMCPShared.shared(.shell, workdir: tmp.path)
    }

    @Test("shell defaults to the workdir as cwd")
    func shellDefaultCwd() async throws {
        let (text, err) = try await harness.callTool("shell", ["command": .string("pwd")])
        #expect(!err)
        #expect(text.contains(tmp.path))
    }

    @Test("shell_background defaults to the workdir as cwd")
    func backgroundDefaultCwd() async throws {
        let (spawn, spawnErr) = try await harness.callTool("shell_background", ["command": .string("pwd")])
        #expect(!spawnErr)
        let handleLine = spawn.split(separator: "\n").first(where: { $0.hasPrefix("handle:") }) ?? ""
        let handleStr = handleLine.replacingOccurrences(of: "handle:", with: "").trimmingCharacters(in: .whitespaces)
        guard let handle = Int(handleStr) else {
            Issue.record("could not parse handle")
            return
        }
        let (text, err) = try await harness.callTool("read_output", ["handle": .int(handle), "wait": .bool(true)])
        #expect(!err)
        #expect(text.contains(tmp.path))
    }

    @Test("shell can still use an absolute cwd outside the workdir (no confinement)")
    func shellAbsoluteCwd() async throws {
        let other = try TempDir()
        let (text, err) = try await harness.callTool("shell", ["command": .string("pwd"), "cwd": .string(other.path)])
        #expect(!err)
        #expect(text.contains(other.path))
    }
}

} // extension AllMCPTests
