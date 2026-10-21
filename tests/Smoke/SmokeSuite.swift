import Foundation
import Testing

@testable import iCanHazAI

// Smoke tests drive the real engine against the mock provider API in tools/mock-api. They are run by
// `./build.sh smoke`, which starts the mock server and sets ICHAI_MOCK_URL. Without it the whole root
// suite is disabled, so a plain `swift test` stays green. The suite is deliberately not nested under
// `AllAppTests`, so `./build.sh test` never runs it.

enum SmokeEnv {
    static let mockURL: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["ICHAI_MOCK_URL"], !raw.isEmpty else { return nil }
        return URL(string: raw)
    }()
}

/// Redirects the process-wide singletons (`EnvironmentManager.shared`, and through it `ConfigManager.shared`)
/// to a throwaway directory. Providers added through the engine persist into `config.toml`, so without this a
/// smoke run would overwrite the real `~/iCanHazAI/config.toml`.
///
/// Installed by `SmokeFixture`, which every smoke test goes through, rather than as a suite trait: a recursive
/// `TestScoping` trait on the root suite sends Swift Testing's plan construction into an endless loop.
enum SmokeSandbox {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    nonisolated(unsafe) private static var removalPath: String?

    static let root: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ichai-smoke-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        EnvironmentManager.mainDirOverride = url
        removalPath = url.path
        atexit { if let path = SmokeSandbox.removalPath { try? FileManager.default.removeItem(atPath: path) } }
        return url
    }()

    /// Sets the override (once per process) and fails loudly when `EnvironmentManager.shared` was created
    /// before it took effect, instead of letting a test write into the real data directory.
    static func install() throws {
        let sandbox = root.standardizedFileURL.path  // must run before the singleton is first touched
        let resolved = EnvironmentManager.shared.rootURL.standardizedFileURL.path
        guard resolved.hasPrefix(sandbox) else {
            throw Failure(description: "EnvironmentManager.shared points at \(resolved), not the sandbox \(sandbox)")
        }
    }
}

@Suite(
    .serialized,
    .enabled(if: SmokeEnv.mockURL != nil, "ICHAI_MOCK_URL is not set — run ./build.sh smoke"))
enum AllSmokeTests {}
