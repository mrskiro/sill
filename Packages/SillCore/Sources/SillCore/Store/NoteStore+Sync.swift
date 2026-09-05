import Foundation
import GRDB

public struct ApplyResult: Equatable, Sendable {
    public var inserted = 0
    public var overwritten = 0
    public var kept = 0
    public var conflicts = 0
    public var conflictCopies = 0
}

extension NoteStore {
    /// Applies one batch of snapshots from a peer, in a single transaction, then merges the
    /// sender's vector into ours. Idempotent: re-applying the same batch changes nothing.
    @discardableResult
    public func apply(
        _ incoming: [Note],
        senderID: DeviceID,
        senderName: String,
        senderVector: VersionVector
    ) throws -> ApplyResult {
        try writer.write { db in
            var result = ApplyResult()
            let localVector = try Self.fetchVector(db)
            let names = try self.deviceNames(db, senderID: senderID, senderName: senderName)

            for snapshot in incoming {
                let local = try NoteRecord.fetchOne(db, key: snapshot.id.uuidString)?.toNote()
                switch SyncResolution.decide(incoming: snapshot, local: local, senderVector: senderVector, localVector: localVector) {
                case .insert:
                    try NoteRecord(snapshot).insert(db)
                    result.inserted += 1
                case .overwrite:
                    try NoteRecord(snapshot).update(db)
                    result.overwritten += 1
                case .keep:
                    result.kept += 1
                case .concurrent:
                    guard let local else { continue }
                    result.conflicts += 1
                    let resolution = SyncResolution.resolve(local: local, incoming: snapshot) { device in
                        names[device] ?? String(device.uuidString.prefix(8))
                    }
                    if resolution.winner.version != local.version {
                        try NoteRecord(resolution.winner).update(db)
                    }
                    if let copy = resolution.conflictCopy,
                       try NoteRecord.fetchOne(db, key: copy.id.uuidString) == nil {
                        let note = Note(
                            id: copy.id,
                            content: copy.content,
                            createdAt: copy.createdAt,
                            updatedAt: copy.updatedAt,
                            version: try self.nextVersion(db)
                        )
                        try NoteRecord(note).insert(db)
                        result.conflictCopies += 1
                    }
                }
            }

            try Self.mergeVector(db, with: senderVector)
            return result
        }
    }

    /// Names for conflict markers: ours, the sender's, and any paired peers.
    private func deviceNames(_ db: Database, senderID: DeviceID, senderName: String) throws -> [DeviceID: String] {
        var names: [DeviceID: String] = [deviceID: deviceName, senderID: senderName]
        for row in try Row.fetchAll(db, sql: "SELECT id, name FROM peer") {
            if let id = UUID(uuidString: row["id"]) { names[id] = row["name"] }
        }
        return names
    }

    static func mergeVector(_ db: Database, with other: VersionVector) throws {
        for (device, seq) in other.maxSeq {
            try db.execute(
                sql: """
                    INSERT INTO seen(device_id, max_seq) VALUES (?, ?)
                    ON CONFLICT(device_id) DO UPDATE SET max_seq = MAX(max_seq, excluded.max_seq)
                    """,
                arguments: [device.uuidString, seq]
            )
        }
    }
}
