import Foundation
import Testing
@testable import iCanHazAI

// Tests for `MCPManager`'s connection-establishment safeguards. A server that
// accepts the transport but never answers the MCP `initialize` handshake
// (e.g. stuck on interactive authorization) must time out, be left
// disconnected, and have its stdio subprocess killed — instead of hanging the
// configuration flow (and the loader overlay) forever.
extension AllAppTests {
    @Suite("MCP manager")
    struct MCPManagerTests {
        @Test("stdio server that never answers initialize times out and is left disconnected")
        func handshakeTimeout() async throws {
            let manager = MCPManager.shared
            await manager.setConnectTimeout(0.5)

            // `sleep 60` launches fine (passes the startup grace) but never
            // speaks MCP, so the initialize handshake hangs until the watchdog
            // fires.
            let server = MCPServer(
                name: "__hang_test__",
                prefix: "",
                transport: .stdio,
                runPolicy: .alwaysOn,
                command: "sleep 60",
                endpoint: nil,
                token: nil,
                tools: nil
            )

            let start = Date()
            var caught: Error? = nil
            do {
                _ = try await manager.connectAndListTools(server)
            } catch {
                caught = error
            }
            let elapsed = Date().timeIntervalSince(start)
            await manager.setConnectTimeout(10)

            guard let caught else {
                Issue.record("expected initializationTimeout, but connectAndListTools succeeded")
                return
            }
            guard case MCPManagerError.initializationTimeout(let name, _) = caught else {
                Issue.record("expected initializationTimeout, got \(caught)")
                return
            }
            #expect(name == "__hang_test__")
            // The default timeout is 10s; with 0.5s configured, the whole flow
            // (1s startup grace + timeout + teardown) must finish well under it.
            #expect(elapsed < 8)
            // The server must not be left connected, and its tools must not be
            // cached — it is marked unavailable and later calls move on.
            #expect(await !manager.isConnected("__hang_test__"))
            #expect(await manager.cachedTools(for: "__hang_test__") == nil)
        }

        @Test("initializationTimeout error message mentions the server and the timeout")
        func timeoutErrorDescription() {
            let error = MCPManagerError.initializationTimeout("Docs", 10)
            #expect(error.localizedDescription.contains("\"Docs\""))
            #expect(error.localizedDescription.contains("10s"))
        }
    }
}
