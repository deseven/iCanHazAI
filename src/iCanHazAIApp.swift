// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import Textual

@main
struct iCanHazAIApp: App {
    @StateObject private var viewModel = AppViewModel()

    init() {
        // Start the UI-free engine at launch so it outlives any window and
        // can later be driven by a CLI.
        Task { await ChatEngine.shared.start() }
    }

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
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
