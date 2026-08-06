// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Thin POSIX wrappers for `AF_UNIX` stream sockets. Blocking I/O only — the
/// server runs accept/read loops on dedicated background queues, and the CLI
/// client is a short-lived process where blocking is fine.
enum UnixSocket {

    enum SocketError: Error, Equatable {
        case pathTooLong
        case createFailed(Int32)
        case connectFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case writeFailed(Int32)
        case notConnected
    }

    /// Builds a `sockaddr_un` for the given filesystem path.
    private static func makeAddr(path: String) throws -> sockaddr_un {
        // sun_path is 104 bytes on Darwin including the NUL terminator.
        guard path.utf8.count < 104 else { throw SocketError.pathTooLong }
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withCString { cstr in
                // sockaddr_un() is zero-initialized, so the copy is NUL-terminated.
                strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, raw.count - 1)
            }
        }
        return addr
    }

    /// Creates a stream socket with SIGPIPE suppression on the fd itself, so
    /// writes to a peer that went away fail with EPIPE instead of killing the
    /// process (belt-and-suspenders alongside the global SIG_IGN).
    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }
        disableSigpipe(fd)
        return fd
    }

    static func disableSigpipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to a listening socket at `path`. Throws `connectFailed` with
    /// ENOENT when the path doesn't exist and ECONNREFUSED when the socket
    /// file is stale (nobody listening).
    static func connect(path: String) throws -> Int32 {
        let fd = try makeSocket()
        var addr = try makeAddr(path: path)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError.connectFailed(code)
        }
        return fd
    }

    /// Whether something is listening at `path` right now. Used to tell a
    /// live socket from a stale one without disturbing the listener.
    static func probe(path: String) -> Bool {
        guard let fd = try? connect(path: path) else { return false }
        close(fd)
        return true
    }

    /// Binds and listens at `path`. Fails with `bindFailed(EADDRINUSE)` when
    /// the file already exists — stale-file removal is the caller's job (it
    /// must probe first so a live peer's socket is never unlinked).
    static func listen(path: String, backlog: Int32 = 8) throws -> Int32 {
        let fd = try makeSocket()
        var addr = try makeAddr(path: path)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketError.bindFailed(code)
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.listenFailed(code)
        }
        return fd
    }

    /// Writes the whole buffer, looping over partial writes. Throws
    /// `writeFailed(EPIPE)` when the peer is gone.
    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !raw.isEmpty else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.writeFailed(errno)
                }
                written += n
            }
        }
    }

    /// The kernel-reported PID of the socket's peer (`LOCAL_PEERPID`), or nil
    /// when unavailable. Unlike a PID claimed in a handshake frame, this can't
    /// be spoofed by the client.
    static func peerPID(of fd: Int32) -> pid_t? {
        // Darwin: SOL_LOCAL = 0, LOCAL_PEERPID = 0x002 (sys/un.h).
        let SOL_LOCAL: Int32 = 0
        let LOCAL_PEERPID: Int32 = 0x002
        var pid = pid_t(0)
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0,
              len == socklen_t(MemoryLayout<pid_t>.size) else { return nil }
        return pid
    }
}
