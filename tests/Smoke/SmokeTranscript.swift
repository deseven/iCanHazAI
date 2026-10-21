import Foundation

@testable import iCanHazAI

// Compact, readable renderings of what the app sent, so assertions on request history read as one list and
// a failure shows the whole conversation.

extension MockRequest {
    /// The OpenAI-wire message list, one line per message.
    var transcript: [String] { messages.map(Self.line) }

    private static func line(_ message: [String: Any]) -> String {
        let role = message["role"] as? String ?? "?"
        let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let calls = message["tool_calls"] as? [[String: Any]] {
            let ids = calls.compactMap { $0["id"] as? String }.joined(separator: ",")
            return "assistant[calls \(ids)] \(text)"
        }
        if role == "tool" { return "tool[\(message["tool_call_id"] as? String ?? "?")] \(text)" }
        return "\(role): \(text)"
    }
}

extension SmokeFixture {
    static let systemLine = "system: \(systemPrompt)"

    /// Provider, role and chat for the common case: one provider added, one role installed, one chat open.
    func start(_ sp: SmokeProvider = .deepseek, tools: SmokeRoleTools = .none) async throws -> String {
        try await addProvider(sp)
        try await installRole(tools: tools)
        return await newChat(sp)
    }
}

enum Calc {
    static func call(_ expression: String) -> String { #"{"expression":"\#(expression)"}"# }
}

extension ToolResult {
    var trimmed: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
}
