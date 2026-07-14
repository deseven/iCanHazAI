// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AppKit

/// App delegate used to hook into application termination so we can tear down
/// MCP server connections (especially stdio subprocesses) cleanly. Without this,
/// force-quitting the app would orphan spawned MCP server processes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The app is single-window; disable automatic window tabbing so the
        // "Show Tab Bar" / "Show All Tabs" items disappear from the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Open ~/iCanHazAI/app.log (truncated) before anything else.
        DebugLogger.startFileLogging()
        // Load and decode config.toml synchronously, on this thread, BEFORE
        // any Task is spawned. This applies the debug-logging flag from the
        // very first log line and stashes the decoded config so the actor's
        // load() consumes it without re-reading the file — eliminating the
        // launch-time race where a mid-atomic-write read produced an empty
        // config that was later persisted as defaults (wiping user config).
        ConfigManager.bootstrapSynchronously()
        // Present the startup loader window immediately. At this point we've
        // read the main config and can enumerate what needs loading, so the
        // loader is seeded synchronously (Application column + MCPs column)
        // and completed as the engine emits load events. Runs on the main
        // thread during launch, so assume main-actor isolation.
        MainActor.assumeIsolated {
            LoaderWindowController.shared.present()
            // Reveal the main window only once the loader has finished loading
            // everything and its 1-second results display has started. Until
            // then the main window is kept invisible so the loader is the sole
            // thing on screen during boot.
            LoaderController.shared.startupReadyHandler = {
                MainWindowRevealer.shared.markReady()
            }
        }
        debugLog("App", "applicationWillFinishLaunching — starting engine")
        // Start the UI-free engine at launch so it outlives any window and
        // can later be driven by a CLI.
        Task { await ChatEngine.shared.start() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the SwiftUI main window the moment it exists (before the user
        // sees it) so only the loader is visible during boot. alphaValue (not
        // orderOut) keeps the window laid out so its `WindowAccessor` still
        // resolves and registers it. The loader panel is an NSPanel and is
        // left alone.
        MainActor.assumeIsolated {
            for window in NSApplication.shared.windows where !(window is NSPanel) {
                window.alphaValue = 0
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("App", "applicationWillTerminate — disconnecting MCP servers")
        Task { await MCPManager.shared.disconnectAll() }
        Task { await MCPManager.shared.disconnectAllInHouse() }
        DebugLogger.stopFileLogging()
    }
}

/// Coordinates revealing the main window after the startup loader finishes.
///
/// The main window is created (and laid out) at launch but kept at
/// `alphaValue = 0` so it isn't visible while the loader runs. The loader's
/// `startupReadyHandler` calls `markReady()` once everything has loaded and the
/// 1-second results display has begun; `register(_:)` is called by the window's
/// `WindowAccessor` once the `NSWindow` exists. Whichever signal arrives first
/// is held; the window is revealed only once both have occurred.
///
/// A 30-second safety fallback reveals the window even if the ready signal
/// never arrives (e.g. a stuck MCP), so the app is never left bricked behind
/// the loader.
@MainActor
final class MainWindowRevealer {
    static let shared = MainWindowRevealer()

    private var window: NSWindow?
    private var ready = false
    private var revealed = false
    private var fallbackTask: Task<Void, Never>?

    private init() {}

    /// Called from `WindowAccessor` once the main `NSWindow` is resolved.
    func register(_ window: NSWindow) {
        guard self.window == nil else { return }
        self.window = window
        scheduleFallbackIfNeeded()
        revealIfReady()
    }

    /// Called from `LoaderController.startupReadyHandler` when the loader's
    /// 1-second results display begins.
    func markReady() {
        ready = true
        revealIfReady()
    }

    private func revealIfReady() {
        guard ready, let window, !revealed else { return }
        revealed = true
        fallbackTask?.cancel()
        fallbackTask = nil
        debugLog("App", "MainWindowRevealer — revealing main window")
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1
        }
        self.window = nil
    }

    private func scheduleFallbackIfNeeded() {
        guard fallbackTask == nil else { return }
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard !self.revealed else { return }
            debugLog("App", "MainWindowRevealer — loader never signaled ready; revealing as fallback")
            self.ready = true
            self.revealIfReady()
        }
    }
}

@main
struct iCanHazAIApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var viewModel = AppViewModel()
    // Captured directly from the view hierarchy via `WindowAccessor` once the
    // main window exists, so later lookups don't need to guess which of
    // `NSApp.windows` is "the" window (the startup loader's borderless
    // `NSPanel` is also in that list and briefly ends up first).
    @State private var mainWindow: NSWindow?

    init() {
        // Ignore SIGPIPE so writing to a closed stdout (e.g. when launched
        // through a pipe) doesn't terminate the app.
        // Without this, the first debugLog print after the reader exits raises
        // SIGPIPE and crashes the app on startup.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(viewModel)
                .frame(minWidth: viewModel.chatInfoSidebarVisible ? 1050 : 860, minHeight: 500)
                .background(WindowAccessor { window in
                    guard mainWindow !== window else { return }
                    mainWindow = window
                    restoreWindowFrame(window)
                    trackWindowFrame(window)
                    applyMinSize(to: window)
                    // Keep the window invisible until the loader signals ready;
                    // `register` defers the key/order-front to the reveal.
                    window.alphaValue = 0
                    MainWindowRevealer.shared.register(window)
                })
                .onChange(of: viewModel.chatInfoSidebarVisible) { _, _ in
                    if let window = mainWindow {
                        applyMinSize(to: window)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .textEditing) {
                Button("New Chat") {
                    AppViewModel.shared?.createNewChat()
                }
                .keyboardShortcut("t", modifiers: .command)
                Button("Find in Chat…") {
                    AppViewModel.shared?.startSearchInChat()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    PreferencesView.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Role") {
                Button("Roles: \(viewModel.roles.count)") {}
                    .disabled(true)
                Button("Prompts: \(viewModel.prompts.count)") {}
                    .disabled(true)
                Divider()
                Button("Reveal Roles in Finder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([EnvironmentManager.shared.rolesURL])
                }
                Button("Reveal Prompts in Finder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([EnvironmentManager.shared.promptsURL])
                }
            }

            CommandMenu("Connection") {
                Button("Connections: \(viewModel.connections.count)") {}
                    .disabled(true)
                Button("Reveal Connections in Finder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([EnvironmentManager.shared.connectionsURL])
                }
                Divider()
                Button("New Connection…") {
                    ConnectionWizardView.show(onFinish: { AppViewModel.shared?.refreshAfterWizard() })
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("MCP") {
                Button("MCP Servers: \(viewModel.mcps.count)") {}
                    .disabled(true)
                Button("Reinitialize MCP Servers…") {
                    AppViewModel.shared?.reloadMCPs()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Reveal MCP Servers in Finder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([EnvironmentManager.shared.mcpsURL])
                }
                Divider()
                Button("New MCP Server…") {
                    MCPWizardView.show(onFinish: { AppViewModel.shared?.refreshPreferences() })
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - Window frame persistence

    /// Applies the saved window position/size from config (if present).
    private func restoreWindowFrame(_ window: NSWindow) {
        Task {
            let config = ConfigManager.shared
            await config.load()
            guard let wc = await config.getWindow() else { return }
            var frame = window.frame
            var changed = false
            if let x = wc.x { frame.origin.x = x; changed = true }
            if let y = wc.y { frame.origin.y = y; changed = true }
            if let width = wc.width { frame.size.width = width; changed = true }
            if let height = wc.height { frame.size.height = height; changed = true }
            if changed {
                await MainActor.run {
                    window.setFrame(frame, display: true)
                }
            }
        }
    }

    /// Starts tracking the window's frame changes with a 500 ms debounce,
    /// writing the updated `[window]` section to the config file.
    private func trackWindowFrame(_ window: NSWindow) {
        let config = ConfigManager.shared
        var debounceTask: Task<Void, Never>?

        let tracker = WindowFrameTracker { frame in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let wc = WindowConfig(x: frame.origin.x, y: frame.origin.y,
                                      width: frame.size.width, height: frame.size.height)
                await config.setWindow(wc)
            }
        }
        objc_setAssociatedObject(window, "frameTracker", tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        tracker.attach(to: window)
    }

    /// Applies the minimum window size based on whether the chat info sidebar
    /// is visible. If the current width is below the new minimum, the window
    /// is widened to meet it.
    private func applyMinSize(to window: NSWindow) {
        let minWidth: CGFloat = viewModel.chatInfoSidebarVisible ? 1050 : 860
        var minSize = window.minSize
        minSize.width = minWidth
        minSize.height = 500
        window.minSize = minSize

        if window.frame.width < minWidth {
            var frame = window.frame
            let delta = minWidth - frame.width
            frame.size.width = minWidth
            // Keep the left edge anchored so the window grows to the right.
            frame.origin.x -= delta
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: - Window frame tracking delegate

/// Observes `NSWindow` frame changes (resize and move) and calls a callback
/// with the new frame. Uses `NSWindowDelegate` and `NSViewFrameDidChangeNotification`.
/// All methods are `@MainActor` since NSWindow is main-actor isolated.
@MainActor
private final class WindowFrameTracker: NSObject, NSWindowDelegate {
    private let onFrameChange: (NSRect) -> Void
    private weak var window: NSWindow?

    init(onFrameChange: @escaping (NSRect) -> Void) {
        self.onFrameChange = onFrameChange
    }

    func attach(to window: NSWindow) {
        self.window = window
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSWindow.didMoveNotification,
            object: window
        )
    }

    @objc private func frameDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onFrameChange(window.frame)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Window accessor

/// Bridges to the actual `NSWindow` hosting this SwiftUI view by reading
/// `NSView.window` off the injected `NSView`, instead of guessing which entry
/// in `NSApp.windows` is "the" main window — a guess that silently picked the
/// startup loader's borderless `NSPanel` instead, since it's created (and
/// thus registered) before this window exists.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            onResolve(window)
        }
    }
}
