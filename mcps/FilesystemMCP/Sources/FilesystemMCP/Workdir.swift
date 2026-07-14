import Foundation

/// Parses `--workdir <path>` and optional `--confine` from the command line.
///
/// `--workdir` sets the working directory: relative paths resolve against it
/// and it becomes the default search root. `--confine` (only meaningful with
/// `--workdir`) enables chroot-like confinement — the workdir becomes `/` for
/// the model, absolute paths are treated as relative to the root, and path
/// escapes are rejected. Without `--confine`, absolute paths are allowed as-is.
struct Workdir {
    let root: String?      // nil = no --workdir
    let confined: Bool     // true = --confine set (chroot-like)

    static let shared = Workdir.parse()

    private static func parse() -> Workdir {
        let args = CommandLine.arguments
        var workdir: String? = nil
        var confine = false
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
            if args[i] == "--confine" {
                confine = true
            }
            i += 1
        }
        return Workdir(root: workdir, confined: confine)
    }

    /// The "current directory" surfaced to the model in tool descriptions.
    /// `/` when confined (chroot illusion), the real workdir path when set,
    /// or the expanded home directory otherwise.
    var currentDirectory: String {
        if confined { return "/" }
        return root ?? NSHomeDirectory()
    }

    /// The filesystem base for resolving relative paths.
    private var base: String {
        root ?? NSHomeDirectory()
    }

    /// Resolve a model-supplied path to an absolute filesystem path. When
    /// confined, absolute paths are treated as relative to the workdir root
    /// (leading slash stripped) and escapes are rejected. When unconfined,
    /// absolute paths pass through and relative paths resolve against the base.
    func resolve(_ path: String) throws -> String {
        if confined, let root {
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

    /// The default search root for find_file/find_text. Returns the model-facing
    /// current directory so it round-trips correctly through `resolve()`: `/`
    /// when confined (the chroot illusion), the real workdir/home otherwise.
    var defaultRoot: String {
        currentDirectory
    }

    /// Directory-neutral path-argument description. Intentionally static so the
    /// real working-directory path is never baked into the tool descriptions
    /// (which are cached once at startup from an unconfined instance). The model
    /// discovers the live current directory via the `pwd` tool.
    var pathDescription: String {
        "Absolute or relative path, resolved against the current working directory."
    }

    /// Directory-neutral search-root description. See `pathDescription`.
    var searchRootDescription: String {
        "Directory to search in (absolute or relative to the current working directory). Defaults to the current working directory."
    }
}
