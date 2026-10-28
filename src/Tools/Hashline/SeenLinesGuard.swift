// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Rejects edits that anchor to lines the model never saw: the tag proves which
/// version of the file it means, the file views prove what it actually looked
/// at. This stops the "editing blind" failure of reading a slice and guessing
/// at the rest.
///
/// A rejection for a version the model did see but not these lines also shows
/// those lines, so the same edit can simply be re-issued. Only a complete
/// reveal counts as seen: a capped or column-clipped one records nothing, or
/// repeated retries could piece their way past the guard without ever
/// displaying the whole range.
enum SeenLinesGuard {
    /// Most unseen anchor lines inlined into a rejection.
    static let revealCap = 20
    /// Revealed lines are cut at this many characters.
    static let revealMaxColumns = 300

    struct Rejection: Equatable {
        let message: String
        /// `seen` events for a complete reveal, otherwise empty.
        let events: [FileViewEvent]
    }

    /// Nil when the section may proceed. `file` is the content the patch was
    /// validated against (the tag already matched it).
    static func check(
        section: HashlineSection, key: FileKey, displayPath: String, tag: String, file: TextFile,
        views: FileViewState
    ) -> Rejection? {
        let header = HashlineFormat.formatHashlineHeader(path: displayPath, fileHash: tag)
        let contentID = HashlineFormat.computeContentID(file.text)

        guard let view = views.view(for: key), view.contentID == contentID else {
            return Rejection(
                message:
                    "This edit references \(header), but that version of the file was never displayed in this conversation. Re-read the file and re-issue the edit.",
                events: [])
        }

        let unseen = section.anchorLines(in: file.text).filter { !view.lines.contains($0) }.sorted()
        guard !unseen.isEmpty else { return nil }

        let lines = HashlineFormat.splitAddressableFileLines(file.text)
        var clipped = false
        var rows: [String] = []
        for number in unseen.prefix(revealCap) where number >= 1 && number <= lines.count {
            var text = lines[number - 1]
            if text.count > revealMaxColumns {
                text = String(text.prefix(revealMaxColumns)) + "…"
                clipped = true
            }
            rows.append(HashlineFormat.formatNumberedLine(lineNumber: number, content: text))
        }
        let complete = unseen.count <= revealCap && !clipped

        let list =
            unseen.count > revealCap
            ? "\(unseen.first!)-\(unseen.last!) (\(unseen.count) lines)"
            : unseen.map(String.init).joined(separator: ", ")
        let shown = unseen.count > revealCap ? "The first \(revealCap) of them" : "Their current content"
        var message =
            "This edit anchors to lines \(list) of \(header) that were never displayed (a partial read or search hit shows only some lines). \(shown):\n"
            + ([header] + rows).joined(separator: "\n") + "\n"
        if complete {
            message +=
                "These lines are now marked as seen — re-issue the edit unchanged (or adjusted) with the same \(header) header."
        } else {
            message +=
                "These lines are NOT marked as seen (too many lines, or lines cut at \(revealMaxColumns) characters). Re-read the range you need with read_file (offset/limit), then re-issue the edit."
        }
        return Rejection(
            message: message,
            events: complete ? [.seen(key, contentID: contentID, lines: LineSet(unseen))] : [])
    }
}
