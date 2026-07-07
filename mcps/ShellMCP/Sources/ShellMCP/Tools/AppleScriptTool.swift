import MCP
import Foundation

enum AppleScriptTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "applescript",
            description: "Execute an AppleScript and return its result.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "script": obj([
                        "type": "string",
                        "description": "The AppleScript source to execute."
                    ])
                ]),
                "required": arr("script")
            ])
        ),
        handler: { args in
            let script = try requireString(args, "script")
            let appleScript = NSAppleScript(source: script)
            var errorInfo: NSDictionary?
            let output = appleScript?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
                let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
                return textContent("AppleScript error: \(message) (number \(number))")
            }
            let result = output?.stringValue ?? ""
            return textContent(result)
        }
    )
}
