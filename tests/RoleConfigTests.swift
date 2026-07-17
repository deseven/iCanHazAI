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

            [utils]
            tools = []
            auto_allow_all = true

            [filesystem]
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
            // Built-in groups
            #expect(config.utils?.autoAllowAll == true)
            #expect(config.filesystem?.autoAllow == ["ls", "read_file", "stat"])
            #expect(config.filesystem?.directoryIsolation == true)
            // Custom MCPs
            let mcps = try #require(config.mcps)
            #expect(mcps.count == 1)
            #expect(mcps[0].mcp == "Tavily")
            #expect(mcps[0].tools == ["tavily_search", "tavily_extract"])
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

        @Test("Role.hasWorkdirCapableMCP is true when a workdir-capable group is selected")
        func hasWorkdirCapableMCPTrue() throws {
            let toml = """
            prompt = "Developer"

            [utils]
            auto_allow_all = true

            [filesystem]
            directory_isolation = true
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(role.hasWorkdirCapableMCP)
        }

        @Test("Role.hasWorkdirCapableMCP is true for Code and Shell groups")
        func hasWorkdirCapableMCPCodeShell() throws {
            for group in ["code", "shell"] {
                let toml = """
                prompt = "Developer"

                [\(group)]
                """
                let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
                let role = Role(name: "Developer", config: config)
                #expect(role.hasWorkdirCapableMCP, "expected hasWorkdirCapableMCP for [\(group)]")
            }
        }

        @Test("Role.hasWorkdirCapableMCP is false when only non-workdir groups are selected")
        func hasWorkdirCapableMCPFalse() throws {
            // Utils is internal but doesn't use the working directory.
            let toml = """
            prompt = "Developer"

            [utils]
            auto_allow_all = true
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!role.hasWorkdirCapableMCP)
        }

        @Test("Role.hasWorkdirCapableMCP is false when no groups are selected")
        func hasWorkdirCapableMCPFalseNoGroups() throws {
            let toml = """
            prompt = "Developer"
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!role.hasWorkdirCapableMCP)
        }

        @Test("Role.hasWorkdirCapableMCP is false for custom (non-group) MCPs only")
        func hasWorkdirCapableMCPFalseCustom() throws {
            let toml = """
            prompt = "Developer"

            [[mcps]]
            mcp = "Tavily"
            tools = ["tavily_search"]
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!role.hasWorkdirCapableMCP)
        }

        // MARK: - hasDirectoryIsolation

        @Test("Role.hasDirectoryIsolation is true when Filesystem has directory_isolation")
        func hasDirectoryIsolationFilesystem() throws {
            let toml = """
            prompt = "Developer"
            working_directory = "~/projects"

            [filesystem]
            directory_isolation = true
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(role.hasDirectoryIsolation)
        }

        @Test("Role.hasDirectoryIsolation is true when Code has directory_isolation")
        func hasDirectoryIsolationCode() throws {
            let toml = """
            prompt = "Developer"
            working_directory_override_allowed = true

            [code]
            directory_isolation = true
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(role.hasDirectoryIsolation)
        }

        @Test("Role.hasDirectoryIsolation is false when directory_isolation is not set")
        func hasDirectoryIsolationFalseWhenNotSet() throws {
            let toml = """
            prompt = "Developer"
            working_directory = "~/projects"

            [filesystem]
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!role.hasDirectoryIsolation)
        }

        @Test("Role.hasDirectoryIsolation is false for Shell (not isolation-capable)")
        func hasDirectoryIsolationFalseForShell() throws {
            let toml = """
            prompt = "Developer"
            working_directory = "~/projects"

            [shell]
            directory_isolation = true
            """
            // Note: this TOML decodes fine (validation is in ConfigValidation,
            // not in the TOML decoder). hasDirectoryIsolation checks the
            // isolation-capable set, so Shell's flag is ignored.
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!role.hasDirectoryIsolation)
        }

        // MARK: - Validation: working_directory without workdir-capable group

        @Test("Role validation rejects working_directory without workdir-capable group")
        func validationRejectsWorkdirWithoutCapableGroup() throws {
            let toml = """
            prompt = "Developer"
            working_directory = "~/projects"

            [utils]
            auto_allow_all = true
            """
            let data = Data(toml.utf8)
            #expect(throws: ConfigValidationError.self) {
                try ConfigValidation.decodeRole(data)
            }
        }

        @Test("Role validation rejects working_directory_override_allowed without workdir-capable group")
        func validationRejectsOverrideWithoutCapableGroup() throws {
            let toml = """
            prompt = "Developer"
            working_directory_override_allowed = true

            [utils]
            auto_allow_all = true
            """
            let data = Data(toml.utf8)
            #expect(throws: ConfigValidationError.self) {
                try ConfigValidation.decodeRole(data)
            }
        }

        @Test("Role validation accepts working_directory with workdir-capable group")
        func validationAcceptsWorkdirWithCapableGroup() throws {
            let toml = """
            prompt = "Developer"
            working_directory = "~/projects"

            [filesystem]
            """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.workingDirectory == "~/projects")
        }

        // MARK: - Validation: directory_isolation on wrong group

        @Test("Role validation rejects directory_isolation on Shell")
        func validationRejectsIsolationOnShell() throws {
            let toml = """
            prompt = "Developer"
            working_directory = "~/projects"

            [shell]
            directory_isolation = true
            """
            let data = Data(toml.utf8)
            #expect(throws: ConfigValidationError.self) {
                try ConfigValidation.decodeRole(data)
            }
        }

        @Test("Role validation accepts directory_isolation on Filesystem with workdir")
        func validationAcceptsIsolationOnFilesystem() throws {
            let toml = """
            prompt = "Developer"
            working_directory = "~/projects"

            [filesystem]
            directory_isolation = true
            """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.filesystem?.directoryIsolation == true)
        }

        // MARK: - Validation: directory_isolation without working directory

        @Test("Role validation rejects directory_isolation without any workdir source")
        func validationRejectsIsolationWithoutWorkdir() throws {
            let toml = """
            prompt = "Developer"

            [filesystem]
            directory_isolation = true
            """
            let data = Data(toml.utf8)
            #expect(throws: ConfigValidationError.self) {
                try ConfigValidation.decodeRole(data)
            }
        }

        @Test("Role validation accepts directory_isolation with override allowed")
        func validationAcceptsIsolationWithOverride() throws {
            let toml = """
            prompt = "Developer"
            working_directory_override_allowed = true

            [code]
            directory_isolation = true
            """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.code?.directoryIsolation == true)
        }

        // MARK: - Validation: bundled role (Configurator) goes through validation

        @Test("bundledRole returns nil for an invalid protected built-in")
        func bundledRoleValidation() throws {
            // The Configurator role is bundled and protected. It has no groups
            // and no working_directory, so it must pass validation (no rules
            // are triggered). We verify it loads successfully.
            let role = try #require(EnvironmentManager.bundledRole(name: "Configurator"))
            #expect(role.name == "Configurator")
            #expect(!role.hasWorkdirCapableMCP)
            #expect(!role.hasDirectoryIsolation)
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

            [utils]
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

        // MARK: - roleNeedsWorkdirPick

        @Test("roleNeedsWorkdirPick is true when override allowed, no preset dir, workdir-capable MCP")
        func roleNeedsWorkdirPickTrue() throws {
            let toml = """
            prompt = "Developer"
            working_directory_override_allowed = true

            [filesystem]
            directory_isolation = true
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(AppViewModel.roleNeedsWorkdirPick(role))
        }

        @Test("roleNeedsWorkdirPick is false when a working directory is pre-set")
        func roleNeedsWorkdirPickFalsePresetDir() throws {
            let toml = """
            prompt = "Developer"
            working_directory = "~/projects"
            working_directory_override_allowed = true

            [filesystem]
            directory_isolation = true
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.roleNeedsWorkdirPick(role))
        }

        @Test("roleNeedsWorkdirPick is false when overrides are not allowed")
        func roleNeedsWorkdirPickFalseNoOverride() throws {
            let toml = """
            prompt = "Developer"

            [filesystem]
            directory_isolation = true
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.roleNeedsWorkdirPick(role))
        }

        @Test("roleNeedsWorkdirPick is false when no workdir-capable MCP")
        func roleNeedsWorkdirPickFalseNoCapableMCP() throws {
            let toml = """
            prompt = "Developer"
            working_directory_override_allowed = true
            """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.roleNeedsWorkdirPick(role))
        }
    }
}

/// A throwable used to skip a test when a precondition (e.g. a bundled
/// resource isn't available in the test environment) isn't met.
private enum SnapshotSkip: Error { case skip }
