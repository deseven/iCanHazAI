import Foundation

/// Parses `--workdir <path>` from the command line. The Shell MCP does **no
/// path confinement** — the workdir only sets the default working directory
/// for `shell`/`shell_background` commands. `--confine` is not supported.
enum WorkdirConfig {
    /// The default working directory for commands, or the expanded home
    /// directory when `--workdir` is absent.
    static let `default`: String = {
        let args = CommandLine.arguments
        var i = args.startIndex
        while i < args.endIndex {
            if args[i] == "--workdir", i + 1 < args.endIndex {
                let raw = args[i + 1]
                let standardized = (raw as NSString).standardizingPath
                return URL(fileURLWithPath: standardized)
                    .resolvingSymlinksInPath().path
            }
            i += 1
        }
        return NSHomeDirectory()
    }()

    /// The "current directory" surfaced to the model in tool descriptions.
    static var currentDirectory: String { `default` }
}
