// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation

/// The CLI front-end. When the binary is launched directly from a shell (not
/// via LaunchServices) it acts as a client of the running app: it connects to
/// the control socket, performs the hello/welcome handshake, sends a
/// `chat.send` request, and streams the reply to stdout.
///
/// When the app isn't running, the CLI spawns it headlessly (`--headless`:
/// normal startup, but the main window is not revealed) and waits for the
/// control socket to appear — connect attempts double as the liveness probe,
/// so no separate socket-file watching is needed.
enum CLIClient {

    // MARK: - Mode detection

    /// Whether this process invocation is a CLI call rather than a GUI
    /// launch. LaunchServices launches are detected by the
    /// `__CFBundleIdentifier` environment variable matching our own bundle id
    /// (a terminal-run binary inherits the *terminal's* id, or none); the
    /// legacy `-psn_…` arg and the explicit `--headless` flag also mean GUI.
    static func isCLIInvocation(
        _ args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        if args.contains("--headless") { return false }
        if args.contains(where: { $0.hasPrefix("-psn_") }) { return false }
        if let envID = environment["__CFBundleIdentifier"], let bundleID, envID == bundleID {
            return false
        }
        return true
    }

    // MARK: - Options

    struct CLIOptions: Equatable {
        var words: [String] = []
        var role: String?
        var connection: String?
        var chat: String?
        var help = false

        enum ParseError: Error, Equatable, CustomStringConvertible {
            case unknownFlag(String)
            case missingFlagValue(String)

            var description: String {
                switch self {
                case .unknownFlag(let flag): return "unknown option: \(flag)"
                case .missingFlagValue(let flag): return "option \(flag) requires a value"
                }
            }
        }

        static func parse(_ args: [String]) throws -> CLIOptions {
            var opts = CLIOptions()
            var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "-h", "--help":
                    opts.help = true
                case "--role", "--connection", "--chat":
                    guard i + 1 < args.count else { throw ParseError.missingFlagValue(arg) }
                    let value = args[i + 1]
                    i += 1
                    switch arg {
                    case "--role": opts.role = value
                    case "--connection": opts.connection = value
                    default: opts.chat = value
                    }
                case "--":
                    opts.words.append(contentsOf: args[(i + 1)...])
                    return opts
                default:
                    if arg.hasPrefix("-") && arg != "-" {
                        throw ParseError.unknownFlag(arg)
                    }
                    opts.words.append(arg)
                }
                i += 1
            }
            return opts
        }
    }

    // MARK: - Run

    /// Executes the CLI flow and returns the process exit code:
    /// 0 = reply printed, 1 = runtime error, 2 = usage error.
    static func run(_ args: [String]) async -> Int32 {
        let opts: CLIOptions
        do {
            opts = try CLIOptions.parse(args)
        } catch {
            stderr("\(error)")
            printUsage(toStderr: true)
            return 2
        }
        if opts.help {
            printUsage(toStderr: false)
            return 0
        }

        var message = opts.words.joined(separator: " ")
        if message.isEmpty, isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            if let data = try? FileHandle.standardInput.readToEnd(),
               let text = String(data: data, encoding: .utf8) {
                message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !message.isEmpty else {
            printUsage(toStderr: true)
            return 2
        }

        let socketPath = EnvironmentManager.shared.socketURL.path
        var fd = try? UnixSocket.connect(path: socketPath)
        if fd == nil {
            if isAppRunning() {
                // The app is up but hasn't created the socket yet (still
                // initializing) — wait for it instead of spawning a copy.
                stderr("waiting for iCanHazAI's control socket…")
            } else {
                stderr("iCanHazAI is not running — starting it in the background…")
                spawnHeadlessApp()
            }
            let deadline = Date().addingTimeInterval(60)
            while fd == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                fd = try? UnixSocket.connect(path: socketPath)
            }
            guard fd != nil else {
                stderr("timed out waiting for iCanHazAI's control socket.")
                return 1
            }
        }

        let conn = CLIConnection(fd: fd!)
        defer { conn.close() }
        do {
            try conn.send(.hello(pid: getpid(), client: "cli", protocolVersion: CLIProtocol.version))
        } catch {
            stderr("failed to greet iCanHazAI — \(error.localizedDescription)")
            return 1
        }

        // If the greeting never arrives, close the connection to break out
        // of the read loop below.
        let greeted = LockedFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !greeted.get() { conn.close() }
        }

        var requestID: String?
        var terminated = false
        var lastCharNewline = true
        var exitCode: Int32 = 1

        loop: for await event in conn.events {
            switch event {
            case .malformed(_, let error):
                stderr("warning: ignored a malformed frame (\(error))")
            case .frame(let frame):
                switch frame {
                case .welcome:
                    greeted.set(true)
                    let reqID = UUID().uuidString
                    requestID = reqID
                    do {
                        try conn.send(.request(CLIRequest(
                            id: reqID,
                            method: CLIRequest.methodChatSend,
                            params: CLIRequestParams(message: message, role: opts.role, connection: opts.connection, chat: opts.chat)
                        )))
                    } catch {
                        stderr("failed to send the request — \(error.localizedDescription)")
                        break loop
                    }
                case .started(let id, _):
                    guard id == requestID else { break }
                case .delta(let id, let text):
                    guard id == requestID else { break }
                    guard writeStdout(text) else {
                        // The stdout reader went away (e.g. `| head`). The
                        // chat keeps streaming in the app; exit quietly.
                        exitCode = 0
                        terminated = true
                        break loop
                    }
                    lastCharNewline = text.hasSuffix("\n")
                case .done(let id, _):
                    guard id == requestID else { break }
                    if !lastCharNewline { _ = writeStdout("\n") }
                    exitCode = 0
                    terminated = true
                    break loop
                case .error(let id, _, let message):
                    guard id == requestID || id == nil else { break }
                    if !lastCharNewline { _ = writeStdout("\n") }
                    stderr("error: \(message)")
                    exitCode = 1
                    terminated = true
                    break loop
                case .hello, .ping, .pong, .request:
                    break // client-side frames / unused by this client
                }
            }
        }
        watchdog.cancel()

        if !greeted.get() {
            stderr("timed out waiting for iCanHazAI's greeting.")
            return 1
        }
        if !terminated {
            stderr("connection to iCanHazAI was lost.")
            return 1
        }
        return exitCode
    }

    // MARK: - App (re)spawn

    private static func isAppRunning() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "wtf.d7.icanhazai"
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Launches the same binary with `--headless`, fully detached: stdio is
    /// redirected to /dev/null so the app's log output can't pollute the CLI's
    /// terminal, and the child outlives this process.
    private static func spawnHeadlessApp() {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--headless"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            stderr("failed to start iCanHazAI — \(error.localizedDescription)")
        }
    }

    // MARK: - Output helpers

    @discardableResult
    private static func writeStdout(_ text: String) -> Bool {
        do {
            try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func printUsage(toStderr: Bool) {
        let usage = """
        Usage: iCanHazAI [options] <message…>
               <command> | iCanHazAI [options]

        Sends a message and streams the reply to stdout. Creates a new chat
        (default role and connection) unless --chat is given. Chats created
        here are regular chats, visible and continuable in the GUI.

        Options:
          --chat <filename>   Continue an existing chat instead of creating a new one
          --role <name>       Role for the new chat (default: the app's default role)
          --connection <id>   Connection for the new chat, "provider/name"
          --                  Treat the remaining arguments as the message
          -h, --help          Show this help

        The app must be running; it is started automatically (without showing
        the main window) when it isn't. Control socket: ~/iCanHazAI/app.sock
        """
        if toStderr {
            stderr(usage)
        } else {
            writeStdout(usage + "\n")
        }
    }
}

/// A lock-protected boolean for cross-task flag sharing (the CLI's greeting
/// watchdog). Satisfies the concurrency checker for shared mutable state.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
