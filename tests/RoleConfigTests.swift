import Foundation
import AppKit
import Testing
import TOML
@testable import iCanHazAI

// Tests for the TOML-based role config, prompt loading, and default seeding.
extension AllAppTests {
    @Suite("Role config")
    struct RoleConfigTests {
        @Test("RoleConfig decodes all fields from TOML")
        func decodesFullConfig() throws {
            let toml = """
            description = "A special developer role."
            prompt = "Developer"
            prompt_override_allowed = false
            working_directory = "~/projects/MyProject"
            working_directory_override_allowed = true
            connection = "openai/DeepSeek"
            connection_override_allowed = true

            [[mcps]]
            mcp = "internal::Utils"
            tools = []
            auto_allow_all = true

            [[mcps]]
            mcp = "internal::Filesystem"
            auto_allow = ["ls", "read_file", "stat"]
            directory_isolation = true

            [[mcps]]
            mcp = "Tavily"
            tools = ["tavily_search", "tavily_extract"]
            auto_allow = ["tavily_search"]
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            #expect(config.description == "A special developer role.")
            #expect(config.prompt == "Developer")
            #expect(config.promptOverrideAllowed == false)
            #expect(config.workingDirectory == "~/projects/MyProject")
            #expect(config.workingDirectoryOverrideAllowed == true)
            #expect(config.connection == "openai/DeepSeek")
            #expect(config.connectionOverrideAllowed == true)
            let mcps = try #require(config.mcps)
            #expect(mcps.count == 3)
            #expect(mcps[0].mcp == "internal::Utils")
            #expect(mcps[0].autoAllowAll == true)
            #expect(mcps[1].mcp == "internal::Filesystem")
            #expect(mcps[1].autoAllow == ["ls", "read_file", "stat"])
            #expect(mcps[1].directoryIsolation == true)
            #expect(mcps[2].mcp == "Tavily")
            #expect(mcps[2].tools == ["tavily_search", "tavily_extract"])
        }

        @Test("RoleConfig applies defaults for omitted optional fields")
        func decodesMinimalConfig() throws {
            let toml = """
            prompt = "Assistant"
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Assistant", config: config)
            #expect(role.description == "No description.")
            #expect(role.promptOverrideAllowed == false)
            #expect(role.connectionOverrideAllowed == false)
            #expect(role.workingDirectoryOverrideAllowed == false)
            #expect(role.mcpCount == 0)
            // No icon set → falls back to the generic default.
            #expect(role.icon == Role.defaultIcon)
        }

        @Test("RoleConfig decodes a custom icon and Role exposes it")
        func decodesIcon() throws {
            let toml = """
            prompt = "Developer"
            icon = "hammer"
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(config.icon == "hammer")
            #expect(role.icon == "hammer")
        }

        @Test("RoleConfig decodes an accent alias and Role exposes it")
        func decodesAccent() throws {
            let toml = """
            prompt = "Developer"
            accent = "purple"
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(config.accent == "purple")
            #expect(role.accentColor == RoleAccent.color(for: "purple"))
        }

        @Test("RoleAccent resolves known aliases to system colors and falls back for unknown")
        func accentResolution() throws {
            // Known aliases resolve to the matching adaptive system color.
            #expect(RoleAccent.nsColor(for: "blue") == .systemBlue)
            #expect(RoleAccent.nsColor(for: "Purple") == .systemPurple) // case-insensitive
            #expect(RoleAccent.nsColor(for: "teal") == .systemTeal)
            #expect(RoleAccent.nsColor(for: "grey") == .systemGray) // grey → gray
            // Absent or unrecognized aliases resolve to nil (caller falls back
            // to the macOS accent color).
            #expect(RoleAccent.nsColor(for: nil) == nil)
            #expect(RoleAccent.nsColor(for: "notacolor") == nil)
            // Every advertised supported alias must resolve.
            for alias in RoleAccent.supportedAliases {
                #expect(RoleAccent.nsColor(for: alias) != nil)
            }
        }

        @Test("EnvironmentManager loads a role TOML and prompt from disk")
        func loadsRoleAndPrompt() throws {
            let env = try TempEnv()
            let roleTOML = """
            description = "Tester"
            prompt = "Tester"

            [[mcps]]
            mcp = "internal::Utils"
            auto_allow_all = true
            """
            try Data(roleTOML.utf8).write(to: env.env.rolesURL.appendingPathComponent("Tester.toml"))
            try Data("# You are a tester".utf8).write(to: env.env.promptsURL.appendingPathComponent("Tester.md"))

            let roles = env.env.loadAllRoles()
            // The protected built-in configurator is always present from the
            // bundle; the user-defined "Tester" role is the only user role.
            #expect(roles.filter { !$0.isBuiltin }.count == 1)
            let role = try #require(roles.first(where: { $0.name == "Tester" }))
            #expect(role.name == "Tester")
            #expect(role.description == "Tester")
            #expect(role.mcpCount == 1)

            let prompt = try #require(env.env.loadSinglePrompt(name: "Tester"))
            #expect(prompt.content == "# You are a tester")

            // loadSingleRole returns the same decoded config.
            let single = try #require(env.env.loadSingleRole(name: "Tester"))
            #expect(single.name == "Tester")
        }

        @Test("seedDefaults copies missing bundled prompts and roles")
        func seedDefaultsCopiesFiles() throws {
            // Seed only works when the bundled/default `default/` directory can
            // be located (it is in the repo root). Skip gracefully if not found.
            guard EnvironmentManager.defaultResourceDir("roles") != nil else {
                throw SnapshotSkip.skip
            }
            let env = try TempEnv()
            // Directories exist but are empty of user roles. The protected
            // built-in configurator is always available from the bundle, even
            // before seeding, so it's the only thing present.
            let preRoles = env.env.loadAllRoles()
            let prePrompts = env.env.loadAllPrompts()
            #expect(preRoles.filter { !$0.isBuiltin }.isEmpty)
            #expect(prePrompts.filter { !$0.isBuiltin }.isEmpty)
            #expect(preRoles.contains(where: { $0.name == "Configurator" && $0.isBuiltin }))
            #expect(prePrompts.contains(where: { $0.name == "Configurator" && $0.isBuiltin }))

            env.env.seedDefaults()
            let roles = env.env.loadAllRoles()
            let prompts = env.env.loadAllPrompts()
            #expect(!roles.isEmpty)
            #expect(!prompts.isEmpty)
            // The bundled Developer role and Developer prompt should be present.
            #expect(roles.contains(where: { $0.name == "Developer" }))
            #expect(prompts.contains(where: { $0.name == "Developer" }))
            // The protected configurator must NOT be copied into the user
            // directory — it stays in the bundle.
            let fm = FileManager.default
            #expect(!fm.fileExists(atPath: env.env.rolesURL.appendingPathComponent("Configurator.toml").path))
            #expect(!fm.fileExists(atPath: env.env.promptsURL.appendingPathComponent("Configurator.md").path))

            // Re-seeding must not overwrite user edits: mutate a file, re-seed,
            // and confirm the mutation survives.
            let devRoleURL = env.env.rolesURL.appendingPathComponent("Developer.toml")
            try Data("description = \"edited\"\nprompt = \"Developer\"\n".utf8)
                .write(to: devRoleURL)
            env.env.seedDefaults()
            let edited = try #require(env.env.loadSingleRole(name: "Developer"))
            #expect(edited.description == "edited")
        }

        @Test("Protected built-in ignores a user shadow file")
        func protectedBuiltinIgnoresShadow() throws {
            // Requires the bundled `default/` directory (repo root).
            guard EnvironmentManager.defaultResourceDir("roles") != nil else {
                throw SnapshotSkip.skip
            }
            let env = try TempEnv()

            // The configurator is available from the bundle before any seeding.
            let bundled = try #require(env.env.loadSingleRole(name: "Configurator"))
            #expect(bundled.isBuiltin)
            let bundledDescription = bundled.description

            // A user creates a shadow role with the same name. It must be
            // ignored — the bundled version always wins.
            let shadowURL = env.env.rolesURL.appendingPathComponent("Configurator.toml")
            try Data("description = \"shadow\"\nprompt = \"Configurator\"\n".utf8)
                .write(to: shadowURL)

            let roles = env.env.loadAllRoles()
            // Exactly one configurator entry, and it's the built-in one.
            #expect(roles.filter { $0.name == "Configurator" }.count == 1)
            let loaded = try #require(roles.first(where: { $0.name == "Configurator" }))
            #expect(loaded.isBuiltin)
            #expect(loaded.description == bundledDescription)
            #expect(loaded.description != "shadow")

            // loadSingleRole also resolves to the bundled version.
            let single = try #require(env.env.loadSingleRole(name: "Configurator"))
            #expect(single.isBuiltin)
            #expect(single.description == bundledDescription)

            // Same protection applies to the prompt.
            let shadowPrompt = env.env.promptsURL.appendingPathComponent("Configurator.md")
            try Data("# shadow prompt".utf8).write(to: shadowPrompt)
            let prompt = try #require(env.env.loadSinglePrompt(name: "Configurator"))
            #expect(prompt.isBuiltin)
            #expect(prompt.content != "# shadow prompt")
        }
    }
}

/// A throwable used to skip a test when a precondition (e.g. a bundled
/// resource isn't available in the test environment) isn't met.
private enum SnapshotSkip: Error { case skip }
