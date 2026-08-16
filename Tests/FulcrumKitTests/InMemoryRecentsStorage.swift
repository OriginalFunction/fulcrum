import Foundation
@testable import FulcrumKit

/// A `RecentsStorage` that never touches disk, for the many tests that need a
/// `RecentsStore` as a collaborator rather than as the thing under test.
///
/// Those tests previously each invented a UUID-named file under `TMPDIR` and
/// left it there: 1,635 files, 6.7MB, growing ~15 every full-suite run.
/// Deleting them afterwards is the fix that does not work — the same
/// conclusion `TestUserDefaults` reached about `~/Library/Preferences`, for a
/// different reason: a test that fails, is cancelled, or is killed mid-run
/// never reaches its own cleanup, and this suite's whole point is to be run
/// while things are broken. Storage with no file behind it cannot leak one.
///
/// Shared between two instances by handing the same object to both, which is
/// how the persistence round-trip tests ("reloaded" stores) work without a
/// filesystem in the loop.
final class InMemoryRecentsStorage: RecentsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    /// - Parameter seeded: pre-existing contents, for tests that need a store
    ///   to load something it did not itself write — including deliberate
    ///   garbage, to prove a corrupt store degrades to empty rather than
    ///   crashing.
    init(seeded: Data? = nil) {
        self.data = seeded
    }

    func read() -> Data? {
        lock.withLock { data }
    }

    func write(_ data: Data) {
        lock.withLock { self.data = data }
    }
}
