// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Argument-aware `shell_whitelist` entries (`sed:read`, `find:read`, `git:read`).
///
/// A bare entry (`sed`) trusts every invocation of a command. A template entry
/// (`sed:read`) trusts only invocations whose arguments match a small allow-list
/// of read-only shapes, covering the common BSD and GNU usage. Anything that is
/// not recognised is "unknown" and falls back to the approval prompt, so the
/// validators only ever answer "known read-only" — they never try to prove that
/// an arbitrary command line is safe.
///
/// Segments with redirections, `$` expansion or brace expansion are never
/// matched (see `ShellSegment.argsAreLiteral`).
enum ShellTemplates {
    typealias Validator = @Sendable ([String]) -> Bool

    static let validators: [String: Validator] = [
        "sed:read": SedReadValidator.allows,
        "find:read": FindReadValidator.allows,
        "git:read": GitReadValidator.allows,
    ]

    static func allows(_ segment: ShellSegment, whitelist: Set<String>) -> Bool {
        guard segment.argsAreLiteral else { return false }
        let prefix = segment.command + ":"
        return validators.contains { name, validator in
            name.hasPrefix(prefix) && whitelist.contains(name) && validator(segment.args)
        }
    }
}

// MARK: - sed:read

/// `sed [-n] [-E|-r] [-e] SCRIPT [file...]` where SCRIPT is a `;`-separated
/// list of `[addr[,addr]][!]cmd` with `cmd` in `p d q =` and `addr` a line
/// number, `$` or `/literal-ish regex/`. Everything else (`s`, `w`, `e`, `r`,
/// `y`, blocks, labels, `-i`, `-f`, `-s`, `-z`...) is unknown.
enum SedReadValidator {
    private static let regexChars = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _.*^$()+?|{},:=<>\"'@#%&~!;-")
    /// Only these may follow a backslash, so an escaped delimiter or an
    /// escape that the two sed flavours read differently can't sneak in.
    private static let escapable = Set(#".*^$()+?|{}<>-[]bBwWsS\"#)

    static func allows(_ args: [String]) -> Bool {
        var scripts: [String] = []
        var positionals: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            if ["--quiet", "--silent", "--regexp-extended"].contains(arg) { continue }
            guard arg.hasPrefix("-"), arg.count > 1 else {
                positionals.append(arg)
                continue
            }
            let cluster = Array(arg.dropFirst())
            for (index, flag) in cluster.enumerated() {
                switch flag {
                case "n", "E", "r":
                    continue
                case "e":
                    guard index == cluster.count - 1, i < args.count else { return false }
                    scripts.append(args[i])
                    i += 1
                default:
                    return false
                }
            }
        }
        if scripts.isEmpty {
            guard !positionals.isEmpty else { return false }
            scripts.append(positionals.removeFirst())
        }
        return scripts.allSatisfy(isReadOnlyScript)
    }

    private static func isReadOnlyScript(_ script: String) -> Bool {
        let s = Array(script)
        var i = 0
        var commands = 0

        func skipBlanks() {
            while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
        }
        func isDigit(_ c: Character) -> Bool { ("0"..."9").contains(c) }

        enum Address { case none, ok, malformed }
        func address() -> Address {
            guard i < s.count else { return .none }
            if s[i] == "$" {
                i += 1
                return .ok
            }
            if isDigit(s[i]) {
                let start = i
                while i < s.count, isDigit(s[i]) { i += 1 }
                return i - start <= 9 ? .ok : .malformed
            }
            guard s[i] == "/" else { return .none }
            i += 1
            var length = 0
            while i < s.count {
                let c = s[i]
                if c == "/" {
                    i += 1
                    return length > 0 ? .ok : .malformed
                }
                if c == "\\" {
                    guard i + 1 < s.count, escapable.contains(s[i + 1]) else { return .malformed }
                    i += 2
                } else {
                    guard regexChars.contains(c) else { return .malformed }
                    i += 1
                }
                length += 1
            }
            return .malformed
        }

        while true {
            skipBlanks()
            guard i < s.count else { break }
            switch address() {
            case .malformed:
                return false
            case .ok:
                skipBlanks()
                if i < s.count, s[i] == "," {
                    i += 1
                    skipBlanks()
                    guard address() == .ok else { return false }
                }
            case .none:
                break
            }
            skipBlanks()
            if i < s.count, s[i] == "!" {
                i += 1
                skipBlanks()
            }
            guard i < s.count, "pdq=".contains(s[i]) else { return false }
            i += 1
            commands += 1
            skipBlanks()
            guard i < s.count else { break }
            guard s[i] == ";" else { return false }
            i += 1
        }
        return commands > 0
    }
}

// MARK: - find:read

/// `find` with only known non-mutating options, tests and actions. Primaries
/// that run commands or write files (`-exec`, `-execdir`, `-ok`, `-okdir`,
/// `-delete`, `-fprint*`, `-fls`) are simply not in the allow-list. Each
/// value-taking primary consumes exactly one argument, mirroring find itself,
/// so a value can never be mistaken for a primary or vice versa.
enum FindReadValidator {
    private static let options = words("-H -L -P -E -s -x -d")
    private static let valueless = words(
        """
        -print -print0 -ls -prune -true -false -empty -readable -writable -executable \
        -nouser -nogroup -mount -xdev -follow -depth -daystart -quit -noleaf \
        -a -and -o -or -not
        """)
    private static let valued = words(
        """
        -name -iname -path -ipath -wholename -iwholename -regex -iregex -lname -ilname \
        -type -xtype -size -perm -user -group -uid -gid -links -inum -samefile \
        -newer -anewer -cnewer -mtime -atime -ctime -mmin -amin -cmin \
        -maxdepth -mindepth -regextype -printf
        """)

    static func allows(_ args: [String]) -> Bool {
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            // Paths, `!`, `(` and `)` don't start with a dash.
            guard arg.hasPrefix("-"), arg.count > 1 else { continue }
            if options.contains(arg) || valueless.contains(arg) { continue }
            if valued.contains(arg) || isNewerXY(arg) {
                guard i < args.count else { return false }
                i += 1
                continue
            }
            return false
        }
        return true
    }

    /// `-newerXY` (e.g. `-newermt DATE`) with X, Y in `a c B m t`.
    private static func isNewerXY(_ arg: String) -> Bool {
        guard arg.hasPrefix("-newer"), arg.count == 8 else { return false }
        return arg.dropFirst(6).allSatisfy { "acBmt".contains($0) }
    }
}

// MARK: - git:read

/// Read-only `git` subcommands with a per-subcommand flag allow-list. Global
/// options that can run code (`-c`, `--exec-path`, `--git-dir`...) are not
/// accepted; neither are flags that write (`--output`), run configured tools
/// (`--ext-diff`, `--textconv`, `-O` on grep) or open a pager.
///
/// Like any git invocation this trusts the repository's own config
/// (`core.fsmonitor`, `diff.external`, ...), which can itself run commands.
enum GitReadValidator {
    private enum Positionals {
        case any
        case none
        /// Allowed only together with one of these flags (e.g. `git branch
        /// --list PATTERN` lists, `git branch NAME` creates).
        case onlyWithAny(Set<String>)
    }

    private struct Rules {
        /// Exact flags without a value.
        var flags: Set<String> = []
        /// Long flags taking `--name=value`.
        var attached: Set<String> = []
        /// Short flags taking a value, attached (`-n5`) or as the next argument.
        var separate: Set<String> = []
        var positionals: Positionals = .any
        /// `-<number>` as in `git log -20`.
        var countShorthand = false
        var anyFlag = false
    }

    private static let diffFlags = words(
        """
        -p -u --patch -s --no-patch --stat --shortstat --numstat --summary \
        --name-only --name-status --raw --compact-summary --check --minimal --patience \
        --histogram --no-color --color --no-ext-diff --no-textconv --full-index --binary \
        -w -b --ignore-all-space --ignore-space-change --ignore-blank-lines \
        --ignore-space-at-eol -R -M -C --find-renames --find-copies --no-renames \
        --word-diff --color-words --text -a -W --function-context --exit-code --relative
        """)
    private static let diffAttached = words(
        """
        --stat --unified --word-diff --color --abbrev --diff-filter --relative \
        --find-renames --find-copies --dirstat --color-moved --color-words \
        --inter-hunk-context --diff-algorithm
        """)
    private static let logFlags = words(
        """
        --oneline --graph --decorate --no-decorate --all --branches --tags --remotes \
        --no-merges --merges --first-parent --follow --abbrev-commit --no-abbrev-commit \
        --reverse --date-order --topo-order --author-date-order --left-right --cherry-pick \
        --boundary --full-history --simplify-by-decoration --use-mailmap --no-walk \
        -i --regexp-ignore-case -E --extended-regexp -F --fixed-strings --all-match --invert-grep
        """)
    private static let logAttached = words(
        """
        --pretty --format --max-count --skip --since --until --after --before --author \
        --committer --grep --date --decorate --min-parents --max-parents
        """)

    private static let rules: [String: Rules] = [
        "status": Rules(
            flags: words(
                """
                -s -sb --short -b --branch --porcelain --long -v --verbose --ignored --show-stash \
                --ahead-behind --no-ahead-behind --renames --no-renames -z -u -uno -unormal -uall \
                --untracked-files
                """),
            attached: words("--porcelain --untracked-files --ignored")),
        "diff": Rules(
            flags: diffFlags.union(words("--cached --staged --merge-base --no-index")),
            attached: diffAttached,
            separate: words("-U -S -G")),
        "log": Rules(
            flags: diffFlags.union(logFlags),
            attached: diffAttached.union(logAttached),
            separate: words("-U -S -G -n -L"),
            countShorthand: true),
        "show": Rules(
            flags: diffFlags.union(words("--oneline --abbrev-commit --no-abbrev-commit --decorate --no-decorate")),
            attached: diffAttached.union(words("--pretty --format --date")),
            separate: words("-U -S -G"),
            countShorthand: true),
        "blame": Rules(
            flags: words(
                """
                -w -M -C -e --show-email -s -l -t -f --show-name -n --show-number --porcelain \
                --line-porcelain --incremental --root --first-parent -p
                """),
            attached: words("--date --since"),
            separate: words("-L")),
        "branch": Rules(
            flags: words(
                """
                -a --all -r --remotes -v -vv --verbose --list --show-current --no-color --color \
                --merged --no-merged --contains --no-contains --points-at
                """),
            attached: words("--color --sort --format --merged --no-merged --contains --no-contains --points-at"),
            positionals: .onlyWithAny(words("--list --merged --no-merged --contains --no-contains --points-at"))),
        "remote": Rules(flags: words("-v --verbose"), positionals: .none),
        "rev-parse": Rules(anyFlag: true),
        "ls-files": Rules(
            flags: words(
                """
                -c --cached -o --others -m --modified -d --deleted -s --stage -u --unmerged \
                -k --killed -i --ignored -z -t -v -f --exclude-standard --full-name \
                --error-unmatch --eol --deduplicate --directory --no-empty-directory
                """),
            attached: words("--abbrev --format")),
        "ls-tree": Rules(
            flags: words("-r -t -d -l --long -z --name-only --name-status --object-only --full-name --full-tree"),
            attached: words("--abbrev --format")),
        "grep": Rules(
            flags: words(
                """
                -n --line-number -i --ignore-case -w --word-regexp -v --invert-match -c --count \
                -l --files-with-matches --name-only -L --files-without-match -h -H -I -a --text \
                -E --extended-regexp -F --fixed-strings -P --perl-regexp -G --basic-regexp \
                --no-index --cached --untracked --exclude-standard --full-name --heading --break \
                --column -q --quiet --and --or --not -o --only-matching -p --show-function \
                -W --function-context -r --recursive
                """),
            attached: words("--max-depth --context --after-context --before-context --threads"),
            separate: words("-e -A -B -C")),
        "describe": Rules(
            flags: words("--tags --all --always --long --first-parent --exact-match --contains --dirty"),
            attached: words("--abbrev --match --exclude --candidates --dirty")),
    ]

    static func allows(_ args: [String]) -> Bool {
        var i = 0
        while i < args.count, args[i].hasPrefix("-") {
            switch args[i] {
            case "--no-pager", "--no-optional-locks":
                i += 1
            case "-C":
                guard i + 1 < args.count else { return false }
                i += 2
            default:
                return false
            }
        }
        guard i < args.count, let rules = rules[args[i]] else { return false }
        return validate(Array(args[(i + 1)...]), rules)
    }

    private static func validate(_ args: [String], _ rules: Rules) -> Bool {
        var positionalCount = 0
        var seenFlags: Set<String> = []
        var endOfOptions = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            if endOfOptions || !arg.hasPrefix("-") || arg == "-" {
                positionalCount += 1
                continue
            }
            if arg == "--" {
                endOfOptions = true
                continue
            }
            seenFlags.insert(arg)
            if rules.anyFlag || rules.flags.contains(arg) { continue }
            if arg.hasPrefix("--") {
                if let eq = arg.firstIndex(of: "="), rules.attached.contains(String(arg[..<eq])) {
                    seenFlags.insert(String(arg[..<eq]))
                    continue
                }
                return false
            }
            if let key = rules.separate.first(where: { arg.hasPrefix($0) }) {
                if arg == key {
                    guard i < args.count else { return false }
                    i += 1
                }
                continue
            }
            if rules.countShorthand, arg.count > 1, arg.dropFirst().allSatisfy({ ("0"..."9").contains($0) }) {
                continue
            }
            return false
        }
        switch rules.positionals {
        case .any: return true
        case .none: return positionalCount == 0
        case .onlyWithAny(let flags): return positionalCount == 0 || !seenFlags.isDisjoint(with: flags)
        }
    }
}

private func words(_ s: String) -> Set<String> {
    Set(s.split(whereSeparator: \.isWhitespace).map(String.init))
}
