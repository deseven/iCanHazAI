// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import TOML

/// Manages the app's data directory
/// and provides loading/saving of chats, roles, and connections.
/// Pure file I/O with no UI dependency, so it is not main-actor isolated.
final class EnvironmentManager: @unchecked Sendable {

    static let shared = EnvironmentManager()

    let rootURL: URL
    let chatsURL: URL
    let rolesURL: URL
    let promptsURL: URL
    let connectionsURL: URL
    let openaiConnectionsURL: URL
    let anthropicConnectionsURL: URL
    let mcpsURL: URL

    /// Internal initializer taking an explicit root URL, so tests can point
    /// the environment at a throwaway temp directory instead of `~/iCanHazAI`.
    /// The production singleton (`shared`) uses the home-directory root.
    init(rootURL: URL) {
        self.rootURL = rootURL
        chatsURL = rootURL.appendingPathComponent("Chats", isDirectory: true)
        rolesURL = rootURL.appendingPathComponent("Roles", isDirectory: true)
        promptsURL = rootURL.appendingPathComponent("Prompts", isDirectory: true)
        connectionsURL = rootURL.appendingPathComponent("Connections", isDirectory: true)
        openaiConnectionsURL = connectionsURL.appendingPathComponent("openai", isDirectory: true)
        anthropicConnectionsURL = connectionsURL.appendingPathComponent("anthropic", isDirectory: true)
        mcpsURL = rootURL.appendingPathComponent("MCPs", isDirectory: true)
    }

    private convenience init() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.init(rootURL: homeURL.appendingPathComponent("iCanHazAI", isDirectory: true))
    }

    // MARK: - Setup

    /// Ensures the data directory structure exists, creating it if needed.
    func ensureDirectories() {
        let fm = FileManager.default
        for url in [rootURL, chatsURL, rolesURL, promptsURL, connectionsURL, openaiConnectionsURL, anthropicConnectionsURL, mcpsURL] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Protected built-ins

    /// Names of built-in roles/prompts that are always served from the app
    /// bundle and never copied into or read from the user directory. A user
    /// file with the same name is ignored in favor of the bundled version, so
    /// these built-ins can always be relied upon (e.g. the onboarding
    /// configurator role and its prompt).
    static let protectedBundleNames: Set<String> = ["Configurator"]

    /// Loads a protected built-in role TOML from the app bundle by name.
    /// Returns nil if the bundle's roles resource directory (`Default/roles`)
    /// can't be located or the file is missing/undecodable.
    nonisolated static func bundledRole(name: String) -> Role? {
        guard let dir = defaultResourceDir("roles") else { return nil }
        let url = dir.appendingPathComponent("\(name).toml")
        debugLog("FileRead", "reading bundled \(url.path)")
        guard let data = try? Data(contentsOf: url) else {
            debugLog("Env", "⚠️ failed to read bundled role \"\(name)\"")
            return nil
        }
        do {
            let config = try ConfigValidation.decodeRole(data)
            return Role(name: name, config: config)
        } catch {
            debugLog("Env", "⚠️ failed to decode bundled role \"\(name)\" — \(error)")
            return nil
        }
    }

    /// Loads a protected built-in prompt from the app bundle by name.
    /// Returns nil if the bundle's prompts resource directory
    /// (`Default/prompts`) can't be located or the file is missing.
    nonisolated static func bundledPrompt(name: String) -> Prompt? {
        guard let dir = defaultResourceDir("prompts") else { return nil }
        let url = dir.appendingPathComponent("\(name).md")
        debugLog("FileRead", "reading bundled \(url.path)")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Prompt(name: name, content: content)
    }

    // MARK: - Default seeding

    /// Locates a bundled default resource directory for `<sub>` (e.g. "roles",
    /// "prompts"). Checks the app bundle's `Contents/Resources/Default/<sub>`
    /// first (the production layout), then the flat `Contents/Resources/<sub>`
    /// (legacy), then walks up from the main bundle (or CWD) to find a
    /// `default/<sub>` directory (for `swift run` / `swift test`). Returns nil
    /// if none exists.
    nonisolated static func defaultResourceDir(_ sub: String) -> URL? {
        let fm = FileManager.default
        if let url = Bundle.main.url(forResource: sub, withExtension: nil, subdirectory: "Default") {
            return url
        }
        if let url = Bundle.main.url(forResource: sub, withExtension: nil) {
            return url
        }
        // Walk up from the bundle's parent dir and the current working dir
        // (the latter covers `swift run` / `swift test`, where CWD is the
        // package root) until a `default/<sub>` directory is found.
        let starts = [
            Bundle.main.bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: fm.currentDirectoryPath)
        ]
        for start in starts {
            var url = start
            while url.path != "/" {
                let candidate = url.appendingPathComponent("default").appendingPathComponent(sub)
                if fm.fileExists(atPath: candidate.path) { return candidate }
                url = url.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// On every startup, copies any missing files from the bundled
    /// `default/prompts` into `~/iCanHazAI/Prompts` and from `default/roles`
    /// into `~/iCanHazAI/Roles`. Existing files are never overwritten, so user
    /// edits to seeded defaults are preserved.
    func seedDefaults() {
        seedFromBundle(sub: "prompts", dest: promptsURL, ext: "md")
        seedFromBundle(sub: "roles", dest: rolesURL, ext: "toml")
    }

    private func seedFromBundle(sub: String, dest: URL, ext: String) {
        guard let src = Self.defaultResourceDir(sub) else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for file in files where file.pathExtension == ext {
            let name = file.deletingPathExtension().lastPathComponent
            // Protected built-ins are never copied into the user directory;
            // they stay in the bundle and are loaded on demand.
            if Self.protectedBundleNames.contains(name) { continue }
            let target = dest.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: file, to: target)
                debugLog("Env", "seeded default \(relativePath(target))")
            }
        }
    }

    // MARK: - Chat images

    /// Returns the directory holding image files for the given chat filename.
    /// The directory is created on demand.
    func imagesDirectory(for chatFilename: String) -> URL {
        let name = (chatFilename as NSString).deletingPathExtension
        let dir = chatsURL.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves processed image data for a chat, returning the on-disk URL.
    func saveImage(data: Data, filename: String, chatFilename: String) -> URL {
        let dir = imagesDirectory(for: chatFilename)
        let url = dir.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Loads the raw bytes of an image attachment for a chat.
    func loadImageData(_ attachment: ImageAttachment, chatFilename: String) -> Data? {
        let dir = imagesDirectory(for: chatFilename)
        let url = dir.appendingPathComponent(attachment.filename)
        return try? Data(contentsOf: url)
    }

    /// Deletes a single image file for a chat.
    func deleteImage(_ attachment: ImageAttachment, chatFilename: String) {
        let dir = imagesDirectory(for: chatFilename)
        let url = dir.appendingPathComponent(attachment.filename)
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes the entire image folder for a chat (used when a chat is deleted).
    func deleteAllImages(for chatFilename: String) {
        let name = (chatFilename as NSString).deletingPathExtension
        let dir = chatsURL.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Chats

    /// Loads all chats from the chats directory, sorted by filename (which encodes creation time).
    func loadChats() -> [(filename: String, chat: Chat)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: chatsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [(filename: String, chat: Chat)] = []
        for file in files where file.pathExtension == "json" {
            debugLog("FileRead", "reading \(relativePath(file))")
            do {
                let data = try Data(contentsOf: file)
                let chat = try JSONDecoder().decode(Chat.self, from: data)
                result.append((filename: file.lastPathComponent, chat: chat))
            } catch {
                debugLog("ChatDecode", "⚠️ failed to decode chat \(file.lastPathComponent): \(error)")
                continue
            }
        }
        result.sort { $0.filename < $1.filename }
        return result
    }

    /// Loads and decodes a single chat file by filename. Returns nil if the
    /// file is missing or undecodable. Used by the FSEvents per-file router so
    /// only the changed file is reloaded instead of scanning the whole directory.
    func loadSingleChat(filename: String) -> Chat? {
        let url = chatsURL.appendingPathComponent(filename)
        debugLog("FileRead", "reading \(relativePath(url))")
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Chat.self, from: data)
        } catch {
            debugLog("ChatDecode", "⚠️ failed to decode chat \(filename): \(error)")
            return nil
        }
    }

    /// Generates a new chat filename using the current date/time.
    func newChatFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date()) + ".json"
    }

    /// Saves a chat to disk under the given filename.
    func saveChat(_ chat: Chat, filename: String) {
        let url = chatsURL.appendingPathComponent(filename)
        debugLog("FileWrite", "writing \(relativePath(url))")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(chat) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes a chat file.
    func deleteChat(filename: String) {
        let url = chatsURL.appendingPathComponent(filename)
        debugLog("FileWrite", "deleting \(relativePath(url))")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Prompts

    /// Loads all prompt files from the prompts directory, sorted by name.
    /// Protected built-in prompts are always appended from the app bundle; a
    /// user file that shadows a protected name is ignored in favor of the
    /// bundled version.
    func loadAllPrompts() -> [Prompt] {
        loadAllPromptsReportingErrors().loaded
    }

    /// Same as [`loadAllPrompts()`](src/Environment/EnvironmentManager.swift) but also returns
    /// a [`ConfigError`](src/Chat/Models.swift) per prompt file that could not be read
    /// or contains unknown variables. Used by `ChatEngine` to populate the
    /// configuration-error registry. Protected built-in prompts are trusted app
    /// content and are never validated here.
    func loadAllPromptsReportingErrors() -> (loaded: [Prompt], errors: [ConfigError]) {
        let fm = FileManager.default
        var loaded: [Prompt] = []
        var errors: [ConfigError] = []
        if let files = try? fm.contentsOfDirectory(at: promptsURL, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "md" {
                let name = url.deletingPathExtension().lastPathComponent
                if Self.protectedBundleNames.contains(name) { continue }
                debugLog("FileRead", "reading \(relativePath(url))")
                guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                    debugLog("Env", "⚠️ failed to read prompt \"\(name)\"")
                    errors.append(ConfigError(kind: .prompt, entityName: name, message: "prompt file could not be read"))
                    continue
                }
                let unknown = PromptVariables.unknownVariables(in: content)
                if !unknown.isEmpty {
                    let message = PromptVariables.unknownVariablesMessage(unknown)
                    debugLog("Env", "⚠️ prompt \"\(name)\" has \(message)")
                    errors.append(ConfigError(kind: .prompt, entityName: name, message: message))
                    continue
                }
                loaded.append(Prompt(name: name, content: content))
            }
        }
        for name in Self.protectedBundleNames {
            if let prompt = Self.bundledPrompt(name: name) {
                loaded.append(prompt)
            }
        }
        return (loaded.sorted { $0.name < $1.name }, errors)
    }

    /// Loads one prompt by name. Returns nil if not found. Protected built-in
    /// names are always resolved from the app bundle.
    func loadSinglePrompt(name: String) -> Prompt? {
        loadSinglePromptReportingError(name: name).prompt
    }

    /// Same as [`loadSinglePrompt(name:)`](src/Environment/EnvironmentManager.swift) but also
    /// returns a [`ConfigError`](src/Chat/Models.swift) when the file exists but
    /// contains unknown variables. A missing file returns `(nil, nil)` — the
    /// caller treats that as a removal (no error). Protected built-ins never
    /// error.
    func loadSinglePromptReportingError(name: String) -> (prompt: Prompt?, error: ConfigError?) {
        if Self.protectedBundleNames.contains(name) {
            return (Self.bundledPrompt(name: name), nil)
        }
        let url = promptsURL.appendingPathComponent("\(name).md")
        debugLog("FileRead", "reading \(relativePath(url))")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            debugLog("Env", "⚠️ failed to read prompt \"\(name)\"")
            return (nil, nil)
        }
        let unknown = PromptVariables.unknownVariables(in: content)
        if !unknown.isEmpty {
            let message = PromptVariables.unknownVariablesMessage(unknown)
            debugLog("Env", "⚠️ prompt \"\(name)\" has \(message)")
            return (nil, ConfigError(kind: .prompt, entityName: name, message: message))
        }
        return (Prompt(name: name, content: content), nil)
    }

    // MARK: - Roles

    /// Loads all role TOML files from the roles directory, sorted by name.
    /// Protected built-in roles are always appended from the app bundle; a user
    /// file that shadows a protected name is ignored in favor of the bundled
    /// version.
    func loadAllRoles() -> [Role] {
        loadAllRolesReportingErrors().loaded
    }

    /// Same as [`loadAllRoles()`](src/Environment/EnvironmentManager.swift) but also returns
    /// a [`ConfigError`](src/Chat/Models.swift) per role file that failed to read or
    /// decode. Used by `ChatEngine` to populate the configuration-error registry.
    func loadAllRolesReportingErrors() -> (loaded: [Role], errors: [ConfigError]) {
        let fm = FileManager.default
        var loaded: [Role] = []
        var errors: [ConfigError] = []
        if let files = try? fm.contentsOfDirectory(at: rolesURL, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "toml" {
                let name = url.deletingPathExtension().lastPathComponent
                if Self.protectedBundleNames.contains(name) { continue }
                debugLog("FileRead", "reading \(relativePath(url))")
                guard let data = try? Data(contentsOf: url) else {
                    debugLog("Env", "⚠️ failed to read role \"\(name)\"")
                    errors.append(ConfigError(kind: .role, entityName: name, message: "role file could not be read"))
                    continue
                }
                do {
                    let config = try ConfigValidation.decodeRole(data)
                    loaded.append(Role(name: name, config: config))
                } catch {
                    debugLog("Env", "⚠️ failed to decode role \"\(name)\" — \(error)")
                    errors.append(ConfigError(kind: .role, entityName: name, message: error.localizedDescription))
                }
            }
        }
        for name in Self.protectedBundleNames {
            if let role = Self.bundledRole(name: name) {
                loaded.append(role)
            }
        }
        return (loaded.sorted { $0.name < $1.name }, errors)
    }

    /// Loads one role by name. Returns nil if not found or undecodable.
    /// Protected built-in names are always resolved from the app bundle.
    func loadSingleRole(name: String) -> Role? {
        loadSingleRoleReportingError(name: name).role
    }

    /// Same as [`loadSingleRole(name:)`](src/Environment/EnvironmentManager.swift) but also
    /// returns a [`ConfigError`](src/Chat/Models.swift) when the file exists but
    /// fails to decode. A missing file returns `(nil, nil)` — the caller treats
    /// that as a removal (no error). Protected built-ins never error.
    func loadSingleRoleReportingError(name: String) -> (role: Role?, error: ConfigError?) {
        if Self.protectedBundleNames.contains(name) {
            return (Self.bundledRole(name: name), nil)
        }
        let url = rolesURL.appendingPathComponent("\(name).toml")
        debugLog("FileRead", "reading \(relativePath(url))")
        guard let data = try? Data(contentsOf: url) else {
            debugLog("Env", "⚠️ failed to read role \"\(name)\"")
            return (nil, nil)
        }
        do {
            let config = try ConfigValidation.decodeRole(data)
            return (Role(name: name, config: config), nil)
        } catch {
            debugLog("Env", "⚠️ failed to decode role \"\(name)\" — \(error)")
            return (nil, ConfigError(kind: .role, entityName: name, message: error.localizedDescription))
        }
    }

    // MARK: - Resource counts (for the startup loader)

    /// Number of chat files on disk (the total the loader shows against the
    /// cached/decoded count produced by `ChatStore.startupSync`).
    func chatCount() -> Int { countFiles(in: chatsURL, ext: "json") }

    /// Number of connection files across both provider directories.
    func connectionCount() -> Int {
        countFiles(in: openaiConnectionsURL, ext: "jsonc") + countFiles(in: anthropicConnectionsURL, ext: "jsonc")
    }

    /// Number of prompt files in the user directory (excluding protected
    /// built-ins) plus the protected built-in prompts served from the bundle.
    func promptCount() -> Int {
        countFiles(in: promptsURL, ext: "md", excludingProtected: true) + Self.protectedBundleNames.count
    }

    /// Number of role files in the user directory (excluding protected
    /// built-ins) plus the protected built-in roles served from the bundle.
    func roleCount() -> Int {
        countFiles(in: rolesURL, ext: "toml", excludingProtected: true) + Self.protectedBundleNames.count
    }

    /// Number of custom MCP config files in the MCPs directory.
    func mcpCount() -> Int {
        countFiles(in: mcpsURL, ext: "toml")
    }

    private func countFiles(in directory: URL, ext: String, excludingProtected: Bool = false) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { url in
            guard url.pathExtension == ext else { return false }
            if excludingProtected {
                let name = url.deletingPathExtension().lastPathComponent
                if Self.protectedBundleNames.contains(name) { return false }
            }
            return true
        }.count
    }

    // MARK: - Connections

    /// Loads all connections from both provider directories.
    func loadConnections() -> [Connection] {
        loadConnectionsReportingErrors().loaded
    }

    /// Same as [`loadConnections()`](src/Environment/EnvironmentManager.swift) but also
    /// returns a [`ConfigError`](src/Chat/Models.swift) per connection file that
    /// failed to read or decode. Used by `ChatEngine` to populate the
    /// configuration-error registry.
    func loadConnectionsReportingErrors() -> (loaded: [Connection], errors: [ConfigError]) {
        var loaded: [Connection] = []
        var errors: [ConfigError] = []
        let r1 = loadConnectionsReportingErrors(in: openaiConnectionsURL, provider: .openai)
        loaded.append(contentsOf: r1.loaded)
        errors.append(contentsOf: r1.errors)
        let r2 = loadConnectionsReportingErrors(in: anthropicConnectionsURL, provider: .anthropic)
        loaded.append(contentsOf: r2.loaded)
        errors.append(contentsOf: r2.errors)
        return (loaded.sorted { $0.displayName < $1.displayName }, errors)
    }

    private func loadConnectionsReportingErrors(in directory: URL, provider: ConnectionProvider) -> (loaded: [Connection], errors: [ConfigError]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var loaded: [Connection] = []
        var errors: [ConfigError] = []
        for url in files where url.pathExtension == "jsonc" {
            debugLog("FileRead", "reading \(relativePath(url))")
            let name = url.deletingPathExtension().lastPathComponent
            let entityName = "\(provider.rawValue)/\(name)"
            guard let data = try? Data(contentsOf: url) else {
                debugLog("Env", "⚠️ failed to read \(provider.rawValue) connection \"\(name)\"")
                errors.append(ConfigError(kind: .connection, entityName: entityName, message: "connection file could not be read"))
                continue
            }
            do {
                let config = try ConfigValidation.decodeConnection(data)
                loaded.append(connection(from: config, url: url, provider: provider))
            } catch {
                debugLog("Env", "⚠️ failed to decode \(provider.rawValue) connection \"\(name)\" — \(error)")
                errors.append(ConfigError(kind: .connection, entityName: entityName, message: error.localizedDescription))
            }
        }
        return (loaded, errors)
    }

    /// Loads one connection from a specific file URL, inferring the provider
    /// from the parent directory name (`openai` or `anthropic`). Returns nil
    /// if the file is missing or undecodable, or the provider is unknown.
    func loadSingleConnection(url: URL) -> Connection? {
        debugLog("FileRead", "reading \(relativePath(url))")
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            debugLog("Env", "⚠️ failed to read connection \"\(name)\"")
            return nil
        }
        let config: ConnectionConfig
        do {
            config = try ConfigValidation.decodeConnection(data)
        } catch {
            debugLog("Env", "⚠️ failed to decode connection \"\(name)\" — \(error)")
            return nil
        }
        let provider: ConnectionProvider
        switch url.deletingLastPathComponent().lastPathComponent {
        case "openai": provider = .openai
        case "anthropic": provider = .anthropic
        default: return nil
        }
        return connection(from: config, url: url, provider: provider)
    }

    /// Builds a `Connection` value from a decoded config + file URL + provider.
    private func connection(from config: ConnectionConfig, url: URL, provider: ConnectionProvider) -> Connection {
        let name = url.deletingPathExtension().lastPathComponent
        return Connection(
            provider: provider,
            name: name,
            baseUrl: config.baseUrl,
            apiKey: config.apiKey,
            model: config.model,
            imageInput: config.imageInput ?? false,
            requestParameters: config.requestParameters
        )
    }

    // MARK: - MCP servers

    /// Loads all MCP servers from the `mcp` directory, sorted by name.
    func loadMCPs() -> [MCPServer] {
        loadMCPsReportingErrors().loaded
    }

    /// Same as [`loadMCPs()`](src/Environment/EnvironmentManager.swift) but also returns a
    /// [`ConfigError`](src/Chat/Models.swift) per MCP config file that failed to
    /// read or decode. Used by `ChatEngine` to populate the configuration-error
    /// registry.
    func loadMCPsReportingErrors() -> (loaded: [MCPServer], errors: [ConfigError]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: mcpsURL, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var loaded: [MCPServer] = []
        var errors: [ConfigError] = []
        for url in files where url.pathExtension == "toml" {
            debugLog("FileRead", "reading \(relativePath(url))")
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                debugLog("MCP", "⚠️ failed to read MCP config \"\(name)\"")
                errors.append(ConfigError(kind: .mcpConfig, entityName: name, message: "MCP config file could not be read"))
                continue
            }
            do {
                let config = try ConfigValidation.decodeMCP(data)
                loaded.append(MCPServer(name: name, config: config))
            } catch {
                debugLog("MCP", "⚠️ failed to decode MCP config \"\(name)\" — \(error)")
                errors.append(ConfigError(kind: .mcpConfig, entityName: name, message: error.localizedDescription))
            }
        }
        return (loaded.sorted { $0.name < $1.name }, errors)
    }

    /// Loads one MCP config by name. Returns nil if the file is missing or
    /// undecodable.
    func loadSingleMCP(name: String) -> MCPServer? {
        loadSingleMCPReportingError(name: name).server
    }

    /// Same as [`loadSingleMCP(name:)`](src/Environment/EnvironmentManager.swift) but also
    /// returns a [`ConfigError`](src/Chat/Models.swift) when the file exists but
    /// fails to decode. A missing file returns `(nil, nil)` — the caller treats
    /// that as a removal (no error).
    func loadSingleMCPReportingError(name: String) -> (server: MCPServer?, error: ConfigError?) {
        let url = mcpsURL.appendingPathComponent("\(name).toml")
        debugLog("FileRead", "reading \(relativePath(url))")
        guard let data = try? Data(contentsOf: url) else {
            debugLog("MCP", "⚠️ failed to read MCP config \"\(name)\"")
            return (nil, nil)
        }
        do {
            let config = try ConfigValidation.decodeMCP(data)
            return (MCPServer(name: name, config: config), nil)
        } catch {
            debugLog("MCP", "⚠️ failed to decode MCP config \"\(name)\" — \(error)")
            return (nil, ConfigError(kind: .mcpConfig, entityName: name, message: error.localizedDescription))
        }
    }

    /// Saves an MCP server to `mcp/<name>.toml` (TOML encoded).
    func saveMCP(_ server: MCPServer) {
        let url = mcpsURL.appendingPathComponent("\(server.name).toml")
        debugLog("FileWrite", "writing \(relativePath(url))")
        guard let data = try? TOMLEncoder().encode(server.config) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes an MCP server config file by name.
    func deleteMCP(name: String) {
        let url = mcpsURL.appendingPathComponent("\(name).toml")
        debugLog("FileWrite", "deleting \(relativePath(url))")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Path helpers

    /// Returns a path relative to `~/iCanHazAI` for readable log messages.
    /// Falls back to the absolute path if the URL is not under the root.
    func relativePath(_ url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let abs = url.standardizedFileURL.path
        if abs.hasPrefix(root) {
            let rel = abs.dropFirst(root.count)
            return rel.hasPrefix("/") ? String(rel.dropFirst()) : String(rel)
        }
        return abs
    }
}
