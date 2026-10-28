// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Why a patch was not (fully) applied: a message for the model plus the file
/// view events that go with it — the lines a seen-lines rejection revealed, or
/// the sections that did land before a commit failed.
struct HashlinePatchError: Error {
    let message: String
    let fileViews: [FileViewEvent]

    init(_ message: String, fileViews: [FileViewEvent] = []) {
        self.message = message
        self.fileViews = fileViews
    }
}

/// A section checked against the file as it is now, ready to be written.
struct PreparedSection {
    struct Destination {
        let resolved: String
        let key: FileKey
    }

    let section: HashlineSection
    let resolved: String
    let key: FileKey
    let file: TextFile
    let result: ApplyResult
    /// Set for `MV`.
    let destination: Destination?
    /// The lines of this exact version of the file the model has seen (the
    /// guard verified the view matches).
    let seenBefore: LineSet
}

struct PreparedPatch {
    let sections: [PreparedSection]
    /// Parser and applier warnings, deduplicated, in patch order.
    let warnings: [String]
}

/// What a committed patch reports.
struct PatchCommit {
    /// One block per section: an `Updated:`/`Deleted:` line, then the preview.
    let summaries: [String]
    let warnings: [String]
    let fileViews: [FileViewEvent]

    var content: String {
        var text = summaries.joined(separator: "\n")
        if !warnings.isEmpty {
            text += "\n\nWarnings:\n" + warnings.joined(separator: "\n")
        }
        return text
    }
}

/// The single `edit_file` pipeline, used for local and SSH workdirs alike
/// (they differ only in their `FileAccess`) and for both the approval
/// preflight and the execution. `prepare` does every check without writing;
/// execution runs it again right before `commit`, so the two can never
/// diverge and a skipped preflight cannot bypass a check.
enum HashlinePatcher {

    // MARK: - Prepare

    /// Parses and validates the whole patch. Every section is prepared before
    /// anything is returned, so nothing is written unless all of them are
    /// valid. Per section: resolve, read, tag, apply in memory, noop, `MV`
    /// destination, seen-lines guard. Guard rejections are collected so a
    /// multi-file patch gets every reveal in one error; any other failure
    /// throws at once.
    static func prepare(
        _ input: String, access: any FileAccess, views: FileViewState
    ) async throws -> PreparedPatch {
        do {
            return try await prepareSections(input, access: access, views: views)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw patchError(error)
        }
    }

    private static func prepareSections(
        _ input: String, access: any FileAccess, views: FileViewState
    ) async throws -> PreparedPatch {
        let patch = try HashlineEdit.parse(input)

        var prepared: [PreparedSection] = []
        var rejections: [SeenLinesGuard.Rejection] = []
        var sources: [String: String] = [:]
        var destinations: Set<String> = []

        for section in patch.sections {
            let resolved = try access.resolve(section.path)
            let displayPath = access.displayPath(resolved)
            let key = access.key(resolved)

            let identity = access.identity(resolved)
            if let first = sources[identity] {
                throw HashlinePatchError(
                    "Multiple sections resolve to the same file (\(first) and \(section.path)). Merge their ops under one header."
                )
            }
            sources[identity] = section.path

            let data: Data
            switch try await access.read(resolved) {
            case .missing:
                throw HashlinePatchError("File not found: \(section.path). Use write_file to create new files.")
            case .directory:
                throw HashlinePatchError("invalid argument 'input': is a directory: \(section.path)")
            case .data(let bytes):
                data = bytes
            }
            guard let file = TextFile.decode(data) else {
                throw HashlinePatchError(
                    "File \(section.path) is not a text file and cannot be edited with edit_file. Use write_file to replace it entirely."
                )
            }

            let result: ApplyResult
            do {
                result = try HashlineEdit.applySection(section, fileContent: file.text)
            } catch let error as HashlineParseError {
                throw HashlinePatchError("[\(section.path)] \(error.localizedDescription)")
            }

            var destination: PreparedSection.Destination?
            if case .move(let dest) = section.fileOp {
                destination = try await checkMoveDestination(
                    dest, section: section, resolved: resolved, access: access, claimed: &destinations)
            }

            // The tag already matched, so `section.fileHash` is set.
            let tag = section.fileHash ?? HashlineFormat.computeFileHash(file.text)
            if let rejection = SeenLinesGuard.check(
                section: section, key: key, displayPath: displayPath, tag: tag, file: file, views: views)
            {
                rejections.append(rejection)
                continue
            }

            prepared.append(
                PreparedSection(
                    section: section, resolved: resolved, key: key, file: file, result: result,
                    destination: destination, seenBefore: views.view(for: key)?.lines ?? LineSet()))
        }

        if !rejections.isEmpty {
            throw HashlinePatchError(
                rejections.map(\.message).joined(separator: "\n\n"),
                fileViews: rejections.flatMap(\.events))
        }

        var warnings: [String] = []
        for warning in prepared.flatMap(\.result.warnings) where !warnings.contains(warning) {
            warnings.append(warning)
        }
        return PreparedPatch(sections: prepared, warnings: warnings)
    }

    /// The destination must differ from the source, be unused by another
    /// section and not exist: `MV` never overwrites.
    private static func checkMoveDestination(
        _ dest: String, section: HashlineSection, resolved: String, access: any FileAccess,
        claimed: inout Set<String>
    ) async throws -> PreparedSection.Destination {
        let resolvedDest = try access.resolve(dest)
        let key = access.key(resolvedDest)
        let identity = access.identity(resolvedDest)
        if key == access.key(resolved) || identity == access.identity(resolved) {
            throw HashlinePatchError("invalid argument 'input': MV destination is the same as \(section.path).")
        }
        if !claimed.insert(identity).inserted {
            throw HashlinePatchError(
                "invalid argument 'input': MV destination \(dest) is used by more than one section.")
        }
        if try await access.exists(resolvedDest) {
            throw HashlinePatchError(
                "invalid argument 'input': MV destination already exists: \(dest). Remove it first or pick another name."
            )
        }
        return PreparedSection.Destination(resolved: resolvedDest, key: key)
    }

    // MARK: - Commit

    /// Writes the sections in patch order. There is no filesystem transaction:
    /// when a write fails after earlier sections landed, the error says which
    /// ones did and carries their events, so the model's view of the files
    /// stays true.
    static func commit(_ patch: PreparedPatch, access: any FileAccess) async throws -> PatchCommit {
        var summaries: [String] = []
        var events: [FileViewEvent] = []
        for (index, prepared) in patch.sections.enumerated() {
            do {
                let outcome = try await write(prepared, access: access)
                summaries.append(outcome.summary)
                events += outcome.events
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                var message = patchError(error).message
                if index > 0 {
                    let written = patch.sections[..<index].map(\.section.path).joined(separator: ", ")
                    let pending = patch.sections[index...].map(\.section.path).joined(separator: ", ")
                    message +=
                        "\nThe patch was applied only partly. Written: \(written). Not written: \(pending). Re-read the written files before retrying."
                }
                throw HashlinePatchError(message, fileViews: events)
            }
        }
        return PatchCommit(summaries: summaries, warnings: patch.warnings, fileViews: events)
    }

    private static func write(
        _ prepared: PreparedSection, access: any FileAccess
    ) async throws -> (summary: String, events: [FileViewEvent]) {
        let section = prepared.section
        switch section.fileOp {
        case .rem:
            try await access.delete(prepared.resolved)
            return ("Deleted: \(section.path)", [.drop(prepared.key)])

        case .move(let dest):
            guard let destination = prepared.destination else {
                throw HashlinePatchError("internal error: MV section prepared without a destination")
            }
            try await access.create(destination.resolved, prepared.file.encode(prepared.result.text))
            try await access.delete(prepared.resolved)
            let outcome = updated(prepared, newPath: dest, newKey: destination.key)
            return (outcome.summary, [.drop(prepared.key)] + outcome.events)

        case nil:
            try await access.write(prepared.resolved, prepared.file.encode(prepared.result.text))
            return updated(prepared, newPath: section.path, newKey: prepared.key)
        }
    }

    /// The `Updated:` block (with the counts of added and removed lines, since
    /// the preview does not print removals) and the `set` event for the
    /// post-edit content, which lives at `newKey`. The model knows of it what it knew before
    /// (carried through the edit's line origins), every line it authored, and
    /// the rows of the preview it is about to read.
    private static func updated(
        _ prepared: PreparedSection, newPath: String, newKey: FileKey
    ) -> (summary: String, events: [FileViewEvent]) {
        let text = prepared.result.text
        let preview = HashlineDiffPreview.generate(
            old: prepared.file.text, new: text, origins: prepared.result.origins)

        var lines = LineSet()
        if !text.isEmpty {
            let origins = prepared.result.origins
            let authored = origins.indices.filter { origins[$0] == nil }.map { $0 + 1 }
            lines = prepared.seenBefore.remapped(throughOrigins: origins)
                .union(LineSet(authored))
                .union(preview?.shownLines ?? LineSet())
        }

        var summary =
            "Updated: \(prepared.section.path) [\(newPath)#\(HashlineFormat.computeFileHash(text))]"
        let counts = HashlineDiffPreview.changeCounts(
            old: prepared.file.text, new: text, origins: prepared.result.origins)
        if let stat = HashlineDiffPreview.changeSummary(added: counts.added, removed: counts.removed) {
            summary += " " + stat
        }
        if let preview { summary += "\n" + preview.text }
        return (summary, [.set(newKey, contentID: HashlineFormat.computeContentID(text), lines: lines)])
    }

    // MARK: - Preflight

    enum Preflight {
        /// The unified diff for the approval prompt (nil when nothing changes).
        case ok(diff: String?)
        /// The patch cannot succeed; relay `message` to the model instead of
        /// asking the user. `fileViews` are events the failure carries.
        case error(message: String, fileViews: [FileViewEvent])
    }

    /// Runs `prepare` for an `edit_file` call (JSON `arguments`) without
    /// writing anything. Failures, transport errors included, come back as
    /// `.error`; only a cancellation throws.
    static func preflight(arguments: String, workdir: Workdir, views: FileViewState) async throws -> Preflight {
        guard let data = arguments.data(using: .utf8),
            let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let input = args["input"] as? String
        else { return .error(message: "Invalid arguments: expected an 'input' string.", fileViews: []) }
        do {
            let prepared = try await prepare(input, access: try workdir.fileAccess(), views: views)
            return .ok(diff: unifiedDiff(prepared))
        } catch let error as HashlinePatchError {
            return .error(message: error.message, fileViews: error.fileViews)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .error(message: patchError(error).message, fileViews: [])
        }
    }

    /// The sections' unified diffs for the approval UI. Warnings stay out: the
    /// tool result carries them, showing them twice would be noise.
    private static func unifiedDiff(_ patch: PreparedPatch) -> String? {
        let diffs = patch.sections.map { prepared -> String in
            let old = prepared.file.text
            let path = prepared.section.path
            switch prepared.section.fileOp {
            case .rem:
                return DiffBuilder.unifiedDiff(old: old, new: "", oldPath: path, newPath: nil)
            case .move(let dest):
                return DiffBuilder.unifiedDiff(old: old, new: prepared.result.text, oldPath: path, newPath: dest)
            case nil:
                return DiffBuilder.unifiedDiff(old: old, new: prepared.result.text, oldPath: path, newPath: path)
            }
        }
        let joined = diffs.filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Errors

    /// Everything that can go wrong in the pipeline, as one error type.
    private static func patchError(_ error: Error) -> HashlinePatchError {
        switch error {
        case let error as HashlinePatchError: return error
        case let error as BuiltinToolError: return HashlinePatchError(error.message)
        default: return HashlinePatchError(error.localizedDescription)
        }
    }
}
