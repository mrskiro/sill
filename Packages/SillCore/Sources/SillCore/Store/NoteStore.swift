import Foundation
import GRDB

/// The single write path for notes. User edits, sync application and conflict resolution
/// all go through here, so every write gets a fresh `Version` and updates the local vector.
public final class NoteStore: Sendable {
    let writer: any DatabaseWriter
    public let deviceID: DeviceID
    public let deviceName: String

    /// Creates the local device identity on first use; reuses it afterwards.
    public init(database: AppDatabase, deviceName: String) throws {
        writer = database.writer
        let record = try writer.write { db -> DeviceRecord in
            if var existing = try DeviceRecord.fetchOne(db) {
                if existing.name != deviceName {
                    existing.name = deviceName
                    try existing.update(db)
                }
                return existing
            }
            let created = DeviceRecord(id: UUID().uuidString, name: deviceName)
            try created.insert(db)
            return created
        }
        guard let id = UUID(uuidString: record.id) else { throw StoreError.corruptRow("device \(record.id)") }
        deviceID = id
        self.deviceName = record.name
    }

    // MARK: - Reads

    public func note(id: UUID) throws -> Note? {
        try writer.read { db in
            try NoteRecord.fetchOne(db, key: id.uuidString)?.toNote()
        }
    }

    /// Non-deleted notes, most recently edited first.
    public func liveNotes() throws -> [Note] {
        try writer.read(Self.fetchLiveNotes)
    }

    public func lastEditedNote() throws -> Note? {
        try writer.read { db in
            try NoteRecord
                .filter(sql: "deleted_at IS NULL")
                .order(sql: "updated_at DESC, id")
                .fetchOne(db)?
                .toNote()
        }
    }

    /// Emits the live note list whenever it changes. Drives the sidebar.
    public func observeLiveNotes() -> AsyncValueObservation<[Note]> {
        ValueObservation
            .tracking(Self.fetchLiveNotes)
            .values(in: writer)
    }

    public func vector() throws -> VersionVector {
        try writer.read(Self.fetchVector)
    }

    /// Every note (including tombstones) whose version the remote replica has not seen.
    /// Scans all rows; fine for the volume of a scratchpad.
    public func changes(since remote: VersionVector) throws -> [Note] {
        try changesSnapshot(since: remote).notes
    }

    /// The outbound batch together with the vector *as of the same snapshot*. A round must send
    /// exactly this pair: a vector read later could include a write whose row was never sent,
    /// and the receiver would then believe it had seen that row forever.
    public func changesSnapshot(since remote: VersionVector) throws -> (notes: [Note], vector: VersionVector) {
        try writer.read { db in
            let notes = try NoteRecord
                .order(sql: "origin_device, origin_seq")
                .fetchAll(db)
                .map { try $0.toNote() }
                .filter { !remote.contains($0.version) }
            return (notes, try Self.fetchVector(db))
        }
    }

    // MARK: - Local writes

    @discardableResult
    public func createNote(content: String, now: Date = Date()) throws -> Note {
        try writer.write { db in
            let note = Note(
                id: UUID(),
                content: content,
                createdAt: now,
                updatedAt: now,
                version: try self.nextVersion(db)
            )
            try NoteRecord(note).insert(db)
            return note
        }
    }

    /// Replaces the content. Unchanged content is a no-op (no new version).
    /// Updating a tombstoned note revives it: an edit always wins over a delete.
    @discardableResult
    public func updateNote(id: UUID, content: String, now: Date = Date()) throws -> Note? {
        try writer.write { db in
            guard var note = try NoteRecord.fetchOne(db, key: id.uuidString)?.toNote() else { return nil }
            if note.content == content, !note.isDeleted { return note }
            note.content = content
            note.updatedAt = now
            note.deletedAt = nil
            note.version = try self.nextVersion(db)
            try NoteRecord(note).update(db)
            return note
        }
    }

    /// Soft delete: keeps the row as a tombstone with empty content.
    @discardableResult
    public func deleteNote(id: UUID, now: Date = Date()) throws -> Note? {
        try writer.write { db in
            guard var note = try NoteRecord.fetchOne(db, key: id.uuidString)?.toNote() else { return nil }
            if note.isDeleted { return note }
            note.content = ""
            note.updatedAt = now
            note.deletedAt = now
            note.version = try self.nextVersion(db)
            try NoteRecord(note).update(db)
            return note
        }
    }

    // MARK: - Internals

    /// Allocates the next local version and records it in the vector, inside the caller's transaction.
    func nextVersion(_ db: Database) throws -> Version {
        let current = try SeenRecord.fetchOne(db, key: deviceID.uuidString)?.maxSeq ?? 0
        let next = current + 1
        try SeenRecord(deviceId: deviceID.uuidString, maxSeq: next).save(db)
        return Version(device: deviceID, seq: next)
    }

    private static func fetchLiveNotes(_ db: Database) throws -> [Note] {
        try NoteRecord
            .filter(sql: "deleted_at IS NULL")
            .order(sql: "updated_at DESC, id")
            .fetchAll(db)
            .map { try $0.toNote() }
    }

    static func fetchVector(_ db: Database) throws -> VersionVector {
        var vector = VersionVector()
        for row in try SeenRecord.fetchAll(db) {
            guard let device = UUID(uuidString: row.deviceId) else { throw StoreError.corruptRow("seen \(row.deviceId)") }
            vector.record(Version(device: device, seq: row.maxSeq))
        }
        return vector
    }
}
