import Foundation

public typealias DeviceID = UUID

/// One state of a note: which device wrote it, and that device's write counter at the time.
/// Two versions are comparable through a `VersionVector`; see `VersionVector.contains(_:)`.
public struct Version: Hashable, Codable, Sendable {
    public var device: DeviceID
    public var seq: Int64

    public init(device: DeviceID, seq: Int64) {
        self.device = device
        self.seq = seq
    }
}

/// A note is a Markdown string plus the minimum metadata needed to sync it.
/// There is no title field: the title is derived from the first line (`NoteTitle`).
public struct Note: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Tombstone. A deleted note keeps its row (with empty content) so that
    /// a device holding an older copy cannot resurrect it.
    public var deletedAt: Date?
    public var version: Version

    public init(
        id: UUID,
        content: String,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil,
        version: Version
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
    }

    public var isDeleted: Bool { deletedAt != nil }
    public var title: String { NoteTitle.title(of: content) }
}
