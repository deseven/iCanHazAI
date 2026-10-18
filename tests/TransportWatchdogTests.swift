// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network
import Testing

@testable import iCanHazAI

// Live watchdog tests against a local stub HTTP server. Each test controls
// the server's send timing to reproduce a specific failure mode: silent
// server, keep-alive-only stream, endless dribble, mid-stream stall.
extension AllAppTests {
    @Suite("Transport watchdog")
    struct TransportWatchdogTests {

        // MARK: - Fixtures

        /// A minimal local HTTP server. Accepts one connection per request,
        /// invokes `onRequest` once the request headers arrived, and leaves
        /// the socket open so handlers control send timing.
        final class StubHTTPServer: @unchecked Sendable {
            private let listener: NWListener
            private let queue = DispatchQueue(label: "stub.http.server")
            private let lock = NSLock()
            private var connections: [NWConnection] = []
            private var _requestCount = 0

            /// Called on the server queue when a connection's request
            /// headers arrived. The connection stays open until cancelled.
            var onRequest: (@Sendable (NWConnection) -> Void)?
            private(set) var port: UInt16 = 0

            var requestCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return _requestCount
            }

            init() throws {
                listener = try NWListener(using: .tcp, on: .any)
            }

            func start() async throws {
                listener.newConnectionHandler = { [weak self] conn in
                    guard let self else { return }
                    self.lock.lock()
                    self.connections.append(conn)
                    self._requestCount += 1
                    self.lock.unlock()
                    conn.start(queue: self.queue)
                    self.awaitRequest(conn, buffer: Data())
                }
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let box = ResumeOnce(cont)
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            self?.port = self?.listener.port?.rawValue ?? 0
                            box.resume()
                        case .failed(let error):
                            box.resume(throwing: error)
                        default:
                            break
                        }
                    }
                    listener.start(queue: queue)
                }
            }

            func stop() {
                listener.cancel()
                lock.lock()
                for conn in connections { conn.cancel() }
                connections.removeAll()
                lock.unlock()
            }

            private func awaitRequest(_ conn: NWConnection, buffer: Data) {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
                    guard let self else { return }
                    var buf = buffer
                    if let data { buf.append(data) }
                    if buf.range(of: Data("\r\n\r\n".utf8)) != nil {
                        self.onRequest?(conn)
                    } else if error == nil {
                        self.awaitRequest(conn, buffer: buf)
                    }
                }
            }

            // MARK: Send helpers

            func send(_ text: String, to conn: NWConnection) {
                conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
            }

            func sendResponseHeaders(to conn: NWConnection) {
                send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n", to: conn)
            }

            func sendContentChunk(_ text: String, to conn: NWConnection) {
                let payload = "{\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}"
                send("data: \(payload)\n\n", to: conn)
            }

            func sendDone(to conn: NWConnection) {
                send("data: [DONE]\n\n", to: conn)
            }

            private final class ResumeOnce: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                private let cont: CheckedContinuation<Void, Error>
                init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }
                func resume(throwing: Error? = nil) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    if let throwing { cont.resume(throwing: throwing) } else { cont.resume() }
                }
            }
        }

        private struct TestTimeout: Error, CustomStringConvertible {
            let description = "test timed out — the watchdog did not fire"
        }

        /// Bounds a transport call so a broken watchdog fails the test
        /// instead of hanging it.
        private func bounded<T: Sendable>(
            _ seconds: Double,
            _ body: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await body() }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw TestTimeout()
                }
                guard let value = try await group.next() else { throw TestTimeout() }
                group.cancelAll()
                return value
            }
        }

        private func makeModel(
            port: UInt16, read: Double?, progress: Double?, transport: Double?, retries: Int = 0
        ) -> ResolvedModel {
            ResolvedModel(
                provider: .openai, modelID: "stub-model", apiKey: "", baseUrl: "http://127.0.0.1:\(port)",
                readTimeout: read, progressTimeout: progress, transportTimeout: transport, numRetries: retries
            )
        }

        private func runStream(_ model: ResolvedModel) async throws -> ChatService.StreamResult {
            try await LLMTransport.stream(
                model: model,
                messages: [ChatMessage(role: .user, content: "hi")],
                chatFilename: "watchdog-test.json",
                tools: nil,
                onChunk: { _ in }
            )
        }

        /// Asserts the call throws a specific `LLMTransportError` case.
        private func expectTimeout<T: Sendable>(
            _ expected: @Sendable (LLMTransportError) -> Bool,
            _ label: String,
            _ body: @escaping @Sendable () async throws -> T
        ) async throws {
            do {
                _ = try await bounded(15, body)
                Issue.record("Expected \(label) but the request completed")
            } catch let error as LLMTransportError {
                if !expected(error) {
                    Issue.record("Expected \(label), got \(error)")
                }
            } catch {
                Issue.record("Expected \(label), got \(error)")
            }
        }

        // MARK: - Read timeout layer

        @Test("readTimeout fires when the server never responds")
        func readTimeoutNeverResponds() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { _ in }

            let conn = makeModel(port: server.port, read: 1, progress: 0, transport: 0)
            try await expectTimeout(
                {
                    if case .readTimeout = $0 { return true }
                    return false
                }, "readTimeout"
            ) {
                try await runStream(conn)
            }
        }

        @Test("readTimeout fires when the stream goes silent after headers")
        func readTimeoutAfterHeaders() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
            }

            let conn = makeModel(port: server.port, read: 1, progress: 0, transport: 0)
            try await expectTimeout(
                {
                    if case .readTimeout = $0 { return true }
                    return false
                }, "readTimeout"
            ) {
                try await runStream(conn)
            }
        }

        // MARK: - Progress timeout layer

        @Test("progressTimeout fires on a keep-alive-only stream")
        func progressTimeoutPingOnly() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                Task {
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(200))
                        server.send(": keep-alive\n\n", to: conn)
                    }
                }
            }

            let conn = makeModel(port: server.port, read: 0, progress: 1, transport: 0)
            try await expectTimeout(
                {
                    if case .progressTimeout = $0 { return true }
                    return false
                }, "progressTimeout"
            ) {
                try await runStream(conn)
            }
        }

        // MARK: - Watchdog re-arming

        @Test("a healthy stream outlives the read timeout (watchdog re-arms)")
        func healthyStreamSurvives() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                Task {
                    for _ in 0..<12 {
                        try? await Task.sleep(for: .milliseconds(150))
                        server.sendContentChunk("x", to: conn)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    server.sendDone(to: conn)
                }
            }

            // Total stream (~2 s) exceeds readTimeout (1 s): the watchdog
            // must re-arm on every received chunk instead of firing.
            let conn = makeModel(port: server.port, read: 1, progress: 0, transport: 0)
            let result = try await bounded(15) { try await runStream(conn) }
            #expect(result.content == String(repeating: "x", count: 12))
        }

        // MARK: - Transport timeout layer

        @Test("transportTimeout caps an endlessly dribbling stream")
        func transportTimeoutCapsDribble() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                Task {
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(250))
                        server.sendContentChunk("x", to: conn)
                    }
                }
            }

            // Chunks every 250 ms keep read/progress fresh; only the total
            // budget can stop this stream.
            let conn = makeModel(port: server.port, read: 0, progress: 0, transport: 2)
            try await expectTimeout(
                {
                    if case .transportTimeout = $0 { return true }
                    return false
                }, "transportTimeout"
            ) {
                try await runStream(conn)
            }
        }

        // MARK: - Retry interaction

        @Test("a silent first attempt is retried and succeeds")
        func retryAfterSilentAttempt() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                if server.requestCount == 1 {
                    // First attempt: headers then stall.
                } else {
                    server.sendContentChunk("ok", to: conn)
                    server.sendDone(to: conn)
                }
            }

            let conn = makeModel(port: server.port, read: 1, progress: 0, transport: 0, retries: 1)
            let result = try await bounded(15) { try await runStream(conn) }
            #expect(result.content == "ok")
            #expect(server.requestCount == 2)
        }

        @Test("no retry once output reached the caller")
        func noRetryAfterOutput() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                server.sendContentChunk("partial", to: conn)
                // Stall after output — a retry would duplicate the text.
            }

            let conn = makeModel(port: server.port, read: 1, progress: 0, transport: 0, retries: 1)
            try await expectTimeout(
                {
                    if case .readTimeout = $0 { return true }
                    return false
                }, "readTimeout"
            ) {
                try await runStream(conn)
            }
            #expect(server.requestCount == 1)
        }

        @Test("transportTimeout is not retried")
        func transportTimeoutNotRetried() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                Task {
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(250))
                        server.sendContentChunk("x", to: conn)
                    }
                }
            }

            // The total budget is final: a retry would burn another full
            // budget on the same pathological request.
            let conn = makeModel(port: server.port, read: 0, progress: 0, transport: 2, retries: 1)
            try await expectTimeout(
                {
                    if case .transportTimeout = $0 { return true }
                    return false
                }, "transportTimeout"
            ) {
                try await runStream(conn)
            }
            #expect(server.requestCount == 1)
        }

        @Test("retries exhausted surface the final error after every attempt")
        func retriesExhausted() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { _ in }

            let conn = makeModel(port: server.port, read: 1, progress: 0, transport: 0, retries: 2)
            try await expectTimeout(
                {
                    if case .readTimeout = $0 { return true }
                    return false
                }, "readTimeout"
            ) {
                try await runStream(conn)
            }
            #expect(server.requestCount == 3)
        }

        // MARK: - Layer independence

        @Test("progressTimeout fires on data-carrying pings that parse to no chunks")
        func progressTimeoutPingData() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                Task {
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(200))
                        // A `data:` event the provider parser yields zero
                        // chunks from — resets read, never progress.
                        server.send("data: {\"type\":\"ping\"}\n\n", to: conn)
                    }
                }
            }

            let conn = makeModel(port: server.port, read: 0, progress: 1, transport: 0)
            try await expectTimeout(
                {
                    if case .progressTimeout = $0 { return true }
                    return false
                }, "progressTimeout"
            ) {
                try await runStream(conn)
            }
        }

        @Test("progressTimeout fires after a mid-stream stall while keep-alives continue")
        func progressTimeoutMidStreamStall() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                server.sendContentChunk("hello", to: conn)
                Task {
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(200))
                        server.send(": keep-alive\n\n", to: conn)
                    }
                }
            }

            // Keep-alives keep the read layer fresh; only the progress layer
            // can catch this stall.
            let conn = makeModel(port: server.port, read: 0, progress: 1, transport: 0)
            try await expectTimeout(
                {
                    if case .progressTimeout = $0 { return true }
                    return false
                }, "progressTimeout"
            ) {
                try await runStream(conn)
            }
        }

        @Test("all layers disabled lets a slow stream complete")
        func allLayersDisabledCompletes() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                Task {
                    for _ in 0..<8 {
                        try? await Task.sleep(for: .milliseconds(200))
                        server.sendContentChunk("x", to: conn)
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    server.sendDone(to: conn)
                }
            }

            // ~1.8 s total — would trip any enabled default layer.
            let conn = makeModel(port: server.port, read: 0, progress: 0, transport: 0)
            let result = try await bounded(15) { try await runStream(conn) }
            #expect(result.content == String(repeating: "x", count: 8))
        }

        // MARK: - Cancellation

        @Test("user cancellation mid-stream propagates as CancellationError")
        func userCancellationPropagates() async throws {
            let server = try StubHTTPServer()
            try await server.start()
            defer { server.stop() }
            server.onRequest = { conn in
                server.sendResponseHeaders(to: conn)
                // Stall forever — the watchdog is disabled, so only the
                // user's Stop can end this request.
            }

            let conn = makeModel(port: server.port, read: 0, progress: 0, transport: 0)
            let task = Task {
                try await runStream(conn)
            }
            try await Task.sleep(for: .milliseconds(300))
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Expected CancellationError but the request completed")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
        }
    }
}
