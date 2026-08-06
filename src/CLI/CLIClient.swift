// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation

/// The CLI front-end. When the binary is launched directly from a shell (not
/// via LaunchServices) it acts as a client of the running app: it connects to
/// the control socket, performs the hello/welcome handshake, sends a
/// `chat.send` request, and streams the reply to stdout.
///
/// When the app isn't running, the CLI launches it headlessly (`--headless`:
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
        var workdir: String?
        var temporary = false
        var allowAll = false
        var help = false

        enum ParseError: Error, Equatable, CustomStringConvertible {
            case unknownFlag(String)
            case missingFlagValue(String)
            case conflictingOptions(String)

            var description: String {
                switch self {
                case .unknownFlag(let flag): return "unknown option: \(flag)"
                case .missingFlagValue(let flag): return "option \(flag) requires a value"
                case .conflictingOptions(let message): return message
                }
            }
        }

        static func parse(_ args: [String]) throws -> CLIOptions {
            var opts = CLIOptions()
            var i = 0
            while i < args.count {
                let arg = args[i]
                // Long options accept both "--name value" and "--name=value"
                // (quoting is handled by the shell before we see the args).
                var name = arg
                var inlineValue: String?
                if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                    name = String(arg[..<eq])
                    inlineValue = String(arg[arg.index(after: eq)...])
                }
                switch name {
                case "-h", "--help":
                    opts.help = true
                case "-t", "--temporary":
                    opts.temporary = true
                case "-y", "--allow-all":
                    opts.allowAll = true
                case "-f", "--chat", "-r", "--role", "-c", "--connection", "-w", "--workdir":
                    let value: String
                    if let inlineValue {
                        guard !inlineValue.isEmpty else { throw ParseError.missingFlagValue(name) }
                        value = inlineValue
                    } else {
                        guard i + 1 < args.count else { throw ParseError.missingFlagValue(arg) }
                        i += 1
                        value = args[i]
                    }
                    switch name {
                    case "-f", "--chat": opts.chat = value
                    case "-r", "--role": opts.role = value
                    case "-w", "--workdir": opts.workdir = value
                    default: opts.connection = value
                    }
                case "--":
                    opts.words.append(contentsOf: args[(i + 1)...])
                    return try finish(opts)
                default:
                    if arg.hasPrefix("-") && arg != "-" {
                        throw ParseError.unknownFlag(arg)
                    }
                    opts.words.append(arg)
                }
                i += 1
            }
            return try finish(opts)
        }

        private static func finish(_ opts: CLIOptions) throws -> CLIOptions {
            if opts.temporary, opts.chat != nil {
                throw ParseError.conflictingOptions("--temporary cannot be combined with --chat")
            }
            return opts
        }
    }

    // MARK: - Run

    /// Resolves the working directory sent with the request: the explicit
    /// -w/--workdir value when given (with `~` expanded, unless it's an SSH
    /// spec like `host:/path`), otherwise the CLI process's own cwd.
    static func resolveWorkdir(_ opts: CLIOptions) -> (workdir: String, explicit: Bool) {
        if let w = opts.workdir {
            if SSHSpec.isSSH(w) { return (w, true) }
            return ((w as NSString).expandingTildeInPath, true)
        }
        return (FileManager.default.currentDirectoryPath, false)
    }

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
                    let wd = resolveWorkdir(opts)
                    do {
                        try conn.send(.request(CLIRequest(
                            id: reqID,
                            method: CLIRequest.methodChatSend,
                            params: CLIRequestParams(message: message, role: opts.role, connection: opts.connection, chat: opts.chat, temporary: opts.temporary, workdir: wd.workdir, workdirExplicit: wd.explicit, allowAll: opts.allowAll)
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
                case .tool(let id, let name, let args, let status):
                    guard id == requestID else { break }
                    // Tool lines render like the renderer's collapsed tool
                    // blocks: a header (name + key arguments) when the call
                    // starts, a status line when its result lands.
                    if !lastCharNewline { _ = writeStdout("\n") }
                    guard writeStdout(renderToolFrame(name: name, args: args, status: status)) else {
                        exitCode = 0
                        terminated = true
                        break loop
                    }
                    lastCharNewline = true
                case .notice(let id, let text):
                    guard id == requestID || id == nil else { break }
                    warn(text)
                case .done(let id, _, let name):
                    guard id == requestID else { break }
                    if !lastCharNewline { _ = writeStdout("\n") }
                    // A chat created by this invocation (no --chat, not
                    // temporary) persists in the app — tell the user its name.
                    if opts.chat == nil, !opts.temporary {
                        info("Chat: \(name ?? "New chat")")
                    }
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

    /// Launches the app bundle with `--headless` via LaunchServices. `open`
    /// detaches the app completely — its own session, no shared stdio — so it
    /// outlives this process and no terminal signal (Ctrl-C, terminal close)
    /// can reach it through us; the socket is the only tie between them.
    private static func spawnHeadlessApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", Bundle.main.bundleURL.path, "--args", "--headless"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stderr("failed to start iCanHazAI — \(output ?? "open exited with \(process.terminationStatus)")")
            }
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

    // MARK: - Terminal styling

    /// Whether ANSI styling is used on a stream: it's a terminal, TERM is not
    /// "dumb", and NO_COLOR is unset.
    private static func colorsEnabled(_ handle: FileHandle) -> Bool {
        let env = ProcessInfo.processInfo.environment
        return isatty(handle.fileDescriptor) != 0
            && env["TERM"] != "dumb"
            && env["NO_COLOR"] == nil
    }

    private static let stdoutColor = colorsEnabled(.standardOutput)
    private static let stderrColor = colorsEnabled(.standardError)

    private static func styled(_ text: String, _ code: String, enabled: Bool) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    /// Renders one tool frame as a terminal line. A call start becomes
    /// `⚙ name args-summary`; a finished call becomes `  ✓ done — description`
    /// with the symbol colored by status (green done, red error, yellow
    /// denied/cancelled). Mirrors the chat renderer's collapsed tool blocks.
    static func renderToolFrame(name: String, args: String?, status: CLIToolStatus?, color: Bool = stdoutColor) -> String {
        if let status {
            let (symbol, code): (String, String)
            switch status.kind {
            case "done": (symbol, code) = ("✓", "32")
            case "error": (symbol, code) = ("✗", "31")
            default: (symbol, code) = ("⚠", "33") // denied / cancelled
            }
            var line = "  " + styled(symbol, code, enabled: color)
                + styled(" \(status.label)", "2", enabled: color)
            if !status.description.isEmpty {
                line += styled(" — ", "2", enabled: color) + status.description
            }
            return line + "\n"
        }
        var line = styled("⚙ \(name)", "1;36", enabled: color)
        if let args, !args.isEmpty {
            line += styled(" \(args)", "2", enabled: color)
        }
        return line + "\n"
    }

    /// A warning shown on stderr (yellow when the terminal supports it).
    private static func warn(_ message: String) {
        stderr(styled("warning: \(message)", "33", enabled: stderrColor))
    }

    /// Ancillary meta output on stderr (dim when the terminal supports it).
    private static func info(_ message: String) {
        stderr(styled(message, "2", enabled: stderrColor))
    }

    private static func printUsage(toStderr: Bool) {
        let usage = """
        Usage: iCanHazAI [options] <message…>
               <command> | iCanHazAI [options]

        Sends a message and streams the reply to stdout. Creates a new chat
        (default role and connection) unless --chat is given. Chats created
        here are regular chats, visible and continuable in the GUI — unless
        --temporary is used, in which case the chat only exists while the
        CLI is running.

        Options:
          -f, --chat <name>       Continue an existing chat instead of creating a new one
          -r, --role <name>       Role for the new chat (default: the app's default role)
          -c, --connection <id>   Connection for the new chat, "provider/name"
          -w, --workdir <path>    Working directory for workdir-capable roles
                                  (default: the current directory)
          -y, --allow-all         Auto-approve all tool calls (without it, calls
                                  that need confirmation are skipped)
          -t, --temporary         Use a temporary chat instead of a permanent one
          --                      Treat the remaining arguments as the message
          -h, --help              Show this help

        Long options also accept the --name=value form. The app must be
        running; it is started automatically (without showing the main
        window) when it isn't. Control socket: ~/iCanHazAI/app.sock
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
