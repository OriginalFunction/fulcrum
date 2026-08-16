import Foundation

/// A project Fulcrum has seen running at some point.
///
/// Identified by web port rather than `TiltInstance.InstanceID`. `InstanceID` is
/// `(server, token)` and tilt regenerates both on every start, so keying on it
/// would record a fresh entry each time you restart the same project. The port
/// is what a project keeps across runs.
public struct RecentProject: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var displayName: String
    public var lastPort: Int
    public var lastSeen: Date
    public var isPinned: Bool
    /// The Tiltfile path resolved for this project the last time it was
    /// running, if any. `nil` for a project Fulcrum has only ever seen via
    /// discovery, never long enough for its session to resolve. Keys an
    /// `InstanceAliases` lookup for this row, so a rename applies to a
    /// stopped project too — and, via `RecentsStore.updateResolvedName`, is
    /// what lets `displayName` above be captured while the project was still
    /// running and survive after it stops, when there is no live apiserver
    /// left to re-ask.
    public var tiltfilePath: String?

    /// `displayName` falls back to `tilt-<lastPort>` when given empty —
    /// display sites must never render a blank row, and this is the one place
    /// that guarantee is kept for a persisted value that could in principle be
    /// constructed, or decoded off disk, with anything.
    public init(
        id: String, displayName: String, lastPort: Int, lastSeen: Date,
        isPinned: Bool = false, tiltfilePath: String? = nil
    ) {
        self.id = id
        self.displayName = Self.resolvedDisplayName(displayName, forPort: lastPort)
        self.lastPort = lastPort
        self.lastSeen = lastSeen
        self.isPinned = isPinned
        self.tiltfilePath = tiltfilePath
    }

    private static func resolvedDisplayName(_ displayName: String, forPort port: Int) -> String {
        displayName.isEmpty ? ProjectIdentity.fallbackName(forPort: port) : displayName
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, lastPort, lastSeen, isPinned, tiltfilePath
    }

    /// Custom rather than synthesized so a corrupt or empty `displayName`
    /// read back from `recents.json` gets the same guard as construction —
    /// the synthesized decoder would assign the raw (possibly empty) string
    /// straight to the stored property, bypassing it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        lastPort = try container.decode(Int.self, forKey: .lastPort)
        displayName = Self.resolvedDisplayName(try container.decode(String.self, forKey: .displayName), forPort: lastPort)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        // `decodeIfPresent`, not `decode`: existing `recents.json` files
        // written before this field existed have no `tiltfilePath` key at
        // all, and that must decode to nil rather than fail the whole entry.
        tiltfilePath = try container.decodeIfPresent(String.self, forKey: .tiltfilePath)
    }
}
