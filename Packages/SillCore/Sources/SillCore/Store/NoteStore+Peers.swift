import Foundation
import GRDB

extension NoteStore {
    public func peers() throws -> [Peer] {
        try writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, name, cert_fingerprint, paired_at, last_sync_at, kind FROM peer ORDER BY paired_at"
            ).map(Self.peer)
        }
    }

    public func peer(fingerprint: Data) throws -> Peer? {
        try writer.read { db in
            try Row.fetchOne(
                db,
                sql:
                    "SELECT id, name, cert_fingerprint, paired_at, last_sync_at, kind FROM peer WHERE cert_fingerprint = ?",
                arguments: [fingerprint]
            ).map(Self.peer)
        }
    }

    public func peer(id: DeviceID) throws -> Peer? {
        try writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT id, name, cert_fingerprint, paired_at, last_sync_at, kind FROM peer WHERE id = ?",
                arguments: [id.uuidString]
            ).map(Self.peer)
        }
    }

    /// Adds or refreshes a trusted device (pairing, or a peer saying hello with a new name or
    /// kind). A nil `kind` leaves whatever is already known in place: pairing does not carry one.
    public func addPeer(
        id: DeviceID, name: String, fingerprint: Data, kind: DeviceKind? = nil, now: Date = Date()
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO peer(id, name, cert_fingerprint, paired_at, kind) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        cert_fingerprint = excluded.cert_fingerprint,
                        kind = COALESCE(excluded.kind, peer.kind)
                    """,
                arguments: [id.uuidString, name, fingerprint, now.timeIntervalSince1970, kind?.rawValue]
            )
        }
    }

    public func removePeer(id: DeviceID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM peer WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func markSynced(peerID: DeviceID, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE peer SET last_sync_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, peerID.uuidString])
        }
    }

    private static func peer(_ row: Row) throws -> Peer {
        guard let id = UUID(uuidString: row["id"]) else { throw StoreError.corruptRow("peer \(row["id"] as String)") }
        let lastSync: Double? = row["last_sync_at"]
        let kind: String? = row["kind"]
        return Peer(
            id: id,
            name: row["name"],
            fingerprint: row["cert_fingerprint"],
            pairedAt: Date(timeIntervalSince1970: row["paired_at"]),
            lastSyncAt: lastSync.map(Date.init(timeIntervalSince1970:)),
            kind: kind.flatMap(DeviceKind.init(rawValue:))
        )
    }
}
