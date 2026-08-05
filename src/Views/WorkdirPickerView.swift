// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A modal sheet for picking the per-chat working directory.
///
/// With an empty search the sheet lists recently picked directories (the MRU
/// list from the app config, capped at 30 — see
/// [`AppViewModel.recordWorkingDirectory()`](src/App/AppViewModel.swift:975)),
/// each with a remove button; the role's pre-set working directory (when it
/// allows overrides) is pinned at the bottom as the default option.
///
/// Typing into the search field browses directories (see
/// [`WorkdirQuery`](src/Views/WorkdirPickerModel.swift:32) for the query
/// classification and [`WorkdirItemsBuilder`](src/Views/WorkdirPickerModel.swift:107)
/// for the result ordering):
/// - free text filters the recents (case-insensitive substring);
/// - a local path (`/...` or `~/...`) shows the typed directory itself when
///   it exists, followed by its subdirectories;
/// - an scp-style spec (`[user@]host:[/path]`) lazily connects over SSH and
///   lists remote subdirectories. The connection is reused across keystrokes
///   and torn down when the picker closes; SSH failures are silent.
///
/// Everything picked here is recorded as most-recently-used by the caller.
/// Layout and keyboard navigation are shared with other pickers via
/// [`PickerDialog`](src/Views/PickerDialog.swift:37). The selected directory
/// is saved to the chat data (alongside the role and title), not to the app
/// config.
struct WorkdirPickerView: View {
    @EnvironmentObject var store: AppViewModel
    let onCancel: () -> Void
    let onPick: (String) -> Void

    @State private var query: String = ""
    @StateObject private var sshLister = WorkdirSSHLister()

    private var directories: [String] { store.workingDirectories }

    /// The role's pre-set working directory (standardized), shown as a pinned
    /// default at the bottom when the role allows overrides. May duplicate an
    /// entry in `directories`; that's intentional — it's still offered as the
    /// default so the user can accept it with ↵.
    private var roleDefaultWorkdir: String? {
        guard let role = store.selectedRole,
              role.workingDirectoryOverrideAllowed,
              let path = role.workingDirectory, !path.isEmpty else { return nil }
        return SSHSpec.isSSH(path) ? path : (path as NSString).standardizingPath
    }

    /// The currently selected chat's working directory, so we can highlight it.
    private var currentWorkdir: String? {
        guard let path = store.selectedChatWorkingDirectory else { return nil }
        return SSHSpec.isSSH(path) ? path : (path as NSString).standardizingPath
    }

    /// The current query, classified.
    private var parsedQuery: WorkdirQuery { WorkdirQuery.parse(query) }

    /// Local browsing results for the current query. When the typed path is
    /// an existing directory: the directory itself plus its subdirectories.
    /// Otherwise: the parent's subdirectories filtered by the last path
    /// component as a prefix.
    private var localResults: (typed: String?, children: [String]) {
        guard case .local(let dir, let prefix, let full) = parsedQuery else { return (nil, []) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
            return ((full as NSString).standardizingPath, WorkdirQuery.localChildren(dir: full, prefix: ""))
        }
        return (nil, WorkdirQuery.localChildren(dir: dir, prefix: prefix))
    }

    /// Scrollable items: assembled from the recents, the typed directory,
    /// and its subdirectories.
    private var scrollItems: [WorkdirItem] {
        switch parsedQuery {
        case .empty:
            return WorkdirItemsBuilder.build(query: "", recents: directories, typedDir: nil, children: [])
        case .plain:
            return WorkdirItemsBuilder.build(query: query, recents: directories, typedDir: nil, children: [])
        case .local:
            let local = localResults
            return WorkdirItemsBuilder.build(query: query, recents: directories, typedDir: local.typed, children: local.children)
        case .ssh:
            return WorkdirItemsBuilder.build(query: query, recents: directories, typedDir: sshLister.typed, children: sshLister.specs)
        }
    }

    /// Pinned entries: the role's default working directory, if any.
    private var pinnedItems: [WorkdirItem] {
        roleDefaultWorkdir.map { [.roleDefault($0)] } ?? []
    }

    private var initialSelection: WorkdirItem? {
        if let roleDefault = roleDefaultWorkdir {
            return .roleDefault(roleDefault)
        }
        if let current = currentWorkdir, directories.contains(current) {
            return .recent(current)
        }
        return directories.first.map { .recent($0) }
    }

    var body: some View {
        PickerDialog<WorkdirItem>(
            title: "Working directory",
            subtitle: "Pick a directory for this chat. Recently picked directories are remembered; type a local path or host:/path to browse.",
            searchText: $query,
            searchPlaceholder: "Type a path or host:/path",
            items: scrollItems,
            pinnedHeader: pinnedItems.isEmpty ? nil : "Default",
            pinnedItems: pinnedItems,
            emptyTitle: "No recent directories",
            emptySubtitle: "Type a local path or host:/path above",
            width: 420,
            rowContent: { item, _ in
                AnyView(WorkdirRowContent(
                    item: item,
                    isCurrent: currentWorkdir == item.path,
                    onRemove: { store.removeWorkingDirectory(item.path) }
                ))
            },
            onSelect: { onPick($0.path) },
            onCancel: onCancel,
            initialSelection: initialSelection
        )
        .onChange(of: query) { _, _ in
            switch parsedQuery {
            case .ssh(let host, let path):
                sshLister.list(host: host, path: path)
            default:
                sshLister.reset()
            }
        }
        .onDisappear {
            sshLister.terminate()
        }
    }
}

/// Inner content of a working-directory picker row. Recent directories get a
/// remove button; directories show a folder icon (network icon for SSH
/// specs), the directory name, and its abbreviated path. Padding and the
/// selection highlight are applied by
/// [`PickerDialog`](src/Views/PickerDialog.swift:37).
private struct WorkdirRowContent: View {
    let item: WorkdirItem
    let isCurrent: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: SSHSpec.isSSH(item.path) ? "network" : "folder")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if case .recent = item {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.borderless)
                .help("Remove directory")
            }
        }
    }

    private var title: String {
        let dir = item.path
        if SSHSpec.isSSH(dir),
           case .success(let spec) = SSHSpec.parse(dir) {
            if let path = spec.path {
                return (path as NSString).lastPathComponent
            }
            return spec.host
        }
        return (dir as NSString).lastPathComponent
    }

    private var subtitle: String {
        let dir = item.path
        if SSHSpec.isSSH(dir) {
            if case .success(let spec) = SSHSpec.parse(dir), spec.path != nil {
                return dir
            }
            return "Remote home directory"
        }
        return (dir as NSString).abbreviatingWithTildeInPath
    }
}
