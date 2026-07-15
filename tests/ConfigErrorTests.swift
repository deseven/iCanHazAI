import Foundation
import Testing
@testable import iCanHazAI

// Tests for the configuration-error gathering flow: the `ConfigError` model,
// the configurator message formatting, and the error-reporting loader variants
// in `EnvironmentManager`.
extension AllAppTests {
    @Suite("Config errors")
    struct ConfigErrorTests {

        // MARK: - Model

        @Test("ConfigError id is stable from kind + entity name")
        func idIsStableFromKindAndName() {
            let a = ConfigError(kind: .connection, entityName: "openai/gpt-5", message: "x")
            let b = ConfigError(kind: .connection, entityName: "openai/gpt-5", message: "different message")
            #expect(a.id == b.id)
            let c = ConfigError(kind: .role, entityName: "openai/gpt-5", message: "x")
            #expect(a.id != c.id)
            let d = ConfigError(kind: .mcpFailure, entityName: "MyMCP", message: "boom")
            #expect(d.id == "mcpFailure:MyMCP")
        }

        @Test("configuratorLine formats each kind")
        func configuratorLineFormats() {
            let conn = ConfigError(kind: .connection, entityName: "openai/gpt-5", message: "Missing model")
            #expect(conn.configuratorLine == #"Connection `openai/gpt-5` is invalid (error: "Missing model")."#)
            let role = ConfigError(kind: .role, entityName: "MyRole", message: "Prompt MyPrompt not found")
            #expect(role.configuratorLine == #"Role `MyRole` is invalid (error: "Prompt MyPrompt not found")."#)
            let mcpCfg = ConfigError(kind: .mcpConfig, entityName: "MyMCP", message: "bad toml")
            #expect(mcpCfg.configuratorLine == #"MCP server `MyMCP` has an invalid config (error: "bad toml")."#)
            let mcpFail = ConfigError(kind: .mcpFailure, entityName: "MyMCP", message: "zsh: command not found: nodefdg")
            #expect(mcpFail.configuratorLine == #"MCP server `MyMCP` failed on startup (error: "zsh: command not found: nodefdg")."#)
        }

        @Test("configuratorMessage numbers errors with a header")
        func configuratorMessageNumbers() {
            let errors = [
                ConfigError(kind: .connection, entityName: "openai/gpt-5", message: "Missing model"),
                ConfigError(kind: .role, entityName: "MyRole", message: "Prompt MyPrompt not found"),
                ConfigError(kind: .mcpFailure, entityName: "MyMCP", message: "zsh: command not found: nodefdg"),
            ]
            let message = AppViewModel.configuratorMessage(for: errors)
            #expect(message == """
            Please investigate the following problems and propose solutions:
            1. Connection `openai/gpt-5` is invalid (error: "Missing model").
            2. Role `MyRole` is invalid (error: "Prompt MyPrompt not found").
            3. MCP server `MyMCP` failed on startup (error: "zsh: command not found: nodefdg").
            """)
        }

        // MARK: - Reporting loaders

        @Test("loadConnectionsReportingErrors surfaces undecodable connections")
        func connectionsReportErrors() throws {
            let env = try TempEnv()
            // A valid connection and a broken one (missing required `model`).
            try Data(#"{"model":"gpt-4o"}"#.utf8)
                .write(to: env.env.openaiConnectionsURL.appendingPathComponent("good.jsonc"))
            try Data(#"{"apiKey":"sk-x"}"#.utf8)
                .write(to: env.env.openaiConnectionsURL.appendingPathComponent("bad.jsonc"))

            let result = env.env.loadConnectionsReportingErrors()
            #expect(result.loaded.count == 1)
            #expect(result.loaded.first?.id == "openai/good")
            #expect(result.errors.count == 1)
            let err = try #require(result.errors.first)
            #expect(err.kind == .connection)
            #expect(err.entityName == "openai/bad")
        }

        @Test("loadAllRolesReportingErrors surfaces undecodable roles")
        func rolesReportErrors() throws {
            let env = try TempEnv()
            try Data("description = \"ok\"\nprompt = \"Assistant\"\n".utf8)
                .write(to: env.env.rolesURL.appendingPathComponent("Good.toml"))
            // Broken TOML: unterminated string → decode failure.
            try Data("description = \"broken\n".utf8)
                .write(to: env.env.rolesURL.appendingPathComponent("Broken.toml"))

            let result = env.env.loadAllRolesReportingErrors()
            let userRoles = result.loaded.filter { !$0.isBuiltin }
            #expect(userRoles.count == 1)
            #expect(userRoles.first?.name == "Good")
            #expect(result.errors.count == 1)
            let err = try #require(result.errors.first)
            #expect(err.kind == .role)
            #expect(err.entityName == "Broken")
        }

        @Test("loadSingleRoleReportingError returns nil+nil for missing, error for broken")
        func singleRoleReporting() throws {
            let env = try TempEnv()
            // Missing file → (nil, nil).
            let missing = env.env.loadSingleRoleReportingError(name: "Nope")
            #expect(missing.role == nil)
            #expect(missing.error == nil)
            // Broken file → (nil, error).
            try Data("description = \"broken\n".utf8)
                .write(to: env.env.rolesURL.appendingPathComponent("Broken.toml"))
            let broken = env.env.loadSingleRoleReportingError(name: "Broken")
            #expect(broken.role == nil)
            #expect(broken.error?.kind == .role)
            #expect(broken.error?.entityName == "Broken")
            // Valid file → (role, nil).
            try Data("description = \"ok\"\nprompt = \"Assistant\"\n".utf8)
                .write(to: env.env.rolesURL.appendingPathComponent("Good.toml"))
            let good = env.env.loadSingleRoleReportingError(name: "Good")
            #expect(good.role?.name == "Good")
            #expect(good.error == nil)
        }

        @Test("loadMCPsReportingErrors surfaces undecodable MCP configs")
        func mcpsReportErrors() throws {
            let env = try TempEnv()
            try Data("transport = \"stdio\"\ncommand = \"echo hi\"\n".utf8)
                .write(to: env.env.mcpsURL.appendingPathComponent("Good.toml"))
            try Data("transport = broken\n".utf8)
                .write(to: env.env.mcpsURL.appendingPathComponent("Broken.toml"))

            let result = env.env.loadMCPsReportingErrors()
            #expect(result.loaded.count == 1)
            #expect(result.loaded.first?.name == "Good")
            #expect(result.errors.count == 1)
            let err = try #require(result.errors.first)
            #expect(err.kind == .mcpConfig)
            #expect(err.entityName == "Broken")
        }

        @Test("loadSingleMCPReportingError returns nil+nil for missing, error for broken")
        func singleMCPReporting() throws {
            let env = try TempEnv()
            let missing = env.env.loadSingleMCPReportingError(name: "Nope")
            #expect(missing.server == nil)
            #expect(missing.error == nil)
            try Data("transport = broken\n".utf8)
                .write(to: env.env.mcpsURL.appendingPathComponent("Broken.toml"))
            let broken = env.env.loadSingleMCPReportingError(name: "Broken")
            #expect(broken.server == nil)
            #expect(broken.error?.kind == .mcpConfig)
        }

        @Test("fixing a broken file clears its error on the next load")
        func fixingClearsError() throws {
            let env = try TempEnv()
            let url = env.env.openaiConnectionsURL.appendingPathComponent("bad.jsonc")
            try Data(#"{"apiKey":"sk-x"}"#.utf8).write(to: url)
            #expect(env.env.loadConnectionsReportingErrors().errors.count == 1)
            // Overwrite with a valid config.
            try Data(#"{"model":"gpt-4o"}"#.utf8).write(to: url)
            let result = env.env.loadConnectionsReportingErrors()
            #expect(result.errors.isEmpty)
            #expect(result.loaded.count == 1)
        }

        @Test("removing a broken file clears its error on the next load")
        func removingClearsError() throws {
            let env = try TempEnv()
            let url = env.env.mcpsURL.appendingPathComponent("bad.toml")
            try Data("transport = broken\n".utf8).write(to: url)
            #expect(env.env.loadMCPsReportingErrors().errors.count == 1)
            try? FileManager.default.removeItem(at: url)
            let result = env.env.loadMCPsReportingErrors()
            #expect(result.errors.isEmpty)
            #expect(result.loaded.isEmpty)
        }
    }
}
