// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import TOML

// MARK: - Config model (Codable, maps to TOML)

/// The app configuration persisted to `~/iCanHazAI/config.toml`.
/// Preferences are organized into TOML groups that mirror the preferences
/// UI tabs: `[general]`, `[chat_features]`, `[debug]`, and `[window]`.
/// All keys are sorted alphabetically on write via
/// `TOMLEncoder.outputFormatting = .sortedKeys`.
struct AppConfig: Codable, Equatable {
    /// General preferences: default connection, role, and utility connection.
    var general: GeneralConfig = GeneralConfig()
    /// Chat behaviour toggles: default expansion of thinking / tool use blocks.
    var chatBehaviour: ChatBehaviourConfig = ChatBehaviourConfig()
    /// Chat feature toggles: Mermaid and KaTeX rendering.
    var chatFeatures: ChatFeaturesConfig = ChatFeaturesConfig()
    /// Debug preferences: chat renderer debug overlay.
    var debug: DebugConfig = DebugConfig()
    /// Window position and size for the UI layer.
    var window: WindowConfig?

    enum CodingKeys: String, CodingKey {
        case general
        case chatBehaviour = "chat_behaviour"
        case chatFeatures = "chat_features"
        case debug
        case window
    }
}

/// `[general]` group — default connection, role, and utility connection.
struct GeneralConfig: Codable, Equatable {
    /// Connection identifier (`"provider/name"`) used by default for new chats.
    var defaultConnection: String?
    /// Role name used by default for new chats. Falls back to "Assistant" when nil.
    var defaultRole: String?
    /// Connection identifier (`"provider/name"`) used for utility tasks (e.g. chat naming).
    var utilityConnection: String?

    enum CodingKeys: String, CodingKey {
        case defaultConnection = "default_connection"
        case defaultRole = "default_role"
        case utilityConnection = "utility_connection"
    }
}

/// `[chat_behaviour]` group — default expansion of thinking / tool use blocks.
struct ChatBehaviourConfig: Codable, Equatable {
    /// Whether Thinking blocks are expanded by default in the chat renderer.
    var expandThinking: Bool = false
    /// Whether Tool Use blocks are expanded by default in the chat renderer.
    var expandToolUse: Bool = false

    enum CodingKeys: String, CodingKey {
        case expandThinking = "expand_thinking"
        case expandToolUse = "expand_tool_use"
    }
}

/// `[chat_features]` group — rendering feature toggles.
struct ChatFeaturesConfig: Codable, Equatable {
    /// Whether Mermaid diagram rendering is enabled in the chat view.
    var mermaidEnabled: Bool = false
    /// Whether KaTeX math rendering is enabled in the chat view.
    var katexEnabled: Bool = false

    enum CodingKeys: String, CodingKey {
        case mermaidEnabled = "mermaid_enabled"
        case katexEnabled = "katex_enabled"
    }
}

/// `[debug]` group — debug-related toggles.
struct DebugConfig: Codable, Equatable {
    /// Whether the app-level debug logging (`debugLog`) is enabled.
    var appDebugEnabled: Bool = false
    /// Whether the chat renderer debug overlay is enabled.
    var chatRendererDebugEnabled: Bool = false

    enum CodingKeys: String, CodingKey {
        case appDebugEnabled = "app_debug_enabled"
        case chatRendererDebugEnabled = "chat_renderer_debug_enabled"
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
///
/// Startup ordering: [`bootstrapSynchronously()`](src/ConfigManager.swift) must be
/// called once at the very beginning of `applicationWillFinishLaunching`, before
/// any `Task` is spawned. It reads and decodes `config.toml` on the calling
/// thread and applies the debug-logging flag immediately, so that:
///  - early `debugLog` calls are captured, and
///  - the actor's [`load()`](src/ConfigManager.swift) consumes the already-decoded
///    config without re-reading the file, eliminating the launch-time race where
///    a mid-write read produced an empty config that was later persisted as
///    defaults (wiping user configuration).
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

    /// Hook called immediately before `persist()` writes `config.toml` to disk.
    /// Set by `ChatEngine` at startup so the engine can register the config
    /// file path in its per-path self-write suppression registry, preventing
    /// the resulting FSEvents burst from triggering a redundant reload.
    var willWriteConfig: (@Sendable () -> Void)?

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        fileURL = home.appendingPathComponent("iCanHazAI").appendingPathComponent("config.toml")
    }

    // MARK: - Synchronous bootstrap

    /// Lock-protected holder for the config decoded during the synchronous
    /// bootstrap. The actor's `load()` consumes it without re-reading the file.
    private final class BootstrapBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _config: AppConfig?
        func get() -> AppConfig? { lock.lock(); defer { lock.unlock() }; return _config }
        func set(_ value: AppConfig) { lock.lock(); defer { lock.unlock() }; _config = value }
    }
    private static let bootstrapBox = BootstrapBox()

    /// The config file URL, computed without touching actor isolation so the
    /// synchronous bootstrap can resolve it on the calling thread.
    private static var bootstrapFileURL: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return home.appendingPathComponent("iCanHazAI").appendingPathComponent("config.toml")
    }

    /// Reads and decodes `config.toml` synchronously on the calling thread and
    /// applies the debug-logging flag immediately. Must be called exactly once,
    /// at the very start of `applicationWillFinishLaunching`, **before** any
    /// `Task` is spawned or any other component touches `ConfigManager`.
    ///
    /// This guarantees that:
    ///  - `DebugLogger.enabled` reflects the user's preference from the first
    ///    log line onward, and
    ///  - the actor's `load()` can consume the already-decoded config without
    ///    re-reading the file, so no launch-time FSEvent/atomic-write race can
    ///    produce an empty config that would later be persisted as defaults.
    ///
    /// If the file is missing or undecodable, defaults are used (and stashed),
    /// which is the correct behavior for a first launch or a genuinely corrupt
    /// file — but the stash is never persisted by this call.
    nonisolated static func bootstrapSynchronously() {
        let url = bootstrapFileURL
        var decoded = AppConfig()
        if let data = try? Data(contentsOf: url) {
            if let parsed = try? ConfigValidation.decodeAppConfig(data) {
                decoded = parsed
            }
        }
        // Apply the debug-logging flag immediately so every subsequent
        // debugLog call (including those inside the actor's load()) is captured.
        DebugLogger.setEnabled(decoded.debug.appDebugEnabled)
        bootstrapBox.set(decoded)
    }

    /// Registers the self-write hook used to suppress FSEvents for our own
    /// writes to `config.toml`. Called once by `ChatEngine` at startup.
    func setWillWriteConfigHook(_ hook: @escaping @Sendable () -> Void) {
        willWriteConfig = hook
    }

    // MARK: - Load / Save

    /// Loads the config. If [`bootstrapSynchronously()`](src/ConfigManager.swift)
    /// has already run (the normal launch path), the config it decoded on the
    /// calling thread is consumed directly — the file is **not** re-read, which
    /// eliminates the launch-time race where a mid-atomic-write read produced
    /// an empty config that was later persisted as defaults.
    ///
    /// If no bootstrap stash is present (e.g. a CLI entry point that didn't call
    /// the bootstrap), this falls back to reading the file directly.
    ///
    /// After loading, validates that referenced connections and roles still
    /// exist; clears any that don't and writes the cleaned config back.
    ///
    /// Idempotent: subsequent calls after the first successful load are no-ops.
    /// This prevents duplicate "loading from …" log lines when multiple startup
    /// paths (window restore, preferences sync) both invoke `load()`.
    func load() {
        guard !didLoad else { return }
        if let stashed = ConfigManager.bootstrapBox.get() {
            debugLog("Config", "consuming synchronously-bootstrapped config (app_debug=\(stashed.debug.appDebugEnabled), chat_renderer_debug=\(stashed.debug.chatRendererDebugEnabled))")
            config = stashed
            didLoad = true
            validateAndSave()
            return
        }
        debugLog("Config", "loading from \(fileURL.path)")
        debugLog("FileRead", "reading config.toml")
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            debugLog("Config", "no config file found — using defaults")
            config = AppConfig()
            didLoad = true
            return
        }
        do {
            config = try ConfigValidation.decodeAppConfig(data)
            debugLog("Config", "loaded successfully (app_debug=\(config.debug.appDebugEnabled), chat_renderer_debug=\(config.debug.chatRendererDebugEnabled))")
        } catch {
            debugLog("Config", "failed to decode config: \(error) — using defaults")
            config = AppConfig()
            didLoad = true
            return
        }
        didLoad = true
        validateAndSave()
    }

    /// Re-reads `config.toml` from disk and updates in-memory state. Called
    /// when an FSEvent for `config.toml` arrives (external edit). Unlike
    /// `load()`, this is not idempotent — it always re-reads the file. After
    /// loading, validates references and persists if anything was cleaned up.
    func reload() {
        debugLog("Config", "reloading from disk (FSEvent)")
        debugLog("FileRead", "reading config.toml")
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            debugLog("Config", "no config file found on reload — keeping current state")
            return
        }
        do {
            config = try ConfigValidation.decodeAppConfig(data)
            debugLog("Config", "reloaded successfully (app_debug=\(config.debug.appDebugEnabled), chat_renderer_debug=\(config.debug.chatRendererDebugEnabled))")
        } catch {
            debugLog("Config", "failed to decode config on reload: \(error) — keeping current state")
            return
        }
        lastWritten = nil
        validateAndSave()
    }

    /// Persists the current config to disk with alphabetically sorted keys.
    /// Does nothing if the config hasn't changed since last write.
    private var lastWritten: AppConfig?
    private func persist() {
        guard config != lastWritten else { return }
        willWriteConfig?()
        debugLog("FileWrite", "writing config.toml")
        let encoder = TOMLEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(config) else { return }
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
            if let dc = config.general.defaultConnection, !connectionIDs.contains(dc) {
                config.general.defaultConnection = nil
                dirty = true
            }
            if let uc = config.general.utilityConnection, !connectionIDs.contains(uc) {
                config.general.utilityConnection = nil
                dirty = true
            }
        }

        let roles = EnvironmentManager.shared.loadAllRoles()
        let roleNames = Set(roles.map { $0.name })

        if let dr = config.general.defaultRole, !roleNames.contains(dr) {
            config.general.defaultRole = "Assistant"
            dirty = true
        }
        if config.general.defaultRole == nil {
            config.general.defaultRole = "Assistant"
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
        config.general.defaultConnection
    }

    func getDefaultRole() -> String? {
        config.general.defaultRole
    }

    func getUtilityConnection() -> String? {
        config.general.utilityConnection
    }

    func getWindow() -> WindowConfig? {
        config.window
    }

    func getMermaidEnabled() -> Bool {
        config.chatFeatures.mermaidEnabled
    }

    func getKatexEnabled() -> Bool {
        config.chatFeatures.katexEnabled
    }

    func getExpandThinking() -> Bool {
        config.chatBehaviour.expandThinking
    }

    func getExpandToolUse() -> Bool {
        config.chatBehaviour.expandToolUse
    }

    func getAppDebugEnabled() -> Bool {
        config.debug.appDebugEnabled
    }

    func getChatRendererDebugEnabled() -> Bool {
        config.debug.chatRendererDebugEnabled
    }

    func getChatListSidebarVisible() -> Bool? {
        config.window?.chatListSidebarVisible
    }

    func getChatInfoSidebarVisible() -> Bool? {
        config.window?.chatInfoSidebarVisible
    }

    func setDefaultConnection(_ id: String?) {
        config.general.defaultConnection = id
        persist()
    }

    func setDefaultRole(_ name: String?) {
        config.general.defaultRole = name
        persist()
    }

    func setUtilityConnection(_ id: String?) {
        config.general.utilityConnection = id
        persist()
    }

    func setMermaidEnabled(_ enabled: Bool) {
        config.chatFeatures.mermaidEnabled = enabled
        persist()
    }

    func setKatexEnabled(_ enabled: Bool) {
        config.chatFeatures.katexEnabled = enabled
        persist()
    }

    func setExpandThinking(_ enabled: Bool) {
        config.chatBehaviour.expandThinking = enabled
        persist()
    }

    func setExpandToolUse(_ enabled: Bool) {
        config.chatBehaviour.expandToolUse = enabled
        persist()
    }

    func setAppDebugEnabled(_ enabled: Bool) {
        config.debug.appDebugEnabled = enabled
        persist()
    }

    func setChatRendererDebugEnabled(_ enabled: Bool) {
        config.debug.chatRendererDebugEnabled = enabled
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
