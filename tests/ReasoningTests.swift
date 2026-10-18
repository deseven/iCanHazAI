import Foundation
import Testing

@testable import iCanHazAI

private func capability(
    _ levels: [String], canDisable: Bool = false, budgetOnly: Bool = false, supported: Bool = true
) -> ReasoningCapability {
    ReasoningCapability(
        supported: supported, levels: levels, defaultLevel: nil, canDisable: canDisable, budgetOnly: budgetOnly)
}

private func resolved(
    _ provider: Provider, reasoning: String?, capability: ReasoningCapability, maxOutputTokens: Int? = 64_000
) -> ResolvedModel {
    var caps = ModelCapabilities.safeDefaults
    caps.reasoning = capability
    caps.maxOutputTokens = maxOutputTokens
    return ResolvedModel(provider: provider, modelID: "m", apiKey: "k", capabilities: caps, reasoning: reasoning)
}

private func openAIBody(_ model: ResolvedModel) -> [String: Any] {
    OpenAIProvider().buildRequestBody(
        model: model, messages: [ChatMessage(role: .user, content: "hi")], chatFilename: "", tools: nil, stream: true)
}

private func anthropicBody(_ model: ResolvedModel, messages: [ChatMessage]? = nil) -> [String: Any] {
    AnthropicProvider().buildRequestBody(
        model: model, messages: messages ?? [ChatMessage(role: .user, content: "hi")], chatFilename: "",
        tools: nil, stream: true)
}

extension AllAppTests {
    @Suite("Reasoning capability")
    struct ReasoningCapabilityTests {

        @Test("the default is the middle level, rounding up")
        func defaults() {
            #expect(capability(["low", "medium", "high"]).defaultOption == "medium")
            #expect(capability(["low", "medium", "high", "xhigh", "max"]).defaultOption == "high")
            #expect(capability(["low", "medium", "high", "xhigh"]).defaultOption == "high")
            #expect(capability(["low", "high", "max"]).defaultOption == "high")
            #expect(capability(["low", "high"]).defaultOption == "high")
            #expect(capability(["high"], canDisable: true).defaultOption == "high")
        }

        @Test("the provider's default level wins when the model offers it")
        func providerDefault() {
            var caps = capability(["low", "medium", "high", "xhigh", "max"])
            caps.defaultLevel = "max"
            #expect(caps.defaultOption == "max")
            caps.defaultLevel = "low"
            #expect(caps.defaultOption == "low")
        }

        @Test("a provider default that isn't offered, or is none, falls back to the middle level")
        func providerDefaultFallback() {
            var caps = capability(["low", "medium", "high"])
            caps.defaultLevel = "max"
            #expect(caps.defaultOption == "medium")
            caps.defaultLevel = "none"
            #expect(caps.defaultOption == "medium")
            var withNone = capability(["none", "low", "medium", "high"], canDisable: true)
            withNone.defaultLevel = "none"
            #expect(withNone.defaultOption == "medium")
        }

        @Test("the default never switches reasoning off, and ignores a provider's none")
        func defaultPrefersReasoning() {
            #expect(capability(["none", "low", "medium", "high"]).defaultOption == "medium")
            #expect(capability([], canDisable: true).defaultOption == ReasoningSetting.on)
        }

        @Test("options list off first when allowed, then levels low to high")
        func options() {
            #expect(capability(["low", "medium", "high"]).options == ["low", "medium", "high"])
            #expect(
                capability(["low", "high"], canDisable: true).options
                    == [ReasoningSetting.off, "low", "high"])
            #expect(
                capability(["none", "low", "high"]).options == [ReasoningSetting.off, "low", "high"])
            #expect(capability([], canDisable: true).options == [ReasoningSetting.off, ReasoningSetting.on])
        }

        @Test("a model with nothing to choose has no control")
        func notConfigurable() {
            #expect(capability([]).isConfigurable == false)
            #expect(capability(["high"]).isConfigurable == false)
            #expect(capability(["low", "high"], supported: false).isConfigurable == false)
            #expect(ReasoningCapability.unsupported.options.isEmpty)
            #expect(ReasoningCapability.unsupported.defaultOption == nil)
            #expect(ReasoningCapability.unsupported.effectiveOption(for: "high") == nil)
        }

        @Test("a stored setting is kept only when the model offers it exactly")
        func effective() {
            let caps = capability(["low", "medium", "high"], canDisable: true)
            #expect(caps.effectiveOption(for: "high") == "high")
            #expect(caps.effectiveOption(for: ReasoningSetting.off) == ReasoningSetting.off)
            #expect(caps.effectiveOption(for: "xhigh") == "medium")
            #expect(caps.effectiveOption(for: nil) == "medium")
        }

        @Test("the fast setting is off when possible, else the lowest level")
        func fast() {
            #expect(capability(["low", "high"], canDisable: true).fastOption == ReasoningSetting.off)
            #expect(capability(["none", "low", "high"]).fastOption == ReasoningSetting.off)
            #expect(capability(["minimal", "low", "high"]).fastOption == "minimal")
            #expect(capability([], supported: true).fastOption == nil)
            #expect(ReasoningCapability.unsupported.fastOption == nil)
        }

        @Test("titles read naturally")
        func titles() {
            #expect(ReasoningSetting.title("off") == "Off")
            #expect(ReasoningSetting.title("medium") == "Medium")
            #expect(ReasoningSetting.title("xhigh") == "Extra high")
        }

        @Test("a chat keeps its setting through Codable and decodes without one")
        func chatRoundTrip() throws {
            var chat = Chat(model: "openai:gpt-5")
            chat.reasoning = "high"
            let data = try JSONEncoder().encode(chat)
            #expect(try JSONDecoder().decode(Chat.self, from: data).reasoning == "high")
            let legacy = try JSONDecoder().decode(Chat.self, from: Data(#"{"messages":[]}"#.utf8))
            #expect(legacy.reasoning == nil)
        }
    }

    @Suite("Reasoning request bodies")
    struct ReasoningRequestTests {

        // MARK: OpenAI wire

        @Test("OpenAI sends reasoning_effort, and none when off")
        func openAI() {
            let caps = capability(["none", "low", "medium", "high"])
            #expect(
                openAIBody(resolved(.openai, reasoning: "high", capability: caps))["reasoning_effort"] as? String
                    == "high")
            #expect(
                openAIBody(resolved(.openai, reasoning: ReasoningSetting.off, capability: caps))["reasoning_effort"]
                    as? String == "none")
            #expect(openAIBody(resolved(.openai, reasoning: nil, capability: caps))["reasoning_effort"] == nil)
        }

        @Test("nothing is sent for a model that doesn't reason")
        func unsupported() {
            let body = openAIBody(resolved(.openai, reasoning: "high", capability: .unsupported))
            #expect(body["reasoning_effort"] == nil)
        }

        @Test("DeepSeek toggles thinking and passes the level")
        func deepSeek() {
            let caps = capability(["low", "high", "max"], canDisable: true)
            let on = openAIBody(resolved(.deepseek, reasoning: "max", capability: caps))
            #expect((on["thinking"] as? [String: String])?["type"] == "enabled")
            #expect(on["reasoning_effort"] as? String == "max")
            let off = openAIBody(resolved(.deepseek, reasoning: ReasoningSetting.off, capability: caps))
            #expect((off["thinking"] as? [String: String])?["type"] == "disabled")
            #expect(off["reasoning_effort"] == nil)
        }

        @Test("OpenRouter uses the unified reasoning object")
        func openRouter() {
            let caps = capability(["low", "high"], canDisable: true)
            let level = openAIBody(resolved(.openrouter, reasoning: "low", capability: caps))
            #expect((level["reasoning"] as? [String: String])?["effort"] == "low")
            let off = openAIBody(resolved(.openrouter, reasoning: ReasoningSetting.off, capability: caps))
            #expect((off["reasoning"] as? [String: Bool])?["enabled"] == false)
            let toggle = openAIBody(
                resolved(.openrouter, reasoning: ReasoningSetting.on, capability: capability([], canDisable: true)))
            #expect((toggle["reasoning"] as? [String: Bool])?["enabled"] == true)
        }

        // MARK: Anthropic

        @Test("Anthropic adaptive thinking asks for summarized display and sets the effort")
        func anthropicAdaptive() {
            let caps = capability(["low", "medium", "high"], canDisable: true)
            let body = anthropicBody(resolved(.anthropic, reasoning: "medium", capability: caps))
            let thinking = body["thinking"] as? [String: String]
            #expect(thinking?["type"] == "adaptive")
            #expect(thinking?["display"] == "summarized")
            #expect((body["output_config"] as? [String: String])?["effort"] == "medium")
        }

        @Test("Anthropic off sends disabled and no effort")
        func anthropicOff() {
            let caps = capability(["low", "high"], canDisable: true)
            let body = anthropicBody(resolved(.anthropic, reasoning: ReasoningSetting.off, capability: caps))
            #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
            #expect(body["output_config"] == nil)
        }

        @Test("Anthropic without a setting leaves thinking alone")
        func anthropicNil() {
            let body = anthropicBody(resolved(.anthropic, reasoning: nil, capability: capability(["low", "high"])))
            #expect(body["thinking"] == nil)
        }

        @Test("budget-only Anthropic models get a manual budget below max_tokens")
        func anthropicBudget() {
            let caps = capability([], canDisable: true, budgetOnly: true)
            let body = anthropicBody(resolved(.anthropic, reasoning: ReasoningSetting.on, capability: caps))
            let thinking = body["thinking"] as? [String: Any]
            #expect(thinking?["type"] as? String == "enabled")
            #expect(thinking?["display"] as? String == "summarized")
            let budget = thinking?["budget_tokens"] as? Int
            let maxTokens = body["max_tokens"] as? Int
            #expect(budget == 16_000)
            #expect((budget ?? Int.max) < (maxTokens ?? 0))
            #expect(body["output_config"] == nil)
        }

        @Test("budget-only thinking is skipped mid tool turn and when max_tokens is too small")
        func anthropicBudgetGuards() {
            let caps = capability([], canDisable: true, budgetOnly: true)
            let midTool = [
                ChatMessage(role: .user, content: "hi"),
                ChatMessage(
                    role: .assistant, content: "", toolCalls: [ToolCall(id: "1", name: "t", arguments: "{}")]),
                ChatMessage(
                    role: .tool, content: "", toolResults: [ToolResult(callID: "1", content: "ok", isError: false)]),
            ]
            let model = resolved(.anthropic, reasoning: ReasoningSetting.on, capability: caps)
            #expect(anthropicBody(model, messages: midTool)["thinking"] == nil)
            let tiny = resolved(.anthropic, reasoning: ReasoningSetting.on, capability: caps, maxOutputTokens: 1500)
            #expect(anthropicBody(tiny)["thinking"] == nil)
        }
    }
}
