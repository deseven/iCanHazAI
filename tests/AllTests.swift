import Testing

/// Process-wide serialization parent suites for the two test families.
///
/// Swift Testing's `.serialized` trait, applied to a suite, serializes that
/// suite's own tests *and* any nested suites — but sibling top-level suites
/// remain independently concurrent unless they share a common ancestor. So
/// every test suite in this target is nested under one of the two parent
/// suites below (via `extension AllXxxTests { @Suite struct ... }` in each
/// test file), and each parent's `.serialized` trait forces its whole suite
/// forest to run strictly sequentially — one test, in one suite, at a time,
/// scoped to that family.
///
/// - `AllAppTests`: main-app suites (chat model, ChatStore, FSEvents). These
///   each spin up their own SwiftData `ModelContainer` via `ChatStore(env:)`
///   backed by a temp SQLite file, and SwiftData contexts aren't safe to
///   juggle across concurrent tests — hence serialization.
/// - `AllMCPTests`: bundled-MCP integration suites, serialized to rule out
///   cross-suite concurrency as a contributor to the residual swift-sdk hang
///   (see `plans/` / `swift-test-problem.md` context).
///
/// Ordering between the two families is enforced by `build.sh`, which runs
/// `swift test --filter AllAppTests` before `swift test --filter AllMCPTests`.
/// The two families are mutually exclusive under filtering (distinct names),
/// so each invocation runs only its own suites.
@Suite(.serialized)
enum AllAppTests {}

@Suite(.serialized)
enum AllMCPTests {}
