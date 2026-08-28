// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A lightweight debug logging facility for the app.
///
/// The single entry point is [`debugLog(topic:message:)`](src/Utilities/DebugLogger.swift)
/// (or the free-function shorthand [`debugLog(_:_:)`](src/Utilities/DebugLogger.swift)).
///
/// Every call is written to `~/iCanHazAI/app.log` (once
/// [`DebugLogger.startFileLogging()`](src/Utilities/DebugLogger.swift) has been called),
/// regardless of the "App Debug" preference. This is essential for diagnosing
/// issues that only reproduce when the app is launched from Finder (where
/// stdout is discarded). The file is truncated on each launch so it only
/// contains the current session.
///
/// When "App Debug Logging" is enabled, output is additionally mirrored to
/// stdout as `[YYYY-MM-DD hh:mm:ss] [topic] message`. The timestamp uses the
/// user's local time zone for readability.
///
/// When app debug logging is enabled,
/// [`DebugLogger.recordLastRequest(_:)`](src/Utilities/DebugLogger.swift) additionally
/// overwrites `~/iCanHazAI/last_request.log` with a complete dump of the most
/// recent LLM request — every header and byte sent and received.
///
/// The enabled flag is cached behind a `DispatchQueue`-protected box so that
/// `debugLog` can be called from any thread/actor without hopping to
/// `ConfigManager`. The flag is refreshed by
/// [`DebugLogger.setEnabled(_:)`](src/Utilities/DebugLogger.swift) whenever preferences
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

    /// Tracks the URL of the currently open log file (mirrors `fileBox`) so
    /// tests can read back what was written.
    private final class URLBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "iCanHazAI.debugLogger.url")
        private var _url: URL?
        func get() -> URL? { queue.sync { _url } }
        func set(_ value: URL?) { queue.sync { _url = value } }
    }
    private static let urlBox = URLBox()

    /// The URL of the currently open log file, if any. Exposed for tests.
    static var currentLogFileURL: URL? { urlBox.get() }

    /// Tracks the URL of `last_request.log` (mirrors `urlBox`). Unlike
    /// `app.log` it isn't kept open — every
    /// [`recordLastRequest(_:)`](src/Utilities/DebugLogger.swift) call overwrites the
    /// file wholesale.
    private final class RequestFileBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "iCanHazAI.debugLogger.requestFile")
        private var _url: URL?
        func get() -> URL? { queue.sync { _url } }
        func set(_ value: URL?) { queue.sync { _url = value } }
    }
    private static let requestFileBox = RequestFileBox()

    /// Serializes `last_request.log` overwrites so concurrent requests settle
    /// in completion order — the request that finishes last always wins.
    private static let requestWriteQueue = DispatchQueue(label: "iCanHazAI.debugLogger.requestWrite")

    /// The URL of `last_request.log`, if file logging has been started.
    /// Exposed for tests.
    static var currentRequestLogFileURL: URL? { requestFileBox.get() }

    /// Opens (and truncates) `~/iCanHazAI/app.log` for appending. Safe to
    /// call before the enabled flag is known — the file is opened regardless
    /// so that early log lines are captured even if logging is later turned on.
    /// Must be called once at launch, before any `debugLog` call that should
    /// reach the file.
    static func startFileLogging() {
        startFileLogging(rootURL: EnvironmentManager.shared.rootURL)
    }

    /// Internal entry point that allows tests to redirect the log into a
    /// throwaway directory. Opens (and truncates) `app.log` inside `rootURL`.
    static func startFileLogging(rootURL: URL) {
        // Already open.
        if fileBox.get() != nil { return }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = rootURL.appendingPathComponent("app.log", isDirectory: false)
        // Truncate on open so each session starts fresh.
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        // Move to end so subsequent writes append.
        _ = try? handle.seekToEnd()
        fileBox.set(handle)
        urlBox.set(url)
        // `last_request.log` is created (truncated) alongside `app.log`; it is
        // overwritten wholesale by recordLastRequest per request.
        let requestURL = rootURL.appendingPathComponent("last_request.log", isDirectory: false)
        FileManager.default.createFile(atPath: requestURL.path, contents: nil, attributes: nil)
        requestFileBox.set(requestURL)
    }

    /// Closes the log file, if open. Called on app termination.
    static func stopFileLogging() {
        if let handle = fileBox.get() {
            try? handle.close()
        }
        fileBox.set(nil)
        urlBox.set(nil)
        requestFileBox.set(nil)
    }

    /// The single entry point for debug logging.
    ///
    /// Example:
    /// ```swift
    /// debugLog("MCP", "stdio server Example started")
    /// // [2026-06-30 18:25:18] [MCP] stdio server Example started
    /// ```
    ///
    /// The line is always written to `app.log` (when file logging has been
    /// started). Stdout mirroring only happens when app debug logging is
    /// enabled.
    static func debugLog(topic: String, message: String) {
        let stamp = formatterQueue.sync { formatter.string(from: Date()) }
        let line = "[\(stamp)] [\(topic)] \(message)\n"
        // stdout is cheap; do it inline, but only when enabled.
        if enabled {
            print(line, terminator: "")
        }
        // File I/O is dispatched off-thread and always happens.
        let handle = fileBox.get()
        guard let handle else { return }
        DispatchQueue.global(qos: .utility).async {
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    // MARK: - Last request capture

    /// Overwrites `last_request.log` with a complete dump of the most recent
    /// LLM request (see [`LLMTransport.requestDump`](src/LLM/LLMTransport.swift)).
    /// Only writes when app debug logging is enabled — the file is a debugging
    /// aid, not a permanent record. Writes are serialized on a dedicated queue
    /// so concurrent requests settle in completion order.
    static func recordLastRequest(_ dump: String) {
        guard enabled else { return }
        let url = requestFileBox.get()
        guard let url else { return }
        requestWriteQueue.async {
            try? dump.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }
}

/// Free-function shorthand so call sites read like the spec:
/// `debugLog("MCP", "stdio server Example started")`.
func debugLog(_ topic: String, _ message: String) {
    DebugLogger.debugLog(topic: topic, message: message)
}
