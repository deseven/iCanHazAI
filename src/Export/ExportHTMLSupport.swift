// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import cmark_gfm
import cmark_gfm_extensions

extension String {
    /// Escapes text for HTML content and double-quoted attribute values.
    var htmlEscaped: String {
        var out = [UInt8]()
        out.reserveCapacity(utf8.count + utf8.count / 8)
        for byte in utf8 {
            switch byte {
            case 38: out.append(contentsOf: "&amp;".utf8)
            case 60: out.append(contentsOf: "&lt;".utf8)
            case 62: out.append(contentsOf: "&gt;".utf8)
            case 34: out.append(contentsOf: "&quot;".utf8)
            default: out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Pre-rendered (static) syntax highlighting: the same grammars the chat view
/// uses, emitted as `<span class="k">` runs styled by the template's CSS.
enum ExportCodeHTML {
    private static func cssClass(_ token: SyntaxToken) -> String {
        switch token {
        case .comment: "c"
        case .keyword: "k"
        case .string: "s"
        case .constant: "n"
        case .function: "f"
        case .type: "t"
        case .property: "p"
        case .tag: "g"
        case .attribute: "a"
        }
    }

    /// A fenced code block. A stated language is followed (even an unsupported
    /// one); only unlabeled code is guessed, mirroring the chat view.
    static func block(code: String, label: String?, language explicit: SyntaxLanguage? = nil) -> String {
        var language = explicit ?? label.flatMap { SyntaxLanguage.from(marker: $0) }
        var shownLabel = label
        if language == nil, label == nil, SyntaxHighlighter.isDetectable(code) {
            language = LanguageDetector.detect(code)
            shownLabel = language?.displayName
        }
        let spans = language.map { SyntaxHighlighter.shared.highlight(code, as: $0).spans } ?? []
        let inner = highlighted(code, spans: spans)
        return
            "<div class=\"code\"><div class=\"code-lang\">\((shownLabel ?? "code").htmlEscaped)</div><pre><code>\(inner)</code></pre></div>\n"
    }

    static func highlighted(_ code: String, spans: [SyntaxSpan]) -> String {
        guard !spans.isEmpty else { return code.htmlEscaped }
        let ns = code as NSString
        var out = ""
        var position = 0
        for span in spans {
            let range = NSIntersectionRange(span.range, NSRange(location: 0, length: ns.length))
            guard range.length > 0, range.location >= position else { continue }
            if range.location > position {
                out += ns.substring(with: NSRange(location: position, length: range.location - position)).htmlEscaped
            }
            out += "<span class=\"\(cssClass(span.token))\">\(ns.substring(with: range).htmlEscaped)</span>"
            position = NSMaxRange(range)
        }
        if position < ns.length { out += ns.substring(from: position).htmlEscaped }
        return out
    }
}

/// 200x200 (max) JPEG thumbnails at 70% quality, as inline data URIs.
enum ExportThumbnail {
    static let maxPixel = 200
    static let quality = 0.7

    static func dataURI(file: URL) -> String? {
        CGImageSourceCreateWithURL(file as CFURL, nil).flatMap(encode)
    }

    static func dataURI(base64: String) -> String? {
        Data(base64Encoded: base64).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap(encode)
    }

    private static func encode(_ source: CGImageSource) -> String? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: thumb.width, height: thumb.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // JPEG has no alpha: flatten transparent images onto white instead of black.
        let rect = CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(thumb, in: rect)
        guard let flat = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}

/// Markdown to HTML through cmark. Raw HTML in the source is shown as text (never
/// emitted), links are limited to safe schemes and images become links, so an
/// exported file can't run scripts or phone home when opened.
enum ExportMarkdownHTML {
    private typealias Node = UnsafeMutablePointer<cmark_node>

    private static let registerExtensions: Void = cmark_gfm_core_extensions_ensure_registered()

    static func render(_ markdown: String) -> String {
        guard markdown.contains(where: { !$0.isWhitespace }) else { return "" }
        _ = registerExtensions
        // UNSAFE only so the pre-rendered code blocks injected below pass through;
        // everything else raw is neutralized in `sanitize`.
        let options = CMARK_OPT_UNSAFE
        guard let parser = cmark_parser_new(options) else { return fallback(markdown) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        var source = markdown
        source.withUTF8 { buf in
            buf.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        }
        guard let doc = cmark_parser_finish(parser) else { return fallback(markdown) }
        defer { cmark_node_free(doc) }
        sanitize(doc)
        guard let cString = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser)) else {
            return fallback(markdown)
        }
        defer { free(cString) }
        return String(cString: cString)
    }

    private static func fallback(_ markdown: String) -> String {
        "<p>\(markdown.htmlEscaped)</p>"
    }

    private static func literal(_ node: Node) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    private static func sanitize(_ doc: Node) {
        // Collect first: the tree is edited below, which an iterator doesn't survive.
        var nodes: [Node] = []
        guard let iterator = cmark_iter_new(doc) else { return }
        defer { cmark_iter_free(iterator) }
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            switch cmark_node_get_type(node) {
            case CMARK_NODE_CODE_BLOCK, CMARK_NODE_HTML_BLOCK, CMARK_NODE_HTML_INLINE, CMARK_NODE_IMAGE,
                CMARK_NODE_LINK:
                nodes.append(node)
            default: break
            }
        }

        for node in nodes {
            switch cmark_node_get_type(node) {
            case CMARK_NODE_CODE_BLOCK:
                var code = literal(node)
                if code.hasSuffix("\n") { code.removeLast() }
                let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
                let first = info.split(separator: " ").first.map(String.init)
                replaceWithHTML(node, ExportCodeHTML.block(code: code, label: first?.isEmpty == false ? first : nil))
            case CMARK_NODE_HTML_BLOCK:
                var html = literal(node)
                while html.hasSuffix("\n") { html.removeLast() }
                replaceWithHTML(node, ExportCodeHTML.block(code: html, label: "html", language: .html))
            case CMARK_NODE_HTML_INLINE:
                cmark_node_set_literal(node, literal(node).htmlEscaped)
            case CMARK_NODE_LINK:
                let url = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
                if isSafe(url) {
                    cmark_node_set_url(node, url)
                } else {
                    unwrap(node)
                }
            case CMARK_NODE_IMAGE:
                convertImage(node)
            default: break
            }
        }
    }

    private static func replaceWithHTML(_ node: Node, _ html: String) {
        guard let replacement = cmark_node_new(CMARK_NODE_HTML_BLOCK) else { return }
        cmark_node_set_literal(replacement, html)
        cmark_node_replace(node, replacement)
        cmark_node_free(node)
    }

    private static func isSafe(_ url: String) -> Bool {
        let lower = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
            || lower.hasPrefix("#")
    }

    /// Replaces a node by its children (an unsafe link keeps its text).
    private static func unwrap(_ node: Node) {
        while let child = cmark_node_first_child(node) {
            cmark_node_insert_before(node, child)
        }
        cmark_node_unlink(node)
        cmark_node_free(node)
    }

    /// Images aren't loaded: like the chat view they show their alt text (or URL) as a link.
    private static func convertImage(_ node: Node) {
        let url = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
        if cmark_node_first_child(node) == nil, let text = cmark_node_new(CMARK_NODE_TEXT) {
            cmark_node_set_literal(text, url)
            cmark_node_append_child(node, text)
        }
        var insideLink = false
        var ancestor = cmark_node_parent(node)
        while let a = ancestor {
            if cmark_node_get_type(a) == CMARK_NODE_LINK { insideLink = true }
            ancestor = cmark_node_parent(a)
        }
        guard isSafe(url), !insideLink, let link = cmark_node_new(CMARK_NODE_LINK) else {
            unwrap(node)
            return
        }
        cmark_node_set_url(link, url)
        while let child = cmark_node_first_child(node) {
            cmark_node_append_child(link, child)
        }
        cmark_node_replace(node, link)
        cmark_node_free(node)
    }
}
