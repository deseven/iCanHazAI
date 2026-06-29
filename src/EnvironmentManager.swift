// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import TOML
import OpenAI

/// Manages the app's data directory
/// and provides loading/saving of chats, roles, and connections.
/// Pure file I/O with no UI dependency, so it is not main-actor isolated.
final class EnvironmentManager: @unchecked Sendable {

    static let shared = EnvironmentManager()

    let rootURL: URL
    let chatsURL: URL
    let rolesURL: URL
    let connectionsURL: URL
    let openaiConnectionsURL: URL
    let anthropicConnectionsURL: URL

    private init() {
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        rootURL = homeURL.appendingPathComponent("iCanHazAI", isDirectory: true)
        chatsURL = rootURL.appendingPathComponent("chats", isDirectory: true)
        rolesURL = rootURL.appendingPathComponent("roles", isDirectory: true)
        connectionsURL = rootURL.appendingPathComponent("connections", isDirectory: true)
        openaiConnectionsURL = connectionsURL.appendingPathComponent("openai", isDirectory: true)
        anthropicConnectionsURL = connectionsURL.appendingPathComponent("anthropic", isDirectory: true)
    }

    // MARK: - Setup

    /// Ensures the data directory structure exists, creating it if needed.
    func ensureDirectories() {
        let fm = FileManager.default
        for url in [rootURL, chatsURL, rolesURL, connectionsURL, openaiConnectionsURL, anthropicConnectionsURL] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
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
            guard let data = try? Data(contentsOf: file),
                  let chat = try? JSONDecoder().decode(Chat.self, from: data) else {
                continue
            }
            result.append((filename: file.lastPathComponent, chat: chat))
        }
        result.sort { $0.filename < $1.filename }
        return result
    }

    /// Generates a new chat filename using the current date/time.
    func newChatFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date()) + ".json"
    }

    /// Saves a chat to disk under the given filename.
    func saveChat(_ chat: Chat, filename: String) {
        let url = chatsURL.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(chat) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes a chat file.
    func deleteChat(filename: String) {
        let url = chatsURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Roles

    /// Loads default roles bundled with the app (read-only).
    func loadDefaultRoles() -> [Role] {
        guard let bundleURL = Bundle.main.url(forResource: "roles", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                return Role(name: name, content: content, isDefault: true)
            }
            .sorted { $0.name < $1.name }
    }

    /// Loads user-defined roles from the roles directory.
    func loadCustomRoles() -> [Role] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: rolesURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                return Role(name: name, content: content, isDefault: false)
            }
            .sorted { $0.name < $1.name }
    }

    /// Loads all roles (default + custom). Custom roles override defaults with the same name.
    func loadAllRoles() -> [Role] {
        let defaults = loadDefaultRoles()
        let custom = loadCustomRoles()
        var merged: [String: Role] = [:]
        for role in defaults { merged[role.name] = role }
        for role in custom { merged[role.name] = role }
        return merged.values.sorted { $0.name < $1.name }
    }

    // MARK: - Connections

    /// Loads all connections from both provider directories.
    func loadConnections() -> [Connection] {
        var connections: [Connection] = []
        connections.append(contentsOf: loadConnections(in: openaiConnectionsURL, provider: .openai))
        connections.append(contentsOf: loadConnections(in: anthropicConnectionsURL, provider: .anthropic))
        return connections.sorted { $0.displayName < $1.displayName }
    }

    private func loadConnections(in directory: URL, provider: ConnectionProvider) -> [Connection] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "toml" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                guard let config = try? TOMLDecoder().decode(ConnectionConfig.self, from: data) else {
                    return nil
                }
                let name = url.deletingPathExtension().lastPathComponent
                let vendorParams: [String: JSONValue]? = {
                    guard let jsonString = config.vendorParameters,
                          let jsonData = jsonString.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode([String: JSONValue].self, from: jsonData)
                }()
                return Connection(
                    provider: provider,
                    name: name,
                    endpoint: config.endpoint,
                    token: config.token,
                    model: config.model,
                    maxTokens: config.maxTokens,
                    temperature: config.temperature,
                    topP: config.topP,
                    reasoningEffort: config.reasoningEffort,
                    frequencyPenalty: config.frequencyPenalty,
                    presencePenalty: config.presencePenalty,
                    maxCompletionTokens: config.maxCompletionTokens,
                    seed: config.seed,
                    topK: config.topK,
                    stopSequences: config.stopSequences,
                    thinkingEnabled: config.thinkingEnabled,
                    thinkingBudget: config.thinkingBudget,
                    vendorParameters: vendorParams,
                    imageInput: config.imageInput
                )
            }
    }
}
