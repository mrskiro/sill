import CryptoKit
import Foundation

/// What to do with one incoming snapshot, given the local row and both replicas' vectors.
public enum SyncDecision: Equatable, Sendable {
    /// No local row and this version is new: store it as-is.
    case insert
    /// The sender had already seen the local version, so its row descends from ours.
    case overwrite
    /// We had already seen the incoming version (or it is identical): nothing to do.
    case keep
    /// Neither side had seen the other's version: resolve (see `SyncResolution.resolve`).
    case concurrent
}

/// The outcome of resolving two concurrent versions of the same note.
public struct SyncResolution: Equatable, Sendable {
    /// Which existing version stays in the note's id. No new version is minted for it:
    /// the other side adopts it through the vector rule on the next exchange.
    public var winner: Note
    /// Content that would otherwise be lost, to be stored as a separate note.
    public var conflictCopy: ConflictCopy?

    public struct ConflictCopy: Equatable, Sendable {
        public var id: UUID
        public var content: String
        public var createdAt: Date
        public var updatedAt: Date
    }

    public static func decide(
        incoming: Note,
        local: Note?,
        senderVector: VersionVector,
        localVector: VersionVector
    ) -> SyncDecision {
        guard let local else {
            return localVector.contains(incoming.version) ? .keep : .insert
        }
        if local.version == incoming.version { return .keep }
        if senderVector.contains(local.version) { return .overwrite }
        if localVector.contains(incoming.version) { return .keep }
        return .concurrent
    }

    /// Data preservation over cleverness:
    /// - a live note beats a tombstone,
    /// - identical content converges on the greater version,
    /// - different content keeps the newer edit in place and copies the older one aside.
    public static func resolve(local: Note, incoming: Note, loserName: (DeviceID) -> String) -> SyncResolution {
        switch (local.isDeleted, incoming.isDeleted) {
        case (true, true):
            return SyncResolution(winner: greaterVersion(local, incoming), conflictCopy: nil)
        case (false, true):
            return SyncResolution(winner: local, conflictCopy: nil)
        case (true, false):
            return SyncResolution(winner: incoming, conflictCopy: nil)
        case (false, false):
            if local.content == incoming.content {
                return SyncResolution(winner: greaterVersion(local, incoming), conflictCopy: nil)
            }
            let (winner, loser) = newerEdit(local, incoming)
            guard !loser.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return SyncResolution(winner: winner, conflictCopy: nil)
            }
            let copy = ConflictCopy(
                id: conflictCopyID(noteID: loser.id, loserVersion: loser.version),
                content: NoteTitle.markingConflict(in: loser.content, from: loserName(loser.version.device)),
                createdAt: loser.createdAt,
                updatedAt: loser.updatedAt
            )
            return SyncResolution(winner: winner, conflictCopy: copy)
        }
    }

    /// Same id on every replica that resolves the same conflict, so copies never duplicate.
    public static func conflictCopyID(noteID: UUID, loserVersion: Version) -> UUID {
        UUID.v5(namespace: conflictNamespace, name: "\(noteID.uuidString)|\(loserVersion.device.uuidString)|\(loserVersion.seq)")
    }

    private static let conflictNamespace = UUID(uuidString: "6B4D3C3E-0F2A-4C1B-9E4D-5A1F0B7C2D11")!

    private static func greaterVersion(_ a: Note, _ b: Note) -> Note {
        if a.version.device == b.version.device {
            return a.version.seq >= b.version.seq ? a : b
        }
        return a.version.device.uuidString > b.version.device.uuidString ? a : b
    }

    private static func newerEdit(_ a: Note, _ b: Note) -> (winner: Note, loser: Note) {
        if a.updatedAt != b.updatedAt {
            return a.updatedAt > b.updatedAt ? (a, b) : (b, a)
        }
        return a.version.device.uuidString > b.version.device.uuidString ? (a, b) : (b, a)
    }
}

extension NoteTitle {
    /// Appends " (Conflict from <device>)" to the first non-blank line. Everything else is untouched.
    public static func markingConflict(in content: String, from deviceName: String) -> String {
        let marker = " (Conflict from \(deviceName))"
        var lines = content.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines[index] += marker
            return lines.joined(separator: "\n")
        }
        return content + marker
    }
}

extension UUID {
    /// RFC 4122 version 5 (SHA-1, name-based) UUID.
    static func v5(namespace: UUID, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
