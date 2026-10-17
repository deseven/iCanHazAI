// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import WebKit

/// Turns the exporter's HTML into a paginated A4 PDF with WebKit's own print
/// pipeline (system frameworks only). The text stays real, selectable text.
@MainActor
final class ChatPDFRenderer: NSObject, WKNavigationDelegate {
    static let pageSize = NSSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 40

    private var window: NSWindow?
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    func render(html: String, to url: URL) async throws {
        let size = Self.pageSize
        let web = WKWebView(frame: NSRect(origin: .zero, size: size))
        web.navigationDelegate = self
        web.appearance = NSAppearance(named: .aqua)
        web.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // WebKit only runs a print operation for a view that lives in a window; this one is never shown.
        let host = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = web
        webView = web
        window = host
        defer {
            webView = nil
            window = nil
        }

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            web.loadHTMLString(html, baseURL: nil)
        }

        let info = NSPrintInfo()
        info.paperSize = size
        info.topMargin = Self.margin
        info.bottomMargin = Self.margin
        info.leftMargin = Self.margin
        info.rightMargin = Self.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = web.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = NSRect(
            x: 0, y: 0, width: size.width - Self.margin * 2, height: size.height - Self.margin * 2)
        let ok = await withCheckedContinuation { continuation in
            printContinuation = continuation
            operation.runModal(
                for: host, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard ok else { throw ChatExportError.pdfFailed("the print operation did not complete") }
    }

    /// AppKit calls this on a background thread when the print operation ends.
    @objc nonisolated private func printDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [self] in
            printContinuation?.resume(returning: success)
            printContinuation = nil
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        debugLog("Export", "PDF: page load failed: \(error)")
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        debugLog("Export", "PDF: page load failed: \(error)")
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
