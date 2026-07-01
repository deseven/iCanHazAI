// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A minimal JSON value type used by the LLM transport layer and by
/// `Connection.requestParameters` to carry arbitrary, provider-specific JSON
/// without leaking library types into the model layer.
///
/// Conforms to `Codable`, `Sendable`, and `Equatable`.
enum LLMJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([LLMJSONValue])
    case object([String: LLMJSONValue])

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Bool must be checked before Double, because `JSONDecoder` decodes
        // `true`/`false` as `NSNumber` which also bridges to `Double`.
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .number(double)
            return
        }
        if let array = try? container.decode([LLMJSONValue].self) {
            self = .array(array)
            return
        }
        if let object = try? container.decode([String: LLMJSONValue].self) {
            self = .object(object)
            return
        }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v):    try container.encode(v)
        case .number(let v):    try container.encode(v)
        case .bool(let v):      try container.encode(v)
        case .null:              try container.encodeNil()
        case .array(let v):     try container.encode(v)
        case .object(let v):    try container.encode(v)
        }
    }

    // MARK: - Any conversion

    /// Converts this value to a plain `Any` suitable for `JSONSerialization`.
    var anyValue: Any {
        switch self {
        case .string(let v):    return v
        case .number(let v):    return v
        case .bool(let v):      return v
        case .null:              return NSNull()
        case .array(let v):     return v.map { $0.anyValue }
        case .object(let v):    return v.mapValues { $0.anyValue }
        }
    }

    /// Builds an `LLMJSONValue` from a `JSONSerialization` output value
    /// (handles `NSString`/`NSNumber` bridging). Returns `.null` for
    /// unrecognised types.
    static func from(_ any: Any) -> LLMJSONValue {
        if any is NSNull { return .null }
        if let v = any as? Bool { return .bool(v) }
        if let v = any as? Int { return .number(Double(v)) }
        if let v = any as? Double { return .number(v) }
        if let v = any as? NSNumber {
            // `NSNumber.boolValue` is true for both `1` and `true`; use the
            // ObjC type encoding to distinguish actual booleans.
            if String(cString: v.objCType) == "c" || String(cString: v.objCType) == "B" {
                return .bool(v.boolValue)
            }
            return .number(v.doubleValue)
        }
        if let v = any as? String { return .string(v) }
        if let v = any as? [Any] { return .array(v.map { from($0) }) }
        if let v = any as? [String: Any] { return .object(v.mapValues { from($0) }) }
        return .null
    }
}
