import Foundation

@testable import iCanHazAI

// Client for the mock provider API's control interface (tools/mock-api, `/__mock`).

enum MockChannel: String, CaseIterable, Sendable {
    case deepseek, openai, anthropic, openrouter, ollama
    case llamaCpp = "llama-cpp"
}

/// One scripted step of a mock response. See tools/mock-api/scenario.py.
enum MockStep: Sendable {
    case text(String)
    case thinking(String)
    case toolCall(name: String, arguments: String = "{}", id: String? = nil, split: Int? = nil)
    case usage(input: Int? = nil, output: Int? = nil, cached: Int? = nil)
    case finish(String)
    case open
    case gate(String)
    case delay(ms: Int)
    case keepAlive
    case sseError(String, type: String? = nil)
    case httpError(Int, message: String? = nil, type: String? = nil)
    /// Resets the connection: the client sees a network error.
    case drop
    /// Closes the connection cleanly mid-stream: the client sees a truncated stream, not an error.
    case close
    case hold

    var json: [String: Any] {
        func compact(_ pairs: [String: Any?]) -> [String: Any] { pairs.compactMapValues { $0 } }
        switch self {
        case .text(let text): return ["type": "text", "text": text]
        case .thinking(let text): return ["type": "thinking", "text": text]
        case .toolCall(let name, let arguments, let id, let split):
            return compact(["type": "tool_call", "name": name, "arguments": arguments, "id": id, "split": split])
        case .usage(let input, let output, let cached):
            return compact(["type": "usage", "input": input, "output": output, "cached": cached])
        case .finish(let reason): return ["type": "finish", "reason": reason]
        case .open: return ["type": "open"]
        case .gate(let name): return ["type": "gate", "name": name]
        case .delay(let ms): return ["type": "delay", "ms": ms]
        case .keepAlive: return ["type": "keepalive"]
        case .sseError(let message, let type):
            return compact(["type": "sse_error", "message": message, "error_type": type])
        case .httpError(let status, let message, let type):
            return compact(["type": "http_error", "status": status, "message": message, "error_type": type])
        case .drop: return ["type": "drop"]
        case .close: return ["type": "close"]
        case .hold: return ["type": "hold"]
        }
    }
}

/// A request the app sent to the mock, as recorded by the server.
struct MockRequest: @unchecked Sendable {
    let seq: Int
    let channel: String
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Any?
    let scripted: Bool
    let state: String
    let status: Int?
    let waitingGate: String?
    let clientDisconnected: Bool
    let mockError: String?

    init(_ json: [String: Any]) {
        seq = json["seq"] as? Int ?? 0
        channel = json["channel"] as? String ?? ""
        method = json["method"] as? String ?? ""
        path = json["path"] as? String ?? ""
        query = json["query"] as? [String: String] ?? [:]
        headers = json["headers"] as? [String: String] ?? [:]
        body = json["body"]
        scripted = json["scripted"] as? Bool ?? false
        state = json["state"] as? String ?? ""
        status = json["status"] as? Int
        waitingGate = json["waiting_gate"] as? String
        clientDisconnected = json["client_disconnected"] as? Bool ?? false
        mockError = json["mock_error"] as? String
    }

    var isChat: Bool {
        path.hasSuffix("/chat/completions") || path.hasSuffix("/messages") || path.hasSuffix("/api/chat")
    }
    var json: [String: Any] { body as? [String: Any] ?? [:] }
    var messages: [[String: Any]] { json["messages"] as? [[String: Any]] ?? [] }
    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct MockStatus: Sendable {
    var pendingScenarios: Int
    var unscripted: [Int]
    var mockErrors: [String]
}

struct MockError: Error, CustomStringConvertible {
    let description: String
}

struct MockServer: Sendable {
    let baseURL: URL

    static let shared: MockServer = {
        guard let url = SmokeEnv.mockURL else { fatalError("ICHAI_MOCK_URL is not set — run ./build.sh smoke") }
        return MockServer(baseURL: url)
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private var root: String { baseURL.absoluteString }
    var liteLLMURL: URL { URL(string: root + "/litellm/model_prices_and_context_window.json")! }

    // MARK: - Control API

    @discardableResult
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: root + path)!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MockError(description: "mock \(method) \(path) failed: \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    func reset() async throws { try await call("POST", "/__mock/reset") }

    func enqueue(_ channel: MockChannel, _ steps: [MockStep]) async throws {
        try await call(
            "POST", "/__mock/scenarios", body: ["channel": channel.rawValue, "steps": steps.map(\.json)])
    }

    func enqueue(_ channel: MockChannel, _ steps: MockStep...) async throws {
        try await enqueue(channel, steps)
    }

    func release(_ gate: String) async throws { try await call("POST", "/__mock/gates/\(gate)/release") }

    /// `page_size`, `models`, `models_status`, `reject_keys`, and per channel `loaded`, `show_failures`,
    /// `ps_status` (Ollama) or `router`, `props`, `props_by_model`, `props_status` (llama.cpp); `NSNull()`
    /// clears an override.
    func configure(_ channel: MockChannel, _ settings: [String: Any]) async throws {
        var body = settings
        body["channel"] = channel.rawValue
        try await call("POST", "/__mock/config", body: body)
    }

    func requests(_ channel: MockChannel? = nil) async throws -> [MockRequest] {
        let suffix = channel.map { "?channel=\($0.rawValue)" } ?? ""
        let data = try await call("GET", "/__mock/requests" + suffix)
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return items.map(MockRequest.init)
    }

    func chatRequests(_ channel: MockChannel) async throws -> [MockRequest] {
        try await requests(channel).filter(\.isChat)
    }

    func status() async throws -> MockStatus {
        let data = try await call("GET", "/__mock/status")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let errors = (json["mock_errors"] as? [[String: Any]] ?? []).map {
            "\($0["path"] as? String ?? "?"): \($0["error"] as? String ?? "?")"
        }
        return MockStatus(
            pendingScenarios: (json["pending_scenarios"] as? [Any])?.count ?? 0,
            unscripted: json["unscripted"] as? [Int] ?? [], mockErrors: errors)
    }

    // MARK: - Waiting

    /// Polls the request log until `check` holds. The mock has no push channel; the interval is short and
    /// the timeout turns a hang into a failure.
    @discardableResult
    func waitUntil(
        _ what: String, timeout: Double = 10, _ check: @Sendable ([MockRequest]) -> Bool
    ) async throws -> [MockRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let all = try await requests()
            if check(all) { return all }
            guard Date() < deadline else { throw MockError(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @discardableResult
    func waitForChatRequests(_ channel: MockChannel, count: Int, timeout: Double = 10) async throws -> [MockRequest] {
        try await waitUntil("\(count) chat request(s) on \(channel.rawValue)", timeout: timeout) { all in
            all.filter { $0.channel == channel.rawValue && $0.isChat }.count >= count
        }
        .filter { $0.channel == channel.rawValue && $0.isChat }
    }

    /// Waits until the `index`-th chat request of the channel (0-based) is parked on `gate`; returns it.
    @discardableResult
    func waitForChatRequest(
        _ channel: MockChannel, index: Int, atGate gate: String, timeout: Double = 10
    ) async throws -> MockRequest {
        let all = try await waitUntil("chat request \(index) on \(channel.rawValue) at gate \(gate)", timeout: timeout)
        {
            let chats = $0.filter { $0.channel == channel.rawValue && $0.isChat }
            return chats.count > index && chats[index].waitingGate == gate
        }
        return all.filter { $0.channel == channel.rawValue && $0.isChat }[index]
    }

    /// Waits until the server saw the client go away on the chat request with `seq`.
    func waitForDisconnect(seq: Int, timeout: Double = 10) async throws {
        try await waitUntil("client disconnect of request \(seq)", timeout: timeout) { all in
            all.first { $0.seq == seq }?.clientDisconnected == true
        }
    }

    /// Waits until the chat request with `seq` is parked on a gate.
    func waitForGate(seq: Int, _ gate: String, timeout: Double = 10) async throws {
        try await waitUntil("request \(seq) at gate \(gate)", timeout: timeout) { all in
            all.first { $0.seq == seq }?.waitingGate == gate
        }
    }
}
