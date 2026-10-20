// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The general preferences that hold a model, each picked via the model picker.
enum ModelSetting: String, Equatable {
    case defaultModel
    case utilityModel
}

/// Every sheet the main window can show. `AppViewModel.activeSheet` holds at
/// most one, so presenting a sheet replaces whichever one is showing.
enum MainSheet: Identifiable, Equatable {
    /// The first-run requirements sheet (provider, default and utility model).
    /// Shown whenever one of them is unmet; see `AppViewModel.onboardingActive`.
    case onboarding
    case preferences
    case providerWizard
    case mcpWizard
    case configErrors
    case rolePicker
    case sidebarRolePicker
    case sidebarDirectoryPicker
    case workdirPicker
    case modelPicker
    /// The model picker for a general model setting, opened from Preferences
    /// or from onboarding; returns to whichever opened it when done.
    case settingsModelPicker(ModelSetting)
    case mcpPicker
    case archivedChats
    case editMessage(UUID)
    case deleteMessage(UUID)
    case denyToolCall(callID: String)
    case renameChat(filename: String, initialText: String)
    case deleteChat(filename: String)

    /// Identifies the kind of sheet (plus its target), not its parameters, so a
    /// parameter change updates the showing sheet instead of re-presenting it.
    var id: String {
        switch self {
        case .onboarding: return "onboarding"
        case .preferences: return "preferences"
        case .providerWizard: return "providerWizard"
        case .mcpWizard: return "mcpWizard"
        case .configErrors: return "configErrors"
        case .rolePicker: return "rolePicker"
        case .sidebarRolePicker: return "sidebarRolePicker"
        case .sidebarDirectoryPicker: return "sidebarDirectoryPicker"
        case .workdirPicker: return "workdirPicker"
        case .modelPicker: return "modelPicker"
        case .settingsModelPicker(let setting): return "settingsModelPicker-\(setting.rawValue)"
        case .mcpPicker: return "mcpPicker"
        case .archivedChats: return "archivedChats"
        case .editMessage(let id): return "editMessage-\(id)"
        case .deleteMessage(let id): return "deleteMessage-\(id)"
        case .denyToolCall(let callID): return "denyToolCall-\(callID)"
        case .renameChat(let filename, _): return "renameChat-\(filename)"
        case .deleteChat(let filename): return "deleteChat-\(filename)"
        }
    }

    /// Sheets that aren't tied to the selected chat's state.
    var isAppLevel: Bool {
        switch self {
        case .onboarding, .preferences, .settingsModelPicker, .providerWizard, .mcpWizard, .configErrors: return true
        default: return false
        }
    }

    /// The only sheets that may be shown while onboarding is active: the
    /// onboarding sheet itself and the dialogs its buttons open.
    var isOnboardingFlow: Bool {
        switch self {
        case .onboarding, .providerWizard, .settingsModelPicker: return true
        default: return false
        }
    }
}

/// The single `.sheet(item:)` body of the main window.
struct MainSheetContent: View {
    let sheet: MainSheet
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        switch sheet {
        case .onboarding:
            OnboardingView()

        case .preferences:
            PreferencesView()

        case .providerWizard:
            ProviderWizardView(
                existingKeyNames: Dictionary(
                    uniqueKeysWithValues: store.providers.map { ($0.provider, $0.keys.map(\.name)) }),
                onClose: { store.closeProviderWizard() })

        case .mcpWizard:
            MCPWizardView(onFinish: { store.refreshPreferences() })

        case .configErrors:
            ConfigErrorsSheet(
                errors: store.configErrors,
                onAcknowledge: { store.showConfigErrors = false },
                onFix: { store.fixWithConfigurator() }
            )

        case .rolePicker:
            RolePickerView(
                mode: store.rolePickerMode,
                onCancel: { store.rolePickerCancelled() },
                onPick: { store.rolePickerPicked(role: $0) },
                diskAccessOnly: store.chatListMode == .directory
            )

        case .sidebarRolePicker:
            RolePickerView(
                mode: .newChat,
                onCancel: { store.sidebarRolePickerCancelled() },
                onPick: { store.sidebarRolePickerPicked(role: $0) }
            )

        case .sidebarDirectoryPicker:
            WorkdirPickerView(
                onCancel: { store.sidebarDirectoryPickerCancelled() },
                onPick: { store.sidebarDirectoryPickerPicked($0) }
            )

        case .workdirPicker:
            WorkdirPickerView(
                onCancel: { store.showWorkdirPicker = false },
                onPick: { path in
                    // Every pick is recorded as most-recently-used so the
                    // picker's recent list stays relevant.
                    store.recordWorkingDirectory(path)
                    store.setWorkingDirectory(path)
                    store.showWorkdirPicker = false
                }
            )

        case .modelPicker:
            ModelPickerView(
                models: store.models,
                hasProviders: !store.providers.isEmpty,
                currentID: store.selectedChatModelID,
                defaultID: store.preferencesModelID(for: .defaultModel),
                onCancel: { store.modelPickerCancelled() },
                onPick: { store.modelPickerPicked($0) }
            )

        case .settingsModelPicker(let setting):
            ModelPickerView(
                models: store.models,
                hasProviders: !store.providers.isEmpty,
                currentID: store.preferencesModelID(for: setting),
                defaultID: store.preferencesModelID(for: .defaultModel),
                subtitle: setting == .defaultModel
                    ? "Pick the model preselected for new chats."
                    : "Pick the model for background tasks. A fast and cheap one is best.",
                onCancel: { store.settingsModelPickerCancelled() },
                onPick: { store.settingsModelPicked(setting, $0) }
            )

        case .mcpPicker:
            MCPPickerView(
                servers: store.mcps,
                initiallySelected: Set(store.selectedChatMCPNames),
                onCancel: { store.showMCPPicker = false },
                onApply: { names in
                    store.setChatMCPs(names)
                    store.showMCPPicker = false
                }
            )

        case .archivedChats:
            ArchivedChatsPickerView(onCancel: { store.dismissSheet(.archivedChats) })

        case .editMessage(let id):
            if let item = store.selectedChatItem, let msg = item.chat?.message(id: id) {
                let followOn = ChatView.followOnMessageCount(for: id, in: item.chat)
                EditMessageSheet(
                    initialText: msg.content,
                    followOnWarning: msg.role == .user && followOn > 0
                        ? "Saving will regenerate the response; \(followOn) following message(s) will be deleted."
                        : nil,
                    onCancel: { store.dismissSheet(sheet) },
                    onConfirm: { newText in
                        store.editMessage(messageID: id, to: newText)
                        store.dismissSheet(sheet)
                    }
                )
            }

        case .deleteMessage(let id):
            if let item = store.selectedChatItem {
                let followOn = ChatView.followOnMessageCount(for: id, in: item.chat)
                ConfirmActionSheet(
                    title: "Delete this message?",
                    message: followOn > 0
                        ? "This action cannot be undone. This will also delete \(followOn) following message(s)."
                        : "This action cannot be undone.",
                    confirmLabel: "Delete",
                    onCancel: { store.dismissSheet(sheet) },
                    onConfirm: {
                        store.deleteMessage(messageID: id)
                        store.dismissSheet(sheet)
                    }
                )
            }

        case .denyToolCall(let callID):
            DenyToolCallSheet(
                onCancel: { store.dismissSheet(sheet) },
                onConfirm: { reason in
                    store.denyToolCall(callID: callID, reason: reason)
                    store.dismissSheet(sheet)
                }
            )

        case .renameChat(let filename, let initialText):
            RenameChatSheet(
                initialText: initialText,
                onCancel: { store.dismissSheet(sheet) },
                onConfirm: { newTitle in
                    store.renameChat(filename, to: newTitle)
                    store.dismissSheet(sheet)
                }
            )

        case .deleteChat(let filename):
            ConfirmActionSheet(
                title: "Delete this chat?",
                message: "This action cannot be undone.",
                confirmLabel: "Delete",
                onCancel: { store.dismissSheet(sheet) },
                onConfirm: {
                    store.deleteChat(filename)
                    store.dismissSheet(sheet)
                }
            )
        }
    }
}
