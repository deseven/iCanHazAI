import Testing
import Foundation
@testable import iCanHazAI

/// Tests for the shell command lexer and command extractor used by the shell
/// whitelist feature.
extension AllAppTests {
    @Suite("Shell lexer")
    struct ShellLexerTests {

        // MARK: - ShellLexer tokenization

        @Test("lexes a simple command")
        func lexSimple() throws {
            var lexer = ShellLexer("cd test")
            let tokens = try lexer.allTokens()
            #expect(tokens == ["cd", "test"])
        }

        @Test("lexes operators as separate tokens")
        func lexOperators() throws {
            var lexer = ShellLexer("cat file | tail -10 && grep pattern; stat file")
            let tokens = try lexer.allTokens()
            #expect(tokens == ["cat", "file", "|", "tail", "-10", "&&", "grep", "pattern", ";", "stat", "file"])
        }

        @Test("lexes double-quoted strings (operators inside quotes are literal)")
        func lexDoubleQuotes() throws {
            var lexer = ShellLexer(#"echo "hello | world""#)
            let tokens = try lexer.allTokens()
            #expect(tokens == ["echo", "hello | world"])
        }

        @Test("lexes single-quoted strings (no escape processing)")
        func lexSingleQuotes() throws {
            var lexer = ShellLexer(#"echo 'hello | world'"#)
            let tokens = try lexer.allTokens()
            #expect(tokens == ["echo", "hello | world"])
        }

        @Test("lexes redirects")
        func lexRedirects() throws {
            var lexer = ShellLexer("cat file > out.txt")
            let tokens = try lexer.allTokens()
            #expect(tokens == ["cat", "file", ">", "out.txt"])

            var lexer2 = ShellLexer("cat file >> out.txt")
            #expect(try lexer2.allTokens() == ["cat", "file", ">>", "out.txt"])
        }

        @Test("lexes fd redirects")
        func lexFdRedirects() throws {
            var lexer = ShellLexer("cat file 2>&1 | grep pattern")
            let tokens = try lexer.allTokens()
            #expect(tokens == ["cat", "file", "2", ">&", "1", "|", "grep", "pattern"])
        }

        @Test("throws on unclosed quote")
        func unclosedQuote() throws {
            #expect(throws: ShellLexer.Error.self) {
                var lexer = ShellLexer(#"echo "unclosed"#)
                _ = try lexer.allTokens()
            }
        }

        // MARK: - ShellCommandExtractor: allowed commands

        @Test("single command")
        func singleCommand() {
            #expect(ShellCommandExtractor.extractCommands("cd test") == ["cd"])
        }

        @Test("pipe chain with && and ;")
        func pipeChain() {
            let result = ShellCommandExtractor.extractCommands("cat file | tail -10 && grep pattern; stat file")
            #expect(result == ["cat", "tail", "grep", "stat"])
        }

        @Test("pipe chain with xargs")
        func pipeWithXargs() {
            let result = ShellCommandExtractor.extractCommands("cat file | grep pattern | xargs something")
            #expect(result == ["cat", "grep", "xargs"])
        }

        @Test("single command with args")
        func singleWithArgs() {
            #expect(ShellCommandExtractor.extractCommands("ls -la /tmp") == ["ls"])
            #expect(ShellCommandExtractor.extractCommands("pwd") == ["pwd"])
        }

        @Test("redirects are not commands")
        func redirectsNotCommands() {
            #expect(ShellCommandExtractor.extractCommands("cat file > out.txt") == ["cat"])
            #expect(ShellCommandExtractor.extractCommands("cat file >> out.txt") == ["cat"])
            #expect(ShellCommandExtractor.extractCommands("cat file 2>&1 | grep pattern") == ["cat", "grep"])
            #expect(ShellCommandExtractor.extractCommands("cat file 2> errors.txt") == ["cat"])
            #expect(ShellCommandExtractor.extractCommands("cat < input.txt > output.txt") == ["cat"])
        }

        @Test("|| chain")
        func orChain() {
            let result = ShellCommandExtractor.extractCommands(#"cat file || echo "not found""#)
            #expect(result == ["cat", "echo"])
        }

        @Test("& background")
        func backgroundChain() {
            let result = ShellCommandExtractor.extractCommands("cat file & grep pattern")
            #expect(result == ["cat", "grep"])
        }

        @Test("&& chain")
        func andChain() {
            #expect(ShellCommandExtractor.extractCommands("cd /tmp && ls -la") == ["cd", "ls"])
            #expect(ShellCommandExtractor.extractCommands("cd .. && pwd") == ["cd", "pwd"])
        }

        @Test("semicolon chain")
        func semicolonChain() {
            #expect(ShellCommandExtractor.extractCommands("echo hi; echo bye") == ["echo", "echo"])
        }

        @Test("quoted pipes are not operators")
        func quotedPipes() {
            #expect(ShellCommandExtractor.extractCommands(#"echo "hello | world""#) == ["echo"])
            #expect(ShellCommandExtractor.extractCommands(#"grep "pattern with spaces" file"#) == ["grep"])
            #expect(ShellCommandExtractor.extractCommands(#"stat -f "%z" file"#) == ["stat"])
            #expect(ShellCommandExtractor.extractCommands(#"find . -name "*.swift" -type f"#) == ["find"])
        }

        @Test("variable expansion is safe")
        func variableExpansion() {
            #expect(ShellCommandExtractor.extractCommands("echo $HOME") == ["echo"])
            #expect(ShellCommandExtractor.extractCommands(#"echo "hello $USER""#) == ["echo"])
            #expect(ShellCommandExtractor.extractCommands("export PATH=/usr/bin:$PATH") == ["export"])
        }

        @Test("multiline commands split on unquoted newlines")
        func multilineCommands() {
            let result = ShellCommandExtractor.extractCommands("cd /tmp\nls -la\npwd")
            #expect(result == ["cd", "ls", "pwd"])
        }

        @Test("multiline with continuation")
        func multilineWithContinuation() {
            let result = ShellCommandExtractor.extractCommands("cat file \\\n  | grep pattern")
            #expect(result == ["cat", "grep"])
        }

        @Test("empty and whitespace commands")
        func emptyCommands() {
            #expect(ShellCommandExtractor.extractCommands("") == [])
            #expect(ShellCommandExtractor.extractCommands("   ") == [])
        }

        // MARK: - ShellCommandExtractor: bails (returns nil)

        @Test("command substitution bails")
        func commandSubstitution() {
            #expect(ShellCommandExtractor.extractCommands("DATA=$(cat file)") == nil)
            #expect(ShellCommandExtractor.extractCommands("x=$(curl http://example.com)") == nil)
        }

        @Test("backtick substitution bails")
        func backtickSubstitution() {
            #expect(ShellCommandExtractor.extractCommands("echo `date`") == nil)
        }

        @Test("arithmetic expansion bails")
        func arithmeticExpansion() {
            #expect(ShellCommandExtractor.extractCommands("echo $((1+2))") == nil)
            #expect(ShellCommandExtractor.extractCommands("((x++))") == nil)
        }

        @Test("heredoc bails")
        func heredoc() {
            #expect(ShellCommandExtractor.extractCommands("cat << EOF") == nil)
            #expect(ShellCommandExtractor.extractCommands("cat <<< hello") == nil)
        }

        @Test("process substitution bails")
        func processSubstitution() {
            #expect(ShellCommandExtractor.extractCommands("diff <(cat a) <(cat b)") == nil)
        }

        @Test("for loop bails")
        func forLoop() {
            #expect(ShellCommandExtractor.extractCommands("for i in 1 2 3; do echo $i; done") == nil)
        }

        @Test("if statement bails")
        func ifStatement() {
            #expect(ShellCommandExtractor.extractCommands("if true; then echo hi; fi") == nil)
        }

        @Test("while loop bails")
        func whileLoop() {
            #expect(ShellCommandExtractor.extractCommands("while read line; do echo $line; done") == nil)
        }

        @Test("command group braces bails")
        func commandGroup() {
            #expect(ShellCommandExtractor.extractCommands("cat file | { grep pattern; }") == nil)
            #expect(ShellCommandExtractor.extractCommands("{ echo hi; }") == nil)
        }

        @Test("unclosed quote bails")
        func unclosedQuoteBails() {
            #expect(ShellCommandExtractor.extractCommands(#"echo "unclosed"#) == nil)
        }

        @Test("parameter expansion with brace bails")
        func parameterExpansionBrace() {
            #expect(ShellCommandExtractor.extractCommands("echo ${VAR:-default}") == nil)
        }

        // MARK: - Shell whitelist integration

        @Test("whitelist allows all-whitelisted commands")
        func whitelistAllows() {
            let wl: Set<String> = ["ls", "cat", "grep", "find"]
            let source = ChatEngine.ResolvedToolSource(
                name: BuiltinTools.shellGroup, isBuiltinGroup: true,
                toolsFilter: [], autoAllow: [], autoAllowAll: false,
                directoryIsolation: false, shellWhitelist: wl
            )
            #expect(source.shellCommandAllowed("ls -la"))
            #expect(source.shellCommandAllowed("cat file | grep pattern"))
            #expect(source.shellCommandAllowed("find . -name '*.swift' | grep test"))
            #expect(source.shellCommandAllowed("cat file; ls; grep foo file"))
        }

        @Test("whitelist rejects non-whitelisted commands")
        func whitelistRejects() {
            let wl: Set<String> = ["ls", "cat"]
            let source = ChatEngine.ResolvedToolSource(
                name: BuiltinTools.shellGroup, isBuiltinGroup: true,
                toolsFilter: [], autoAllow: [], autoAllowAll: false,
                directoryIsolation: false, shellWhitelist: wl
            )
            #expect(!source.shellCommandAllowed("mkdir test"))
            #expect(!source.shellCommandAllowed("cat file | xargs something"))
            #expect(!source.shellCommandAllowed("rm -rf /"))
        }

        @Test("whitelist rejects complex commands")
        func whitelistRejectsComplex() {
            let wl: Set<String> = ["cat"]
            let source = ChatEngine.ResolvedToolSource(
                name: BuiltinTools.shellGroup, isBuiltinGroup: true,
                toolsFilter: [], autoAllow: [], autoAllowAll: false,
                directoryIsolation: false, shellWhitelist: wl
            )
            #expect(!source.shellCommandAllowed("DATA=$(cat file)"))
            #expect(!source.shellCommandAllowed("cat file | { grep pattern; }"))
            #expect(!source.shellCommandAllowed("for i in 1 2 3; do cat $i; done"))
        }

        @Test("empty whitelist rejects everything")
        func emptyWhitelistRejects() {
            let source = ChatEngine.ResolvedToolSource(
                name: BuiltinTools.shellGroup, isBuiltinGroup: true,
                toolsFilter: [], autoAllow: [], autoAllowAll: false,
                directoryIsolation: false, shellWhitelist: []
            )
            #expect(!source.shellCommandAllowed("ls"))
            #expect(!source.shellCommandAllowed("cat file"))
        }

        @Test("whitelist with cd pwd head tail like user example")
        func userExample() {
            let wl: Set<String> = ["ls", "cat", "grep", "find", "stat", "file", "curl", "cd", "pwd", "head", "tail"]
            let source = ChatEngine.ResolvedToolSource(
                name: BuiltinTools.shellGroup, isBuiltinGroup: true,
                toolsFilter: [], autoAllow: [], autoAllowAll: false,
                directoryIsolation: false, shellWhitelist: wl
            )
            // Example 1
            #expect(source.shellCommandAllowed("cd test"))
            // Example 2
            #expect(source.shellCommandAllowed("cat file | tail -10 && grep pattern; stat file"))
            // Example 3 (mkdir not whitelisted)
            #expect(!source.shellCommandAllowed("mkdir test"))
            // Example 4 (xargs not whitelisted)
            #expect(!source.shellCommandAllowed("cat file | grep pattern | xargs something"))
            // Example 5 (command substitution bails)
            #expect(!source.shellCommandAllowed("DATA=$(cat file)"))
        }
    }
}
