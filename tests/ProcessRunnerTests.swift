import Foundation
import ProcessExit
import Testing

extension AllAppTests {
    @Suite("ProcessRunner termination")
    struct ProcessRunnerTests {

        /// A temp file the spawned script writes the pid of its inner process to.
        private final class PidFile: Sendable {
            let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "ichai-runner-\(UUID().uuidString).pid")

            deinit { try? FileManager.default.removeItem(atPath: path) }

            /// Waits for the script to have written it: the process is up and running.
            func pid(timeout: Duration = .seconds(5)) async throws -> pid_t {
                let clock = ContinuousClock()
                let deadline = clock.now + timeout
                while clock.now < deadline {
                    if let text = try? String(contentsOfFile: path, encoding: .utf8),
                        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    {
                        return pid
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw ProcessTestError("the script never started")
            }
        }

        private struct ProcessTestError: Error, CustomStringConvertible {
            let description: String
            init(_ description: String) { self.description = description }
        }

        private static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

        private static func waitForDeath(_ pid: pid_t, timeout: Duration = .seconds(5)) async throws -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while clock.now < deadline {
                if !isAlive(pid) { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        /// A shell that, like the shell tool, reads its script from stdin and runs a grandchild — here one
        /// that ignores SIGTERM (ignored signals survive `exec`), so only SIGKILL takes it down.
        private static func stubbornScript(_ pidFile: PidFile) -> Data {
            Data("trap '' TERM\nsh -c 'echo $$ > \(pidFile.path); exec sleep 600'\n".utf8)
        }

        @Test("cancelling kills the whole process group, escalating to SIGKILL, and returns promptly")
        func cancelKillsGroup() async throws {
            let pidFile = PidFile()
            let run = Task {
                await ProcessRunner.run(
                    executable: "/bin/sh", stdin: Self.stubbornScript(pidFile), outputMode: .merged,
                    killGrace: .milliseconds(300))
            }
            let grandchild = try await pidFile.pid()

            let clock = ContinuousClock()
            let start = clock.now
            run.cancel()
            let result = await run.value
            #expect(clock.now - start < .seconds(3))
            #expect(result.exitCode == -1)
            #expect(result.stderrString == "cancelled")
            #expect(try await Self.waitForDeath(grandchild))
        }

        @Test("cancelling a run with a pending timeout returns at once instead of spinning until the deadline")
        func cancelWithTimeout() async throws {
            let pidFile = PidFile()
            let run = Task {
                await ProcessRunner.run(
                    executable: "/bin/sh", stdin: Data("echo $$ > \(pidFile.path); exec sleep 600\n".utf8),
                    timeout: 60, outputMode: .merged)
            }
            let shell = try await pidFile.pid()

            let clock = ContinuousClock()
            let start = clock.now
            run.cancel()
            let result = await run.value
            #expect(clock.now - start < .seconds(3))
            #expect(result.exitCode == -1)
            #expect(try await Self.waitForDeath(shell))
        }

        @Test("a timeout kills what the process spawned too, not just the process")
        func timeoutKillsGroup() async throws {
            let pidFile = PidFile()
            let result = await ProcessRunner.run(
                executable: "/bin/sh", stdin: Self.stubbornScript(pidFile), timeout: 1, outputMode: .merged,
                killGrace: .milliseconds(300))
            let grandchild = try await pidFile.pid()

            #expect(result.exitCode == -1)
            #expect(result.stderrString.contains("timed out"))
            #expect(try await Self.waitForDeath(grandchild))
        }

        @Test("killAllNow takes down a stopped group still inside its kill grace period (app quit)")
        func killAllNowSkipsGrace() async throws {
            let pidFile = PidFile()
            let run = Task {
                await ProcessRunner.run(
                    executable: "/bin/sh", stdin: Self.stubbornScript(pidFile), outputMode: .merged,
                    killGrace: .seconds(600))
            }
            let grandchild = try await pidFile.pid()
            run.cancel()
            // SIGTERM is ignored and the SIGKILL is 10 minutes out: only killAllNow can end it in time.
            #expect(!(try await Self.waitForDeath(grandchild, timeout: .milliseconds(500))))

            ProcessGroupKiller.killAllNow()
            #expect(try await Self.waitForDeath(grandchild))
            _ = await run.value
        }

        @Test("a normal run is unaffected")
        func normalRun() async {
            let result = await ProcessRunner.run(
                executable: "/bin/sh", stdin: Data("echo hi; exit 3\n".utf8), timeout: 10, outputMode: .merged)
            #expect(result.exitCode == 3)
            #expect(result.stdoutString == "hi\n")
        }
    }
}
