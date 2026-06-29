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
    /// Actual editor height, clamped between one line and five lines.
    @State private var editorHeight: CGFloat = ChatView.editorMinHeight
    @FocusState private var isInputFocused: Bool
    /// Holds a weak reference to the live input text view so we can request
    /// focus on it directly from SwiftUI (the @FocusState doesn't re-trigger
    /// updateNSView when the value is already true, e.g. switching chats).
    @StateObject private var focusController = InputFocusController()

    /// Single-line height: font (~13 pt) + top/bottom insets (4 pt each) + a tiny buffer.
    static let editorMinHeight: CGFloat = 22
    /// Five-line cap. Beyond this the text view scrolls internally.
    static let editorMaxHeight: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            // Custom header bar with pickers — lives inside ChatView so it
            // naturally shrinks when the inspector panel is open.
            ChatHeaderBar {
                store.chatInfoSidebarVisible.toggle()
            }

            Divider()

            // Chat content: rendered by the persistent web view.
            ChatWebView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Input container — rounded bordered box that grows up to 5 lines.
            VStack(spacing: 0) {

                // Pending image chips (filenames with remove buttons).
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
                        .padding(.horizontal, 10)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                }

                // Text editor — height tracks content, capped at 5 lines.
                ChatInputEditor(
                    text: $inputText,
                    isFocused: $isInputFocused,
                    focusController: focusController,
                    onReturn: { handleReturn() },
                    onImagePaste: handleClipboardPaste,
                    onHeightChange: { natural in
                        let clamped = min(max(natural, ChatView.editorMinHeight), ChatView.editorMaxHeight)
                        if clamped != editorHeight { editorHeight = clamped }
                    }
                )
                .frame(height: editorHeight)
                // Small horizontal padding so text doesn't press the border.
                .padding(.horizontal, 2)
                .padding(.top, pendingImages.isEmpty ? 6 : 2)

                // Bottom toolbar: attach on the left, send on the right.
                HStack(spacing: 0) {
                    if store.selectedChatSupportsImageInput {
                        Button(action: { filePicker = true }) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Attach images")
                        .disabled(store.isStreaming)
                        .padding(.leading, 2)
                    }

                    Spacer()

                    Button(action: handleSendOrStop) {
                        Image(systemName: store.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(sendDisabled ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .disabled(sendDisabled)
                    .help(store.isStreaming ? "Stop" : "Send")
                    .padding(.trailing, 4)
                }
                .frame(height: 36)
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
            // Drag-and-drop images onto the input area.
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
        .onAppear {
            isInputFocused = true
            // Focus after the view is on screen; the text view may not have
            // been attached to a window during the first updateNSView pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusController.focus() }
        }
        .onChange(of: store.selectedChatID) { _, _ in
            inputText = ""
            pendingImages = []
            editorHeight = ChatView.editorMinHeight
            isInputFocused = true
            // The @FocusState is already true, so updateNSView won't re-run
            // for focus. Request focus directly on the text view instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusController.focus() }
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
        // Edit sheet — driven by the web view bridge setting
        // `pendingEditMessageID`.
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
        // Delete confirmation — driven by the web view bridge setting
        // `pendingDeleteMessageID`.
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
        // Disallow sending when there's no usable connection selected.
        if !store.selectedChatHasConnection { return true }
        // Allow sending image-only messages (no text) when images are attached.
        if !pendingImages.isEmpty { return false }
        return inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // Disallow sending when no connection is selected instead of silently dropping.
        guard store.selectedChatHasConnection else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        // Allow image-only messages (no text) when images are attached.
        guard (!text.isEmpty || !images.isEmpty), !store.isStreaming else { return }
        inputText = ""
        pendingImages = []
        editorHeight = ChatView.editorMinHeight
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
        guard store.selectedChatSupportsImageInput else {
            print("[ichai] paste: selected chat does not support image input")
            return false
        }
        let pb = NSPasteboard.general
        print("[ichai] paste: types=\(pb.types?.map { $0.rawValue } ?? [])")

        // 1. File URLs first (e.g. an image file copied in Finder). We prefer
        //    the actual file content over any TIFF/PNG representation on the
        //    pasteboard, because Finder also places the file's *icon* as TIFF
        //    data — reading that would attach the icon, not the real image.
        //    A copied screenshot carries no file URL, so it falls through to
        //    the direct-image-data path below.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            print("[ichai] paste: found \(urls.count) file URL(s)")
            var added = false
            for url in urls {
                let supported = ImageProcessor.isSupportedFile(url)
                print("[ichai] paste url: \(url.lastPathComponent) supported=\(supported)")
                if supported {
                    let didStart = url.startAccessingSecurityScopedResource()
                    if let data = try? Data(contentsOf: url),
                       let img = ImageManager.intake(data: data, originalName: url.lastPathComponent) {
                        pendingImages.append(img)
                        added = true
                        print("[ichai] paste: attached from file URL (\(data.count) bytes)")
                    } else {
                        print("[ichai] paste: failed to read/process file URL")
                    }
                    if didStart { url.stopAccessingSecurityScopedResource() }
                }
            }
            if added { return true }
        }

        // 2. Direct image data (e.g. screenshot copy, image copied from a
        //    browser). These pasteboards carry no file URL.
        if let tiff = pb.data(forType: .tiff) {
            print("[ichai] paste: tiff data \(tiff.count) bytes")
            if let img = ImageManager.intake(data: tiff, originalName: nil) {
                pendingImages.append(img)
                return true
            }
        }
        if let png = pb.data(forType: .png) {
            print("[ichai] paste: png data \(png.count) bytes")
            if let img = ImageManager.intake(data: png, originalName: nil) {
                pendingImages.append(img)
                return true
            }
        }

        // 3. NSImage objects (e.g. a photo copied from Photos.app) that don't
        //    expose TIFF/PNG data types directly. This is the only way to
        //    reach image content on some pasteboards.
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            print("[ichai] paste: found \(images.count) NSImage object(s)")
            for image in images {
                if let img = ImageManager.intake(nsImage: image, originalName: nil) {
                    pendingImages.append(img)
                    return true
                }
            }
        }

        print("[ichai] paste: no image content found")
        return false
    }

    /// Handles drag-and-dropped image files onto the input area.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard store.selectedChatSupportsImageInput else { return false }
        print("[ichai] drop: \(providers.count) providers")
        var accepted = false
        for provider in providers {
            let conforms = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            print("[ichai] drop provider: fileURL=\(conforms) registered=\(provider.registeredTypeIdentifiers)")
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            // Use loadObject(forClass:) which is more reliable than loadItem
            // for file URLs from Finder drags.
            provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error {
                    print("[ichai] drop load error: \(error)")
                    return
                }
                guard let url = object as? URL else {
                    print("[ichai] drop: object is not a URL")
                    return
                }
                print("[ichai] drop URL: \(url)")
                DispatchQueue.main.async {
                    let didStart = url.startAccessingSecurityScopedResource()
                    if ImageProcessor.isSupportedFile(url) {
                        if let data = try? Data(contentsOf: url),
                           let img = ImageManager.intake(data: data, originalName: url.lastPathComponent) {
                            pendingImages.append(img)
                            print("[ichai] drop: attached \(url.lastPathComponent)")
                        } else {
                            print("[ichai] drop: failed to read/process \(url.lastPathComponent)")
                        }
                    } else {
                        print("[ichai] drop: not a supported image file")
                    }
                    if didStart { url.stopAccessingSecurityScopedResource() }
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
// MARK: - InputFocusController

/// Holds a weak reference to the live input text view so the SwiftUI layer
/// can request focus on it directly. This is needed because `@FocusState`
/// doesn't re-trigger `updateNSView` when the value is already `true`
/// (e.g. switching chats while the input is already focused).
final class InputFocusController: ObservableObject {
    /// Weak reference to the live input text view (typed as NSTextView to
    /// avoid visibility issues with the private ChatInputTextView subclass).
    weak var textView: NSTextView?

    /// Requests first-responder status on the text view. Safe to call
    /// repeatedly; no-ops if the view isn't in a window yet.
    @MainActor func focus() {
        guard let tv = textView, let window = tv.window else {
            print("[ichai] focus: no text view or window")
            return
        }
        if window.firstResponder === tv {
            print("[ichai] focus: already first responder")
            return
        }
        let ok = window.makeFirstResponder(tv)
        print("[ichai] focus: makeFirstResponder -> \(ok) (firstResponder now \(window.firstResponder as Any))")
    }
}

// MARK: - ChatInputEditor

private struct ChatInputEditor: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var focusController: InputFocusController
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
        // Insets: a bit of horizontal breathing room, minimal vertical.
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.imagePasteHandler = { onImagePaste() }
        tv.returnHandler = onReturn
        tv.contentHeightChanged = onHeightChange
        // Apply initial text.
        tv.string = text

        // Configure the text container so the text view tracks the scroll
        // view's width and lays out properly inside it.
        if let tc = tv.textContainer {
            tc.widthTracksTextView = false
            tc.heightTracksTextView = false
            tc.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        // Wrap the text view in a scroll view so that once the content
        // exceeds the (SwiftUI-capped) frame height, the text scrolls
        // internally instead of overflowing the component borders.
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView = FlippedClipView()
        scrollView.documentView = tv
        // Make the text view fill the scroll view's width and grow vertically
        // with its content. autoresizingMask keeps the width in sync as the
        // scroll view is resized by SwiftUI.
        tv.autoresizingMask = [.width]
        // Give it a non-zero initial height so it can receive focus/clicks;
        // reportContentHeight() will correct it to the content height.
        tv.frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: 22)
        // Trigger an initial layout + height report now that the text view is
        // wired into the scroll view.
        DispatchQueue.main.async { tv.reportContentHeight() }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? ChatInputTextView else { return }
        // Register the text view with the focus controller so ChatView can
        // request focus on it directly (bypassing @FocusState).
        focusController.textView = tv
        // Sync external text changes (e.g. cleared after send).
        if tv.string != text {
            tv.string = text
            // Force a height report so SwiftUI can collapse the editor after send.
            tv.reportContentHeight()
        }
        // Sync focus state.
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
        // Keep the container width in sync with the (possibly resized) frame
        // so wrapping matches the visible width.
        tc.size = NSSize(width: bounds.width - textContainerInset.width * 2,
                         height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        // Add top + bottom insets.
        let total = used.height + textContainerInset.height * 2
        // Grow the text view's frame to fit its content so the scroll view
        // can scroll within the SwiftUI-capped outer height.
        var f = frame
        if f.height != total {
            f.size.height = total
            frame = f
        }
        contentHeightChanged?(total)
    }

    // Keep the text container width in sync when the scroll view is resized.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportContentHeight()
    }

    // MARK: Paste / key overrides

    override func paste(_ sender: Any?) {
        print("[ichai] paste: action called")
        // Check the pasteboard for image content first. If an image is found
        // and consumed, don't fall through to text pasting.
        if imagePasteHandler?() == true { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Intercept Return (without Shift) for send.
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
            print("[ichai] performKeyEquivalent: Cmd+V detected (keyCode=9)")
            if imagePasteHandler?() == true {
                print("[ichai] performKeyEquivalent: image consumed")
                return true
            }
            print("[ichai] performKeyEquivalent: no image, falling through")
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
        // Map our supported UTI strings to UTType values, falling back to
        // generic image types if a specific one isn't available.
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
