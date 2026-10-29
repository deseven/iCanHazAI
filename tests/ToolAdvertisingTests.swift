import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Tool advertising: shell description")
    struct ShellDescriptionTests {
        private static let shell = BuiltinTools.tools(for: BuiltinTools.shellGroup).first { $0.name == "shell" }!

        @Test("without file tools it keeps the generic hint")
        func noFileTools() {
            let desc = Self.shell.description(fileTags: false, available: ["shell", "calc"])
            #expect(desc.contains("Only use if other available tools"))
            #expect(!desc.contains("read_file"))
        }

        @Test("names exactly the dedicated file tools the chat has")
        func namesAvailableTools() {
            let all: Set<String> = [
                "shell", "ls", "read_file", "write_file", "find_file", "find_text", "replace_text", "edit_file",
            ]
            let desc = Self.shell.description(fileTags: true, available: all)
            for name in all where name != "shell" {
                #expect(desc.contains(name), "\(name) missing: \(desc)")
            }
            #expect(desc.contains("sed -i"))
            #expect(desc.contains("Lines seen only in shell output can't be edited with edit_file"))
            #expect(!desc.contains("Only use if other available tools"))

            let readOnly = Self.shell.description(fileTags: false, available: ["shell", "read_file"])
            #expect(readOnly.contains("read_file"))
            for name in ["find_text", "find_file", "replace_text", "edit_file", "write_file", "sed -i"] {
                #expect(!readOnly.contains(name), "\(name) mentioned: \(readOnly)")
            }

            let replaceOnly = Self.shell.description(fileTags: false, available: ["shell", "replace_text"])
            #expect(replaceOnly.contains("replace_text, never sed -i"))
            #expect(!replaceOnly.contains("edit_file"))
        }
    }

    @Suite("Tool advertising: engine")
    struct ToolAdvertisingEngineTests {
        private struct Harness {
            let engine: ChatEngine
            let temp: TempEnv
        }

        private static let roleTOML = """
            prompt = "P"

            [utils]
            tools = ["uuid", "calc"]

            [filesystem]
            tools = ["write_file", "read_file", "find_text"]

            [edit]

            [shell]
            tools = ["shell"]
            """

        private func harness() async throws -> Harness {
            let temp = try TempEnv()
            let registry = ProviderRegistry(store: InMemorySecretStore())
            try await registry.load()
            let catalog = ModelCatalog(
                registry: registry, store: ModelCatalogStore(),
                fetcher: StubFetcher { _ in .status(500) },
                metadata: StubMetadataSource(result: .failure(TestFailure())))
            let engine = ChatEngine(store: temp.store, env: temp.env, registry: registry, catalog: catalog)
            try "Hello".write(
                to: temp.env.promptsURL.appendingPathComponent("P.md"), atomically: true, encoding: .utf8)
            try Self.roleTOML.write(
                to: temp.env.rolesURL.appendingPathComponent("Dev.toml"), atomically: true, encoding: .utf8)
            await engine.applyConfigChange(.prompts)
            await engine.applyConfigChange(.roles)
            try temp.writeChatDirect(Fixtures.chat(messages: [Fixtures.message()], role: "Dev"), filename: "c.json")
            await engine.loadFromCache()
            await engine.ensureChatLoaded(filename: "c.json")
            return Harness(engine: engine, temp: temp)
        }

        @Test("tools are advertised by group in canonical order, sorted by name within each group")
        func order() async throws {
            let h = try await harness()
            let names = await h.engine.gatherTools(filename: "c.json").map(\.name)
            #expect(
                names == [
                    "calc", "uuid",
                    "find_text", "read_file", "write_file",
                    "edit_file", "replace_text",
                    "shell",
                ])
        }

        @Test("the shell description follows the chat's tools")
        func shellDescription() async throws {
            let h = try await harness()
            let shell = try #require(await h.engine.gatherTools(filename: "c.json").first { $0.name == "shell" })
            let desc = try #require(shell.description)
            #expect(desc.contains("find_text"))
            #expect(desc.contains("replace_text or edit_file"))
            #expect(!desc.contains("find_file"))
            let entry = try #require(
                await h.engine.toolSnapshot(filename: "c.json").builtin.first { $0.name == "shell" })
            #expect(entry.description == desc)
        }
    }
}
