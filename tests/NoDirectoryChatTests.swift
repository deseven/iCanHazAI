import Foundation
import Testing

@testable import iCanHazAI

private struct Harness {
    let engine: ChatEngine
    let temp: TempEnv
}

private let optionalRole = """
    prompt = "P"
    working_directory_optional = true

    [utils]
    tools = ["calc"]

    [filesystem]
    tools = ["ls", "read_file"]

    [edit]

    [shell]
    tools = ["shell"]

    [web]
    tools = ["web_fetch"]
    """

private let requiredRole = optionalRole.replacingOccurrences(of: "working_directory_optional = true\n", with: "")

private func makeHarness(prompt: String = "Hello") async throws -> Harness {
    let temp = try TempEnv()
    let registry = ProviderRegistry(store: InMemorySecretStore())
    try await registry.load()
    let catalog = ModelCatalog(
        registry: registry, store: ModelCatalogStore(),
        fetcher: StubFetcher { _ in .status(500) },
        metadata: StubMetadataSource(result: .failure(TestFailure())))
    let engine = ChatEngine(store: temp.store, env: temp.env, registry: registry, catalog: catalog)
    try prompt.write(
        to: temp.env.promptsURL.appendingPathComponent("P.md"), atomically: true, encoding: .utf8)
    for (name, toml) in [("Optional", optionalRole), ("Required", requiredRole)] {
        try toml.write(
            to: temp.env.rolesURL.appendingPathComponent("\(name).toml"), atomically: true, encoding: .utf8)
    }
    await engine.applyConfigChange(.prompts)
    await engine.applyConfigChange(.roles)
    return Harness(engine: engine, temp: temp)
}

/// Writes a chat and loads it into the engine.
private func seed(_ h: Harness, _ chat: Chat, filename: String = "c.json") async throws {
    try h.temp.writeChatDirect(chat, filename: filename)
    await h.engine.loadFromCache()
    await h.engine.ensureChatLoaded(filename: filename)
}

private func loadedChat(_ h: Harness, filename: String = "c.json") async throws -> Chat {
    try #require(await h.engine.records.first(where: { $0.filename == filename })?.chat)
}

extension AllAppTests {
    @Suite("No directory chats")
    struct NoDirectoryChatTests {

        private func toolNames(_ h: Harness) async -> [String] {
            await h.engine.toolSnapshot(filename: "c.json").builtin.map(\.name)
        }

        @Test("without a choice every group of the role is advertised")
        func allToolsBeforeChoice() async throws {
            let h = try await makeHarness()
            try await seed(h, Fixtures.chat(messages: [Fixtures.message()], role: "Optional"))
            #expect(
                await toolNames(h) == ["calc", "edit_file", "ls", "read_file", "shell", "web_fetch"])
        }

        @Test("picking no directory removes Filesystem, Edit and Shell tools but keeps the rest")
        func noDirectoryRemovesDirectoryTools() async throws {
            let h = try await makeHarness()
            try await seed(
                h, Fixtures.chat(messages: [Fixtures.message()], role: "Optional", noWorkingDirectory: true))
            #expect(await toolNames(h) == ["calc", "web_fetch"])
        }

        @Test("a no-directory flag is ignored when the role doesn't allow it")
        func flagIgnoredForRequiredRole() async throws {
            let h = try await makeHarness()
            try await seed(
                h, Fixtures.chat(messages: [Fixtures.message()], role: "Required", noWorkingDirectory: true))
            #expect(
                await toolNames(h) == ["calc", "edit_file", "ls", "read_file", "shell", "web_fetch"])
        }

        @Test("setNoWorkingDirectory records the choice, persists it and drops the tools")
        func setNoWorkingDirectoryApplies() async throws {
            let h = try await makeHarness()
            try await seed(h, Fixtures.chat(messages: [Fixtures.message()], role: "Optional"))
            await h.engine.setNoWorkingDirectory(filename: "c.json")

            #expect(try await loadedChat(h).noWorkingDirectory == true)
            #expect(try h.temp.readChatDirect("c.json").noWorkingDirectory == true)
            #expect(await toolNames(h) == ["calc", "web_fetch"])
        }

        @Test("setNoWorkingDirectory is ignored once a directory is set or for roles that require one")
        func setNoWorkingDirectoryIgnored() async throws {
            let h = try await makeHarness()
            try await seed(
                h,
                Fixtures.chat(messages: [Fixtures.message()], role: "Optional", workingDirectory: "/tmp/proj"),
                filename: "picked.json")
            try await seed(
                h, Fixtures.chat(messages: [Fixtures.message()], role: "Required"), filename: "required.json")
            await h.engine.setNoWorkingDirectory(filename: "picked.json")
            await h.engine.setNoWorkingDirectory(filename: "required.json")

            #expect(try await loadedChat(h, filename: "picked.json").noWorkingDirectory == nil)
            #expect(try await loadedChat(h, filename: "required.json").noWorkingDirectory == nil)
        }

        @Test("the system prompt explains the missing directory and reads no files")
        func systemPromptExplainsAndSkipsFiles() async throws {
            let notes = try TestDirHelper.makeNotesFile(content: "secret notes")
            defer { try? FileManager.default.removeItem(atPath: notes.dir) }
            let h = try await makeHarness(
                prompt: "Dir: {current_directory}\nNotes: {load_first_available:\(notes.file)}")

            try await seed(
                h, Fixtures.chat(messages: [Fixtures.message()], role: "Optional", workingDirectory: notes.dir),
                filename: "dir.json")
            try await seed(
                h, Fixtures.chat(messages: [Fixtures.message()], role: "Optional", noWorkingDirectory: true),
                filename: "none.json")

            let withDir = try #require(
                await h.engine.systemMessage(for: try await loadedChat(h, filename: "dir.json")))
            #expect(withDir.content.contains("Dir: \(notes.dir)"))
            #expect(withDir.content.contains("secret notes"))

            let without = try #require(
                await h.engine.systemMessage(for: try await loadedChat(h, filename: "none.json")))
            #expect(without.content.contains(PromptVariables.noDirectoryNotice))
            #expect(!without.content.contains("secret notes"))
        }
    }
}

private enum TestDirHelper {
    /// A temp directory holding `NOTES.md`; returns its path and the file's absolute path.
    static func makeNotesFile(content: String) throws -> (dir: String, file: String) {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ichai-nodir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = (dir as NSString).appendingPathComponent("NOTES.md")
        try Data(content.utf8).write(to: URL(fileURLWithPath: file))
        return (dir, file)
    }
}
