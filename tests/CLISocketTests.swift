import Testing
import Foundation
@testable import iCanHazAI

/// Tests for the unix socket plumbing ([`UnixSocket`](src/CLI/UnixSocket.swift))
/// and the control-socket server ([`CLIServer`](src/CLI/CLIServer.swift)) using
/// real loopback sockets in a temp directory.
extension AllAppTests {

    @Suite("CLI socket")
    struct CLISocketTests {

        /// Socket paths must fit `sockaddr_un.sun_path` (104 bytes on Darwin),
        /// which the deep NSTemporaryDirectory() paths don't — use /tmp with a
        /// short unique name instead.
        private func makeTempSocketPath() throws -> (dir: URL, path: String) {
            let path = "/tmp/ichai-test-\(UUID().uuidString.prefix(8)).sock"
            return (URL(fileURLWithPath: path), path)
        }

        private func cleanup(_ dir: URL) {
            try? FileManager.default.removeItem(at: dir)
        }

        @Test("a stale socket file is probed and removed; a live one is kept")
        func staleSocketHandling() throws {
            let (dir, path) = try makeTempSocketPath()
            defer { cleanup(dir) }

            // Stale: the file exists but the listener is gone.
            let fd = try UnixSocket.listen(path: path)
            #expect(UnixSocket.probe(path: path))
            close(fd) // file remains, nobody listening → stale
            #expect(!UnixSocket.probe(path: path))
            CLIServer.removeStaleSocketIfNeeded(at: path)
            #expect(!FileManager.default.fileExists(atPath: path))

            // Live: a bound listener must survive the cleanup.
            let liveFD = try UnixSocket.listen(path: path)
            CLIServer.removeStaleSocketIfNeeded(at: path)
            #expect(FileManager.default.fileExists(atPath: path))
            close(liveFD)
        }

        @Test("handshake, one-shot streaming, and clean shutdown over a real socket")
        func loopbackOneShot() async throws {
            let (dir, path) = try makeTempSocketPath()
            defer { cleanup(dir) }

            let server = CLIServer(socketPath: path) { request in
                #expect(request.method == CLIRequest.methodChatSend)
                #expect(request.params.message == "hi")
                let (stream, continuation) = AsyncStream<OneShotEvent>.makeStream()
                Task {
                    continuation.yield(.delta("Hello"))
                    continuation.yield(.delta(", "))
                    continuation.yield(.delta("world"))
                    continuation.yield(.finished(error: nil))
                    continuation.finish()
                }
                return .started(filename: "cli-chat.json", events: stream)
            }
            server.start()
            defer { server.stop() }
            #expect(FileManager.default.fileExists(atPath: path))

            let fd = try UnixSocket.connect(path: path)
            let conn = CLIConnection(fd: fd)
            defer { conn.close() }
            try conn.send(.hello(pid: getpid(), client: "test", protocolVersion: CLIProtocol.version))

            var frames: [CLIFrame] = []
            var requestSent = false
            for await event in conn.events {
                guard case .frame(let frame) = event else { continue }
                frames.append(frame)
                if case .welcome = frame, !requestSent {
                    requestSent = true
                    try conn.send(.request(CLIRequest(
                        id: "req-1",
                        method: CLIRequest.methodChatSend,
                        params: CLIRequestParams(message: "hi")
                    )))
                }
                if case .done = frame { break }
            }

            // welcome → started → delta×3 → done
            guard frames.count == 6 else {
                Issue.record("expected 6 frames, got \(frames.count): \(frames)")
                return
            }
            guard case .welcome(let session, _, let negotiated) = frames[0] else {
                Issue.record("frame 0 is not welcome: \(frames[0])")
                return
            }
            #expect(!session.isEmpty)
            #expect(negotiated == CLIProtocol.version)
            #expect(frames[1] == .started(id: "req-1", chat: "cli-chat.json"))
            #expect(frames[2] == .delta(id: "req-1", text: "Hello"))
            #expect(frames[3] == .delta(id: "req-1", text: ", "))
            #expect(frames[4] == .delta(id: "req-1", text: "world"))
            #expect(frames[5] == .done(id: "req-1", chat: "cli-chat.json"))

            // The server saw our real PID via LOCAL_PEERPID.
            // (verified implicitly: a mismatch only logs, the session proceeds)

            conn.close()
            server.stop()
            #expect(!FileManager.default.fileExists(atPath: path))
        }

        @Test("stream errors are forwarded as error frames")
        func loopbackStreamError() async throws {
            let (dir, path) = try makeTempSocketPath()
            defer { cleanup(dir) }

            let server = CLIServer(socketPath: path) { _ in
                let (stream, continuation) = AsyncStream<OneShotEvent>.makeStream()
                Task {
                    continuation.yield(.delta("partial"))
                    continuation.yield(.finished(error: "provider blew up"))
                    continuation.finish()
                }
                return .started(filename: "cli-chat.json", events: stream)
            }
            server.start()
            defer { server.stop() }

            let fd = try UnixSocket.connect(path: path)
            let conn = CLIConnection(fd: fd)
            defer { conn.close() }
            try conn.send(.hello(pid: getpid(), client: "test", protocolVersion: CLIProtocol.version))

            var frames: [CLIFrame] = []
            var requestSent = false
            for await event in conn.events {
                guard case .frame(let frame) = event else { continue }
                frames.append(frame)
                if case .welcome = frame, !requestSent {
                    requestSent = true
                    try conn.send(.request(CLIRequest(id: "r", method: CLIRequest.methodChatSend,
                                                    params: CLIRequestParams(message: "hi"))))
                }
                if case .error = frame { break }
            }

            #expect(frames.last == .error(id: "r", code: "stream_error", message: "provider blew up"))
            #expect(frames.contains(.delta(id: "r", text: "partial")))
        }

        @Test("unknown methods and malformed frames get error replies")
        func protocolErrors() async throws {
            let (dir, path) = try makeTempSocketPath()
            defer { cleanup(dir) }

            let server = CLIServer(socketPath: path) { _ in .failed("should not be called") }
            server.start()
            defer { server.stop() }

            let fd = try UnixSocket.connect(path: path)
            let conn = CLIConnection(fd: fd)
            defer { conn.close() }

            // Garbage line, then an unknown method, then a valid ping.
            try UnixSocket.writeAll(fd: fd, data: Data("this is not json\n".utf8))
            try conn.send(.request(CLIRequest(id: "x", method: "chat.explode",
                                              params: CLIRequestParams(message: "hi"))))
            try conn.send(.ping)

            var frames: [CLIFrame] = []
            for await event in conn.events {
                guard case .frame(let frame) = event else { continue }
                frames.append(frame)
                if case .pong = frame { break }
            }

            #expect(frames.count == 3)
            guard case .error(let eid1, let code1, _) = frames[0] else {
                Issue.record("frame 0 is not an error: \(frames[0])")
                return
            }
            #expect(eid1 == nil)
            #expect(code1 == "bad_frame")
            #expect(frames[1] == .error(id: "x", code: "unknown_method", message: "unknown method \"chat.explode\""))
            guard case .pong = frames[2] else {
                Issue.record("frame 2 is not a pong: \(frames[2])")
                return
            }
        }
    }
}
