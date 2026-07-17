import Foundation
import Testing
import TOML
import Logging
@testable import iCanHazAI

// Tests for the TOML-based MCP server config (`MCPConfig` / `MCPServer`).
// Locks down the snake_case on-disk contract for the `run_policy` key and its
// enum values, plus the encode/decode round-trip used by `EnvironmentManager`.
extension AllAppTests {
    @Suite("MCP config")
    struct MCPConfigTests {
        @Test("MCPConfig decodes snake_case run_policy key and values")
        func decodesRunPolicy() throws {
            let toml = """
            transport = "stdio"
            prefix = ""
            run_policy = "on_demand"
            command = "node /srv/index.js"
            tools = ["search"]
            """
            let config = try TOMLDecoder().decode(MCPConfig.self, from: Data(toml.utf8))
            let server = MCPServer(name: "Tavily", config: config)
            #expect(server.transport == .stdio)
            #expect(server.runPolicy == .onDemand)
            #expect(server.command == "node /srv/index.js")
            #expect(server.tools == ["search"])
        }

        @Test("unknown run_policy value falls back to always_on")
        func unknownRunPolicyFallsBack() throws {
            let toml = """
            transport = "stdio"
            prefix = ""
            run_policy = "bogus"
            command = "x"
            """
            let config = try TOMLDecoder().decode(MCPConfig.self, from: Data(toml.utf8))
            let server = MCPServer(name: "S", config: config)
            #expect(server.runPolicy == .alwaysOn)
        }

        @Test("MCPConfig decodes without a prefix key (prefix is optional)")
        func decodesMissingPrefix() throws {
            // A hand-written config that omits `prefix` (e.g. the Tavily HTTP
            // config) must decode cleanly rather than being silently dropped.
            let toml = """
            transport = "http"
            endpoint = "https://mcp.tavily.com/mcp/?tavilyApiKey=secret"
            tools = ["tavily_search", "tavily_extract"]
            """
            let config = try TOMLDecoder().decode(MCPConfig.self, from: Data(toml.utf8))
            let server = MCPServer(name: "Tavily", config: config)
            #expect(server.transport == .http)
            #expect(server.prefix == "")
            #expect(server.endpoint == "https://mcp.tavily.com/mcp/?tavilyApiKey=secret")
            #expect(server.tools == ["tavily_search", "tavily_extract"])
        }

        @Test("http server omits run_policy and decodes endpoint/token")
        func decodesHttpServer() throws {
            let toml = """
            transport = "http"
            prefix = "remote"
            endpoint = "https://example.com/mcp"
            token = "secret"
            """
            let config = try TOMLDecoder().decode(MCPConfig.self, from: Data(toml.utf8))
            let server = MCPServer(name: "Remote", config: config)
            #expect(server.transport == .http)
            // run_policy is meaningless for http; the init leaves it nil.
            #expect(server.runPolicy == nil)
            #expect(server.endpoint == "https://example.com/mcp")
            #expect(server.token == "secret")
        }

        @Test("MCPServer.config round-trips through TOML with snake_case keys")
        func roundTripsTOML() throws {
            let server = MCPServer(
                name: "Tavily",
                prefix: "",
                transport: .stdio,
                runPolicy: .onDemand,
                command: "npx -y @tavily/mcp-server",
                endpoint: nil,
                token: nil,
                tools: ["tavily_search"]
            )
            let encoded = try TOMLEncoder().encode(server.config)
            let text = try #require(String(data: encoded, encoding: .utf8))
            // The on-disk key and value are snake_case.
            #expect(text.contains("run_policy"))
            #expect(text.contains("\"on_demand\""))
            #expect(!text.contains("runPolicy"))

            // Decoding the encoded TOML reproduces the same server.
            let decoded = try TOMLDecoder().decode(MCPConfig.self, from: encoded)
            let again = MCPServer(name: "Tavily", config: decoded)
            #expect(again.transport == server.transport)
            #expect(again.runPolicy == server.runPolicy)
            #expect(again.command == server.command)
            #expect(again.tools == server.tools)
        }

        @Test("MCPDebugLogHandler forwards to debugLog without infinite recursion")
        func logHandlerDoesNotRecurse() async throws {
            // Regression: MCPDebugLogHandler previously implemented the deprecated
            // `log(level:...Source:...)` with a capital `Source` label, which did
            // not satisfy the LogHandler protocol requirement. The default
            // implementations then called each other ~1000+ times until the stack
            // overflowed (EXC_BAD_ACCESS / SIGBUS) on app launch.
            DebugLogger.stopFileLogging()
            DebugLogger.setEnabled(false)
            defer {
                DebugLogger.stopFileLogging()
                DebugLogger.setEnabled(false)
            }

            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ichai-mcplog-\(UUID().uuidString)", isDirectory: true)
            DebugLogger.startFileLogging(rootURL: tmpRoot)

            let logger = Logger(label: "test.mcp") { _ in MCPDebugLogHandler() }
            let marker = "mcp-handler-marker-\(UUID().uuidString)"
            logger.debug(.init(stringLiteral: marker))

            // Give the file write a moment to flush.
            try await Task.sleep(for: .milliseconds(50))

            let url = try #require(DebugLogger.currentLogFileURL)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.contains("MCP/SDK"))
            #expect(contents.contains(marker))
        }
    }
}
