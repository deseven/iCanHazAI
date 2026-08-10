// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import TOML

/// Shared config-text validation used by both the standard file loaders
/// ([`EnvironmentManager`](src/Environment/EnvironmentManager.swift),
/// [`ConfigManager`](src/Config/ConfigManager.swift)) and the in-process
/// [`ConfiguratorTools`](src/Config/ConfiguratorTools.swift) write tools.
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
        if let v = obj["headers"] {
            guard let dict = v as? [String: Any] else {
                throw ConfigValidationError("connection field \"headers\" must be an object of strings")
            }
            for (k, val) in dict where !(val is String) {
                throw ConfigValidationError("connection field \"headers\" must be an object of strings (value for \"\(k)\" is not a string)")
            }
        }
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
    /// cross-field rules documented in [`validateRole`](src/Config/ConfigValidation.swift).
    /// `references` carries the entities a role may point at; when nil the
    /// reference checks are skipped (used for trusted bundled content).
    static func decodeRole(_ data: Data, references: RoleReferences? = nil) throws -> RoleConfig {
        do {
            let config = try TOMLDecoder().decode(RoleConfig.self, from: data)
            try validateRole(config, references: references)
            return config
        } catch let error as ConfigValidationError {
            throw error
        } catch {
            throw ConfigValidationError("role config is invalid: \(error)")
        }
    }

    /// Cross-field validation for a decoded [`RoleConfig`](src/Chat/Models.swift).
    ///
    /// - `connection`, `prompt`, and every `[[mcps]]` entry must reference an
    ///   existing entity. Checked only when `references` is provided; a name
    ///   counts as existing when its config file is on disk, even if that
    ///   config failed to decode (the broken config reports its own error).
    /// - `working_directory` requires at least one workdir-capable built-in
    ///   group (Filesystem, Code, or Shell). Without one, the directory
    ///   setting is meaningless because nothing consumes it.
    /// - `directory_isolation` (top level) isolates the Filesystem and Code
    ///   groups to the working directory. It requires at least one of them to
    ///   be enabled — otherwise there is nothing to isolate. Isolation always
    ///   needs a directory to isolate to, but it doesn't have to come from
    ///   the role: Filesystem/Code can't run without a directory, so when
    ///   `working_directory` is omitted the user is forced to pick one per
    ///   chat.
    /// - `directory_isolation` combined with the Shell group is an error:
    ///   Shell commands are not directory-isolated, so the model could escape
    ///   the confinement and the isolation promise would be void.
    /// - `features.with_chat_trees = true` requires `features.with_response_regen`
    ///   to also be true: chat trees only exist via regeneration/edit-forking,
    ///   so enabling trees without regen is a contradiction.
    static func validateRole(_ config: RoleConfig, references: RoleReferences? = nil) throws {
        if let references {
            if let connection = config.connection, !connection.isEmpty, !references.connectionIDs.contains(connection) {
                throw ConfigValidationError(
                    "role config references unknown connection \"\(connection)\" "
                    + "(no matching config in the Connections directory)"
                )
            }
            if let prompt = config.prompt, !prompt.isEmpty, !references.promptNames.contains(prompt) {
                throw ConfigValidationError(
                    "role config references unknown prompt \"\(prompt)\" "
                    + "(no matching file in the Prompts directory)"
                )
            }
            if let mcps = config.mcps {
                var unknown: [String] = []
                for entry in mcps where !references.mcpNames.contains(entry.mcp) && !unknown.contains(entry.mcp) {
                    unknown.append(entry.mcp)
                }
                if !unknown.isEmpty {
                    throw ConfigValidationError(
                        "role config references unknown MCP server(s): \(unknown.map { "\"\($0)\"" }.joined(separator: ", ")) "
                        + "(no matching config in the MCPs directory)"
                    )
                }
            }
        }

        let enabledGroups = BuiltinTools.groupOrder.filter { group in
            switch group {
            case BuiltinTools.utilsGroup: return config.utils != nil
            case BuiltinTools.filesystemGroup: return config.filesystem != nil
            case BuiltinTools.codeGroup: return config.code != nil
            case BuiltinTools.shellGroup: return config.shell != nil
            case BuiltinTools.webGroup: return config.web != nil
            default: return false
            }
        }

        let hasWorkdirCapableGroup = enabledGroups.contains {
            BuiltinTools.workdirCapableGroups.contains($0)
        }

        if config.workingDirectory?.isEmpty == false && !hasWorkdirCapableGroup {
            throw ConfigValidationError(
                "role config sets working_directory "
                + "but selects no workdir-capable built-in group (Filesystem, Code, or Shell)"
            )
        }

        if config.directoryIsolation == true {
            // Isolation applies to Filesystem and Code; with neither enabled
            // there is nothing to isolate, so the setting is meaningless.
            let hasIsolationCapableGroup = enabledGroups.contains {
                BuiltinTools.isolationCapableGroups.contains($0)
            }
            if !hasIsolationCapableGroup {
                throw ConfigValidationError(
                    "role config enables directory_isolation "
                    + "but selects no isolation-capable built-in group (Filesystem or Code)"
                )
            }
            if config.shell != nil {
                throw ConfigValidationError(
                    "role config enables directory_isolation but also selects the Shell group; "
                    + "shell tools are NOT directory-isolated, so the model could escape the confinement"
                )
            }
        }

        // Chat trees only exist via regeneration/edit-forking, so enabling
        // trees without regen is a contradiction.
        if config.features?.withChatTrees == true && config.features?.withResponseRegen != true {
            throw ConfigValidationError(
                "role config enables with_chat_trees but not with_response_regen; "
                + "chat trees only exist via response regeneration, so both must be enabled together"
            )
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

/// The entities a role may reference, used by
/// [`validateRole`](src/Config/ConfigValidation.swift) to check `connection`,
/// `prompt`, and `[[mcps]]` entries. Built by the loaders from the configs
/// present on disk; a config that exists but failed to decode still counts as
/// existing (it reports its own error separately).
struct RoleReferences: Sendable {
    /// Connection IDs in `provider/name` form (matches `Connection.id`).
    var connectionIDs: Set<String>
    var promptNames: Set<String>
    var mcpNames: Set<String>
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
