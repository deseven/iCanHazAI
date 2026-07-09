// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A lightweight, opt-in debug logging facility for the app.
///
/// The single entry point is [`debugLog(topic:message:)`](src/DebugLogger.swift)
/// (or the free-function shorthand [`debugLog(_:_:)`](src/DebugLogger.swift)).
/// When "App Debug Logging" is disabled (the default) every call is a no-op,
/// so sprinkling `debugLog` calls throughout the codebase has zero cost in
/// production builds.
///
/// Output is written to stdout formatted as
/// `[YYYY-MM-DD hh:mm:ss] [topic] message`. The timestamp uses the user's
/// local time zone for readability.
///
/// In addition to stdout, output is duplicated to `~/iCanHazAI/app.log` when
/// [`DebugLogger.startFileLogging()`](src/DebugLogger.swift) has been called.
/// This is essential for diagnosing issues that only reproduce when the app is
/// launched from Finder (where stdout is discarded). The file is truncated on
/// each launch so it only contains the current session.
///
/// The enabled flag is cached behind a `DispatchQueue`-protected box so that
/// `debugLog` can be called from any thread/actor without hopping to
/// `ConfigManager`. The flag is refreshed by
/// [`DebugLogger.setEnabled(_:)`](src/DebugLogger.swift) whenever preferences
/// are loaded or toggled.
enum DebugLogger {

    /// A small lock-protected box holding the mutable enabled flag. Using a
    /// class instance with a serial queue satisfies Swift's concurrency
    /// checker for shared mutable global state.
    private final class FlagBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "iCanHazAI.debugLogger.flag")
        private var _enabled = false

        func get() -> Bool { queue.sync { _enabled } }
        func set(_ value: Bool) { queue.sync { _enabled = value } }
    }

    private static let flagBox = FlagBox()

    /// Thread-safe accessor for the enabled flag.
    static var enabled: Bool {
        get { flagBox.get() }
        set { flagBox.set(newValue) }
    }

    /// Updates the cached enabled flag. Called by `AppViewModel` after
    /// loading preferences or when the user toggles the switch.
    static func setEnabled(_ value: Bool) {
        enabled = value
    }

    /// The shared date formatter used to produce `[YYYY-MM-DD hh:mm:ss]`.
    /// Configured for the user's local time zone. `DateFormatter` is
    /// documented as thread-safe in modern Foundation, but we guard access
    /// with a queue to be safe across concurrent callers.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
    private static let formatterQueue = DispatchQueue(label: "iCanHazAI.debugLogger.formatter")

    // MARK: - File logging

    /// A lock-protected box holding the open log file handle. Mirrors the
    /// `FlagBox` pattern so the mutable state satisfies Swift's concurrency
    /// checker. All access is serialized on `fileQueue`.
    private final class FileBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "iCanHazAI.debugLogger.file")
        private var _handle: FileHandle?

        func get() -> FileHandle? { queue.sync { _handle } }
        func set(_ value: FileHandle?) { queue.sync { _handle = value } }
    }

    private static let fileBox = FileBox()

    /// Opens (and truncates) `~/iCanHazAI/app.log` for appending. Safe to
    /// call before the enabled flag is known — the file is opened regardless
    /// so that early log lines are captured even if logging is later turned on.
    /// Must be called once at launch, before any `debugLog` call that should
    /// reach the file.
    static func startFileLogging() {
        // Already open.
        if fileBox.get() != nil { return }
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let rootURL = homeURL.appendingPathComponent("iCanHazAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = rootURL.appendingPathComponent("app.log", isDirectory: false)
        // Truncate on open so each session starts fresh.
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        // Move to end so subsequent writes append.
        try? handle.seekToEnd()
        fileBox.set(handle)
    }

    /// Closes the log file, if open. Called on app termination.
    static func stopFileLogging() {
        if let handle = fileBox.get() {
            try? handle.close()
        }
        fileBox.set(nil)
    }

    /// The single entry point for debug logging.
    ///
    /// Example:
    /// ```swift
    /// debugLog("MCP", "stdio server Example started")
    /// // [2026-06-30 18:25:18] [MCP] stdio server Example started
    /// ```
    ///
    /// Silently returns when app debug logging is disabled.
    static func debugLog(topic: String, message: String) {
        guard enabled else { return }
        let stamp = formatterQueue.sync { formatter.string(from: Date()) }
        let line = "[\(stamp)] [\(topic)] \(message)\n"
        // stdout is cheap; do it inline.
        print(line, terminator: "")
        // File I/O is dispatched off-thread.
        let handle = fileBox.get()
        guard let handle else { return }
        DispatchQueue.global(qos: .utility).async {
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}

/// Free-function shorthand so call sites read like the spec:
/// `debugLog("MCP", "stdio server Example started")`.
func debugLog(_ topic: String, _ message: String) {
    DebugLogger.debugLog(topic: topic, message: message)
}
