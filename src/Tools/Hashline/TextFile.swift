// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A UTF-8 text file split into the parts the file tools care about: the BOM,
/// the dominant line ending, and the content itself normalized to LF.
/// Everything the model sees or edits (hash, `read_file`, `find_text`, the
/// applier, previews) works on `text`; `encode` restores the on-disk shape.
struct TextFile: Equatable, Sendable {
    enum LineEnding: Sendable {
        case lf
        case crlf
    }

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    let hasBOM: Bool
    /// The dominant ending (CRLF only when it is the majority of line breaks);
    /// LF when the file has none.
    let lineEnding: LineEnding
    /// LF-normalized and BOM-stripped.
    let text: String

    /// Returns nil when the data is not valid UTF-8. The BOM is detected on
    /// the raw bytes: `String(data:encoding:)` would drop it silently.
    static func decode(_ data: Data) -> TextFile? {
        let hasBOM = data.starts(with: bom)
        var normalized: [UInt8] = []
        normalized.reserveCapacity(data.count)
        var crlf = 0
        var lf = 0
        var previous: UInt8 = 0
        for byte in data.dropFirst(hasBOM ? bom.count : 0) {
            if byte == 0x0A {
                if previous == 0x0D {
                    // Drop the CR that was already emitted.
                    normalized.removeLast()
                    crlf += 1
                } else {
                    lf += 1
                }
            }
            normalized.append(byte)
            previous = byte
        }
        guard let text = String(validating: normalized, as: UTF8.self) else { return nil }
        return TextFile(hasBOM: hasBOM, lineEnding: crlf > lf ? .crlf : .lf, text: text)
    }

    /// Serializes `newText` (LF-normalized) back with this file's BOM and
    /// line ending.
    func encode(_ newText: String) -> Data {
        var out = Data()
        out.reserveCapacity(newText.utf8.count + (hasBOM ? Self.bom.count : 0))
        if hasBOM { out.append(contentsOf: Self.bom) }
        switch lineEnding {
        case .lf:
            out.append(contentsOf: newText.utf8)
        case .crlf:
            var previous: UInt8 = 0
            for byte in newText.utf8 {
                if byte == 0x0A, previous != 0x0D { out.append(0x0D) }
                out.append(byte)
                previous = byte
            }
        }
        return out
    }
}
