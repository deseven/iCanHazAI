import Foundation
import Testing
import TOML
@testable import iCanHazAI

// Tests for the in-process configurator tools ([`ConfiguratorTools`](src/ConfiguratorTools.swift)).
// Each test points the tools at a throwaway `TempEnv` so nothing touches `~/iCanHazAI`.
extension AllAppTests {
    @Suite("Configurator tools")
    struct ConfiguratorToolsTests {

        /// JSON-encodes a string→string argument map the way the model would.
        private func args(_ dict: [String: String]) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
        }

        private func call(_ name: String, _ env: EnvironmentManager, _ dict: [String: String], callID: String = "c") async -> ToolResult {
            await ConfiguratorTools.call(name: name, arguments: args(dict), callID: callID, env: env)
        }

        // MARK: - Registry

        @Test("tool definitions cover the expected tools")
        func registry() {
            #expect(!ConfiguratorTools.toolDefinitions.isEmpty)
            for def in ConfiguratorTools.toolDefinitions {
                #expect(def.serverName == ConfiguratorTools.serverName)
                #expect(def.prefix.isEmpty)
                #expect(ConfiguratorTools.toolNames.contains(def.name))
            }
            for expected in ["list_connections", "list_mcps", "list_roles", "list_prompts",
                             "read_config", "write_config", "read_log",
                             "delete_connection", "delete_mcp", "delete_role", "delete_prompt",
                             "mcp_stdio_check", "mcp_http_check", "connection_check"] {
                #expect(ConfiguratorTools.toolNames.contains(expected), "missing \(expected)")
            }
        }

        // MARK: - Connections

        @Test("write_connection validates and persists; list/read round-trip")
        func connectionRoundTrip() async throws {
            let env = try TempEnv().env
            let invalid = await call("write_connection", env, ["id": "openai/bad", "content": "{ not jsonc"])
            #expect(invalid.isError)
            #expect(!FileManager.default.fileExists(atPath: env.openaiConnectionsURL.appendingPathComponent("bad.jsonc").path))

            let valid = await call("write_connection", env, ["id": "openai/gpt", "content": "{\"model\":\"gpt-4o\"}"])
            #expect(!valid.isError)

            let listed = await call("list_connections", env, [:])
            #expect(!listed.isError)
            #expect(listed.content.contains("openai/gpt"))

            let read = await call("read_connection", env, ["id": "openai/gpt"])
            #expect(!read.isError)
            #expect(read.content.contains("\"model\":"))
        }

        @Test("write_connection rejects an unknown provider")
        func connectionBadProvider() async throws {
            let env = try TempEnv().env
            let res = await call("write_connection", env, ["id": "mistral/x", "content": "{\"model\":\"m\"}"])
            #expect(res.isError)
        }

        // MARK: - MCPs

        @Test("write_mcp validates TOML and persists")
        func mcpRoundTrip() async throws {
            let env = try TempEnv().env
            let invalid = await call("write_mcp", env, ["name": "bad", "content": "not = = toml"])
            #expect(invalid.isError)

            let valid = await call("write_mcp", env, ["name": "Tavily", "content": "transport = \"stdio\"\ncommand = \"npx -y x\"\n"])
            #expect(!valid.isError)

            let listed = await call("list_mcps", env, [:])
            #expect(listed.content.contains("Tavily"))

            let read = await call("read_mcp", env, ["name": "Tavily"])
            #expect(read.content.contains("transport"))
        }

        // MARK: - Roles

        @Test("write_role validates TOML and persists; protected role refused")
        func roleRoundTrip() async throws {
            let env = try TempEnv().env
            let invalid = await call("write_role", env, ["name": "bad", "content": "[[broken"])
            #expect(invalid.isError)

            let valid = await call("write_role", env, ["name": "Coder", "content": "prompt = \"Assistant\"\n"])
            #expect(!valid.isError)

            let protected = await call("write_role", env, ["name": "Configurator", "content": "prompt = \"Assistant\"\n"])
            #expect(protected.isError)
        }

        // MARK: - Prompts

        @Test("write_prompt rejects empty; protected prompt refused")
        func promptRoundTrip() async throws {
            let env = try TempEnv().env
            let empty = await call("write_prompt", env, ["name": "Empty", "content": "   "])
            #expect(empty.isError)

            let valid = await call("write_prompt", env, ["name": "Greeter", "content": "You are friendly."])
            #expect(!valid.isError)

            let protected = await call("write_prompt", env, ["name": "Configurator", "content": "nope"])
            #expect(protected.isError)

            let read = await call("read_prompt", env, ["name": "Greeter"])
            #expect(read.content == "You are friendly.")
        }

        // MARK: - App config

        @Test("write_config validates and read_config round-trips")
        func configRoundTrip() async throws {
            let env = try TempEnv().env
            // Broken TOML is rejected.
            #expect(await call("write_config", env, ["content": "[general\nbroken"]).isError)
            // A partial config is rejected too — the app's decoder requires the
            // full set of groups, so write_config mirrors that (prevents writing
            // a config the app would discard on reload).
            #expect(await call("write_config", env, ["content": "[general]\ndefault_role = \"Assistant\"\n"]).isError)

            // A complete config (encoded the same way the app persists it) is accepted.
            var cfg = AppConfig()
            cfg.general.defaultRole = "Assistant"
            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let toml = String(data: try encoder.encode(cfg), encoding: .utf8) ?? ""
            let valid = await call("write_config", env, ["content": toml])
            #expect(!valid.isError)

            let read = await call("read_config", env, [:])
            #expect(read.content.contains("default_role"))
        }

        // MARK: - Read missing

        @Test("reading a missing entity errors")
        func readMissing() async throws {
            let env = try TempEnv().env
            #expect(await call("read_mcp", env, ["name": "nope"]).isError)
            #expect(await call("read_role", env, ["name": "nope"]).isError)
            #expect(await call("read_prompt", env, ["name": "nope"]).isError)
            #expect(await call("read_connection", env, ["id": "openai/nope"]).isError)
        }

        // MARK: - Name validation

        @Test("names with spaces and special characters are accepted")
        func namesWithSpacesAndSpecialChars() async throws {
            let env = try TempEnv().env
            // A name with spaces and '&' — the case from the bug report.
            let res = await call("write_mcp", env, [
                "name": "Ultimate Google Docs & Sheets MCP Server",
                "content": "transport = \"stdio\"\ncommand = \"echo\"\n"
            ])
            #expect(!res.isError, "error: \(res.content)")

            // It should be listable and readable under that exact name.
            let listed = await call("list_mcps", env, [:])
            #expect(listed.content.contains("Ultimate Google Docs & Sheets MCP Server"))

            let read = await call("read_mcp", env, ["name": "Ultimate Google Docs & Sheets MCP Server"])
            #expect(!read.isError)
            #expect(read.content.contains("transport"))

            // Reading a non-existent name with spaces yields "not found", not a
            // character-rejection error.
            let missing = await call("read_role", env, ["name": "Incorrect Test Role"])
            #expect(missing.isError)
            #expect(missing.content.lowercased().contains("not found"))
        }

        @Test("names with path separators are rejected")
        func namesWithPathSeparators() async throws {
            let env = try TempEnv().env
            // Forward slash — would escape the entity directory.
            let slash = await call("write_mcp", env, ["name": "../evil", "content": "transport = \"stdio\"\n"])
            #expect(slash.isError)
            #expect(slash.content.lowercased().contains("separator"))

            // Backslash — same protection on platforms that treat it as a separator.
            let backslash = await call("write_mcp", env, ["name": "..\\evil", "content": "transport = \"stdio\"\n"])
            #expect(backslash.isError)
            #expect(backslash.content.lowercased().contains("separator"))

            // Empty name is rejected.
            let empty = await call("write_mcp", env, ["name": "", "content": "transport = \"stdio\"\n"])
            #expect(empty.isError)
            #expect(empty.content.lowercased().contains("empty"))
        }

        // MARK: - Delete

        @Test("delete removes existing entities and errors on missing/protected")
        func deleteFlow() async throws {
            let env = try TempEnv().env
            _ = await call("write_mcp", env, ["name": "Temp", "content": "transport = \"stdio\"\n"])
            _ = await call("write_role", env, ["name": "Temp", "content": "prompt = \"Assistant\"\n"])
            _ = await call("write_prompt", env, ["name": "Temp", "content": "hi"])
            _ = await call("write_connection", env, ["id": "openai/Temp", "content": "{\"model\":\"m\"}"])

            #expect(!(await call("delete_mcp", env, ["name": "Temp"])).isError)
            #expect(!(await call("delete_role", env, ["name": "Temp"])).isError)
            #expect(!(await call("delete_prompt", env, ["name": "Temp"])).isError)
            #expect(!(await call("delete_connection", env, ["id": "openai/Temp"])).isError)

            // Already deleted → error.
            #expect(await call("delete_mcp", env, ["name": "Temp"]).isError)

            // Protected names cannot be deleted.
            #expect(await call("delete_role", env, ["name": "Configurator"]).isError)
            #expect(await call("delete_prompt", env, ["name": "Configurator"]).isError)
        }

        // MARK: - read_log

        @Test("read_log returns a string")
        func readLog() async throws {
            let env = try TempEnv().env
            let res = await call("read_log", env, [:])
            #expect(!res.isError)
        }

        @Test("read_log trims to the last 1000 lines")
        func readLogTrims() async throws {
            let temp = try TempEnv()
            let env = temp.env
            let logURL = env.rootURL.appendingPathComponent("app.log")
            // 1500 numbered lines; the tail should keep 501..1500.
            let content = (1...1500).map { "line \($0)" }.joined(separator: "\n")
            try Data(content.utf8).write(to: logURL)
            let res = await call("read_log", env, [:])
            #expect(!res.isError)
            #expect(!res.content.contains("line 500\n"))
            #expect(res.content.contains("line 501"))
            #expect(res.content.contains("line 1500"))
            #expect(res.content.components(separatedBy: "\n").count <= 1000)
        }

        // MARK: - Error messages

        @Test("validation errors name the offending field")
        func validationMessagesAreSpecific() async throws {
            let env = try TempEnv().env
            // Missing required "model" → message must mention "model".
            let conn = await call("write_connection", env, ["id": "openai/x", "content": "{\"baseUrl\":\"https://x\"}"])
            #expect(conn.isError)
            #expect(conn.content.lowercased().contains("model"))

            // Missing required "transport" → message must mention "transport".
            let mcp = await call("write_mcp", env, ["name": "x", "content": "command = \"echo\"\n"])
            #expect(mcp.isError)
            #expect(mcp.content.lowercased().contains("transport"))

            // Broken TOML syntax → message mentions invalid/syntax.
            let role = await call("write_role", env, ["name": "x", "content": "not = = valid"])
            #expect(role.isError)
            #expect(role.content.lowercased().contains("invalid"))
        }

        // MARK: - mcp_stdio_check

        @Test("mcp_stdio_check lists tools from a running stdio server")
        func mcpStdioCheckListsTools() async throws {
            // The bundled MCP binaries are built by build.sh before tests run
            // (same assumption the MCPTestHarness-based suites make).
            let path = try #require(MCPManager.builtinBinaryPath(for: "iCanHazAI-UtilsMCP"))
            let env = try TempEnv().env
            let res = await call("mcp_stdio_check", env, ["command": "\"\(path)\""])
            #expect(!res.isError, "error: \(res.content)")
            #expect(res.content.contains("calc"))
        }

        @Test("mcp_stdio_check reports an error for a failing command")
        func mcpStdioCheckFails() async throws {
            let env = try TempEnv().env
            // A command that exits immediately with a non-zero status.
            let res = await call("mcp_stdio_check", env, ["command": "this-binary-does-not-exist-xyz"])
            #expect(res.isError)
        }

        @Test("mcp_stdio_check rejects an empty command")
        func mcpStdioCheckEmpty() async throws {
            let env = try TempEnv().env
            let res = await call("mcp_stdio_check", env, ["command": ""])
            #expect(res.isError)
            #expect(res.content.lowercased().contains("command"))
        }

        // MARK: - mcp_http_check

        @Test("mcp_http_check rejects an empty endpoint")
        func mcpHttpCheckEmpty() async throws {
            let env = try TempEnv().env
            let res = await call("mcp_http_check", env, ["endpoint": ""])
            #expect(res.isError)
            #expect(res.content.lowercased().contains("endpoint"))
        }

        @Test("mcp_http_check rejects an invalid endpoint URL")
        func mcpHttpCheckInvalidUrl() async throws {
            let env = try TempEnv().env
            let res = await call("mcp_http_check", env, ["endpoint": "not a url"])
            #expect(res.isError)
            #expect(res.content.lowercased().contains("valid"))
        }

        @Test("mcp_http_check errors on an unreachable endpoint")
        func mcpHttpCheckUnreachable() async throws {
            let env = try TempEnv().env
            // Port 1 is reserved/unbindable, so the connection should fail fast.
            let res = await call("mcp_http_check", env, ["endpoint": "http://127.0.0.1:1/mcp"])
            #expect(res.isError)
        }

        // MARK: - connection_check

        @Test("connection_check errors on a missing connection")
        func connectionCheckMissing() async throws {
            let env = try TempEnv().env
            let res = await call("connection_check", env, ["id": "openai/nope"])
            #expect(res.isError)
            #expect(res.content.lowercased().contains("not found"))
        }

        @Test("connection_check errors on a malformed id")
        func connectionCheckBadId() async throws {
            let env = try TempEnv().env
            let res = await call("connection_check", env, ["id": "no-slash"])
            #expect(res.isError)
        }

        @Test("connection_check errors on an undecodable connection file")
        func connectionCheckUndecodable() async throws {
            let env = try TempEnv().env
            _ = await call("write_connection", env, ["id": "openai/broken", "content": "{\"model\":\"m\"}"])
            // Corrupt the file on disk so loading/decoding fails.
            let url = env.openaiConnectionsURL.appendingPathComponent("broken.jsonc")
            try Data("{ not valid jsonc".utf8).write(to: url)
            let res = await call("connection_check", env, ["id": "openai/broken"])
            #expect(res.isError)
        }
    }
}
