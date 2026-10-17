// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// The chat screen: header, message list and input. Only the header, the
/// drop overlay and the sheets are SwiftUI; the list and the input live in
/// one AppKit pane (`NativeChatView`) so the input can grow in step with the
/// list, and typing never invalidates this view.
struct ChatView: View {
    @EnvironmentObject var store: AppViewModel
    @StateObject private var input = ChatInputController()
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderBar {
                store.chatInfoSidebarVisible.toggle()
            }

            Divider()

            NativeChatView(input: input)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if isDropTargeted && store.selectedChatSupportsAttachments {
                DropPlaceholder()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            input.handleDrop(providers: providers)
        }
        .sheet(
            item: Binding(
                get: { store.pendingEditMessageID.map { PendingID(id: $0) } },
                set: { if $0 == nil { store.pendingEditMessageID = nil } }
            )
        ) { pending in
            if let item = store.selectedChatItem,
                let msg = item.chat?.message(id: pending.id)
            {
                let followOn = Self.followOnMessageCount(for: pending.id, in: item.chat)
                EditMessageSheet(
                    initialText: msg.content,
                    followOnWarning: msg.role == .user && followOn > 0
                        ? "Saving will regenerate the response; \(followOn) following message(s) will be deleted."
                        : nil,
                    onCancel: { store.pendingEditMessageID = nil },
                    onConfirm: { newText in
                        store.editMessage(messageID: pending.id, to: newText)
                        store.pendingEditMessageID = nil
                    }
                )
            }
        }
        .sheet(
            item: Binding(
                get: { store.pendingDeleteMessageID.map { PendingID(id: $0) } },
                set: { if $0 == nil { store.pendingDeleteMessageID = nil } }
            )
        ) { pending in
            if let item = store.selectedChatItem {
                let followOn = Self.followOnMessageCount(for: pending.id, in: item.chat)
                ConfirmActionSheet(
                    title: "Delete this message?",
                    message: followOn > 0
                        ? "This action cannot be undone. This will also delete \(followOn) following message(s)."
                        : "This action cannot be undone.",
                    confirmLabel: "Delete",
                    onCancel: { store.pendingDeleteMessageID = nil },
                    onConfirm: {
                        store.deleteMessage(messageID: pending.id)
                        store.pendingDeleteMessageID = nil
                    }
                )
            }
        }
        .sheet(
            item: Binding(
                get: { store.pendingDenyToolCallID.map { ToolCallIDTarget(callID: $0) } },
                set: { if $0 == nil { store.pendingDenyToolCallID = nil } }
            )
        ) { target in
            DenyToolCallSheet(
                onCancel: { store.pendingDenyToolCallID = nil },
                onConfirm: { reason in
                    store.denyToolCall(callID: target.callID, reason: reason)
                    store.pendingDenyToolCallID = nil
                }
            )
        }
        .sheet(isPresented: $store.showWorkdirPicker) {
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
        }
        .sheet(isPresented: $store.showConnectionPicker) {
            ConnectionPickerView(
                connections: store.connections,
                currentID: store.selectedChatConnectionID,
                onCancel: { store.showConnectionPicker = false },
                onPick: { connection in
                    store.setConnection(connection.id)
                    store.showConnectionPicker = false
                }
            )
        }
        .sheet(isPresented: $store.showMCPPicker) {
            MCPPickerView(
                servers: store.mcps,
                initiallySelected: Set(store.selectedChatMCPNames),
                onCancel: { store.showMCPPicker = false },
                onApply: { names in
                    store.setChatMCPs(names)
                    store.showMCPPicker = false
                }
            )
        }
    }

    /// A header bar that sits at the top of the chat content area (below the
    /// window titlebar). By living inside the content, it naturally shifts left
    /// when the inspector panel opens — unlike toolbar items which span the full
    /// titlebar width regardless of the inspector.
    ///
    /// The model (connection) control is always shown; it's clickable only
    /// when the role allows a connection override. The prompt picker,
    /// working-directory picker, and MCP picker are shown only when the
    /// chat's role allows the corresponding
    /// override. The MCP control is hidden entirely when no custom MCP servers
    /// are configured; without override permission it only displays the
    /// role's selection (and hides when that's empty).
    private struct ChatHeaderBar: View {
        @EnvironmentObject var store: AppViewModel
        let onToggleInfo: () -> Void

        var body: some View {
            HStack(spacing: 8) {

                if store.selectedChatPromptPickerVisible {
                    Picker(
                        "Prompt",
                        selection: Binding(
                            get: { store.selectedChatPromptName ?? "" },
                            set: { store.setPrompt($0.isEmpty ? nil : $0) }
                        )
                    ) {
                        Text("No prompt").tag("")
                        ForEach(store.prompts) { prompt in
                            Text(prompt.name).tag(prompt.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(store.isStreaming)
                }

                // The model, workdir and MCP controls share the same look: an
                // icon plus tag(s), white while the value can be (re)set via a
                // picker, grey when it's fixed. Red marks a missing required
                // directory. `allowsHitTesting` is used instead of `disabled`
                // so the colors aren't dimmed.
                if store.selectedChatConnectionControlVisible {
                    Button {
                        store.showConnectionPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                            toolbarTag(store.selectedChatConnection?.displayName ?? "No connection")
                        }
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(store.selectedChatConnectionPickerEnabled ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(connectionHelp)
                    .allowsHitTesting(store.selectedChatConnectionPickerEnabled && !store.isStreaming)
                }

                if store.selectedChatWorkdirPickerVisible {
                    Button {
                        store.showWorkdirPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(
                                systemName: AppViewModel.workdirIcon(
                                    directory: store.selectedChatWorkingDirectory,
                                    isolated: store.selectedChatWorkdirIsolated
                                ))
                            toolbarTag(workdirLabel)
                        }
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(workdirColor)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(workdirHelp)
                    .allowsHitTesting(store.selectedChatWorkdirPickerEnabled && !store.isStreaming)
                }

                // MCP control: tags for the chat's active custom MCP servers.
                // Opens the multi-select picker when the role allows overrides;
                // otherwise it's a read-only display of the role's selection.
                if store.selectedChatMCPControlVisible {
                    Button {
                        store.showMCPPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.and.screwdriver")
                            if store.selectedChatMCPNames.isEmpty {
                                toolbarTag("No MCPs selected")
                            } else {
                                ForEach(store.selectedChatMCPNames, id: \.self) { name in
                                    toolbarTag(name)
                                }
                            }
                        }
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(mcpColor)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(mcpHelp)
                    .allowsHitTesting(store.selectedChatMCPPickerEnabled && !store.isStreaming)
                }

                Spacer()

                if store.selectedChatSupportsChatTrees {
                    Button(action: { store.openTreeOverview() }) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.title3)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isStreaming)
                    .help("Tree overview")
                }

                Button(action: onToggleInfo) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(store.chatInfoSidebarVisible ? "Hide chat info" : "Show chat info")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
        }

        /// A grey-capsule tag used by the model, workdir and MCP toolbar controls.
        private func toolbarTag(_ text: String) -> some View {
            Text(text)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }

        private var workdirLabel: String {
            if let path = store.selectedChatWorkingDirectory, !path.isEmpty {
                return (path as NSString).abbreviatingWithTildeInPath
            }
            return "No directory"
        }

        /// Red when a required directory is missing (the chat is blocked
        /// until the user picks one); white while the directory can be
        /// picked; grey once it's fixed (picked or pre-set by the role).
        private var workdirColor: Color {
            if store.selectedChatWorkdirRequired { return .red }
            return store.selectedChatWorkdirPickerEnabled ? .primary : .secondary
        }

        /// White when the MCP selection can be changed; grey when it's fixed
        /// by the role.
        private var mcpColor: Color {
            store.selectedChatMCPPickerEnabled ? .primary : .secondary
        }

        private var connectionHelp: String {
            let model = store.selectedChatConnection.map { " (\($0.model))" } ?? ""
            if store.selectedChatConnectionPickerEnabled {
                return "Model used for this chat" + model
            }
            return "Model (set by role)" + model
        }

        private var mcpHelp: String {
            if store.selectedChatMCPPickerEnabled {
                return "MCP servers active for this chat"
            }
            return "MCP servers (set by role)"
        }

        private var workdirHelp: String {
            if store.selectedChatWorkdirRequired {
                return "A working directory is required by this role"
            }
            if !store.selectedChatWorkdirPickerEnabled {
                return "Working directory (fixed for this chat)"
            }
            return "Working directory (permanent once picked)"
        }
    }
}

// MARK: - DropPlaceholder

/// Full-pane overlay shown while files are dragged over the chat, inviting
/// the user to drop them. Purely visual: hit testing is disabled so the drag
/// session keeps reaching the `onDrop` destination underneath.
private struct DropPlaceholder: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            Color.accentColor.opacity(0.7),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                        )
                )
                .padding(12)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text("Drop files to attach")
                    .font(.title2.weight(.medium))
                Text("They will be added to your next message")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Helpers

/// Uniform type identifiers accepted by the attachment file picker. Includes
/// image formats plus common document and plain-text types so the picker
/// accepts anything the classifier can route.
enum AttachmentPickerTypes {
    /// Memoized: this is read on every `ChatView` body evaluation (it's the
    /// `allowedContentTypes` of the file importer), so it must not rebuild the
    /// set per call — during streaming the body runs on every token flush.
    static let supported: [UTType] = {
        var types: [UTType] = []
        // Image formats.
        for uti in ImageProcessor.supportedTypeIdentifiers {
            if let t = UTType(uti) {
                types.append(t)
            }
        }
        // Document formats.
        let docUTIs: [UTType?] = [
            UTType("com.adobe.pdf"),
            UTType("org.openxmlformats.wordprocessingml.document"),
            UTType("com.microsoft.word.doc"),
            UTType("org.oasis.opendocument.text"),
            UTType("public.rtf"),
            UTType("com.apple.rtfd"),
            UTType("com.apple.webarchive"),
        ]
        for t in docUTIs { if let t { types.append(t) } }
        // Plain text and source code.
        types.append(.plainText)
        types.append(.html)
        types.append(.json)
        types.append(.xml)
        types.append(.sourceCode)
        types.append(.yaml)
        // Deduplicate while preserving order.
        var seen = Set<UTType>()
        return types.filter { seen.insert($0).inserted }
    }()
}

/// A wrapper that makes a `UUID` `Identifiable` so it can drive `.sheet(item:)`.
private struct PendingID: Identifiable {
    let id: UUID
}

extension ChatView {
    /// The number of messages that follow `messageID` in the chat — i.e. the
    /// continuation that a delete or user-message edit would remove. Pure so it
    /// can be unit-tested without a view instance.
    nonisolated static func followOnMessageCount(for messageID: UUID, in chat: Chat?) -> Int {
        guard let chat else { return 0 }
        let active = chat.activeMessages
        guard let idx = active.firstIndex(where: { $0.id == messageID }) else { return 0 }
        return max(0, active.count - idx - 1)
    }
}

/// A wrapper that makes a tool-call id `Identifiable` so it can drive
/// `.sheet(item:)` for the deny-reason sheet.
private struct ToolCallIDTarget: Identifiable {
    let callID: String
    var id: String { callID }
}

/// A modal asking for an optional reason when the user denies a tool call.
/// An empty reason sends a generic denial to the model; a non-empty reason is
/// forwarded verbatim. Cancel returns to the Allow/Deny buttons without
/// resolving.
struct DenyToolCallSheet: View {
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var reason: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deny tool call")
                .font(.headline)

            Text("Optionally provide a reason to send back to the model.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Single-line input: Return triggers the Deny button (default
            // action) rather than inserting a newline.
            TextField("Optional reason", text: $reason)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Deny") { onConfirm(reason) }
                    .keyboardShortcut(.defaultAction)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            isFocused = true
        }
    }
}
