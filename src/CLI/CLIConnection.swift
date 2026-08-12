// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Inbound wire events for one socket connection.
enum CLIConnectionEvent: Sendable {
    case frame(CLIFrame)
    /// A line that failed to decode as a protocol frame (not JSON, or an
    /// unknown/malformed type). Carries the raw line and the decode error so
    /// the server can report it back to the client.
    case malformed(line: String, error: String)
}

/// One framed protocol connection over a unix socket fd, used symmetrically
/// by the server (accepted sockets) and the CLI client.
///
/// Reading: a dedicated queue runs a blocking read loop, splitting the byte
/// stream into newline-delimited frames and yielding them as `events`. The
/// stream finishes on EOF, read error, or `close()`.
///
/// Writing: `send` encodes a frame and writes it whole, serialized across
/// concurrent callers (multiple in-flight requests can share a connection).
final class CLIConnection: @unchecked Sendable {

    /// A single line longer than this aborts the connection — guards against
    /// a broken peer growing the buffer without bound.
    static let maxLineBytes = 16 * 1024 * 1024

    /// Inbound events. Finishes when the connection ends.
    let events: AsyncStream<CLIConnectionEvent>

    /// The kernel-reported peer PID (accepted server-side sockets; nil when
    /// unavailable, e.g. on the client side).
    let peerPID: pid_t?

    private let lock = NSLock()
    private var fd: Int32 = -1
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        UnixSocket.disableSigpipe(fd)
        self.peerPID = UnixSocket.peerPID(of: fd)

        var cont: AsyncStream<CLIConnectionEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        let continuation = cont!
        // The loop holds `self` until the connection ends; connections are
        // always closed explicitly (by peer EOF, an error, or close()).
        DispatchQueue(label: "wtf.d7.icanhazai.cli.read").async { [self] in
            readLoop(continuation: continuation)
        }
    }

    deinit { close() }

    private var currentFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }

    /// Encodes and writes one frame. Throws when the connection is closed or
    /// the write fails (e.g. EPIPE after the peer went away).
    func send(_ frame: CLIFrame) throws {
        let data = try CLIProtocol.encode(frame)
        let current = currentFD
        guard current >= 0 else { throw UnixSocket.SocketError.notConnected }
        writeLock.lock()
        defer { writeLock.unlock() }
        try UnixSocket.writeAll(fd: current, data: data)
    }

    /// Closes the connection. Idempotent; `shutdown` first so a thread blocked
    /// in `read` wakes up (closing alone doesn't reliably interrupt it).
    func close() {
        lock.lock()
        let current = fd
        fd = -1
        lock.unlock()
        guard current >= 0 else { return }
        shutdown(current, SHUT_RDWR)
        Darwin.close(current)
    }

    private func readLoop(continuation: AsyncStream<CLIConnectionEvent>.Continuation) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let current = currentFD
            guard current >= 0 else { break }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(current, $0.baseAddress, $0.count) }
            if n == 0 { break }  // orderly EOF
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                handleLine(line, continuation: continuation)
            }
            if buffer.count > Self.maxLineBytes { break }
        }
        continuation.finish()
    }

    private func handleLine(_ line: Data, continuation: AsyncStream<CLIConnectionEvent>.Continuation) {
        guard !line.isEmpty else { return }
        do {
            continuation.yield(.frame(try CLIProtocol.decode(line: line)))
        } catch {
            let raw = String(data: line, encoding: .utf8) ?? "<\(line.count) non-UTF8 bytes>"
            continuation.yield(.malformed(line: raw, error: String(describing: error)))
        }
    }
}
