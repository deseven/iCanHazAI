import Foundation

@testable import iCanHazAI

struct StubResponse: Sendable {
    var status: Int = 200
    var body: String

    static func json(_ body: String, status: Int = 200) -> StubResponse { StubResponse(status: status, body: body) }
    static func status(_ status: Int) -> StubResponse { StubResponse(status: status, body: "{}") }
}

/// Canned HTTP responses keyed by whatever the handler decides, with a request log.
final class StubFetcher: HTTPFetching, @unchecked Sendable {
    typealias Handler = @Sendable (URL) async throws -> StubResponse

    struct Request: Sendable {
        var url: URL
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var _handler: Handler
    private var _requests: [Request] = []

    init(_ handler: @escaping Handler) { _handler = handler }

    func setHandler(_ handler: @escaping Handler) { lock.withLock { _handler = handler } }

    var requests: [Request] { lock.withLock { _requests } }

    func count(where predicate: (URL) -> Bool) -> Int { requests.filter { predicate($0.url) }.count }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let handler = lock.withLock {
            _requests.append(Request(url: url, headers: headers))
            return _handler
        }
        let response = try await handler(url)
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (Data(response.body.utf8), http)
    }
}

struct StubMetadataSource: ModelMetadataSource {
    var result: Result<[String: LiteLLMEntry], Error>

    func openAIEntries() async throws -> [String: LiteLLMEntry] { try result.get() }
}

/// Switchable at runtime so one catalog can see a working and then a broken source.
final class FlakyMetadataSource: ModelMetadataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<[String: LiteLLMEntry], Error>

    init(_ result: Result<[String: LiteLLMEntry], Error>) { _result = result }

    func set(_ result: Result<[String: LiteLLMEntry], Error>) { lock.withLock { _result = result } }

    func openAIEntries() async throws -> [String: LiteLLMEntry] { try lock.withLock { _result }.get() }
}

struct TestFailure: Error {}

/// A clock that only moves when the test advances it.
final class ManualClock: CatalogClock, @unchecked Sendable {
    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let action: (() -> Void)? = lock.withLock {
                    if Task.isCancelled { return { continuation.resume(throwing: CancellationError()) } }
                    if current >= deadline { return { continuation.resume() } }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                action?()
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by interval: TimeInterval) {
        let due: [Sleeper] = lock.withLock {
            current = current.addingTimeInterval(interval)
            let ids = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Polls until `condition` holds; returns whether it did within the timeout.
func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - Fixtures

enum ProviderFixtures {
    static let anthropicPage1 = """
        {"data":[
          {"id":"claude-opus-x","display_name":"Claude Opus X","max_input_tokens":1000000,"max_tokens":128000,
           "lifecycle":"active",
           "capabilities":{"image_input":{"supported":true},
             "effort":{"supported":true,"max":{"supported":true},"low":{"supported":true},
                       "medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":false}},
             "thinking":{"supported":true,"types":{"adaptive":{"supported":true}}}}},
          {"id":"claude-haiku-old","display_name":"Claude Haiku Old","max_input_tokens":200000,"max_tokens":8192,
           "capabilities":{"image_input":{"supported":true},"effort":{"supported":false},
                           "thinking":{"supported":true}}}
        ],"has_more":true,"first_id":"claude-opus-x","last_id":"claude-haiku-old"}
        """

    static let anthropicPage2 = """
        {"data":[
          {"id":"claude-text-only","display_name":"Claude Text Only","max_input_tokens":100000,"max_tokens":4096,
           "capabilities":{"image_input":{"supported":false},"effort":{"supported":false},
                           "thinking":{"supported":false}}},
          {"id":"claude-retired","display_name":"Retired","lifecycle":"retired","max_input_tokens":1,"max_tokens":1}
        ],"has_more":false,"first_id":"claude-text-only","last_id":"claude-retired"}
        """

    static let deepseek = """
        {"object":"list","data":[
          {"id":"deepseek-flash","object":"model","owned_by":"deepseek","name":"DeepSeek-V4.1-Flash",
           "context_window":1048576,"max_output_tokens":393216,
           "input_modalities":["text","image"],"output_modalities":["text"],
           "effort":{"supported_levels":["max","low","high"],"default_level":"high"}},
          {"id":"deepseek-v4-pro","name":"DeepSeek-V4-Pro","context_window":1048576,"max_output_tokens":393216,
           "input_modalities":["text"],"output_modalities":["text"]},
          {"id":"deepseek-embed","name":"Embed","context_window":8192,
           "input_modalities":["text"],"output_modalities":["embedding"]}
        ]}
        """

    static let openRouterTop = """
        {"total_count":471,"data":[
          {"id":"anthropic/claude-x","name":"Anthropic: Claude X","context_length":200000,
           "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
           "top_provider":{"max_completion_tokens":64000},
           "reasoning":{"supported_efforts":["high","low"],"default_effort":"medium"},
           "supported_parameters":["reasoning","tools"]},
          {"id":"foo/bar:free","name":"Foo: Bar (free)","context_length":32000,
           "architecture":{"input_modalities":["text"]},"top_provider":{"max_completion_tokens":null},
           "supported_parameters":["reasoning","tools"]},
          {"id":"plain/model","name":"Plain","context_length":8000,
           "architecture":{"input_modalities":["text"]},"supported_parameters":["tools"]}
        ]}
        """

    static let openRouterLookup = """
        {"total_count":2,"data":[
          {"id":"foo/bar:batch","name":"Foo: Bar (batch)","context_length":1000,
           "architecture":{"input_modalities":["text"]}},
          {"id":"foo/bar","name":"Foo: Bar","context_length":2000,
           "architecture":{"input_modalities":["text","image"]}}
        ]}
        """

    static let openRouterCount = #"{"total_count":471,"data":[]}"#

    static func openRouterModels(_ entries: [(id: String, context: Int)]) -> String {
        let rows = entries.map {
            #"{"id":"\#($0.id)","name":"\#($0.id)","context_length":\#($0.context),"architecture":{"input_modalities":["text"]}}"#
        }
        return #"{"total_count":\#(entries.count),"data":[\#(rows.joined(separator: ","))]}"#
    }

    static func deepseekModels(_ ids: [String]) -> String {
        let rows = ids.map {
            #"{"id":"\#($0)","name":"\#($0)","context_window":1000,"input_modalities":["text"],"output_modalities":["text"]}"#
        }
        return #"{"data":[\#(rows.joined(separator: ","))]}"#
    }

    static func openAIModels(_ ids: [String], shutdown: [String: String] = [:]) -> String {
        let rows = ids.map { id -> String in
            if let date = shutdown[id] { return #"{"id":"\#(id)","object":"model","shutdown_date":"\#(date)"}"# }
            return #"{"id":"\#(id)","object":"model"}"#
        }
        return #"{"object":"list","data":[\#(rows.joined(separator: ","))]}"#
    }

    /// A LiteLLM-shaped excerpt, including entries of other providers that must be ignored.
    static let liteLLM = """
        {
          "sample_spec": {"litellm_provider": "one of https://docs.litellm.ai/docs/providers", "mode": "one of"},
          "gpt-5": {"litellm_provider":"openai","mode":"chat",
            "supported_endpoints":["/v1/chat/completions","/v1/responses"],
            "supports_vision":true,"max_input_tokens":272000,"max_output_tokens":128000,
            "supports_reasoning":true,"supports_minimal_reasoning_effort":true},
          "gpt-5-2025-08-07": {"litellm_provider":"openai","mode":"chat",
            "supported_endpoints":["/v1/chat/completions"],"max_input_tokens":272000,"supports_reasoning":true},
          "gpt-5.2": {"litellm_provider":"openai","mode":"chat",
            "supported_endpoints":["/v1/chat/completions"],"max_input_tokens":400000,"supports_reasoning":true,
            "supports_none_reasoning_effort":true,"supports_xhigh_reasoning_effort":true,
            "supports_max_reasoning_effort":false},
          "gpt-4o": {"litellm_provider":"openai","mode":"chat","supports_vision":true,
            "max_input_tokens":128000,"max_output_tokens":16384},
          "gpt-4o-2024-05-13": {"litellm_provider":"openai","mode":"chat","max_input_tokens":128000},
          "gpt-5-codex": {"litellm_provider":"openai","mode":"responses",
            "supported_endpoints":["/v1/responses"],"max_input_tokens":400000},
          "gpt-responses-only-no-endpoints": {"litellm_provider":"openai","mode":"responses"},
          "gpt-4o-audio-preview": {"litellm_provider":"openai","mode":"chat","max_input_tokens":128000},
          "gpt-4o-search-preview": {"litellm_provider":"openai","mode":"chat","max_input_tokens":128000},
          "babbage-002": {"litellm_provider":"openai","mode":"completion","max_input_tokens":16384},
          "o4-custom": {"litellm_provider":"openai","mode":"chat","max_input_tokens":200000,
            "supports_reasoning":true,"reasoning_effort_levels":["high","low"],
            "supports_xhigh_reasoning_effort":true},
          "chatgpt/chatgpt-4o-latest": {"litellm_provider":"chatgpt","mode":"chat","max_input_tokens":128000,
            "supports_vision":true},
          "claude-3-opus": {"litellm_provider":"anthropic","mode":"chat","max_input_tokens":200000}
        }
        """
}

func parseLiteLLMFixture() throws -> [String: LiteLLMEntry] {
    try LiteLLMMetadataSource.parseOpenAIEntries(from: Data(ProviderFixtures.liteLLM.utf8))
}
