// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AppKit

/// Owns the borderless floating window that shows the loader during app
/// startup. Created and presented synchronously from `AppDelegate` right after
/// the main config is read, so the loader appears instantly while the engine
/// loads connections / prompts / roles / MCPs. Fades out (0.3s) one second
/// after everything settles, via the `LoaderController.visibilityHandler` hook.
/// The main window is already visible underneath (it opens normally at
/// launch); the loader panel floats above it at `.statusBar` level and simply
/// fades away once loading completes.
///
/// Only acts during `.startup` mode; usage-mode loader activity is shown as an
/// overlay on the main window instead (see `LoaderOverlay`).
@MainActor
final class LoaderWindowController {
    static let shared = LoaderWindowController()

    // Created lazily in `present()`, after the loader has been seeded with
    // real content. Building the panel/hosting view eagerly in `init()` — while
    // `LoaderController.shared.sections` is still empty — let the hosting view's
    // first layout pass happen against an empty card, sizing/positioning the
    // panel incorrectly before it ever had real content to measure. The window
    // would then briefly flash at that wrong spot before a corrective re-center
    // kicked in. Building it only once real sections exist (like the working
    // standalone test script does) avoids that entirely.
    private var panel: NSPanel?
    private var hosting: NSHostingView<LoaderStartView>?

    private init() {
        debugLog("Loader", "init")
        LoaderController.shared.visibilityHandler = { [weak self] visible in
            self?.handleVisibility(visible)
        }
    }

    /// Seeds the loader from the on-disk environment, then creates and presents
    /// the window in one shot: build the panel, size it to the now-populated
    /// content, center it on screen, and order it front — mirroring
    /// `loader-window-test.swift`. Because the sections are seeded first, the
    /// hosting view's very first layout pass already reflects the real content,
    /// so there's no wrong-sized/mispositioned frame to flash before centering.
    func present() {
        debugLog("Loader", "present — seeding")
        LoaderController.shared.beginStartup()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.title = "iCanHazAI starting up…"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // statusBar (not floating) so the loader stays above the main window
        // while it loads; floating was getting covered.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system window shadow follows the window's rectangular bounds,
        // which would draw a straight-edged halo around the rounded card. The
        // card renders its own rounded drop shadow instead (with room provided
        // by `LoaderStartView`'s padding).
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: LoaderStartView())
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting

        let fit = hosting.fittingSize
        debugLog("Loader", "present — fittingSize=\(fit.width)x\(fit.height)")
        if fit.width > 1, fit.height > 1, fit.width < 2000, fit.height < 2000 {
            panel.setContentSize(fit)
        }
        panel.center()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        debugLog("Loader", "present — frame=\(panel.frame), isVisible=\(panel.isVisible), level=\(panel.level.rawValue)")
    }

    private func handleVisibility(_ visible: Bool) {
        guard let panel else { return }
        debugLog("Loader", "handleVisibility — visible=\(visible), panelVisible=\(panel.isVisible), mode=\(LoaderController.shared.mode)")
        if !visible && panel.isVisible {
            fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        debugLog("Loader", "fadeOut")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }
}
