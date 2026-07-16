import MCP
import Foundation

/// Returns the current working directory as seen by the file tools. When the
/// server runs isolated (`--isolate`), this returns `/` (the chroot illusion)
/// so the real working-directory path is never exposed to the model; otherwise
/// it returns the real working directory (or the home directory when no
/// `--workdir` was given).
enum PwdTool {
    static let definition = ToolDefinition(
        tool: Tool(
            name: "pwd",
            description: "Return the current working directory.",
            inputSchema: obj([
                "type": "object",
                "properties": obj([:]),
                "required": arr()
            ])
        ),
        handler: { _ in
            textContent(Workdir.shared.currentDirectory)
        }
    )
}
