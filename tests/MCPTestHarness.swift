import Foundation
import MCP
import ProcessExit
#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// Integration-test harness for the bundled stdio MCP servers.
///
/// Spawns a server binary as a subprocess, wires its stdin/stdout to a real
/// swift-sdk `Client` via `StdioTransport` (the same transport the main app
/// uses in [`MCPManager`](src/MCPManager.swift)), and exposes helpers to list
/// tools, call tools, and assert on the text result. Each instance owns one
/// server process; `shutdown()` must be called to tear it down.
///
/// The harness mirrors the connect flow in
/// [`connectAndListTools`](src/MCPManager.swift:428): a `Process` with piped
/// stdin/stdout/stderr, `FileDescriptor`-backed `StdioTransport`, and a
/// `Client.connect(transport:)` handshake. A startup grace period detects
/// processes that exit immediately (e.g. missing binary), failing fast instead
/// of hanging on the handshake.
final class MCPTestHarness: @unchecked Sendable {

    /// Which bundled server to launch.
    enum Server: String {
        case utils = "UtilsMCP"
        case filesystem = "FilesystemMCP"
        case code = "CodeMCP"
        case shell = "ShellMCP"

        var binaryPath: String {
            let dir = MCPTestHarness.packageRoot
            // Binaries are prefixed `iCanHazAI-` (see Package.swift) so the
            // spawned processes are distinguishable in `ps` / Activity Monitor.
            return "\(dir)/.build/debug/iCanHazAI-\(rawValue)"
        }
    }

    let client: Client
    let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let workdir: String?

    /// Captured stderr (filled on shutdown if the process has exited).
    private var stderrText: String = ""

    /// - Parameters:
    ///   - server: Which bundled server to launch.
    ///   - workdir: Optional `--workdir <path>` argument.
    ///   - confine: If true, appends `--confine` (only meaningful with workdir).
    init(server: Server, workdir: String? = nil, confine: Bool = false) async throws {
        self.workdir = workdir
        self.client = Client(name: "ichai-tests", version: "1.0.0")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: server.binaryPath)
        var args: [String] = []
        if let workdir { args += ["--workdir", workdir] }
        if confine { args += ["--confine"] }
        proc.arguments = args

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Track early termination so we can report stderr if the process
        // dies during the handshake. We intentionally do NOT sleep a grace
        // period (unlike MCPManager.startupGrace): blocking a cooperative
        // thread here can exhaust the pool when multiple suites initialize
        // concurrently, causing intermittent deadlocks. The servers are
        // known-good binaries; a missing one fails the handshake directly.
        let box = TerminationBox()
        proc.terminationHandler = { p in
            box.setTerminated(status: p.terminationStatus, reason: p.terminationReason)
        }

        try proc.run()

        let inputFD = FileDescriptor(rawValue: stdout.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: stdin.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: inputFD, output: outputFD)

        do {
            _ = try await client.connect(transport: transport)
        } catch {
            proc.terminationHandler = nil
            if box.hasTerminated() {
                let stderr = Self.readAll(stderr)
                proc.terminate()
                await awaitProcessExit(proc)
                throw MCPTestError.serverDied(server: server.rawValue, status: box.status ?? -1, stderr: stderr)
            }
            proc.terminate()
            await awaitProcessExit(proc)
            throw error
        }
        proc.terminationHandler = nil
    }

    deinit {
        // Best-effort cleanup if shutdown() wasn't called. We must stop the
        // Client's internal message-loop Task, otherwise it busy-spins on the
        // finished transport stream at 100% CPU after the server exits.
        // `Client.disconnect()` is async and can't be called from deinit, so
        // we detach a Task to do it. Closing stdin first sends EOF to the
        // server so its read loop breaks and it exits cleanly.
        //
        // We must NOT call the blocking `process.waitUntilExit()` here:
        // under concurrent process churn it can hang indefinitely (see
        // `awaitProcessExit`'s doc comment), and `deinit` can't `await` to
        // use the async-safe alternative. `terminate()` alone is enough to
        // signal the child; reaping happens asynchronously below.
        try? stdinPipe.fileHandleForWriting.close()
        let process = self.process
        if process.isRunning {
            process.terminate()
        }
        let client = self.client
        Task {
            await awaitProcessExit(process)
            await client.disconnect()
        }
    }

    /// Tears down the client and terminates the subprocess.
    func shutdown() async {
        await client.disconnect()
        if process.isRunning {
            process.terminate()
            await awaitProcessExit(process)
        }
        stderrText = Self.readAll(stderrPipe)
    }

    // MARK: - Tool helpers

    /// Lists the server's tools, paginating through all cursors.
    func listTools() async throws -> [Tool] {
        var tools: [Tool] = []
        var cursor: String? = nil
        repeat {
            let (batch, next) = try await client.listTools(cursor: cursor)
            tools.append(contentsOf: batch)
            cursor = next
        } while cursor != nil
        return tools
    }

    /// Calls a tool and returns `(text, isError)`, joining all text content.
    func callTool(_ name: String, _ arguments: [String: Value] = [:]) async throws -> (text: String, isError: Bool) {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        let text = content.map { item -> String in
            switch item {
            case .text(let t, _, _): return t
            case .image(_, let mime, _, _): return "[image: \(mime)]"
            case .audio(_, let mime, _, _): return "[audio: \(mime)]"
            case .resource(let r, _, _): return "[resource: \(r.uri)]"
            case .resourceLink(let uri, let n, _, _, _, _): return "[resource link: \(n) at \(uri)]"
            }
        }.joined(separator: "\n")
        return (text, isError ?? false)
    }

    // MARK: - Private

    private static func readAll(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Locates the package root by walking up from #file until a `mcps/` dir exists.
    static let packageRoot: String = {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("mcps")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url.path
            }
            url = url.deletingLastPathComponent()
        }
        return FileManager.default.currentDirectoryPath
    }()
}

/// Captures process termination status/reason from the termination handler.
final class TerminationBox: @unchecked Sendable {
    private(set) var status: Int32? = nil
    private(set) var reason: Process.TerminationReason? = nil
    private var terminated: Bool = false

    func setTerminated(status: Int32, reason: Process.TerminationReason) {
        self.status = status
        self.reason = reason
        self.terminated = true
    }

    func hasTerminated() -> Bool { terminated }
}

enum MCPTestError: Error, CustomStringConvertible {
    case serverDied(server: String, status: Int32, stderr: String)

    var description: String {
        switch self {
        case .serverDied(let s, let st, let err):
            return "MCP server \(s) exited (status \(st)) before handshake. stderr: \(err)"
        }
    }
}

// MARK: - Temp directory helper

/// Creates a unique temp directory and returns its path. Removed on deinit.
final class TempDir {
    let path: String

    init() throws {
        let base = NSTemporaryDirectory()
        let name = "ichai-mcp-tests-\(UUID().uuidString)"
        let dir = (base as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = dir
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Returns a path inside the temp dir.
    func sub(_ relative: String) -> String {
        (path as NSString).appendingPathComponent(relative)
    }

    /// Writes a file inside the temp dir, creating parent dirs.
    @discardableResult
    func write(_ relative: String, content: String) throws -> String {
        let url = sub(relative)
        let dir = (url as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: url))
        return url
    }

    /// Reads a file inside the temp dir as UTF-8 text.
    func read(_ relative: String) throws -> String {
        let url = sub(relative)
        return try String(contentsOf: URL(fileURLWithPath: url), encoding: .utf8)
    }

    /// Checks existence of a path inside the temp dir.
    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: sub(relative))
    }
}

// MARK: - Shared harness registry

/// Process-wide registry of long-lived `MCPTestHarness` instances, keyed by a
/// string description of the server + launch args.
///
/// Each test suite shares a single harness (one process, one client) via this
/// registry instead of spawning one subprocess per test, so tests within a
/// suite reuse the same live connection. The harness lives for the whole test
/// run; the OS reaps the subprocess when the test process exits.
///
/// The cache is keyed by the *creation `Task`* rather than the finished
/// result, and that's stored before the first `await`. Storing the `Task`
/// synchronously closes the window between the cache check and the cache
/// write, so concurrent callers racing for the *same* key (e.g. two suites
/// that happen to share a `--workdir`) always await one shared creation
/// instead of each spawning a duplicate subprocess.
actor SharedHarness {
    private var tasks: [String: Task<MCPTestHarness, Error>] = [:]

    static let shared = SharedHarness()

    /// Returns a shared harness for the given server + args, creating it on
    /// first access. The harness (and its backing subprocess) is kept alive
    /// for the remainder of the process.
    func harness(
        _ server: MCPTestHarness.Server,
        workdir: String? = nil,
        confine: Bool = false
    ) async throws -> MCPTestHarness {
        var key = server.rawValue
        if let workdir { key += "@\(workdir)" }
        if confine { key += "+confine" }

        if let existing = tasks[key] {
            return try await existing.value
        }

        let task = Task {
            try await MCPTestHarness(server: server, workdir: workdir, confine: confine)
        }
        tasks[key] = task
        return try await task.value
    }
}

/// Convenience accessor used by test suites. Async because harness creation
/// involves spawning a process and performing the MCP handshake.
enum UtilsMCPShared {
    static func shared(
        _ server: MCPTestHarness.Server,
        workdir: String? = nil,
        confine: Bool = false
    ) async throws -> MCPTestHarness {
        try await SharedHarness.shared.harness(server, workdir: workdir, confine: confine)
    }
}
