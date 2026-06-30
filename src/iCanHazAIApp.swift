// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AppKit

/// App delegate used to hook into application termination so we can tear down
/// MCP server connections (especially stdio subprocesses) cleanly. Without this,
/// force-quitting the app would orphan spawned MCP server processes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Start the UI-free engine at launch so it outlives any window and
        // can later be driven by a CLI.
        Task { await ChatEngine.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Disconnect all MCP servers (terminates stdio subprocesses) so we
        // don't leave orphaned processes behind on quit.
        Task { await MCPManager.shared.disconnectAll() }
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
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    // Ensure the main window is brought to front immediately on launch.
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let window = NSApplication.shared.windows.first(where: { $0.contentViewController is NSHostingController<AnyView> }) ?? NSApplication.shared.windows.first {
                        window.makeKeyAndOrderFront(nil)
                        restoreWindowFrame(window)
                        trackWindowFrame(window)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Replace the default "New Window" item (Cmd+N) to prevent
            // creating multiple main windows.
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    AppViewModel.shared?.createNewChat()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("New Chat") {
                    AppViewModel.shared?.createNewChat()
                }
                .keyboardShortcut("t", modifiers: .command)
                Button("New Connection...") {
                    ConnectionWizardView.show(onFinish: { AppViewModel.shared?.refreshAfterWizard() })
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New MCP Server...") {
                    MCPWizardView.show(onFinish: { AppViewModel.shared?.refreshPreferences() })
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    PreferencesView.show()
                }
                .keyboardShortcut(",", modifiers: .command)
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

        // Use a dedicated delegate object to intercept resize/move events.
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
        // Keep the tracker alive by associating it with the window.
        objc_setAssociatedObject(window, "frameTracker", tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        tracker.attach(to: window)
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
        // Also observe live resize notifications since the delegate's
        // `windowDidResize` only fires after resize ends.
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
