// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import TOML

// MARK: - Config model (Codable, maps to TOML)

/// The app configuration persisted to `~/iCanHazAI/config.toml`.
/// All keys are sorted alphabetically on write via `TOMLEncoder.outputFormatting = .sortedKeys`.
struct AppConfig: Codable, Equatable {
    /// Connection identifier (`"provider/name"`) used by default for new chats.
    var defaultConnection: String?
    /// Role name used by default for new chats. Falls back to "Assistant" when nil.
    var defaultRole: String?
    /// Connection identifier (`"provider/name"`) used for utility tasks (e.g. chat naming).
    var utilityConnection: String?
    /// Whether Mermaid diagram rendering is enabled in the chat view.
    var mermaidEnabled: Bool = false
    /// Whether KaTeX math rendering is enabled in the chat view.
    var katexEnabled: Bool = false
    /// Whether the chat renderer debug overlay is enabled.
    var chatRendererDebugEnabled: Bool = false
    /// Window position and size for the UI layer.
    var window: WindowConfig?

    enum CodingKeys: String, CodingKey {
        case defaultConnection = "default_connection"
        case defaultRole = "default_role"
        case utilityConnection = "utility_connection"
        case mermaidEnabled = "mermaid_enabled"
        case katexEnabled = "katex_enabled"
        case chatRendererDebugEnabled = "chat_renderer_debug_enabled"
        case window
    }
}

struct WindowConfig: Codable, Equatable {
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    /// Whether the left sidebar (chat list) was visible when the window was last closed.
    var chatListSidebarVisible: Bool?
    /// Whether the right sidebar (chat info) was visible when the window was last closed.
    var chatInfoSidebarVisible: Bool?

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
        case chatListSidebarVisible = "chat_list_sidebar_visible"
        case chatInfoSidebarVisible = "chat_info_sidebar_visible"
    }
}

// MARK: - Config manager

/// UI-free singleton actor that owns the app config file at `~/iCanHazAI/config.toml`.
/// Every modification triggers an immediate TOML write so the file is always in a
/// correct state. Validation of connection/role references happens on load and
/// can be re-triggered by callers (e.g. after FSEvents).
actor ConfigManager {

    static let shared = ConfigManager()

    /// The current in-memory config. Always reflects what's on disk.
    private(set) var config = AppConfig()

    /// Whether `load()` has completed at least once. Validation/persistence is
    /// suppressed until the config has been read from disk, otherwise an
    /// FSEvent-triggered `validateReferences()` that fires *before* the initial
    /// load would wipe `default_connection` / `utility_connection` (which are
    /// still nil in the default `AppConfig()` and would be persisted as such).
    private var didLoad = false

    private let fileURL: URL

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        fileURL = home.appendingPathComponent("iCanHazAI").appendingPathComponent("config.toml")
    }

    // MARK: - Load / Save

    /// Loads the config from disk. If the file doesn't exist yet, starts with defaults.
    /// After loading, validates that referenced connections and roles still exist;
    /// clears any that don't and writes the cleaned config back.
    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            config = AppConfig()
            didLoad = true
            return
        }
        do {
            config = try TOMLDecoder().decode(AppConfig.self, from: data)
        } catch {
            config = AppConfig()
            didLoad = true
            return
        }
        didLoad = true
        validateAndSave()
    }

    /// Persists the current config to disk with alphabetically sorted keys.
    /// Does nothing if the config hasn't changed since last write.
    private var lastWritten: AppConfig?
    private func persist() {
        guard config != lastWritten else { return }
        let encoder = TOMLEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(config) else { return }
        // Ensure the parent directory exists.
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        lastWritten = config
    }

    // MARK: - Validation

    /// Checks that `default_connection`, `utility_connection`, and `default_role`
    /// still refer to existing items. Clears invalid references and persists.
    private func validateAndSave() {
        // Suppress validation until the config has been loaded from disk at
        // least once. Otherwise an FSEvent-triggered `validateReferences()`
        // that races ahead of the initial `load()` would validate against the
        // default (empty) `AppConfig()` and persist a wiped config file.
        guard didLoad else { return }

        var dirty = false

        let connections = EnvironmentManager.shared.loadConnections()
        let connectionIDs = Set(connections.map { $0.id })

        // Only clear a connection reference when we actually loaded connections
        // and the referenced one is missing. An empty `loadConnections()` result
        // is almost always a transient/race state (e.g. directory just created,
        // or a connection file being replaced) — not a signal that the user
        // deleted all connections. Treating it as "all deleted" was the root
        // cause of `default_connection` / `utility_connection` being wiped.
        if !connections.isEmpty {
            if let dc = config.defaultConnection, !connectionIDs.contains(dc) {
                config.defaultConnection = nil
                dirty = true
            }
            if let uc = config.utilityConnection, !connectionIDs.contains(uc) {
                config.utilityConnection = nil
                dirty = true
            }
        }

        let roles = EnvironmentManager.shared.loadAllRoles()
        let roleNames = Set(roles.map { $0.name })

        if let dr = config.defaultRole, !roleNames.contains(dr) {
            config.defaultRole = "Assistant"
            dirty = true
        }
        if config.defaultRole == nil {
            config.defaultRole = "Assistant"
            dirty = true
        }

        if dirty {
            persist()
        }
    }

    /// Re-validates connection/role references (call after FSEvents fires for
    /// connections or roles directories). If something was cleared, the config
    /// is persisted automatically.
    func validateReferences() {
        validateAndSave()
    }

    // MARK: - Getters / Setters

    func getDefaultConnection() -> String? {
        config.defaultConnection
    }

    func getDefaultRole() -> String? {
        config.defaultRole
    }

    func getUtilityConnection() -> String? {
        config.utilityConnection
    }

    func getWindow() -> WindowConfig? {
        config.window
    }

    func getMermaidEnabled() -> Bool {
        config.mermaidEnabled
    }

    func getKatexEnabled() -> Bool {
        config.katexEnabled
    }

    func getChatRendererDebugEnabled() -> Bool {
        config.chatRendererDebugEnabled
    }

    func getChatListSidebarVisible() -> Bool? {
        config.window?.chatListSidebarVisible
    }

    func getChatInfoSidebarVisible() -> Bool? {
        config.window?.chatInfoSidebarVisible
    }

    func setDefaultConnection(_ id: String?) {
        config.defaultConnection = id
        persist()
    }

    func setDefaultRole(_ name: String?) {
        config.defaultRole = name
        persist()
    }

    func setUtilityConnection(_ id: String?) {
        config.utilityConnection = id
        persist()
    }

    func setMermaidEnabled(_ enabled: Bool) {
        config.mermaidEnabled = enabled
        persist()
    }

    func setKatexEnabled(_ enabled: Bool) {
        config.katexEnabled = enabled
        persist()
    }

    func setChatRendererDebugEnabled(_ enabled: Bool) {
        config.chatRendererDebugEnabled = enabled
        persist()
    }

    func setWindow(_ window: WindowConfig?) {
        // Merge: preserve existing sidebar visibility if the incoming config
        // doesn't specify it (e.g. when the window frame tracker saves position).
        if var w = window {
            if w.chatListSidebarVisible == nil { w.chatListSidebarVisible = config.window?.chatListSidebarVisible }
            if w.chatInfoSidebarVisible == nil { w.chatInfoSidebarVisible = config.window?.chatInfoSidebarVisible }
            config.window = w
        } else {
            config.window = nil
        }
        persist()
    }

    func setChatListSidebarVisible(_ visible: Bool) {
        if config.window == nil { config.window = WindowConfig() }
        config.window?.chatListSidebarVisible = visible
        persist()
    }

    func setChatInfoSidebarVisible(_ visible: Bool) {
        if config.window == nil { config.window = WindowConfig() }
        config.window?.chatInfoSidebarVisible = visible
        persist()
    }
}
