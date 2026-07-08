import MCP
import Foundation

enum CalcTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "calc",
            description: "Evaluate a mathematical expression using bc syntax (e.g. '2+2*3' or 'sqrt(16)'). Loads the bc math library so sqrt, s, c, l, e are available.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "expression": obj([
                        "type": "string",
                        "description": "The mathematical expression to evaluate, e.g. '2+2*3' or 'sqrt(16)'. Uses bc syntax."
                    ])
                ]),
                "required": arr("expression")
            ])
        ),
        handler: { args in
            let expression = try requireString(args, "expression")
            let result = try await ShellRunner.run(launchPath: "/usr/bin/bc", arguments: ["-l"], stdin: expression + "\n")
            if result.exitCode != 0 {
                throw ToolError.invalidArgument("expression", "bc failed: \(result.stderr)")
            }
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw ToolError.invalidArgument("expression", "bc returned no output")
            }
            return textContent(trimmed)
        }
    )
}
