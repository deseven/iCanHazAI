// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import WebKit
import CoreGraphics

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

    var body: some View {
        ZStack {
            ChatWebViewRepresentable(model: model)
                .onAppear {
                    model.bind(store: store)
                }
                .onDisappear {
                    model.unbind()
                }
                .onChange(of: store.selectedChatID) { _, newID in
                    debugLog("Chat", "selection changed → \(newID ?? "nil")")
                    if let newID {
                        model.beginChatSwitch(to: newID)
                    } else {
                        model.cancelChatSwitch()
                    }
                    model.pushSnapshot()
                }
                .onChange(of: store.isStreaming) { _, _ in
                    model.pushSnapshot()
                }
                .onChange(of: store.preferencesMermaidEnabled) { _, _ in
                    model.reload(mermaid: store.preferencesMermaidEnabled, katex: store.preferencesKatexEnabled, debug: store.preferencesChatRendererDebugEnabled, expandThinking: store.preferencesExpandThinking, expandToolUse: store.preferencesExpandToolUse)
                }
                .onChange(of: store.preferencesKatexEnabled) { _, _ in
                    model.reload(mermaid: store.preferencesMermaidEnabled, katex: store.preferencesKatexEnabled, debug: store.preferencesChatRendererDebugEnabled, expandThinking: store.preferencesExpandThinking, expandToolUse: store.preferencesExpandToolUse)
                }
                .onChange(of: store.preferencesChatRendererDebugEnabled) { _, _ in
                    model.reload(mermaid: store.preferencesMermaidEnabled, katex: store.preferencesKatexEnabled, debug: store.preferencesChatRendererDebugEnabled, expandThinking: store.preferencesExpandThinking, expandToolUse: store.preferencesExpandToolUse)
                }
                .onChange(of: store.preferencesExpandThinking) { _, _ in
                    model.reload(mermaid: store.preferencesMermaidEnabled, katex: store.preferencesKatexEnabled, debug: store.preferencesChatRendererDebugEnabled, expandThinking: store.preferencesExpandThinking, expandToolUse: store.preferencesExpandToolUse)
                }
                .onChange(of: store.preferencesExpandToolUse) { _, _ in
                    model.reload(mermaid: store.preferencesMermaidEnabled, katex: store.preferencesKatexEnabled, debug: store.preferencesChatRendererDebugEnabled, expandThinking: store.preferencesExpandThinking, expandToolUse: store.preferencesExpandToolUse)
                }
                .onChange(of: store.preferencesInterfaceScale) { _, scale in
                    model.setInterfaceScale(scale)
                }

            // Opaque cover + spinner while the renderer loads a freshly
            // selected chat. Native (not the renderer's own spinner) so it
            // appears even while the WebContent process is still busy
            // rendering the previous chat.
            if model.switchOverlayVisible {
                Color(nsColor: .windowBackgroundColor)
                ProgressView()
                    .controlSize(.large)
            }
        }
    }
}

// MARK: - ChatWebViewModel

/// Owns the persistent `WKWebView` and bridges `AppViewModel` state into it.
/// Kept alive via `@StateObject` so the web view survives chat switches within
/// the same window.
@MainActor
final class ChatWebViewModel: ObservableObject {
    /// The live web view. Created lazily and torn down when the host window
    /// stays occluded/minimized/closed for >15s to free the WebContent process.
    /// The renderer is purely representational, so it can be recreated and
    /// the current chat snapshot replayed on demand.
    private(set) var webView: WKWebView?
    /// The scheme handler serving chat images via `ichai://`.
    private let imageSchemeHandler = ImageSchemeHandler()
    /// Whether the web page has finished loading and reported `ready`.
    /// Messages sent before this are queued and flushed on ready.
    private var webReady: Bool = false
    /// Queued JS statements waiting for the web view to become ready.
    private var pendingMessages: [String] = []
    /// Off-main pipeline that projects, diffs, and encodes chat snapshots
    /// into JS statements (see `ChatRenderQueue`). `pushSnapshot()` just
    /// captures the current state and enqueues a job, so the main actor never
    /// does O(chat size) work.
    private lazy var renderQueue = ChatRenderQueue { [weak self] js in
        await self?.deliverJS(js)
    }
    /// Tail of a task chain serializing `renderQueue.enqueue` calls so jobs
    /// reach the actor in exactly the order they were issued here.
    private var renderQueueTail: Task<Void, Never>?
    /// The chat the renderer is currently loading, while a chat switch is in
    /// flight. Cleared when the renderer reports `loaded` for this id.
    private var pendingSwitchChatId: String?
    /// Whether the opaque switch overlay (spinner) covers the web view.
    @Published private(set) var switchOverlayVisible: Bool = false
    /// Force-dismisses the overlay if the renderer never reports `loaded`
    /// (e.g. a crashed WebContent process) so the spinner can't get stranded.
    private var switchWatchdogTask: Task<Void, Never>?
    /// Max time to wait for the renderer's `loaded` report before giving up.
    private static let switchWatchdogTimeout: Duration = .seconds(10)
    private var store: AppViewModel?
    private var themeObservation: NSKeyValueObservation?
    /// Retains the navigation delegate that intercepts link clicks and opens
    /// external http(s) URLs in the user's default system browser instead of
    /// trying (and failing) to navigate the web view to them.
    private let navigationDelegate = ChatWebViewNavigationDelegate()
    /// Feature flags passed to the renderer via URL query params so it only
    /// loads the (large) Mermaid/KaTeX bundles when enabled.
    private var mermaidEnabled: Bool = false
    private var katexEnabled: Bool = false
    private var interfaceScale: Double = ChatFeaturesConfig.defaultInterfaceScale
    private var debugEnabled: Bool = false
    private var expandThinkingEnabled: Bool = false
    private var expandToolUseEnabled: Bool = false

    /// Host container returned to SwiftUI; the web view is added/removed as a
    /// subview so we can tear it down and recreate it without invalidating the
    /// representable.
    private var hostView: ChatWebViewHostView?
    private var userContentController: WKUserContentController?
    private var config: WKWebViewConfiguration?
    /// The window whose visibility we track, if any.
    private weak var observedWindow: NSWindow?
    /// Pending teardown-after-15s timer.
    private var killTask: Task<Void, Never>?
    /// Pending one-shot fallback coverage check (20s after window goes inactive
    /// but isn't minimized/occluded).
    private var coverageTask: Task<Void, Never>?
    /// True when the web view has been torn down and not yet restored.
    private var isTornDown: Bool = false
    /// Grace period (seconds) before killing the WebContent process after the
    /// host window becomes non-visible (occluded/minimized/closed).
    private static let killDelaySeconds: Int = 15
    /// Delay (seconds) before running the one-shot fallback coverage check
    /// after the window becomes inactive but not minimized/occluded.
    private static let coverageDelaySeconds: Int = 20
    /// Minimum fraction of our window's area that the frontmost window must
    /// cover for us to consider the webview not visible.
    private static let coverageThreshold: Double = 0.9

    init() {}

    deinit {
        themeObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle (teardown / restore on window occlusion)

    /// Returns the host container SwiftUI should display. The web view is
    /// created lazily and embedded as a subview; it can be torn down and
    /// recreated without invalidating the representable.
    func makeHostView() -> NSView {
        if hostView == nil {
            let host = ChatWebViewHostView()
            host.autoresizesSubviews = true
            host.onMoveToWindow = { [weak self] _ in
                self?.reattachToCurrentWindow()
            }
            hostView = host
        }
        ensureWebView()
        return hostView!
    }

    /// Creates a fresh web view (config + scheme handler + message bridge) and
    /// embeds it in the host view. No-op if one already exists.
    private func ensureWebView() {
        guard webView == nil, let hostView else { return }
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        cfg.setURLSchemeHandler(imageSchemeHandler, forURLScheme: ImageSchemeHandler.scheme)

        let wv = WKWebView(frame: hostView.bounds, configuration: cfg)
        wv.navigationDelegate = navigationDelegate
        wv.pageZoom = CGFloat(interfaceScale / 100)
        wv.underPageBackgroundColor = .clear
        wv.setValue(false, forKey: "drawsBackground")
        wv.allowsBackForwardNavigationGestures = false
        wv.autoresizingMask = [.width, .height]
        hostView.addSubview(wv)

        ucc.add(MessageHandlerBridge(target: self), name: "bridge")

        webView = wv
        userContentController = ucc
        config = cfg
        isTornDown = false
        debugLog("Renderer", "webview created")
    }

    /// Kills the WebContent process (via the private `_close` API, the only
    /// reliable way to terminate it promptly) and drops the web view. State
    /// lives in `AppViewModel`, so `restoreWebView()` can replay the snapshot.
    func teardownWebView() {
        killTask?.cancel()
        killTask = nil
        guard let webView else { return }
        debugLog("Renderer", "tearing down webview to free memory")
        webView.stopLoading()
        userContentController?.removeScriptMessageHandler(forName: "bridge")
        webView.perform(NSSelectorFromString("_close"))
        webView.removeFromSuperview()
        self.webView = nil
        userContentController = nil
        config = nil
        webReady = false
        pendingMessages = []
        isTornDown = true
        enqueueRenderJob(.reset)
    }

    /// Recreates the web view (if needed) and replays the current chat snapshot.
    /// Safe to call when the web view already exists — it just reloads + pushes.
    private func restoreWebView() {
        debugLog("Renderer", "restoring webview after window became visible")
        if webView == nil {
            pendingMessages = []
            ensureWebView()
        }
        guard webView != nil, store != nil else { return }
        if !webReady {
            loadPage()
        }
        pushSnapshot()
    }

    // MARK: - Window visibility tracking

    /// (Re)attaches occlusion/close/key observers to the window currently
    /// hosting the web view. Called whenever the host view moves to a window.
    private func reattachToCurrentWindow() {
        let window = hostView?.window
        if observedWindow === window { return }
        if let old = observedWindow {
            for name in Self.observedNotifications {
                NotificationCenter.default.removeObserver(self, name: name, object: old)
            }
        }
        observedWindow = window
        guard let window else { return }
        for name in Self.observedNotifications {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: window)
        }
        windowVisibilityChanged()
    }

    private static let observedNotifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.willCloseNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.didMiniaturizeNotification,
    ]

    @objc private func windowVisibilityChanged() {
        guard let window = observedWindow, window === hostView?.window else {
            debugLog("Renderer", "visibility: no observed window → schedule kill")
            scheduleKill()
            return
        }
        // Active (key/main) window is in front → definitely visible.
        // Minimized or fully-occluded → definitely not visible.
        // Otherwise (inactive but on screen, not minimized) → ambiguous; the
        // fallback coverage check decides after a grace period.
        let isKeyOrMain = window.isKeyWindow || window.isMainWindow
        let isMinimized = window.isMiniaturized
        let isOccluded = !window.occlusionState.contains(.visible)
        debugLog("Renderer", "visibility: key=\(window.isKeyWindow) main=\(window.isMainWindow) minimized=\(isMinimized) occluded=\(isOccluded) visible=\(window.isVisible)")

        if isKeyOrMain {
            // Definitely visible: cancel any pending kill/coverage check.
            killTask?.cancel()
            killTask = nil
            coverageTask?.cancel()
            coverageTask = nil
            if isTornDown { restoreWebView() }
        } else if isMinimized || isOccluded {
            // Definitely hidden: kill after the grace period.
            coverageTask?.cancel()
            coverageTask = nil
            scheduleKill()
        } else {
            // Inactive but on screen and not minimized/occluded. The occlusion
            // machinery didn't fire (a sliver of the window is visible), so we
            // schedule the one-shot fallback coverage check.
            killTask?.cancel()
            killTask = nil
            scheduleCoverageCheck()
        }
    }

    private func scheduleKill() {
        if killTask != nil { return }
        debugLog("Renderer", "scheduling kill in \(ChatWebViewModel.killDelaySeconds)s")
        killTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ChatWebViewModel.killDelaySeconds))
            guard !Task.isCancelled, let self else { return }
            self.teardownWebView()
        }
    }

    /// One-shot fallback: 20s after the window becomes inactive (but not
    /// minimized/occluded), checks whether the frontmost window fully covers
    /// our window's rect (inset by 10px). If so, the webview isn't visible and
    /// we tear it down. Runs only once per inactive period.
    private func scheduleCoverageCheck() {
        if coverageTask != nil { return }
        debugLog("Renderer", "scheduling coverage check in \(ChatWebViewModel.coverageDelaySeconds)s")
        coverageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ChatWebViewModel.coverageDelaySeconds))
            guard !Task.isCancelled, let self else { return }
            self.performCoverageCheck()
        }
    }

    private func performCoverageCheck() {
        coverageTask = nil
        guard let window = observedWindow, window === hostView?.window else {
            debugLog("Renderer", "coverage check: no observed window")
            return
        }
        // If the window became key again in the meantime, nothing to do.
        if window.isKeyWindow || window.isMainWindow {
            debugLog("Renderer", "coverage check: window is key/main again, aborting")
            return
        }
        let ourRect = window.frame
        guard let ourWindowID = window.windowNumber as Int? else {
            debugLog("Renderer", "coverage check: no window number")
            return
        }
        // Enumerate all on-screen layer-0 windows front-to-back, find ours, and
        // union the rects of every window above ours. If that union covers
        // >= coverageThreshold of our window's area, the webview isn't visible.
        guard let (ourRectFound, coveringUnion) = Self.coveringUnionAbove(windowID: ourWindowID) else {
            debugLog("Renderer", "coverage check: could not enumerate windows")
            return
        }
        guard ourRectFound else {
            debugLog("Renderer", "coverage check: our window not found in window list")
            return
        }
        // Same-screen check: the covering union's midpoint must be on the same
        // screen as our window's midpoint.
        guard Self.sameScreen(ourRect, coveringUnion) else {
            debugLog("Renderer", "coverage check: different screens, aborting")
            return
        }
        let intersection = ourRect.intersection(coveringUnion)
        let ourArea = ourRect.width * ourRect.height
        let coveredArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let ratio = ourArea > 0 ? coveredArea / ourArea : 0
        let covered = ratio >= ChatWebViewModel.coverageThreshold
        debugLog("Renderer", "coverage check: ourRect=\(ourRect) union=\(coveringUnion) ourArea=\(ourArea) coveredArea=\(coveredArea) ratio=\(ratio) covered=\(covered)")
        if covered {
            debugLog("Renderer", "fallback coverage check: window covered by windows above → killing webview")
            teardownWebView()
        }
    }

    /// Enumerates on-screen layer-0 windows front-to-back, finds the window
    /// matching `windowID`, and returns the union of all layer-0 window rects
    /// that are above it in z-order. Returns (found, unionRect). If our window
    /// isn't found, returns (false, .null).
    private static func coveringUnionAbove(windowID: Int) -> (Bool, CGRect)? {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var union = CGRect.null
        var found = false
        for w in info {
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }
            let id = (w[kCGWindowNumber as String] as? Int) ?? -1
            if id == windowID {
                found = true
                break
            }
            guard let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0
            let wv = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0
            union = union.union(CGRect(x: x, y: y, width: wv, height: h))
        }
        return (found, union)
    }

    /// Returns true if both rects' midpoints lie on the same NSScreen.
    private static func sameScreen(_ a: CGRect, _ b: CGRect) -> Bool {
        let midA = CGPoint(x: a.midX, y: a.midY)
        let midB = CGPoint(x: b.midX, y: b.midY)
        let screenA = NSScreen.screens.first { $0.frame.contains(midA) }
        let screenB = NSScreen.screens.first { $0.frame.contains(midB) }
        return screenA != nil && screenA === screenB
    }

    // MARK: - Page loading

    /// Loads the bundled index.html from the app bundle's ChatRenderer resource
    /// directory. The web renderer is always built and included in the bundle
    /// by `build.sh`; there is no dev fallback. Feature flags are passed via
    /// URL query params so the renderer only loads Mermaid/KaTeX when enabled.
    private func loadPage() {
        guard let webView else { return }
        var parts: [String] = []
        if mermaidEnabled { parts.append("withMermaid") }
        if katexEnabled { parts.append("withKatex") }
        if debugEnabled { parts.append("withDebug") }
        if expandThinkingEnabled { parts.append("withExpandedThinking") }
        if expandToolUseEnabled { parts.append("withExpandedToolUse") }
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
    /// The web view itself is created lazily by `makeHostView()` once it's
    /// placed in a window; this just stashes the store and feature flags.
    func bind(store: AppViewModel) {
        self.store = store
        store.chatWebViewModel = self
        mermaidEnabled = store.preferencesMermaidEnabled
        katexEnabled = store.preferencesKatexEnabled
        interfaceScale = store.preferencesInterfaceScale
        webView?.pageZoom = CGFloat(interfaceScale / 100)
        debugEnabled = store.preferencesChatRendererDebugEnabled
        expandThinkingEnabled = store.preferencesExpandThinking
        expandToolUseEnabled = store.preferencesExpandToolUse
        observeTheme()
        // If the web view is already alive (e.g. re-bind on view reappear),
        // reload + push; otherwise it'll be created on first window placement.
        if webView != nil {
            loadPage()
            pushSnapshot()
        }
    }

    func unbind() {
        if store?.chatWebViewModel === self {
            store?.chatWebViewModel = nil
        }
        store = nil
    }

    /// Applies the chat interface scale immediately. Unlike the feature flags
    /// this does not need a page reload — WebKit updates the zoom in place.
    func setInterfaceScale(_ scale: Double) {
        interfaceScale = ChatFeaturesConfig.normalizedInterfaceScale(scale)
        webView?.pageZoom = CGFloat(interfaceScale / 100)
    }

    /// Reloads the web page with updated feature flags. Called when the
    /// Mermaid/KaTeX preferences change so the renderer loads (or skips) the
    /// corresponding bundles.
    func reload(mermaid: Bool, katex: Bool, debug: Bool, expandThinking: Bool, expandToolUse: Bool) {
        debugLog("Renderer", "reload — mermaid=\(mermaid), katex=\(katex), debug=\(debug), expandThinking=\(expandThinking), expandToolUse=\(expandToolUse)")
        mermaidEnabled = mermaid
        katexEnabled = katex
        debugEnabled = debug
        expandThinkingEnabled = expandThinking
        expandToolUseEnabled = expandToolUse
        // Reset bridge state so queued messages are flushed after re-ready.
        webReady = false
        enqueueRenderJob(.reset)
        loadPage()
    }

    // MARK: - Theme

    private func observeTheme() {
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
        // The role accent color is appearance-dependent (system colors resolve
        // differently per theme), so a theme change must re-push the snapshot
        // to deliver the re-resolved accent to the renderer.
        pushSnapshot()
    }

    // MARK: - Snapshot pushing

    /// Called whenever the store's published state changes. Captures the
    /// current chat state (cheap — arrays are COW value types) and hands it
    /// to `ChatRenderQueue`, which projects/diffs/encodes off the main actor
    /// and delivers the resulting JS back here in order.
    func pushSnapshot() {
        guard let store else { return }
        guard let item = store.selectedChatItem else { return }
        // If the chat is not loaded yet, there's nothing to render.
        guard let chat = item.chat else { return }

        ImageSchemeHandler.currentChatFilename = item.filename

        enqueueRenderJob(.snapshot(
            chatId: item.id,
            messages: chat.messages,
            isStreaming: item.isStreaming,
            roleName: item.effectiveRoleName,
            // The accent is appearance-dependent — never persisted; re-resolved
            // on theme change (see `pushTheme`).
            roleAccent: RoleAccent.hexColor(for: store.selectedRole?.config.accent)
        ))
    }

    /// Enqueues a render-queue job, preserving call order: unstructured tasks
    /// give no start-order guarantee, so each job chains onto the previous one.
    private func enqueueRenderJob(_ job: RenderJob) {
        let prev = renderQueueTail
        renderQueueTail = Task {
            await prev?.value
            await renderQueue.enqueue(job)
        }
    }

    // MARK: - Chat-switch overlay

    /// Starts the chat-switch handshake: covers the web view with the native
    /// overlay right away (the renderer's own spinner can't be relied on — it
    /// can only paint once the WebContent process finishes rendering the old
    /// chat), asks the renderer to blank itself, and arms the watchdog until
    /// the renderer reports `loaded` for the new chat.
    func beginChatSwitch(to chatId: String) {
        switchWatchdogTask?.cancel()
        pendingSwitchChatId = chatId
        switchOverlayVisible = true
        enqueueRenderJob(.unload)
        switchWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: ChatWebViewModel.switchWatchdogTimeout)
            guard !Task.isCancelled, let self, self.pendingSwitchChatId == chatId else { return }
            debugLog("Renderer", "watchdog: no loaded signal for \(chatId) — dismissing switch overlay")
            self.pendingSwitchChatId = nil
            self.switchOverlayVisible = false
        }
    }

    /// Aborts an in-flight switch handshake (selection became nil).
    func cancelChatSwitch() {
        switchWatchdogTask?.cancel()
        pendingSwitchChatId = nil
        switchOverlayVisible = false
    }

    /// The renderer finished rendering `chatId`'s first snapshot; dismiss the
    /// overlay if it's the chat we're waiting for. Stale reports (from an
    /// earlier switch or a webview restore) are ignored.
    private func handleRendererLoaded(_ chatId: String) {
        guard pendingSwitchChatId == chatId else { return }
        pendingSwitchChatId = nil
        switchWatchdogTask?.cancel()
        switchOverlayVisible = false
    }

    /// Forces a scroll-to-bottom in the web view (e.g. when the user sends a
    /// new message).
    func scrollToBottom() {
        sendHostMessage(.scrollToBottom)
    }

    /// Opens the in-chat search bar. Focuses the web view first so keystrokes
    /// land in the renderer's search input, then asks it to show the form.
    func startSearch() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        sendHostMessage(.startSearch)
    }

    // MARK: - JS communication

    /// Encodes and sends a small, order-independent host message (theme,
    /// scroll, search). Chat-content messages go through `renderQueue`
    /// instead, both for ordering and to keep encoding off the main actor.
    private func sendHostMessage(_ message: HostMessageData) {
        guard let js = ChatRenderQueue.encodeToJS(message) else { return }
        deliverJS(js)
    }

    /// Delivers a pre-encoded JS statement to the web view, or queues it for
    /// the post-`ready` flush when the page isn't up yet.
    private func deliverJS(_ js: String) {
        if !webReady {
            pendingMessages.append(js)
            return
        }
        guard let webView else { return }
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
            store.pendingEditMessageID = UUID(uuidString: messageId)
        case .delete(let messageId):
            store.pendingDeleteMessageID = UUID(uuidString: messageId)
        case .retry:
            store.retryLastMessage()
        case .scrollState(let atBottom):
            store.selectedChatAtBottom = atBottom
        case .ready:
            webReady = true
            for js in pendingMessages {
                webView?.evaluateJavaScript(js, completionHandler: nil)
            }
            pendingMessages.removeAll()
            enqueueRenderJob(.reset)
            pushSnapshot()
            pushTheme()
        case .loaded(let chatId):
            handleRendererLoaded(chatId)
        case .requestOlder:
            break
        case .allowToolCall(let callId):
            store.allowToolCall(callID: callId)
        case .allowToolCallForChat(let callId):
            store.allowToolCallForChat(callID: callId)
        case .denyToolCall(let callId):
            store.pendingDenyToolCallID = callId
        }
    }

    private func copyMessage(_ messageId: String) {
        guard let item = store?.selectedChatItem,
              let msg = item.chat?.messages.first(where: { $0.id.uuidString == messageId }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(msg.content, forType: .string)
    }
}

// MARK: - Bridge message handler

/// Intercepts link clicks in the chat renderer and opens external http(s)
/// URLs in the user's default system browser. The renderer marks links with
/// `target="_blank"`, so without this delegate the clicks are dropped silently.
/// In-page file loads and the custom `ichai://` image scheme are allowed
/// through unchanged.
private final class ChatWebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

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

    func makeNSView(context: Context) -> NSView {
        model.makeHostView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Push the latest snapshot whenever SwiftUI re-renders.
        model.pushSnapshot()
    }
}

/// Container view that hosts the `WKWebView` as a subview. Notifies the model
/// when it moves to a window so occlusion observers can be (re)attached.
final class ChatWebViewHostView: NSView {
    var onMoveToWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }
}

// MARK: - Wire types (Swift <-> JSON)

/// The JSON shape sent Swift -> JS. Matches `HostMessage` in types.ts.
enum HostMessageData: Codable, Sendable {
    case snapshot(snapshot: ChatSnapshotData)
    case streaming(chatId: String, isStreaming: Bool)
    case theme(theme: String)
    case scrollToBottom
    case startSearch
    /// Blank the renderer and show its spinner (chat switch in progress).
    case unload
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
        case .startSearch:
            try c.encode("startSearch", forKey: .type)
        case .unload:
            try c.encode("unload", forKey: .type)
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
        case "startSearch":
            self = .startSearch
        case "unload":
            self = .unload
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
enum BridgeMessageData: Codable, Sendable {
    case copy(messageId: String)
    case edit(messageId: String)
    case delete(messageId: String)
    case retry
    case scrollState(atBottom: Bool)
    case ready
    /// The renderer finished committing the first snapshot of `chatId` to the
    /// DOM — the host dismisses its chat-switch overlay in response.
    case loaded(chatId: String)
    case requestOlder(chatId: String)
    /// User approved a pending tool call (Allow button).
    case allowToolCall(callId: String)
    /// User approved a pending tool call and asked to auto-approve this tool
    /// for the rest of the chat (Allow for this chat button).
    case allowToolCallForChat(callId: String)
    /// User requested to deny a pending tool call (Deny button); the host
    /// presents a reason sheet before resolving.
    case denyToolCall(callId: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case messageId
        case atBottom
        case chatId
        case callId
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
        case .loaded(let chatId):
            try c.encode("loaded", forKey: .type)
            try c.encode(chatId, forKey: .chatId)
        case .requestOlder(let chatId):
            try c.encode("requestOlder", forKey: .type)
            try c.encode(chatId, forKey: .chatId)
        case .allowToolCall(let callId):
            try c.encode("allowToolCall", forKey: .type)
            try c.encode(callId, forKey: .callId)
        case .allowToolCallForChat(let callId):
            try c.encode("allowToolCallForChat", forKey: .type)
            try c.encode(callId, forKey: .callId)
        case .denyToolCall(let callId):
            try c.encode("denyToolCall", forKey: .type)
            try c.encode(callId, forKey: .callId)
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
        case "loaded":
            self = .loaded(chatId: try c.decode(String.self, forKey: .chatId))
        case "requestOlder":
            self = .requestOlder(chatId: try c.decode(String.self, forKey: .chatId))
        case "allowToolCall":
            self = .allowToolCall(callId: try c.decode(String.self, forKey: .callId))
        case "allowToolCallForChat":
            self = .allowToolCallForChat(callId: try c.decode(String.self, forKey: .callId))
        case "denyToolCall":
            self = .denyToolCall(callId: try c.decode(String.self, forKey: .callId))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type")
        }
    }
}

/// A chat snapshot sent to the web view.
struct ChatSnapshotData: Codable, Sendable {
    let chatId: String
    let messages: [ChatMessageData]
    let isStreaming: Bool
    /// The chat's role name (e.g. "Developer"), shown as the title of
    /// assistant messages. Nil when no role is set; the renderer falls back
    /// to "Assistant" in that case.
    let roleName: String?
    /// The role's accent color as an "#RRGGBB" hex string, resolved against
    /// the current appearance so it matches the active light/dark theme. Used
    /// to color the assistant message title. Appearance-dependent — must not be
    /// persisted; re-resolved on theme change.
    let roleAccent: String?
}

/// The JSON representation of a `ChatMessage` sent to the web view.
struct ChatMessageData: Codable, Equatable, Sendable {
    let id: String
    let role: String
    let content: String
    let thinking: String?
    let error: String?
    let timestamp: String
    let connectionName: String?
    /// Attachments on the message. Images are `ichai://` URLs the renderer
    /// loads via the custom scheme handler; documents carry metadata only
    /// (name, kind, status) — the extracted text body is never sent to the
    /// WebView. Nil/empty for messages without attachments.
    let attachments: [AttachmentData]?
    /// For assistant messages: tool calls issued by the model. Nil otherwise.
    let toolCalls: [ToolCallData]?
    /// For `tool`-role messages: the result of a tool call. Nil otherwise.
    /// Mutable so the view projection in `projectToolResults` can fold
    /// `tool`-role messages onto the preceding assistant message.
    var toolResults: [ToolResultData]?

    /// A single attachment reference for the wire protocol.
    struct AttachmentData: Codable, Equatable, Sendable {
        /// The kind: "image", "text", or "document".
        let kind: String
        /// For images: the `ichai://` URL the renderer uses as the `src`.
        /// For text/documents: nil (the body is never sent to the renderer).
        let url: String?
        /// Original filename for display/alt text.
        let name: String?
        /// Extraction status for text/document attachments: "ok",
        /// "truncated", or "failed". Nil for images.
        let status: String?
        /// Short failure reason when status is "failed". Nil otherwise.
        let failureReason: String?
    }

    /// A tool call issued by the assistant.
    struct ToolCallData: Codable, Equatable, Sendable {
        let id: String
        let name: String
        /// Raw JSON arguments string as returned by the model.
        let arguments: String
        /// True while the engine is waiting for the user to approve this call.
        /// Drives the renderer's Allow/Deny buttons.
        var pendingApproval: Bool = false
        /// Optional pre-rendered unified diff for `write_file`/`apply_patch`
        /// calls. When present, the renderer shows this diff instead of the
        /// raw arguments. Nil for tools that don't produce diffs.
        let diff: String?
        /// The tool schema's required argument names, used by the renderer to
        /// order the collapsed header's argument summary (required first) for
        /// tools it has no built-in knowledge of.
        let requiredArgs: [String]?
        /// True for in-process internal (Configurator) tools. Guards the
        /// renderer's per-tool syntax-highlighting hints against same-named
        /// external MCP tools.
        let internalTool: Bool
        /// The collapsed one-line argument summary, pre-computed by the
        /// engine. Nil for calls from before the field existed — the renderer
        /// computes it locally then.
        let summary: String?

        init(id: String, name: String, arguments: String, pendingApproval: Bool = false, diff: String? = nil, requiredArgs: [String]? = nil, internalTool: Bool = false, summary: String? = nil) {
            self.id = id
            self.name = name
            self.arguments = arguments
            self.pendingApproval = pendingApproval
            self.diff = diff
            self.requiredArgs = requiredArgs
            self.internalTool = internalTool
            self.summary = summary
        }
    }

    /// The result of executing a tool call.
    struct ToolResultData: Codable, Equatable, Sendable {
        let callID: String
        let content: String
        let isError: Bool
        /// True while the tool is still running and `content` is streaming in.
        let isStreaming: Bool
        /// True when the result is a user denial (not a tool failure). The
        /// renderer shows a "denied" badge instead of "error".
        let isDenied: Bool
        /// True when the result was synthesized on stop for a call that never
        /// executed. The renderer shows a "cancelled" badge instead of "error".
        let isCancelled: Bool
        /// The one-line status summary, pre-computed by the engine. Nil for
        /// results from before the field existed — the renderer computes it
        /// locally then.
        let summary: ToolSummary.Status?

        init(callID: String, content: String, isError: Bool, isStreaming: Bool, isDenied: Bool = false, isCancelled: Bool = false, summary: ToolSummary.Status? = nil) {
            self.callID = callID
            self.content = content
            self.isError = isError
            self.isStreaming = isStreaming
            self.isDenied = isDenied
            self.isCancelled = isCancelled
            self.summary = summary
        }
    }
}

/// Shared timestamp style for `ChatMessage.webData` — allocating a formatter
/// per message was a measurable cost when projecting large chats. A value
/// type (Sendable), and the output matches ISO8601DateFormatter with
/// `.withInternetDateTime` + `.withFractionalSeconds`.
private let webDataTimestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

extension ChatMessage {
    /// Converts a `ChatMessage` to its JSON wire representation.
    var webData: ChatMessageData {
        let attachments = attachments?.map { attachment in
            ChatMessageData.AttachmentData(
                kind: attachment.kind.rawValue,
                url: attachment.kind == .image
                    ? "\(ImageSchemeHandler.scheme)://\(attachment.filename)"
                    : nil,
                name: attachment.originalName,
                status: attachment.kind == .image ? nil : attachment.status.rawValue,
                failureReason: attachment.failureReason
            )
        }
        let toolCalls = toolCalls?.map {
            ChatMessageData.ToolCallData(id: $0.id, name: $0.name, arguments: $0.arguments, pendingApproval: $0.pendingApproval, diff: $0.diff, requiredArgs: $0.requiredArgs, internalTool: $0.internalTool, summary: $0.summary)
        }
        let toolResults = toolResults?.map {
            ChatMessageData.ToolResultData(callID: $0.callID, content: $0.content, isError: $0.isError, isStreaming: $0.isStreaming, isDenied: $0.isDenied, isCancelled: $0.isCancelled, summary: $0.summary)
        }
        return ChatMessageData(
            id: id.uuidString,
            role: role.rawValue,
            content: content,
            thinking: thinking,
            error: error,
            timestamp: timestamp.formatted(webDataTimestampStyle),
            connectionName: connectionName,
            attachments: attachments,
            toolCalls: toolCalls,
            toolResults: toolResults
        )
    }
}
