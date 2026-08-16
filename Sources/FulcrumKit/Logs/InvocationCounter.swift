import Foundation

/// Counts how many times an operation actually ran. Test-only seam —
/// package-internal, never on a public signature — so tests can assert
/// "this happened once, not once per line" or "this did not happen at all"
/// by COUNTING invocations rather than measuring wall-clock time.
///
/// One type rather than one per call site: `LogFilter` needs it twice (regex
/// compilations, record-grouping passes) and `JSONBlock` once (character-level
/// brace scans), and three byte-identical nested classes is three places for
/// the locking to drift. Each call site keeps its own name via a typealias, so
/// `LogFilter.CompilationCounter` and `JSONBlock.BraceScanCounter` still read
/// as what they count.
///
/// `@unchecked Sendable` with an `NSLock`, following `StubCommandRunner` and
/// `LogStreamChild`: the state is a single counter, not worth an actor —
/// which matters because these seams are called from synchronous,
/// non-isolated code paths that an actor would force to become `async`.
final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
