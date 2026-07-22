// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import TOML

/// Shared config-text validation used by both the standard file loaders
/// ([`EnvironmentManager`](src/EnvironmentManager.swift),
/// [`ConfigManager`](src/ConfigManager.swift)) and the in-process
/// [`ConfiguratorTools`](src/ConfiguratorTools.swift) write tools.
///
/// The underlying decoders (`JSONDecoder`, `TOMLDecoder`) produce generic
/// "The data couldn't be read because it is missing." messages that don't say
/// *which* key is missing. These wrappers surface field-specific reasons
/// (e.g. a connection missing `model`, or `Key 'transport' not found. Available
/// keys: …` for TOML) so a broken external edit logs something actionable.
///
/// Loaders use these to decode-and-log; the configurator write tools use them
/// as a dry-run validation gate before writing to disk.
enum ConfigValidation {

    /// Validates and decodes a connection (JSONC). `model` is the only required
    /// field; the rest are checked for type correctness before the final decode.
    static func decodeConnection(_ data: Data) throws -> ConnectionConfig {
        guard let source = String(data: data, encoding: .utf8) else {
            throw ConfigValidationError("connection config is not valid UTF-8")
        }
        guard let obj = JSONC.parse(source) as? [String: Any] else {
            throw ConfigValidationError("connection config is not valid JSONC (expected a JSON object)")
        }
        guard let model = obj["model"] as? String,
              !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigValidationError("connection config is missing the required \"model\" field (a non-empty model string)")
        }
        if let v = obj["baseUrl"], !(v is String) { throw ConfigValidationError("connection field \"baseUrl\" must be a string") }
        if let v = obj["apiKey"], !(v is String) { throw ConfigValidationError("connection field \"apiKey\" must be a string") }
        if let v = obj["imageInput"], !(v is Bool) { throw ConfigValidationError("connection field \"imageInput\" must be a boolean") }
        if let v = obj["requestParameters"], !(v is [String: Any]) { throw ConfigValidationError("connection field \"requestParameters\" must be an object") }
        do {
            return try JSONC.decode(data, as: ConnectionConfig.self)
        } catch {
            throw ConfigValidationError("connection config failed validation: \(error)")
        }
    }

    /// Validates and decodes a custom MCP server (TOML).
    static func decodeMCP(_ data: Data) throws -> MCPConfig {
        do {
            return try TOMLDecoder().decode(MCPConfig.self, from: data)
        } catch {
            throw ConfigValidationError("MCP config is invalid: \(error)")
        }
    }

    /// Validates and decodes a role (TOML). Beyond TOML decoding, enforces the
    /// cross-field rules documented in [`validateRole`](src/ConfigValidation.swift).
    static func decodeRole(_ data: Data) throws -> RoleConfig {
        do {
            let config = try TOMLDecoder().decode(RoleConfig.self, from: data)
            try validateRole(config)
            return config
        } catch let error as ConfigValidationError {
            throw error
        } catch {
            throw ConfigValidationError("role config is invalid: \(error)")
        }
    }

    /// Cross-field validation for a decoded [`RoleConfig`](src/Models.swift).
    ///
    /// - `working_directory` / `working_directory_override_allowed` require at
    ///   least one workdir-capable built-in group (Filesystem, Code, or Shell).
    ///   Without one, the directory setting is meaningless because nothing
    ///   consumes it.
    /// - `directory_isolation` is only meaningful on the Filesystem and Code
    ///   groups. Setting it on any other group (including Shell) is an error.
    /// - `directory_isolation` requires a working directory to be available —
    ///   either pre-set (`working_directory`) or user-pickable
    ///   (`working_directory_override_allowed = true`). Without one, the
    ///   isolation target is undefined.
    static func validateRole(_ config: RoleConfig) throws {
        let enabledGroups = BuiltinTools.groupOrder.filter { group in
            switch group {
            case BuiltinTools.utilsGroup: return config.utils != nil
            case BuiltinTools.filesystemGroup: return config.filesystem != nil
            case BuiltinTools.codeGroup: return config.code != nil
            case BuiltinTools.shellGroup: return config.shell != nil
            default: return false
            }
        }

        let hasWorkdirCapableGroup = enabledGroups.contains {
            BuiltinTools.workdirCapableGroups.contains($0)
        }

        let hasWorkdir = config.workingDirectory?.isEmpty == false
        let hasOverride = config.workingDirectoryOverrideAllowed ?? false

        if (hasWorkdir || hasOverride) && !hasWorkdirCapableGroup {
            throw ConfigValidationError(
                "role config sets working_directory or working_directory_override_allowed "
                + "but selects no workdir-capable built-in group (Filesystem, Code, or Shell)"
            )
        }

        // Check directory_isolation on each enabled group.
        let groupConfigs: [(String, RoleToolGroup?)] = [
            (BuiltinTools.filesystemGroup, config.filesystem),
            (BuiltinTools.codeGroup, config.code),
            (BuiltinTools.shellGroup, config.shell),
            (BuiltinTools.utilsGroup, config.utils),
        ]
        for (group, groupConfig) in groupConfigs {
            guard let groupConfig, groupConfig.directoryIsolation == true else { continue }
            if !BuiltinTools.isolationCapableGroups.contains(group) {
                throw ConfigValidationError(
                    "role config sets directory_isolation on group \"\(group)\", "
                    + "but it is only supported on Filesystem and Code"
                )
            }
            if !hasWorkdir && !hasOverride {
                throw ConfigValidationError(
                    "role config sets directory_isolation on group \"\(group)\" "
                    + "but provides no working directory (set working_directory "
                    + "or working_directory_override_allowed = true)"
                )
            }
        }
    }

    /// Validates and decodes the app config (TOML).
    static func decodeAppConfig(_ data: Data) throws -> AppConfig {
        do {
            return try TOMLDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw ConfigValidationError("app config is invalid: \(error)")
        }
    }
}

/// A config validation failure with a human-readable reason. Conforms to both
/// `LocalizedError` (so `localizedDescription` returns the message for the
/// loaders' `debugLog` calls) and `CustomStringConvertible` (so string
/// interpolation surfaces it directly).
struct ConfigValidationError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}
