import Foundation
import Testing

@testable import iCanHazAI

private func configured(_ provider: Provider, _ names: String...) -> ConfiguredProvider {
    let keys = names.map { StoredKey(id: UUID(), provider: provider, name: $0) }
    return ConfiguredProvider(
        provider: provider, keys: keys, selectedKeyID: keys.first?.id, modelCount: nil, isRefreshing: false,
        lastRefresh: nil, lastError: nil)
}

/// Records what the model asked its injected closures to do.
@MainActor
private final class KeysProbe {
    var providers: [ConfiguredProvider]
    var renames: [(id: UUID, name: String)] = []
    var deletions: [UUID] = []
    var failure: Error?
    var delay: Duration?

    init(_ providers: [ConfiguredProvider]) { self.providers = providers }

    func key(_ provider: Provider, _ name: String) -> StoredKey {
        providers.first { $0.provider == provider }!.keys.first { $0.name == name }!
    }

    func makeModel() -> ProviderKeysModel {
        ProviderKeysModel(
            providers: { [unowned self] in providers },
            rename: { [unowned self] id, name in
                if let delay { try await Task.sleep(for: delay) }
                if let failure { throw failure }
                renames.append((id, name))
            },
            delete: { [unowned self] id in
                if let delay { try await Task.sleep(for: delay) }
                if let failure { throw failure }
                deletions.append(id)
            })
    }
}

private struct SaveError: LocalizedError { var errorDescription: String? { "the store is locked" } }

extension AllAppTests {
    @Suite("ProviderKeysModel")
    @MainActor
    struct ProviderKeysModelTests {
        private func probe() -> KeysProbe {
            KeysProbe([configured(.openai, "Default", "Work"), configured(.anthropic, "Default")])
        }

        // MARK: - Renaming

        @Test("renaming starts from the current name and can be cancelled")
        func beginAndCancel() {
            let p = probe()
            let model = p.makeModel()
            let work = p.key(.openai, "Work")

            model.beginRename(work)
            #expect(model.renamingKey == work)
            #expect(model.draftName == "Work")

            model.cancelRename()
            #expect(model.renamingKey == nil)
            #expect(p.renames.isEmpty)
        }

        @Test("saving renames the key to the trimmed name and closes the editor")
        func commit() async {
            let p = probe()
            let model = p.makeModel()
            let work = p.key(.openai, "Work")

            model.beginRename(work)
            model.draftName = "  Personal  "
            #expect(model.canCommitRename)
            model.commitRename()
            await model.settle()

            #expect(p.renames.map(\.id) == [work.id])
            #expect(p.renames.map(\.name) == ["Personal"])
            #expect(model.renamingKey == nil)
            #expect(model.errorMessage == nil)
            #expect(!model.isWorking)
        }

        @Test("an unchanged name just closes the editor, a change of case is a rename")
        func unchangedName() async {
            let p = probe()
            let model = p.makeModel()
            let work = p.key(.openai, "Work")

            model.beginRename(work)
            model.draftName = " Work "
            model.commitRename()
            await model.settle()
            #expect(model.renamingKey == nil)
            #expect(p.renames.isEmpty)

            model.beginRename(work)
            model.draftName = "WORK"
            model.commitRename()
            await model.settle()
            #expect(p.renames.map(\.name) == ["WORK"])
        }

        @Test("an empty name or one used by another key of the provider is refused, ignoring case")
        func invalidNames() async {
            let p = probe()
            let model = p.makeModel()
            let work = p.key(.openai, "Work")
            model.beginRename(work)

            model.draftName = "   "
            #expect(!model.canCommitRename)

            model.draftName = "default"
            #expect(model.isDraftNameTaken)
            #expect(!model.canCommitRename)
            model.commitRename()
            await model.settle()
            #expect(p.renames.isEmpty)
            #expect(model.renamingKey == work)

            model.draftName = "Spare"
            #expect(!model.isDraftNameTaken)
            #expect(model.canCommitRename)
        }

        @Test("another provider may use the same name")
        func sameNameOtherProvider() {
            let p = probe()
            let model = p.makeModel()
            model.beginRename(p.key(.anthropic, "Default"))
            model.draftName = "Work"
            #expect(!model.isDraftNameTaken)
            #expect(model.canCommitRename)
        }

        @Test("the name is limited to 30 characters")
        func nameLimit() {
            let p = probe()
            let model = p.makeModel()
            model.beginRename(p.key(.openai, "Work"))
            model.draftName = String(repeating: "x", count: 50)
            #expect(model.draftName.count == ProviderWizardModel.maxKeyNameLength)
        }

        @Test("a failed rename keeps the editor open and shows the reason")
        func renameFailure() async {
            let p = probe()
            p.failure = SaveError()
            let model = p.makeModel()
            model.beginRename(p.key(.openai, "Work"))
            model.draftName = "Personal"
            model.commitRename()
            await model.settle()

            #expect(model.renamingKey != nil)
            #expect(model.errorMessage == "the store is locked")
            #expect(!model.isWorking)

            // Starting over clears the message.
            model.beginRename(p.key(.openai, "Default"))
            #expect(model.errorMessage == nil)
        }

        // MARK: - Deleting

        @Test("a delete needs a confirmation, and cancelling it deletes nothing")
        func deleteConfirmation() async {
            let p = probe()
            let model = p.makeModel()
            let work = p.key(.openai, "Work")

            model.requestDelete(work)
            #expect(model.pendingDeletion == work)
            #expect(p.deletions.isEmpty)

            model.cancelDelete()
            #expect(model.pendingDeletion == nil)
            model.confirmDelete()
            await model.settle()
            #expect(p.deletions.isEmpty)

            model.requestDelete(work)
            model.confirmDelete()
            await model.settle()
            #expect(p.deletions == [work.id])
            #expect(model.pendingDeletion == nil)
            #expect(model.errorMessage == nil)
        }

        @Test("a failed delete shows the reason")
        func deleteFailure() async {
            let p = probe()
            p.failure = SaveError()
            let model = p.makeModel()
            model.requestDelete(p.key(.openai, "Work"))
            model.confirmDelete()
            await model.settle()

            #expect(p.deletions.isEmpty)
            #expect(model.pendingDeletion == nil)
            #expect(model.errorMessage == "the store is locked")
        }

        @Test("deleting the key being renamed closes its editor")
        func deleteRenamingKey() async {
            let p = probe()
            let model = p.makeModel()
            let work = p.key(.openai, "Work")
            model.beginRename(work)
            model.requestDelete(work)
            model.confirmDelete()
            await model.settle()
            #expect(model.renamingKey == nil)
            #expect(p.deletions == [work.id])

            model.beginRename(p.key(.openai, "Default"))
            model.requestDelete(p.key(.anthropic, "Default"))
            model.confirmDelete()
            await model.settle()
            #expect(model.renamingKey?.name == "Default")
        }

        @Test("the confirmation calls out when it removes a provider's last key, or the last key altogether")
        func deletionMessages() {
            let p = probe()
            let model = p.makeModel()

            let work = model.deletionMessage(for: p.key(.openai, "Work"))
            #expect(work.contains("OpenAI key 'Work'"))
            #expect(work.contains("cannot be undone"))
            #expect(!work.contains("disabled"))

            let lastOfProvider = model.deletionMessage(for: p.key(.anthropic, "Default"))
            #expect(lastOfProvider.contains("last Anthropic key"))
            #expect(lastOfProvider.contains("Anthropic will be disabled"))
            #expect(!lastOfProvider.contains("No provider will be left"))

            p.providers = [configured(.anthropic, "Default")]
            let lastOfAll = model.deletionMessage(for: p.key(.anthropic, "Default"))
            #expect(lastOfAll.contains("Anthropic will be disabled"))
            #expect(lastOfAll.contains("No provider will be left"))
        }

        // MARK: - While busy

        @Test("nothing else starts while an operation runs")
        func busy() async throws {
            let p = probe()
            p.delay = .milliseconds(100)
            let model = p.makeModel()
            let work = p.key(.openai, "Work")
            model.beginRename(work)
            model.draftName = "Personal"
            model.commitRename()
            #expect(model.isWorking)
            #expect(!model.canCommitRename)

            model.requestDelete(p.key(.openai, "Default"))
            #expect(model.pendingDeletion == nil)
            model.beginRename(p.key(.anthropic, "Default"))
            #expect(model.renamingKey == work)

            await model.settle()
            #expect(!model.isWorking)
            #expect(p.renames.map(\.name) == ["Personal"])
            #expect(model.renamingKey == nil)
        }
    }
}
