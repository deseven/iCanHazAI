import MCP
import Foundation

// Stub: starts the server and responds to initialize/ping, but exposes no
// tools yet. Tool implementations land in a later task.
let server = Server(
    name: "ichai-filesystem",
    version: "0.1.0",
    capabilities: .init(tools: .init())
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [])
}

await server.withMethodHandler(CallTool.self) { params in
    CallTool.Result(
        content: [.text(text: "Error: tool '\(params.name)' is not implemented", annotations: nil, _meta: nil)],
        isError: true
    )
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
