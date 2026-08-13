// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A recorded version of a file's content as seen by the model: the hash tag
/// minted by the read/edit that created it, the optional full text (nil when
/// rebuilt from chat history — the bytes aren't in the tool result), and the
/// 1-indexed line numbers actually displayed. `seenLines == nil` means "all
/// lines seen" (an edit wrote the whole file, so every line is known).
struct Snapshot: Sendable {
    let path: String
    let text: String?
    let hash: String
    /// `nil` = all lines seen. Non-nil values are merged when the store
    /// records a dedup or the reveal-and-retry path reveals new lines.
    var seenLines: Set<Int>?
}

/// Per-chat, in-memory store of what file content the model has actually
/// seen, keyed by canonical filesystem path. Feeds `edit_file`'s seen-lines
/// guard: edits targeting lines never displayed are rejected, fixing the
/// "editing blind" failure class where the model reads a partial slice and
/// then guesses at lines outside it.
///
/// The store is derived data, not primary state: the chat JSON already
/// contains every `read_file`/`find_text`/`edit_file` call and result, so the
/// store is rebuilt from chat history at request start
/// ([`BuiltinTools.rebuildSnapshots`](src/Tools/BuiltinTools.swift)) and kept
/// alive for the request's duration, updated live as tools execute. No
/// sidecar files, no persistence — unloading a chat drops the store and the
/// next request rebuilds it.
final class SnapshotStore: @unchecked Sendable {

    private let lock = NSLock()
    private var versions: [String: [Snapshot]] = [:]

    /// Maximum unseen lines inlined into a seen-lines rejection before it is
    /// truncated, forcing a re-read instead of a reveal-and-retry.
    static let maxRevealLines = 40
    /// Maximum characters per line inlined into a seen-lines rejection.
    static let maxRevealLineChars = 512

    /// Records a version with an explicit tag. When `text` is non-nil, dedups
    /// on full-text equality (two distinct texts can collide on 4 hex); when
    /// nil (rebuilt from history) it dedups on the hash alone. A dedup
    /// refreshes recency (the entry becomes `head`) and unions `seenLines`.
    @discardableResult
    func record(path: String, hash: String, text: String?, seenLines: Set<Int>?) -> String {
        lock.lock()
        defer { lock.unlock() }
        var list = versions[path] ?? []
        if let idx = existingIndex(in: list, text: text, hash: hash) {
            var snap = list[idx]
            snap.seenLines = Self.mergedSeen(snap.seenLines, seenLines)
            list.remove(at: idx)
            list.append(snap)
        } else {
            list.append(Snapshot(path: path, text: text, hash: hash, seenLines: seenLines))
        }
        versions[path] = list
        return hash
    }

    /// Computes the tag from `text` and records the version.
    @discardableResult
    func record(path: String, text: String, seenLines: Set<Int>?) -> String {
        record(path: path, hash: HashlineFormat.computeFileHash(text), text: text, seenLines: seenLines)
    }

    /// Merges additional seen lines into the entry matching `hash`. No-op if
    /// no such entry exists.
    func recordSeenLines(path: String, hash: String, lines: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        guard var list = versions[path], let idx = list.firstIndex(where: { $0.hash == hash }) else { return }
        var snap = list[idx]
        if snap.seenLines != nil {
            snap.seenLines = snap.seenLines!.union(lines)
        }
        list[idx] = snap
        versions[path] = list
    }

    /// The most recent version matching a tag.
    func byHash(path: String, hash: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return versions[path]?.last(where: { $0.hash == hash })
    }

    /// A version whose full text equals `fullText`. Only entries recorded
    /// live carry text, so rebuilt stores never match here.
    func byContent(path: String, fullText: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return versions[path]?.last(where: { $0.text == fullText })
    }

    /// The most recent version for a path.
    func head(path: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return versions[path]?.last
    }

    /// Drops every version for a path (used by `REM`).
    func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        versions[path] = nil
    }

    /// Moves a path's version history to a new canonical path (used by `MV`),
    /// appending it to the destination's history.
    func relocate(from: String, to: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let list = versions.removeValue(forKey: from) else { return }
        var dest = versions[to] ?? []
        dest.append(contentsOf: list.map { Snapshot(path: to, text: $0.text, hash: $0.hash, seenLines: $0.seenLines) })
        versions[to] = dest
    }

    /// Drops everything.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        versions.removeAll()
    }

    /// The seen-lines guard shared by `edit_file` execution and preflight.
    /// Returns a rejection message when the edit anchors to lines the model
    /// never saw; nil when the guard passes or is skipped (no snapshot for
    /// the content/tag, or all lines were seen). When the inline reveal is
    /// not truncated, the revealed lines are merged into the snapshot's
    /// `seenLines` so a straight retry of the same edit succeeds.
    static func seenLinesRejection(
        _ store: SnapshotStore?, displayPath: String, canonical: String, tag: String?, currentContent: String,
        anchorLines: [Int]
    ) -> String? {
        guard let store, let tag else { return nil }
        guard
            let snapshot = store.byContent(path: canonical, fullText: currentContent)
                ?? store.byHash(path: canonical, hash: tag)
        else { return nil }
        guard let seen = snapshot.seenLines else { return nil }
        let unseen = anchorLines.filter { !seen.contains($0) }.sorted()
        guard !unseen.isEmpty else { return nil }

        let header = HashlineFormat.formatHashlineHeader(path: displayPath, fileHash: tag)
        let linesList = unseen.map(String.init).joined(separator: ", ")

        guard let text = snapshot.text else {
            // Rebuilt from history: no full content to inline. Force a re-read.
            return """
                This edit anchors to lines \(linesList) of \(displayPath) that were not displayed in the read that minted \(header). Re-read those lines in full first, then re-issue the edit.
                """
        }

        let textLines = HashlineFormat.splitAddressableFileLines(text)
        var truncated = unseen.count > maxRevealLines
        var revealed: [String] = []
        for line in unseen {
            let content = line <= textLines.count ? textLines[line - 1] : ""
            if content.count > maxRevealLineChars { truncated = true }
            revealed.append("  \(line):\(content)")
        }
        if truncated {
            let shown = revealed.prefix(maxRevealLines).joined(separator: "\n")
            return """
                This edit anchors to lines \(unseen.first!)-\(unseen.last!) of \(displayPath) that \(header) never displayed. Preview of the first \(min(unseen.count, maxRevealLines)) unseen line(s):
                \(shown)
                The range exceeds the inline preview cap — re-read the remainder before re-issuing the edit.
                """
        }

        store.recordSeenLines(path: canonical, hash: snapshot.hash, lines: Set(unseen))
        return """
            This edit anchors to lines \(linesList) of \(displayPath) that \(header) never displayed (it showed a partial range or a search hit). Re-read them in full first, then re-issue the edit.

            Actual file content at those lines:
            \(revealed.joined(separator: "\n"))
            """
    }

    private func existingIndex(in list: [Snapshot], text: String?, hash: String) -> Int? {
        if let text {
            return list.lastIndex(where: { $0.text == text })
        }
        return list.lastIndex(where: { $0.hash == hash })
    }

    private static func mergedSeen(_ existing: Set<Int>?, _ incoming: Set<Int>?) -> Set<Int>? {
        if incoming == nil || existing == nil { return nil }
        return existing!.union(incoming!)
    }
}
