// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation

/// The CLI front-end. When the binary is launched directly from a shell (not
/// via LaunchServices) it acts as a client of the running app: it connects to
/// the control socket, performs the hello/welcome handshake, sends a
/// `chat.send` request, and streams the reply to stdout.
///
/// Two modes:
/// - one-shot (default): one message in, the agent's turn streams out (as
///   many tool-call iterations as it takes), exit when the turn ends;
/// - interactive (`-i`): a persistent chat driven from the terminal — the
///   user is prompted for follow-up messages with `< `, tool calls that need
///   confirmation prompt with (y/a/n), and ctrl-C stops the stream after the
///   current iteration (a second ctrl-C quits).
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
    /// legacy `-psn_…` arg and the explicit `--headless`/`--gui` flags also
    /// mean GUI. `--gui` is a hidden flag for running the bundled binary
    /// directly from a terminal (blocking, stdio attached) without falling
    /// into CLI mode.
    static func isCLIInvocation(
        _ args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        if args.contains("--headless") { return false }
        if args.contains("--gui") { return false }
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
        var interactive = false
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
                case "-i", "--interactive":
                    opts.interactive = true
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
        // Non-interactive only: a piped stdin is the message. In interactive
        // mode stdin is the session's input channel instead.
        if message.isEmpty, !opts.interactive, isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            if let data = try? FileHandle.standardInput.readToEnd(),
               let text = String(data: data, encoding: .utf8) {
                message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !opts.interactive, message.isEmpty {
            printUsage(toStderr: true)
            return 2
        }

        guard let conn = await connect() else { return 1 }
        defer { conn.close() }

        if opts.interactive {
            return await runInteractive(opts: opts, initialMessage: message, conn: conn)
        }
        return await runOneShot(opts: opts, message: message, conn: conn)
    }

    /// Connects to the app's control socket (spawning the app headlessly when
    /// it isn't running) and sends the hello frame. Returns nil on failure —
    /// the reason is printed to stderr.
    private static func connect() async -> CLIConnection? {
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
                return nil
            }
        }

        let conn = CLIConnection(fd: fd!)
        do {
            try conn.send(.hello(pid: getpid(), client: "cli", protocolVersion: CLIProtocol.version))
        } catch {
            stderr("failed to greet iCanHazAI — \(error.localizedDescription)")
            conn.close()
            return nil
        }
        return conn
    }

    // MARK: - One-shot mode

    private static func runOneShot(opts: CLIOptions, message: String, conn: CLIConnection) async -> Int32 {
        // If the greeting never arrives, close the connection to break out
        // of the read loop below.
        let greeted = LockedFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !greeted.get() { conn.close() }
        }

        var requestID: String?
        var terminated = false
        let renderer = OutputRenderer()
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
                    guard writeStdout(renderer.delta(text)) else {
                        // The stdout reader went away (e.g. `| head`) —
                        // exit quietly; the app stops the stream when it
                        // notices the disconnect.
                        exitCode = 0
                        terminated = true
                        break loop
                    }
                case .tool(let id, let name, let args, let status):
                    guard id == requestID else { break }
                    if let status {
                        guard writeStdout(renderer.toolResult(name: name, status: status)) else {
                            exitCode = 0
                            terminated = true
                            break loop
                        }
                    } else {
                        renderer.toolStart(name: name, args: args)
                    }
                case .notice(let id, let text):
                    guard id == requestID || id == nil else { break }
                    warn(text)
                case .done(let id, let chat, let name):
                    guard id == requestID else { break }
                    _ = writeStdout(renderer.streamEnd())
                    // A chat created by this invocation (no --chat, not
                    // temporary) persists in the app — tell the user its
                    // name (streamEnd already separated it with a blank line).
                    if opts.chat == nil, !opts.temporary {
                        info(renderChatCreatedLine(chat: chat, name: name))
                    }
                    exitCode = 0
                    terminated = true
                    break loop
                case .error(let id, _, let message):
                    guard id == requestID || id == nil else { break }
                    _ = writeStdout(renderer.streamEnd())
                    stderr("error: \(message)")
                    exitCode = 1
                    terminated = true
                    break loop
                case .hello, .ping, .pong, .request, .approve:
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

    // MARK: - Interactive mode

    /// The interactive (-i) session loop: a persistent chat driven from the
    /// terminal. Output renders line by line exactly like the one-shot mode;
    /// between replies the user is prompted for the next message with `< `
    /// (Enter sends). Ctrl-C requests a stop after the current iteration
    /// (like the GUI's "Stop after streaming"), or cancels the whole request
    /// when a tool confirmation is up (like the GUI's Stop); a second ctrl-C
    /// at any point after that — including at the input prompt — quits.
    /// Ctrl-D (EOF) quits gracefully.
    private static func runInteractive(opts: CLIOptions, initialMessage: String, conn: CLIConnection) async -> Int32 {
        /// Everything the session loop reacts to: socket frames, stdin
        /// bytes, and SIGINT.
        enum SessionEvent {
            case frame(CLIFrame)
            case malformed(String)
            case disconnected
            /// Raw stdin bytes: whole lines in the normal (canonical)
            /// terminal mode, single keypresses in the approval prompt's key
            /// mode.
            case input(Data)
            /// Stdin hit EOF (ctrl-D).
            case inputEOF
            case interrupt
        }

        let (events, push) = AsyncStream<SessionEvent>.makeStream()

        // Socket frames.
        Task {
            for await event in conn.events {
                switch event {
                case .frame(let frame): push.yield(.frame(frame))
                case .malformed(_, let error): push.yield(.malformed(error))
                }
            }
            push.yield(.disconnected)
        }
        // Stdin bytes. A blocking read on a detached thread — it lives until
        // the process exits; the session loop below decides what the bytes
        // mean (lines vs. keypresses) based on the current input mode.
        Task.detached {
            var chunk = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = chunk.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if n > 0 {
                    push.yield(.input(Data(chunk[0..<n])))
                } else if n == 0 || errno != EINTR {
                    push.yield(.inputEOF)
                    break
                }
            }
        }
        // Ctrl-C. SIGINT is ignored at the signal level and delivered via a
        // dispatch source instead, so the process keeps running and the
        // terminal's line editing stays intact.
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { push.yield(.interrupt) }
        sigint.resume()
        defer { sigint.cancel() }

        // If the greeting never arrives, close the connection to break out
        // of the event loop below.
        let greeted = LockedFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !greeted.get() { conn.close() }
        }
        defer { watchdog.cancel() }

        let renderer = OutputRenderer()
        /// The chat this session is bound to, taken from the `started` frame.
        var chatFilename: String?
        var requestID: String?
        var streaming = false
        /// Tool calls awaiting an approval answer, in order; the head is the
        /// one the current prompt is about. (Calls execute sequentially, so
        /// in practice this never holds more than one.)
        var approvalQueue: [String] = [] // call ids
        /// Set after answering "n": the next input line is the deny reason.
        var awaitingDenyReason = false
        /// Stdin bytes not yet consumed (a partial line in line mode).
        var inputBuffer = Data()
        /// The approval prompt's single-keypress mode: the terminal is in
        /// raw mode and every key answers immediately. False when stdin is
        /// not a terminal (piped input answers with whole lines instead).
        var keyMode = false
        /// Terminal attributes saved on entering key mode, restored on exit.
        var savedTermios: termios?
        /// An input/approval prompt is on screen without a trailing newline.
        var promptVisible = false
        /// Set by the first ctrl-C; a second one quits. Reset when a new
        /// message is sent.
        var quitArmed = false
        var announcedChat = false
        var result: Int32 = 0

        func showInputPrompt() {
            _ = writeStdout("< ")
            promptVisible = true
        }

        /// Switches stdin between the normal (canonical, echoing) line mode
        /// and the raw key mode used by the approval prompt, where every
        /// keypress arrives immediately (ISIG stays on, so ctrl-C keeps
        /// signalling). Returns the resulting key-mode state — false when
        /// stdin isn't a terminal.
        @discardableResult
        func setKeyMode(_ enable: Bool) -> Bool {
            if !enable {
                if var saved = savedTermios {
                    tcsetattr(STDIN_FILENO, TCSANOW, &saved)
                    savedTermios = nil
                }
                return false
            }
            guard isatty(STDIN_FILENO) != 0 else { return false }
            var t = termios()
            guard tcgetattr(STDIN_FILENO, &t) == 0 else { return false }
            if savedTermios == nil { savedTermios = t }
            t.c_lflag &= ~tcflag_t(ICANON | ECHO)
            withUnsafeMutableBytes(of: &t.c_cc) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &t)
            return true
        }

        func exitKeyMode() {
            guard keyMode else { return }
            keyMode = false
            setKeyMode(false)
            inputBuffer.removeAll()
        }

        func showApprovalPrompt() {
            if !keyMode {
                keyMode = setKeyMode(true)
                inputBuffer.removeAll()
            }
            _ = writeStdout(styled("  allow? (y/a/n): ", "1", enabled: stdoutColor))
            promptVisible = true
        }

        func sendApproval(decision: String, reason: String? = nil) {
            guard !approvalQueue.isEmpty else { return }
            let callID = approvalQueue.removeFirst()
            try? conn.send(.request(CLIRequest(
                id: UUID().uuidString,
                method: CLIRequest.methodToolApprove,
                params: CLIRequestParams(message: "", callID: callID, decision: decision, reason: reason)
            )))
            if !approvalQueue.isEmpty {
                showApprovalPrompt()
            }
        }

        func sendMessage(_ text: String) {
            let reqID = UUID().uuidString
            let wd = resolveWorkdir(opts)
            let continuing = chatFilename != nil
            do {
                try conn.send(.request(CLIRequest(
                    id: reqID,
                    method: CLIRequest.methodChatSend,
                    params: CLIRequestParams(
                        message: text,
                        role: continuing ? nil : opts.role,
                        connection: continuing ? nil : opts.connection,
                        chat: continuing ? chatFilename : opts.chat,
                        temporary: continuing ? false : opts.temporary,
                        workdir: continuing ? nil : wd.workdir,
                        workdirExplicit: !continuing && wd.explicit,
                        allowAll: opts.allowAll,
                        interactive: true
                    )
                )))
                requestID = reqID
                streaming = true
                quitArmed = false
                // Separate the typed message from the reply with a blank line.
                _ = writeStdout(renderer.userMessageSent())
            } catch {
                stderr("failed to send the message — \(error.localizedDescription)")
                showInputPrompt()
            }
        }

        /// A keypress at the approval prompt (key mode): y/a/n answer
        /// immediately (the pressed key is echoed manually — the terminal's
        /// echo is off), anything else repeats the question.
        func handleKey(_ byte: UInt8) {
            guard !approvalQueue.isEmpty else { return }
            promptVisible = false
            switch byte {
            case UInt8(ascii: "y"), UInt8(ascii: "Y"):
                _ = writeStdout("y\n")
                exitKeyMode()
                sendApproval(decision: "allow")
            case UInt8(ascii: "a"), UInt8(ascii: "A"):
                _ = writeStdout("a\n")
                exitKeyMode()
                sendApproval(decision: "allow_chat")
            case UInt8(ascii: "n"), UInt8(ascii: "N"):
                _ = writeStdout("n\n")
                exitKeyMode()
                awaitingDenyReason = true
                _ = writeStdout(styled("  reason (optional): ", "1", enabled: stdoutColor))
                promptVisible = true
            default:
                _ = writeStdout("\n")
                showApprovalPrompt()
            }
        }

        /// A full input line: a message at the "< " prompt, a line-based
        /// approval answer (piped stdin, where key mode is unavailable), or
        /// a deny reason.
        func handleLine(_ line: String) {
            promptVisible = false
            if awaitingDenyReason {
                awaitingDenyReason = false
                let reason = line.trimmingCharacters(in: .whitespacesAndNewlines)
                sendApproval(decision: "deny", reason: reason.isEmpty ? nil : reason)
            } else if !approvalQueue.isEmpty {
                // Line-based answers: the first character decides.
                switch line.trimmingCharacters(in: .whitespaces).lowercased().first {
                case "y":
                    sendApproval(decision: "allow")
                case "a":
                    sendApproval(decision: "allow_chat")
                case "n":
                    awaitingDenyReason = true
                    _ = writeStdout(styled("  reason (optional): ", "1", enabled: stdoutColor))
                    promptVisible = true
                default:
                    showApprovalPrompt()
                }
            } else if !streaming {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    showInputPrompt()
                } else {
                    sendMessage(text)
                }
            }
            // Lines typed while streaming (no pending prompt) are dropped.
        }

        defer { setKeyMode(false) }

        loop: for await event in events {
            switch event {
            case .malformed(let error):
                stderr("warning: ignored a malformed frame (\(error))")
            case .disconnected:
                if promptVisible { _ = writeStdout("\n") }
                if greeted.get() {
                    stderr("connection to iCanHazAI was lost.")
                } else {
                    stderr("timed out waiting for iCanHazAI's greeting.")
                }
                result = 1
                break loop
            case .interrupt:
                if quitArmed {
                    // Second ctrl-C: stop everything and quit. Closing the
                    // connection (via defer) makes the app stop the stream.
                    if promptVisible || !renderer.atLineStart { _ = writeStdout("\n") }
                    result = 130
                    break loop
                }
                quitArmed = true
                if promptVisible { _ = writeStdout("\n"); promptVisible = false }
                if !approvalQueue.isEmpty || awaitingDenyReason {
                    // Ctrl-C at a tool confirmation cancels the whole request
                    // — like the GUI's Stop: the pending approval and the
                    // remaining tool calls are cancelled, the stream ends
                    // (done arrives below and returns the input prompt).
                    approvalQueue.removeAll()
                    awaitingDenyReason = false
                    exitKeyMode()
                    if let chatFilename {
                        try? conn.send(.request(CLIRequest(
                            id: UUID().uuidString,
                            method: CLIRequest.methodChatStop,
                            params: CLIRequestParams(message: "", chat: chatFilename, immediate: true)
                        )))
                    }
                    warn("stopped — press ctrl-c again to quit")
                } else if streaming, let chatFilename {
                    try? conn.send(.request(CLIRequest(
                        id: UUID().uuidString,
                        method: CLIRequest.methodChatStop,
                        params: CLIRequestParams(message: "", chat: chatFilename)
                    )))
                    warn("stopping after the current iteration — press ctrl-c again to quit")
                } else {
                    warn("press ctrl-c again to quit")
                    showInputPrompt()
                }
            case .input(let bytes):
                inputBuffer.append(bytes)
                if keyMode {
                    while !inputBuffer.isEmpty {
                        handleKey(inputBuffer.removeFirst())
                    }
                } else {
                    while let nl = inputBuffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: inputBuffer[..<nl], as: UTF8.self)
                        inputBuffer.removeSubrange(...nl)
                        handleLine(line)
                    }
                }
            case .inputEOF:
                // EOF (ctrl-D) — end the session.
                if promptVisible { _ = writeStdout("\n") }
                break loop
            case .frame(let frame):
                switch frame {
                case .welcome(_, _, let negotiated):
                    greeted.set(true)
                    guard negotiated >= 2 else {
                        stderr("interactive mode requires a newer version of the running app — restart iCanHazAI and try again.")
                        result = 1
                        break loop
                    }
                    if initialMessage.isEmpty {
                        showInputPrompt()
                    } else {
                        // Echo the start message as if it were typed.
                        _ = writeStdout("< \(initialMessage)\n")
                        sendMessage(initialMessage)
                    }
                case .started(let id, let chat):
                    guard id == requestID else { break }
                    chatFilename = chat
                case .delta(let id, let text):
                    guard id == requestID else { break }
                    guard writeStdout(renderer.delta(text)) else { break loop }
                case .tool(let id, let name, let args, let status):
                    guard id == requestID else { break }
                    if let status {
                        guard writeStdout(renderer.toolResult(name: name, status: status)) else { break loop }
                    } else {
                        renderer.toolStart(name: name, args: args)
                    }
                case .approve(let id, let callID, let name, let args):
                    guard id == requestID else { break }
                    guard writeStdout(renderer.approval(name: name, args: args)) else { break loop }
                    approvalQueue.append(callID)
                    if approvalQueue.count == 1 { showApprovalPrompt() }
                case .notice(let id, let text):
                    guard id == requestID || id == nil else { break }
                    warn(text)
                case .done(let id, let chat, let name):
                    guard id == requestID else { break }
                    streaming = false
                    requestID = nil
                    approvalQueue.removeAll()
                    awaitingDenyReason = false
                    exitKeyMode()
                    _ = writeStdout(renderer.streamEnd())
                    // Announce the chat created by the first message (no
                    // --chat, not temporary) — once, like the one-shot mode.
                    if !announcedChat, opts.chat == nil, !opts.temporary {
                        announcedChat = true
                        info(renderChatCreatedLine(chat: chat, name: name))
                    }
                    showInputPrompt()
                case .error(let id, _, let message):
                    if id != requestID, id != nil {
                        // A failure of an auxiliary request (chat.stop,
                        // tool.approve) — the session is unaffected.
                        warn("request failed: \(message)")
                        break
                    }
                    if promptVisible { _ = writeStdout("\n"); promptVisible = false }
                    streaming = false
                    requestID = nil
                    approvalQueue.removeAll()
                    awaitingDenyReason = false
                    exitKeyMode()
                    _ = writeStdout(renderer.streamEnd())
                    stderr("error: \(message)")
                    showInputPrompt()
                case .hello, .ping, .pong, .request:
                    break // client-side frames / unused by this client
                }
            }
        }
        return result
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

    /// The line-by-line transcript rendering shared by the one-shot and
    /// interactive modes: the first line of each agent message is prefixed
    /// with "> " (continuation lines are not), messages and tool blocks are
    /// separated by one blank line, and tool-call header lines are paired
    /// with their result status lines. Pure rendering — every method returns
    /// the text to write to stdout.
    final class OutputRenderer {
        /// Trailing newlines of everything written so far (capped at 2):
        /// 0 = mid-line, 1 = at a line start, 2 = a blank line was emitted.
        private var trailingNewlines = 2
        /// True while the frames of an agent iteration's tool calls are the
        /// last thing printed — the next agent text starts a new message.
        private var toolBlockOpen = false
        /// The next non-empty delta line opens an agent message and gets the
        /// "> " prefix.
        private var prefixPending = true
        /// Start lines of tool calls whose results haven't landed yet. The
        /// header is printed together with the result, not at call time, so
        /// a batch of parallel calls doesn't pile all headers above all
        /// results.
        private var pendingToolCalls = PendingToolCalls()
        /// Names of tool calls whose header line was already printed by an
        /// approval prompt — their results print only the status line.
        private var approvedToolCalls: [String] = []

        var atLineStart: Bool { trailingNewlines > 0 }

        /// An agent text chunk. The first non-empty line of a message gets
        /// the "> " prefix; continuation lines pass through unprefixed.
        func delta(_ text: String) -> String {
            // Stray pending headers belong to the previous block — flush
            // them before the new text.
            var out = flushPending()
            if toolBlockOpen {
                // A delta after tool frames opens a new agent message.
                out += blockSeparator()
                toolBlockOpen = false
                prefixPending = true
            }
            var rest = Substring(text)
            while prefixPending, !rest.isEmpty {
                if rest.first == "\n" {
                    out += "\n"
                    rest = rest.dropFirst()
                } else {
                    out += "> "
                    prefixPending = false
                }
            }
            out += rest
            return track(out)
        }

        /// A tool call began execution. Prints nothing — the header is
        /// deferred until the result lands (or an approval prompt needs it).
        func toolStart(name: String, args: String?) {
            pendingToolCalls.add(name: name, args: args)
        }

        /// A tool call produced its final result: the deferred header line
        /// followed by the status line.
        func toolResult(name: String, status: CLIToolStatus) -> String {
            var out = toolBlockSeparator()
            if let idx = approvedToolCalls.firstIndex(of: name) {
                // The header was already printed by the approval prompt.
                approvedToolCalls.remove(at: idx)
                out += CLIClient.renderToolFrame(name: name, args: nil, status: status)
            } else {
                let header = pendingToolCalls.pop(forResultName: name) ?? (name, nil)
                out += CLIClient.renderToolFrame(name: header.name, args: header.args, status: nil)
                out += CLIClient.renderToolFrame(name: name, args: nil, status: status)
            }
            return track(out)
        }

        /// A tool call needs the user's confirmation (interactive mode): the
        /// header line is printed now so the prompt has context; the result
        /// then prints only the status line.
        func approval(name: String, args: String?) -> String {
            var out = toolBlockSeparator()
            let header = pendingToolCalls.pop(forResultName: name) ?? (name, args)
            out += CLIClient.renderToolFrame(name: header.name, args: header.args, status: nil)
            approvedToolCalls.append(name)
            return track(out)
        }

        /// The stream settled: stray headers, then the blank line closing
        /// the final agent message / tool block. The next message
        /// (interactive mode) starts a fresh prefixed segment.
        func streamEnd() -> String {
            var out = flushPending()
            out += blockSeparator()
            toolBlockOpen = false
            prefixPending = true
            return track(out)
        }

        /// Interactive mode: a user message was just entered at the "< "
        /// prompt (the terminal echoed it plus a newline the renderer never
        /// saw) — separate it from the reply with a blank line.
        func userMessageSent() -> String {
            trailingNewlines = 1
            toolBlockOpen = false
            prefixPending = true
            return track(blockSeparator())
        }

        /// The spacing before a new block: terminates a mid-line chunk and
        /// separates blocks with exactly one blank line.
        private func blockSeparator() -> String {
            switch trailingNewlines {
            case 0: return "\n\n"
            case 1: return "\n"
            default: return ""
            }
        }

        /// The spacing before a tool frame: a blank line when the frame opens
        /// a block (after agent text), nothing between frames of one block.
        private func toolBlockSeparator() -> String {
            if toolBlockOpen {
                return trailingNewlines == 0 ? "\n" : ""
            }
            toolBlockOpen = true
            return blockSeparator()
        }

        /// Renders any pending start lines that never got a result (the
        /// stream moved on without them).
        private func flushPending() -> String {
            guard !pendingToolCalls.isEmpty else { return "" }
            var out = toolBlockSeparator()
            for header in pendingToolCalls.drain() {
                out += CLIClient.renderToolFrame(name: header.name, args: header.args, status: nil)
            }
            return out
        }

        /// Updates the trailing-newline count for returned output.
        private func track(_ out: String) -> String {
            var n = 0
            for ch in out.reversed() {
                guard ch == "\n" else { break }
                n += 1
            }
            if n == out.count { // only newlines (or empty) — they accumulate
                trailingNewlines = min(2, trailingNewlines + n)
            } else {
                trailingNewlines = min(2, n)
            }
            return out
        }
    }

    /// Buffers tool-call start lines until their results arrive. Result
    /// frames carry only the tool name (no args), so pairing matches on the
    /// name, falling back to the oldest pending header.
    struct PendingToolCalls {
        private(set) var headers: [(name: String, args: String?)] = []

        var isEmpty: Bool { headers.isEmpty }

        mutating func add(name: String, args: String?) {
            headers.append((name, args))
        }

        /// Pops the header for a finished call: the first pending one with
        /// the same name, else the oldest.
        mutating func pop(forResultName name: String) -> (name: String, args: String?)? {
            guard let idx = headers.firstIndex(where: { $0.name == name })
                ?? (headers.isEmpty ? nil : headers.startIndex) else { return nil }
            return headers.remove(at: idx)
        }

        /// Returns all pending headers (results that never came) and clears
        /// the buffer.
        mutating func drain() -> [(name: String, args: String?)] {
            defer { headers.removeAll() }
            return headers
        }
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

    /// The "Chat: <file> (<name>)" line printed when the invocation created
    /// a persistent chat. `chat` is the chat filename, shown without the
    /// ".json" extension.
    static func renderChatCreatedLine(chat: String, name: String?) -> String {
        let file = (chat as NSString).deletingPathExtension
        return "Chat: \(file) (\(name ?? "New chat"))"
    }

    /// Ancillary meta output on stderr (dim when the terminal supports it).
    private static func info(_ message: String) {
        stderr(styled(message, "2", enabled: stderrColor))
    }

    private static func printUsage(toStderr: Bool) {
        let usage = """
        Usage: iCanHazAI [options] <message…>
               <command> | iCanHazAI [options]
               iCanHazAI --interactive [options] [message…]

        Sends a message and streams the reply to stdout. Creates a new chat
        (default role and connection) unless --chat is given. Chats created
        here are regular chats, visible and continuable in the GUI — unless
        --temporary is used, in which case the chat only exists while the
        CLI is running.

        Options:
          -f, --chat <name>       Continue an existing chat
          -r, --role <name>       Role for the new chat
                                  (default: your default role)
          -c, --connection <id>   Connection for the new chat, "provider/name"
                                  (default: your default connection)
          -w, --workdir <path>    Working directory for workdir-capable roles
                                  (default: the current directory)
          -y, --allow-all         Auto-approve all tool calls (without it, calls
                                  that need confirmation are skipped; interactive
                                  mode asks instead)
          -t, --temporary         Use a temporary chat instead of a permanent one
          -i, --interactive       Interactive session: the message is optional,
                                  follow-up messages are entered at the "< "
                                  prompt, ^C stops after the current iteration,
                                  ^C again quits
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
