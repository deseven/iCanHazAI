import Foundation

/// Parses `--workdir <path>` and optional `--isolate` from the command line.
///
/// `--workdir` sets the working directory: relative paths resolve against it
/// and it becomes the default cwd for git. `--isolate` (only meaningful with
/// `--workdir`) enables chroot-like isolation — the workdir becomes `/` for
/// the model, absolute paths are treated as relative to the root, and path
/// escapes are rejected. Without `--isolate`, absolute paths are allowed as-is.
struct Workdir {
    let root: String?      // nil = no --workdir
    let isolated: Bool     // true = --isolate set (chroot-like)

    static let shared = Workdir.parse()

    private static func parse() -> Workdir {
        let args = CommandLine.arguments
        var workdir: String? = nil
        var isolate = false
        var i = args.startIndex
        while i < args.endIndex {
            if args[i] == "--workdir", i + 1 < args.endIndex {
                let raw = args[i + 1]
                let standardized = (raw as NSString).standardizingPath
                workdir = URL(fileURLWithPath: standardized)
                    .resolvingSymlinksInPath().path
                i += 2
                continue
            }
            if args[i] == "--isolate" {
                isolate = true
            }
            i += 1
        }
        return Workdir(root: workdir, isolated: isolate)
    }

    /// The "current directory" surfaced to the model in tool descriptions.
    /// `/` when isolated (chroot illusion), the real workdir path when set,
    /// or the expanded home directory otherwise.
    var currentDirectory: String {
        if isolated { return "/" }
        return root ?? NSHomeDirectory()
    }

    /// The filesystem base for resolving relative paths.
    private var base: String {
        root ?? NSHomeDirectory()
    }

    /// Resolve a model-supplied path to an absolute filesystem path. When
    /// isolated, absolute paths are treated as relative to the workdir root
    /// (leading slash stripped) and escapes are rejected. When not isolated,
    /// absolute paths pass through and relative paths resolve against the base.
    func resolve(_ path: String) throws -> String {
        if isolated, let root {
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let joined = (root as NSString).appendingPathComponent(relative)
            let standardized = (joined as NSString).standardizingPath
            let resolved = URL(fileURLWithPath: standardized)
                .resolvingSymlinksInPath().path
            guard resolved == root || resolved.hasPrefix(root + "/") else {
                throw ToolError.invalidArgument("path", "path escapes the workdir")
            }
            return resolved
        } else {
            if path.hasPrefix("/") {
                return (path as NSString).standardizingPath
            }
            let joined = (base as NSString).appendingPathComponent(path)
            return (joined as NSString).standardizingPath
        }
    }

    /// The default cwd for git: the workdir root, or `~` when unrestricted.
    var defaultCwd: String {
        root ?? NSHomeDirectory()
    }

    /// Neutral path-argument description mentioning the current directory.
    var pathDescription: String {
        "Absolute or relative path, resolved against the current directory (\(currentDirectory))."
    }
}
