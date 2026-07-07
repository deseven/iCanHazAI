import MCP
import Foundation

struct ToolDefinition {
    let tool: Tool
    let handler: @Sendable ([String: Value]) async throws -> [Tool.Content]
}

func obj(_ dict: [String: Value]) -> Value { .object(dict) }
func arr(_ values: [Value]) -> Value { .array(values) }
func arr(_ values: String...) -> Value { .array(values.map { .string($0) }) }

func textContent(_ s: String) -> [Tool.Content] {
    [.text(text: s, annotations: nil, _meta: nil)]
}

func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: textContent("Error: \(message)"), isError: true)
}

func requireString(_ args: [String: Value], _ key: String) throws -> String {
    guard let v = args[key], let s = v.stringValue else {
        throw ToolError.missingArgument(key)
    }
    return s
}

func optionalString(_ args: [String: Value], _ key: String) -> String? {
    args[key]?.stringValue
}

func optionalInt(_ args: [String: Value], _ key: String) -> Int? {
    guard let v = args[key] else { return nil }
    return v.intValue
}

func optionalBool(_ args: [String: Value], _ key: String) -> Bool? {
    args[key]?.boolValue
}

enum ToolError: Error, CustomStringConvertible {
    case missingArgument(String)
    case invalidArgument(String, String)

    var description: String {
        switch self {
        case .missingArgument(let k): return "missing required argument '\(k)'"
        case .invalidArgument(let k, let r): return "invalid argument '\(k)': \(r)"
        }
    }
}
