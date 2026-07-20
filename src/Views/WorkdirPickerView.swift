// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// A modal sheet for picking the per-chat working directory. Lists the
/// user-managed directories from the app config (`working_directories`), each
/// with a remove icon. An "Add a directory..." pseudo-entry is pinned to the
/// top of the list — selecting it opens the macOS folder picker, and the
/// chosen directory is added to the config and immediately selected for the
/// chat, closing the picker. Next to it, "Add SSH path..." asks for an
/// `ssh::host/path` spec (see [`SSHSpec`](src/SSHManager.swift:13)); remote
/// entries live in the same `working_directories` list.
///
/// When the selected chat's role pre-sets a `working_directory` (and allows
/// overrides), that directory is pinned at the bottom as the default option —
/// mirroring how the role picker pins built-in roles — and is selected by
/// default so the user can press ↵ to accept it.
///
/// Layout and keyboard navigation are shared with other pickers via
/// [`PickerDialog`](src/Views/PickerDialog.swift:14). The selected directory
/// is saved to the chat data (alongside the role and title), not to the app
/// config.
struct WorkdirPickerView: View {
    @EnvironmentObject var store: AppViewModel
    let onCancel: () -> Void
    let onPick: (String) -> Void

    @State private var addPicker: Bool = false
    @State private var sshPrompt: Bool = false
    @State private var sshInput: String = ""

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

    /// Scrollable entries: the "Add a directory..." and "Add SSH path..."
    /// pseudo-entries first, then the user-managed directories.
    private var scrollItems: [WorkdirSelection] {
        [.add, .addSSH] + directories.map { WorkdirSelection.userList($0) }
    }

    /// Pinned entries: the role's default working directory, if any.
    private var pinnedItems: [WorkdirSelection] {
        roleDefaultWorkdir.map { [.roleDefault($0)] } ?? []
    }

    /// Combined ordered list for keyboard navigation.
    private var allEntries: [WorkdirSelection] { scrollItems + pinnedItems }

    private var initialSelection: WorkdirSelection? {
        if let roleDefault = roleDefaultWorkdir {
            return .roleDefault(roleDefault)
        }
        if let current = currentWorkdir, directories.contains(current) {
            return .userList(current)
        }
        if let firstDir = directories.first {
            return .userList(firstDir)
        }
        return .add
    }

    /// The typed SSH path with the `ssh::` prefix guaranteed — the dialog
    /// accepts both `host/path` and the fully-prefixed form.
    private var normalizedSSHInput: String {
        let trimmed = sshInput.trimmingCharacters(in: .whitespaces)
        return SSHSpec.isSSH(trimmed) ? trimmed : SSHSpec.prefix + trimmed
    }

    private var sshInputValid: Bool {
        if case .success = SSHSpec.parse(normalizedSSHInput) { return true }
        return false
    }

    var body: some View {
        PickerDialog<WorkdirSelection>(
            title: "Working directory",
            subtitle: "Pick a directory for this chat. Added directories are saved to the app config and offered in every chat.",
            items: scrollItems,
            pinnedHeader: pinnedItems.isEmpty ? nil : "Default",
            pinnedItems: pinnedItems,
            emptyTitle: "No directories",
            emptySubtitle: nil,
            visibleRowCount: 6,
            estimatedRowHeight: 50,
            width: 420,
            rowContent: { item, _ in
                AnyView(WorkdirRowContent(
                    item: item,
                    isCurrent: currentWorkdir == item.path,
                    onRemove: {
                        if case .userList(let dir) = item {
                            store.removeWorkingDirectory(dir)
                        }
                    }
                ))
            },
            onSelect: { item in
                switch item {
                case .add:
                    addPicker = true
                case .addSSH:
                    sshPrompt = true
                case .userList(let dir), .roleDefault(let dir):
                    onPick(dir)
                }
            },
            onCancel: onCancel,
            initialSelection: initialSelection
        )
        .fileImporter(
            isPresented: $addPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let path = url.path
                    store.addWorkingDirectory(path)
                    onPick(path)
                }
            case .failure:
                break
            }
        }
        .alert("Add SSH path", isPresented: $sshPrompt) {
            TextField("somehost/home/user/project", text: $sshInput)
            Button("Add") {
                let spec = normalizedSSHInput
                sshInput = ""
                store.addWorkingDirectory(spec)
                onPick(spec)
            }
            .disabled(!sshInputValid)
            Button("Cancel", role: .cancel) { sshInput = "" }
        } message: {
            Text("Enter an SSH working directory as host/absolute/path, e.g. somehost/home/user/project or user@somehost/home/user/project. Just somehost (no path) means the remote home directory.\n\nAll authorization must be pre-configured: running `ssh somehost` in your terminal must work as-is, without prompts.")
        }
    }
}

/// Inner content of a working-directory picker row. The "Add a directory..."
/// pseudo-entry uses a `plus.rectangle.on.folder` symbol and "Add SSH
/// path..." a `network` symbol; real directories show a folder icon (network
/// icon for SSH specs), the directory name, and its abbreviated path.
/// User-managed directories get a remove button. Padding and the selection
/// highlight are applied by [`PickerDialog`](src/Views/PickerDialog.swift:14).
private struct WorkdirRowContent: View {
    let item: WorkdirSelection
    let isCurrent: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if case .userList = item {
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

    private var iconName: String {
        switch item {
        case .add: return "plus.rectangle.on.folder"
        case .addSSH: return "network"
        case .userList(let dir), .roleDefault(let dir):
            return SSHSpec.isSSH(dir) ? "network" : "folder"
        }
    }

    private var iconColor: Color {
        switch item {
        case .add, .addSSH: return Color.accentColor
        case .userList, .roleDefault: return .secondary
        }
    }

    private var title: String {
        switch item {
        case .add:
            return "Add a directory..."
        case .addSSH:
            return "Add SSH path..."
        case .userList(let dir), .roleDefault(let dir):
            if SSHSpec.isSSH(dir),
               case .success(let spec) = SSHSpec.parse(dir) {
                return spec.host
            }
            return (dir as NSString).lastPathComponent
        }
    }

    private var subtitle: String? {
        switch item {
        case .add:
            // Keep a subtitle so the row matches the height of directory rows
            // (the list sizes itself to fit a fixed number of rows).
            return "Choose a folder to add and use"
        case .addSSH:
            return "Use a remote directory over SSH"
        case .userList(let dir), .roleDefault(let dir):
            if SSHSpec.isSSH(dir) {
                if case .success(let spec) = SSHSpec.parse(dir), let path = spec.path {
                    return path
                }
                return "Remote home directory"
            }
            return (dir as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Distinguishes the "Add a directory..." / "Add SSH path..." pseudo-entries,
/// a user-managed directory (from `working_directories`), and the role's
/// pinned default, so keyboard navigation and highlighting stay correct even
/// when paths overlap.
private enum WorkdirSelection: Identifiable, Hashable {
    case add
    case addSSH
    case userList(String)
    case roleDefault(String)

    var id: Self { self }

    var path: String? {
        switch self {
        case .add, .addSSH: return nil
        case .userList(let p), .roleDefault(let p): return p
        }
    }
}
