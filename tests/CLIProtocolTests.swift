import Testing
import Foundation
@testable import iCanHazAI

/// Tests for the CLI wire protocol ([`CLIProtocol`](src/CLI/CLIProtocol.swift))
/// and the CLI launch-mode detection / option parsing
/// ([`CLIClient`](src/CLI/CLIClient.swift)).
extension AllAppTests {

    @Suite("CLI protocol")
    struct CLIProtocolTests {

        private func roundTrip(_ frame: CLIFrame) throws -> CLIFrame {
            let data = try CLIProtocol.encode(frame)
            #expect(data.last == 0x0A)
            return try CLIProtocol.decode(line: data.dropLast())
        }

        @Test("every frame type survives an encode/decode round-trip")
        func roundTrips() throws {
            let frames: [CLIFrame] = [
                .hello(pid: 4242, client: "cli", protocolVersion: 1),
                .welcome(session: "sess-1", appVersion: "1.0.0", protocolVersion: 1),
                .ping,
                .pong(appVersion: "1.0.0", pid: 99),
                .request(CLIRequest(id: "r1", method: CLIRequest.methodChatSend,
                                    params: CLIRequestParams(message: "hi", role: "Assistant", connection: "openai/main", chat: "c.json", temporary: true))),
                .request(CLIRequest(id: "r2", method: CLIRequest.methodChatSend,
                                    params: CLIRequestParams(message: "hi"))),
                .request(CLIRequest(id: "r3", method: CLIRequest.methodChatSend,
                                    params: CLIRequestParams(message: "hi", workdir: "/tmp/proj", workdirExplicit: true, allowAll: true))),
                .started(id: "r1", chat: "c.json"),
                .delta(id: "r1", text: "Hello, {json} \"escaped\"\nnewlines"),
                .tool(id: "r1", name: "read_file", args: "src/main.swift · offset: 10", status: nil),
                .tool(id: "r1", name: "read_file", args: nil,
                      status: CLIToolStatus(kind: "done", label: "done", description: "Read 50 lines.")),
                .notice(id: "r1", text: "tool call \"rm\" requires confirmation — skipped"),
                .notice(id: nil, text: "connection-less notice"),
                .done(id: "r1", chat: "c.json", name: "Line counting"),
                .done(id: "r2", chat: "d.json", name: nil),
                .error(id: "r1", code: "stream_error", message: "boom"),
                .error(id: nil, code: "bad_frame", message: "no id"),
            ]
            for frame in frames {
                #expect(try roundTrip(frame) == frame)
            }
        }

        @Test("frames carry the protocol version and tolerate unknown keys")
        func versionAndUnknownKeys() throws {
            let data = try CLIProtocol.encode(.ping)
            var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(obj["v"] as? Int == CLIProtocol.version)

            // A frame from a newer peer with extra keys still decodes.
            obj["future_field"] = ["nested": true]
            let mutated = try JSONSerialization.data(withJSONObject: obj)
            #expect(try CLIProtocol.decode(line: mutated) == .ping)
        }

        @Test("an unknown frame type throws unknownFrameType")
        func unknownType() throws {
            let line = Data(#"{"v":1,"type":"teleport"}"#.utf8)
            #expect(throws: CLIProtocolError.unknownFrameType("teleport")) {
                try CLIProtocol.decode(line: line)
            }
        }

        @Test("malformed frames throw")
        func malformed() throws {
            // Not JSON at all → the raw JSONSerialization error surfaces.
            #expect(throws: (any Error).self) { try CLIProtocol.decode(line: Data("not json".utf8)) }
            // JSON but not a protocol frame → CLIProtocolError.malformedFrame.
            #expect(throws: CLIProtocolError.self) { try CLIProtocol.decode(line: Data(#"[1,2]"#.utf8)) }
            #expect(throws: CLIProtocolError.self) { try CLIProtocol.decode(line: Data(#"{"v":1}"#.utf8)) }
            // A request without params.message is malformed.
            #expect(throws: CLIProtocolError.self) {
                try CLIProtocol.decode(line: Data(#"{"v":1,"type":"request","id":"x","method":"chat.send","params":{}}"#.utf8))
            }
        }

        @Test("encoded frames contain no literal newlines inside the JSON")
        func noInnerNewlines() throws {
            let data = try CLIProtocol.encode(.delta(id: "x", text: "line1\nline2\nline3"))
            #expect(data.filter { $0 == 0x0A }.count == 1) // only the terminator
        }
    }

    @Suite("CLI options")
    struct CLIOptionsTests {

        @Test("positional words are joined into the message")
        func messageWords() throws {
            let opts = try CLIClient.CLIOptions.parse(["hello", "there", "world"])
            #expect(opts.words == ["hello", "there", "world"])
            #expect(opts.role == nil)
            #expect(opts.help == false)
        }

        @Test("flags parse in any position")
        func flags() throws {
            let opts = try CLIClient.CLIOptions.parse(["--role", "Developer", "hi", "--connection", "openai/main", "--chat", "c.json"])
            #expect(opts.role == "Developer")
            #expect(opts.connection == "openai/main")
            #expect(opts.chat == "c.json")
            #expect(opts.words == ["hi"])
        }

        @Test("short flags parse like their long forms")
        func shortFlags() throws {
            let opts = try CLIClient.CLIOptions.parse(["-r", "Developer", "-c", "openai/main", "-f", "c.json", "hi"])
            #expect(opts.role == "Developer")
            #expect(opts.connection == "openai/main")
            #expect(opts.chat == "c.json")
            #expect(!opts.temporary)
            #expect(opts.words == ["hi"])

            // -t can't be combined with -f, so it gets its own parse.
            let temp = try CLIClient.CLIOptions.parse(["-t", "hi"])
            #expect(temp.temporary)
            #expect(temp.chat == nil)
        }

        @Test("long flags accept the --name=value form, including values with spaces")
        func equalsForm() throws {
            // Quoting is the shell's job — a quoted value arrives as a single arg.
            let opts = try CLIClient.CLIOptions.parse([
                "--role=role name with spaces",
                "--connection=connection name with spaces",
                "--chat=my chat",
                "hi",
            ])
            #expect(opts.role == "role name with spaces")
            #expect(opts.connection == "connection name with spaces")
            #expect(opts.chat == "my chat")
            #expect(!opts.temporary)
            #expect(opts.words == ["hi"])

            let temp = try CLIClient.CLIOptions.parse(["--temporary", "hi"])
            #expect(temp.temporary)
            #expect(temp.chat == nil)
        }

        @Test("--workdir and --allow-all parse in both short and long form")
        func workdirAndAllowAll() throws {
            let opts = try CLIClient.CLIOptions.parse(["-w", "/tmp/proj", "-y", "hi"])
            #expect(opts.workdir == "/tmp/proj")
            #expect(opts.allowAll)
            #expect(opts.words == ["hi"])

            let long = try CLIClient.CLIOptions.parse(["--workdir=/tmp/proj with spaces", "--allow-all", "hi"])
            #expect(long.workdir == "/tmp/proj with spaces")
            #expect(long.allowAll)

            let none = try CLIClient.CLIOptions.parse(["hi"])
            #expect(none.workdir == nil)
            #expect(!none.allowAll)
        }

        @Test("resolveWorkdir: explicit value wins (tilde expanded), cwd is the default")
        func resolveWorkdir() {
            let cwd = FileManager.default.currentDirectoryPath
            let def = CLIClient.resolveWorkdir(CLIClient.CLIOptions())
            #expect(def.workdir == cwd)
            #expect(!def.explicit)

            let explicit = CLIClient.resolveWorkdir(CLIClient.CLIOptions(words: [], workdir: "~/proj"))
            #expect(explicit.workdir == NSHomeDirectory() + "/proj")
            #expect(explicit.explicit)

            // SSH specs are passed through untouched (no tilde expansion).
            let ssh = CLIClient.resolveWorkdir(CLIClient.CLIOptions(words: [], workdir: "nas:/var/www"))
            #expect(ssh.workdir == "nas:/var/www")
            #expect(ssh.explicit)
        }

        @Test("tool frames render like collapsed tool blocks")
        func toolFrameRendering() {
            let start = CLIClient.renderToolFrame(name: "read_file", args: "src/main.swift · offset: 10", status: nil, color: false)
            #expect(start == "⚙ read_file src/main.swift · offset: 10\n")

            let noArgs = CLIClient.renderToolFrame(name: "pwd", args: "", status: nil, color: false)
            #expect(noArgs == "⚙ pwd\n")

            let done = CLIClient.renderToolFrame(name: "read_file", args: nil,
                                                 status: CLIToolStatus(kind: "done", label: "done", description: "Read 50 lines."), color: false)
            #expect(done == "  ✓ done — Read 50 lines.\n")

            let err = CLIClient.renderToolFrame(name: "rm", args: nil,
                                                status: CLIToolStatus(kind: "error", label: "error", description: "nope"), color: false)
            #expect(err == "  ✗ error — nope\n")

            // Cancelled carries no description — the label says it all.
            let cancelled = CLIClient.renderToolFrame(name: "rm", args: nil,
                                                      status: CLIToolStatus(kind: "cancelled", label: "cancelled", description: ""), color: false)
            #expect(cancelled == "  ⚠ cancelled\n")

            // With color enabled the text is wrapped in ANSI escapes.
            let colored = CLIClient.renderToolFrame(name: "ls", args: nil,
                                                    status: CLIToolStatus(kind: "done", label: "done", description: "Listed 3 items."), color: true)
            #expect(colored.contains("\u{1B}[32m"))
            #expect(colored.hasSuffix("\u{1B}[0m\n") || colored.contains("Listed 3 items."))
        }

        @Test("--temporary and --chat cannot be combined")
        func temporaryConflictsWithChat() {
            #expect(throws: CLIClient.CLIOptions.ParseError.conflictingOptions("--temporary cannot be combined with --chat")) {
                try CLIClient.CLIOptions.parse(["-t", "-f", "c.json", "hi"])
            }
            #expect(throws: CLIClient.CLIOptions.ParseError.conflictingOptions("--temporary cannot be combined with --chat")) {
                try CLIClient.CLIOptions.parse(["--temporary", "--chat=c.json", "hi"])
            }
        }

        @Test("-- escapes flag parsing for the rest")
        func doubleDash() throws {
            let opts = try CLIClient.CLIOptions.parse(["--", "--not-a-flag", "-x"])
            #expect(opts.words == ["--not-a-flag", "-x"])
        }

        @Test("unknown flags and missing values are errors")
        func parseErrors() {
            #expect(throws: CLIClient.CLIOptions.ParseError.unknownFlag("--bogus")) {
                try CLIClient.CLIOptions.parse(["--bogus"])
            }
            #expect(throws: CLIClient.CLIOptions.ParseError.unknownFlag("-x")) {
                try CLIClient.CLIOptions.parse(["-x"])
            }
            #expect(throws: CLIClient.CLIOptions.ParseError.missingFlagValue("--role")) {
                try CLIClient.CLIOptions.parse(["--role"])
            }
            #expect(throws: CLIClient.CLIOptions.ParseError.missingFlagValue("-r")) {
                try CLIClient.CLIOptions.parse(["-r"])
            }
            #expect(throws: CLIClient.CLIOptions.ParseError.missingFlagValue("--chat")) {
                try CLIClient.CLIOptions.parse(["--chat="])
            }
        }

        @Test("launch mode detection")
        func modeDetection() {
            // Direct shell invocation → CLI.
            #expect(CLIClient.isCLIInvocation([], environment: [:], bundleID: "wtf.d7.icanhazai"))
            #expect(CLIClient.isCLIInvocation(["hi"], environment: ["__CFBundleIdentifier": "com.apple.Terminal"], bundleID: "wtf.d7.icanhazai"))
            // LaunchServices sets __CFBundleIdentifier to our own bundle id → GUI.
            #expect(!CLIClient.isCLIInvocation([], environment: ["__CFBundleIdentifier": "wtf.d7.icanhazai"], bundleID: "wtf.d7.icanhazai"))
            // Legacy -psn arg → GUI.
            #expect(!CLIClient.isCLIInvocation(["-psn_0_12345"], environment: [:], bundleID: nil))
            // Explicit headless flag → GUI.
            #expect(!CLIClient.isCLIInvocation(["--headless"], environment: [:], bundleID: nil))
        }
    }

    @Suite("CLI chat name resolution")
    struct CLIChatNameResolutionTests {

        private let filenames = ["2026-08-05 20-00-00.json", "my chat.json"]

        @Test("exact filenames resolve as-is")
        func exactMatch() {
            #expect(ChatEngine.resolveChatFilename("my chat.json", among: filenames) == "my chat.json")
        }

        @Test("names without the extension resolve to the .json file")
        func extensionlessMatch() {
            #expect(ChatEngine.resolveChatFilename("my chat", among: filenames) == "my chat.json")
            #expect(ChatEngine.resolveChatFilename("2026-08-05 20-00-00", among: filenames) == "2026-08-05 20-00-00.json")
        }

        @Test("unknown names don't resolve")
        func noMatch() {
            #expect(ChatEngine.resolveChatFilename("nope", among: filenames) == nil)
            #expect(ChatEngine.resolveChatFilename("nope.json", among: filenames) == nil)
        }
    }

    @Suite("Chat output rendering")
    struct ChatOutputRenderingTests {

        @Test("chats decode without the field (rich) and with it (plain)")
        func tolerantDecode() throws {
            let minimal = Data(#"{"messages":[]}"#.utf8)
            let rich = try JSONDecoder().decode(Chat.self, from: minimal)
            #expect(rich.outputRendering == nil)

            let plainJSON = Data(#"{"messages":[],"output_rendering":"plain"}"#.utf8)
            let plain = try JSONDecoder().decode(Chat.self, from: plainJSON)
            #expect(plain.outputRendering == .plain)
        }

        @Test("the flag round-trips through Codable")
        func roundTrip() throws {
            var chat = Chat()
            chat.outputRendering = .plain
            let decoded = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
            #expect(decoded.outputRendering == .plain)
        }

        @Test("plain text rendering description mentions the terminal")
        func plainTextContent() {
            let text = PromptVariables.plainTextRendering()
            #expect(text.contains("plain text"))
            #expect(text.contains("NOT rendered"))
        }
    }
}
