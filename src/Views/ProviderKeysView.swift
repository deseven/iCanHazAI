// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// The Manage Keys sheet ("Provider > Manage Keys…"): every stored API key,
/// grouped by provider and shown as its first and last 4 characters. A key can
/// be renamed (the key itself can't change) or deleted after a confirmation,
/// and each provider offers adding another one through the provider wizard,
/// which starts on its key step. Deleting the last key of a provider disables
/// it; with no key left at all the sheet closes (see `AppViewModel`).
struct ProviderKeysView: View {
    @EnvironmentObject var store: AppViewModel
    @StateObject private var model: ProviderKeysModel

    init(model: @autoclosure @escaping () -> ProviderKeysModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.providers) { configured in
                        providerSection(configured)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer
                .padding(12)
        }
        .frame(width: 520, height: 440)
        .sheet(item: pendingDeletion) { key in
            ConfirmActionSheet(
                title: "Delete this key?",
                message: model.deletionMessage(for: key),
                confirmLabel: "Delete",
                onCancel: { model.cancelDelete() },
                onConfirm: { model.confirmDelete() })
        }
    }

    private var pendingDeletion: Binding<StoredKey?> {
        Binding(
            get: { model.pendingDeletion },
            set: { if $0 == nil { model.cancelDelete() } })
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Manage Keys")
                .font(.title3.weight(.semibold))
            Text("A provider without keys is disabled. Keys are stored encrypted and tied to this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            // While a name is being edited, Return belongs to the editor's Save.
            Button("Done") { store.dismissSheet(.manageKeys) }
                .keyboardShortcut(model.renamingKey == nil ? .defaultAction : nil)
        }
    }

    // MARK: - Providers

    private func providerSection(_ configured: ConfiguredProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderTag(provider: configured.provider, color: configured.custom?.providerColor)
                Text(loaderPluralized(configured.keys.count, singular: "key", plural: "keys"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.presentSheet(.providerWizard(configured.provider))
                } label: {
                    Label("Add Key…", systemImage: "plus")
                }
                .controlSize(.small)
            }

            VStack(spacing: 0) {
                ForEach(configured.keys) { key in
                    ProviderKeyRow(
                        model: model,
                        key: key,
                        preview: configured.keyPreviews[key.id] ?? "",
                        isActive: key.id == configured.selectedKeyID)
                    if key.id != configured.keys.last?.id {
                        Divider()
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
        }
    }
}

// MARK: - Key row

private struct ProviderKeyRow: View {
    @ObservedObject var model: ProviderKeysModel
    let key: StoredKey
    let preview: String
    let isActive: Bool

    @FocusState private var nameFocused: Bool

    private var isRenaming: Bool { model.renamingKey?.id == key.id }

    var body: some View {
        Group {
            if isRenaming {
                editor
            } else {
                display
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var display: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                previewText
            }
            Spacer()
            Button {
                model.beginRename(key)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rename")
            .disabled(model.isWorking)
            Button {
                model.requestDelete(key)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .disabled(model.isWorking)
        }
    }

    private var editor: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Key name", text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onAppear {
                        nameFocused = true
                        DispatchQueue.main.async {
                            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        }
                    }
                if model.isDraftNameTaken {
                    Text("\(key.provider.displayName) already has a key with this name.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    previewText
                }
            }
            Button("Cancel") { model.cancelRename() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                .padding(.top, 2)
            Button("Save") { model.commitRename() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
                .disabled(!model.canCommitRename)
                .padding(.top, 2)
        }
    }

    private var previewText: some View {
        Text(preview)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
