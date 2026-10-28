// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What a path holds right now.
enum FileRead: Equatable, Sendable {
    case missing
    case directory
    case data(Data)
}

/// The only place the patch pipeline touches a filesystem, so local and SSH
/// workdirs share one implementation of `edit_file` (see
/// [`HashlinePatcher`](src/Tools/Hashline/HashlinePatcher.swift)). `resolved`
/// arguments are outputs of `resolve`. Failures are thrown as
/// `BuiltinToolError`s whose text is safe to show the model.
protocol FileAccess: Sendable {
    /// `Workdir.resolve`: jail check and normalization, no filesystem access.
    func resolve(_ path: String) throws -> String
    /// The spelling shown to the model (jail-relative when isolated).
    func displayPath(_ resolved: String) -> String
    /// Identity in the model's file views (see `FileViewState`).
    func key(_ resolved: String) -> FileKey
    /// Whether two resolved paths are the same file, for telling apart
    /// differently spelled paths and symlinks: `key` deliberately leaves the
    /// last component unresolved.
    func identity(_ resolved: String) -> String
    func read(_ resolved: String) async throws -> FileRead
    /// Also true for a dangling symlink: something occupies the path.
    func exists(_ resolved: String) async throws -> Bool
    /// Overwrites an existing file in place, keeping its inode, permissions
    /// and extended attributes.
    func write(_ resolved: String, _ data: Data) async throws
    /// Writes a new file, creating missing parent directories.
    func create(_ resolved: String, _ data: Data) async throws
    func delete(_ resolved: String) async throws
}

extension Workdir {
    /// The `FileAccess` for this workdir: remote over SSH, or the local
    /// filesystem. A malformed SSH root is an error, as for the other tools.
    func fileAccess() throws -> any FileAccess {
        if let ssh { return SSHFileAccess(workdir: self, ssh: ssh) }
        if let sshSpecError { throw BuiltinToolError(sshSpecError) }
        return LocalFileAccess(workdir: self)
    }
}

struct LocalFileAccess: FileAccess {
    let workdir: Workdir

    func resolve(_ path: String) throws -> String { try workdir.resolve(path) }

    func displayPath(_ resolved: String) -> String { workdir.displayPath(forResolved: resolved) }

    func key(_ resolved: String) -> FileKey { .local(resolved: resolved) }

    func identity(_ resolved: String) -> String { BuiltinTools.canonicalPath(resolved) }

    func read(_ resolved: String) async throws -> FileRead {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else { return .missing }
        if isDir.boolValue { return .directory }
        guard let data = fm.contents(atPath: resolved) else {
            throw BuiltinToolError("could not read \(displayPath(resolved))")
        }
        return .data(data)
    }

    func exists(_ resolved: String) async throws -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: resolved)) != nil
    }

    func write(_ resolved: String, _ data: Data) async throws {
        try scrubbing { try data.write(to: URL(fileURLWithPath: resolved)) }
    }

    func create(_ resolved: String, _ data: Data) async throws {
        try scrubbing {
            try FileManager.default.createDirectory(
                atPath: (resolved as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: resolved))
        }
    }

    func delete(_ resolved: String) async throws {
        try scrubbing { try FileManager.default.removeItem(atPath: resolved) }
    }

    /// Cocoa errors can embed resolved paths; in isolated mode the workdir
    /// root must not leak through them.
    private func scrubbing(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            var message = error.localizedDescription
            if workdir.isolated, let root = workdir.root {
                message = message.replacingOccurrences(of: root, with: "")
            }
            throw BuiltinToolError(message)
        }
    }
}
