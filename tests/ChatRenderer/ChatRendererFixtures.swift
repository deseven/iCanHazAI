import Foundation

@testable import iCanHazAI

enum ChatRendererFixtures {
    static func message(
        _ id: String, role: ChatRowModel.Role = .assistant, content: String = "", thinking: String? = nil,
        error: String? = nil
    ) -> ChatRowModel {
        ChatRowModel(
            id: id, role: role, content: content, thinking: thinking, error: error,
            timestamp: Date(timeIntervalSince1970: 0))
    }

    static func paragraph(_ seed: Int, sentences: Int = 4) -> String {
        let words = [
            "native", "renderer", "layout", "message", "scroll", "anchor", "height", "block", "token", "stream",
        ]
        return (0..<sentences).map { s in
            let body = (0..<12).map { words[($0 * 7 + s * 3 + seed) % words.count] }.joined(separator: " ")
            return body.prefix(1).uppercased() + body.dropFirst() + "."
        }.joined(separator: " ")
    }

    /// A deterministic chat of `count` messages with a mix of paragraphs, lists,
    /// code, tables, thinking and tool blocks, so heights vary a lot.
    static func chat(_ count: Int) -> [ChatRowModel] {
        (0..<count).map { i in
            if i % 2 == 0 {
                return message("u-\(i)", role: .user, content: "Question \(i): \(paragraph(i, sentences: 1 + i % 3))")
            }
            var parts = (0..<(1 + i % 5)).map { paragraph(i + $0) }
            if i % 3 == 0 { parts.append("```swift\nlet value = \(i)\nprint(value)\n```") }
            if i % 4 == 1 { parts.append("- first \(i)\n- second\n  - nested\n- third") }
            if i % 7 == 1 { parts.append("| Key | Value |\n| --- | ---: |\n| a | \(i) |\n| b | 2 |") }
            var m = message(
                "a-\(i)", content: parts.joined(separator: "\n\n"),
                thinking: i % 5 == 1 ? paragraph(i, sentences: 6) : nil)
            if i % 6 == 1 {
                m.toolCalls = [.init(id: "c-\(i)", name: "shell", arguments: #"{"command":"ls"}"#, summary: "ls")]
                m.toolResults = [.init(callID: "c-\(i)", content: "file1\nfile2\nfile3", isError: false)]
            }
            return m
        }
    }

    static let streamingText: String = (0..<30).map { "## Part \($0)\n\n" + paragraph($0, sentences: 6) }
        .joined(separator: "\n\n")
}
