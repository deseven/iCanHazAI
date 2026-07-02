import MCP
import Foundation
import CryptoKit

enum HashTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "hash",
            description: "Compute a cryptographic hash of a string. Returns a lowercase hex digest.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([
                    "input": obj([
                        "type": "string",
                        "description": "The string to hash."
                    ]),
                    "algorithm": obj([
                        "type": "string",
                        "enum": arr("sha256", "sha1", "md5"),
                        "description": "Hash algorithm. Defaults to sha256."
                    ])
                ]),
                "required": arr("input")
            ])
        ),
        handler: { args in
            let input = try requireString(args, "input")
            let algorithm = optionalString(args, "algorithm") ?? "sha256"
            let data = Data(input.utf8)
            let digest: String
            switch algorithm.lowercased() {
            case "sha256":
                digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "sha1":
                digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "md5":
                digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            default:
                throw ToolError.invalidArgument("algorithm", "must be sha256, sha1, or md5")
            }
            return textContent(digest)
        }
    )
}
