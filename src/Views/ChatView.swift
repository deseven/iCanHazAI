// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var store: AppViewModel
    @State private var inputText: String = ""
    @State private var pendingImages: [PendingImageAttachment] = []
    @State private var isDropTargeted: Bool = false
    @State private var filePicker: Bool = false
    /// Natural content height of the editor, clamped to [1, 5] lines.
    @State private var editorHeight: CGFloat = ChatView.lineHeight
    @FocusState private var isInputFocused: Bool
    /// Monotonic counter bumped to force `updateNSView` to re-run and re-claim
    /// focus, even when `isInputFocused` is already `true` (e.g. switching chats).
    @State private var focusToken: Int = 0

    /// Height of a single text line (font + insets). Computed from the actual
    /// font metrics so it exactly matches the text view's natural one-line
    /// height — a hardcoded value would cause sub-pixel mismatches that leave
    /// a residual vertical scrollbar.
    static let lineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lm = NSLayoutManager()
        return lm.defaultLineHeight(for: font) + 8 // textContainerInset.height * 2
    }()
    /// Five-line cap. Beyond this the text view scrolls internally.
    static let maxHeight: CGFloat = lineHeight * 5

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderBar {
                store.chatInfoSidebarVisible.toggle()
            }

            Divider()

            ChatWebView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                if store.selectedChatSupportsImageInput {
                    Button(action: { filePicker = true }) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: ChatView.lineHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Attach images")
                    .disabled(store.isStreaming)
                    .padding(.leading, 2)
                    .padding(.top, 6)
                }

                VStack(spacing: 4) {
                    if !pendingImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(pendingImages) { img in
                                    ImageChip(
                                        name: img.originalName ?? "image",
                                        onRemove: { removeImage(img.id) }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }

                    ChatInputEditor(
                        text: $inputText,
                        isFocused: $isInputFocused,
                        focusToken: focusToken,
                        onReturn: { handleReturn() },
                        onImagePaste: handleClipboardPaste,
                        onHeightChange: { natural in
                            let clamped = min(max(natural, ChatView.lineHeight), ChatView.maxHeight)
                            if clamped != editorHeight { editorHeight = clamped }
                        }
                    )
                    .frame(height: editorHeight)
                }
                .padding(.vertical, 6)

                Button(action: handleSendOrStop) {
                    Image(systemName: store.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(sendDisabled ? Color.secondary : Color.accentColor)
                        .frame(width: 30, height: ChatView.lineHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(sendDisabled)
                .help(store.isStreaming ? "Stop" : "Send")
                .padding(.trailing, 4)
                .padding(.top, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isDropTargeted
                          ? Color.accentColor.opacity(0.07)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isDropTargeted
                            ? Color.accentColor.opacity(0.55)
                            : Color(nsColor: .separatorColor),
                        lineWidth: 1
                    )
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
        .onAppear {
            isInputFocused = true
            focusToken &+= 1
        }
        .onChange(of: store.selectedChatID) { _, _ in
            inputText = ""
            pendingImages = []
            editorHeight = ChatView.lineHeight
            isInputFocused = true
            focusToken &+= 1
        }
        .fileImporter(
            isPresented: $filePicker,
            allowedContentTypes: ImagePickerTypes.supported,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let img = ImageManager.intake(fileURL: url) {
                            pendingImages.append(img)
                        }
                    }
                }
            case .failure:
                break
            }
        }
        .sheet(item: Binding(
            get: { store.pendingEditMessageID.map { PendingID(id: $0) } },
            set: { if $0 == nil { store.pendingEditMessageID = nil } }
        )) { pending in
            if let item = store.selectedChatItem,
               let msg = item.chat.messages.first(where: { $0.id == pending.id }) {
                EditMessageSheet(
                    initialText: msg.content,
                    onCancel: { store.pendingEditMessageID = nil },
                    onConfirm: { newText in
                        store.editMessage(messageID: pending.id, to: newText)
                        store.pendingEditMessageID = nil
                    }
                )
            }
        }
        .sheet(item: Binding(
            get: { store.pendingDeleteMessageID.map { PendingID(id: $0) } },
            set: { if $0 == nil { store.pendingDeleteMessageID = nil } }
        )) { pending in
            ConfirmActionSheet(
                title: "Delete this message?",
                message: "This action cannot be undone.",
                confirmLabel: "Delete",
                onCancel: { store.pendingDeleteMessageID = nil },
                onConfirm: {
                    store.deleteMessage(messageID: pending.id)
                    store.pendingDeleteMessageID = nil
                }
            )
        }
    }

    /// Whether the send/stop button should be disabled.
    private var sendDisabled: Bool {
        if store.isStreaming { return false }
        if !store.selectedChatHasConnection { return true }
        if !pendingImages.isEmpty { return false }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return false }
        // Empty input is allowed when the last message is from the user —
        // pressing send triggers the assistant reply on that message.
        return !store.selectedChatLastMessageIsFromUser
    }

    /// A header bar that sits at the top of the chat content area (below the
    /// window titlebar). By living inside the content, it naturally shifts left
    /// when the inspector panel opens — unlike toolbar items which span the full
    /// titlebar width regardless of the inspector.
    private struct ChatHeaderBar: View {
        @EnvironmentObject var store: AppViewModel
        let onToggleInfo: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Picker("Connection", selection: Binding(
                    get: { store.selectedChatItem?.chat.connection ?? "" },
                    set: { store.setConnection($0) }
                )) {
                    Text("No connection").tag("")
                    ForEach(store.connections) { connection in
                        Text(connection.displayName).tag(connection.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)

                Picker("Role", selection: Binding(
                    get: { store.selectedChatItem?.chat.role ?? "" },
                    set: { store.setRole($0) }
                )) {
                    Text("No role").tag("")
                    ForEach(store.roles) { role in
                        HStack {
                            Text(role.name)
                            if role.isDefault {
                                Image(systemName: "checkmark.seal")
                            }
                        }
                        .tag(role.name)
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                if !store.mcps.isEmpty {
                    Menu {
                        Button("None") {
                            store.setActiveMCPs(nil)
                        }
                        Divider()
                        ForEach(store.mcps) { server in
                            let active = store.selectedChatItem?.chat.mcps?.contains(server.name) ?? false
                            Button {
                                var current = store.selectedChatItem?.chat.mcps ?? []
                                if active {
                                    current.removeAll { $0 == server.name }
                                } else {
                                    current.append(server.name)
                                }
                                store.setActiveMCPs(current.isEmpty ? nil : current)
                            } label: {
                                if active {
                                    Label(server.name, systemImage: "checkmark")
                                } else {
                                    Text(server.name)
                                }
                            }
                        }
                    } label: {
                        let count = store.selectedChatItem?.chat.mcps?.count ?? 0
                        Label("MCP: \(count)", systemImage: "wrench.and.screwdriver")
                            .labelStyle(.titleAndIcon)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Active MCP servers for this chat")
                }

                Spacer()

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
    }

    /// Routes the button press to either stop (while streaming) or send.
    private func handleSendOrStop() {
        if store.isStreaming {
            store.stopStreaming()
            return
        }
        send()
    }

    private func send() {
        guard store.selectedChatHasConnection else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard !store.isStreaming else { return }
        // Empty input with no images: if the last message is from the user,
        // trigger a regenerate of the assistant reply on that message.
        if text.isEmpty && images.isEmpty {
            guard store.selectedChatLastMessageIsFromUser else { return }
            store.retryLastMessage()
            return
        }
        inputText = ""
        pendingImages = []
        editorHeight = ChatView.lineHeight
        store.sendMessage(text, pendingImages: images)
    }

    // MARK: - Key handling

    /// Returns true if the Return key was handled (message sent), false to
    /// let the default newline insertion proceed.
    private func handleReturn() -> Bool {
        send()
        return true
    }

    // MARK: - Image attachment handling

    private func removeImage(_ id: UUID) {
        pendingImages.removeAll(where: { $0.id == id })
    }

    /// Checks the system pasteboard for image content and, if found, attaches
    /// it as a pending image. Returns true if an image was consumed (so the
    /// caller can swallow the paste event), false to let normal text paste
    /// proceed.
    private func handleClipboardPaste() -> Bool {
        guard store.selectedChatSupportsImageInput else { return false }
        let pb = NSPasteboard.general

        // 1. File URLs first (e.g. an image file copied in Finder). We prefer
        //    the actual file content over any TIFF/PNG representation on the
        //    pasteboard, because Finder also places the file's *icon* as TIFF
        //    data — reading that would attach the icon, not the real image.
        //    A copied screenshot carries no file URL, so it falls through to
        //    the direct-image-data path below.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            var added = false
            for url in urls {
                guard ImageProcessor.isSupportedFile(url) else { continue }
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url),
                   let img = ImageManager.intake(data: data, originalName: url.lastPathComponent) {
                    pendingImages.append(img)
                    added = true
                }
            }
            if added { return true }
        }

        if let tiff = pb.data(forType: .tiff),
           let img = ImageManager.intake(data: tiff, originalName: nil) {
            pendingImages.append(img)
            return true
        }
        if let png = pb.data(forType: .png),
           let img = ImageManager.intake(data: png, originalName: nil) {
            pendingImages.append(img)
            return true
        }

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images {
                if let img = ImageManager.intake(nsImage: image, originalName: nil) {
                    pendingImages.append(img)
                    return true
                }
            }
        }
        return false
    }

    /// Handles drag-and-dropped image files onto the input area.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard store.selectedChatSupportsImageInput else { return false }
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? URL else { return }
                DispatchQueue.main.async {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    guard ImageProcessor.isSupportedFile(url),
                          let data = try? Data(contentsOf: url),
                          let img = ImageManager.intake(data: data, originalName: url.lastPathComponent) else {
                        return
                    }
                    pendingImages.append(img)
                }
            }
            accepted = true
        }
        return accepted
    }
}

// MARK: - ChatInputEditor

/// The text editor for chat input, built on a custom `NSTextView` subclass
/// that intercepts `paste:` (both Cmd+V and right-click → Paste) to check
/// for image content before falling through to normal text pasting.
///
/// The view reports its natural content height via `onHeightChange` so SwiftUI
/// can grow the container from one line up to a five-line cap, after which the
/// text view itself scrolls internally.
private struct ChatInputEditor: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    /// Incremented to force `updateNSView` to re-run (and re-claim focus).
    var focusToken: Int
    let onReturn: () -> Bool
    let onImagePaste: () -> Bool
    let onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ChatInputTextView()
        tv.delegate = context.coordinator
        tv.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.imagePasteHandler = { onImagePaste() }
        tv.returnHandler = onReturn
        tv.contentHeightChanged = onHeightChange
        tv.string = text

        if let tc = tv.textContainer {
            tc.widthTracksTextView = false
            tc.heightTracksTextView = false
            tc.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView = FlippedClipView()
        scrollView.documentView = tv
        tv.autoresizingMask = [.width]
        tv.frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: ChatView.lineHeight)
        DispatchQueue.main.async { tv.reportContentHeight() }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? ChatInputTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.reportContentHeight()
        }
        if isFocused.wrappedValue, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputEditor
        init(parent: ChatInputEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? ChatInputTextView else { return }
            parent.text = tv.string
            tv.reportContentHeight()
        }
    }
}

// MARK: - FlippedClipView

/// A clip view with a flipped coordinate system so the text view stays pinned
/// to the top of the scroll view and new lines push downward.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - ChatInputTextView

/// A custom `NSTextView` that:
/// - Intercepts paste to detect images before plain-text paste.
/// - Intercepts Return (without Shift) to trigger send.
/// - Reports its natural text layout height via `contentHeightChanged`.
private final class ChatInputTextView: NSTextView {
    var imagePasteHandler: (() -> Bool)?
    var returnHandler: (() -> Bool)?
    /// Called whenever the text layout height changes (after layout is complete).
    var contentHeightChanged: ((CGFloat) -> Void)?

    // MARK: Height reporting

    /// Asks the layout manager for the used rect, adds insets, and fires the
    /// callback. Safe to call from the main thread after any text change.
    /// Also resizes the text view's own frame to match its content height so
    /// the enclosing scroll view can clip and scroll it.
    func reportContentHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        tc.size = NSSize(width: bounds.width - textContainerInset.width * 2,
                         height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        // Add top + bottom insets. Round up to the nearest pixel to avoid
        // sub-pixel mismatches that leave a residual scrollbar sliver when
        // the content collapses back to one line.
        let total = (used.height + textContainerInset.height * 2).rounded(.up)
        // Grow the text view's frame to fit its content so the scroll view
        // can scroll within the SwiftUI-capped outer height.
        var f = frame
        if f.height != total {
            f.size.height = total
            frame = f
        }
        if let clip = enclosingScrollView?.contentView as? FlippedClipView {
            let visible = clip.bounds.height
            if total <= visible {
                clip.bounds.origin = .zero
            }
        }
        contentHeightChanged?(total)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportContentHeight()
    }

    // MARK: Paste / key overrides

    override func paste(_ sender: Any?) {
        if imagePasteHandler?() == true { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            if let handler = returnHandler, handler() { return }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept Cmd+V here because the standard NSTextView key equivalent
        // handling skips `paste:` when the pasteboard has no text content
        // (e.g. a copied screenshot that only has image data). We check for
        // images first; if found, consume. Otherwise let super handle the
        // normal text paste.
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 9 {
            if imagePasteHandler?() == true {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - ImageChip

/// A compact chip showing an attached image's filename with a remove button.
private struct ImageChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.caption2)
            Text(name)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Remove image")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

// MARK: - Helpers

/// Uniform type identifiers accepted by the image file picker.
enum ImagePickerTypes {
    static var supported: [UTType] {
        var types: [UTType] = []
        for uti in ImageProcessor.supportedTypeIdentifiers {
            if let t = UTType(uti) {
                types.append(t)
            }
        }
        if types.isEmpty {
            types = [.image]
        }
        return types
    }
}

/// A wrapper that makes a `UUID` `Identifiable` so it can drive `.sheet(item:)`.
private struct PendingID: Identifiable {
    let id: UUID
}
