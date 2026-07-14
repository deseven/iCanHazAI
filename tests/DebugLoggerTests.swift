import Testing
import Foundation
@testable import iCanHazAI

/// Tests for [`DebugLogger`](src/DebugLogger.swift).
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
    }
}
