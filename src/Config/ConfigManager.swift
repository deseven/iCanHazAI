// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import TOML

// MARK: - Config model (Codable, maps to TOML)

/// The app configuration persisted to `~/iCanHazAI/config.toml`.
/// Preferences are organized into TOML groups that mirror the preferences
/// UI tabs: `[general]`, `[chat]`, `[web_search]`, and `[debug]`, plus the
/// app-managed `[window]`.
/// All keys are sorted alphabetically on write via
/// `TOMLEncoder.outputFormatting = .sortedKeys`.
struct AppConfig: Codable, Equatable {
    /// General preferences: default role and working directories.
    var general: GeneralConfig = GeneralConfig()
    /// Chat preferences: tool use expansion, streaming animation and interface scale.
    var chat: ChatConfig = ChatConfig()
    /// Web search provider settings for the built-in `web` tool group.
    var webSearch: WebSearchConfig = WebSearchConfig()
    /// Chat list sidebar display mode and filter selection.
    var chatList: ChatListConfig = ChatListConfig()
    /// Debug preferences: app debug logging.
    var debug: DebugConfig = DebugConfig()
    /// Window position and size for the UI layer.
    var window: WindowConfig?
    /// The active API key of each provider: provider raw value → key id
    /// (`anthropic = "<uuid>"`). Managed by the app; the keys themselves live
    /// in the encrypted secret store. A raw-string dictionary so an unknown
    /// provider or malformed id (hand-edited config) degrades instead of failing
    /// the whole config decode.
    var providers: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case general
        case chat
        case webSearch = "web_search"
        case chatList = "chat_list"
        case debug
        case window
        case providers
    }

    /// Every group is optional: a missing table (or a totally empty file)
    /// falls back to the struct's own defaults instead of throwing
    /// `keyNotFound`. This keeps partial configs loadable — every
    /// field in every sub-struct is itself optional, so once a table is
    /// present its keys are all tolerated too.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
        chat = try c.decodeIfPresent(ChatConfig.self, forKey: .chat) ?? ChatConfig()
        webSearch = try c.decodeIfPresent(WebSearchConfig.self, forKey: .webSearch) ?? WebSearchConfig()
        chatList = try c.decodeIfPresent(ChatListConfig.self, forKey: .chatList) ?? ChatListConfig()
        debug = try c.decodeIfPresent(DebugConfig.self, forKey: .debug) ?? DebugConfig()
        window = try c.decodeIfPresent(WindowConfig.self, forKey: .window)
        providers = try c.decodeIfPresent([String: String].self, forKey: .providers) ?? [:]
    }

    init() {}
}

/// `[general]` group — default role, default/utility models and working directories.
struct GeneralConfig: Codable, Equatable {
    /// Role name used by default for new chats. Falls back to "Assistant" when nil.
    var defaultRole: String?

    /// `provider:model-id` preselected for every new chat (unless the chat's
    /// role sets `preferred_model`). Nil → "No model".
    var defaultModel: String?

    /// `provider:model-id` used for background utility tasks such as chat
    /// naming. Nil → "No model" (utility tasks are skipped).
    var utilityModel: String?

    /// User-managed list of working directories offered in the per-chat
    /// directory picker. Nil/missing in older configs → treated as empty.
    /// The selected directory is saved to the chat data (alongside role and
    /// title), not here.
    var workingDirectories: [String]?

    enum CodingKeys: String, CodingKey {
        case defaultRole = "default_role"
        case defaultModel = "default_model"
        case utilityModel = "utility_model"
        case workingDirectories = "working_directories"
    }
}

/// `[chat]` group — how chats are shown: tool use expansion, streaming animation and interface scale.
struct ChatConfig: Codable, Equatable {
    /// Whether Tool Use blocks are expanded by default in the chat renderer.
    /// Nil/missing → false.
    var expandToolUse: Bool?
    /// Whether a streaming reply fades its new text in and glides the list down.
    /// Nil/missing → true.
    var smoothStreaming: Bool?
    /// Chat renderer interface scale, as a percentage. Nil/missing → 100.
    var interfaceScale: Double?

    static let interfaceScaleRange: ClosedRange<Double> = 70...200
    static let defaultInterfaceScale: Double = 100

    static func normalizedInterfaceScale(_ scale: Double?) -> Double {
        min(max(scale ?? defaultInterfaceScale, interfaceScaleRange.lowerBound), interfaceScaleRange.upperBound)
    }

    enum CodingKeys: String, CodingKey {
        case expandToolUse = "expand_tool_use"
        case smoothStreaming = "smooth_streaming"
        case interfaceScale = "interface_scale"
    }
}

/// The web search backends supported by the built-in `web` tool group.
enum WebSearchProviderKind: String, CaseIterable, Sendable {
    case none
    case exa
    case linkup
    case tavily
}

/// `[web_search]` group — provider selection and credentials for the built-in
/// `web` tool group's `web_search` / `web_extract` tools. `provider` is stored
/// as a raw string so an unknown value (hand-edited config) degrades to
/// `none` instead of failing the whole config decode.
struct WebSearchConfig: Codable, Equatable, Sendable {
    /// One of "none" (default), "exa", "linkup", "tavily".
    var provider: String?
    /// API token for the selected provider. Never part of `config.toml`: it
    /// lives in the encrypted secret store and is filled in by `ConfigManager`.
    var token: String?
    /// Linkup-only: pass `renderJs` to the fetch endpoint.
    var linkupRenderJS: Bool?
    /// Tavily-only: use `advanced` extract depth instead of `basic`.
    var tavilyAdvancedExtraction: Bool?

    var resolvedProvider: WebSearchProviderKind {
        WebSearchProviderKind(rawValue: provider ?? "none") ?? .none
    }

    /// True when `web_search` / `web_extract` can run: a provider is selected
    /// and a token is set.
    var isConfigured: Bool {
        resolvedProvider != .none && !(token ?? "").isEmpty
    }

    /// The config after a successful setup: `provider` selected and the
    /// options that belong to other providers dropped.
    func settingUp(_ provider: WebSearchProviderKind) -> WebSearchConfig {
        var copy = self
        copy.provider = provider.rawValue
        if provider != .linkup { copy.linkupRenderJS = nil }
        if provider != .tavily { copy.tavilyAdvancedExtraction = nil }
        return copy
    }

    /// How a token is shown once stored: its first and last 4 characters, or
    /// bullets when it's too short for that to hide most of it.
    static func maskedToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return String(repeating: "•", count: 8) }
        return "\(trimmed.prefix(4))…\(trimmed.suffix(4))"
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case linkupRenderJS = "linkup_render_js"
        case tavilyAdvancedExtraction = "tavily_advanced_extraction"
    }

    /// Provider-specific keys are only persisted while their provider is
    /// selected — `linkup_render_js` is never saved under another provider,
    /// and likewise for `tavily_advanced_extraction`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let provider = resolvedProvider
        try c.encodeIfPresent(self.provider, forKey: .provider)
        if provider == .linkup {
            try c.encodeIfPresent(linkupRenderJS, forKey: .linkupRenderJS)
        }
        if provider == .tavily {
            try c.encodeIfPresent(tavilyAdvancedExtraction, forKey: .tavilyAdvancedExtraction)
        }
    }
}

/// `[chat_list]` group — sidebar display mode and filter selection.
/// The mode determines how chats are grouped/filtered in the sidebar:
/// "all" (plain list), "role" (filter by role), or "directory" (filter by
/// working directory). The `role` and `directory` keys persist the last
/// selection even when the mode isn't active, so switching back restores it.
struct ChatListConfig: Codable, Equatable {
    /// Display mode: "all", "role", or "directory". Nil/missing → "all".
    var mode: String?
    /// Role name for "role" mode. Nil → default role.
    var role: String?
    /// Directory path for "directory" mode. Nil → "~" (user home).
    var directory: String?
}

/// `[debug]` group — debug-related toggles.
struct DebugConfig: Codable, Equatable {
    /// Whether the app-level debug logging (`debugLog`) is enabled.
    /// Nil/missing → false.
    var appDebugEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case appDebugEnabled = "app_debug_enabled"
    }
}

struct WindowConfig: Codable, Equatable {
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    /// Whether the right sidebar (chat info) was visible when the window was last closed.
    var chatInfoSidebarVisible: Bool?
    /// Width of the left sidebar (chat list) when the window was last closed.
    var chatListSidebarWidth: Double?
    /// Width of the right sidebar (chat info) when the window was last closed.
    var chatInfoSidebarWidth: Double?

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
        case chatInfoSidebarVisible = "chat_info_sidebar_visible"
        case chatListSidebarWidth = "chat_list_sidebar_width"
        case chatInfoSidebarWidth = "chat_info_sidebar_width"
    }
}

// MARK: - Config manager

/// UI-free singleton actor that owns the app config file at `~/iCanHazAI/config.toml`.
/// Every modification triggers an immediate TOML write so the file is always in a
/// correct state. Validation of the default role reference happens on load and
/// can be re-triggered by callers (e.g. after entities are reloaded).
///
/// Startup ordering: [`bootstrapSynchronously()`](src/Config/ConfigManager.swift) must be
/// called once at the very beginning of `applicationWillFinishLaunching`, before
/// any `Task` is spawned. It reads and decodes `config.toml` on the calling
/// thread and applies the debug-logging flag immediately, so that:
///  - early `debugLog` calls are captured, and
///  - the actor's [`load()`](src/Config/ConfigManager.swift) consumes the already-decoded
///    config without re-reading the file, eliminating the launch-time race where
///    a mid-write read produced an empty config that was later persisted as
///    defaults (wiping user configuration).
actor ConfigManager {

    static let shared = ConfigManager()

    /// The current in-memory config. Always reflects what's on disk.
    private(set) var config = AppConfig()

    /// Whether `load()` has completed at least once. Validation/persistence is
    /// suppressed until the config has been read from disk, otherwise a
    /// `validateReferences()` that fires *before* the initial load would reset
    /// `default_role` (which is still nil in the default `AppConfig()` and
    /// would be persisted as such).
    private var didLoad = false

    private let fileURL: URL

    private static let webSearchTokenName = "web_search.token"
    private let secrets: SecretStore = EncryptedSecretStore.shared
    private var webSearchToken: String?
    private var webSearchTokenLoaded = false

    private init() {
        fileURL = EnvironmentManager.shared.rootURL.appendingPathComponent("config.toml")
    }

    // MARK: - Synchronous bootstrap

    /// Lock-protected holder for the config decoded during the synchronous
    /// bootstrap. The actor's `load()` consumes it without re-reading the file.
    /// Also carries whether the on-disk file failed to decode, so `load()` can
    /// overwrite the broken file with the fresh defaults.
    private final class BootstrapBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _payload: (config: AppConfig, decodeFailed: Bool)?
        func get() -> (config: AppConfig, decodeFailed: Bool)? {
            lock.lock()
            defer { lock.unlock() }
            return _payload
        }
        func set(_ config: AppConfig, decodeFailed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            _payload = (config, decodeFailed)
        }
    }
    private static let bootstrapBox = BootstrapBox()

    /// The config file URL, computed without touching actor isolation so the
    /// synchronous bootstrap can resolve it on the calling thread.
    private static var bootstrapFileURL: URL {
        return EnvironmentManager.shared.rootURL.appendingPathComponent("config.toml")
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
    ///    re-reading the file, so no launch-time read can produce an empty
    ///    config that would later be persisted as defaults.
    ///
    /// If the file is missing, defaults are used (a normal first launch — no
    /// overwrite). If the file exists but fails to decode, defaults are used
    /// and the failure is stashed so `load()` overwrites the broken file with a
    /// fresh default config (logging the action).
    nonisolated static func bootstrapSynchronously() {
        let url = bootstrapFileURL
        var decoded = AppConfig()
        var decodeFailed = false
        if let data = try? Data(contentsOf: url) {
            if let parsed = try? ConfigValidation.decodeAppConfig(data) {
                decoded = parsed
            } else {
                decodeFailed = true
            }
        }
        // Apply the debug-logging flag immediately so every subsequent
        // debugLog call (including those inside the actor's load()) is captured.
        DebugLogger.setEnabled(decoded.debug.appDebugEnabled ?? false)
        if decodeFailed {
            debugLog(
                "Config",
                "⚠️ failed to decode app config on startup — using defaults; the broken file will be overwritten")
        }
        bootstrapBox.set(decoded, decodeFailed: decodeFailed)
    }

    // MARK: - Load / Save

    /// Loads the config. If [`bootstrapSynchronously()`](src/Config/ConfigManager.swift)
    /// has already run (the normal launch path), the config it decoded on the
    /// calling thread is consumed directly — the file is **not** re-read, which
    /// eliminates the launch-time race where a mid-atomic-write read produced
    /// an empty config that was later persisted as defaults.
    ///
    /// If no bootstrap stash is present (e.g. a CLI entry point that didn't call
    /// the bootstrap), this falls back to reading the file directly.
    ///
    /// After loading, validates that the default role still exists; resets it
    /// if not and writes the cleaned config back.
    ///
    /// Idempotent: subsequent calls after the first successful load are no-ops.
    /// This prevents duplicate "loading from …" log lines when multiple startup
    /// paths (window restore, preferences sync) both invoke `load()`.
    func load() {
        guard !didLoad else { return }
        if let stashed = ConfigManager.bootstrapBox.get() {
            debugLog(
                "Config",
                "consuming synchronously-bootstrapped config (app_debug=\(stashed.config.debug.appDebugEnabled ?? false))"
            )
            config = stashed.config
            didLoad = true
            if stashed.decodeFailed {
                // The on-disk config was undecodable at startup — overwrite it
                // with the fresh defaults we fell back to so the file is usable
                // again (and the next launch doesn't hit the same failure).
                debugLog("Config", "⚠️ overwriting unreadable app config with defaults")
                lastWritten = nil
                persist()
            }
            validateAndSave()
            return
        }
        debugLog("Config", "loading from \(fileURL.path)")
        debugLog("FileRead", "reading config.toml")
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL)
        else {
            debugLog("Config", "no config file found — using defaults")
            config = AppConfig()
            didLoad = true
            return
        }
        do {
            config = try ConfigValidation.decodeAppConfig(data)
            debugLog(
                "Config",
                "loaded successfully (app_debug=\(config.debug.appDebugEnabled ?? false))"
            )
        } catch {
            debugLog("Config", "⚠️ failed to decode config: \(error) — using defaults and overwriting the file")
            config = AppConfig()
            didLoad = true
            lastWritten = nil
            persist()
            return
        }
        didLoad = true
        validateAndSave()
    }

    /// Re-reads `config.toml` from disk and updates in-memory state. Called
    /// after `config.toml` was written by something other than this actor
    /// (e.g. the Configurator tools). Unlike `load()`, this is not idempotent —
    /// it always re-reads the file. After loading, validates references and
    /// persists if anything was cleaned up.
    func reload() {
        debugLog("Config", "reloading from disk")
        debugLog("FileRead", "reading config.toml")
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL)
        else {
            // The config file was removed or can't be read while the app is
            // running. Restore the current live configuration
            // to disk so the app keeps a working config file.
            debugLog("Config", "⚠️ config file missing on reload — restoring current live config to disk")
            lastWritten = nil
            persist()
            return
        }
        do {
            config = try ConfigValidation.decodeAppConfig(data)
            debugLog(
                "Config",
                "reloaded successfully (app_debug=\(config.debug.appDebugEnabled ?? false))"
            )
        } catch {
            // The file is undecodable. Keep the in-memory `config` (the live
            // state) and persist it back so the broken file is replaced with a
            // working one.
            debugLog("Config", "⚠️ failed to decode config on reload: \(error) — restoring current live config to disk")
            lastWritten = nil
            persist()
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

    /// Checks that `default_role` still refers to an existing role. Resets an
    /// invalid reference and persists. Returns whether anything was changed.
    @discardableResult
    private func validateAndSave() -> Bool {
        // Suppress validation until the config has been loaded from disk at
        // least once. Otherwise a `validateReferences()` that races ahead of
        // the initial `load()` would validate against the default (empty)
        // `AppConfig()` and persist a wiped config file.
        guard didLoad else { return false }

        var dirty = false

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
        return dirty
    }

    /// Re-validates the default role reference (call after roles were reloaded). If something was cleared, the config is persisted
    /// automatically and `true` is returned so callers can refresh their view
    /// of it.
    @discardableResult
    func validateReferences() -> Bool {
        validateAndSave()
    }

    // MARK: - Getters / Setters

    func getDefaultRole() -> String? {
        config.general.defaultRole
    }

    func getDefaultModel() -> String? {
        config.general.defaultModel
    }

    func getUtilityModel() -> String? {
        config.general.utilityModel
    }

    func getWorkingDirectories() -> [String] {
        config.general.workingDirectories ?? []
    }

    func setWorkingDirectories(_ dirs: [String]) {
        config.general.workingDirectories = dirs
        persist()
    }

    func getWindow() -> WindowConfig? {
        config.window
    }

    func getInterfaceScale() -> Double {
        ChatConfig.normalizedInterfaceScale(config.chat.interfaceScale)
    }

    func getExpandToolUse() -> Bool {
        config.chat.expandToolUse ?? false
    }

    func getSmoothStreaming() -> Bool {
        config.chat.smoothStreaming ?? true
    }

    func getAppDebugEnabled() -> Bool {
        config.debug.appDebugEnabled ?? false
    }

    func getWebSearchConfig() -> WebSearchConfig {
        if !webSearchTokenLoaded {
            webSearchTokenLoaded = true
            do {
                webSearchToken = try secrets.namedSecret(Self.webSearchTokenName)
            } catch SecretStoreError.undecryptable {
                // Same policy as provider keys: an unreadable secret is dropped.
                debugLog("Config", "⚠️ discarding undecryptable web search token")
                try? secrets.setNamedSecret(Self.webSearchTokenName, to: nil)
            } catch {
                debugLog("Config", "⚠️ failed to read web search token: \(error.localizedDescription)")
            }
        }
        var webSearch = config.webSearch
        webSearch.token = webSearchToken
        return webSearch
    }

    func getChatInfoSidebarVisible() -> Bool? {
        config.window?.chatInfoSidebarVisible
    }

    func getChatListSidebarWidth() -> Double? {
        config.window?.chatListSidebarWidth
    }

    func getChatInfoSidebarWidth() -> Double? {
        config.window?.chatInfoSidebarWidth
    }

    func getChatListConfig() -> ChatListConfig {
        config.chatList
    }

    /// The persisted active key per provider. Entries for unknown providers or
    /// with an unparsable id are ignored.
    func getProviderKeys() -> [Provider: UUID] {
        var result: [Provider: UUID] = [:]
        for (name, id) in config.providers {
            if let provider = Provider(rawValue: name), let uuid = UUID(uuidString: id) { result[provider] = uuid }
        }
        return result
    }

    /// Replaces the whole `[providers]` table, which also drops stale entries.
    func setProviderKeys(_ keys: [Provider: UUID]) {
        config.providers = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value.uuidString) })
        persist()
    }

    func setChatListConfig(_ value: ChatListConfig) {
        config.chatList = value
        persist()
    }

    func setDefaultRole(_ name: String?) {
        config.general.defaultRole = name
        persist()
    }

    func setDefaultModel(_ model: String?) {
        config.general.defaultModel = model
        persist()
    }

    func setUtilityModel(_ model: String?) {
        config.general.utilityModel = model
        persist()
    }

    func setInterfaceScale(_ scale: Double) {
        config.chat.interfaceScale = ChatConfig.normalizedInterfaceScale(scale)
        persist()
    }

    func setExpandToolUse(_ enabled: Bool) {
        config.chat.expandToolUse = enabled
        persist()
    }

    func setSmoothStreaming(_ enabled: Bool) {
        config.chat.smoothStreaming = enabled
        persist()
    }

    func setAppDebugEnabled(_ enabled: Bool) {
        config.debug.appDebugEnabled = enabled
        persist()
    }

    /// Stores a checked token and selects its provider. The token goes first,
    /// so a failed store never leaves a provider selected without one.
    func setUpWebSearch(provider: WebSearchProviderKind, token: String) throws {
        try secrets.setNamedSecret(Self.webSearchTokenName, to: token)
        webSearchToken = token
        webSearchTokenLoaded = true
        config.webSearch = config.webSearch.settingUp(provider)
        persist()
    }

    /// Disconnects web search: drops the token, the provider selection and
    /// every provider option, leaving `[web_search]` as on a fresh install.
    /// Throws without changing anything when the token can't be removed.
    func resetWebSearch() throws {
        try secrets.setNamedSecret(Self.webSearchTokenName, to: nil)
        webSearchToken = nil
        webSearchTokenLoaded = true
        config.webSearch = WebSearchConfig()
        persist()
    }

    func setLinkupRenderJS(_ enabled: Bool) {
        config.webSearch.linkupRenderJS = enabled
        persist()
    }

    func setTavilyAdvancedExtraction(_ enabled: Bool) {
        config.webSearch.tavilyAdvancedExtraction = enabled
        persist()
    }

    func setWindow(_ window: WindowConfig?) {
        // Merge: preserve existing sidebar visibility if the incoming config
        // doesn't specify it (e.g. when the window frame tracker saves position).
        if var w = window {
            if w.chatInfoSidebarVisible == nil { w.chatInfoSidebarVisible = config.window?.chatInfoSidebarVisible }
            if w.chatListSidebarWidth == nil { w.chatListSidebarWidth = config.window?.chatListSidebarWidth }
            if w.chatInfoSidebarWidth == nil { w.chatInfoSidebarWidth = config.window?.chatInfoSidebarWidth }
            config.window = w
        } else {
            config.window = nil
        }
        persist()
    }

    /// Persists the sidebar UI state (info sidebar visibility + both sidebar
    /// widths) in one write.
    func setSidebarState(chatInfoVisible: Bool, chatListWidth: Double, chatInfoWidth: Double) {
        if config.window == nil { config.window = WindowConfig() }
        config.window?.chatInfoSidebarVisible = chatInfoVisible
        config.window?.chatListSidebarWidth = chatListWidth
        config.window?.chatInfoSidebarWidth = chatInfoWidth
        persist()
    }
}
