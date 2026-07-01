// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import FSEventsWrapper

/// Watches the app's environment tree (`~/iCanHazAI`) with a single FSEvents
/// stream and forwards the full decoded `FSEvent` (path + type) to a callback.
///
/// Routing by path and event type is done by the engine, not here — this class
/// is a thin transport. FSEvents watches recursively: events for all files in
/// all subdirectories bubble up to the watched root, and each event carries
/// the full path of the affected file.
final class EnvironmentWatcher: @unchecked Sendable {

    private var stream: FSEventStream?
    private let onEvent: @Sendable (FSEvent) -> Void

    /// Creates a watcher for the given root directory path.
    /// - Parameters:
    ///   - rootPath: Absolute path of the directory to watch recursively.
    ///   - onEvent: Called (on a background queue) with each decoded `FSEvent`.
    init(rootPath: String, onEvent: @escaping @Sendable (FSEvent) -> Void) {
        self.onEvent = onEvent
        guard FileManager.default.fileExists(atPath: rootPath) else {
            debugLog("FSEvents", "watch root does not exist: \(rootPath)")
            return
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let s = FSEventStream(
            path: rootPath,
            updateInterval: 0.1,
            fsEventStreamFlags: flags,
            callback: { _, event in
                onEvent(event)
            }
        ) else {
            debugLog("FSEvents", "failed to create stream for \(rootPath)")
            return
        }
        self.stream = s
    }

    deinit {
        debugLog("FSEvents", "stream stop (deinit)")
        stream?.stopWatching()
    }

    func start() {
        debugLog("FSEvents", "stream start")
        stream?.startWatching()
    }
}
