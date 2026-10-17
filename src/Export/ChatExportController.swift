// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The "Exporting…" sheet: a spinner and a label, no controls.
@MainActor
private final class ExportProgressSheet {
    private let panel: NSPanel
    private weak var parent: NSWindow?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered,
            defer: false)
        panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Exporting…")
        label.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
    }

    func present(on window: NSWindow) {
        parent = window
        window.beginSheet(panel)
    }

    func dismiss() {
        guard let parent else { return }
        parent.endSheet(panel)
        panel.orderOut(nil)
        self.parent = nil
    }
}

/// Runs the three Chat-menu exports: HTML and PDF ask for a file first, Print
/// renders the same PDF to a temporary file and hands it to the system print panel.
@MainActor
final class ChatExportController {
    static let shared = ChatExportController()

    enum Kind {
        case html, pdf, print
    }

    private init() {}

    func start(_ kind: Kind) {
        guard let store = AppViewModel.shared, store.canExportCurrentChat,
            let item = store.selectedChatItem, let chat = item.chat,
            let window = MainWindowController.shared.mainWindow
        else {
            NSSound.beep()
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }

        let title = item.displayTitle
        let snapshotInput = (
            chat: chat, title: title, role: item.effectiveRoleName,
            directory: EnvironmentManager.shared.attachmentsDirectoryURL(for: item.filename),
            accent: RoleAccent.cssLightDark(for: store.selectedRole?.config.accent)
        )
        store.chatExportRunning = true
        let started = Date()
        func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(started)) }
        debugLog("Export", "\(kind) export of \(item.filename) started (\(chat.messages.count) messages)")
        Task {
            defer {
                store.chatExportRunning = false
                debugLog("Export", "\(kind) export finished after \(elapsed())")
            }
            do {
                var destination: URL?
                if kind != .print {
                    destination = await askForDestination(kind: kind, title: title, window: window)
                    guard destination != nil else { return }
                }

                let sheet = ExportProgressSheet()
                sheet.present(on: window)
                defer { sheet.dismiss() }

                let html = try await Task.detached(priority: .userInitiated) {
                    let snapshot = ChatExportSnapshot(
                        title: snapshotInput.title, roleName: snapshotInput.role,
                        rows: ChatRenderQueue.projectActiveMessages(snapshotInput.chat),
                        attachmentsDirectory: snapshotInput.directory, exportedAt: Date(),
                        accent: snapshotInput.accent)
                    return try ChatHTMLExporter.render(snapshot, mode: kind == .html ? .html : .pdf)
                }.value

                switch kind {
                case .html:
                    try Data(html.utf8).write(to: destination!, options: .atomic)
                case .pdf:
                    let temp = Self.temporaryPDFURL()
                    try await ChatPDFRenderer().render(html: html, to: temp)
                    try Self.move(temp, to: destination!)
                case .print:
                    let temp = Self.temporaryPDFURL()
                    try await ChatPDFRenderer().render(html: html, to: temp)
                    sheet.dismiss()
                    // Let the sheet's close animation finish before the print panel slides in.
                    try? await Task.sleep(for: .milliseconds(300))
                    printPDF(at: temp, title: title, window: window)
                }
            } catch {
                debugLog("Export", "\(kind) export failed after \(elapsed()): \(error.localizedDescription)")
                showError(error, window: window)
            }
        }
    }

    // MARK: Pieces

    private func askForDestination(kind: Kind, title: String, window: NSWindow) async -> URL? {
        let panel = NSSavePanel()
        let isHTML = kind == .html
        panel.allowedContentTypes = [isHTML ? .html : .pdf]
        panel.nameFieldStringValue = Self.fileName(for: title) + (isHTML ? ".html" : ".pdf")
        panel.canCreateDirectories = true
        panel.title = isHTML ? "Export Chat as HTML" : "Export Chat as PDF"
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.url : nil
    }

    private func printPDF(at url: URL, title: String, window: NSWindow) {
        guard let document = PDFDocument(url: url),
            let operation = document.printOperation(
                for: NSPrintInfo.shared.copy() as? NSPrintInfo, scalingMode: .pageScaleDownToFit, autoRotate: true)
        else {
            showError(ChatExportError.pdfFailed("the generated PDF could not be opened for printing"), window: window)
            return
        }
        operation.jobTitle = title
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func showError(_ error: Error, window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: Files

    /// Printing reads the PDF lazily while the panel is open, so temp files are only
    /// cleaned up at the start of the next export.
    private static func temporaryPDFURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iCanHazAI-export", isDirectory: true)
        let fm = FileManager.default
        if let old = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in old { try? fm.removeItem(at: url) }
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + ".pdf")
    }

    private static func move(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    static func fileName(for title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "[/:\\n\\r\\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Chat" : name
    }
}
