import Testing
import Foundation
@testable import iCanHazAI

/// Integration tests for the in-house (builtin) MCP server handling in
/// [`MCPManager`](src/MCPManager.swift): the always-present builtin list, and
/// the per-chat copy lifecycle (`ensureInHouseRunning` / `callInHouseTool`).
///
/// These drive the real `MCPManager.shared` singleton against the bundled
/// UtilsMCP binary, so they're nested under `AllMCPTests` (serialized). Each
/// test that spawns per-chat copies awaits its own teardown before returning.
extension AllMCPTests {

    @Suite("In-house MCPs", .serialized, .timeLimit(.minutes(1)))
    struct InHouseMCPTests {

        // MARK: - builtin registry

        @Test("builtinServers lists the four in-house servers")
        func builtinRegistry() async throws {
            let servers = MCPManager.builtinServers()
            // Servers whose binary is missing are omitted; in the test env the
            // SwiftPM build output is present, so all four should resolve.
            #expect(servers.count == 4)
            let names = Set(servers.map(\.name))
            #expect(names == ["Utils", "Filesystem", "Code", "Shell"])
            for s in servers {
                #expect(s.isBuiltin)
                #expect(s.transport == .stdio)
                #expect(s.runPolicy == .onDemand)
                #expect(s.command?.isEmpty == false)
            }
        }

        @Test("builtins expose tools without a prefix")
        func builtinPrefixes() async throws {
            let prefixes = MCPManager.builtinServers().map(\.prefix)
            // In-house tools are exposed under their own names (no namespacing).
            #expect(prefixes.allSatisfy { $0.isEmpty })
        }

        // MARK: - per-chat copies

        @Test("two chats get independent per-chat copies of the same server")
        func perChatIsolation() async throws {
            let chatA = "chatA.json"
            let chatB = "chatB.json"
            // Builtins must be configured (tool list cached) before use.
            _ = await MCPManager.shared.configure(MCPManager.builtinServers())
            defer {
                // Best-effort; the awaited teardown below is the real one.
                Task { await MCPManager.shared.disconnectAllInHouse(chatFilename: chatA) }
                Task { await MCPManager.shared.disconnectAllInHouse(chatFilename: chatB) }
            }

            #expect(await MCPManager.shared.cachedTools(for: "Utils")?.isEmpty == false)

            await MCPManager.shared.ensureInHouseRunning(chatFilename: chatA, names: ["Utils"])
            await MCPManager.shared.ensureInHouseRunning(chatFilename: chatB, names: ["Utils"])

            // Builtins must NOT live in the shared connection pool — they're
            // per-chat only.
            #expect(await MCPManager.shared.isConnected("Utils") == false)

            let resultA = await MCPManager.shared.callInHouseTool(
                chatFilename: chatA, server: "Utils", name: "calc",
                arguments: "{\"expression\":\"2+2\"}", callID: "a"
            )
            #expect(!resultA.isError)
            #expect(resultA.content.trimmingCharacters(in: .whitespacesAndNewlines) == "4")

            let resultB = await MCPManager.shared.callInHouseTool(
                chatFilename: chatB, server: "Utils", name: "calc",
                arguments: "{\"expression\":\"3+3\"}", callID: "b"
            )
            #expect(!resultB.isError)
            #expect(resultB.content.trimmingCharacters(in: .whitespacesAndNewlines) == "6")

            await MCPManager.shared.disconnectAllInHouse(chatFilename: chatA)
            await MCPManager.shared.disconnectAllInHouse(chatFilename: chatB)
        }

        @Test("disconnectAllInHouse tears down a chat's copies")
        func perChatTeardown() async throws {
            let chat = "teardown.json"
            _ = await MCPManager.shared.configure(MCPManager.builtinServers())
            await MCPManager.shared.ensureInHouseRunning(chatFilename: chat, names: ["Utils"])
            // A tool call confirms the copy is alive.
            let r = await MCPManager.shared.callInHouseTool(
                chatFilename: chat, server: "Utils", name: "calc",
                arguments: "{\"expression\":\"1+1\"}", callID: "t"
            )
            #expect(!r.isError)
            await MCPManager.shared.disconnectAllInHouse(chatFilename: chat)
            // After teardown, a call re-spawns a fresh copy (lazy) and still works.
            let r2 = await MCPManager.shared.callInHouseTool(
                chatFilename: chat, server: "Utils", name: "calc",
                arguments: "{\"expression\":\"5+5\"}", callID: "t2"
            )
            #expect(!r2.isError)
            #expect(r2.content.trimmingCharacters(in: .whitespacesAndNewlines) == "10")
            await MCPManager.shared.disconnectAllInHouse(chatFilename: chat)
        }
    }
}
