import Foundation
import Observation

/// The app's last-known notification permission, refreshed from an async read
/// that overlapping callers can start at any time.
///
/// The refresh is not something Fulcrum can schedule. macOS never tells an app
/// its notification permission changed, so the only way to notice is to re-read
/// on every activation — and a user resolving a denial in System Settings
/// generates a burst of activations (leave Fulcrum, come back, leave again),
/// each starting a read that races the ones before it.
///
/// That race had a visible consequence: an earlier read returning `.denied`
/// could land *after* a later one returned `.authorized` and leave the Settings
/// pane showing a "notifications are denied" notice about a denial the user had
/// just fixed — with nothing they could do from inside the app to clear it,
/// since the only remedy is the System Settings trip they had already made.
///
/// So a read publishes its answer if and only if it is still the newest read
/// outstanding. This is the same discipline `LogPaneModel.ifCurrent(_:_:)`
/// applies to a stream session, for the same reason and after the same class of
/// bug: cancellation is a request, and a task that has already got its answer
/// walks straight past one. Identity — here, "was another refresh started after
/// mine?" — is the only thing that settles it.
@Observable
@MainActor
public final class AuthorizationState {
    /// The newest answer anything has read. `@Observable`, so the Settings
    /// pane's denial notice updates the moment one lands.
    public private(set) var authorization: NotificationAuthorization = .notDetermined

    /// Counts refreshes started, and so names the newest one. A monotonic
    /// counter rather than a token object because the comparison is "is mine
    /// the last one started", which an integer answers exactly.
    @ObservationIgnored private var newestRead = 0
    @ObservationIgnored private let read: @MainActor () async -> NotificationAuthorization

    /// `read` is the actual permission query. Injected rather than called
    /// directly so this type — and the staleness rule, which is the only part
    /// worth testing — stays free of `UserNotifications`, which `FulcrumKit`
    /// cannot import.
    public init(read: @escaping @MainActor () async -> NotificationAuthorization) {
        self.read = read
    }

    /// Reads the permission and publishes it if no newer read has started in
    /// the meantime.
    ///
    /// Returns what THIS read saw, whether or not it was published. A caller
    /// that just prompted the user needs its own answer — handing it
    /// `authorization` instead would hand it whatever a concurrent refresh
    /// happened to have stored, which is the same staleness one level up.
    @discardableResult
    public func refresh() async -> NotificationAuthorization {
        newestRead += 1
        let token = newestRead

        let value = await read()

        // Not `Task.isCancelled`: nothing cancels these, and a read that has
        // already returned would ignore it anyway. Superseded is not an error
        // — the newer read's answer is simply the true one.
        if token == newestRead { authorization = value }
        return value
    }
}
