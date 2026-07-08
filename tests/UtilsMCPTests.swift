import Testing
import Foundation
import MCP

/// Integration tests for the Utils MCP server (run with no arguments).
///
/// All tests share a single server process via a static `sharedHarness` so we
/// don't spawn (and fail to cleanly tear down) one subprocess per test. The
/// swift-sdk `Client` keeps an internal message-loop `Task` that busy-spins
/// if its transport stream finishes while the client is still connected;
/// the only reliable way to stop it is `await client.disconnect()` *before*
/// the stream ends, which can't be done from `deinit`. A single shared
/// connection avoids per-test orphaned clients. The suite is `.serialized`
/// so tests run sequentially on the one connection.
///
/// Nested under `AllMCPTests` (see `AllTests.swift`) so its `.serialized`
/// trait forces this suite to run strictly sequentially with every other
/// bundled-MCP suite, not just internally.
extension AllMCPTests {

@Suite("UtilsMCP", .serialized, .timeLimit(.minutes(1)))
struct UtilsMCPTests {

    let harness: MCPTestHarness

    init() async throws {
        harness = try await UtilsMCPShared.shared(.utils)
    }

    // MARK: - tools/list

    @Test("lists all expected tools")
    func listsTools() async throws {
        let tools = try await harness.listTools()
        let names = tools.map(\.name).sorted()
        #expect(names == ["base64_decode", "base64_encode", "calc", "datetime", "hash", "sleep", "uuid"])
    }

    // MARK: - calc

    @Test("calc evaluates a simple expression")
    func calcSimple() async throws {
        let (text, isError) = try await harness.callTool("calc", ["expression": .string("2+2*3")])
        #expect(!isError)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "8")
    }

    @Test("calc supports sqrt via the bc math library")
    func calcSqrt() async throws {
        let (text, isError) = try await harness.callTool("calc", ["expression": .string("sqrt(16)")])
        #expect(!isError)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("4"))
    }

    @Test("calc errors on missing expression")
    func calcMissing() async throws {
        let (text, isError) = try await harness.callTool("calc", [:])
        #expect(isError)
        #expect(text.contains("expression"))
    }

    @Test("calc errors on invalid expression")
    func calcInvalid() async throws {
        let (_, isError) = try await harness.callTool("calc", ["expression": .string("@@@notvalid")])
        #expect(isError)
    }

    // MARK: - datetime

    @Test("datetime returns a YYYY-MM-DD HH:mm:ss string")
    func datetimeFormat() async throws {
        let (text, isError) = try await harness.callTool("datetime", [:])
        #expect(!isError)
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#
        #expect(text.range(of: pattern, options: .regularExpression) != nil)
    }

    // MARK: - uuid

    @Test("uuid returns a valid UUID")
    func uuidValid() async throws {
        let (text, isError) = try await harness.callTool("uuid", [:])
        #expect(!isError)
        #expect(UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }

    @Test("uuid returns distinct values")
    func uuidDistinct() async throws {
        let (a, _) = try await harness.callTool("uuid", [:])
        let (b, _) = try await harness.callTool("uuid", [:])
        #expect(a != b)
    }

    // MARK: - hash

    @Test("hash computes sha256 by default")
    func hashDefault() async throws {
        let (text, isError) = try await harness.callTool("hash", ["input": .string("abc")])
        #expect(!isError)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) ==
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("hash supports sha1")
    func hashSha1() async throws {
        let (text, isError) = try await harness.callTool("hash", ["input": .string("abc"), "algorithm": .string("sha1")])
        #expect(!isError)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) ==
                "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test("hash supports md5")
    func hashMd5() async throws {
        let (text, isError) = try await harness.callTool("hash", ["input": .string("abc"), "algorithm": .string("md5")])
        #expect(!isError)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) ==
                "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test("hash rejects unknown algorithm")
    func hashUnknown() async throws {
        let (text, isError) = try await harness.callTool("hash", ["input": .string("abc"), "algorithm": .string("rot13")])
        #expect(isError)
        #expect(text.contains("algorithm"))
    }

    @Test("hash errors on missing input")
    func hashMissing() async throws {
        let (text, isError) = try await harness.callTool("hash", [:])
        #expect(isError)
        #expect(text.contains("input"))
    }

    // MARK: - base64_encode / base64_decode

    @Test("base64_encode encodes UTF-8")
    func b64Encode() async throws {
        let (text, isError) = try await harness.callTool("base64_encode", ["input": .string("hello")])
        #expect(!isError)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "aGVsbG8=")
    }

    @Test("base64_decode decodes valid base64")
    func b64Decode() async throws {
        let (text, isError) = try await harness.callTool("base64_decode", ["input": .string("aGVsbG8=")])
        #expect(!isError)
        #expect(text == "hello")
    }

    @Test("base64 round-trips arbitrary text")
    func b64RoundTrip() async throws {
        let original = "Héllo, 世界! 🚀"
        let (encoded, _) = try await harness.callTool("base64_encode", ["input": .string(original)])
        let (decoded, isError) = try await harness.callTool("base64_decode", ["input": .string(encoded.trimmingCharacters(in: .whitespacesAndNewlines))])
        #expect(!isError)
        #expect(decoded == original)
    }

    @Test("base64_decode rejects invalid input")
    func b64DecodeInvalid() async throws {
        let (text, isError) = try await harness.callTool("base64_decode", ["input": .string("!!!not base64!!!")])
        #expect(isError)
        #expect(text.contains("base64"))
    }

    // MARK: - sleep

    @Test("sleep returns after the requested duration")
    func sleepShort() async throws {
        let start = Date()
        let (text, isError) = try await harness.callTool("sleep", ["seconds": .double(0.1)])
        let elapsed = Date().timeIntervalSince(start)
        #expect(!isError)
        #expect(text.contains("Slept"))
        #expect(elapsed >= 0.1)
    }

    @Test("sleep clamps negative values to 0")
    func sleepClamp() async throws {
        let (text, isError) = try await harness.callTool("sleep", ["seconds": .double(-5)])
        #expect(!isError)
        #expect(text.contains("Slept for 0"))
    }

    @Test("sleep errors on missing seconds")
    func sleepMissing() async throws {
        let (text, isError) = try await harness.callTool("sleep", [:])
        #expect(isError)
        #expect(text.contains("seconds"))
    }

    // MARK: - unknown tool

    @Test("calling an unknown tool returns an error result")
    func unknownTool() async throws {
        let (text, isError) = try await harness.callTool("does_not_exist", [:])
        #expect(isError)
        #expect(text.contains("unknown tool"))
    }
}

} // extension AllMCPTests
