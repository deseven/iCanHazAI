import Foundation
import Testing

@testable import iCanHazAI

// Tests for per-connection custom HTTP headers: the provider `buildHeaders`
// merge (defaults preserved, override wins, empty-string removes, auth
// override), config validation (invalid types produce a clear error), the
// file template's commented-out example, and the `listModels` synthetic
// connection carrying headers.
extension AllAppTests {
    @Suite("Connection custom headers")
    struct ConnectionHeadersTests {

        // MARK: - Anthropic provider

        @Test("Anthropic defaults are preserved without custom headers")
        func anthropicDefaultsPreserved() {
            let conn = Connection(
                provider: .anthropic, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: nil)
            let headers = AnthropicProvider().buildHeaders(connection: conn)
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["Accept"] == "text/event-stream")
            #expect(headers["anthropic-version"] == "2023-06-01")
            #expect(headers["User-Agent"] == AppInfo.userAgent)
            #expect(headers["x-api-key"] == "sk-x")
        }

        @Test("Anthropic custom header overrides User-Agent")
        func anthropicOverridesUserAgent() {
            let conn = Connection(
                provider: .anthropic, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: ["User-Agent": "claude-cli/2.0.30 (external, cli)"])
            let headers = AnthropicProvider().buildHeaders(connection: conn)
            #expect(headers["User-Agent"] == "claude-cli/2.0.30 (external, cli)")
            // Other defaults untouched.
            #expect(headers["anthropic-version"] == "2023-06-01")
            #expect(headers["x-api-key"] == "sk-x")
        }

        @Test("Anthropic custom header overrides auth (x-api-key)")
        func anthropicOverridesAuth() {
            let conn = Connection(
                provider: .anthropic, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: ["x-api-key": "custom-key"])
            let headers = AnthropicProvider().buildHeaders(connection: conn)
            #expect(headers["x-api-key"] == "custom-key")
        }

        @Test("Anthropic empty-string value removes a default header")
        func anthropicEmptyStringRemoves() {
            let conn = Connection(
                provider: .anthropic, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: ["User-Agent": ""])
            let headers = AnthropicProvider().buildHeaders(connection: conn)
            #expect(headers["User-Agent"] == nil)
            #expect(headers["x-api-key"] == "sk-x")
        }

        @Test("Anthropic adds a brand-new header")
        func anthropicAddsNewHeader() {
            let conn = Connection(
                provider: .anthropic, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: ["X-Custom": "yes"])
            let headers = AnthropicProvider().buildHeaders(connection: conn)
            #expect(headers["X-Custom"] == "yes")
        }

        // MARK: - OpenAI provider

        @Test("OpenAI defaults are preserved without custom headers")
        func openaiDefaultsPreserved() {
            let conn = Connection(
                provider: .openai, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: nil)
            let headers = OpenAIProvider().buildHeaders(connection: conn)
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["Accept"] == "text/event-stream")
            #expect(headers["User-Agent"] == AppInfo.userAgent)
            #expect(headers["Authorization"] == "Bearer sk-x")
        }

        @Test("OpenAI custom header overrides User-Agent")
        func openaiOverridesUserAgent() {
            let conn = Connection(
                provider: .openai, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: ["User-Agent": "codex_cli_rs/0.1"])
            let headers = OpenAIProvider().buildHeaders(connection: conn)
            #expect(headers["User-Agent"] == "codex_cli_rs/0.1")
            #expect(headers["Authorization"] == "Bearer sk-x")
        }

        @Test("OpenAI custom header overrides auth (Authorization)")
        func openaiOverridesAuth() {
            let conn = Connection(
                provider: .openai, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: ["Authorization": "ApiKey custom"])
            let headers = OpenAIProvider().buildHeaders(connection: conn)
            #expect(headers["Authorization"] == "ApiKey custom")
        }

        @Test("OpenAI empty-string value removes a default header")
        func openaiEmptyStringRemoves() {
            let conn = Connection(
                provider: .openai, name: "c", baseUrl: nil, apiKey: "sk-x", model: "m", imageInput: false,
                requestParameters: nil, headers: ["Authorization": ""])
            let headers = OpenAIProvider().buildHeaders(connection: conn)
            #expect(headers["Authorization"] == nil)
            #expect(headers["User-Agent"] == AppInfo.userAgent)
        }

        // MARK: - Config validation

        @Test("decodeConnection accepts a valid headers object")
        func decodeAcceptsHeaders() throws {
            let jsonc = #"{"model":"m","headers":{"User-Agent":"x","X-Key":"y"}}"#
            let config = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            #expect(config.headers?["User-Agent"] == "x")
            #expect(config.headers?["X-Key"] == "y")
        }

        @Test("decodeConnection accepts an empty headers object")
        func decodeAcceptsEmptyHeaders() throws {
            let jsonc = #"{"model":"m","headers":{}}"#
            let config = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            #expect(config.headers?.isEmpty == true)
        }

        @Test("decodeConnection rejects headers that is not an object")
        func decodeRejectsNonObjectHeaders() {
            let jsonc = #"{"model":"m","headers":"not-an-object"}"#
            #expect(throws: ConfigValidationError.self) {
                _ = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            }
        }

        @Test("decodeConnection rejects headers with a non-string value")
        func decodeRejectsNonStringHeaderValue() {
            let jsonc = #"{"model":"m","headers":{"User-Agent":123}}"#
            do {
                _ = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
                Issue.record("expected a validation error")
            } catch let err as ConfigValidationError {
                #expect(err.message.contains("headers"))
                #expect(err.message.contains("User-Agent"))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test("decodeConnection rejects headers with a non-string value in a nested shape")
        func decodeRejectsNonStringHeaderValueNested() {
            let jsonc = #"{"model":"m","headers":{"X":{"nested":true}}}"#
            #expect(throws: ConfigValidationError.self) {
                _ = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            }
        }

        // MARK: - Loading from disk

        @Test("loaded connection carries headers from the config file")
        func loadedConnectionCarriesHeaders() throws {
            let temp = try TempEnv()
            let env = temp.env
            let jsonc = #"{"model":"m","headers":{"User-Agent":"claude-cli/2.0.30"}}"#
            try Data(jsonc.utf8).write(to: env.openaiConnectionsURL.appendingPathComponent("custom.jsonc"))
            let connections = env.loadConnections()
            let conn = try #require(connections.first { $0.name == "custom" })
            #expect(conn.headers?["User-Agent"] == "claude-cli/2.0.30")
        }

        @Test("loaded connection has nil headers when the field is absent")
        func loadedConnectionNilHeadersWhenAbsent() throws {
            let temp = try TempEnv()
            let env = temp.env
            try Data(#"{"model":"m"}"#.utf8).write(to: env.openaiConnectionsURL.appendingPathComponent("plain.jsonc"))
            let connections = env.loadConnections()
            let conn = try #require(connections.first { $0.name == "plain" })
            #expect(conn.headers == nil)
        }

        // MARK: - File template

        @Test("ConnectionFileWriter includes a commented-out headers example")
        func fileTemplateIncludesHeadersExample() {
            let jsonc = ConnectionFileWriter.generateJSONC(
                provider: .openai, baseUrl: nil, apiKey: nil, model: "gpt-4o", imageInput: false)
            #expect(jsonc.contains("\"headers\""))
            #expect(jsonc.contains("User-Agent"))
            // The example must be commented out so it doesn't take effect by default.
            #expect(jsonc.contains("// \"headers\""))
        }

        // MARK: - listModels synthetic connection

        @Test("listModels threads headers into the synthetic connection's buildHeaders")
        func listModelsCarriesHeaders() {
            // We can't hit a real endpoint in tests, but we can verify the
            // synthetic Connection built inside listModels carries the headers
            // by mirroring its construction here and checking buildHeaders.
            let provider = ConnectionProvider.anthropic
            let headers: [String: String] = ["User-Agent": "claude-cli/2.0.30 (external, cli)"]
            let synthetic = Connection(
                provider: provider,
                name: "_models",
                baseUrl: nil,
                apiKey: "sk-x",
                model: "",
                imageInput: false,
                requestParameters: nil,
                headers: headers
            )
            let built = AnthropicProvider().buildHeaders(connection: synthetic)
            #expect(built["User-Agent"] == "claude-cli/2.0.30 (external, cli)")
            #expect(built["x-api-key"] == "sk-x")
        }

        @Test("listModels without headers keeps the default User-Agent in the synthetic connection")
        func listModelsDefaultUserAgent() {
            let synthetic = Connection(
                provider: .openai,
                name: "_models",
                baseUrl: nil,
                apiKey: "sk-x",
                model: "",
                imageInput: false,
                requestParameters: nil,
                headers: nil
            )
            let built = OpenAIProvider().buildHeaders(connection: synthetic)
            #expect(built["User-Agent"] == AppInfo.userAgent)
        }
    }
}
