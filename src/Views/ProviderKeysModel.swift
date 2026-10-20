// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// State of the Manage Keys sheet: the key being renamed, the one awaiting a
/// delete confirmation and the last failure. The keys themselves are read
/// through `providers`, so the list follows the engine.
@MainActor
final class ProviderKeysModel: ObservableObject {
    typealias Rename = @MainActor (UUID, String) async throws -> Void
    typealias Delete = @MainActor (UUID) async throws -> Void

    /// The key whose name is being edited.
    @Published private(set) var renamingKey: StoredKey?
    @Published var draftName = "" {
        didSet {
            if draftName.count > ProviderWizardModel.maxKeyNameLength {
                draftName = String(draftName.prefix(ProviderWizardModel.maxKeyNameLength))
            }
        }
    }
    /// The key awaiting a delete confirmation.
    @Published private(set) var pendingDeletion: StoredKey?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    private let providers: @MainActor () -> [ConfiguredProvider]
    private let rename: Rename
    private let delete: Delete
    private(set) var task: Task<Void, Never>?

    init(
        providers: @escaping @MainActor () -> [ConfiguredProvider], rename: @escaping Rename,
        delete: @escaping Delete
    ) {
        self.providers = providers
        self.rename = rename
        self.delete = delete
    }

    var trimmedDraftName: String { draftName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Two keys of one provider can't share a name (ignoring case), since the
    /// Provider menu tells them apart by it. The key's own name doesn't count.
    var isDraftNameTaken: Bool {
        guard let key = renamingKey else { return false }
        let siblings = providers().first { $0.provider == key.provider }?.keys ?? []
        return siblings.contains {
            $0.id != key.id
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(trimmedDraftName) == .orderedSame
        }
    }

    var canCommitRename: Bool {
        renamingKey != nil && !trimmedDraftName.isEmpty && !isDraftNameTaken && !isWorking
    }

    func beginRename(_ key: StoredKey) {
        guard !isWorking else { return }
        errorMessage = nil
        renamingKey = key
        draftName = key.name
    }

    func cancelRename() {
        renamingKey = nil
    }

    /// Saves the draft. An unchanged name just closes the editor.
    func commitRename() {
        guard canCommitRename, let key = renamingKey else { return }
        let name = trimmedDraftName
        guard name != key.name else {
            cancelRename()
            return
        }
        run { [rename] in
            try await rename(key.id, name)
            self.renamingKey = nil
        }
    }

    func requestDelete(_ key: StoredKey) {
        guard !isWorking else { return }
        errorMessage = nil
        pendingDeletion = key
    }

    func cancelDelete() {
        pendingDeletion = nil
    }

    func confirmDelete() {
        guard !isWorking, let key = pendingDeletion else { return }
        pendingDeletion = nil
        if renamingKey?.id == key.id { renamingKey = nil }
        run { [delete] in try await delete(key.id) }
    }

    /// What the delete confirmation says. Deleting a provider's last key
    /// disables the provider, and deleting the only key left sends the user
    /// back to adding a provider, so both are called out.
    func deletionMessage(for key: StoredKey) -> String {
        let all = providers()
        let name = key.provider.displayName
        var message = "The \(name) key '\(key.name)' will be permanently deleted. This action cannot be undone."
        if all.first(where: { $0.provider == key.provider })?.keys.count == 1 {
            message += " It is the last \(name) key, so \(name) will be disabled."
            if all.count == 1 { message += " No provider will be left, so you will need to add one again." }
        }
        return message
    }

    /// Waits for the operation started by the last action.
    func settle() async {
        await task?.value
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                try await operation()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isWorking = false
        }
    }
}
