// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import UniformTypeIdentifiers

/// Decides which attachments are opened in Quick Look; anything else goes to
/// the system's default app. Deliberately an allowlist: only passive document
/// formats are previewed, never apps, installers, archives, etc.
enum QuickLookSupport {
    private static let extensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
        "rtf", "rtfd", "pages", "numbers", "key", "csv", "tsv", "epub", "webarchive",
    ]

    private static let types: [UTType] = [.image, .pdf, .text, .spreadsheet, .presentation]

    static func canPreview(filename: String, kind: AttachmentKind) -> Bool {
        if kind == .image { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return types.contains { type.conforms(to: $0) }
    }
}
