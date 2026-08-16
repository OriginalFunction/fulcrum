import Foundation

/// A `uisessions` object from the apiserver. Carries far more than
/// `tiltfileKey` (featureFlags, runningTiltBuild, tiltStartTime, ...) — this
/// type decodes only what it needs and tolerates the rest.
public struct UISession: Codable, Sendable {
    public struct Status: Codable, Sendable {
        public var tiltfileKey: String?
    }
    public var status: Status
}

public struct UISessionList: Codable, Sendable {
    public var items: [UISession]
}
