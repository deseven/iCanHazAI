// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import WebKit

/// A `WKURLSchemeHandler` that serves chat images via the custom `ichai://`
/// scheme. Two resource shapes are supported:
///
/// - **Attachment images**: `ichai://{percent-encoded filename}` — resolved
///   against the currently selected chat's attachment folder and streamed back
///   without ever putting base64 into the DOM. The filename is percent-encoded
///   so names with spaces or non-ASCII characters survive the URL round-trip.
/// - **Tool result images**: `ichai://toolresult/{callID}` — resolved from the
///   chat data (the `ToolResult.image` on the `tool`-role message matching
///   `callID`). No file is written to disk; the processed bytes live on the
///   `ToolResult` and are served directly from memory.
///
/// The handler is registered for the `"ichai"` scheme. It is main-actor
/// isolated because it reads the current chat filename from the shared view
/// model; lookups are cheap (a single file read or an in-memory scan).
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The scheme this handler is registered for.
    nonisolated static let scheme = "ichai"

    /// Host prefix for tool-result image URLs (`ichai://toolresult/{callID}`).
    static let toolResultHost = "toolresult"

    /// Percent-encodes a filename for use as the host of an `ichai://` URL.
    /// Uses `urlHostAllowed` so spaces, slashes, colons, etc. are encoded.
    /// Pure function — `nonisolated` so it can be called from any context.
    nonisolated static func encodeResource(_ filename: String) -> String {
        filename.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? filename
    }

    /// Decodes a percent-encoded resource string back to the raw filename.
    /// Pure function — `nonisolated` so it can be called from any context.
    nonisolated static func decodeResource(_ resource: String) -> String {
        resource.removingPercentEncoding ?? resource
    }

    /// The currently selected chat filename, set by the web view model so the
    /// handler can resolve image paths. Main-actor isolated.
    static var currentChatFilename: String?

    /// A lookup closure that resolves a `callID` to its `ToolResultImage` for
    /// the currently selected chat. Set by the web view model so the handler
    /// can serve tool-result images from the in-memory chat data without a
    /// disk read. Main-actor isolated.
    static var toolResultImageLookup: ((String) -> ToolResultImage?)?

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        let resource = imageResource(from: url)

        guard let resource, !resource.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Tool-result image: serve from chat data (no disk file).
        // `ichai://toolresult/{callID}` — the host is "toolresult", the
        // callID is in the path (with a leading "/").
        if resource == Self.toolResultHost {
            let path = url?.path ?? ""
            let callID = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard !callID.isEmpty else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            serveToolResultImage(callID: callID, url: url!, urlSchemeTask: urlSchemeTask)
            return
        }

        // Attachment image: serve from the chat's attachment directory.
        // The resource host is percent-encoded; decode it back to the raw
        // filename before resolving against the attachment directory.
        let filename = Self.decodeResource(resource)
        let chatFilename = ImageSchemeHandler.currentChatFilename ?? ""
        let dir = EnvironmentManager.shared.attachmentsDirectory(for: chatFilename)
        let fileURL = dir.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = Self.mime(forExt: ext)

        Self.respond(url: url!, data: data, mime: mime, urlSchemeTask: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    }

    // MARK: - Tool result images

    /// Serves a tool-result image from the in-memory chat data via the
    /// `toolResultImageLookup` closure. Falls back to a 404 if the callID
    /// can't be resolved (e.g. the message was deleted).
    private func serveToolResultImage(callID: String, url: URL, urlSchemeTask: WKURLSchemeTask) {
        guard let image = Self.toolResultImageLookup?(callID) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data = image.decoded
        guard !data.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        Self.respond(url: url, data: data, mime: image.mimeType, urlSchemeTask: urlSchemeTask)
    }

    // MARK: - Helpers

    /// Sends a data response with the given mime type.
    private static func respond(url: URL, data: Data, mime: String, urlSchemeTask: WKURLSchemeTask) {
        let response = HTTPURLResponse(
            url: url,
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

    /// Maps a file extension to a mime type for attachment images.
    private static func mime(forExt ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    /// Extracts the resource string from an `ichai://` URL. For attachment
    /// images this is the percent-encoded filename host; for tool-result
    /// images the host is `toolresult` and the callID is in the path.
    private func imageResource(from url: URL?) -> String? {
        guard let url else { return nil }
        // `ichai://{percent-encoded filename}` — the host holds the resource.
        if let host = url.host, !host.isEmpty {
            return host
        }
        // Fallback: path-based form `ichai:/{filename}`.
        let path = url.path
        if !path.isEmpty {
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        return nil
    }
}

