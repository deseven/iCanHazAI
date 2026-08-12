import AppKit
import Foundation
import TOML
import Testing

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
                connection = "openai/DeepSeek"
                connection_override_allowed = true
                mcps_override_allowed = true
                directory_isolation = true

                [utils]
                tools = []
                auto_allow_all = true

                [filesystem]
                auto_allow = ["ls", "read_file", "stat"]

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
            #expect(config.connection == "openai/DeepSeek")
            #expect(config.connectionOverrideAllowed == true)
            #expect(config.mcpsOverrideAllowed == true)
            #expect(Role(name: "Developer", config: config).mcpsOverrideAllowed == true)
            // Built-in groups
            #expect(config.utils?.autoAllowAll == true)
            #expect(config.filesystem?.autoAllow == ["ls", "read_file", "stat"])
            #expect(config.directoryIsolation == true)
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
            #expect(role.mcpsOverrideAllowed == false)
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

        @Test("Role.hasDirectoryIsolation is true when directory_isolation is set at the top level")
        func hasDirectoryIsolationTrue() throws {
            let toml = """
                prompt = "Developer"
                working_directory = "~/projects"
                directory_isolation = true

                [filesystem]
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

        @Test("A group-level directory_isolation key is ignored (isolation is role-level)")
        func groupLevelIsolationKeyIgnored() throws {
            // Legacy placement: the key no longer exists on RoleToolGroup, so
            // the decoder simply skips it and the role stays non-isolated.
            let toml = """
                prompt = "Developer"
                working_directory = "~/projects"

                [filesystem]
                directory_isolation = true
                """
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

        // MARK: - Validation: directory_isolation requires Filesystem or Code

        @Test("Role validation rejects directory_isolation without an isolation-capable group")
        func validationRejectsIsolationWithoutCapableGroup() throws {
            for group in ["shell", "utils", "web"] {
                let toml = """
                    prompt = "Developer"
                    directory_isolation = true

                    [\(group)]
                    """
                let data = Data(toml.utf8)
                #expect(throws: ConfigValidationError.self, "expected rejection for [\(group)]-only role") {
                    try ConfigValidation.decodeRole(data)
                }
            }
        }

        @Test("Role validation accepts directory_isolation with Filesystem and a pre-set workdir")
        func validationAcceptsIsolationOnFilesystem() throws {
            let toml = """
                prompt = "Developer"
                working_directory = "~/projects"
                directory_isolation = true

                [filesystem]
                """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.directoryIsolation == true)
        }

        // MARK: - Validation: directory_isolation without a pre-set directory

        @Test("Role validation accepts directory_isolation without working_directory (user picks per chat)")
        func validationAcceptsIsolationWithoutWorkdir() throws {
            // Filesystem/Code always require a directory, so the user is
            // asked to pick one when the role doesn't pre-set it — isolation
            // without working_directory is fine.
            let toml = """
                prompt = "Developer"
                directory_isolation = true

                [filesystem]
                """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.directoryIsolation == true)
        }

        @Test("Role validation accepts directory_isolation with Code and without working_directory")
        func validationAcceptsIsolationOnCodeWithoutWorkdir() throws {
            let toml = """
                prompt = "Developer"
                directory_isolation = true

                [code]
                """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.directoryIsolation == true)
        }

        // MARK: - Validation: directory_isolation combined with the Shell group

        @Test("Role validation rejects directory_isolation when Shell is enabled")
        func validationRejectsIsolationWithShell() throws {
            for group in ["filesystem", "code"] {
                let toml = """
                    prompt = "Developer"
                    directory_isolation = true

                    [\(group)]

                    [shell]
                    """
                let data = Data(toml.utf8)
                #expect(throws: ConfigValidationError.self, "expected rejection for [\(group)] + [shell]") {
                    try ConfigValidation.decodeRole(data)
                }
            }
        }

        @Test("directory_isolation + Shell error explains the escape risk")
        func validationIsolationWithShellMessage() throws {
            let toml = """
                prompt = "Developer"
                directory_isolation = true

                [filesystem]

                [shell]
                """
            let data = Data(toml.utf8)
            do {
                _ = try ConfigValidation.decodeRole(data)
                Issue.record("expected validation to reject directory_isolation combined with Shell")
            } catch let error as ConfigValidationError {
                #expect(error.message.contains("Shell"))
                #expect(error.message.contains("NOT directory-isolated"))
                #expect(error.message.contains("escape"))
            }
        }

        @Test("Role validation accepts the Shell group without directory_isolation")
        func validationAcceptsShellWithoutIsolation() throws {
            let toml = """
                prompt = "Developer"

                [filesystem]

                [shell]
                """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.shell != nil)
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
            #expect(RoleAccent.nsColor(for: "Purple") == .systemPurple)  // case-insensitive
            #expect(RoleAccent.nsColor(for: "teal") == .systemTeal)
            #expect(RoleAccent.nsColor(for: "grey") == .systemGray)  // grey → gray
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

                [[mcps]]
                mcp = "Tavily"
                """
            try Data(roleTOML.utf8).write(to: env.env.rolesURL.appendingPathComponent("Tester.toml"))
            try Data("# You are a tester".utf8).write(to: env.env.promptsURL.appendingPathComponent("Tester.md"))
            // Role reference validation requires the MCP config to exist.
            try Data("transport = \"stdio\"\ncommand = \"echo hi\"\n".utf8)
                .write(to: env.env.mcpsURL.appendingPathComponent("Tavily.toml"))

            let roles = env.env.loadAllRoles()
            // The protected built-in configurator is always present from the
            // bundle; the user-defined "Tester" role is the only user role.
            #expect(roles.filter { !$0.isBuiltin }.count == 1)
            let role = try #require(roles.first(where: { $0.name == "Tester" }))
            #expect(role.name == "Tester")
            #expect(role.description == "Tester")
            // mcpCount covers custom MCPs only — the [utils] built-in group
            // is not an MCP server and is not counted.
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

        @Test("roleNeedsWorkdirPick is true with directory-relevant tools and no pre-set dir")
        func roleNeedsWorkdirPickTrue() throws {
            for group in ["filesystem", "code"] {
                let toml = """
                    prompt = "Developer"

                    [\(group)]
                    """
                let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
                let role = Role(name: "Developer", config: config)
                #expect(AppViewModel.roleNeedsWorkdirPick(role), "expected pick needed for [\(group)]")
            }
        }

        @Test("roleNeedsWorkdirPick is false when a working directory is pre-set")
        func roleNeedsWorkdirPickFalsePresetDir() throws {
            let toml = """
                prompt = "Developer"
                working_directory = "~/projects"

                [filesystem]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.roleNeedsWorkdirPick(role))
        }

        @Test("roleNeedsWorkdirPick is false for Shell-only roles (home is fine)")
        func roleNeedsWorkdirPickFalseShellOnly() throws {
            let toml = """
                prompt = "Developer"

                [shell]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.roleNeedsWorkdirPick(role))
        }

        @Test("roleNeedsWorkdirPick is false with no directory-relevant tools")
        func roleNeedsWorkdirPickFalseNoRelevantTools() throws {
            let toml = """
                prompt = "Developer"

                [utils]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.roleNeedsWorkdirPick(role))
        }

        // MARK: - hasDirectoryRelevantTools

        @Test("Role.hasDirectoryRelevantTools is true for Filesystem and Code")
        func hasDirectoryRelevantToolsTrue() throws {
            for group in ["filesystem", "code"] {
                let toml = """
                    prompt = "Developer"

                    [\(group)]
                    """
                let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
                let role = Role(name: "Developer", config: config)
                #expect(role.hasDirectoryRelevantTools, "expected directory-relevant for [\(group)]")
            }
        }

        @Test("Role.hasDirectoryRelevantTools is false for Shell and Utils")
        func hasDirectoryRelevantToolsFalse() throws {
            for group in ["shell", "utils"] {
                let toml = """
                    prompt = "Developer"

                    [\(group)]
                    """
                let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
                let role = Role(name: "Developer", config: config)
                #expect(!role.hasDirectoryRelevantTools, "expected not directory-relevant for [\(group)]")
            }
        }

        // MARK: - Role picker feature badges (bindsToDirectory / hasShellTools / hasWebTools)

        @Test("Role.bindsToDirectory is true for workdir-capable groups (Filesystem, Code, Shell)")
        func bindsToDirectoryTrue() throws {
            for group in ["filesystem", "code", "shell"] {
                let toml = """
                    prompt = "Developer"

                    [\(group)]
                    """
                let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
                let role = Role(name: "Developer", config: config)
                #expect(role.bindsToDirectory, "expected bindsToDirectory for [\(group)]")
            }
        }

        @Test("Role.bindsToDirectory is false for non-workdir groups (Utils, Web) and no groups")
        func bindsToDirectoryFalse() throws {
            for group in ["utils", "web"] {
                let toml = """
                    prompt = "Developer"

                    [\(group)]
                    """
                let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
                let role = Role(name: "Developer", config: config)
                #expect(!role.bindsToDirectory, "expected not bindsToDirectory for [\(group)]")
            }
            let toml = """
                prompt = "Developer"
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!role.bindsToDirectory)
        }

        @Test("Role.hasShellTools is true only when the Shell group is enabled")
        func hasShellTools() throws {
            let withShell = """
                prompt = "Developer"

                [shell]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(withShell.utf8))
            #expect(Role(name: "Developer", config: config).hasShellTools)

            let withoutShell = """
                prompt = "Developer"

                [filesystem]
                """
            let config2 = try TOMLDecoder().decode(RoleConfig.self, from: Data(withoutShell.utf8))
            #expect(!Role(name: "Developer", config: config2).hasShellTools)
        }

        @Test("Role.hasWebTools is true only when the Web group is enabled")
        func hasWebTools() throws {
            let withWeb = """
                prompt = "Developer"

                [web]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(withWeb.utf8))
            #expect(Role(name: "Developer", config: config).hasWebTools)

            let withoutWeb = """
                prompt = "Developer"

                [utils]
                """
            let config2 = try TOMLDecoder().decode(RoleConfig.self, from: Data(withoutWeb.utf8))
            #expect(!Role(name: "Developer", config: config2).hasWebTools)
        }

        // MARK: - shell_whitelist

        @Test("RoleConfig decodes shell_whitelist under [shell]")
        func decodesShellWhitelist() throws {
            let toml = """
                prompt = "Developer"

                [shell]
                tools = ["shell"]
                shell_whitelist = ["ls", "cat", "grep", "find", "stat", "file", "curl", "cd", "pwd", "head", "tail"]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let shell = try #require(config.shell)
            #expect(
                shell.shellWhitelist == [
                    "ls", "cat", "grep", "find", "stat", "file", "curl", "cd", "pwd", "head", "tail",
                ])
        }

        @Test("RoleConfig decodes [shell] without shell_whitelist (nil default)")
        func shellWhitelistNilDefault() throws {
            let toml = """
                prompt = "Developer"

                [shell]
                tools = ["shell"]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let shell = try #require(config.shell)
            #expect(shell.shellWhitelist == nil)
        }

        // MARK: - workdirPickerEnabled (pick permanence)

        /// A role with directory-relevant tools and no pre-set directory.
        private func pickerRole() throws -> Role {
            let toml = """
                prompt = "Developer"

                [filesystem]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            return Role(name: "Developer", config: config)
        }

        @Test("workdirPickerEnabled is true while the chat has no directory")
        func pickerEnabledBeforePick() throws {
            let role = try pickerRole()
            #expect(AppViewModel.workdirPickerEnabled(role: role, chatWorkingDirectory: nil))
            #expect(AppViewModel.workdirPickerEnabled(role: role, chatWorkingDirectory: ""))
        }

        @Test("workdirPickerEnabled is false once a directory is picked (permanent)")
        func pickerDisabledAfterPick() throws {
            let role = try pickerRole()
            #expect(!AppViewModel.workdirPickerEnabled(role: role, chatWorkingDirectory: "/tmp/proj"))
            #expect(!AppViewModel.workdirPickerEnabled(role: role, chatWorkingDirectory: "nas:/var/www"))
        }

        @Test("workdirPickerEnabled is false when the role pre-sets a directory")
        func pickerDisabledForPresetRole() throws {
            let toml = """
                prompt = "Developer"
                working_directory = "~/projects"

                [filesystem]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.workdirPickerEnabled(role: role, chatWorkingDirectory: nil))
        }

        @Test("workdirPickerEnabled is false for roles without directory-relevant tools")
        func pickerDisabledForShellOnly() throws {
            let toml = """
                prompt = "Developer"

                [shell]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.workdirPickerEnabled(role: role, chatWorkingDirectory: nil))
        }

        // MARK: - workdirPickerVisible (toolbar control)

        /// A Filesystem role with a pre-set working directory.
        private func presetRole(_ dir: String) throws -> Role {
            let toml = """
                prompt = "Developer"
                working_directory = "\(dir)"

                [filesystem]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            return Role(name: "Developer", config: config)
        }

        @Test("workdirPickerVisible is true for a pre-set non-home directory")
        func pickerVisibleForPresetDir() throws {
            #expect(AppViewModel.workdirPickerVisible(role: try presetRole("/tmp/proj")))
            #expect(AppViewModel.workdirPickerVisible(role: try presetRole("~/projects")))
            #expect(AppViewModel.workdirPickerVisible(role: try presetRole("nas:/var/www")))
        }

        @Test("workdirPickerVisible is false when the role pre-sets the home directory")
        func pickerHiddenForHomePreset() throws {
            #expect(!AppViewModel.workdirPickerVisible(role: try presetRole("~")))
            #expect(!AppViewModel.workdirPickerVisible(role: try presetRole("~/")))
            #expect(!AppViewModel.workdirPickerVisible(role: try presetRole(NSHomeDirectory())))
        }

        @Test("workdirPickerVisible is true with directory-relevant tools and no pre-set dir")
        func pickerVisibleForPickerRole() throws {
            #expect(AppViewModel.workdirPickerVisible(role: try pickerRole()))
        }

        @Test("workdirPickerVisible is false without directory-relevant tools and no pre-set dir")
        func pickerVisibleForShellOnly() throws {
            let toml = """
                prompt = "Developer"

                [shell]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let role = Role(name: "Developer", config: config)
            #expect(!AppViewModel.workdirPickerVisible(role: role))
        }

        @Test("isHomeWorkdir recognizes home in tilde and expanded forms only")
        func isHomeWorkdirForms() {
            #expect(AppViewModel.isHomeWorkdir("~"))
            #expect(AppViewModel.isHomeWorkdir("~/"))
            #expect(AppViewModel.isHomeWorkdir(NSHomeDirectory()))
            #expect(!AppViewModel.isHomeWorkdir("/tmp"))
            #expect(!AppViewModel.isHomeWorkdir("~/projects"))
            #expect(!AppViewModel.isHomeWorkdir("nas:/var/www"))
        }

        // MARK: - workdirIcon (toolbar symbol)

        @Test("workdirIcon is questionmark.folder when no directory is picked")
        func workdirIconNoDirectory() {
            #expect(AppViewModel.workdirIcon(directory: nil, isolated: false) == "questionmark.folder")
            #expect(AppViewModel.workdirIcon(directory: "", isolated: false) == "questionmark.folder")
            // Isolation doesn't matter until a directory is picked.
            #expect(AppViewModel.workdirIcon(directory: nil, isolated: true) == "questionmark.folder")
        }

        @Test("workdirIcon is folder.circle for an isolated directory")
        func workdirIconIsolated() {
            #expect(AppViewModel.workdirIcon(directory: "/tmp/proj", isolated: true) == "folder.circle")
        }

        @Test("workdirIcon is folder for a non-isolated directory")
        func workdirIconPlain() {
            #expect(AppViewModel.workdirIcon(directory: "/tmp/proj", isolated: false) == "folder")
        }

        // MARK: - [features] table

        @Test("RoleConfig decodes a [features] table")
        func decodesFeatures() throws {
            let toml = """
                prompt = "Assistant"

                [features]
                with_attachments = true
                with_response_regen = true
                with_chat_trees = true
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let features = try #require(config.features)
            #expect(features.withAttachments == true)
            #expect(features.withResponseRegen == true)
            #expect(features.withChatTrees == true)
            let role = Role(name: "Assistant", config: config)
            #expect(role.hasAttachments)
            #expect(role.hasResponseRegen)
            #expect(role.hasChatTrees)
        }

        @Test("RoleConfig decodes a partial [features] table (omitted keys default to nil)")
        func decodesPartialFeatures() throws {
            let toml = """
                prompt = "Assistant"

                [features]
                with_attachments = true
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let features = try #require(config.features)
            #expect(features.withAttachments == true)
            #expect(features.withResponseRegen == nil)
            #expect(features.withChatTrees == nil)
            let role = Role(name: "Assistant", config: config)
            #expect(role.hasAttachments)
            #expect(!role.hasResponseRegen)
            #expect(!role.hasChatTrees)
        }

        @Test("RoleConfig with no [features] table leaves all features off")
        func noFeaturesTable() throws {
            let toml = """
                prompt = "Assistant"
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            #expect(config.features == nil)
            let role = Role(name: "Assistant", config: config)
            #expect(!role.hasAttachments)
            #expect(!role.hasResponseRegen)
            #expect(!role.hasChatTrees)
        }

        @Test("An empty [features] table leaves all features off")
        func emptyFeaturesTable() throws {
            let toml = """
                prompt = "Assistant"

                [features]
                """
            let config = try TOMLDecoder().decode(RoleConfig.self, from: Data(toml.utf8))
            let features = try #require(config.features)
            #expect(features.withAttachments == nil)
            #expect(features.withResponseRegen == nil)
            #expect(features.withChatTrees == nil)
            let role = Role(name: "Assistant", config: config)
            #expect(!role.hasAttachments)
            #expect(!role.hasResponseRegen)
            #expect(!role.hasChatTrees)
        }

        @Test("Role validation rejects with_chat_trees without with_response_regen")
        func validationRejectsTreesWithoutRegen() throws {
            let toml = """
                prompt = "Assistant"

                [features]
                with_chat_trees = true
                """
            let data = Data(toml.utf8)
            #expect(throws: ConfigValidationError.self) {
                try ConfigValidation.decodeRole(data)
            }
        }

        @Test("Role validation accepts with_chat_trees with with_response_regen")
        func validationAcceptsTreesWithRegen() throws {
            let toml = """
                prompt = "Assistant"

                [features]
                with_response_regen = true
                with_chat_trees = true
                """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.features?.withChatTrees == true)
            #expect(config.features?.withResponseRegen == true)
        }

        @Test("Role validation accepts with_response_regen without with_chat_trees")
        func validationAcceptsRegenWithoutTrees() throws {
            let toml = """
                prompt = "Assistant"

                [features]
                with_response_regen = true
                """
            let data = Data(toml.utf8)
            let config = try ConfigValidation.decodeRole(data)
            #expect(config.features?.withResponseRegen == true)
            #expect(config.features?.withChatTrees == nil)
        }

        @Test("trees-without-regen error explains the requirement")
        func treesWithoutRegenMessage() throws {
            let toml = """
                prompt = "Assistant"

                [features]
                with_chat_trees = true
                """
            let data = Data(toml.utf8)
            do {
                _ = try ConfigValidation.decodeRole(data)
                Issue.record("expected validation to reject with_chat_trees without with_response_regen")
            } catch let error as ConfigValidationError {
                #expect(error.message.contains("with_chat_trees"))
                #expect(error.message.contains("with_response_regen"))
            }
        }
    }
}

/// A throwable used to skip a test when a precondition (e.g. a bundled
/// resource isn't available in the test environment) isn't met.
private enum SnapshotSkip: Error { case skip }
