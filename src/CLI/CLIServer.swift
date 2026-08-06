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
/// live peer's file is never unlinked), the server itself is started once the
/// startup loader has finished AND hidden (from the loader's
/// `startupHiddenHandler`, after the 1-second results-display delay — clients
/// treat socket connectability as the readiness signal, so it must not appear
/// while the loader is still up), and `stop()` on termination closes
/// everything and unlinks the socket file.
final class CLIServer: @unchecked Sendable {

    /// Dispatches a `chat.send` request to the engine. Injectable for tests.
    typealias OneShotHandler = @Sendable (CLIRequest) async -> OneShotStart

    /// Destroys temporary chats whose owning client disconnected. Injectable
    /// for tests; nil means temporary chats outlive their client.
    typealias TemporaryChatCleanup = @Sendable ([String]) async -> Void

    static let shared = CLIServer(
        socketPath: EnvironmentManager.shared.socketURL.path,
        oneShotHandler: { request in
            await ChatEngine.shared.performOneShot(
                message: request.params.message,
                role: request.params.role,
                connection: request.params.connection,
                chatName: request.params.chat,
                temporary: request.params.temporary,
                workdir: request.params.workdir,
                workdirExplicit: request.params.workdirExplicit,
                allowAll: request.params.allowAll
            )
        },
        temporaryChatCleanup: { filenames in
            await ChatEngine.shared.destroyTemporaryChats(filenames: filenames)
        }
    )

    let socketPath: String
    private let oneShotHandler: OneShotHandler
    private let temporaryChatCleanup: TemporaryChatCleanup?

    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clients: [ObjectIdentifier: ClientContext] = [:]

    init(socketPath: String, oneShotHandler: @escaping OneShotHandler, temporaryChatCleanup: TemporaryChatCleanup? = nil) {
        self.socketPath = socketPath
        self.oneShotHandler = oneShotHandler
        self.temporaryChatCleanup = temporaryChatCleanup
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

    /// Per-connection state: the framed transport, its session id, the
    /// in-flight request tasks (cancelled when the connection drops), and
    /// the temporary chats this client created (destroyed on disconnect).
    private final class ClientContext: @unchecked Sendable {
        let connection: CLIConnection
        var sessionID: String?
        private let lock = NSLock()
        private var tasks: [String: Task<Void, Never>] = [:]
        private var temporaryChats: Set<String> = []
        /// Set when the connection is gone and the chats were drained — a
        /// late `addTemporaryChat` then fails so the caller destroys the
        /// chat itself instead of registering it where nobody will look.
        private var closed = false

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

        /// Returns false when the connection was already closed and drained:
        /// the chat is NOT registered and the caller must dispose of it.
        func addTemporaryChat(_ filename: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return false }
            temporaryChats.insert(filename)
            return true
        }

        func drainTemporaryChats() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            closed = true
            let all = Array(temporaryChats)
            temporaryChats.removeAll()
            return all
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
            let orphanTempChats = ctx.drainTemporaryChats()
            if !orphanTempChats.isEmpty, let cleanup = self.temporaryChatCleanup {
                debugLog("CLI", "destroying \(orphanTempChats.count) temporary chat(s) of a disconnected client")
                await cleanup(orphanTempChats)
            }
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
            case .welcome, .pong, .started, .delta, .tool, .notice, .done, .error:
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
                if request.params.temporary, !ctx.addTemporaryChat(filename) {
                    // The client disconnected while the chat was being
                    // created; the disconnect handler already drained this
                    // context, so destroy the chat here — otherwise it would
                    // leak (invisible, streaming to nobody).
                    debugLog("CLI", "client gone before temporary chat \(filename) was registered — destroying it")
                    await self.temporaryChatCleanup?([filename])
                    return
                }
                do {
                    try ctx.connection.send(.started(id: requestID, chat: filename))
                    for await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .delta(let text):
                            try ctx.connection.send(.delta(id: requestID, text: text))
                        case .toolCall(let name, let summary):
                            try ctx.connection.send(.tool(id: requestID, name: name, args: summary, status: nil))
                        case .toolResult(let name, let summary):
                            try ctx.connection.send(.tool(id: requestID, name: name, args: nil, status: CLIToolStatus(kind: summary.kind.rawValue, label: summary.label, description: summary.description)))
                        case .notice(let text):
                            try ctx.connection.send(.notice(id: requestID, text: text))
                        case .finished(let error, let chatName):
                            if let error {
                                try ctx.connection.send(.error(id: requestID, code: "stream_error", message: error))
                            } else {
                                try ctx.connection.send(.done(id: requestID, chat: filename, name: chatName))
                            }
                        }
                    }
                } catch {
                    // Client went away mid-stream; only the forwarding stops
                    // here — the engine stops the stream itself once the last
                    // one-shot sink of the chat terminates.
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
