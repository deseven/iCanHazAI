import Testing

/// Parent suite forcing full serialization across all bundled-MCP
/// integration suites.
///
/// Swift Testing's `.serialized` trait, applied to a suite, serializes that
/// suite's own tests *and* any nested suites — but sibling top-level suites
/// remain independently concurrent unless they share a common ancestor.
/// Every suite in this test target is nested under `AllMCPTests` (via
/// `extension AllMCPTests { @Suite ... struct ... }` in each test file) so
/// that this one `.serialized` trait forces the entire suite forest to run
/// strictly sequentially — one test, in one suite, at a time, process-wide.
///
/// This is Suggested Next Step #2 from `swift-test-problem.md`'s Bug #3
/// investigation: a lower-effort way (vs. forking swift-sdk to add tracing)
/// to rule in/out cross-suite concurrency as a contributing factor to the
/// residual hang, independent of swift-sdk's internals. If serializing
/// eliminates the hang across many repro-loop runs, that points back at
/// swift-sdk's `Client`/`StdioTransport` concurrency handling; if the hang
/// still occurs fully serialized, suspicion shifts to our own
/// `MCPTestHarness`/tool-call code instead.
@Suite(.serialized)
enum AllMCPTests {}
