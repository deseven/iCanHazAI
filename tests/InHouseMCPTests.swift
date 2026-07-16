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

            await MCPManager.shared.ensureInHouseRunning(chatFilename: chatA, servers: [("Utils", false)], workingDirectory: nil)
            await MCPManager.shared.ensureInHouseRunning(chatFilename: chatB, servers: [("Utils", false)], workingDirectory: nil)

            // Builtins must NOT live in the shared connection pool — they're
            // per-chat only.
            #expect(await MCPManager.shared.isConnected("Utils") == false)

            let resultA = await MCPManager.shared.callInHouseTool(
                chatFilename: chatA, server: "Utils", name: "calc",
                arguments: "{\"expression\":\"2+2\"}", callID: "a",
                workingDirectory: nil, directoryIsolation: false
            )
            #expect(!resultA.isError)
            #expect(resultA.content.trimmingCharacters(in: .whitespacesAndNewlines) == "4")

            let resultB = await MCPManager.shared.callInHouseTool(
                chatFilename: chatB, server: "Utils", name: "calc",
                arguments: "{\"expression\":\"3+3\"}", callID: "b",
                workingDirectory: nil, directoryIsolation: false
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
            await MCPManager.shared.ensureInHouseRunning(chatFilename: chat, servers: [("Utils", false)], workingDirectory: nil)
            // A tool call confirms the copy is alive.
            let r = await MCPManager.shared.callInHouseTool(
                chatFilename: chat, server: "Utils", name: "calc",
                arguments: "{\"expression\":\"1+1\"}", callID: "t",
                workingDirectory: nil, directoryIsolation: false
            )
            #expect(!r.isError)
            await MCPManager.shared.disconnectAllInHouse(chatFilename: chat)
            // After teardown, a call re-spawns a fresh copy (lazy) and still works.
            let r2 = await MCPManager.shared.callInHouseTool(
                chatFilename: chat, server: "Utils", name: "calc",
                arguments: "{\"expression\":\"5+5\"}", callID: "t2",
                workingDirectory: nil, directoryIsolation: false
            )
            #expect(!r2.isError)
            #expect(r2.content.trimmingCharacters(in: .whitespacesAndNewlines) == "10")
            await MCPManager.shared.disconnectAllInHouse(chatFilename: chat)
        }

        @Test("workdir + isolate are forwarded to a per-chat Filesystem copy")
        func workdirIsolateForwarded() async throws {
            let chat = "isolate.json"
            let tmp = try TempDir()
            _ = await MCPManager.shared.configure(MCPManager.builtinServers())
            defer { Task { await MCPManager.shared.disconnectAllInHouse(chatFilename: chat) } }

            // directoryIsolation = true → the copy launches with
            // `--workdir <tmp> --isolate`.
            await MCPManager.shared.ensureInHouseRunning(
                chatFilename: chat,
                servers: [("Filesystem", true)],
                workingDirectory: tmp.path
            )

            // --isolate: an absolute path is treated as relative to the root,
            // so "/isolated.txt" lands inside the workdir.
            let w = try await MCPManager.shared.callInHouseTool(
                chatFilename: chat, server: "Filesystem", name: "write_file",
                arguments: "{\"path\":\"/isolated.txt\",\"content\":\"x\"}", callID: "w",
                workingDirectory: tmp.path, directoryIsolation: true
            )
            #expect(!w.isError)
            #expect(tmp.exists("isolated.txt"))

            // Path escapes via .. are rejected under --isolate.
            let e = try await MCPManager.shared.callInHouseTool(
                chatFilename: chat, server: "Filesystem", name: "write_file",
                arguments: "{\"path\":\"../../escaped.txt\",\"content\":\"y\"}", callID: "e",
                workingDirectory: tmp.path, directoryIsolation: true
            )
            #expect(e.isError)
            #expect(e.content.contains("escapes"))

            await MCPManager.shared.disconnectAllInHouse(chatFilename: chat)
        }

        @Test("a ~ in the working directory is expanded before launching the copy")
        func tildeExpanded() async throws {
            let chat = "tilde.json"
            // Create a real dir under the home directory and reference it with
            // the `~` form, so we can assert the leading tilde is expanded
            // (an unexpanded `~/...` would resolve against CWD, not home).
            let basename = "ichai-tilde-test-\(UUID().uuidString)"
            let realPath = (NSHomeDirectory() as NSString).appendingPathComponent(basename)
            try FileManager.default.createDirectory(atPath: realPath, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: realPath) }

            _ = await MCPManager.shared.configure(MCPManager.builtinServers())
            defer { Task { await MCPManager.shared.disconnectAllInHouse(chatFilename: chat) } }

            // Pass the `~` form; --workdir (no isolate) makes relative paths
            // resolve against the expanded home-based dir.
            await MCPManager.shared.ensureInHouseRunning(
                chatFilename: chat,
                servers: [("Filesystem", false)],
                workingDirectory: "~/\(basename)"
            )

            let w = try await MCPManager.shared.callInHouseTool(
                chatFilename: chat, server: "Filesystem", name: "write_file",
                arguments: "{\"path\":\"rel.txt\",\"content\":\"hi\"}", callID: "w",
                workingDirectory: "~/\(basename)", directoryIsolation: false
            )
            #expect(!w.isError)
            let written = (realPath as NSString).appendingPathComponent("rel.txt")
            #expect(FileManager.default.fileExists(atPath: written))

            await MCPManager.shared.disconnectAllInHouse(chatFilename: chat)
        }
    }
}
