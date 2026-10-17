// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import UniformTypeIdentifiers

/// Connects the AppKit input bar to the app: sending, per-chat drafts,
/// attachments (picker, paste, drop) and focus.
///
/// Typing never goes through SwiftUI. The text lives in the bar's text view
/// and is read only when needed (send, draft save); store changes are
/// coalesced into one cheap refresh per run-loop turn.
@MainActor
final class ChatInputController: ObservableObject {
    let bar = ChatInputBarView()
    let queueView = QueuedMessagesView()

    private weak var store: AppViewModel?
    private var storeChanges: AnyCancellable?
    private var refreshScheduled = false
    private var currentChatID: String?
    private var attachments: [PendingAttachment] = []
    private var facts = ChatInputFacts()
    private var optionHeld = false
    private var flagsMonitor: Any?
    private var lastFocusRequest = 0
    private var wantsFocus = false

    init() {
        bar.onTextChange = { [weak self] in self?.updateBarState() }
        bar.onAction = { [weak self] in self?.handleAction() }
        bar.onAttach = { [weak self] in self?.showFilePicker() }
        bar.onRemoveAttachment = { [weak self] id in self?.removeAttachment(id) }
        queueView.onSendNow = { [weak self] in self?.store?.sendQueuedMessagesNow() }
        queueView.onDiscard = { [weak self] in self?.store?.clearQueuedMessages() }
        bar.textView.returnHandler = { [weak self] in
            self?.submit()
            return true
        }
        bar.textView.attachmentPasteHandler = { [weak self] in self?.pasteAttachments() ?? false }
    }

    // MARK: Lifecycle

    func bind(store: AppViewModel) {
        self.store = store
        storeChanges = store.objectWillChange.sink { [weak self] _ in
            // `objectWillChange` fires before the new values are in place.
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
        currentChatID = store.selectedChatID
        restoreDraft(for: currentChatID)
        lastFocusRequest = store.chatInputFocusRequest
        refreshFacts()
        requestFocus()

        optionHeld = NSEvent.modifierFlags.contains(.option)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setOptionHeld(event.modifierFlags.contains(.option))
            return event
        }
    }

    func unbind() {
        saveDraft(for: currentChatID)
        storeChanges = nil
        store = nil
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    // MARK: Store state

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshFacts()
        }
    }

    private func refreshFacts() {
        guard let store else { return }
        if store.selectedChatID != currentChatID {
            saveDraft(for: currentChatID)
            currentChatID = store.selectedChatID
            restoreDraft(for: currentChatID)
            requestFocus()
        }
        if store.chatInputFocusRequest != lastFocusRequest {
            lastFocusRequest = store.chatInputFocusRequest
            requestFocus()
        }
        let queued = store.selectedChatQueuedMessages
        facts = ChatInputFacts(
            supportsAttachments: store.selectedChatSupportsAttachments,
            hasValidRole: store.selectedChatHasValidRole,
            hasConnection: store.selectedChatHasConnection,
            workdirRequired: store.selectedChatWorkdirRequired,
            lastMessageIsFromUser: store.selectedChatLastMessageIsFromUser,
            isStreaming: store.isStreaming,
            stopAfterIterationPending: store.stopAfterIterationPending,
            queuedCount: queued.count)
        queueView.setItems(queued.map(\.preview))
        updateBarState()
    }

    /// Pushes facts plus the typed content to the bar. Per keystroke this is
    /// only a struct comparison, because `facts` is cached.
    private func updateBarState() {
        let action: ChatInputAction
        if facts.isStreaming && hasContent && !facts.inputDisabled {
            action = optionHeld ? .sendImmediately : .queue
        } else if facts.stopAfterIterationPending {
            action = .finishing
        } else if facts.isStreaming {
            action = .stop(afterIteration: optionHeld)
        } else {
            action = .send(
                enabled: facts.actionEnabled(hasText: bar.hasNonBlankText, hasAttachments: !attachments.isEmpty))
        }
        bar.state = ChatInputBarState(
            showsAttachButton: facts.supportsAttachments,
            attachEnabled: !facts.inputDisabled,
            inputEnabled: !facts.inputDisabled,
            action: action)
    }

    private func setOptionHeld(_ held: Bool) {
        guard held != optionHeld else { return }
        optionHeld = held
        updateBarState()
    }

    // MARK: Drafts

    /// Saves the current input (text + pending attachments) as the runtime-only
    /// draft for the given chat, so it survives switching to another chat.
    private func saveDraft(for chatID: String?) {
        guard let chatID, let store else { return }
        store.inputDrafts.set(ChatInputDraft(text: bar.text, attachments: attachments), for: chatID)
    }

    /// Restores the saved draft for the given chat, or clears the input when
    /// no draft exists. Restoring never animates: it's a different chat, not an edit.
    private func restoreDraft(for chatID: String?) {
        let draft = chatID.flatMap { store?.inputDrafts.draft(for: $0) }
        attachments = draft?.attachments ?? []
        bar.setAttachments(chipItems(), animated: false)
        bar.setText(draft?.text ?? "", animated: false)
    }

    // MARK: Sending

    private var hasContent: Bool { bar.hasNonBlankText || !attachments.isEmpty }

    private func handleAction() {
        guard let store else { return }
        if store.isStreaming && !hasContent {
            // Holding Option requests a graceful stop: the current iteration
            // (model response + its tool calls) finishes, then the stream
            // stops without another model request.
            if NSEvent.modifierFlags.contains(.option) {
                store.stopStreamingAfterIteration()
            } else {
                store.stopStreaming()
            }
            return
        }
        submit()
    }

    /// Return key and button: while streaming, what was typed is queued (or,
    /// with Option held, sent right away); otherwise it is sent.
    private func submit() {
        guard let store else { return }
        guard store.isStreaming else {
            send()
            return
        }
        guard hasContent, !facts.inputDisabled else { return }
        let (text, sending) = takeInput()
        if NSEvent.modifierFlags.contains(.option) {
            store.sendMessageImmediately(text, pendingAttachments: sending)
        } else {
            store.queueMessage(text, pendingAttachments: sending)
        }
    }

    /// Returns the typed text and pending attachments and clears the input.
    private func takeInput() -> (String, [PendingAttachment]) {
        let text = bar.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = attachments
        attachments = []
        bar.setAttachments([], animated: true)
        bar.setText("", animated: true)
        return (text, sending)
    }

    private func send() {
        guard let store, store.selectedChatHasConnection, !store.isStreaming else { return }
        // Empty input with no attachments: send what is still queued (after a
        // stop or an error), or else, if the last message is from the user,
        // trigger a regenerate of the assistant reply on that message.
        if !hasContent {
            if facts.queuedCount > 0 {
                store.sendQueuedMessagesNow()
                return
            }
            guard store.selectedChatLastMessageIsFromUser else { return }
            store.retryLastMessage()
            return
        }
        let (text, sending) = takeInput()
        store.sendMessage(text, pendingAttachments: sending)
    }

    // MARK: Focus

    /// Asks for the input to take keyboard focus, retrying until it sticks.
    /// SwiftUI's focus machinery doesn't reliably drive focus into AppKit
    /// views (the chat list can hold first-responder status), and at app
    /// start the main window is created hidden and shown later, so the first
    /// attempts may find no usable window.
    func requestFocus() {
        wantsFocus = true
        DispatchQueue.main.async { [weak self] in self?.claimFocus(attemptsLeft: 20) }
    }

    private func claimFocus(attemptsLeft: Int) {
        guard wantsFocus else { return }
        if !bar.isTextFocused { bar.focusText() }
        if bar.isTextFocused {
            wantsFocus = false
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.claimFocus(attemptsLeft: attemptsLeft - 1)
        }
    }

    // MARK: Attachments

    private func chipItems() -> [AttachmentChipItem] {
        attachments.map {
            AttachmentChipItem(id: $0.id, kind: $0.kind, name: $0.originalName ?? Self.defaultName(for: $0))
        }
    }

    /// A display name for a pending attachment that has no original filename.
    nonisolated static func defaultName(for attachment: PendingAttachment) -> String {
        switch attachment.kind {
        case .image: return "image"
        case .text: return "text"
        case .document: return "document"
        case .unsupportedBinary: return "file"
        }
    }

    private func addAttachment(_ attachment: PendingAttachment) {
        attachments.append(attachment)
        bar.setAttachments(chipItems(), animated: true)
        updateBarState()
    }

    private func removeAttachment(_ id: UUID) {
        attachments.removeAll(where: { $0.id == id })
        bar.setAttachments(chipItems(), animated: true)
        updateBarState()
    }

    private func intake(urls: [URL]) {
        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if let attachment = AttachmentManager.intake(fileURL: url) {
                addAttachment(attachment)
            }
        }
    }

    private func showFilePicker() {
        guard let window = bar.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AttachmentPickerTypes.supported
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.intake(urls: urls) }
        }
    }

    /// Handles drag-and-dropped files anywhere on the chat pane.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard facts.supportsAttachments else { return false }
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                guard let url = object as? URL else { return }
                DispatchQueue.main.async { self?.intake(urls: [url]) }
            }
            accepted = true
        }
        return accepted
    }

    /// Checks the system pasteboard for attachment content and, if found,
    /// attaches it as a pending attachment. Returns true if an attachment was
    /// consumed (so the caller can swallow the paste event), false to let
    /// normal text paste proceed. No-op (returns false) when the selected
    /// chat's role doesn't enable attachments.
    private func pasteAttachments() -> Bool {
        guard facts.supportsAttachments else { return false }
        let pb = NSPasteboard.general

        // 1. File URLs first (e.g. a file copied in Finder). We prefer the
        //    actual file content over any TIFF/PNG representation on the
        //    pasteboard, because Finder also places the file's *icon* as TIFF
        //    data — reading that would attach the icon, not the real file.
        //    A copied screenshot carries no file URL, so it falls through to
        //    the direct-image-data path below.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            var added = false
            for url in urls {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                if let attachment = AttachmentManager.intake(fileURL: url) {
                    addAttachment(attachment)
                    added = true
                }
            }
            if added { return true }
        }

        if let tiff = pb.data(forType: .tiff),
            let attachment = AttachmentManager.intake(data: tiff, originalName: nil)
        {
            addAttachment(attachment)
            return true
        }
        if let png = pb.data(forType: .png),
            let attachment = AttachmentManager.intake(data: png, originalName: nil)
        {
            addAttachment(attachment)
            return true
        }

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images {
                if let attachment = AttachmentManager.intake(nsImage: image, originalName: nil) {
                    addAttachment(attachment)
                    return true
                }
            }
        }
        return false
    }
}
