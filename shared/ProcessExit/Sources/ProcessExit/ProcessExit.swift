import Foundation

/// Async-safe replacement for the blocking `Process.waitUntilExit()`.
///
/// `waitUntilExit()` blocks the calling thread until the process's
/// termination is reaped, relying on the same NSTask/libdispatch machinery
/// that also delivers `terminationHandler` callbacks. Under concurrent
/// process churn on the host (several processes being spawned/terminated
/// around the same time — e.g. our own stdio MCP subprocess plus tools it
/// runs, alongside other unrelated processes reaping children), that
/// blocking wait has been observed to hang indefinitely: `terminate()` is
/// sent, the child receives SIGTERM and exits, but the calling thread's
/// `waitUntilExit()` never returns even though `terminationHandler`
/// (installed beforehand) *does* fire promptly. This is a reentrancy/
/// ordering issue in Foundation's `Process` on Darwin, not something under
/// our control.
///
/// Since `MCPManager` (in the main app) is an actor, calling the blocking
/// `waitUntilExit()` from one of its methods would freeze the *entire
/// actor* — every MCP operation (tool calls, reconfigure, etc.) — for as
/// long as the hang lasts, with no external escape hatch. Bridging
/// `terminationHandler` to an `async` wait via a continuation avoids that:
/// it costs nothing when the process exits normally, reliably unblocks
/// when `terminate()` was already called, and lets callers suspend (rather
/// than block) while waiting.
///
/// - Important: Call `awaitProcessExit(_:)` — do not call
///   `process.waitUntilExit()` directly — on any `Process` that might run
///   concurrently with other process churn on the host.
///
/// A previous version of this function raced itself into a **double
/// resume** of the `CheckedContinuation`, which is a fatal error in Swift
/// (the runtime traps/crashes the process — `EXC_BREAKPOINT`/`SIGTRAP`,
/// diagnosable via `~/Library/Logs/DiagnosticReports/<name>-*.ips` showing
/// a crash inside `CheckedContinuation.resume` called from this file). The
/// sequence was:
///
/// 1. `!process.isRunning` check (still running) — proceed.
/// 2. Install `terminationHandler`.
/// 3. Process exits *right here*, asynchronously invoking
///    `terminationHandler` on a libdispatch queue, which calls
///    `continuation.resume()` — **first** resume.
/// 4. Our own follow-up `!process.isRunning` re-check (added to catch the
///    process-already-exited race) sees the process has exited and calls
///    `continuation.resume()` again — **second** resume, crash.
///
/// The fix: guard the continuation with a lock so it is resumed exactly
/// once, no matter how many code paths (the explicit re-check and the
/// handler) race to do so.
public func awaitProcessExit(_ process: Process) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let box = SingleResumeBox(continuation: continuation)
        if !process.isRunning {
            box.resumeOnce()
            return
        }
        process.terminationHandler = { _ in
            box.resumeOnce()
        }
        // Handle the race where the process exited between the isRunning
        // check above and installing the handler. `resumeOnce()` is safe to
        // call from both this thread and the termination handler's queue,
        // and guarantees the continuation is resumed exactly once even if
        // both fire.
        if !process.isRunning {
            box.resumeOnce()
        }
    }
}

/// Lock-protected wrapper ensuring a `CheckedContinuation<Void, Never>` is
/// resumed exactly once, even when multiple concurrent callers (a
/// `terminationHandler` callback racing an explicit `isRunning` re-check)
/// attempt to resume it. Calling `resume()` more than once on a
/// `CheckedContinuation` is a fatal error in Swift, so this box is the
/// difference between a clean async wait and a crash — see the doc comment
/// on `awaitProcessExit(_:)` for the Bug #3 postmortem this fixes.
private final class SingleResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resumeOnce() {
        lock.lock()
        let toResume = continuation
        continuation = nil
        lock.unlock()
        toResume?.resume()
    }
}
