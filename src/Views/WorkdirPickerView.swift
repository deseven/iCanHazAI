// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// A modal sheet for picking the per-chat working directory. Lists the
/// user-managed directories from the app config (`working_directories`), each
/// with a remove icon, plus an "Add" button that opens the macOS folder picker
/// to append a new entry. Selecting a directory sets it as the chat's working
/// directory override.
///
/// When the selected chat's role pre-sets a `working_directory` (and allows
/// overrides), that directory is pinned at the bottom as the default option —
/// mirroring how the role picker pins built-in roles — and is selected by
/// default so the user can press ↵ to accept it. The pinned default is shown
/// even if it duplicates an entry in `working_directories`.
///
/// The list is empty by default — the user builds it up by adding directories.
/// The selected directory is saved to the chat data (alongside the role and
/// title), not to the app config.
struct WorkdirPickerView: View {
    @EnvironmentObject var store: AppViewModel
    let onCancel: () -> Void
    let onPick: (String) -> Void

    @State private var selection: WorkdirSelection?
    @State private var addPicker: Bool = false
    @State private var rowHeight: CGFloat = 50
    @FocusState private var focused: Bool

    private var directories: [String] { store.workingDirectories }

    /// Number of directory rows that fit in the scroll area before a scrollbar
    /// appears. The actual pixel height is derived at runtime from a measured
    /// row, so the list shrinks to fit fewer rows and only scrolls past this.
    private let visibleRowCount = 6

    /// Scroll area height: the natural content height, capped so a scrollbar
    /// only appears once there are more than `visibleRowCount` rows.
    private var listHeight: CGFloat {
        let count = directories.count
        let content = rowHeight * CGFloat(count) + CGFloat(max(count - 1, 0))
        let cap = rowHeight * CGFloat(visibleRowCount) + CGFloat(visibleRowCount - 1)
        return min(content, cap)
    }

    /// The role's pre-set working directory (standardized), shown as a pinned
    /// default at the bottom when the role allows overrides. May duplicate an
    /// entry in `directories`; that's intentional — it's still offered as the
    /// default so the user can accept it with ↵.
    private var roleDefaultWorkdir: String? {
        guard let role = store.selectedRole,
              role.workingDirectoryOverrideAllowed,
              let path = role.workingDirectory, !path.isEmpty else { return nil }
        return (path as NSString).standardizingPath
    }

    /// The currently selected chat's working directory, so we can highlight it.
    private var currentWorkdir: String? {
        guard let path = store.selectedChatWorkingDirectory else { return nil }
        return (path as NSString).standardizingPath
    }

    /// Combined ordered list of selectable entries for keyboard navigation:
    /// user-managed directories followed by the role's pinned default (if any).
    private var allEntries: [WorkdirSelection] {
        var entries = directories.map { WorkdirSelection.userList($0) }
        if let roleDefault = roleDefaultWorkdir {
            entries.append(.roleDefault(roleDefault))
        }
        return entries
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Working directory")
                    .font(.headline)
                Text("Pick a directory for this chat. Added directories are saved to the app config and offered in every chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            if allEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No directories")
                        .foregroundStyle(.secondary)
                    Text("Add one with the button below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight * CGFloat(visibleRowCount))
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(directories, id: \.self) { dir in
                                    directoryRow(dir)
                                        .id(WorkdirSelection.userList(dir))
                                    if dir != directories.last {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(height: listHeight)

                        if let roleDefault = roleDefaultWorkdir {
                            // Pinned role-default row, always visible (mirrors
                            // the role picker's built-in section).
                            VStack(spacing: 0) {
                                PickerSectionHeader(title: "Default")
                                roleDefaultRow(roleDefault)
                                    .id(WorkdirSelection.roleDefault(roleDefault))
                            }
                            .background(Color.secondary.opacity(0.05))
                        }
                    }
                    .onPreferenceChange(RowHeightKey.self) { if $0 > 0 { rowHeight = $0 } }
                    .onChange(of: selection) { _, newSelection in
                        guard let newSelection else { return }
                        proxy.scrollTo(newSelection, anchor: .center)
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    addPicker = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 420)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { pickCurrent(); return .handled }
        .onAppear {
            if let roleDefault = roleDefaultWorkdir {
                selection = .roleDefault(roleDefault)
            } else if let current = currentWorkdir, directories.contains(current) {
                selection = .userList(current)
            } else {
                selection = allEntries.first
            }
            focused = true
        }
        .fileImporter(
            isPresented: $addPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    store.addWorkingDirectory(url.path)
                }
            case .failure:
                break
            }
        }
    }

    @ViewBuilder
    private func directoryRow(_ dir: String) -> some View {
        let isSelected = selection == .userList(dir)
        let isCurrent = currentWorkdir == dir
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text((dir as NSString).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Text((dir as NSString).abbreviatingWithTildeInPath)
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
            Button {
                store.removeWorkingDirectory(dir)
                if selection == .userList(dir) { selection = nil }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help("Remove directory")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { selection = .userList(dir) }
        }
        .onTapGesture { onPick(dir) }
        .measureRowHeight()
    }

    /// Pinned row for the role's pre-set working directory. Mirrors
    /// `directoryRow` but has no remove button (it's role-defined, not
    /// user-managed); the "Default" label lives in the section header above it.
    @ViewBuilder
    private func roleDefaultRow(_ dir: String) -> some View {
        let isSelected = selection == .roleDefault(dir)
        let isCurrent = currentWorkdir == dir
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text((dir as NSString).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Text((dir as NSString).abbreviatingWithTildeInPath)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { selection = .roleDefault(dir) }
        }
        .onTapGesture { onPick(dir) }
    }

    /// Moves the keyboard selection by `delta` positions, clamped to the list.
    private func moveSelection(by delta: Int) {
        guard !allEntries.isEmpty else { return }
        let current = selection.flatMap { allEntries.firstIndex(of: $0) } ?? 0
        let newIndex = min(max(current + delta, 0), allEntries.count - 1)
        selection = allEntries[newIndex]
    }

    /// Picks the currently selected directory (falling back to the first).
    private func pickCurrent() {
        if let sel = selection {
            onPick(sel.path)
        } else if let first = allEntries.first {
            onPick(first.path)
        }
    }
}

/// Distinguishes a user-managed directory (from `working_directories`) from the
/// role's pinned default, so keyboard navigation and highlighting stay correct
/// even when the two share the same path.
private enum WorkdirSelection: Hashable {
    case userList(String)
    case roleDefault(String)

    var path: String {
        switch self {
        case .userList(let p), .roleDefault(let p): return p
        }
    }
}
