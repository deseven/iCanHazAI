// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The app-side control socket server. Listens on `~/iCanHazAI/app.sock` and
/// serves CLI clients using the [`CLIProtocol`](src/CLI/CLIProtocol.swift)
/// framing. One `accept()` per client gives every CLI process a dedicated
/// connection with its own read loop — clients never block each other.
///
/// Lifecycle: the stale socket from a previous run is removed at app start
/// ([`removeStaleSocketIfNeeded`](src/CLI/CLIServer.swift), after probing so a
/// live peer's file is never unlinked), the server itself is started once all
/// initialization has completed (from the loader's `startupReadyHandler`, the
/// same signal that reveals the main window), and `stop()` on termination
/// closes everything and unlinks the socket file.
final class CLIServer: @unchecked Sendable {

    /// Dispatches a `chat.send` request to the engine. Injectable for tests.
    typealias OneShotHandler = @Sendable (CLIRequest) async -> OneShotStart

    static let shared = CLIServer(socketPath: EnvironmentManager.shared.socketURL.path) { request in
        await ChatEngine.shared.performOneShot(
            message: request.params.message,
            role: request.params.role,
            connection: request.params.connection,
            chatFilename: request.params.chat
        )
    }

    let socketPath: String
    private let oneShotHandler: OneShotHandler

    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clients: [ObjectIdentifier: ClientContext] = [:]

    init(socketPath: String, oneShotHandler: @escaping OneShotHandler) {
        self.socketPath = socketPath
        self.oneShotHandler = oneShotHandler
    }

    // MARK: - Stale socket cleanup

    /// Removes a leftover socket file from a previous run, but only when
    /// nothing is listening on it — a live peer's socket is never unlinked.
    /// Called right on app start, before the engine spins up.
    static func removeStaleSocketIfNeeded(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if UnixSocket.probe(path: path) {
            debugLog("CLI", "⚠️ control socket at \(path) is live — another instance may be running; leaving it")
            return
        }
        unlink(path)
        debugLog("CLI", "removed stale control socket at \(path)")
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        guard listenerFD < 0 else { lock.unlock(); return }
        do {
            listenerFD = try UnixSocket.listen(path: socketPath)
        } catch {
            listenerFD = -1
            lock.unlock()
            debugLog("CLI", "⚠️ failed to create control socket at \(socketPath) — \(error)")
            return
        }
        lock.unlock()
        debugLog("CLI", "control socket listening at \(socketPath)")
        DispatchQueue(label: "wtf.d7.icanhazai.cli.accept").async { [weak self] in
            self?.acceptLoop()
        }
    }

    /// Closes the listener and every client connection, and unlinks the
    /// socket file. Safe to call multiple times.
    func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        let all = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        for ctx in all {
            ctx.cancelRequests()
            ctx.connection.close()
        }
        unlink(socketPath)
        debugLog("CLI", "control socket closed")
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenerFD
            lock.unlock()
            guard fd >= 0 else { return }
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return // listener closed by stop()
            }
            handleClient(fd: clientFD)
        }
    }

    // MARK: - Per-client handling

    /// Per-connection state: the framed transport, its session id, and the
    /// in-flight request tasks (cancelled when the connection drops).
    private final class ClientContext: @unchecked Sendable {
        let connection: CLIConnection
        var sessionID: String?
        private let lock = NSLock()
        private var tasks: [String: Task<Void, Never>] = [:]

        init(connection: CLIConnection) {
            self.connection = connection
        }

        func addTask(_ id: String, _ task: Task<Void, Never>) {
            lock.lock()
            tasks[id] = task
            lock.unlock()
        }

        func removeTask(_ id: String) {
            lock.lock()
            tasks[id] = nil
            lock.unlock()
        }

        func cancelRequests() {
            lock.lock()
            let all = Array(tasks.values)
            tasks.removeAll()
            lock.unlock()
            for task in all { task.cancel() }
        }
    }

    private func handleClient(fd: Int32) {
        let conn = CLIConnection(fd: fd)
        let ctx = ClientContext(connection: conn)
        lock.lock()
        clients[ObjectIdentifier(ctx)] = ctx
        lock.unlock()
        debugLog("CLI", "client connected (pid \(conn.peerPID.map(String.init) ?? "?"))")
        Task { [weak self] in
            guard let self else { return }
            for await event in conn.events {
                self.handleEvent(event, ctx: ctx)
            }
            ctx.cancelRequests()
            ctx.connection.close()
            self.removeClient(ctx)
            debugLog("CLI", "client disconnected (pid \(conn.peerPID.map(String.init) ?? "?"))")
        }
    }

    /// Locking is confined to sync helpers — `NSLock` can't be used directly
    /// from async contexts.
    private func removeClient(_ ctx: ClientContext) {
        lock.withLock { clients[ObjectIdentifier(ctx)] = nil }
    }

    private func handleEvent(_ event: CLIConnectionEvent, ctx: ClientContext) {
        switch event {
        case .malformed(_, let error):
            debugLog("CLI", "malformed frame from client — \(error)")
            send(.error(id: nil, code: "bad_frame", message: "malformed frame: \(error)"), to: ctx)
        case .frame(let frame):
            switch frame {
            case .hello(let pid, let client, let protocolVersion):
                if let realPID = ctx.connection.peerPID, realPID != pid {
                    debugLog("CLI", "⚠️ client claimed pid \(pid) but kernel says \(realPID)")
                }
                let session = UUID().uuidString
                ctx.sessionID = session
                debugLog("CLI", "hello from \(client) (pid \(pid), protocol v\(protocolVersion)) — session \(session)")
                send(.welcome(session: session, appVersion: Self.appVersion,
                              protocolVersion: min(protocolVersion, CLIProtocol.version)), to: ctx)
            case .ping:
                send(.pong(appVersion: Self.appVersion, pid: getpid()), to: ctx)
            case .request(let request):
                handleRequest(request, ctx: ctx)
            case .welcome, .pong, .started, .delta, .done, .error:
                send(.error(id: nil, code: "unexpected_frame", message: "server-side frame received from a client"), to: ctx)
            }
        }
    }

    private func handleRequest(_ request: CLIRequest, ctx: ClientContext) {
        guard request.method == CLIRequest.methodChatSend else {
            send(.error(id: request.id, code: "unknown_method", message: "unknown method \"\(request.method)\""), to: ctx)
            return
        }
        guard !request.params.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            send(.error(id: request.id, code: "bad_params", message: "message is empty"), to: ctx)
            return
        }
        let requestID = request.id
        let task = Task { [weak self, weak ctx] in
            defer { ctx?.removeTask(requestID) }
            guard let self, let ctx else { return }
            let start = await self.oneShotHandler(request)
            switch start {
            case .failed(let message):
                try? ctx.connection.send(.error(id: requestID, code: "request_failed", message: message))
            case .started(let filename, let events):
                do {
                    try ctx.connection.send(.started(id: requestID, chat: filename))
                    for await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .delta(let text):
                            try ctx.connection.send(.delta(id: requestID, text: text))
                        case .finished(let error):
                            if let error {
                                try ctx.connection.send(.error(id: requestID, code: "stream_error", message: error))
                            } else {
                                try ctx.connection.send(.done(id: requestID, chat: filename))
                            }
                        }
                    }
                } catch {
                    // Client went away mid-stream; the chat keeps streaming
                    // in the app — only the forwarding stops here.
                }
            }
        }
        ctx.addTask(requestID, task)
    }

    private func send(_ frame: CLIFrame, to ctx: ClientContext) {
        do {
            try ctx.connection.send(frame)
        } catch {
            debugLog("CLI", "failed to send frame to client — \(error)")
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }
}
