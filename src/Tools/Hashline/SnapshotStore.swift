// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A recorded version of a file's content as seen by the model: the hash tag
/// minted by the read/edit that created it, the optional full text (used to
/// dedup versions — two distinct texts can collide on 4 hex; nil when rebuilt
/// from chat history), and the 1-indexed line numbers actually displayed.
/// `seenLines == nil` means "all lines seen" — a write_file replaced the whole
/// file, so every line is known.
struct Snapshot: Sendable {
    let path: String
    let text: String?
    let hash: String
    /// `nil` = all lines seen. Non-nil values are merged when the store
    /// records a dedup.
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

    /// Records the post-edit version after a successful `edit_file` section.
    /// The model's knowledge does not extend to the whole file — it saw the
    /// lines it had previously read (matching the pre-edit version) plus the
    /// rows of the returned diff preview (post-edit line numbers). Marking
    /// every line as seen here would let a model that read only lines 1-5
    /// edit line 30 immediately after touching line 5, which is exactly the
    /// "editing blind" failure this store exists to prevent.
    ///
    /// `editFile` is the caller; it has the post-edit full text in hand, so
    /// the version is recorded with `text` (dedups on content, not just the
    /// 4-hex tag). The pre-edit version is looked up by the pre-edit tag to
    /// inherit what was already seen; the preview rows are added on top.
    @discardableResult
    func recordEdit(
        path: String, preTag: String?, postHash: String, postText: String, previewSeen: Set<Int>
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        var seen: Set<Int> = previewSeen
        if let preTag, let pre = versions[path]?.last(where: { $0.hash == preTag }), let preSeen = pre.seenLines {
            seen.formUnion(preSeen)
        }
        var list = versions[path] ?? []
        if let idx = existingIndex(in: list, text: postText, hash: postHash) {
            var snap = list[idx]
            snap.seenLines = Self.mergedSeen(snap.seenLines, seen)
            list.remove(at: idx)
            list.append(snap)
        } else {
            list.append(Snapshot(path: path, text: postText, hash: postHash, seenLines: seen))
        }
        versions[path] = list
        return postHash
    }

    /// Computes the tag from `text` and records the version.
    @discardableResult
    func record(path: String, text: String, seenLines: Set<Int>?) -> String {
        record(path: path, hash: HashlineFormat.computeFileHash(text), text: text, seenLines: seenLines)
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

    /// Moves a path's version history to a new canonical path (used by `MV`).
    /// The destination's previous history is dropped: `MV` is guarded against
    /// overwriting an existing file, so any prior snapshots there are stale.
    func relocate(from: String, to: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let list = versions.removeValue(forKey: from) else { return }
        versions[to] = list.map { Snapshot(path: to, text: $0.text, hash: $0.hash, seenLines: $0.seenLines) }
    }

    /// Drops everything.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        versions.removeAll()
    }

    /// The seen-lines guard shared by `edit_file` execution and preflight.
    /// Returns a rejection message when the edit anchors to lines the model
    /// never saw; nil when the guard passes or is skipped (store nil, all
    /// lines seen, or `seenLines == nil` = "everything seen"). The guard is
    /// metadata-only: it never inlines file content — a rejection always
    /// requires a re-read.
    ///
    /// `currentContent` is matched against a recorded snapshot by full text
    /// first (the hash is a 4-hex fingerprint and can collide across distinct
    /// contents); the tag lookup is the fallback for rebuilt stores (no text).
    /// When the file has a snapshot store but no snapshot matches the current
    /// content or tag, `strictReject` is true and the edit is rejected — the
    /// tag names content the model never saw (a silent skip would let a model
    /// dodge the guard with a fresh/unknown tag).
    static func seenLinesRejection(
        _ store: SnapshotStore?, displayPath: String, canonical: String, tag: String?, currentContent: String,
        anchorLines: [Int], strictReject: Bool
    ) -> String? {
        guard let store else { return nil }
        let header = tag.map { HashlineFormat.formatHashlineHeader(path: displayPath, fileHash: $0) }

        guard let tag else {
            // Untagged sections are normally a parse error upstream; if one
            // reaches the guard with a store, reject rather than guess.
            return strictReject
                ? "This edit has no #TAG, so it cannot be verified against what was displayed. Re-read the file and re-issue the edit with a \(HashlineFormat.filePrefix)path#TAG\(HashlineFormat.fileSuffix) header."
                : nil
        }

        let snapshot =
            store.byContent(path: canonical, fullText: currentContent)
            ?? store.byHash(path: canonical, hash: tag)

        guard let snapshot else {
            // No recorded version of this content/tag — the model never saw
            // it in this session. Reject rather than silently skip.
            return strictReject
                ? "This edit references \(header!) which was never displayed (no read in this session produced that content). Re-read the file and re-issue the edit."
                : nil
        }

        guard let seen = snapshot.seenLines else { return nil }
        let unseen = anchorLines.filter { !seen.contains($0) }.sorted()
        guard !unseen.isEmpty else { return nil }

        // Collapse large ranges so a pathological edit cannot produce a
        // message with hundreds of line numbers.
        let linesList: String
        if unseen.count > 20 {
            linesList = "\(unseen.first!)-\(unseen.last!) (\(unseen.count) lines)"
        } else {
            linesList = unseen.map(String.init).joined(separator: ", ")
        }
        return """
            This edit anchors to lines \(linesList) of \(header!) that were never displayed (a partial read or search hit shows only some lines). Re-read them in full first, then re-issue the edit.
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
