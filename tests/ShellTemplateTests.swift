import Foundation
import Testing

@testable import iCanHazAI

/// Tests for the `command:read` shell_whitelist templates and the segment
/// extraction they build on.
extension AllAppTests {
    @Suite("Shell whitelist templates")
    struct ShellTemplateTests {

        private func allowed(_ command: String, whitelist: Set<String>) -> Bool {
            ChatEngine.ResolvedToolSource(
                name: BuiltinTools.shellGroup, isBuiltinGroup: true,
                toolsFilter: [], autoAllow: [], autoAllowAll: false,
                directoryIsolation: false, shellWhitelist: whitelist
            ).shellCommandAllowed(command)
        }

        private func sed(_ command: String) -> Bool { allowed(command, whitelist: ["sed:read"]) }
        private func find(_ command: String) -> Bool { allowed(command, whitelist: ["find:read"]) }
        private func git(_ command: String) -> Bool { allowed(command, whitelist: ["git:read"]) }

        // MARK: - Segments and lexer flags

        @Test("extractSegments returns command and raw args")
        func segments() {
            let segments = ShellCommandExtractor.extractSegments("cat f | grep -n x; ls")
            #expect(
                segments == [
                    ShellSegment(command: "cat", args: ["f"], argsAreLiteral: true),
                    ShellSegment(command: "grep", args: ["-n", "x"], argsAreLiteral: true),
                    ShellSegment(command: "ls", args: [], argsAreLiteral: true),
                ])
        }

        @Test("quoted or escaped operators are arguments, not separators")
        func quotedOperators() {
            #expect(ShellCommandExtractor.extractSegments(#"echo ";""#)?.count == 1)
            #expect(ShellCommandExtractor.extractSegments(#"echo \;"#)?.count == 1)
            #expect(ShellCommandExtractor.extractSegments("echo ';' ls")?.map(\.command) == ["echo"])
            #expect(ShellCommandExtractor.extractSegments("echo ; ls")?.map(\.command) == ["echo", "ls"])
        }

        @Test("segments with redirects, expansion or brace expansion are not literal")
        func literalFlag() throws {
            func literal(_ command: String) throws -> Bool {
                try #require(ShellCommandExtractor.extractSegments(command)?.first).argsAreLiteral
            }
            #expect(try literal("echo a b"))
            #expect(try literal("echo '$x'"))
            #expect(try literal(#"echo \$x"#))
            #expect(try literal("echo @{u}.."))
            #expect(try literal("echo \">\""))
            #expect(try !literal("echo $x"))
            #expect(try !literal(#"echo "$x""#))
            #expect(try !literal("echo a{b,c}"))
            #expect(try !literal("echo a{1..3}"))
            #expect(try !literal("echo x > f"))
            #expect(try !literal("echo x 2>&1"))
            #expect(try !literal("echo x &> f"))
        }

        @Test("lexer reports punctuation and expansion per token")
        func lexerInfos() throws {
            var lexer = ShellLexer(#"a > "b>" $c 'd$' "e$""#)
            let infos = try lexer.allTokenInfos()
            #expect(infos.map(\.text) == ["a", ">", "b>", "$c", "d$", "e$"])
            #expect(infos.map(\.isPunctuation) == [false, true, false, false, false, false])
            #expect(infos.map(\.expands) == [false, false, false, true, false, true])
        }

        @Test("backslash-newline is a line continuation")
        func lineContinuation() throws {
            var lexer = ShellLexer("-\\\ni")
            #expect(try lexer.allTokens() == ["-i"])
        }

        // MARK: - Whitelist plumbing

        @Test("template entries only apply to their own command")
        func templateScope() {
            #expect(!allowed("cat f", whitelist: ["sed:read"]))
            #expect(!allowed("sed -n 1p f", whitelist: ["sed:reed"]))
            #expect(!allowed("sed -n 1p f", whitelist: ["find:read"]))
            #expect(!allowed("sed:read -n 1p f", whitelist: ["sed:read"]))
        }

        @Test("bare names keep meaning every invocation")
        func bareNames() {
            #expect(allowed("sed -i 's/a/b/' f", whitelist: ["sed"]))
            #expect(allowed("find . -delete", whitelist: ["find"]))
        }

        @Test("every segment must pass, templates mix with bare names")
        func mixedSegments() {
            let wl: Set<String> = ["sed:read", "git:read", "cd", "head"]
            #expect(allowed("cd /tmp && sed -n 1,5p f | head -3", whitelist: wl))
            #expect(allowed("git log --oneline | head", whitelist: wl))
            #expect(!allowed("sed -n 1,5p f | rm x", whitelist: wl))
            #expect(!allowed("sed -n 1,5p f; sed -i 1d f", whitelist: wl))
        }

        @Test("a quoted separator cannot hide a flag behind another whitelisted command")
        func quotedSeparatorCannotSmuggle() {
            #expect(!allowed(#"sed -n 1p ";" ls -i f"#, whitelist: ["sed:read", "ls"]))
            #expect(!allowed("find . -name x ';' ls -delete", whitelist: ["find:read", "ls"]))
        }

        // MARK: - sed:read

        @Test("sed:read allows line-range and address printing")
        func sedAllowed() {
            #expect(sed("sed -n 940,1060p src/Chat/Models.swift"))
            #expect(sed("sed -n '940,1060p' file"))
            #expect(sed(#"sed -n "5p" file"#))
            #expect(sed("sed -n '$p' file"))
            #expect(sed("sed -n '10,$p' file"))
            #expect(sed("sed -n '/foo/,/bar/p' file"))
            #expect(sed("sed -n '/foo bar/p' a b c"))
            #expect(sed(#"sed -n '/arr\[0\]/p' file"#))
            #expect(sed("sed -n -e '1p' -e '5,10p' a b"))
            #expect(sed("sed -ne 1p file"))
            #expect(sed("sed -n -E '/a|b/p' file"))
            #expect(sed("sed -nE '/a|b/p' file"))
            #expect(sed("sed --quiet 1p file"))
            #expect(sed("sed -n '1,5p;10q' file"))
            #expect(sed("sed -n '1p ; 3p' file"))
            #expect(sed("sed 5q file"))
            #expect(sed("sed '1,5d' file"))
            #expect(sed("sed -n '$=' file"))
            #expect(sed("sed -n '2,4!p' file"))
            #expect(allowed("cat file | sed -n '1,5p'", whitelist: ["sed:read", "cat"]))
        }

        @Test("sed:read rejects anything that writes, executes or is unknown")
        func sedRejected() {
            #expect(!sed("sed -i 's/a/b/' f"))
            #expect(!sed("sed -i.bak 1p f"))
            #expect(!sed("sed -i '' 1p f"))
            #expect(!sed("sed -ni 1p f"))
            #expect(!sed("sed -n 1p f -i"))
            #expect(!sed("sed --in-place 1p f"))
            #expect(!sed("sed -n 'w out' f"))
            #expect(!sed("sed -n '1p;w out' f"))
            #expect(!sed("sed -n '/a/w out' f"))
            #expect(!sed("sed 's/a/b/w out' f"))
            #expect(!sed("sed -n '1{p;w x\n}' f"))
            #expect(!sed("sed 's/a/b/' f"))
            #expect(!sed("sed -n 'e echo hi'"))
            #expect(!sed("sed -n '1e id' f"))
            #expect(!sed("sed 'r other' f"))
            #expect(!sed("sed -f script f"))
            #expect(!sed("sed -n -f script f"))
            #expect(!sed("sed -s -n 1p a b"))
            #expect(!sed("sed -z -n 1p a"))
            #expect(!sed("sed -n 1p -- f"))
            #expect(!sed("sed -n"))
            #expect(!sed("sed"))
            #expect(!sed("sed -n -e"))
            #expect(!sed("sed -n 'p;'; w x f"))
        }

        @Test("sed:read rejects scripts outside the strict grammar")
        func sedGrammar() {
            #expect(!sed("sed -n '/a\\/p' f"))
            #expect(!sed("sed -n '/[/]/p' f"))
            #expect(!sed("sed -n '//p' f"))
            #expect(!sed("sed -n '/a' f"))
            #expect(!sed("sed -n '1,p' f"))
            #expect(!sed("sed -n '1p2' f"))
            #expect(!sed("sed -n 'p p' f"))
            #expect(!sed("sed -n '1q5' f"))
            #expect(!sed("sed -n '1p\n2p' f"))
            #expect(!sed("sed -n '/a/I,p' f"))
            #expect(!sed("sed -n '1~2p' f"))
            #expect(!sed("sed -n '1,+2p' f"))
            #expect(!sed("sed -n '12345678901p' f"))
        }

        @Test("sed:read refuses redirects and expansion")
        func sedLiteralOnly() {
            #expect(!sed("sed -n 1,5p f > out"))
            #expect(!sed("sed -n 1,5p f >> out"))
            #expect(!sed("sed -n 1,5p f 2>/dev/null"))
            #expect(!sed("sed -n 1,5p f 2>&1"))
            #expect(!sed("sed -n 1,5p f &> out"))
            #expect(!sed("sed -n 1,5p < f"))
            #expect(!sed("sed -n $X f"))
            #expect(!sed(#"sed -n "$X" f"#))
            #expect(!sed("sed -n 1,5p $F"))
            #expect(!sed("sed -n 1,5p{,} f"))
            #expect(!sed("sed -n '$(id)' f"))
        }

        // MARK: - find:read

        @Test("find:read allows common searches")
        func findAllowed() {
            #expect(find(#"find . -name "*.swift""#))
            #expect(find("find src -type f -name '*.swift' -not -path './.build/*'"))
            #expect(find("find . -maxdepth 2 -type d"))
            #expect(find("find . -mtime -7 -size +1M"))
            #expect(find("find . -name x -print0"))
            #expect(find(#"find . \( -name a -o -name b \)"#))
            #expect(find("find . -newermt 2024-01-01 -type f"))
            #expect(find(#"find / -name foo -printf '%p\n'"#))
            #expect(find("find . -perm -u+x -type f"))
            #expect(find("find . ! -name '*.o'"))
            #expect(find("find -L . -name x"))
            #expect(find("find . -name '-delete'"))
            #expect(!find("find . -type f | head"))
            #expect(allowed("find . -type f | head", whitelist: ["find:read", "head"]))
        }

        @Test("find:read rejects primaries that execute or write")
        func findRejected() {
            #expect(!find("find . -exec rm -f ';'"))
            #expect(!find("find . -exec rm {} \\;"))
            #expect(!find("find . -name x -exec cat {} +"))
            #expect(!find("find . -execdir rm -f ';'"))
            #expect(!find("find . -ok rm -f ';'"))
            #expect(!find("find . -okdir rm -f ';'"))
            #expect(!find("find . -delete"))
            #expect(!find("find . -name x -o -delete"))
            #expect(!find("find . -fprint out"))
            #expect(!find("find . -fprint0 out"))
            #expect(!find("find . -fprintf out '%p'"))
            #expect(!find("find . -fls out"))
            #expect(!find("find . -unknownprimary"))
            #expect(!find("find . -name"))
            #expect(!find("find . -newermt"))
        }

        @Test("find:read refuses redirects and expansion")
        func findLiteralOnly() {
            #expect(!find("find . -name '*.swift' > out"))
            #expect(!find("find . -name x 2>/dev/null"))
            #expect(!find("find . -name $PAT"))
            #expect(!find("find . -name x{,\\ -delete}"))
        }

        // MARK: - git:read

        @Test("git:read allows common read-only invocations")
        func gitAllowed() {
            for command in [
                "git status",
                "git status -s",
                "git status -sb",
                "git status --porcelain=v1",
                "git status -- src",
                "git diff",
                "git diff --stat",
                "git diff HEAD~1 -- src/foo.swift",
                "git diff --cached --name-only",
                "git diff -U0 main...HEAD",
                "git diff -S foo",
                "git log --oneline -n 20",
                "git log -20 --oneline",
                "git log --since=\"2 weeks ago\" --author=bob -- src",
                "git log --format=%H -1",
                "git log --pretty=format:'%h %s' --graph --decorate",
                "git log -p -S foo -- file",
                "git log -L 10,20:file.swift",
                "git log @{u}..",
                "git show HEAD",
                "git show --stat HEAD~1",
                "git show HEAD:README.md",
                "git show -5 --oneline",
                "git blame -L 10,20 file",
                "git blame -w file",
                "git branch",
                "git branch -a",
                "git branch -vv",
                "git branch --show-current",
                "git branch --list 'feature/*'",
                "git branch --contains abc123",
                "git branch --sort=-committerdate",
                "git remote -v",
                "git remote",
                "git rev-parse --show-toplevel",
                "git rev-parse --abbrev-ref HEAD",
                "git ls-files",
                "git ls-files -m",
                "git ls-tree -r HEAD --name-only",
                "git grep -n foo -- '*.swift'",
                "git grep -e foo -A 3",
                "git grep -C2 foo",
                "git describe --tags",
                "git -C /path/to/repo log --oneline",
                "git --no-pager log -5",
            ] {
                #expect(git(command), "expected allowed: \(command)")
            }
        }

        @Test("git:read rejects mutating, code-running and unknown invocations")
        func gitRejected() {
            for command in [
                "git",
                "git push",
                "git commit -m x",
                "git checkout main",
                "git reset --hard",
                "git stash",
                "git tag v1",
                "git config user.name x",
                "git config --get user.name",
                "git fetch",
                "git branch foo",
                "git branch -d foo",
                "git branch -D foo",
                "git branch -m old new",
                "git branch --set-upstream-to=origin/main",
                "git remote add x y",
                "git remote set-url origin z",
                "git diff --output=out.txt",
                "git diff --output out.txt",
                "git diff --out=out.txt",
                "git log --output=out.txt",
                "git show --output=out.txt HEAD",
                "git diff --ext-diff",
                "git log -p --textconv",
                "git log --show-signature",
                "git grep -O vim foo",
                "git grep --open-files-in-pager=vim foo",
                "git -c core.pager=x log",
                "git -c alias.x=!id log",
                "git --git-dir=/x log",
                "git --exec-path=/x log",
                "git --paginate log",
                "git -C",
                "git log -n",
                "git log --unknown-flag",
                "git blame -S revs file",
                "git remote -v origin",
            ] {
                #expect(!git(command), "expected prompt: \(command)")
            }
        }

        @Test("git:read refuses redirects and expansion")
        func gitLiteralOnly() {
            #expect(!git("git log > out"))
            #expect(!git("git diff 2>/dev/null"))
            #expect(!git("git status $X"))
            #expect(!git(#"git log --author="$USER""#))
            #expect(!git("git log --{oneline,output=x}"))
        }
    }
}
