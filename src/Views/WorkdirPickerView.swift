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
/// The list is empty by default — the user builds it up by adding directories.
/// The selected directory is saved to the chat data (alongside the role and
/// title), not to the app config.
struct WorkdirPickerView: View {
    @EnvironmentObject var store: AppViewModel
    let onCancel: () -> Void
    let onPick: (String) -> Void

    @State private var selection: String?
    @State private var addPicker: Bool = false
    @FocusState private var focused: Bool

    private var directories: [String] { store.workingDirectories }

    /// The currently selected chat's working directory, so we can highlight it.
    private var currentWorkdir: String? {
        guard let path = store.selectedChatWorkingDirectory else { return nil }
        return (path as NSString).standardizingPath
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

            if directories.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No directories")
                        .foregroundStyle(.secondary)
                    Text("Add one with the button below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(directories, id: \.self) { dir in
                                directoryRow(dir)
                                    .id(dir)
                                if dir != directories.last {
                                    Divider()
                                }
                            }
                        }
                    }
                    .onChange(of: selection) { _, newName in
                        guard let newName else { return }
                        proxy.scrollTo(newName, anchor: .center)
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
        .frame(width: 420, height: 420)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { pickCurrent(); return .handled }
        .onAppear {
            selection = currentWorkdir
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
        let isSelected = selection == dir
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
                if selection == dir { selection = nil }
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
            if hovering { selection = dir }
        }
        .onTapGesture { onPick(dir) }
    }

    /// Moves the keyboard selection by `delta` positions, clamped to the list.
    private func moveSelection(by delta: Int) {
        guard !directories.isEmpty else { return }
        let current = directories.firstIndex(where: { $0 == selection }) ?? 0
        let newIndex = min(max(current + delta, 0), directories.count - 1)
        selection = directories[newIndex]
    }

    /// Picks the currently selected directory (falling back to the first).
    private func pickCurrent() {
        if let dir = selection {
            onPick(dir)
        } else if let first = directories.first {
            onPick(first)
        }
    }
}
