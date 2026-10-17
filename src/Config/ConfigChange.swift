// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Describes which config entities changed on disk, so
/// [`ChatEngine.applyConfigChanges(_:)`](src/Chat/ChatEngine.swift) knows what to
/// re-read. Every internal writer (Configurator tools, wizards, "Reload …"
/// menu items) reports its writes this way — the disk itself is not watched.
///
/// Single-entity cases also cover deletion: a missing file is treated as a
/// removal.
enum ConfigChange: Sendable, Hashable {
    /// `config.toml`.
    case config
    /// All connection files (both providers).
    case connections
    case roles
    case role(String)
    case prompts
    case prompt(String)
    case mcp(String)

    /// The loader "Application" row this change belongs to, or nil for kinds
    /// the loader doesn't report (MCPs are reported via the MCP configuration
    /// status).
    var appResource: AppResource? {
        switch self {
        case .config: return .configuration
        case .connections: return .connections
        case .roles, .role: return .roles
        case .prompts, .prompt: return .prompts
        case .mcp: return nil
        }
    }

    /// How many entities this change refreshes, given the on-disk total of its
    /// resource. Drives the loader subtitle (e.g. "1 entry" for a single role).
    func refreshCount(total: Int) -> Int {
        switch self {
        case .role, .prompt, .mcp, .config: return 1
        case .connections, .roles, .prompts: return total
        }
    }
}
