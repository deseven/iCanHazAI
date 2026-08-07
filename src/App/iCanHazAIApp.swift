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
        // Remove a stale control socket left behind by a crashed/killed
        // previous run. Probed first: a live socket (another running
        // instance) is never unlinked.
        CLIServer.removeStaleSocketIfNeeded(at: EnvironmentManager.shared.socketURL.path)
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
            // In headless mode (spawned by the CLI when no app instance was
            // running) startup proceeds normally — loader window included —
            // but the main window is not revealed. The dock icon still opens
            // it later via applicationShouldHandleReopen.
            let headless = CommandLine.arguments.contains("--headless")
            // Show the main window (unless headless) as soon as loading has
            // finished, and surface any configuration errors collected during
            // startup.
            LoaderController.shared.startupReadyHandler = {
                if headless {
                    debugLog("App", "headless start — main window not revealed")
                } else {
                    MainWindowController.shared.reveal()
                }
                if let vm = AppViewModel.shared, !vm.configErrors.isEmpty {
                    vm.showConfigErrors = true
                }
            }
            // Create the CLI control socket only once the loader has actually
            // hidden (after the 1-second results-display delay). A CLI that
            // spawned us treats the socket as the readiness signal — starting
            // it earlier let a script connect and flood the engine with tool
            // calls while the loader was still on screen.
            LoaderController.shared.startupHiddenHandler = {
                CLIServer.shared.start()
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
        debugLog("App", "applicationWillTerminate — closing control socket and disconnecting MCP servers")
        // Synchronous: closes the listener and unlinks the socket file so no
        // stale socket survives a normal quit.
        CLIServer.shared.stop()
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
    private var creationInFlight = false

    private init() {}

    /// Creates and shows the main window. Called from the loader's
    /// `startupReadyHandler` once loading is complete. No-op if the window
    /// already exists (e.g. user clicked the Dock icon while it was open).
    func reveal() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard !creationInFlight else { return }
        guard let store = AppViewModel.shared else {
            debugLog("App", "⚠️ reveal() — no AppViewModel available")
            return
        }

        // The config has already been loaded by the engine by the time
        // reveal() is called, so the await resolves immediately. Fetching the
        // saved frame BEFORE the window is created lets the window appear at
        // its final size — resizing an already-shown window re-distributes
        // the split view and stretches the sidebars beyond their saved widths.
        creationInFlight = true
        Task {
            defer { creationInFlight = false }
            let config = ConfigManager.shared
            await config.load()
            let savedWindow = await config.getWindow()

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
            trackWindowFrame(window)

            // The final frame must be the FIRST size the window ever gets:
            // the split view applies the saved sidebar widths on its first
            // layout pass and proportionally scales them on every later one,
            // so an intermediate resize (e.g. applyMinSize growing a small
            // default frame) would stretch the sidebars.
            if let savedWindow {
                let minimumFrameSize = window.frameRect(
                    forContentRect: NSRect(origin: .zero, size: Self.minWindowSize)
                ).size
                window.setFrame(
                    Self.restoredFrame(from: savedWindow, minimumFrameSize: minimumFrameSize, fallbackOrigin: window.frame.origin),
                    display: false
                )
            } else {
                // First launch: default to the minimum size, centered.
                window.setContentSize(Self.minWindowSize)
                window.center()
            }
            // Sets the min-size constraints only — the frame is already at or
            // above the minimum (restoredFrame clamps), so no resize happens.
            applyMinSize()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            debugLog("App", "main window shown — \(window.frame)")
        }
    }

    /// The frame to create the main window with, computed from the saved
    /// config. Sizes are clamped up to the minimum frame size; missing or
    /// invalid (non-finite, non-positive) sizes fall back to the minimum,
    /// missing/invalid positions keep `fallbackOrigin`.
    nonisolated static func restoredFrame(from saved: WindowConfig, minimumFrameSize: NSSize, fallbackOrigin: NSPoint) -> NSRect {
        var frame = NSRect(origin: fallbackOrigin, size: minimumFrameSize)
        if let x = saved.x, x.isFinite { frame.origin.x = x }
        if let y = saved.y, y.isFinite { frame.origin.y = y }
        if let width = saved.width, width.isFinite, width > 0 {
            frame.size.width = max(width, minimumFrameSize.width)
        }
        if let height = saved.height, height.isFinite, height > 0 {
            frame.size.height = max(height, minimumFrameSize.height)
        }
        return frame
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

    /// The minimum content size — also the default content size on first launch.
    static let minWindowSize = NSSize(width: 1024, height: 600)

    /// Applies the minimum window size. `contentMinSize` is the actual user
    /// constraint; the frame-level `minSize` includes the title bar and is
    /// derived from it. If a restored frame is below the minimum, the window
    /// grows to meet it.
    func applyMinSize() {
        guard let window else { return }
        window.contentMinSize = Self.minWindowSize
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: Self.minWindowSize)
        ).size
        window.minSize = minimumFrameSize

        if window.frame.width < minimumFrameSize.width || window.frame.height < minimumFrameSize.height {
            var frame = window.frame
            frame.size.width = max(frame.width, minimumFrameSize.width)
            frame.size.height = max(frame.height, minimumFrameSize.height)
            window.setFrame(frame, display: true)
        }
    }
}

/// The entry point is [`AppEntry`](src/App/Main.swift), which branches
/// between CLI mode and this SwiftUI app.
struct iCanHazAIApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var viewModel = AppViewModel()

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
                Button("Filter Chat List…") {
                    AppViewModel.shared?.focusChatListFilter()
                }
                .keyboardShortcut("f", modifiers: [.option, .command])
                Divider()
                Button("Stop Streaming") {
                    AppViewModel.shared?.stopStreaming()
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!viewModel.isStreaming)
                Button("Stop After Streaming") {
                    AppViewModel.shared?.stopStreamingAfterIteration()
                }
                .keyboardShortcut("b", modifiers: [.option, .command])
                .disabled(!viewModel.isStreaming || viewModel.stopAfterIterationPending)
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
                Button("New Temporary Chat…") {
                    AppViewModel.shared?.createNewTemporaryChat()
                }
                .keyboardShortcut("t", modifiers: [.option, .command])
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

    /// SwiftUI hosting can overwrite the window's min-size properties during
    /// layout, so enforce the floor in the resize delegate as well.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimumFrameSize = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: MainWindowController.minWindowSize)
        ).size
        return NSSize(
            width: max(frameSize.width, minimumFrameSize.width),
            height: max(frameSize.height, minimumFrameSize.height)
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
