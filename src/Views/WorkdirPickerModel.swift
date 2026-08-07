// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One row in the working-directory picker. All cases carry the path/spec
/// that gets picked when the row is selected; the cases only differ in how
/// the row is rendered (recent rows get a remove button).
enum WorkdirItem: Identifiable, Hashable {
    /// A previously picked directory (from the MRU list in the app config).
    case recent(String)
    /// A directory from browsing: the typed directory itself or one of its
    /// subdirectories (local or remote).
    case directory(String)

    var id: Self { self }

    var path: String {
        switch self {
        case .recent(let p), .directory(let p): return p
        }
    }

    /// Display form of a stored path: SSH specs verbatim, local paths
    /// tilde-abbreviated (so `~` queries match recents in search).
    static func display(_ path: String) -> String {
        SSHSpec.isSSH(path) ? path : (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Classification of the picker's search text, deciding which result sources
/// are consulted. Browsing semantics are the same locally and over SSH: the
/// full typed path is probed first — when it names an existing directory the
/// results are that directory plus its subdirectories; otherwise the parent
/// directory's entries are filtered by the last path component as a prefix.
enum WorkdirQuery: Equatable {
    /// Empty query: recents only.
    case empty
    /// Free text (no path form): search among recents only.
    case plain
    /// Absolute or `~`-rooted local path. `full` is the whole typed path
    /// (tilde-expanded, trailing slashes stripped); `dir`/`prefix` are the
    /// fallback listing target (parent directory + name prefix) used when
    /// `full` isn't an existing directory.
    case local(dir: String, prefix: String, full: String)
    /// scp-style remote spec; `path` is the remote path (nil for a bare
    /// `host:`, which browses the remote root — same as `host:/`).
    case ssh(host: String, path: String?)

    static func parse(_ raw: String) -> WorkdirQuery {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return .empty }

        if SSHSpec.isSSH(q) {
            guard case .success(let spec) = SSHSpec.parse(q) else { return .plain }
            return .ssh(host: spec.host, path: spec.path.map(stripTrailingSlashes))
        }

        guard q.hasPrefix("/") || q.hasPrefix("~") else { return .plain }
        let expanded = stripTrailingSlashes((q as NSString).expandingTildeInPath)
        // An unresolvable `~user` form doesn't expand to an absolute path.
        guard expanded.hasPrefix("/") else { return .plain }
        let complete = q == "~" || q.hasSuffix("/")
        let (dir, prefix) = splitDirPrefix(expanded, completeDir: complete)
        return .local(dir: dir, prefix: prefix, full: expanded)
    }

    /// Strips trailing slashes (except for the root itself).
    static func stripTrailingSlashes(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Splits an absolute path into the directory to list and the name prefix
    /// to filter its entries by. `completeDir` treats the whole path as the
    /// directory itself (trailing slash, bare `~`, or `/`).
    static func splitDirPrefix(_ path: String, completeDir: Bool) -> (dir: String, prefix: String) {
        let p = stripTrailingSlashes(path)
        if p == "/" || completeDir { return (p, "") }
        guard let idx = p.lastIndex(of: "/") else { return (p, "") }
        let dir = String(p[..<idx])
        let prefix = String(p[p.index(after: idx)...])
        return (dir.isEmpty ? "/" : dir, prefix)
    }

    /// Case-insensitive anchored match; an empty prefix matches everything.
    static func nameMatches(_ name: String, prefix: String) -> Bool {
        prefix.isEmpty || name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    /// Lists subdirectories of `dir` (an absolute local path) whose names
    /// start with `prefix` (case-insensitive), sorted by name, as
    /// standardized full paths. Hidden entries are skipped unless the prefix
    /// itself starts with a dot. Returns an empty list for unreadable dirs.
    /// Scanning stops after `scanLimit` matching entries — the picker only
    /// shows a handful anyway.
    static func localChildren(dir: String, prefix: String, scanLimit: Int = 50) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let includeHidden = prefix.hasPrefix(".")
        var result: [String] = []
        for entry in entries.sorted() {
            guard includeHidden || !entry.hasPrefix(".") else { continue }
            guard nameMatches(entry, prefix: prefix) else { continue }
            let full = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            result.append((full as NSString).standardizingPath)
            if result.count >= scanLimit { break }
        }
        return result
    }
}

/// Assembles the picker's item list from its sources, in display order:
/// matching recents first, then the typed directory itself, then its
/// subdirectories (capped at `childLimit`).
enum WorkdirItemsBuilder {
    static let childLimit = 10

    /// - Parameters:
    ///   - query: raw search text.
    ///   - recents: the MRU list (standardized local paths, verbatim SSH specs).
    ///   - typedDir: normalized path of the typed directory when it exists,
    ///     or nil when it doesn't / can't be checked.
    ///   - children: subdirectory entries (full paths/specs), pre-filtered.
    static func build(query: String, recents: [String], typedDir: String?, children: [String]) -> [WorkdirItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recents.map { .recent($0) } }

        // Recents are matched (case-insensitive substring) against their
        // display form so `~` and abbreviated queries behave the way the
        // user sees them; MRU order is preserved.
        var items = recents
            .filter { WorkdirItem.display($0).range(of: q, options: .caseInsensitive) != nil }
            .map { WorkdirItem.recent($0) }

        // A perfect match in the recents suppresses the typed-directory row.
        var typed: String? = nil
        if let typedDir, !recents.contains(typedDir) {
            typed = typedDir
            items.append(.directory(typedDir))
        }

        let recentsSet = Set(recents)
        var count = 0
        for child in children where count < childLimit {
            // Skip children already represented by a recent or the typed row.
            guard !recentsSet.contains(child), child != typed else { continue }
            items.append(.directory(child))
            count += 1
        }
        return items
    }
}

/// Lazily browses remote directories over SSH while the user types an
/// scp-style query in the workdir picker.
///
/// The first query for a host establishes a control-master connection (via
/// `SSHManager`, using a picker-scoped chat ID so it never collides with chat
/// connections); later queries reuse it. All failures are swallowed — the
/// picker simply shows no remote results, per the "no ssh errors" rule.
/// `terminate()` tears down every connection it made; the picker calls it
/// when dismissed for any reason.
@MainActor
final class WorkdirSSHLister: ObservableObject {
    /// The typed directory itself when the probe showed it exists, as a full
    /// `host:/path` spec.
    @Published private(set) var typed: String? = nil
    /// Subdirectories to show, as full `host:/path` specs.
    @Published private(set) var specs: [String] = []

    /// Picker-scoped identity for the control socket names.
    private let pickerID = "picker-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    /// Hosts we've connected to, so `terminate()` can close them all.
    private var hosts: Set<String> = []
    /// Monotonic query version; stale async results are dropped.
    private var generation = 0

    /// Clears remote results (non-SSH queries don't browse anything).
    func reset() {
        generation += 1
        typed = nil
        specs = []
    }

    /// Browses `path` on `host`. The full path is probed first: when it names
    /// an existing directory the results are the directory itself plus its
    /// subdirectories; otherwise the parent directory's entries are filtered
    /// by the last path component as a prefix. Superseded queries' results
    /// are discarded; all failures are silent.
    func list(host: String, path: String?) {
        generation += 1
        let gen = generation
        hosts.insert(host)
        typed = nil
        specs = []
        let ctx = SSHContext(host: host, chatID: pickerID)
        let full = (path?.isEmpty ?? true) ? "/" : path!
        Task { [weak self] in
            guard let self else { return }
            if let entries = await self.ls(ctx, dir: full) {
                guard gen == self.generation else { return }
                self.typed = "\(host):\(full)"
                self.specs = entries
                    .filter { !$0.hasPrefix(".") }
                    .map { "\(host):\(full == "/" ? "" : full)/\($0)" }
                return
            }
            let (dir, prefix) = WorkdirQuery.splitDirPrefix(full, completeDir: false)
            guard let entries = await self.ls(ctx, dir: dir) else { return }
            let includeHidden = prefix.hasPrefix(".")
            let base = dir == "/" ? "" : dir
            let matched = entries
                .filter { includeHidden || !$0.hasPrefix(".") }
                .filter { WorkdirQuery.nameMatches($0, prefix: prefix) }
                .map { "\(host):\(base)/\($0)" }
            guard gen == self.generation else { return }
            self.specs = matched
        }
    }

    /// Lists the immediate subdirectories of `dir`, or nil when it isn't a
    /// readable directory (or on any connection failure). Hidden entries are
    /// included; callers filter them based on the prefix.
    private func ls(_ ctx: SSHContext, dir: String) async -> [String]? {
        // `test -d` rejects plain files (ls would happily list a file as
        // itself); `ls -1Ap` marks directories with a trailing "/".
        let script = "test -d \(BuiltinToolsSSH.q(dir)) && ls -1Ap \(BuiltinToolsSSH.q(dir))"
        guard let result = try? await SSHManager.shared.exec(
            ctx, stdin: Data(script.utf8), hardTimeout: 20, idleTimeout: nil
        ), result.exitCode == 0 else { return nil }
        return result.stdoutString
            .components(separatedBy: "\n")
            .filter { $0.hasSuffix("/") }
            .map { String($0.dropLast()) }
    }

    /// Closes every connection this lister established. Safe to call once
    /// when the picker disappears.
    func terminate() {
        generation += 1
        for host in hosts {
            let ctx = SSHContext(host: host, chatID: pickerID)
            Task { await SSHManager.shared.close(ctx) }
        }
        hosts = []
    }
}
