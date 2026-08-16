import Foundation
import Testing
@testable import FulcrumKit

// MARK: - Harness
//
// Every test here drives `LogStreamer` with `/bin/sh` emitting canned JSON
// Lines, never with real tilt. A test that needed a live instance would pass
// or fail based on whether the developer happened to have `tilt up` running,
// which is not a test.

private func streamInstance(port: Int = 10370) -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)",
        port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data(),
        token: "t"
    ))
}

/// A `LogStreamer` whose "tilt" is `/bin/sh -c <script>`.
private func shStreamer(_ script: String) -> LogStreamer {
    LogStreamer(binary: URL(fileURLWithPath: "/bin/sh"), arguments: { _, _ in ["-c", script] })
}

/// One line of tilt's `--json` log output, in the exact shape verified
/// against v0.36.3 (see `LogLine`). Contains no single quotes, so it drops
/// into a single-quoted `sh` string unescaped.
private func jsonLine(_ message: String, resource: String = "server", level: String = "info") -> String {
    #"""
    {"time":"2026-08-11T18:27:47+08:00","resource":"\#(resource)","level":"\#(level)","message":"\#(message)","spanID":"localserve:1","progressID":"","buildEvent":"","source":"runtime"}
    """#
}

private struct TestTimeout: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "the operation did not finish within \(seconds)s" }
}

/// Fails, rather than hangs, when the thing under test stops making progress.
///
/// Load-bearing, not decoration. Every test in this file awaits either a
/// stream or a child process, and a regression in either direction (a stream
/// that never finishes, a child that never dies) presents as a hang. One
/// earlier test on this project stalled a run for six minutes under mutation
/// with no diagnosis; `.timeLimit`'s whole-minute granularity is too coarse to
/// prevent that, so these use seconds.
@discardableResult
private func within<T: Sendable>(
    _ seconds: Double = 20,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeout(seconds: seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Drains a stream to its end, keeping both what it delivered and how it
/// ended. Both halves get asserted on: "which lines arrived" and "did it end
/// clean or throwing" are separate claims, and a stream that silently stops
/// looks exactly like a quiet one unless the ending is checked too.
private func drain(
    _ stream: AsyncThrowingStream<LogLine, any Error>
) async -> (lines: [LogLine], failure: (any Error)?) {
    var lines: [LogLine] = []
    do {
        for try await line in stream { lines.append(line) }
    } catch {
        return (lines, error)
    }
    return (lines, nil)
}

/// True while `pid` still exists. Only ever called with a pid this file's own
/// tests spawned.
private func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

/// `ps` output for `pid`, or nil when no such process exists — used to make a
/// failure say *what* survived instead of just "still alive".
private func psDescription(_ pid: Int32) async -> String? {
    let runner = ProcessCommandRunner(timeout: 5)
    guard let output = try? await runner.run(
        URL(fileURLWithPath: "/bin/ps"), ["-o", "state=,comm=", "-p", "\(pid)"]
    ) else { return nil }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - Delivery

@Test(.timeLimit(.minutes(1))) func emitsOneValuePerJSONLine() async throws {
    let (lines, failure) = try await within {
        let streamer = shStreamer("echo '\(jsonLine("first"))'; echo '\(jsonLine("second", resource: "quick"))'")
        return await drain(streamer.stream(instance: streamInstance(), tail: 50))
    }

    #expect(failure == nil)
    #expect(lines.map(\.message) == ["first", "second"])
    #expect(lines.map(\.resource) == ["server", "quick"])
    #expect(lines.first?.level == .info)
    #expect(lines.first?.source == .runtime)
    #expect(lines.first?.spanID == "localserve:1")
}

@Test(.timeLimit(.minutes(1))) func aMalformedLineIsSkippedNotFatal() async throws {
    // tilt writes plain text among its JSON — measured on v0.36.3. One bad
    // line must cost one line, not the rest of the session's logs.
    let (lines, failure) = try await within {
        let script = [
            "echo '\(jsonLine("before"))'",
            "echo 'Beginning Tilt log stream...'",
            "echo '{\"time\":\"not-a-timestamp\",\"resource\":\"x\",\"level\":\"info\",\"message\":\"m\",\"spanID\":\"\",\"source\":\"runtime\"}'",
            "echo '{\"partial\":'",
            "echo '\(jsonLine("after"))'"
        ].joined(separator: "; ")
        return await drain(shStreamer(script).stream(instance: streamInstance(), tail: 50))
    }

    #expect(failure == nil)
    #expect(lines.map(\.message) == ["before", "after"])
}

@Test(.timeLimit(.minutes(1))) func handlesALineSplitAcrossTwoReads() async throws {
    // A 5.7 MB burst does not arrive on tidy line boundaries. Split one JSON
    // object mid-token and hand the halves over in two separate reads.
    let whole = jsonLine("split")
    let breakPoint = whole.index(whole.startIndex, offsetBy: 40)
    let head = String(whole[whole.startIndex..<breakPoint])
    let tail = String(whole[breakPoint...])

    // Guards the guard: if `head` happened to be a decodable object on its
    // own, this test would pass without ever exercising re-assembly.
    #expect((try? JSONDecoder().decode(LogLine.self, from: Data(head.utf8))) == nil)
    #expect(!head.contains("\n") && !tail.contains("\n"))

    let (lines, failure) = try await within {
        // `sleep` between the halves forces two distinct reads rather than
        // one buffered write.
        let script = "printf '%s' '\(head)'; sleep 0.4; printf '%s\\n' '\(tail)'"
        return await drain(shStreamer(script).stream(instance: streamInstance(), tail: 50))
    }

    #expect(failure == nil)
    #expect(lines.map(\.message) == ["split"])
}

@Test(.timeLimit(.minutes(1))) func aFinalLineWithoutATrailingNewlineIsStillDelivered() async throws {
    let (lines, failure) = try await within {
        let script = "printf '%s\\n%s' '\(jsonLine("terminated"))' '\(jsonLine("unterminated"))'"
        return await drain(shStreamer(script).stream(instance: streamInstance(), tail: 50))
    }

    #expect(failure == nil)
    #expect(lines.map(\.message) == ["terminated", "unterminated"])
}

@Test(.timeLimit(.minutes(1))) func everyConcurrentStreamDeliversItsFinalUnterminatedLine() async throws {
    // The test above catches the race that used to drop that final line only
    // about 5% of the time — as a full-suite flake it read as a test artifact
    // rather than as production data loss. This runs the same scenario 200
    // times across 8 concurrent streams, which turns a 5%-per-stream failure
    // into a certainty (0.95^200 ≈ 3e-5 chance of a clean run). Measured
    // against the broken ordering: 19 losses in 400 streams, and 20/20 runs
    // of this test failed.
    //
    // Concurrency is the point, not incidental: the dropped line was caused by
    // another thread ending the stream between "stdout is at EOF" and "here is
    // the last line", so a sequential version of this exercises nothing.
    let streams = 8
    let perStream = 25

    let badOutcomes = await withTaskGroup(of: [String].self, returning: [String].self) { group in
        for _ in 0..<streams {
            group.addTask {
                var bad: [String] = []
                for _ in 0..<perStream {
                    let script = "printf '%s\\n%s' '\(jsonLine("terminated"))' '\(jsonLine("unterminated"))'"
                    let (lines, failure) = await drain(
                        shStreamer(script).stream(instance: streamInstance(), tail: 50)
                    )
                    let messages = lines.map(\.message)
                    if failure != nil || messages != ["terminated", "unterminated"] {
                        bad.append("\(messages) failure=\(String(describing: failure))")
                    }
                }
                return bad
            }
        }
        var all: [String] = []
        for await result in group { all.append(contentsOf: result) }
        return all
    }

    #expect(badOutcomes.isEmpty, "\(badOutcomes.count)/\(streams * perStream) streams lost output: \(badOutcomes.prefix(3))")
}

@Test(.timeLimit(.minutes(1))) func theFinalUnterminatedLineSurvivesEndingOnTheEOFFallback() async throws {
    // Deterministic cover for the other path that can decide the ending: the
    // post-exit EOF watch. Backgrounding a process that holds the pipe open
    // means stdout never reaches EOF, so the fallback is what ends this stream
    // — with an unterminated line still buffered. It used to end without
    // flushing at all, losing that line 100% of the time; unlike the race
    // above, this ordering is forced rather than hoped for.
    // The unterminated last line carries the grandchild's pid, so the test can
    // prove that process was still holding the pipe when the stream ended.
    let script = #"""
        fmt='{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"%s","spanID":"s","progressID":"","buildEvent":"","source":"runtime"}'
        sleep 2 &
        printf "$fmt\n" terminated
        printf "$fmt" "$!"
        exit 0
        """#

    let (lines, failure) = try await within {
        await drain(shStreamer(script).stream(instance: streamInstance(), tail: 50))
    }

    #expect(failure == nil)
    #expect(lines.count == 2, "the final unterminated line was dropped: \(lines.map(\.message))")
    #expect(lines.first?.message == "terminated")

    let holder = try #require(Int32(lines.last?.message ?? ""))
    // Without this, the test would also pass on an implementation that simply
    // waited for the grandchild to exit — which is the ordering it exists to
    // rule out.
    #expect(isAlive(holder), "the grandchild released the pipe before the stream ended, so the fallback was not the ending path")

    // That grandchild outlives the stream by design; wait it out so the test
    // leaves nothing running.
    while isAlive(holder) { try await Task.sleep(nanoseconds: 100_000_000) }
}

// MARK: - Endings

@Test(.timeLimit(.minutes(1))) func endsCleanlyWhenTheChildExits() async throws {
    let (lines, failure) = try await within {
        await drain(shStreamer("echo '\(jsonLine("only"))'; exit 0").stream(instance: streamInstance(), tail: 50))
    }

    #expect(lines.count == 1)
    #expect(failure == nil)
}

@Test(.timeLimit(.minutes(1))) func aChildThatDiesUnexpectedlyFinishesTheStreamWithItsStderr() async throws {
    // The ending a quiet stream must never be confused with. A non-zero exit
    // carries tilt's own stderr through to the UI verbatim, because that text
    // ("could not connect to tilt at port 10370") is the only thing that tells
    // the user what to fix.
    let (lines, failure) = try await within {
        let script = "echo '\(jsonLine("last"))'; echo 'Error: could not connect' >&2; exit 3"
        return await drain(shStreamer(script).stream(instance: streamInstance(), tail: 50))
    }

    #expect(lines.map(\.message) == ["last"])
    #expect(failure as? TiltActionError == .commandFailed(exitCode: 3, stderr: "Error: could not connect\n"))
}

@Test(.timeLimit(.minutes(1))) func endsAfterTheChildExitsEvenWhenAGrandchildStillHoldsThePipe() async throws {
    // "The stream ends when the child ends" cannot be implemented as "wait
    // for EOF on stdout" alone: anything the child backgrounded inherits that
    // pipe and can hold it open long after the child is gone. A log pane
    // still spinning on a process that died minutes ago is the same failure
    // as one that ended silently, just pointing the other way.
    let script = #"""
        fmt='{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"%s","spanID":"s","progressID":"","buildEvent":"","source":"runtime"}\n'
        sleep 3 &
        printf "$fmt" "$!"
        exit 0
        """#

    let started = Date()
    let (lines, failure) = try await within(20) {
        await drain(shStreamer(script).stream(instance: streamInstance(), tail: 50))
    }
    let elapsed = Date().timeIntervalSince(started)

    #expect(failure == nil)
    let holder = try #require(Int32(lines.first?.message ?? ""))
    // Both halves matter: the stream ended, *and* it ended while the process
    // holding its pipe was still alive — otherwise this test would pass on an
    // implementation that simply waited the grandchild out.
    #expect(isAlive(holder), "the grandchild released the pipe before the stream ended, so nothing was proven")
    #expect(elapsed < 2, "took \(elapsed)s to end after the child exited")

    // Leave nothing running behind this test.
    while isAlive(holder) { try await Task.sleep(nanoseconds: 100_000_000) }
}

@Test(.timeLimit(.minutes(1))) func aChildThatCannotBeLaunchedFinishesTheStreamThrowing() async throws {
    let (lines, failure) = try await within {
        let missing = URL(fileURLWithPath: "/nonexistent/fulcrum-not-tilt")
        let streamer = LogStreamer(binary: missing, arguments: { _, _ in [] })
        return await drain(streamer.stream(instance: streamInstance(), tail: 50))
    }

    #expect(lines.isEmpty)
    guard case .launchFailed = failure as? TiltActionError else {
        Issue.record("expected .launchFailed, got \(String(describing: failure))")
        return
    }
}

@Test(.timeLimit(.minutes(1))) func aMissingTiltBinaryIsReportedNotSilentlyEmpty() async throws {
    // `TiltBinary.locate` returns nil when tilt is genuinely not installed —
    // and a GUI app launched from Finder inherits launchd's PATH, so this is
    // reachable on a machine where `tilt` works fine in a terminal. An empty
    // log pane would read as "no logs yet".
    let (lines, failure) = try await within(5) {
        await drain(LogStreamer(binary: nil).stream(instance: streamInstance(), tail: 50))
    }

    #expect(lines.isEmpty)
    #expect(failure as? TiltActionError == .invalidArgument(
        "Could not find the tilt executable. Install tilt, or set FULCRUM_TILT_PATH to its full path."
    ))
}

@Test(.timeLimit(.minutes(1))) func aNonPositiveTailIsRefusedRatherThanRunUnbounded() async throws {
    // `--follow` with no bound replays the entire history: 24,128 lines /
    // 5.7 MB in 20 seconds, measured. Never launch that by accident.
    for tail in [0, -1] {
        let (lines, failure) = try await within(5) {
            await drain(shStreamer("echo '\(jsonLine("never"))'").stream(instance: streamInstance(), tail: tail))
        }
        #expect(lines.isEmpty)
        guard case .invalidArgument = failure as? TiltActionError else {
            Issue.record("tail \(tail): expected .invalidArgument, got \(String(describing: failure))")
            return
        }
    }
}

// MARK: - Cancellation

@Test(.timeLimit(.minutes(1))) func terminatesTheChildWhenTheStreamIsCancelled() async throws {
    // THE test for this task. An orphaned `tilt logs --follow` per instance
    // selection would accumulate silently for a whole session, each one still
    // streaming. Asserting only that the stream ended proves nothing about
    // the child: this captures the child's real pid (the shell reports `$$`
    // as its own first log line) and checks the process itself.
    let script = #"""
        fmt='{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"%s","spanID":"s","progressID":"","buildEvent":"","source":"runtime"}\n'
        printf "$fmt" "$$"
        while :; do printf "$fmt" tick; sleep 0.2; done
        """#

    let pid: Int32 = try await within(20) {
        let streamer = shStreamer(script)
        let (observed, observedContinuation) = AsyncStream<LogLine>.makeStream()

        let consumer = Task {
            for try await line in streamer.stream(instance: streamInstance(), tail: 50) {
                observedContinuation.yield(line)
            }
            observedContinuation.finish()
        }

        var childPID: Int32?
        for await line in observed {
            childPID = Int32(line.message)
            break
        }
        let pid = try #require(childPID, "the child never reported its pid, so nothing was streaming")

        // Sanity before the real assertion: this pid must be a live process
        // we spawned. Without this, a mutation that reported a bogus pid
        // would make the "it's gone" check below pass trivially.
        #expect(isAlive(pid), "captured pid \(pid) was not alive even before cancelling")

        consumer.cancel()
        _ = await consumer.result
        return pid
    }

    // Poll rather than assert once: termination and reaping are asynchronous,
    // and a fixed sleep would either be flaky or slow.
    let deadline = Date().addingTimeInterval(10)
    while isAlive(pid) && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    let survivor = isAlive(pid) ? await psDescription(pid) : nil
    #expect(survivor == nil, "child pid \(pid) survived cancellation: \(survivor ?? "")")
}

@Test(.timeLimit(.minutes(1))) func aChildThatIgnoresSIGTERMIsKilledAnyway() async throws {
    // SIGTERM is a request, and a child is free to decline it. Declining it
    // must not be enough to survive: the whole point of the previous test is
    // that no `tilt logs` outlives the selection that started it.
    let script = #"""
        trap '' TERM
        fmt='{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"%s","spanID":"s","progressID":"","buildEvent":"","source":"runtime"}\n'
        printf "$fmt" "$$"
        while :; do printf "$fmt" tick; sleep 0.2; done
        """#

    let pid: Int32 = try await within(20) {
        let streamer = shStreamer(script)
        var found: Int32?
        for try await line in streamer.stream(instance: streamInstance(), tail: 50) {
            found = Int32(line.message)
            break
        }
        return try #require(found, "the child never reported its pid, so nothing was streaming")
    }

    let deadline = Date().addingTimeInterval(10)
    while isAlive(pid) && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    let survivor = isAlive(pid) ? await psDescription(pid) : nil
    #expect(survivor == nil, "child pid \(pid) ignored SIGTERM and was never killed: \(survivor ?? "")")
}

@Test(.timeLimit(.minutes(1))) func droppingTheStreamWithoutCancellingAlsoTerminatesTheChild() async throws {
    // The other way a consumer stops consuming: it just walks away — a
    // `break` out of the `for await`, or the owning view disappearing. The
    // child must not outlive that either.
    let script = #"""
        fmt='{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"%s","spanID":"s","progressID":"","buildEvent":"","source":"runtime"}\n'
        printf "$fmt" "$$"
        while :; do printf "$fmt" tick; sleep 0.2; done
        """#

    let pid: Int32 = try await within(20) {
        let streamer = shStreamer(script)
        var found: Int32?
        for try await line in streamer.stream(instance: streamInstance(), tail: 50) {
            found = Int32(line.message)
            break
        }
        return try #require(found, "the child never reported its pid, so nothing was streaming")
    }

    let deadline = Date().addingTimeInterval(10)
    while isAlive(pid) && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    let survivor = isAlive(pid) ? await psDescription(pid) : nil
    #expect(survivor == nil, "child pid \(pid) survived the consumer walking away: \(survivor ?? "")")
}

// MARK: - Throughput

@Test(.timeLimit(.minutes(1))) func doesNotDeadlockOnALargeBurst() async throws {
    // The 64 KB pipe-buffer deadlock was a real, measured finding on this
    // project's other subprocess path: a child fills the pipe and blocks
    // forever while the parent waits for it to exit. Here the burst is the
    // normal case, not the edge case — `--tail 50 --follow` replays before it
    // follows, and an unbounded one measured 5.7 MB.
    let padding = String(repeating: "x", count: 240)
    let script = """
        i=0
        while [ $i -lt 5000 ]; do
          echo '\(jsonLine(padding))'
          i=$((i+1))
        done
        """

    let (lines, failure) = try await within(20) {
        await drain(shStreamer(script).stream(instance: streamInstance(), tail: 50))
    }

    #expect(failure == nil)
    #expect(lines.count == 5000)
    #expect(lines.last?.message == padding)
}

@Test(.timeLimit(.minutes(1))) func aStderrFloodDoesNotStallStdout() async throws {
    // The same 64 KB deadlock from the other side: tilt writes plain text to
    // stderr, and a parent that only drains stdout blocks the child on its
    // *stderr* write — after which no more log lines ever arrive. 200 KB is
    // comfortably past the pipe buffer.
    let (lines, failure) = try await within(20) {
        let script = """
            i=0
            while [ $i -lt 2000 ]; do
              echo 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >&2
              i=$((i+1))
            done
            echo '\(jsonLine("after the flood"))'
            """
        return await drain(shStreamer(script).stream(instance: streamInstance(), tail: 50))
    }

    #expect(failure == nil)
    #expect(lines.map(\.message) == ["after the flood"])
}

// MARK: - The real command

@Test func buildsTheVerifiedTiltLogsCommand() {
    // Verified against live tilt v0.36.3 on 2026-08-11.
    #expect(LogStreamer.tiltLogsArguments(streamInstance(port: 10370), 500)
        == ["logs", "--port", "10370", "--json", "--tail", "500", "--follow"])
}

@Test func neverPassesAResourceNameToTheCLI() {
    // Positional resource filtering is broken in v0.36.3: asking for `server`
    // returned lines for `(Tiltfile)` and `quick` as well. Filtering happens
    // client-side on `LogLine.resource`; the CLI is asked for everything.
    let argv = LogStreamer.tiltLogsArguments(streamInstance(port: 10370), 50)
    #expect(argv.allSatisfy { $0.hasPrefix("--") || $0 == "logs" || Int($0) != nil })
}
