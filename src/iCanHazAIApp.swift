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
        debugLog("App", "applicationWillFinishLaunching — starting engine")
        // Start the UI-free engine at launch so it outlives any window and
        // can later be driven by a CLI.
        Task { await ChatEngine.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("App", "applicationWillTerminate — disconnecting MCP servers")
        Task { await MCPManager.shared.disconnectAll() }
        Task { await MCPManager.shared.disconnectAllInHouse() }
        DebugLogger.stopFileLogging()
    }
}

@main
struct iCanHazAIApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var viewModel = AppViewModel()

    init() {}

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(viewModel)
                .frame(minWidth: viewModel.chatInfoSidebarVisible ? 1050 : 860, minHeight: 500)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let window = NSApplication.shared.windows.first(where: { $0.contentViewController is NSHostingController<AnyView> }) ?? NSApplication.shared.windows.first {
                        window.makeKeyAndOrderFront(nil)
                        restoreWindowFrame(window)
                        trackWindowFrame(window)
                        applyMinSize(to: window)
                    }
                }
                .onChange(of: viewModel.chatInfoSidebarVisible) { _, _ in
                    if let window = NSApplication.shared.windows.first(where: { $0.contentViewController is NSHostingController<AnyView> }) ?? NSApplication.shared.windows.first {
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
