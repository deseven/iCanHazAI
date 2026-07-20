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
        //
        // The main window is NOT created at launch — only the loader is
        // visible during boot. The main window is created by
        // MainWindowController.reveal() once the loader signals ready. The UI
        // is fully detached from the loading process (ChatEngine is a
        // singleton actor; the view model subscribes to its events and
        // populates @Published properties incrementally), so the window can
        // be created the instant loading completes.
        MainActor.assumeIsolated {
            LoaderWindowController.shared.present()
            // Create and show the main window once the loader has finished
            // loading everything and its 1-second results display has begun.
            // Also surface any configuration errors collected during startup.
            LoaderController.shared.startupReadyHandler = {
                MainWindowController.shared.reveal()
                if let vm = AppViewModel.shared, !vm.configErrors.isEmpty {
                    vm.showConfigErrors = true
                }
            }
        }
        debugLog("App", "applicationWillFinishLaunching — starting engine")
        // Start the UI-free engine at launch so it outlives any window and
        // can later be driven by a CLI.
        Task { await ChatEngine.shared.start() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nothing to do — the main window is created on demand by
        // MainWindowController.reveal() once loading completes.
    }

    /// Reopens the main window when the user clicks the Dock icon and no
    /// main window exists (e.g. it was closed). The engine keeps running
    /// regardless, so this just brings the UI back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated {
                MainWindowController.shared.reveal()
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("App", "applicationWillTerminate — disconnecting MCP servers")
        Task { await MCPManager.shared.disconnectAll() }
        DebugLogger.stopFileLogging()
    }
}

/// Creates and owns the main window. Unlike the previous design (which used
/// SwiftUI's `WindowGroup` to auto-create the window at launch and then hid/
/// revealed it via fragile coordination), this creates the `NSWindow` manually
/// — exactly when loading is done — using the same `NSHostingController` pattern
/// the wizard windows already use. No hiding, no fallback, no coordination: the
/// window simply doesn't exist until `reveal()` is called.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?
    private var frameTracker: WindowFrameTracker?

    private init() {}

    /// Creates and shows the main window. Called from the loader's
    /// `startupReadyHandler` once loading is complete. No-op if the window
    /// already exists (e.g. user clicked the Dock icon while it was open).
    func reveal() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let store = AppViewModel.shared else {
            debugLog("App", "⚠️ reveal() — no AppViewModel available")
            return
        }

        let mainView = MainWindow()
            .environmentObject(store)
        let hosting = NSHostingController(rootView: mainView)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        self.window = window

        debugLog("App", "creating main window")
        applyMinSize(to: window, sidebarVisible: store.chatInfoSidebarVisible)
        trackWindowFrame(window)

        // Restore the saved frame, then show the window. The config has
        // already been loaded by the engine at this point, so the actor
        // calls return immediately (one run-loop hop). Showing after the
        // frame is restored avoids a flash of a tiny default-sized window.
        Task {
            let config = ConfigManager.shared
            await config.load()
            if let wc = await config.getWindow() {
                var frame = window.frame
                if let x = wc.x { frame.origin.x = x }
                if let y = wc.y { frame.origin.y = y }
                if let width = wc.width { frame.size.width = width }
                if let height = wc.height { frame.size.height = height }
                window.setFrame(frame, display: true)
            } else {
                window.center()
            }
            // Re-apply min size after frame restoration in case the saved
            // frame was smaller than the current minimum.
            applyMinSize(to: window, sidebarVisible: store.chatInfoSidebarVisible)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            debugLog("App", "main window shown — \(window.frame)")
        }
    }

    // MARK: - Window frame persistence

    /// Starts tracking the window's frame changes with a 500 ms debounce,
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
        frameTracker = tracker
        tracker.attach(to: window)
    }

    /// Applies the minimum window size based on whether the chat info sidebar
    /// is visible. If the current width is below the new minimum, the window
    /// is widened to meet it. Called at creation and when sidebar visibility
    /// changes.
    func applyMinSize(sidebarVisible: Bool? = nil) {
        guard let window else { return }
        let visible = sidebarVisible ?? AppViewModel.shared?.chatInfoSidebarVisible ?? false
        applyMinSize(to: window, sidebarVisible: visible)
    }

    private func applyMinSize(to window: NSWindow, sidebarVisible: Bool) {
        let minWidth: CGFloat = sidebarVisible ? 1050 : 860
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

@main
struct iCanHazAIApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var viewModel = AppViewModel()

    init() {
        // Ignore SIGPIPE so writing to a closed stdout (e.g. when launched
        // through a pipe) doesn't terminate the app.
        // Without this, the first debugLog print after the reader exits raises
        // SIGPIPE and crashes the app on startup.
        signal(SIGPIPE, SIG_IGN)
    }

    // The `Settings` scene carries `.commands` without auto-creating a window
    // at launch. The main window is created on demand by MainWindowController
    // once the startup loader finishes. The Settings window itself never opens
    // because we replace the `.appSettings` command group with our own
    // Preferences button.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .textEditing) {
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
                Button("Reveal MCP Servers in Finder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([EnvironmentManager.shared.mcpsURL])
                }
                Button("Reinitialize MCP Servers…") {
                    AppViewModel.shared?.reloadMCPs()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("New MCP Server…") {
                    MCPWizardView.show(onFinish: { AppViewModel.shared?.refreshPreferences() })
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            CommandMenu("Prompt") {
                Button("Prompts: \(viewModel.prompts.count)") {}
                    .disabled(true)
                Button("Reveal Prompts in Finder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([EnvironmentManager.shared.promptsURL])
                }
            }

            CommandMenu("Role") {
                Button("Roles: \(viewModel.roles.count)") {}
                    .disabled(true)
                Button("Reveal Roles in Finder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([EnvironmentManager.shared.rolesURL])
                }
            }

            CommandMenu("Chat") {
                Button("Chats: \(viewModel.chatItems.count)") {}
                    .disabled(true)
                Button("Reveal Chats in Finder…") {
                    NSWorkspace.shared.activateFileViewerSelecting([EnvironmentManager.shared.chatsURL])
                }
                Divider()
                Button("New Chat…") {
                    AppViewModel.shared?.createNewChat()
                }
                .keyboardShortcut("t", modifiers: .command)
            }
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
