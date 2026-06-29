// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import WebKit

/// A `WKURLSchemeHandler` that serves chat image files via the custom
/// `ichai://` scheme. The renderer references images as
/// `<img src="ichai://{UUID}.{ext}">`; this handler resolves the UUID+ext
/// against the currently selected chat's image folder and streams the bytes
/// back without ever putting base64 into the DOM.
///
/// The handler is registered for the `"ichai"` scheme. It is main-actor
/// isolated because it reads the current chat filename from the shared view
/// model; lookups are cheap (a single file read).
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The scheme this handler is registered for.
    nonisolated static let scheme = "ichai"

    /// The currently selected chat filename, set by the web view model so the
    /// handler can resolve image paths. Main-actor isolated.
    static var currentChatFilename: String?

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        // The host/path carries "{UUID}.{ext}". We accept it from either the
        // host or the path component depending on how WK parses the URL.
        let resource = imageResource(from: url)

        guard let resource, !resource.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let chatFilename = ImageSchemeHandler.currentChatFilename ?? ""
        let dir = EnvironmentManager.shared.imagesDirectory(for: chatFilename)
        let fileURL = dir.appendingPathComponent(resource)

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let ext = (resource as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        default: mime = "application/octet-stream"
        }

        let response = HTTPURLResponse(
            url: url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-cache",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to cancel; the handler is synchronous.
    }

    // MARK: - Helpers

    /// Extracts the "{UUID}.{ext}" resource string from an `ichai://` URL.
    private func imageResource(from url: URL?) -> String? {
        guard let url else { return nil }
        // `ichai://{UUID}.{ext}` — the host holds the resource.
        if let host = url.host, !host.isEmpty {
            return host
        }
        // Fallback: path-based form `ichai:/{UUID}.{ext}`.
        let path = url.path
        if !path.isEmpty {
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        return nil
    }
}
