import Foundation
import Testing

@testable import iCanHazAI

/// The seven ways the app reaches the mock: four built-in providers whose base URL is swapped for the mock,
/// and three custom ones, one per type. `ollama` and `ollamaOpenAI` are the same Ollama server (one channel)
/// reached through its native API and through its OpenAI layer.
enum SmokeProvider: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case deepseek, openai, anthropic, openrouter, ollama, ollamaOpenAI, llamaCpp

    var testDescription: String { rawValue }

    var channel: MockChannel {
        switch self {
        case .deepseek: return .deepseek
        case .openai: return .openai
        case .anthropic: return .anthropic
        case .openrouter: return .openrouter
        case .ollama, .ollamaOpenAI: return .ollama
        case .llamaCpp: return .llamaCpp
        }
    }

    /// What a custom provider is, or nil for a built-in one.
    var customType: CustomProviderType? {
        switch self {
        case .ollama: return .ollama
        case .ollamaOpenAI: return .openai
        case .llamaCpp: return .llamacpp
        default: return nil
        }
    }

    var provider: Provider {
        switch self {
        case .deepseek: return .deepseek
        case .openai: return .openai
        case .anthropic: return .anthropic
        case .openrouter: return .openrouter
        case .ollama: return .custom("ollama")
        case .ollamaOpenAI: return .custom("ollama-openai")
        case .llamaCpp: return .custom("llama-cpp")
        }
    }

    var isCustom: Bool { provider.isCustom }
    var isAnthropic: Bool { self == .anthropic }
    /// Ollama's native API: NDJSON, `options`, object tool arguments, results paired by tool name.
    var isOllamaNative: Bool { self == .ollama }

    /// Whether the mock streams reasoning text for this provider (OpenAI's chat completions never do).
    var streamsThinking: Bool { self != .openai }

    /// The URL the app talks to: the mock under this provider's prefix. A built-in provider has the path of
    /// the real base URL (so a regression in a default URL path is caught); a custom one is given as the
    /// user would type it: the server's address for the native types, with `/v1` for an OpenAI-compatible one.
    var baseURL: String {
        let root = MockServer.shared.baseURL.absoluteString
        switch self {
        case .ollama, .llamaCpp: return "\(root)/\(channel.rawValue)"
        case .ollamaOpenAI: return "\(root)/\(channel.rawValue)/v1"
        default: return "\(root)/\(channel.rawValue)\(URL(string: provider.defaultBaseUrl)!.path)"
        }
    }

    var customConfig: CustomProviderConfig? {
        customType.map { CustomProviderConfig(name: provider.rawValue, type: $0, endpoint: baseURL) }
    }

    /// The path of the chat request on the mock.
    var chatPath: String {
        switch self {
        case .ollama: return "/ollama/api/chat"
        case .llamaCpp: return "/llama-cpp/v1/chat/completions"
        default: return baseURLPath + (isAnthropic ? "/messages" : "/chat/completions")
        }
    }
    var modelsPath: String {
        switch self {
        case .ollama: return "/ollama/api/tags"
        case .llamaCpp: return "/llama-cpp/v1/models"
        default: return baseURLPath + "/models"
        }
    }
    private var baseURLPath: String { URL(string: baseURL)!.path }

    /// A model of this provider that chats are created with.
    var modelName: String {
        switch self {
        case .deepseek: return "deepseek-flash"
        case .openai: return "gpt-4o"
        case .anthropic: return "claude-sonnet-5-5"
        case .openrouter: return "anthropic/claude-sonnet-5-5"
        case .ollama, .ollamaOpenAI: return "llama3.2:latest"
        case .llamaCpp: return "qwen3-8b"
        }
    }

    var modelString: String { "\(provider.rawValue):\(modelName)" }

    /// What the app should list for this provider after the mock's listing is filtered.
    var expectedModels: Set<String> {
        switch self {
        case .deepseek: return ["deepseek-flash", "deepseek-v4-pro"]
        case .openai: return ["gpt-4o", "gpt-4o-mini", "gpt-5"]
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-text-only"]
        case .openrouter:
            return [
                "anthropic/claude-sonnet-5-5", "openai/gpt-5", "deepseek/deepseek-flash",
                "meta-llama/llama-3.3-70b-instruct:free", "foo/bar",
            ]
        // The embedding model installed next to them is left out: by its capabilities for the native API,
        // by LiteLLM's mode for the OpenAI layer.
        case .ollama, .ollamaOpenAI: return ["llama3.2:latest", "qwen3-vl:8b", "gpt-oss:20b"]
        case .llamaCpp: return ["qwen3-8b"]
        }
    }
}

extension SmokeProvider {
    /// The key must travel the way this provider's API wants it.
    func expectAuth(_ request: MockRequest, sourceLocation: SourceLocation = #_sourceLocation) {
        if isAnthropic {
            #expect(request.header("x-api-key") == SmokeFixture.apiKey, sourceLocation: sourceLocation)
            #expect(request.header("anthropic-version") == "2023-06-01", sourceLocation: sourceLocation)
        } else {
            #expect(request.header("authorization") == "Bearer \(SmokeFixture.apiKey)", sourceLocation: sourceLocation)
        }
    }
}

enum SmokeRoleTools {
    case none
    /// `calc` only, auto-approved.
    case calcAutoAllow
    /// `calc` only; every call asks first.
    case calcApproval
    /// `calc` and `sleep`, auto-approved.
    case utilsAutoAllow
}

struct SmokeTimeout: Error, CustomStringConvertible {
    let description: String
}

/// One engine on a throwaway environment, wired to the mock provider API. Each test builds its own; nothing
/// is shared with `ChatEngine.shared`.
final class SmokeFixture: @unchecked Sendable {
    static let apiKey = "mock-key"
    static let systemPrompt = "You are a smoke test assistant."

    let mock = MockServer.shared
    let temp: TempEnv
    let registry: ProviderRegistry
    let catalog: ModelCatalog
    let engine: ChatEngine
    /// Set by tests that deliberately make the mock reject requests (e.g. a bad key).
    var allowMockRejections = false
    private var chats: [String] = []

    private init() async throws {
        try SmokeSandbox.install()
        try await MockServer.shared.reset()
        let temp = try TempEnv()
        let registry = ProviderRegistry(store: InMemorySecretStore())
        try await registry.load()
        var baseUrls: [Provider: String] = [:]
        for sp in SmokeProvider.allCases where !sp.isCustom { baseUrls[sp.provider] = sp.baseURL }
        let catalog = ModelCatalog(
            registry: registry, store: ModelCatalogStore(), fetcher: URLSessionFetcher(),
            metadata: LiteLLMMetadataSource(fetcher: URLSessionFetcher(), url: MockServer.shared.liteLLMURL),
            baseUrls: baseUrls)
        let engine = ChatEngine(store: temp.store, env: temp.env, registry: registry, catalog: catalog)
        await engine.setEndpointOverrides(baseUrls)
        self.temp = temp
        self.registry = registry
        self.catalog = catalog
        self.engine = engine
    }

    /// Runs `body` on a fresh fixture, then checks the mock saw exactly what the test scripted.
    static func run(_ body: (SmokeFixture) async throws -> Void) async throws {
        let fixture = try await SmokeFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
        try await fixture.verifyMock()
    }

    private func cleanUp() async {
        for chat in chats { await engine.deleteChat(filename: chat) }
        chats = []
    }

    private func verifyMock() async throws {
        let status = try await mock.status()
        #expect(status.pendingScenarios == 0, "scenarios queued but never consumed")
        #expect(status.unscripted.isEmpty, "chat requests without a scenario: \(status.unscripted)")
        if !allowMockRejections {
            #expect(status.mockErrors.isEmpty, "the mock rejected requests: \(status.mockErrors)")
        }
    }

    // MARK: - Setup

    /// Adds the provider the way the wizard does: validate the key, then add it with the validation result.
    @discardableResult
    func addProvider(_ sp: SmokeProvider, apiKey: String = SmokeFixture.apiKey) async throws -> ValidationResult {
        let custom = sp.customConfig
        let validation = try await engine.validateProvider(sp.provider, custom: custom, apiKey: apiKey)
        try await engine.addProvider(
            sp.provider, custom: custom, keyName: "Default", apiKey: apiKey, makeActive: true,
            validation: validation)
        return validation
    }

    /// Writes the role (and its prompt) into the environment and has the engine pick them up.
    func installRole(_ name: String = "SmokePlain", tools: SmokeRoleTools = .none) async throws {
        try Self.systemPrompt.write(
            to: temp.env.promptsURL.appendingPathComponent("SmokePrompt.md"), atomically: true, encoding: .utf8)
        var toml = "description = \"Smoke test role\"\nprompt = \"SmokePrompt\"\n"
        switch tools {
        case .none: break
        case .calcAutoAllow: toml += "\n[utils]\ntools = [\"calc\"]\nauto_allow_all = true\n"
        case .calcApproval: toml += "\n[utils]\ntools = [\"calc\"]\n"
        case .utilsAutoAllow: toml += "\n[utils]\ntools = [\"calc\", \"sleep\"]\nauto_allow_all = true\n"
        }
        try toml.write(
            to: temp.env.rolesURL.appendingPathComponent("\(name).toml"), atomically: true, encoding: .utf8)
        await engine.applyConfigChange(.prompts)
        await engine.applyConfigChange(.roles)
    }

    /// A new chat on the provider's model (or on `model` of it), selected like the GUI does when the user
    /// opens it (which also keeps its content loaded after the stream ends).
    func newChat(_ sp: SmokeProvider, model: String? = nil, role: String = "SmokePlain") async -> String {
        let modelString = model.map { "\(sp.provider.rawValue):\($0)" } ?? sp.modelString
        let filename = await engine.createNewChat(role: role, model: modelString)
        await engine.selectChat(filename: filename)
        chats.append(filename)
        return filename
    }

    // MARK: - Acting

    func send(_ chat: String, _ text: String) async {
        await engine.sendMessage(filename: chat, text: text)
    }

    // MARK: - Observing

    func record(_ chat: String) async -> ChatRecord? { await engine.record(for: chat) }

    func messages(_ chat: String) async -> [ChatMessage] {
        await record(chat)?.chat?.activeMessages ?? []
    }

    /// What was saved to disk, as opposed to what is in memory.
    func persisted(_ chat: String) throws -> Chat { try temp.readChatDirect(chat) }

    /// Waits on the engine's event stream until the chat's record satisfies `predicate`. The subscription
    /// starts with a snapshot, so a state that already holds returns immediately.
    /// `confirm` is an extra check on the engine itself, evaluated whenever the predicate holds; if it
    /// doesn't, the wait continues with the next event.
    @discardableResult
    func wait(
        for chat: String, _ what: String, timeout: Double = 10,
        until predicate: @escaping @Sendable (ChatRecord) -> Bool,
        confirm: (@Sendable () async -> Bool)? = nil
    ) async throws -> ChatRecord {
        let events = await engine.subscribe()
        return try await withThrowingTaskGroup(of: ChatRecord.self) { group in
            group.addTask {
                for await event in events {
                    if case .chatsChanged(let records) = event,
                        let record = records.first(where: { $0.filename == chat }), predicate(record)
                    {
                        if let confirm, await !confirm() { continue }
                        return record
                    }
                }
                throw SmokeTimeout(description: "event stream ended while waiting for \(what)")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw SmokeTimeout(description: "timed out waiting for \(what)")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Waits for the stream to be over *and unwound*. A stop clears `isStreaming` at once, while the cancelled
    /// task still has to save the chat, so the flag alone would be too early.
    @discardableResult
    func waitUntilIdle(_ chat: String, timeout: Double = 10) async throws -> ChatRecord {
        let engine = self.engine
        return try await wait(
            for: chat, "the stream to finish", timeout: timeout, until: { !$0.isStreaming },
            confirm: { await !engine.hasActiveStreamTask(filename: chat) })
    }

    /// Waits until the streamed assistant answer (the last assistant message) reads exactly `content`.
    @discardableResult
    func waitForAnswer(_ chat: String, _ content: String, timeout: Double = 10) async throws -> ChatRecord {
        try await wait(for: chat, "the answer to read \"\(content)\"", timeout: timeout) { record in
            record.chat?.activeMessages.last(where: { $0.role == .assistant })?.content == content
        }
    }

    /// Waits until a tool call of the last assistant message asks for approval; returns its id.
    func waitForApproval(_ chat: String, timeout: Double = 10) async throws -> String {
        let record = try await wait(for: chat, "a tool approval request", timeout: timeout) { record in
            let calls = record.chat?.activeMessages.last(where: { $0.role == .assistant })?.toolCalls ?? []
            return calls.contains { $0.pendingApproval }
        }
        let calls = record.chat?.activeMessages.last(where: { $0.role == .assistant })?.toolCalls ?? []
        return calls.first { $0.pendingApproval }?.id ?? ""
    }

    func waitForQueue(_ chat: String, count: Int, timeout: Double = 10) async throws {
        try await wait(for: chat, "\(count) queued message(s)", timeout: timeout) { $0.queuedMessages.count == count }
    }
}
