// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import WebKit

// MARK: - EditMessageSheet

/// A multiline plain-text editing modal for editing a message's content.
/// Presented by `ChatView` when the web view bridge requests an edit action.
struct EditMessageSheet: View {
    let initialText: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit message")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120, maxHeight: 240)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .focused($isFocused)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onConfirm(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            text = initialText
            isFocused = true
        }
    }
}

// MARK: - ChatWebView

/// A SwiftUI wrapper around a persistent `WKWebView` that renders the chat as
/// HTML/JS. The underlying web view is kept alive across chat switches (held by
/// `ChatWebViewModel`) so switching chats is instant — we just push a new
/// snapshot rather than reloading the page.
///
/// Communication:
///  - Swift -> JS: `evaluateJavaScript` calling `window.chatHost.postMessage(json)`.
///  - JS -> Swift: `WKScriptMessageHandler` named "bridge".
struct ChatWebView: View {
    @EnvironmentObject var store: AppViewModel
    @StateObject private var model = ChatWebViewModel()

    /// A lightweight signature of the selected chat's message contents.
    /// Changes when any message is added, edited, deleted, or streamed to.
    /// Used as an `onChange` trigger so the web view gets refreshed.
    private var chatContentSignature: Int {
        guard let messages = store.selectedChatItem?.chat.messages else { return 0 }
        var hash = messages.count
        for msg in messages {
            hash = hash &* 31 &+ msg.content.count
            hash = hash &* 31 &+ (msg.thinking?.count ?? 0)
            hash = hash &* 31 &+ (msg.error?.count ?? 0)
        }
        return hash
    }

    var body: some View {
        ChatWebViewRepresentable(model: model)
            .onAppear {
                model.bind(store: store)
            }
            .onDisappear {
                model.unbind()
            }
            .onChange(of: store.selectedChatID) { _, _ in
                model.pushSnapshot()
            }
            .onChange(of: store.isStreaming) { _, _ in
                model.pushSnapshot()
            }
            // Reload the web view when chat rendering features change so the
            // renderer re-evaluates which optional dependencies to load.
            .onChange(of: store.preferencesMermaidEnabled) { _, _ in
                model.reload(mermaid: store.preferencesMermaidEnabled, katex: store.preferencesKatexEnabled, debug: store.preferencesChatRendererDebugEnabled)
            }
            .onChange(of: store.preferencesKatexEnabled) { _, _ in
                model.reload(mermaid: store.preferencesMermaidEnabled, katex: store.preferencesKatexEnabled, debug: store.preferencesChatRendererDebugEnabled)
            }
            .onChange(of: store.preferencesChatRendererDebugEnabled) { _, _ in
                model.reload(mermaid: store.preferencesMermaidEnabled, katex: store.preferencesKatexEnabled, debug: store.preferencesChatRendererDebugEnabled)
            }
            // Observe a lightweight signature of the selected chat's messages
            // (count + total content length + total thinking length). This
            // catches new messages, edits, deletes, and streaming token updates
            // without observing every individual message.
            .onChange(of: chatContentSignature) { _, _ in
                model.pushSnapshot()
            }
    }
}

// MARK: - ChatWebViewModel

/// Owns the persistent `WKWebView` and bridges `AppViewModel` state into it.
/// Kept alive via `@StateObject` so the web view survives chat switches within
/// the same window.
@MainActor
final class ChatWebViewModel: ObservableObject {
    let webView: WKWebView
    /// Whether the web page has finished loading and reported `ready`.
    /// Messages sent before this are queued and flushed on ready.
    private var webReady: Bool = false
    /// Queued host messages waiting for the web view to become ready.
    private var pendingMessages: [HostMessageData] = []
    /// The chat id currently rendered in the web view. Used to detect chat
    /// switches so we send a fresh full snapshot.
    private var renderedChatId: String?
    /// The last streaming state we pushed, so we only send changes.
    private var lastStreamingState: Bool = false
    /// The last known messages (by id) in the rendered chat, used for diffing
    /// to send incremental updates instead of full snapshots.
    private var lastMessages: [String: ChatMessageData] = [:]
    /// The last known message order (ids in order), used for diffing.
    private var lastMessageIds: [String] = []
    private var store: AppViewModel?
    private var themeObservation: NSKeyValueObservation?
    /// Feature flags passed to the renderer via URL query params so it only
    /// loads the (large) Mermaid/KaTeX bundles when enabled.
    private var mermaidEnabled: Bool = false
    private var katexEnabled: Bool = false
    private var debugEnabled: Bool = false

    init() {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        config.userContentController = userContentController
        // Allow local file access for the bundled web assets.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = nil
        // Transparent background so the SwiftUI material shows through.
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        // Suppress the default context menu / text selection callouts we don't want.
        webView.allowsBackForwardNavigationGestures = false

        // Register the JS -> Swift bridge. The view model is the message handler.
        userContentController.add(MessageHandlerBridge(target: self), name: "bridge")
    }

    deinit {
        // KVO observation is cleaned up automatically; the script message
        // handler is retained by the web view's configuration which is freed
        // when the web view deallocates. We avoid touching main-actor isolated
        // properties here (deinit is nonisolated).
        themeObservation?.invalidate()
    }

    // MARK: - Page loading

    /// Loads the bundled index.html from the app bundle's ChatRenderer resource
    /// directory. The web renderer is always built and included in the bundle
    /// by `build.sh`; there is no dev fallback. Feature flags are passed via
    /// URL query params so the renderer only loads Mermaid/KaTeX when enabled.
    private func loadPage() {
        // Feature flags are presence-based query params, e.g.
        // `?withMermaid&withKatex&withDebug`. Only enabled features are included.
        var parts: [String] = []
        if mermaidEnabled { parts.append("withMermaid") }
        if katexEnabled { parts.append("withKatex") }
        if debugEnabled { parts.append("withDebug") }
        let query = parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ChatRenderer") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = query.isEmpty ? nil : query.dropFirst().description
            if let final = components?.url {
                webView.loadFileURL(final, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        } else if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = query.isEmpty ? nil : query.dropFirst().description
            if let final = components?.url {
                webView.loadFileURL(final, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }
    }

    // MARK: - Binding to the store

    /// Connects this model to the app view model and starts pushing snapshots.
    func bind(store: AppViewModel) {
        self.store = store
        mermaidEnabled = store.preferencesMermaidEnabled
        katexEnabled = store.preferencesKatexEnabled
        debugEnabled = store.preferencesChatRendererDebugEnabled
        loadPage()
        observeTheme()
        pushSnapshot()
    }

    func unbind() {
        store = nil
    }

    /// Reloads the web page with updated feature flags. Called when the
    /// Mermaid/KaTeX preferences change so the renderer loads (or skips) the
    /// corresponding bundles.
    func reload(mermaid: Bool, katex: Bool, debug: Bool) {
        mermaidEnabled = mermaid
        katexEnabled = katex
        debugEnabled = debug
        // Reset bridge state so queued messages are flushed after re-ready.
        webReady = false
        renderedChatId = nil
        lastMessages = [:]
        lastMessageIds = []
        lastStreamingState = false
        loadPage()
    }

    // MARK: - Theme

    private func observeTheme() {
        // Observe the effective appearance and push theme changes.
        themeObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.pushTheme()
            }
        }
        pushTheme()
    }

    private func pushTheme() {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let theme = appearance == .darkAqua ? "dark" : "light"
        sendHostMessage(.theme(theme: theme))
    }

    // MARK: - Snapshot pushing

    /// Called whenever the store's published state changes. Diffs the current
    /// message list against the last known state and sends incremental updates
    /// (updateMessage / addMessage / deleteMessage) when possible. Falls back
    /// to a full snapshot on chat switch or streaming-end.
    func pushSnapshot() {
        guard let store else { return }
        guard let item = store.selectedChatItem else { return }

        let chatId = item.id
        let isStreaming = item.isStreaming
        let currentMessages = item.chat.messages.map(\.webData)
        let currentIds = currentMessages.map(\.id)

        // Chat switched: send a full snapshot and reset diff state.
        if chatId != renderedChatId {
            renderedChatId = chatId
            lastStreamingState = isStreaming
            lastMessages = Dictionary(uniqueKeysWithValues: currentMessages.map { ($0.id, $0) })
            lastMessageIds = currentIds
            let snapshot = ChatSnapshotData(chatId: chatId, messages: currentMessages, isStreaming: isStreaming)
            sendHostMessage(.snapshot(snapshot: snapshot))
            return
        }

        // Same chat — handle streaming state change first.
        if isStreaming != lastStreamingState {
            lastStreamingState = isStreaming
            if !isStreaming {
                // Streaming ended: send a full snapshot so the web view
                // re-renders the final content as block markdown.
                lastMessages = Dictionary(uniqueKeysWithValues: currentMessages.map { ($0.id, $0) })
                lastMessageIds = currentIds
                let snapshot = ChatSnapshotData(chatId: chatId, messages: currentMessages, isStreaming: false)
                sendHostMessage(.snapshot(snapshot: snapshot))
                return
            } else {
                sendHostMessage(.streaming(chatId: chatId, isStreaming: true))
            }
        }

        // Diff messages and send incremental updates.
        let oldIds = Set(lastMessageIds)
        let newIds = Set(currentIds)

        // Deleted messages.
        for id in lastMessageIds where !newIds.contains(id) {
            sendHostMessage(.deleteMessage(chatId: chatId, messageId: id))
        }

        // Added or updated messages.
        for (index, msg) in currentMessages.enumerated() {
            if !oldIds.contains(msg.id) {
                // New message.
                sendHostMessage(.addMessage(chatId: chatId, message: msg, index: index))
            } else if let old = lastMessages[msg.id], old != msg {
                // Content changed (streaming token, edit, error).
                sendHostMessage(.updateMessage(chatId: chatId, message: msg))
            }
        }

        // Update diff state.
        lastMessages = Dictionary(uniqueKeysWithValues: currentMessages.map { ($0.id, $0) })
        lastMessageIds = currentIds
    }

    /// Forces a scroll-to-bottom in the web view (e.g. when the user sends a
    /// new message).
    func scrollToBottom() {
        sendHostMessage(.scrollToBottom)
    }

    // MARK: - JS communication

    private func sendHostMessage(_ message: HostMessageData) {
        // If the web view hasn't reported ready yet, queue the message. It will
        // be flushed once the page loads and calls `ready`.
        if !webReady {
            pendingMessages.append(message)
            return
        }
        guard let json = try? JSONEncoder().encode(message),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        // The web view's `chatHost.postMessage` expects a JSON string.
        let escaped = jsonString.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = "window.chatHost && window.chatHost.postMessage('\(escaped)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Receiving messages from JS

    /// Called by the `MessageHandlerBridge` when the web view posts a message.
    fileprivate func handleBridgeMessage(_ message: BridgeMessageData) {
        guard let store else { return }
        switch message {
        case .copy(let messageId):
            copyMessage(messageId)
        case .edit(let messageId):
            // Defer to the view's edit sheet via a published flag.
            store.pendingEditMessageID = UUID(uuidString: messageId)
        case .delete(let messageId):
            store.pendingDeleteMessageID = UUID(uuidString: messageId)
        case .retry:
            store.retryLastMessage()
        case .scrollState(let atBottom):
            store.selectedChatAtBottom = atBottom
        case .ready:
            // Web view is ready. Flush any queued messages, then force a full
            // snapshot + theme so the initial state is always delivered.
            webReady = true
            for msg in pendingMessages {
                sendHostMessage(msg)
            }
            pendingMessages.removeAll()
            // Reset diff state so the next pushSnapshot sends a full snapshot.
            renderedChatId = nil
            lastMessages = [:]
            lastMessageIds = []
            lastStreamingState = false
            pushSnapshot()
            pushTheme()
        case .requestOlder:
            // Infinite scroll: the host owns the full history already (all
            // messages are in the snapshot), so there's nothing to load. This
            // hook is here for future pagination if chats grow very large.
            break
        }
    }

    private func copyMessage(_ messageId: String) {
        guard let item = store?.selectedChatItem,
              let msg = item.chat.messages.first(where: { $0.id.uuidString == messageId }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(msg.content, forType: .string)
    }
}

// MARK: - Bridge message handler

/// A thin `WKScriptMessageHandler` that forwards to the view model. We use a
/// separate class (rather than making the view model conform) so the web view
/// doesn't retain the view model strongly via the message-handler loop.
private final class MessageHandlerBridge: NSObject, WKScriptMessageHandler {
    weak var target: ChatWebViewModel?

    init(target: ChatWebViewModel) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let parsed = try? JSONDecoder().decode(BridgeMessageData.self, from: data) else {
            return
        }
        Task { @MainActor in
            self.target?.handleBridgeMessage(parsed)
        }
    }
}

// MARK: - SwiftUI representable

private struct ChatWebViewRepresentable: NSViewRepresentable {
    let model: ChatWebViewModel

    func makeNSView(context: Context) -> WKWebView {
        model.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Push the latest snapshot whenever SwiftUI re-renders.
        model.pushSnapshot()
    }
}

// MARK: - Wire types (Swift <-> JSON)

/// The JSON shape sent Swift -> JS. Matches `HostMessage` in types.ts.
enum HostMessageData: Codable {
    case snapshot(snapshot: ChatSnapshotData)
    case streaming(chatId: String, isStreaming: Bool)
    case theme(theme: String)
    case scrollToBottom
    case updateMessage(chatId: String, message: ChatMessageData)
    case addMessage(chatId: String, message: ChatMessageData, index: Int)
    case deleteMessage(chatId: String, messageId: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case snapshot
        case chatId
        case isStreaming
        case theme
        case message
        case index
        case messageId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let snapshot):
            try c.encode("snapshot", forKey: .type)
            try c.encode(snapshot, forKey: .snapshot)
        case .streaming(let chatId, let isStreaming):
            try c.encode("streaming", forKey: .type)
            try c.encode(chatId, forKey: .chatId)
            try c.encode(isStreaming, forKey: .isStreaming)
        case .theme(let theme):
            try c.encode("theme", forKey: .type)
            try c.encode(theme, forKey: .theme)
        case .scrollToBottom:
            try c.encode("scrollToBottom", forKey: .type)
        case .updateMessage(let chatId, let message):
            try c.encode("updateMessage", forKey: .type)
            try c.encode(chatId, forKey: .chatId)
            try c.encode(message, forKey: .message)
        case .addMessage(let chatId, let message, let index):
            try c.encode("addMessage", forKey: .type)
            try c.encode(chatId, forKey: .chatId)
            try c.encode(message, forKey: .message)
            try c.encode(index, forKey: .index)
        case .deleteMessage(let chatId, let messageId):
            try c.encode("deleteMessage", forKey: .type)
            try c.encode(chatId, forKey: .chatId)
            try c.encode(messageId, forKey: .messageId)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            self = .snapshot(snapshot: try c.decode(ChatSnapshotData.self, forKey: .snapshot))
        case "streaming":
            self = .streaming(chatId: try c.decode(String.self, forKey: .chatId),
                              isStreaming: try c.decode(Bool.self, forKey: .isStreaming))
        case "theme":
            self = .theme(theme: try c.decode(String.self, forKey: .theme))
        case "scrollToBottom":
            self = .scrollToBottom
        case "updateMessage":
            self = .updateMessage(chatId: try c.decode(String.self, forKey: .chatId),
                                  message: try c.decode(ChatMessageData.self, forKey: .message))
        case "addMessage":
            self = .addMessage(chatId: try c.decode(String.self, forKey: .chatId),
                               message: try c.decode(ChatMessageData.self, forKey: .message),
                               index: try c.decode(Int.self, forKey: .index))
        case "deleteMessage":
            self = .deleteMessage(chatId: try c.decode(String.self, forKey: .chatId),
                                  messageId: try c.decode(String.self, forKey: .messageId))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type")
        }
    }
}

/// The JSON shape received JS -> Swift. Matches `BridgeMessage` in types.ts.
enum BridgeMessageData: Codable {
    case copy(messageId: String)
    case edit(messageId: String)
    case delete(messageId: String)
    case retry
    case scrollState(atBottom: Bool)
    case ready
    case requestOlder(chatId: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case messageId
        case atBottom
        case chatId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .copy(let id):
            try c.encode("copy", forKey: .type)
            try c.encode(id, forKey: .messageId)
        case .edit(let id):
            try c.encode("edit", forKey: .type)
            try c.encode(id, forKey: .messageId)
        case .delete(let id):
            try c.encode("delete", forKey: .type)
            try c.encode(id, forKey: .messageId)
        case .retry:
            try c.encode("retry", forKey: .type)
        case .scrollState(let atBottom):
            try c.encode("scrollState", forKey: .type)
            try c.encode(atBottom, forKey: .atBottom)
        case .ready:
            try c.encode("ready", forKey: .type)
        case .requestOlder(let chatId):
            try c.encode("requestOlder", forKey: .type)
            try c.encode(chatId, forKey: .chatId)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "copy":
            self = .copy(messageId: try c.decode(String.self, forKey: .messageId))
        case "edit":
            self = .edit(messageId: try c.decode(String.self, forKey: .messageId))
        case "delete":
            self = .delete(messageId: try c.decode(String.self, forKey: .messageId))
        case "retry":
            self = .retry
        case "scrollState":
            self = .scrollState(atBottom: try c.decode(Bool.self, forKey: .atBottom))
        case "ready":
            self = .ready
        case "requestOlder":
            self = .requestOlder(chatId: try c.decode(String.self, forKey: .chatId))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type")
        }
    }
}

/// A chat snapshot sent to the web view.
struct ChatSnapshotData: Codable {
    let chatId: String
    let messages: [ChatMessageData]
    let isStreaming: Bool
}

/// The JSON representation of a `ChatMessage` sent to the web view.
struct ChatMessageData: Codable, Equatable {
    let id: String
    let role: String
    let content: String
    let thinking: String?
    let error: String?
    let timestamp: String
    let connectionName: String?
}

extension ChatMessage {
    /// Converts a `ChatMessage` to its JSON wire representation.
    var webData: ChatMessageData {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ChatMessageData(
            id: id.uuidString,
            role: role.rawValue,
            content: content,
            thinking: thinking,
            error: error,
            timestamp: formatter.string(from: timestamp),
            connectionName: connectionName
        )
    }
}
