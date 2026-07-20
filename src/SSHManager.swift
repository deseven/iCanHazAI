// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CryptoKit
import ProcessExit

// MARK: - SSH workdir spec

/// Parses the `ssh::` working-directory scheme. Format: `ssh::host/path` —
/// `host` is anything `ssh` accepts (a Host alias from ~/.ssh/config or
/// `user@host`), and `path` is an absolute remote path. A bare `ssh::host`
/// (no path) means the remote home directory.
enum SSHSpec {
    static let prefix = "ssh::"

    struct ParseFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func isSSH(_ s: String) -> Bool { s.hasPrefix(prefix) }

    /// Parses a full workdir string. On failure returns a user-facing reason.
    static func parse(_ spec: String) -> Result<(host: String, path: String?), ParseFailure> {
        guard spec.hasPrefix(prefix) else {
            return .failure(ParseFailure("missing \"\(prefix)\" prefix"))
        }
        let rest = String(spec.dropFirst(prefix.count))
        let host: String
        let path: String?
        if let slash = rest.firstIndex(of: "/") {
            host = String(rest[rest.startIndex..<slash])
            let p = String(rest[slash...]) // includes the leading "/"
            path = p == "/" ? "/" : p
        } else {
            host = rest
            path = nil
        }
        if host.isEmpty {
            return .failure(ParseFailure("missing host (expected \(prefix)host/absolute/path)"))
        }
        if host.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\0" }) {
            return .failure(ParseFailure("host must not contain whitespace or quotes"))
        }
        if let path, path.contains("\0") {
            return .failure(ParseFailure("path must not contain null bytes"))
        }
        return .success((host, path))
    }
}

/// A live SSH target for tool execution: the ssh destination plus the chat
/// identity used to name the per-chat control socket.
struct SSHContext: Sendable, Hashable {
    let host: String
    let chatID: String
}

// MARK: - SSHManager

/// Owns ssh ControlMaster connections for `ssh::` working directories and
/// runs remote commands over them.
///
/// One master connection per (chat, host), established lazily on the first
/// tool call that needs it: `ssh -M -S <sock> -fN -o ControlPersist=120 ...`.
/// The master authenticates once and backgrounds itself; `ControlPersist=120`
/// makes ssh terminate it after 120s idle, so no app-side reaper is needed.
/// Before each exec the socket is probed with `ssh -O check`; a dead socket is
/// removed and re-established (up to 3 attempts, each bounded by
/// `ConnectTimeout=10`).
///
/// Remote commands are never passed as `ssh host "cmd"` argv — OpenSSH joins
/// argv client-side and the remote shell re-parses it, giving two quoting
/// layers. Instead we spawn `ssh -T -S sock host` with no command and pipe a
/// script into stdin (like `bash -s`), leaving a single shell-syntax layer we
/// fully control.
final class SSHManager: @unchecked Sendable {

    static let shared = SSHManager(
        cacheDir: EnvironmentManager.shared.rootURL
            .appendingPathComponent(".cache", isDirectory: true).path
    )

    let cacheDir: String

    init(cacheDir: String) {
        self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        // Writing to a pipe whose reader vanished (e.g. a timed-out ssh) must
        // deliver EPIPE, not kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Types

    enum Failure: Sendable {
        case hardTimeout(TimeInterval)
        case idleTimeout(TimeInterval)
    }

    struct RunResult: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        let failure: Failure?

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    // MARK: - Socket path

    /// Unix socket paths are limited to 104 bytes on macOS — and ssh first
    /// creates the control socket under a temporary name with a random
    /// 16-char suffix (`<path>.XXXXXXXXXXXXXXXX`) before renaming it into
    /// place, so the visible path must leave headroom for that. The chat/host
    /// pair is compressed (chat-id prefix + sanitized host), falling back to
    /// a hash, and finally to /tmp when the cache dir itself is too deep.
    private static let socketPathBudget = 104 - 17

    func socketPath(for ctx: SSHContext) -> String {
        let idPart = String(ctx.chatID.replacingOccurrences(of: "-", with: "").prefix(8))
        let hostPart = String(ctx.host.map { ch in
            ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "@" || ch == "-" ? ch : "_"
        })
        let readable = (cacheDir as NSString).appendingPathComponent("ssh-\(idPart)-\(hostPart).sock")
        if readable.utf8.count <= Self.socketPathBudget { return readable }

        let digest = SHA256.hash(data: Data("\(ctx.chatID)|\(ctx.host)".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let hashed = (cacheDir as NSString).appendingPathComponent("ssh-\(digest).sock")
        if hashed.utf8.count <= Self.socketPathBudget { return hashed }

        return "/tmp/ichai-ssh-\(digest).sock"
    }

    // MARK: - Exec

    /// Ensures the control connection is up, then runs
    /// `ssh -T -C -S sock host 'exec $SHELL -l -s'` piping `stdin` to the
    /// remote shell. `hardTimeout` kills the ssh process after N seconds
    /// regardless of activity; `idleTimeout` kills it after N seconds without
    /// any stdout/stderr output.
    ///
    /// The remote command is a fixed literal (no user data, so the client-side
    /// argv join is harmless): it replaces itself with the user's default
    /// login shell reading the script from stdin. Passing *no* command would
    /// make sshd run a login session that prints the MOTD/banner into our
    /// data channel — any explicit command suppresses it.
    func exec(_ ctx: SSHContext, stdin: Data, hardTimeout: TimeInterval?, idleTimeout: TimeInterval?) async throws -> RunResult {
        try await ensureConnection(ctx)
        return try await runSSH(
            arguments: ["-T", "-C", "-S", socketPath(for: ctx), ctx.host, "exec $SHELL -l -s"],
            stdin: stdin, hardTimeout: hardTimeout, idleTimeout: idleTimeout
        )
    }

    // MARK: - Connection lifecycle

    private let lock = NSLock()
    private var pending: [String: Task<Void, Error>] = [:]

    private func ensureConnection(_ ctx: SSHContext) async throws {
        let sock = socketPath(for: ctx)
        if await isAlive(socket: sock, host: ctx.host) { return }
        // Serialize establishment per socket so concurrent tool calls in one
        // chat don't race to create the master.
        let task: Task<Void, Error> = lock.withLock {
            if let t = pending[sock] { return t }
            let t = Task { [self] in try await establish(socket: sock, host: ctx.host) }
            pending[sock] = t
            return t
        }
        defer { lock.withLock { _ = pending.removeValue(forKey: sock) } }
        try await task.value
    }

    private func isAlive(socket: String, host: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: socket) else { return false }
        do {
            let r = try await runSSH(
                arguments: ["-O", "check", "-S", socket, host],
                stdin: nil, hardTimeout: 5, idleTimeout: nil
            )
            if r.exitCode == 0 { return true }
            debugLog("SSH", "control check failed for \(host): \(r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch {
            debugLog("SSH", "control check failed for \(host): \(error.localizedDescription)")
        }
        return false
    }

    private func establish(socket: String, host: String) async throws {
        var lastError = ""
        var lastExitCode: Int32 = -1
        for attempt in 1...3 {
            try? FileManager.default.removeItem(atPath: socket)
            // -fN backgrounds the master after auth; BatchMode guarantees no
            // hidden interactive prompt can hang us (auth must be
            // pre-configured by the user). ControlPersist=120 closes the
            // master 120s after the last session — our idle timeout.
            let r = try await runSSH(
                arguments: [
                    "-M", "-S", socket, "-fN",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                    "-o", "ControlPersist=120",
                    host,
                ],
                stdin: nil, hardTimeout: 15, idleTimeout: nil
            )
            if r.exitCode == 0 {
                debugLog("SSH", "established master for \(host) (socket \(socket))")
                return
            }
            lastError = r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).joined(separator: " | ")
            lastExitCode = r.exitCode
            debugLog("SSH", "connect attempt \(attempt)/3 to \(host) failed: \(lastError)")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw BuiltinToolError("SSH connection to '\(host)' failed after 3 attempts (last exit code \(lastExitCode))"
            + (lastError.isEmpty ? "." : ": \(lastError)"))
    }

    // MARK: - Process runner

    private final class IOBox: @unchecked Sendable {
        private let l = NSLock()
        private var out = Data()
        private var err = Data()
        private var activity = Date()

        var lastActivity: Date { l.withLock { activity } }
        var stdout: Data { l.withLock { out } }
        var stderr: Data { l.withLock { err } }

        func appendStdout(_ d: Data) { l.withLock { out.append(d); activity = Date() } }
        func appendStderr(_ d: Data) { l.withLock { err.append(d); activity = Date() } }
    }

    private func runSSH(arguments: [String], stdin: Data?, hardTimeout: TimeInterval?, idleTimeout: TimeInterval?) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            stdinPipe = p
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        let box = IOBox()
        try process.run()

        // Drain stdout/stderr concurrently; chunk arrival doubles as the
        // activity signal for idle timeouts.
        let outTask = Task.detached {
            while let d = try? stdoutPipe.fileHandleForReading.read(upToCount: 65536), !d.isEmpty {
                box.appendStdout(d)
            }
        }
        let errTask = Task.detached {
            while let d = try? stderrPipe.fileHandleForReading.read(upToCount: 65536), !d.isEmpty {
                box.appendStderr(d)
            }
        }

        // stdin is written from a side task so a slow/blocked remote reader
        // never deadlocks the watchdog (pipe buffer backpressure).
        if let stdin, let stdinPipe {
            Task.detached {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        var failure: Failure? = nil
        let start = Date()
        while process.isRunning {
            if let hardTimeout, Date().timeIntervalSince(start) >= hardTimeout {
                failure = .hardTimeout(hardTimeout)
                process.terminate()
                break
            }
            if let idleTimeout, Date().timeIntervalSince(box.lastActivity) >= idleTimeout {
                failure = .idleTimeout(idleTimeout)
                process.terminate()
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await awaitProcessExit(process)
        if failure != nil {
            // Killed mid-session: the pipe far ends can stay open until the
            // remote side notices (no pty → no SIGHUP; the remote command
            // may run to completion), so awaiting the drain tasks would block
            // for the remote command's full duration. Give them a brief
            // grace to flush what already arrived, then move on — they
            // finish (and their threads are reclaimed) whenever the session
            // fully dies.
            try? await Task.sleep(nanoseconds: 200_000_000)
        } else {
            _ = await outTask.value
            _ = await errTask.value
        }

        return RunResult(
            exitCode: failure != nil ? -1 : process.terminationStatus,
            stdout: box.stdout,
            stderr: box.stderr,
            failure: failure
        )
    }
}
