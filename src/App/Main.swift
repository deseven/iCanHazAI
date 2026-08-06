// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Process entry point. The same binary serves two modes:
/// - launched via LaunchServices (Finder, `open`, Dock) → the SwiftUI app;
/// - executed directly from a shell → the CLI client (see
///   [`CLIClient.isCLIInvocation`](src/CLI/CLIClient.swift) for detection).
@main
enum AppEntry {
    static func main() async {
        // Ignore SIGPIPE so writing to a closed stdout (piped output whose
        // reader exited) or a dead socket fails gracefully instead of
        // terminating the process.
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        if CLIClient.isCLIInvocation(args) {
            exit(await CLIClient.run(args))
        }
        iCanHazAIApp.main()
    }
}
