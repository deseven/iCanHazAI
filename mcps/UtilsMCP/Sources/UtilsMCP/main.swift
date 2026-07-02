import MCP
import Foundation

let server = Server(
    name: "ichai-utils",
    version: "0.1.0",
    capabilities: .init(tools: .init())
)

let tools: [ToolDefinition] = [
    CalcTool.definition,
    DateTimeTool.definition,
    UuidTool.definition,
    HashTool.definition,
    Base64EncodeTool.definition,
    Base64DecodeTool.definition,
    SleepTool.definition,
]

let dispatch: [String: @Sendable ([String: Value]) async throws -> [Tool.Content]] = Dictionary(
    uniqueKeysWithValues: tools.map { ($0.tool.name, $0.handler) }
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: tools.map(\.tool))
}

await server.withMethodHandler(CallTool.self) { params in
    guard let handler = dispatch[params.name] else {
        return CallTool.Result(
            content: textContent("Error: unknown tool '\(params.name)'"),
            isError: true
        )
    }
    let args = params.arguments ?? [:]
    do {
        let content = try await handler(args)
        return CallTool.Result(content: content)
    } catch let e as ToolError {
        return CallTool.Result(content: textContent("Error: \(e.description)"), isError: true)
    } catch {
        return CallTool.Result(content: textContent("Error: \(error)"), isError: true)
    }
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
