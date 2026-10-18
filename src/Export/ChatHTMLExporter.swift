// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum ChatExportMode: Sendable {
    /// A standalone page: thinking and tool blocks are collapsed but expandable.
    case html
    /// Input for the PDF: those blocks are a one-line summary without a body.
    case pdf
}

/// Everything an export needs, detached from the live chat.
struct ChatExportSnapshot: Sendable {
    let title: String
    let roleName: String?
    let rows: [ChatRowModel]
    let attachmentsDirectory: URL
    let exportedAt: Date
    /// CSS color of the assistant's name and icon, e.g. `light-dark(#0a84ff, #0a84ff)`.
    let accent: String
}

enum ChatExportError: LocalizedError {
    case templateMissing
    case pdfFailed(String)

    var errorDescription: String? {
        switch self {
        case .templateMissing: "The HTML template (Export/chat.html) is missing from the app bundle."
        case .pdfFailed(let reason): "PDF generation failed: \(reason)"
        }
    }
}

/// Renders a chat to a self-contained HTML page using the bundled template
/// (`res/export/chat.html`). Pure and thread-safe: run it off the main actor.
struct ChatHTMLExporter {
    let snapshot: ChatExportSnapshot
    let mode: ChatExportMode

    static func render(_ snapshot: ChatExportSnapshot, mode: ChatExportMode) throws -> String {
        try ChatHTMLExporter(snapshot: snapshot, mode: mode).render()
    }

    // MARK: Template

    /// The bundled `Export` resource folder; sources and tests fall back to the repo's `res/export`.
    private static let templateURL: URL? = {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Export/chat.html"),
            fm.fileExists(atPath: bundled.path)
        {
            return bundled
        }
        // …/src/Export/ChatHTMLExporter.swift → repo root
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let checkout = root.appendingPathComponent("res/export/chat.html")
        return fm.fileExists(atPath: checkout.path) ? checkout : nil
    }()

    /// Fills `{{NAME}}` placeholders in one pass over the template, so substituted
    /// values (a chat title, message text) are never scanned for placeholders.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([A-Z]+)\\}\\}") else { return template }
        let ns = template as NSString
        var out = ""
        var position = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: position, length: match.range.location - position))
            let name = ns.substring(with: match.range(at: 1))
            out += values[name] ?? ns.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        out += ns.substring(from: position)
        return out
    }

    func render() throws -> String {
        guard let url = Self.templateURL, let template = try? String(contentsOf: url, encoding: .utf8) else {
            throw ChatExportError.templateMissing
        }
        var body = ""
        for row in snapshot.rows {
            try Task.checkCancellation()
            body += message(row)
        }
        var meta: [String] = []
        if let role = snapshot.roleName, !role.isEmpty { meta.append(role) }
        meta.append("\(snapshot.rows.count) message\(snapshot.rows.count == 1 ? "" : "s")")
        meta.append("exported " + snapshot.exportedAt.formatted(date: .abbreviated, time: .shortened))
        return Self.fill(
            template,
            [
                "MODE": mode == .pdf ? "pdf" : "html",
                "TITLE": snapshot.title.htmlEscaped,
                "ACCENT": snapshot.accent,
                "META": meta.joined(separator: " · ").htmlEscaped,
                "BODY": body,
            ])
    }

    // MARK: Messages

    /// An icon from the template's inline SVG sprite (CSS masks print as solid squares in PDFs).
    private func icon(_ name: String, _ cssClass: String = "ico") -> String {
        "<svg class=\"\(cssClass)\" aria-hidden=\"true\"><use href=\"#i-\(name)\"/></svg>"
    }

    private func message(_ m: ChatRowModel) -> String {
        var body = ""
        if m.hasThinking, let thinking = m.thinking {
            body += collapsible(
                "thinking",
                summary: icon("thinking")
                    + "<span class=\"b-main\"><span class=\"b-l1\"><span class=\"b-title\">\(RenderedMessage.thinkingTitle(m.thinkingDuration).htmlEscaped)</span></span></span>"
            ) {
                "<div class=\"thinking-text\">\(thinking.htmlEscaped)</div>"
            }
        }
        if !m.attachments.isEmpty { body += attachments(m.attachments) }
        if m.hasContent { body += "<div class=\"md\">\(ExportMarkdownHTML.render(m.content))</div>\n" }
        for call in m.toolCalls { body += toolBlock(m, call) }
        if m.role == .tool, m.toolCalls.isEmpty {
            for result in m.toolResults { body += standaloneResult(result) }
        }
        if m.hasError, let error = m.error {
            body += "<div class=\"error\">\(icon("alert"))<span>\(error.htmlEscaped)</span></div>\n"
        }
        // Placeholder assistant messages (nothing arrived) have nothing to show.
        guard !body.isEmpty else { return "" }

        let (iconName, label): (String, String) =
            switch m.role {
            case .user: ("user", "You")
            case .assistant: ("assistant", snapshot.roleName ?? "Assistant")
            case .tool: ("tool", "Tool")
            case .system: ("system", "System")
            }
        var detail = m.timestamp.formatted(date: .abbreviated, time: .shortened)
        if m.role == .assistant, let model = m.model, !model.isEmpty {
            detail += " · via \(model)"
        }
        return """
            <article class="msg \(m.role.rawValue)">
            <div class="msg-head">\(self.icon(iconName, "avatar"))<span class="who">\(label.htmlEscaped)</span><span class="when">\(detail.htmlEscaped)</span></div>
            <div class="msg-body">
            \(body)</div>
            </article>

            """
    }

    /// A `<details>` block for HTML; for the PDF only its summary line (the body is never built).
    private func collapsible(_ kind: String, summary: String, body: () -> String) -> String {
        switch mode {
        case .html:
            return
                "<details class=\"block \(kind)\"><summary>\(summary)</summary><div class=\"block-body\">\(body())</div></details>\n"
        case .pdf:
            return "<div class=\"block \(kind)\"><div class=\"summary\">\(summary)</div></div>\n"
        }
    }

    // MARK: Attachments

    private func attachments(_ items: [ChatRowModel.AttachmentInfo]) -> String {
        var h = "<div class=\"attachments\">"
        for item in items {
            let name = item.displayName.htmlEscaped
            if item.kind == .image {
                let file = snapshot.attachmentsDirectory.appendingPathComponent(item.filename)
                if let uri = ExportThumbnail.dataURI(file: file) {
                    h += "<img class=\"thumb\" src=\"\(uri)\" alt=\"\(name)\" title=\"\(name)\">"
                } else {
                    h +=
                        "<span class=\"chip\">\(icon("image"))\(name) <span class=\"note\">(image unavailable)</span></span>"
                }
            } else {
                var chip = "<span class=\"chip\">\(icon("file"))\(name)"
                if let note = item.statusText { chip += " <span class=\"note\">(\(note.htmlEscaped))</span>" }
                h += chip + "</span>"
            }
        }
        return h + "</div>\n"
    }

    // MARK: Tool calls

    private func toolBlock(_ m: ChatRowModel, _ call: ChatRowModel.ToolCall) -> String {
        let result = m.result(for: call)
        let status = ToolPresentation.status(for: result, running: false, pending: call.pendingApproval)
        let line = call.summary ?? ToolSummary.callLine(name: call.name, arguments: call.arguments)
        var first = "<span class=\"b-title\">\(ToolPresentation.shortName(call.name).htmlEscaped)</span>"
        if !line.isEmpty { first += "<span class=\"b-sum\">\(line.htmlEscaped)</span>" }
        var second = ""
        if let status {
            let badge = "<span class=\"badge s-\(status.kind.rawValue)\">\(status.label.htmlEscaped)</span>"
            first += badge.replacingOccurrences(of: "class=\"badge", with: "class=\"b-open badge")
            second = "<span class=\"b-l2\">\(badge)"
            if !status.description.isEmpty {
                second += "<span class=\"b-desc\">\(status.description.htmlEscaped)</span>"
            }
            second += "</span>"
        }
        let summary = icon("wrench") + "<span class=\"b-main\"><span class=\"b-l1\">\(first)</span>\(second)</span>"
        return collapsible("tool", summary: summary) { toolBody(call, result) }
    }

    private func toolBody(_ call: ChatRowModel.ToolCall, _ result: ChatRowModel.ToolResult?) -> String {
        var h = ""
        if let diff = call.diff, !diff.isEmpty {
            h += label("Diff")
            h += diffHTML(diff)
        } else if !(call.name == "shell" && appendShellCommand(&h, call.arguments)),
            !ToolSummary.isEmptyArgs(call.arguments)
        {
            h += label("Arguments")
            h += entriesOrRaw(call.arguments)
        }
        guard let result else { return h }
        if let image = result.image {
            h += label("Image", hint: "vision-capable models")
            if let uri = ExportThumbnail.dataURI(base64: image.data) {
                h += "<img class=\"thumb\" src=\"\(uri)\" alt=\"Tool result image\">"
            }
            h += label("Fallback", hint: "vision-incapable models")
            h += plain(result.content)
        } else {
            h += label("Result")
            let failed = result.isError && !result.isDenied && !result.isCancelled
            if result.content.drop(while: \.isWhitespace).first == "{",
                let entries = ToolSummary.argumentEntries(result.content)
            {
                h += entriesHTML(entries)
            } else {
                h += plain(result.content, failed: failed)
            }
        }
        return h
    }

    private func standaloneResult(_ result: ChatRowModel.ToolResult) -> String {
        let failed = result.isError && !result.isDenied && !result.isCancelled
        return collapsible(
            "tool",
            summary: icon("wrench")
                + "<span class=\"b-main\"><span class=\"b-l1\"><span class=\"b-title\">Tool result</span><span class=\"b-sum\">\(ToolPresentation.firstLine(result.content).htmlEscaped)</span></span></span>"
        ) { plain(result.content, failed: failed) }
    }

    private func appendShellCommand(_ h: inout String, _ arguments: String) -> Bool {
        guard let entries = ToolSummary.argumentEntries(arguments),
            let command = entries.first(where: { $0.key == "command" })
        else { return false }
        let rest = entries.filter { $0.key != "command" }
            .map { "\($0.key): \($0.value.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: " · ")
        h += label("Command", hint: rest)
        h += plain(command.value)
        return true
    }

    private func entriesOrRaw(_ arguments: String) -> String {
        if let entries = ToolSummary.argumentEntries(arguments) { return entriesHTML(entries) }
        return plain(arguments)
    }

    private func label(_ title: String, hint: String? = nil) -> String {
        var h = "<div class=\"lbl\">\(title.htmlEscaped)"
        if let hint, !hint.isEmpty { h += "<span class=\"hint\">\(hint.htmlEscaped)</span>" }
        return h + "</div>"
    }

    private func entriesHTML(_ entries: [ToolSummary.ArgEntry]) -> String {
        var h = "<dl class=\"args\">"
        for e in entries { h += "<dt>\(e.key.htmlEscaped)</dt><dd>\(plain(e.value))</dd>" }
        return h + "</dl>"
    }

    private func plain(_ text: String, failed: Bool = false) -> String {
        var trimmed = text
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        return "<pre class=\"plain\(failed ? " err" : "")\">\(trimmed.htmlEscaped)</pre>"
    }

    private func diffHTML(_ diff: String) -> String {
        var lines: [String] = []
        var inHeader = true
        var trimmed = diff
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            let kind = DiffLineKind.classify(line, inHeader: inHeader)
            if kind == .hunk { inHeader = false }
            let cls =
                switch kind {
                case .added: "a"
                case .removed: "r"
                case .hunk, .header: "h"
                case .context: ""
                }
            let escaped = String(line).htmlEscaped
            lines.append(cls.isEmpty ? escaped : "<span class=\"\(cls)\">\(escaped)</span>")
        }
        return "<pre class=\"plain diff\">\(lines.joined(separator: "\n"))</pre>"
    }
}
