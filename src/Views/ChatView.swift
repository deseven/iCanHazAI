// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import Textual

struct ChatView: View {
    @EnvironmentObject var store: AppViewModel
    @State private var inputText: String = ""
    @State private var isAtBottom = true

    /// Sentinel id placed at the very bottom of the content; scrolling to it with
    /// `.bottom` lands flush against the end, with no leftover padding gap.
    private let bottomID = "chat-bottom"

    /// Grace interval (in points). If the user is within this distance of the bottom
    /// we still consider them "at the bottom" and keep auto-scrolling.
    private let bottomGrace: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    // Outer VStack places the sentinel after the padded content so
                    // nothing (not even padding) sits below it — scrolling to it lands
                    // flush at 100% of the bottom.
                    VStack(spacing: 0) {
                        // A regular (non-lazy) VStack keeps layout stable and avoids the
                        // measurement jumps that LazyVStack produces while streaming.
                        VStack(alignment: .leading, spacing: 16) {
                            if let item = store.selectedChatItem {
                                ForEach(item.chat.messages) { message in
                                    MessageView(message: message)
                                        .id(message.id)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Bottom sentinel: scrolling here lands flush at the very end.
                        Color.clear
                            .frame(height: 0)
                            .id(bottomID)
                    }
                }
                // Track whether the user is currently at the bottom of the scroll view.
                .onScrollGeometryChange(for: Bool.self) { geo in
                    // Consider "at bottom" when within the grace interval of the end.
                    let maxOffset = geo.contentSize.height - geo.visibleRect.height
                    return maxOffset - geo.contentOffset.y <= bottomGrace
                } action: { _, atBottom in
                    isAtBottom = atBottom
                }
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: store.selectedChatItem?.id) { _, _ in
                    isAtBottom = true
                    scrollToBottom(proxy)
                }
                .onChange(of: store.selectedChatItem?.chat.messages.last?.content) { _, _ in
                    if isAtBottom { scrollToBottom(proxy) }
                }
                .onChange(of: store.selectedChatItem?.chat.messages.last?.thinking) { _, _ in
                    if isAtBottom { scrollToBottom(proxy) }
                }
                .onChange(of: store.selectedChatItem?.chat.messages.last?.error) { _, _ in
                    if isAtBottom { scrollToBottom(proxy) }
                }
                .onChange(of: store.selectedChatItem?.chat.messages.count) { _, _ in
                    // A message-count change only happens on a user-initiated send, so
                    // always follow it to the bottom (independent of isAtBottom, which
                    // may transiently be false right after the content grows).
                    isAtBottom = true
                    scrollToBottom(proxy)
                }
            }

            Divider()

            // Input
            HStack(spacing: 8) {
                TextEditor(text: $inputText)
                    .font(.body)
                    .frame(minHeight: 36, maxHeight: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            // Let the default newline happen
                            return .ignored
                        }
                        send()
                        return .handled
                    }

                Button(action: handleSendOrStop) {
                    Image(systemName: store.isStreaming ? "stop.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(sendDisabled)
                .help(store.isStreaming ? "Stop" : "Send")
            }
            .padding(12)
        }
    }

    /// Scrolls to the bottom sentinel, anchoring it flush at the very bottom.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomID, anchor: .bottom)
    }

    /// Whether the send/stop button should be disabled.
    private var sendDisabled: Bool {
        if store.isStreaming { return false }
        // Disallow sending when there's no usable connection selected.
        if !store.selectedChatHasConnection { return true }
        return inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        guard !text.isEmpty, !store.isStreaming else { return }
        inputText = ""
        // Sending a new message implies we want to follow the new response.
        isAtBottom = true
        store.sendMessage(text)
    }
}
