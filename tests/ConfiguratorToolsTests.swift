import Foundation
import TOML
import Testing

@testable import iCanHazAI

// Tests for the in-process configurator tools ([`ConfiguratorTools`](src/Config/ConfiguratorTools.swift)).
// Each test points the tools at a throwaway `TempEnv` so nothing touches `~/iCanHazAI`.
extension AllAppTests {
    @Suite("Configurator tools")
    struct ConfiguratorToolsTests {

        /// JSON-encodes a string→string argument map the way the model would.
        private func args(_ dict: [String: String]) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
        }

        private func call(_ name: String, _ env: EnvironmentManager, _ dict: [String: String], callID: String = "c")
            async -> ToolResult
        {
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
            for expected in [
                "list_mcps", "list_roles", "list_prompts",
                "read_config", "write_config", "read_log",
                "delete_mcp", "delete_role", "delete_prompt",
                "check_mcp_stdio", "check_mcp_http",
            ] {
                #expect(ConfiguratorTools.toolNames.contains(expected), "missing \(expected)")
            }
        }

        @Test("connection tools are gone")
        func connectionToolsRemoved() async throws {
            for removed in [
                "list_connections", "read_connection", "write_connection", "delete_connection", "check_connection",
            ] {
                #expect(!ConfiguratorTools.toolNames.contains(removed), "\(removed) should not exist")
            }
            let env = try TempEnv().env
            #expect(await call("list_connections", env, [:]).isError)
        }

        // MARK: - MCPs

        @Test("write_mcp validates TOML and persists")
        func mcpRoundTrip() async throws {
            let env = try TempEnv().env
            let invalid = await call("write_mcp", env, ["name": "bad", "content": "not = = toml"])
            #expect(invalid.isError)

            let valid = await call(
                "write_mcp", env, ["name": "Tavily", "content": "transport = \"stdio\"\ncommand = \"npx -y x\"\n"])
            #expect(!valid.isError)

            let listed = await call("list_mcps", env, [:])
            #expect(listed.content.contains("Tavily"))

            let read = await call("read_mcp", env, ["name": "Tavily"])
            #expect(read.content.contains("transport"))
        }

        // MARK: - Roles

        @Test("write_role rejects references to entities that don't exist")
        func writeRoleRejectsUnknownReferences() async throws {
            let env = try TempEnv().env
            let badMCP = await call("write_role", env, ["name": "x", "content": "[[mcps]]\nmcp = \"Ghost\"\n"])
            #expect(badMCP.isError)
            #expect(badMCP.content.contains("Ghost"))
            let badPrompt = await call("write_role", env, ["name": "x", "content": "prompt = \"Ghost\"\n"])
            #expect(badPrompt.isError)
            #expect(badPrompt.content.contains("Ghost"))

            // Once the referenced MCP exists, the same write succeeds.
            _ = await call(
                "write_mcp", env, ["name": "Real", "content": "transport = \"stdio\"\ncommand = \"echo hi\"\n"])
            let ok = await call("write_role", env, ["name": "x", "content": "[[mcps]]\nmcp = \"Real\"\n"])
            #expect(!ok.isError)
        }

        @Test("write_role validates TOML and persists; protected role refused")
        func roleRoundTrip() async throws {
            let env = try TempEnv().env
            let invalid = await call("write_role", env, ["name": "bad", "content": "[[broken"])
            #expect(invalid.isError)

            // The referenced prompt must exist — role reference validation.
            _ = await call("write_prompt", env, ["name": "Assistant", "content": "hi"])
            let valid = await call("write_role", env, ["name": "Coder", "content": "prompt = \"Assistant\"\n"])
            #expect(!valid.isError)

            let protected = await call(
                "write_role", env, ["name": "Configurator", "content": "prompt = \"Assistant\"\n"])
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

        @Test("write_prompt rejects unknown variables; accepts known and escaped")
        func promptVariableValidation() async throws {
            let env = try TempEnv().env
            // Unknown variable → rejected, nothing written.
            let bad = await call("write_prompt", env, ["name": "Bad", "content": "Hi {stranger}"])
            #expect(bad.isError)
            #expect(bad.content.contains("{stranger}"))
            #expect(!FileManager.default.fileExists(atPath: env.promptsURL.appendingPathComponent("Bad.md").path))

            // Known variables + escaped literal brace → accepted.
            let good = await call("write_prompt", env, ["name": "Good", "content": "\\{literal} {user} {date}"])
            #expect(!good.isError)
            let read = await call("read_prompt", env, ["name": "Good"])
            #expect(read.content == "\\{literal} {user} {date}")
        }

        // MARK: - App config

        @Test("write_config validates and read_config round-trips")
        func configRoundTrip() async throws {
            let env = try TempEnv().env
            // Broken TOML (unparseable) is rejected.
            #expect(await call("write_config", env, ["content": "[general\nbroken"]).isError)
            // A partial config is accepted — every field/group is optional and
            // missing keys fall back to defaults rather than failing the decode.
            let partial = await call("write_config", env, ["content": "[general]\ndefault_role = \"Assistant\"\n"])
            #expect(!partial.isError)

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

        @Test("AppConfig decodes working_directories from TOML")
        func decodesWorkingDirectories() throws {
            let toml = """
                [general]
                default_role = "Assistant"
                working_directories = ["/Users/me/proj1", "/Users/me/proj2"]

                [chat_behaviour]
                expand_tool_use = false

                [chat_features]
                interface_scale = 100

                [debug]
                app_debug_enabled = false
                """
            let config = try TOMLDecoder().decode(AppConfig.self, from: Data(toml.utf8))
            #expect(config.general.workingDirectories == ["/Users/me/proj1", "/Users/me/proj2"])
        }

        @Test("AppConfig ignores keys of removed preferences")
        func ignoresRemovedKeys() throws {
            let toml = """
                [chat_features]
                mermaid_enabled = true
                katex_enabled = true
                interface_scale = 120

                [debug]
                app_debug_enabled = true
                chat_renderer_debug_enabled = true
                """
            let config = try TOMLDecoder().decode(AppConfig.self, from: Data(toml.utf8))
            #expect(config.chatFeatures.interfaceScale == 120)
            #expect(config.debug.appDebugEnabled == true)
        }

        @Test("AppConfig decodes working_directories as nil when omitted")
        func defaultsWorkingDirectories() throws {
            // An older config written before working_directories existed must
            // still decode cleanly — the field is optional so a missing key
            // yields nil rather than a decode failure.
            let toml = """
                [general]
                default_role = "Assistant"

                [chat_behaviour]
                expand_tool_use = false

                [chat_features]
                interface_scale = 100

                [debug]
                app_debug_enabled = false
                """
            let config = try TOMLDecoder().decode(AppConfig.self, from: Data(toml.utf8))
            #expect(config.general.workingDirectories == nil)
        }

        @Test("AppConfig working_directories round-trips through TOML with snake_case key")
        func roundTripsWorkingDirectories() throws {
            var cfg = AppConfig()
            cfg.general.workingDirectories = ["/a", "/b"]
            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let encoded = try encoder.encode(cfg)
            let text = try #require(String(data: encoded, encoding: .utf8))
            #expect(text.contains("working_directories"))
            let decoded = try TOMLDecoder().decode(AppConfig.self, from: encoded)
            #expect(decoded.general.workingDirectories == ["/a", "/b"])
        }

        @Test("AppConfig default_model and utility_model round-trip through TOML")
        func roundTripsGeneralModels() throws {
            var cfg = AppConfig()
            cfg.general.defaultModel = "openai:gpt-5"
            cfg.general.utilityModel = "deepseek:flash"
            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let encoded = try encoder.encode(cfg)
            let text = try #require(String(data: encoded, encoding: .utf8))
            #expect(text.contains("default_model"))
            #expect(text.contains("utility_model"))
            let decoded = try TOMLDecoder().decode(AppConfig.self, from: encoded)
            #expect(decoded.general.defaultModel == "openai:gpt-5")
            #expect(decoded.general.utilityModel == "deepseek:flash")
            #expect(AppConfig().general.defaultModel == nil)
        }

        @Test("AppConfig [providers] round-trips the active key of each provider")
        func roundTripsProviderKeys() throws {
            var cfg = AppConfig()
            cfg.providers = [
                "anthropic": "6F1C2B3A-0000-4000-8000-000000000001",
                "openai": "6F1C2B3A-0000-4000-8000-000000000002",
            ]
            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let encoded = try encoder.encode(cfg)
            let text = try #require(String(data: encoded, encoding: .utf8))
            #expect(text.contains("[providers]"))
            #expect(text.contains("anthropic = \"6F1C2B3A-0000-4000-8000-000000000001\""))
            let decoded = try TOMLDecoder().decode(AppConfig.self, from: encoded)
            #expect(decoded.providers == cfg.providers)
        }

        @Test("AppConfig without [providers] has no active keys, and an empty table survives a round trip")
        func providerKeysDefault() throws {
            #expect(AppConfig().providers.isEmpty)
            #expect(try TOMLDecoder().decode(AppConfig.self, from: Data("".utf8)).providers.isEmpty)

            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let decoded = try TOMLDecoder().decode(AppConfig.self, from: try encoder.encode(AppConfig()))
            #expect(decoded.providers.isEmpty)
        }

        @Test("AppConfig interface_scale round-trips through TOML")
        func roundTripsInterfaceScale() throws {
            var cfg = AppConfig()
            cfg.chatFeatures.interfaceScale = 125
            let encoder = TOMLEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let encoded = try encoder.encode(cfg)
            let text = try #require(String(data: encoded, encoding: .utf8))
            #expect(text.contains("interface_scale"))
            let decoded = try TOMLDecoder().decode(AppConfig.self, from: encoded)
            #expect(decoded.chatFeatures.interfaceScale == 125)
        }

        @Test("Interface scale defaults to 100 and clamps to the supported range")
        func normalizesInterfaceScale() throws {
            let toml = """
                [chat_features]
                interface_scale = 125.5
                """
            let decoded = try TOMLDecoder().decode(AppConfig.self, from: Data(toml.utf8))
            #expect(decoded.chatFeatures.interfaceScale == 125.5)
            #expect(ChatFeaturesConfig.normalizedInterfaceScale(nil) == 100)
            #expect(ChatFeaturesConfig.normalizedInterfaceScale(69) == 70)
            #expect(ChatFeaturesConfig.normalizedInterfaceScale(201) == 200)
            #expect(ChatFeaturesConfig.normalizedInterfaceScale(120) == 120)
        }

        // MARK: - Missing-key tolerance

        @Test("AppConfig decodes an empty TOML file with all defaults")
        func decodesEmptyFile() throws {
            // A completely empty file is valid TOML — every group is missing,
            // so all fields fall back to their defaults.
            let config = try TOMLDecoder().decode(AppConfig.self, from: Data("".utf8))
            #expect(config.general.defaultRole == nil)
            #expect(config.chatBehaviour.expandToolUse == nil)
            #expect(config.chatBehaviour.smoothStreaming == nil)
            #expect(config.chatFeatures.interfaceScale == nil)
            #expect(config.debug.appDebugEnabled == nil)
            #expect(config.window == nil)
        }

        @Test("smooth_streaming round-trips through [chat_behaviour]")
        func smoothStreamingKey() throws {
            let off = try TOMLDecoder().decode(
                AppConfig.self, from: Data("[chat_behaviour]\nsmooth_streaming = false\n".utf8))
            #expect(off.chatBehaviour.smoothStreaming == false)
            let on = try TOMLDecoder().decode(
                AppConfig.self, from: Data("[chat_behaviour]\nsmooth_streaming = true\n".utf8))
            #expect(on.chatBehaviour.smoothStreaming == true)
        }

        @Test("AppConfig decodes a partial config with only one group")
        func decodesPartialConfig() throws {
            // Only [general] is present — the other groups are missing and
            // must fall back to defaults without throwing.
            let toml = """
                [general]
                default_role = "Assistant"
                """
            let config = try TOMLDecoder().decode(AppConfig.self, from: Data(toml.utf8))
            #expect(config.general.defaultRole == "Assistant")
            #expect(config.chatBehaviour.expandToolUse == nil)
            #expect(config.chatFeatures.interfaceScale == nil)
            #expect(config.debug.appDebugEnabled == nil)
        }

        @Test("AppConfig decodes a group with missing keys, substituting defaults")
        func decodesGroupWithMissingKeys() throws {
            // [chat_behaviour] exists but has no keys (and a key of a removed
            // preference) — expand_tool_use must default to nil rather than throwing.
            let toml = """
                [chat_behaviour]
                expand_thinking = true
                """
            let config = try TOMLDecoder().decode(AppConfig.self, from: Data(toml.utf8))
            #expect(config.chatBehaviour.expandToolUse == nil)
        }

        @Test("AppConfig rejects invalid TOML syntax")
        func rejectsInvalidSyntax() throws {
            // Genuinely unparseable TOML must still throw — this is the only
            // case that should trigger the "failed to decode" overwrite path.
            let invalid = "[general\nbroken"
            #expect(throws: (any Error).self) {
                _ = try TOMLDecoder().decode(AppConfig.self, from: Data(invalid.utf8))
            }
        }

        // MARK: - Read missing

        @Test("reading a missing entity errors")
        func readMissing() async throws {
            let env = try TempEnv().env
            #expect(await call("read_mcp", env, ["name": "nope"]).isError)
            #expect(await call("read_role", env, ["name": "nope"]).isError)
            #expect(await call("read_prompt", env, ["name": "nope"]).isError)
        }

        // MARK: - Name validation

        @Test("names with spaces and special characters are accepted")
        func namesWithSpacesAndSpecialChars() async throws {
            let env = try TempEnv().env
            // A name with spaces and '&' — the case from the bug report.
            let res = await call(
                "write_mcp", env,
                [
                    "name": "Ultimate Google Docs & Sheets MCP Server",
                    "content": "transport = \"stdio\"\ncommand = \"echo\"\n",
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
            _ = await call("write_prompt", env, ["name": "Assistant", "content": "hi"])
            _ = await call("write_role", env, ["name": "Temp", "content": "prompt = \"Assistant\"\n"])
            _ = await call("write_prompt", env, ["name": "Temp", "content": "hi"])

            #expect(!(await call("delete_mcp", env, ["name": "Temp"])).isError)
            #expect(!(await call("delete_role", env, ["name": "Temp"])).isError)
            #expect(!(await call("delete_prompt", env, ["name": "Temp"])).isError)

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
            // Missing required "transport" → message must mention "transport".
            let mcp = await call("write_mcp", env, ["name": "x", "content": "command = \"echo\"\n"])
            #expect(mcp.isError)
            #expect(mcp.content.lowercased().contains("transport"))

            // Broken TOML syntax → message mentions invalid/syntax.
            let role = await call("write_role", env, ["name": "x", "content": "not = = valid"])
            #expect(role.isError)
            #expect(role.content.lowercased().contains("invalid"))
        }

        // MARK: - check_mcp_stdio

        @Test("check_mcp_stdio reports an error for a failing command")
        func mcpStdioCheckFails() async throws {
            let env = try TempEnv().env
            // A command that exits immediately with a non-zero status.
            let res = await call("check_mcp_stdio", env, ["command": "this-binary-does-not-exist-xyz"])
            #expect(res.isError)
        }

        @Test("check_mcp_stdio rejects an empty command")
        func mcpStdioCheckEmpty() async throws {
            let env = try TempEnv().env
            let res = await call("check_mcp_stdio", env, ["command": ""])
            #expect(res.isError)
            #expect(res.content.lowercased().contains("command"))
        }

        // MARK: - check_mcp_http

        @Test("check_mcp_http rejects an empty endpoint")
        func mcpHttpCheckEmpty() async throws {
            let env = try TempEnv().env
            let res = await call("check_mcp_http", env, ["endpoint": ""])
            #expect(res.isError)
            #expect(res.content.lowercased().contains("endpoint"))
        }

        @Test("check_mcp_http rejects an invalid endpoint URL")
        func mcpHttpCheckInvalidUrl() async throws {
            let env = try TempEnv().env
            let res = await call("check_mcp_http", env, ["endpoint": "not a url"])
            #expect(res.isError)
            #expect(res.content.lowercased().contains("valid"))
        }

        @Test("check_mcp_http errors on an unreachable endpoint")
        func mcpHttpCheckUnreachable() async throws {
            let env = try TempEnv().env
            // Port 1 is reserved/unbindable, so the connection should fail fast.
            let res = await call("check_mcp_http", env, ["endpoint": "http://127.0.0.1:1/mcp"])
            #expect(res.isError)
        }

        // MARK: - Applying changes

        /// Collects the `ConfigChange`s the tools report to the engine.
        private final class ChangeRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _changes: [ConfigChange] = []
            var changes: [ConfigChange] {
                lock.lock()
                defer { lock.unlock() }
                return _changes
            }
            func record(_ change: ConfigChange) {
                lock.lock()
                _changes.append(change)
                lock.unlock()
            }
        }

        private func callRecording(_ name: String, _ env: EnvironmentManager, _ dict: [String: String]) async
            -> (ToolResult, [ConfigChange])
        {
            let recorder = ChangeRecorder()
            let result = await ConfiguratorTools.call(
                name: name, arguments: args(dict), callID: "c", env: env, apply: { recorder.record($0) })
            return (result, recorder.changes)
        }

        @Test("successful writes and deletes report the matching change")
        func reportsChanges() async throws {
            let env = try TempEnv().env
            let cases: [(String, [String: String], ConfigChange)] = [
                (
                    "write_mcp", ["name": "Tavily", "content": "transport = \"stdio\"\ncommand = \"npx\"\n"],
                    .mcp("Tavily")
                ),
                ("write_prompt", ["name": "Greeter", "content": "Hi"], .prompt("Greeter")),
                ("write_role", ["name": "Coder", "content": "prompt = \"Greeter\"\n"], .role("Coder")),
                ("write_config", ["content": "[general]\ndefault_role = \"Assistant\"\n"], .config),
                ("delete_role", ["name": "Coder"], .role("Coder")),
                ("delete_prompt", ["name": "Greeter"], .prompt("Greeter")),
                ("delete_mcp", ["name": "Tavily"], .mcp("Tavily")),
            ]
            for (name, arguments, expected) in cases {
                let (result, changes) = await callRecording(name, env, arguments)
                #expect(!result.isError, "\(name): \(result.content)")
                #expect(changes == [expected], "\(name)")
            }
        }

        @Test("rejected and read-only calls report no change")
        func reportsNoChangeOnFailure() async throws {
            let env = try TempEnv().env
            let invalid = await callRecording("write_mcp", env, ["name": "bad", "content": "not = = toml"])
            #expect(invalid.0.isError)
            #expect(invalid.1.isEmpty)

            let missing = await callRecording("delete_prompt", env, ["name": "Ghost"])
            #expect(missing.0.isError)
            #expect(missing.1.isEmpty)

            let listed = await callRecording("list_mcps", env, [:])
            #expect(!listed.0.isError)
            #expect(listed.1.isEmpty)
        }
    }
}
