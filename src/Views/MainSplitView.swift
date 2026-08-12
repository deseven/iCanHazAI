// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Width constraints for the main window's sidebars (points). Nonisolated so
/// the split view delegate (AppKit callbacks) can read them without hopping
/// to the main actor.
enum SidebarSizing {
    static let chatListRange: ClosedRange<CGFloat> = 200...400
    static let chatInfoRange: ClosedRange<CGFloat> = 220...480
    static let defaultChatListWidth: CGFloat = 240
    static let defaultChatInfoWidth: CGFloat = 260
}

/// Pure width distribution for the three-pane split. Window resizes may
/// proportionally scale the sidebars, but every layout pass clamps them to
/// their supported ranges and assigns whatever remains to the detail pane.
enum MainSplitLayout {
    static func paneWidths(totalWidth: CGFloat, dividerThickness: CGFloat, listWidth: CGFloat, infoWidth: CGFloat?) -> (
        list: CGFloat, detail: CGFloat, info: CGFloat?
    ) {
        let list = min(max(listWidth, SidebarSizing.chatListRange.lowerBound), SidebarSizing.chatListRange.upperBound)
        let info = infoWidth.map {
            min(max($0, SidebarSizing.chatInfoRange.lowerBound), SidebarSizing.chatInfoRange.upperBound)
        }
        let infoReserve = info.map { $0 + dividerThickness } ?? 0
        let detail = max(totalWidth - list - dividerThickness - infoReserve, 0)
        return (list, detail, info)
    }
}

/// The three-pane window layout (chat list | chat | chat info) backed by a
/// real `NSSplitView` hosting the SwiftUI panes.
///
/// Why AppKit: a pure-SwiftUI divider drag re-rendered the whole window
/// (webview included) on every mouse-moved — visible jitter — and overlay
/// hit areas don't extend past a view's bounds, leaving a ~1pt grab zone.
/// `NSSplitView` does hit-testing, cursor changes, and live dragging itself,
/// exactly like the `NavigationSplitView` it replaces, but the delegate
/// clamps both sidebar widths to their ranges so no pane can ever collapse
/// (no toggle button, no ⌃⌘S, no drag-to-zero). Widths are persisted
/// (debounced) via [`AppViewModel.saveSidebarState()`](src/App/AppViewModel.swift)
/// once a drag settles.
struct MainSplitView: NSViewRepresentable {
    @EnvironmentObject var store: AppViewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = RoomySplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.splitView = split
        coordinator.listHost = NSHostingController(rootView: AnyView(ChatSidebar().environmentObject(store)))
        coordinator.detailHost = NSHostingController(rootView: AnyView(ChatDetailPane().environmentObject(store)))
        coordinator.infoHost = NSHostingController(rootView: AnyView(ChatInfoSidebar().environmentObject(store)))

        split.addArrangedSubview(coordinator.listHost!.view)
        split.addArrangedSubview(coordinator.detailHost!.view)
        // The detail keeps the default (lowest) holding priority so it
        // absorbs window resizes; the sidebars sit just above it.
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        // The split view lays out exactly from these widths on its first
        // real sizing pass (see RoomySplitView.resizeSubviews).
        split.initialWidths = {
            MainActor.assumeIsolated {
                (
                    list: store.chatListSidebarWidth,
                    info: store.chatInfoSidebarVisible && store.selectedChatItem != nil
                        ? store.chatInfoSidebarWidth : nil
                )
            }
        }

        coordinator.syncInfoPane(visible: store.chatInfoSidebarVisible && store.selectedChatItem != nil, store: store)
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.syncInfoPane(
            visible: store.chatInfoSidebarVisible && store.selectedChatItem != nil, store: store)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var splitView: NSSplitView?
        var listHost: NSHostingController<AnyView>?
        var detailHost: NSHostingController<AnyView>?
        var infoHost: NSHostingController<AnyView>?
        /// Last state pushed by `syncInfoPane`, so `updateNSView` stays cheap.
        private var infoVisible = false
        private var saveTask: Task<Void, Never>?

        // MARK: Info pane show/hide

        @MainActor
        func syncInfoPane(visible: Bool, store: AppViewModel) {
            guard visible != infoVisible, let splitView, let infoHost else { return }
            infoVisible = visible
            if visible {
                splitView.addArrangedSubview(infoHost.view)
                splitView.setHoldingPriority(.init(260), forSubviewAt: splitView.arrangedSubviews.count - 1)
                // Restore the stored width once the pane is laid out. When
                // the window is still on its first layout the split view's
                // own restore hook covers this instead.
                Task { @MainActor [weak self, weak splitView] in
                    guard let self, let splitView, splitView.bounds.width > 0,
                        splitView.arrangedSubviews.count > 2
                    else { return }
                    self.setInfoWidth(store.chatInfoSidebarWidth, in: splitView)
                }
            } else {
                infoHost.view.removeFromSuperview()
            }
        }

        // MARK: Stored widths

        @MainActor
        private func setInfoWidth(_ width: CGFloat, in splitView: NSSplitView) {
            splitView.setPosition(splitView.bounds.width - width, ofDividerAt: 1)
        }

        // MARK: Width persistence

        /// Called continuously during a drag; the actual write is debounced
        /// to 400 ms after the user stops moving the divider.
        func splitViewDidResizeSubviews(_ notification: Notification) {
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, let splitView else { return }
                self.persistWidths(from: splitView)
            }
        }

        @MainActor
        private func persistWidths(from splitView: NSSplitView) {
            guard let store = AppViewModel.shared else { return }
            let panes = splitView.arrangedSubviews
            guard panes.count >= 2 else { return }
            var changed = false
            let listWidth = panes[0].frame.width.rounded()
            if SidebarSizing.chatListRange.contains(listWidth), abs(listWidth - store.chatListSidebarWidth) > 0.5 {
                store.chatListSidebarWidth = listWidth
                changed = true
            }
            if infoVisible, panes.count > 2 {
                let infoWidth = panes[2].frame.width.rounded()
                if SidebarSizing.chatInfoRange.contains(infoWidth), abs(infoWidth - store.chatInfoSidebarWidth) > 0.5 {
                    store.chatInfoSidebarWidth = infoWidth
                    changed = true
                }
            }
            // Skip the config write when nothing moved (e.g. window resizes
            // fire the same notification without touching sidebar widths).
            if changed { store.saveSidebarState() }
        }

        // MARK: NSSplitViewDelegate

        /// No pane may collapse — this also disables double-click-to-collapse
        /// on the dividers.
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

        /// Clamps divider positions so both sidebars stay within their width
        /// ranges regardless of how the user drags.
        func splitView(
            _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            if dividerIndex == 0 {
                return min(
                    max(proposedPosition, SidebarSizing.chatListRange.lowerBound),
                    SidebarSizing.chatListRange.upperBound)
            }
            let minPos = splitView.bounds.width - SidebarSizing.chatInfoRange.upperBound
            let maxPos = splitView.bounds.width - SidebarSizing.chatInfoRange.lowerBound
            return min(max(proposedPosition, minPos), maxPos)
        }
    }
}

/// Hairline dividers. The first real sizing pass is laid out manually from
/// the stored widths (`initialWidths`): NSSplitView's default initial layout
/// sizes panes from their content's fitting sizes (long chat titles, tool
/// chips), which left the sidebars at arbitrary out-of-range widths, and any
/// earlier restore attempt raced the zero-frame pre-display layout.
private final class RoomySplitView: NSSplitView {
    override var dividerThickness: CGFloat { 2 }
    override var dividerColor: NSColor { .separatorColor }

    /// Exact sidebar widths for the first layout; `info` is nil when the
    /// chat info pane starts hidden.
    var initialWidths: (() -> (list: CGFloat, info: CGFloat?))?
    private var didApplyInitialLayout = false

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let panes = arrangedSubviews
        guard bounds.width > 1, panes.count >= 2 else {
            super.resizeSubviews(withOldSize: oldSize)
            return
        }

        // Scale the sidebars with the window, then clamp the result. Calling
        // super lets NSSplitView do the scaling without the clamp, which is
        // what pushed sidebars outside their ranges during live resizes.
        let scale = oldSize.width > 1 ? bounds.width / oldSize.width : 1
        var listWidth = panes[0].frame.width * scale
        var infoWidth: CGFloat? = panes.count > 2 ? panes[2].frame.width * scale : nil
        if !didApplyInitialLayout {
            if let widths = initialWidths?() {
                listWidth = widths.list
                infoWidth = panes.count > 2 ? widths.info : nil
            }
            didApplyInitialLayout = true
        }
        layoutPanes(
            MainSplitLayout.paneWidths(
                totalWidth: bounds.width,
                dividerThickness: dividerThickness,
                listWidth: listWidth,
                infoWidth: infoWidth
            ))
    }

    private func layoutPanes(_ widths: (list: CGFloat, detail: CGFloat, info: CGFloat?)) {
        let panes = arrangedSubviews
        let height = bounds.height
        panes[0].frame = NSRect(x: 0, y: 0, width: widths.list, height: height)
        let detailX = widths.list + dividerThickness
        panes[1].frame = NSRect(x: detailX, y: 0, width: widths.detail, height: height)
        if let info = widths.info, panes.count > 2 {
            panes[2].frame = NSRect(x: bounds.width - info, y: 0, width: info, height: height)
        }
    }
}

/// The center pane: the current chat, or a placeholder when none is selected.
private struct ChatDetailPane: View {
    @EnvironmentObject var store: AppViewModel

    var body: some View {
        Group {
            if store.selectedChatItem != nil {
                ChatView()
            } else {
                VStack {
                    Spacer()
                    Text("No chat selected")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
