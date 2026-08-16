import Foundation

/// Vends an isolated `UserDefaults` for a test that never touches disk.
///
/// Tests previously isolated themselves with `UserDefaults(suiteName: UUID().uuidString)!`
/// — a *named suite*, which Foundation persists to a plist under
/// `~/Library/Preferences` the moment anything calls `set(_:forKey:)` on it.
/// Confirmed as real, accumulating damage on this machine, not a theoretical
/// concern: run repeatedly, that left 589 such plists in 24 hours.
///
/// A disk-backed cleanup (`removePersistentDomain(forName:)`, even paired
/// with deleting the file directly and calling `synchronize()`, all tried
/// here first) cannot reliably fix this: the actual persistence for a named
/// suite is owned by `cfprefsd`, a system daemon that flushes dirty state to
/// disk on its own asynchronous schedule, independent of this test
/// process's lifetime. Verified empirically — a suite removed, synchronized,
/// and file-deleted at `atexit` was gone immediately after `swift test`
/// returned, and back on disk (recreated by `cfprefsd`) a few seconds later.
/// Nothing this process does at exit can out-race a daemon that keeps
/// running, and still holds dirty state, after this process is gone.
///
/// `InMemoryUserDefaults` below sidesteps that entirely: it is a
/// `UserDefaults` subclass that overrides every accessor this codebase's
/// `UserDefaults`-backed types (`SettingsStore`, `InstanceAliases`) actually
/// call, backing them with a plain in-memory dictionary instead of
/// delegating to `super`. There is no named domain, so `cfprefsd` never
/// hears about it, and there is no file for it to ever write.
enum TestUserDefaults {
    /// A fresh, isolated, disk-free `UserDefaults`. Every call site that
    /// otherwise constructs `UserDefaults(suiteName: UUID().uuidString)!`
    /// directly should go through this instead.
    static func fresh() -> UserDefaults {
        InMemoryUserDefaults()
    }
}

/// Overrides exactly the accessors `SettingsStore` and `InstanceAliases`
/// call (`set(_:forKey:)`, `string(forKey:)`, `bool(forKey:)`,
/// `object(forKey:)`, `double(forKey:)`, `dictionary(forKey:)`) — if a
/// production type starts reading or writing through a different
/// `UserDefaults` accessor, it will silently fall through to `super`'s real,
/// disk-backed implementation here, so any new accessor a production type
/// starts using must be added below too.
///
/// `object(forKey:)` and `double(forKey:)` were added for
/// `SettingsStore.logPaneHeight`, which — unlike every other setting, which
/// falls back from an *unrecognised* stored value — has to distinguish "never
/// set" (defaults to 220) from "explicitly stored" via `object(forKey:)`,
/// since `double(forKey:)` alone returns `0` for both. Missing this override
/// exactly reproduced that ambiguity in tests: `settingsPersistToDefaults`
/// read back the 220 fallback instead of the height it had just stored,
/// because `object(forKey:)` was silently falling through to `super`'s real,
/// empty-domain implementation rather than seeing `storage` at all.
private final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    init() {
        // `init(suiteName:)` is the actual designated initializer — plain
        // `init()` is merely a convenience wrapper around it passing `nil`.
        // Neither, on its own, creates or touches a file; this subclass
        // never calls through to `super`'s storage regardless, since every
        // accessor below is overridden.
        super.init(suiteName: nil)!
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { () -> Void in
            if let value {
                storage[defaultName] = value
            } else {
                storage.removeValue(forKey: defaultName)
            }
        }
    }

    override func string(forKey defaultName: String) -> String? {
        lock.withLock { storage[defaultName] as? String }
    }

    override func bool(forKey defaultName: String) -> Bool {
        lock.withLock { storage[defaultName] as? Bool ?? false }
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { storage[defaultName] }
    }

    override func double(forKey defaultName: String) -> Double {
        lock.withLock { storage[defaultName] as? Double ?? 0 }
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        lock.withLock { storage[defaultName] as? [String: Any] }
    }
}
