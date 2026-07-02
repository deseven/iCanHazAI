import MCP
import Foundation

/// A tool definition paired with its handler closure. Each server keeps a
/// static array of these; `ListTools` returns the `tool`s and `CallTool`
/// dispatches on `params.name` to the matching handler.
struct ToolDefinition {
    let tool: Tool
    let handler: @Sendable ([String: Value]) async throws -> [Tool.Content]
}

/// Build a JSON-Schema object `Value` from a dictionary literal.
func obj(_ dict: [String: Value]) -> Value { .object(dict) }

/// Build a JSON array `Value` from `Value` elements.
func arr(_ values: [Value]) -> Value { .array(values) }

/// Build a JSON array of strings.
func arr(_ values: String...) -> Value { .array(values.map { .string($0) }) }

/// Convenience for returning a text-only tool result.
func textContent(_ s: String) -> [Tool.Content] {
    [.text(text: s, annotations: nil, _meta: nil)]
}

/// Convenience for returning a tool error result.
func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: textContent("Error: \(message)"), isError: true)
}

/// Extracts a string argument, throwing a tool error if missing/invalid.
func requireString(_ args: [String: Value], _ key: String) throws -> String {
    guard let v = args[key], let s = v.stringValue else {
        throw ToolError.missingArgument(key)
    }
    return s
}

/// Extracts an optional string argument.
func optionalString(_ args: [String: Value], _ key: String) -> String? {
    args[key]?.stringValue
}

/// Extracts a numeric argument as Double, throwing a tool error if missing/invalid.
func requireDouble(_ args: [String: Value], _ key: String) throws -> Double {
    guard let v = args[key] else { throw ToolError.missingArgument(key) }
    if let d = v.doubleValue { return d }
    if let i = v.intValue { return Double(i) }
    throw ToolError.invalidArgument(key, "expected number")
}

/// Extracts an optional integer argument.
func optionalInt(_ args: [String: Value], _ key: String) -> Int? {
    guard let v = args[key] else { return nil }
    return v.intValue
}

/// Extracts an optional boolean argument.
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
