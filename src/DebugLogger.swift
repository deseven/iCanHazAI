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
        print("[\(stamp)] [\(topic)] \(message)")
    }
}

/// Free-function shorthand so call sites read like the spec:
/// `debugLog("MCP", "stdio server Example started")`.
func debugLog(_ topic: String, _ message: String) {
    DebugLogger.debugLog(topic: topic, message: message)
}