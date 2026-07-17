import Testing

/// Process-wide serialization parent suite for every test in this target.
///
/// Swift Testing's `.serialized` trait, applied to a suite, serializes that
/// suite's own tests *and* any nested suites. So every test suite here is
/// nested under `AllAppTests` (via `extension AllAppTests { @Suite struct ... }`
/// in each test file), and the `.serialized` trait forces the whole suite
/// forest to run strictly sequentially — one test, in one suite, at a time.
///
/// This covers the main-app suites (chat model, ChatStore, FSEvents) — which
/// each spin up their own SwiftData `ModelContainer` via `ChatStore(env:)`
/// backed by a temp SQLite file, and SwiftData contexts aren't safe to juggle
/// across concurrent tests — plus the in-process builtin/configurator tools
/// suites and the stateful-singleton suites (LoaderController, DebugLogger).
/// `build.sh` runs the lot via `swift test --filter AllAppTests`.
@Suite(.serialized)
enum AllAppTests {}
