import Foundation

/// The subset of tilt's `UIResource` Fulcrum reads.
///
/// Every field is optional below `metadata.name`: tilt's objects carry far more
/// than this, and unknown or absent fields must never fail a decode.
public struct UIResource: Codable, Sendable, Equatable {
    public struct Metadata: Codable, Sendable, Equatable {
        public var name: String
        public var resourceVersion: String?
        /// Observed shape is a single entry whose key equals its value
        /// (e.g. `{"ai": "ai"}`); `(Tiltfile)` omits this key entirely.
        public var labels: [String: String]?
    }

    public struct DisableStatus: Codable, Sendable, Equatable {
        /// `"Enabled"` or `"Disabled"`.
        public var state: String?
    }

    /// Present only while a resource is blocked on another resource's build.
    public struct Waiting: Codable, Sendable, Equatable {
        public struct Reference: Codable, Sendable, Equatable {
            public var group: String?
            public var apiVersion: String?
            public var kind: String?
            public var name: String?
        }
        public var reason: String?
        public var on: [Reference]?
    }

    public struct EndpointLink: Codable, Sendable, Equatable {
        public var url: String?
    }

    public struct BuildRecord: Codable, Sendable, Equatable {
        public var startTime: String?
        public var finishTime: String?
        public var error: String?
    }

    /// One entry of `status.conditions`. tilt reports `Ready` and `UpToDate`
    /// as strings, not booleans (`"True"` / `"False"`) — Fulcrum's uptime
    /// column reads `Ready`'s `lastTransitionTime`, not `UpToDate`'s: the two
    /// often share a timestamp because a successful rebuild re-stamps both at
    /// once, but `UpToDate` describes the build, not whether the resource is
    /// currently running.
    public struct Condition: Codable, Sendable, Equatable {
        public var type: String?
        public var status: String?
        public var lastTransitionTime: String?
        public var reason: String?

        public init(type: String? = nil, status: String? = nil, lastTransitionTime: String? = nil, reason: String? = nil) {
            self.type = type
            self.status = status
            self.lastTransitionTime = lastTransitionTime
            self.reason = reason
        }
    }

    /// One entry of `status.specs`. tilt reports an array; the first entry's
    /// `type` is what the dashboard's Type column shows.
    public struct Spec: Codable, Sendable, Equatable {
        public var id: String?
        public var type: String?
    }

    public struct Status: Codable, Sendable, Equatable {
        /// One of `pending`, `in_progress`, `not_applicable`, `ok`, `error`, `none`.
        public var updateStatus: String?
        /// One of `unknown`, `pending`, `ok`, `error`, `not_applicable`, `none`.
        public var runtimeStatus: String?
        public var disableStatus: DisableStatus?
        public var buildHistory: [BuildRecord]?
        public var pendingBuildSince: String?
        /// tilt's own display ordering.
        public var order: Int?
        public var specs: [Spec]?
        public var waiting: Waiting?
        public var endpointLinks: [EndpointLink]?
        /// Defaulted so every existing call site building a `Status` by hand
        /// (tests, mainly) keeps compiling without having to name a field
        /// they don't care about.
        public var conditions: [Condition]? = nil
    }

    public var metadata: Metadata
    public var status: Status?
}

public struct UIResourceList: Codable, Sendable {
    public struct ListMetadata: Codable, Sendable {
        public var resourceVersion: String?
    }
    public var metadata: ListMetadata
    public var items: [UIResource]
}
