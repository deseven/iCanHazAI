// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import Textual

struct ChatView: View {
    @EnvironmentObject var store: AppViewModel
    @State private var inputText: String = ""
    @State private var isAtBottom = true
    /// Master switch: true means we should keep scrolling to the bottom as new
    /// content arrives. Only cleared by a genuine user scroll-up gesture (scroll
    /// phase = interacting AND geometry says not at bottom). Restored any time
    /// the view reaches the bottom — whether by the user scrolling back down or
    /// by a programmatic scroll.
    @State private var autoscrollEnabled = true
    /// True while the user's finger/trackpad is actively driving the scroll.
    /// Used to distinguish user gestures from programmatic scroll animations.
    @State private var userIsScrolling = false
    /// Bumped before chatInfoSidebarVisible changes so the scroll fires with
    /// the pre-toggle value of autoscrollEnabled (before geometry changes flip it).
    @State private var scrollRequest: UUID?

    /// Sentinel id placed at the very bottom of the content; scrolling to it with
    /// `.bottom` lands flush against the end, with no leftover padding gap.
    private let bottomID = "chat-bottom"

    /// Grace interval (in points). If the user is within this distance of the bottom
    /// we still consider them "at the bottom" and keep auto-scrolling.
    private let bottomGrace: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            // Custom header bar with pickers — lives inside ChatView so it
            // naturally shrinks when the inspector panel is open.
            ChatHeaderBar {
                // Capture autoscrollEnabled before the sidebar toggle causes a
                // geometry change that may flip it to false.
                if autoscrollEnabled { scrollRequest = UUID() }
                store.chatInfoSidebarVisible.toggle()
            }

            Divider()

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
                // Track genuine user-initiated scrolling so we can tell it apart
                // from programmatic animations triggered by `scrollTo`.
                // The moment a real touch/drag begins we disable autoscroll
                // immediately so the very next content onChange doesn't fight the
                // user's gesture. It is re-enabled when the view reaches the bottom.
                .onScrollPhaseChange { _, newPhase in
                    let interacting = newPhase == .interacting
                    userIsScrolling = interacting
                    if interacting {
                        autoscrollEnabled = false
                    }
                }
                // Geometry change: re-enable autoscroll once the view reaches
                // the bottom (whether the user scrolled back or we programmatically
                // scrolled there). Content-height jumps that push us slightly off
                // the bottom while the user isn't scrolling are ignored.
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let maxOffset = max(0, geo.contentSize.height - geo.visibleRect.height)
                    return maxOffset - geo.contentOffset.y <= bottomGrace
                } action: { _, atBottom in
                    isAtBottom = atBottom
                    store.selectedChatAtBottom = atBottom
                    if atBottom {
                        // Reached the bottom — re-engage autoscroll regardless of
                        // how we got here.
                        autoscrollEnabled = true
                    }
                    // Disabling autoscroll is handled exclusively in
                    // onScrollPhaseChange (on .interacting) to avoid races with
                    // content-driven geometry updates.
                }
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: store.selectedChatItem?.id) { _, _ in
                    autoscrollEnabled = true
                    isAtBottom = true
                    store.selectedChatAtBottom = true
                    scrollToBottom(proxy)
                }
                .onChange(of: store.selectedChatItem?.chat.messages.last?.content) { _, _ in
                    if autoscrollEnabled && !userIsScrolling { scrollToBottom(proxy) }
                }
                .onChange(of: store.selectedChatItem?.chat.messages.last?.thinking) { _, _ in
                    if autoscrollEnabled && !userIsScrolling { scrollToBottom(proxy) }
                }
                .onChange(of: store.selectedChatItem?.chat.messages.last?.error) { _, _ in
                    if autoscrollEnabled && !userIsScrolling { scrollToBottom(proxy) }
                }
                .onChange(of: store.selectedChatItem?.chat.messages.count) { _, _ in
                    // A message-count change only happens on a user-initiated send, so
                    // always follow it to the bottom.
                    autoscrollEnabled = true
                    isAtBottom = true
                    store.selectedChatAtBottom = true
                    scrollToBottom(proxy)
                }
                // When the left sidebar opens/closes the available width animates;
                // re-anchor to the bottom once the animation settles.
                .onGeometryChange(for: CGFloat.self) { geo in
                    geo.size.width
                } action: { _, _ in
                    if autoscrollEnabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            scrollToBottom(proxy)
                        }
                    }
                }
                // scrollRequest is set in the info-button action *before* the
                // sidebar toggle, so autoscrollEnabled is captured at pre-layout time.
                .onChange(of: scrollRequest) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollToBottom(proxy)
                    }
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
        guard !text.isEmpty, !store.isStreaming else { return }
        inputText = ""
        // Sending a new message implies we want to follow the new response.
        isAtBottom = true
        store.sendMessage(text)
    }
}
