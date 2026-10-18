import Foundation
import Testing

@testable import iCanHazAI

/// Tests for [`DebugLogger`](src/Utilities/DebugLogger.swift).
///
/// The key invariant under test: `app.log` is written on every `debugLog`
/// call regardless of the "App Debug" preference; that preference only gates
/// the stdout mirror. Nested under [`AllAppTests`](tests/AllTests.swift) so
/// its `.serialized` trait keeps these sequential with the rest of the app
/// suites — `DebugLogger` holds process-global mutable state (the file handle
/// and the enabled flag) that must not be raced by concurrent tests.
extension AllAppTests {

    @Suite("DebugLogger")
    struct DebugLoggerTests {

        /// Restores global state after each test so suites don't leak handles
        /// or flag values into one another.
        private func reset() {
            DebugLogger.stopFileLogging()
            DebugLogger.setEnabled(false)
        }

        @Test("app.log is written even when app debug logging is disabled")
        func fileWrittenWhenDisabled() async throws {
            reset()
            DebugLogger.setEnabled(false)

            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ichai-debug-\(UUID().uuidString)", isDirectory: true)
            DebugLogger.startFileLogging(rootURL: tmpRoot)

            let marker = "marker-\(UUID().uuidString)"
            debugLog("TestTopic", marker)

            // The file write is dispatched onto a global utility queue; give it
            // a moment to drain before reading.
            try await Task.sleep(nanoseconds: 200_000_000)

            let url = try #require(DebugLogger.currentLogFileURL)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.contains(marker))
            #expect(contents.contains("[TestTopic]"))

            reset()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        @Test("app.log is written when app debug logging is enabled")
        func fileWrittenWhenEnabled() async throws {
            reset()
            DebugLogger.setEnabled(true)

            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ichai-debug-\(UUID().uuidString)", isDirectory: true)
            DebugLogger.startFileLogging(rootURL: tmpRoot)

            let marker = "enabled-\(UUID().uuidString)"
            debugLog("TestTopic", marker)

            try await Task.sleep(nanoseconds: 200_000_000)

            let url = try #require(DebugLogger.currentLogFileURL)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.contains(marker))

            reset()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        @Test("last_request.log is written when app debug logging is enabled")
        func lastRequestWrittenWhenEnabled() async throws {
            reset()
            DebugLogger.setEnabled(true)

            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ichai-debug-\(UUID().uuidString)", isDirectory: true)
            DebugLogger.startFileLogging(rootURL: tmpRoot)

            let marker = "last-\(UUID().uuidString)"
            DebugLogger.recordLastRequest("dump: \(marker)")

            try await Task.sleep(nanoseconds: 200_000_000)

            let url = try #require(DebugLogger.currentRequestLogFileURL)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.contains(marker))

            reset()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        @Test("last_request.log is not written when app debug logging is disabled")
        func lastRequestSkippedWhenDisabled() async throws {
            reset()
            DebugLogger.setEnabled(false)

            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ichai-debug-\(UUID().uuidString)", isDirectory: true)
            DebugLogger.startFileLogging(rootURL: tmpRoot)

            let marker = "should-not-appear-\(UUID().uuidString)"
            DebugLogger.recordLastRequest("dump: \(marker)")

            try await Task.sleep(nanoseconds: 200_000_000)

            let url = try #require(DebugLogger.currentRequestLogFileURL)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(!contents.contains(marker))

            reset()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        @Test("recordLastRequest overwrites the previous dump")
        func lastRequestOverwrites() async throws {
            reset()
            DebugLogger.setEnabled(true)

            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ichai-debug-\(UUID().uuidString)", isDirectory: true)
            DebugLogger.startFileLogging(rootURL: tmpRoot)

            let first = "first-\(UUID().uuidString)"
            let second = "second-\(UUID().uuidString)"
            DebugLogger.recordLastRequest("dump: \(first)")
            DebugLogger.recordLastRequest("dump: \(second)")

            try await Task.sleep(nanoseconds: 200_000_000)

            let url = try #require(DebugLogger.currentRequestLogFileURL)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.contains(second))
            // The file is overwritten, not appended.
            #expect(!contents.contains(first))

            reset()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        @Test("requestDump includes request and response headers and bodies")
        func requestDumpIsComplete() throws {
            let url = try #require(URL(string: "https://api.example.com/v1/chat/completions"))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer sk-test", forHTTPHeaderField: "Authorization")
            request.setValue("sk-ant-test", forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"model":"gpt-test","messages":[{"role":"user","content":"hi"}]}"#.utf8)

            let response = try #require(
                HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "X-Rate-Limit": "42"]))
            let body = Data(#"{"id":"resp-1","choices":[{"message":{"content":"hello"}}]}"#.utf8)

            let dump = LLMTransport.requestDump(request: request, response: response, receivedBody: body)

            #expect(dump.contains("POST https://api.example.com/v1/chat/completions"))
            #expect(dump.contains("Authorization: <redacted>"))
            #expect(dump.contains("x-api-key: <redacted>"))
            #expect(!dump.contains("sk-test"))
            #expect(!dump.contains("sk-ant-test"))
            #expect(dump.contains("Content-Type: application/json"))
            #expect(dump.contains(#""model":"gpt-test""#))
            #expect(dump.contains("HTTP 200"))
            #expect(dump.contains("X-Rate-Limit: 42"))
            #expect(dump.contains(#""id":"resp-1""#))
        }

        @Test("requestDump reports transport errors without a response")
        func requestDumpTransportError() throws {
            var request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1/chat/completions")))
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)

            let dump = LLMTransport.requestDump(
                request: request, response: nil, receivedBody: Data(), transportError: "connection refused")

            #expect(dump.contains("=== Transport error ==="))
            #expect(dump.contains("connection refused"))
            // No response section when the request never reached the server.
            #expect(!dump.contains("=== Response ==="))
        }
    }
}
