// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import FSEventsWrapper

/// Watches the app's environment directories (chats, roles, connections) using FSEvents
/// and notifies a callback when any of them change.
final class EnvironmentWatcher: @unchecked Sendable {

    /// The area of the environment that changed.
    enum Area: String, Sendable {
        case chats
        case roles
        case connections
    }

    private var streams: [FSEventStream] = []
    private let onChange: @Sendable (Area) -> Void

    /// Creates a watcher for the given directory paths.
    /// - Parameters:
    ///   - paths: Mapping of watched absolute paths to the area they represent.
    ///   - onChange: Called on the main thread with the area that changed.
    init(paths: [(path: String, area: Area)], onChange: @escaping @Sendable (Area) -> Void) {
        self.onChange = onChange

        for (path, area) in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let stream = FSEventStream(
                path: path,
                updateInterval: 0.5,
                fsEventStreamFlags: FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot),
                callback: { _, _ in
                    // Any event in this directory means we should reload the area.
                    DispatchQueue.main.async {
                        onChange(area)
                    }
                }
            ) else { continue }
            streams.append(stream)
        }
    }

    deinit {
        stop()
    }

    func start() {
        for stream in streams {
            stream.startWatching()
        }
    }

    func stop() {
        for stream in streams {
            stream.stopWatching()
        }
    }
}
