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
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        // Extract --maindir (GUI-only) before anything else so it doesn't
        // trip CLI option parsing. Applied only when staying in GUI mode.
        let (args, mainDir) = extractMainDir(rawArgs)
        if CLIClient.isCLIInvocation(args) {
            exit(await CLIClient.run(args))
        }
        if let mainDir {
            EnvironmentManager.mainDirOverride = URL(
                fileURLWithPath: (mainDir as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        iCanHazAIApp.main()
    }

    /// Extracts and removes `--maindir <path>` (or `--maindir=<path>`) from the
    /// argument list. Returns the cleaned args and the override path (if any).
    static func extractMainDir(_ args: [String]) -> (args: [String], mainDir: String?) {
        var cleaned: [String] = []
        var mainDir: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--maindir" {
                if i + 1 < args.count {
                    mainDir = args[i + 1]
                    i += 2
                    continue
                }
            } else if arg.hasPrefix("--maindir=") {
                mainDir = String(arg.dropFirst("--maindir=".count))
            }
            cleaned.append(arg)
            i += 1
        }
        return (cleaned, mainDir)
    }
}
