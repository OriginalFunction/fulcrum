import Foundation

/// Streams a tilt instance's logs by following a `tilt logs … --follow` child
/// process, decoding one `LogLine` per JSON line of its stdout.
///
/// The child is long-lived — it runs for as long as the instance stays
/// selected — which is what separates this from `ProcessCommandRunner`. The
/// lessons that path already learned still apply (stdout and stderr must be
/// drained concurrently or a 64 KB pipe fills and the child blocks forever),
/// but its cancellation story does not transfer: it races a
/// `Task.detached` blocking read against a timeout and abandons the read,
/// which is survivable for a command that was going to finish in seconds and
/// is not survivable here. This spawns no reader tasks at all. Both pipes are
/// drained by `readabilityHandler`, which is event-driven, holds no thread
/// while idle, and is removed the instant its handle reaches EOF.
public struct LogStreamer: LogStreaming {
    /// Builds the child's argv from the instance and the tail bound.
    /// Injectable so tests can drive the whole pipeline — spawn, drain,
    /// decode, cancel — with `/bin/sh` emitting canned JSON Lines instead of
    /// needing a live `tilt up` on the developer's machine.
    public typealias ArgumentBuilder = @Sendable (TiltInstance, Int) -> [String]

    private let binary: URL?
    private let arguments: ArgumentBuilder

    /// - Parameter binary: the `tilt` executable, `nil` when it could not be
    ///   found. Optional rather than a failable init because "tilt isn't
    ///   installed" has to reach the user as a message in the log pane, and a
    ///   `LogStreamer` that could not be constructed has nowhere to say it.
    public init(
        binary: URL? = TiltBinary.locate(),
        arguments: @escaping ArgumentBuilder = LogStreamer.tiltLogsArguments
    ) {
        self.binary = binary
        self.arguments = arguments
    }

    /// The real command, verified against live tilt v0.36.3 on 2026-08-11.
    ///
    /// Two things about it are load-bearing and were established by
    /// measurement, not by reading `--help`:
    ///
    /// - `--tail` is always passed. `--follow` on its own replays the entire
    ///   history before it starts following — 24,128 lines / 5.7 MB in 20
    ///   seconds from one 20-hour-old instance. `--tail 50 --follow` on the
    ///   same instance gave 76 lines in 12 seconds.
    /// - No resource name is ever passed. Positional resource filtering is
    ///   broken in this version: asking for `server` also returned lines for
    ///   `(Tiltfile)` and `quick`. The CLI is asked for everything and
    ///   filtering happens client-side on `LogLine.resource`.
    public static let tiltLogsArguments: ArgumentBuilder = { instance, tail in
        ["logs", "--port", "\(instance.webPort)", "--json", "--tail", "\(tail)", "--follow"]
    }

    public func stream(instance: TiltInstance, tail: Int) -> AsyncThrowingStream<LogLine, any Error> {
        // Unbounded buffering, deliberately. The alternative policies drop
        // lines when a consumer falls behind, and drop them *silently* —
        // which is this project's recurring failure mode. The bound on
        // retained lines belongs downstream in `LogBuffer`, which at least
        // counts what it dropped. Unbounded also means `yield` never blocks
        // the pipe drain, which is what keeps a 5.7 MB replay burst from
        // backing up into the child.
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            guard tail > 0 else {
                continuation.finish(throwing: TiltActionError.invalidArgument(
                    "A log stream needs a positive --tail bound, got \(tail)."
                ))
                return
            }
            guard let binary else {
                continuation.finish(throwing: TiltActionError.invalidArgument(
                    "Could not find the tilt executable. Install tilt, or set FULCRUM_TILT_PATH to its full path."
                ))
                return
            }

            let child = LogStreamChild(
                binary: binary,
                arguments: arguments(instance, tail),
                continuation: continuation
            )
            // Set before launching, so there is no window in which the child
            // is running but nothing is registered to kill it.
            continuation.onTermination = { _ in child.stop() }
            child.start()
        }
    }
}


/// One running `tilt logs` child and everything attached to it.
///
/// **Locking discipline — read this before changing anything below.**
///
/// All stream state (`partialLine`, the EOF flags, `exitStatus`, `didFinish`,
/// `didStop`) is confined to `queue`, a serial queue, and every line is
/// delivered from there too. Confinement, not a mutex, is what serialises the
/// pipe reads against the post-exit EOF watch. Exactly one datum crosses
/// threads — `readsInFlight` — and its lock is held for an increment and
/// nothing else.
///
/// Two rules make this deadlock-free, and both are load-bearing:
///
/// 1. **Nothing in `stop()` waits.** It is called from the stream's
///    `onTermination`, which the runtime runs while it holds the cancelled
///    task's status record. An earlier version took a mutex there. The stdout
///    handler held that same mutex while calling `continuation.yield`, which
///    needs the task machinery the canceller is holding — a textbook ABBA
///    inversion, and because the canceller was `LogPaneModel.follow(nil)` on
///    the main actor, the symptom was a permanently beachballed app on window
///    close, quit, or switching projects mid-replay. Nothing here may block on
///    anything the delivery path can hold.
///
/// 2. **No lock is ever held across `continuation.yield`.** `yield` re-enters
///    the concurrency runtime; anything held across it can be waited on by a
///    thread that runtime already owns. `emit` is called only from `queue`,
///    holding nothing.
///
/// The handler closures capture `self` **strongly**, on purpose. A weak
/// capture would let this object deallocate while the child was still
/// running, leaving a live process with nothing left to notice its output or
/// its death — precisely the orphan this class exists to prevent. The
/// resulting `self → Pipe → handler → self` cycle is broken by `teardown()`,
/// which every ending path reaches.
private final class LogStreamChild: @unchecked Sendable {
    /// How often, once the child has exited, to check whether its pipes have
    /// anything left in them — see `scheduleEOFWatch(until:)`.
    private static let eofPollInterval: TimeInterval = 0.25

    /// The hard ceiling on how long a stream may outlive its child. Only
    /// reachable if something keeps *writing* to an inherited pipe after the
    /// child is gone; the ordinary case ends within one poll interval.
    private static let maxDrainAfterExit: TimeInterval = 10

    /// How long a terminated child gets to die politely before SIGKILL.
    private static let sigkillGrace: TimeInterval = 2

    /// Only the tail of stderr is kept. It exists to explain a failure, and
    /// an hours-long stream can produce far more of it than any error message
    /// should carry.
    private static let stderrTailLimit = 8 * 1024

    private let binary: URL
    private let arguments: [String]
    private let continuation: AsyncThrowingStream<LogLine, any Error>.Continuation

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    /// The single place stream state is touched and lines are delivered.
    /// Serial, so a delivery and the EOF watch can never interleave.
    private let queue = DispatchQueue(label: "com.fulcrum.log-stream")

    // MARK: State confined to `queue`

    /// Only ever used from `queue`.
    private let decoder = JSONDecoder()
    /// Bytes read from stdout but not yet terminated by a newline. A 5.7 MB
    /// burst does not arrive on line boundaries; this is what makes an object
    /// split across two reads still decode. Its size is bounded by the
    /// producer's longest line, which for `tilt logs --json` is one log line.
    private var partialLine = Data()
    private var capturedStderr = Data()
    private var stdoutAtEOF = false
    private var stderrAtEOF = false
    private var exitStatus: Int32?
    private var didFinish = false
    /// Set by `stop()`. Turns the SIGTERM-shaped ending that follows into a
    /// clean one rather than an error about the signal we sent ourselves.
    private var didStop = false

    // MARK: The one cross-thread datum

    /// Reads taken out of a pipe but not yet delivered.
    ///
    /// Incremented on the readability handler's own thread *before* the read,
    /// decremented on `queue` after the lines are out. The EOF watch consults
    /// it because `poll` cannot: once `availableData` has emptied the pipe,
    /// the kernel has nothing left to report, yet those bytes have not reached
    /// the consumer. Ending the stream in that window is what silently dropped
    /// the last lines of a burst.
    private let inFlightLock = NSLock()
    private var readsInFlight = 0

    init(
        binary: URL,
        arguments: [String],
        continuation: AsyncThrowingStream<LogLine, any Error>.Continuation
    ) {
        self.binary = binary
        self.arguments = arguments
        self.continuation = continuation
    }

    func start() {
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Never let a child inherit — and compete for — this process's stdin.
        process.standardInput = FileHandle.nullDevice

        // `availableData` is called here, on the source's own callback, and
        // never on `queue`: it *blocks* when the pipe is empty and a writer is
        // still open, and only this callback carries the guarantee that it is
        // not. Reading it from a queue block would eventually wedge that queue
        // — and with it every stop and every delivery behind it.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = readIntoFlight(from: handle)
            queue.async { [self] in
                defer { endRead() }
                deliverStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = readIntoFlight(from: handle)
            queue.async { [self] in
                defer { endRead() }
                deliverStderr(data)
            }
        }
        process.terminationHandler = { [self] finished in
            let status = finished.terminationStatus
            queue.async { [self] in recordExit(status) }
        }

        do {
            try process.run()
        } catch {
            let reason = error.localizedDescription
            queue.async { [self] in
                guard !didFinish else { return }
                didFinish = true
                continuation.finish(throwing: TiltActionError.launchFailed(binary: binary, reason: reason))
            }
            teardown()
        }
    }

    /// Terminates the child and guarantees it stays terminated.
    ///
    /// Reached from `onTermination`, which fires whether the consumer
    /// cancelled its task, broke out of the loop, or simply released the
    /// stream. SIGTERM first — tilt gets to exit on its own terms — then
    /// SIGKILL if it is still there a moment later, because a child that
    /// ignored SIGTERM would otherwise keep both the process and its pipe
    /// alive for the rest of the session.
    ///
    /// Every line here is non-blocking by design; see rule 1 on the type.
    /// `didStop` is set by a queued block rather than directly, and that block
    /// is enqueued *before* the signal, so it is ordered ahead of the
    /// `recordExit` that the signal will cause.
    func stop() {
        queue.async { [self] in didStop = true }
        if process.isRunning { process.terminate() }
        queue.asyncAfter(deadline: .now() + Self.sigkillGrace) { [self] in
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Draining

    /// Marks a read as in flight and takes the bytes out of the pipe. Runs on
    /// the readability handler's thread, never on `queue`.
    private func readIntoFlight(from handle: FileHandle) -> Data {
        inFlightLock.withLock { readsInFlight += 1 }
        let data = handle.availableData
        if data.isEmpty {
            // Empty means EOF. The handler must come off now: at EOF the
            // underlying dispatch source stays readable and would spin.
            handle.readabilityHandler = nil
        }
        return data
    }

    private func endRead() {
        inFlightLock.withLock { readsInFlight -= 1 }
    }

    private func deliverStdout(_ data: Data) {
        guard !data.isEmpty else {
            stdoutAtEOF = true
            // Anything left in `partialLine` — a child killed mid-line, or one
            // whose last line simply had no trailing newline — is flushed by
            // `finishIfComplete()`.
            finishIfComplete()
            return
        }
        partialLine.append(data)
        for line in takeCompleteLines() { emit(line) }
    }

    private func deliverStderr(_ data: Data) {
        guard !data.isEmpty else {
            stderrAtEOF = true
            finishIfComplete()
            return
        }
        // Drained even though nothing consumes it live, because not draining
        // it is the 64 KB deadlock: tilt writes plain text here, fills the
        // pipe, blocks on the write, and stops producing stdout entirely.
        capturedStderr.append(data)
        if capturedStderr.count > Self.stderrTailLimit {
            capturedStderr.removeFirst(capturedStderr.count - Self.stderrTailLimit)
        }
    }

    /// Splits every complete line out of `partialLine`, leaving any unfinished
    /// tail behind for the next read.
    ///
    /// Scans once and copies the remainder once, rather than re-slicing the
    /// buffer per line: a single 64 KB read can hold hundreds of lines, and
    /// re-slicing each time makes that quadratic.
    private func takeCompleteLines() -> [Data] {
        var lines: [Data] = []
        var lineStart = partialLine.startIndex
        var index = partialLine.startIndex
        while index < partialLine.endIndex {
            if partialLine[index] == UInt8(ascii: "\n") {
                lines.append(Data(partialLine[lineStart..<index]))
                lineStart = partialLine.index(after: index)
            }
            index = partialLine.index(after: index)
        }
        partialLine = lineStart == partialLine.endIndex ? Data() : Data(partialLine[lineStart...])
        return lines
    }

    /// Decodes one line and hands it to the consumer. An undecodable line is
    /// skipped, not fatal: tilt interleaves plain text with its JSON, and
    /// ending the stream on the first banner line would cost the user every
    /// log that came after it.
    ///
    /// Called only from `queue`, holding no lock — see rule 2 on the type.
    private func emit(_ raw: Data) {
        guard !raw.isEmpty, let line = try? decoder.decode(LogLine.self, from: raw) else { return }
        continuation.yield(line)
    }

    // MARK: - Ending

    private func recordExit(_ status: Int32) {
        exitStatus = status
        finishIfComplete()
        scheduleEOFWatch(until: Date().addingTimeInterval(Self.maxDrainAfterExit))
    }

    /// Ends a stream whose child has exited but whose pipes never reached EOF.
    ///
    /// EOF normally arrives with the exit, because the child held the only
    /// write ends. It does not when the child left something behind holding an
    /// inherited pipe — then "wait for EOF" means "wait for that", possibly
    /// forever, and a log pane still following a process that died is the same
    /// failure as one that ended silently, pointed the other way.
    ///
    /// The wait ends on a *fact*, not a guess: the child is dead, so
    /// everything it ever wrote is already in the pipe or in flight, and with
    /// no read in flight and `poll` reporting nothing readable there is
    /// nothing of the child's left to lose. Only a still-running writer can
    /// extend this, and `maxDrainAfterExit` caps even that so the stream
    /// always ends.
    private func scheduleEOFWatch(until deadline: Date) {
        queue.asyncAfter(deadline: .now() + Self.eofPollInterval) { [self] in
            guard !didFinish else { return }
            let stillArriving = inFlightLock.withLock { readsInFlight > 0 } || !pipesAreDrained()
            guard !stillArriving || Date() >= deadline else {
                scheduleEOFWatch(until: deadline)
                return
            }
            stdoutAtEOF = true
            stderrAtEOF = true
            finishIfComplete()
        }
    }

    /// True when no pipe still being read has anything waiting in it. A handle
    /// that already hit EOF is excluded rather than polled: it stays readable
    /// forever (a zero-length read), which would otherwise read as "still
    /// draining" for as long as the other pipe's writer lived.
    private func pipesAreDrained() -> Bool {
        var descriptors: [pollfd] = []
        if !stdoutAtEOF {
            descriptors.append(pollfd(
                fd: stdoutPipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0
            ))
        }
        if !stderrAtEOF {
            descriptors.append(pollfd(
                fd: stderrPipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0
            ))
        }
        guard !descriptors.isEmpty else { return true }
        return descriptors.withUnsafeMutableBufferPointer { buffer in
            poll(buffer.baseAddress, nfds_t(buffer.count), 0) == 0
        }
    }

    /// Ends the stream once the child has exited *and* its output is fully
    /// delivered — both, because a child can exit while a burst is still in
    /// the pipe, and truncating that would drop real logs.
    ///
    /// The last unterminated line is flushed here, before the finish, and that
    /// placement is load-bearing. It used to be flushed by the stdout EOF
    /// handler, which published `stdoutAtEOF` and only then emitted the
    /// residual; in between, this method — reached from the termination
    /// handler on another thread — saw a complete set of conditions and ended
    /// the stream first, so the residual's `yield` was dropped. Measured at
    /// ~5% of runs under concurrency (19 losses in 400 streams), which as a
    /// once-in-seven full-suite flake looked like a test artifact rather than
    /// the data loss it was. Queue confinement now makes that ordering the
    /// only one available.
    private func finishIfComplete() {
        guard stdoutAtEOF, stderrAtEOF, let status = exitStatus, !didFinish else { return }
        didFinish = true

        let residual = partialLine
        partialLine = Data()
        emit(residual)

        // A child we killed ourselves reports the signal we sent it; that is
        // not a failure to report to anyone.
        if didStop || status == 0 {
            continuation.finish()
        } else {
            // The distinction that matters: a stream that ends because tilt
            // died is not the same as a stream that ends because there was
            // nothing more to say, and only this branch can tell the user
            // which one they are looking at.
            continuation.finish(throwing: TiltActionError.commandFailed(
                exitCode: status, stderr: String(decoding: capturedStderr, as: UTF8.self)
            ))
        }
        teardown()
    }

    /// Releases the handlers, and with them the retain cycle that kept this
    /// object alive while the child was running.
    private func teardown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }
}
