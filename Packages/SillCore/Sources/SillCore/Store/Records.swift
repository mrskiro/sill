import Foundation
import GRDB

/// Row shape of the `note` table. Timestamps are unix seconds (REAL) so the file stays
/// readable from the sqlite3 CLI: `datetime(updated_at, 'unixepoch')`.
struct NoteRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "note"

    var id: String
    var content: String
    var createdAt: Double
    var updatedAt: Double
    var deletedAt: Double?
    var originDevice: String
    var originSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case originDevice = "origin_device"
        case originSeq = "origin_seq"
    }

    init(_ note: Note) {
        id = note.id.uuidString
        content = note.content
        createdAt = note.createdAt.timeIntervalSince1970
        updatedAt = note.updatedAt.timeIntervalSince1970
        deletedAt = note.deletedAt?.timeIntervalSince1970
        originDevice = note.version.device.uuidString
        originSeq = note.version.seq
    }

    func toNote() throws -> Note {
        guard let noteID = UUID(uuidString: id), let device = UUID(uuidString: originDevice) else {
            throw StoreError.corruptRow("note \(id)")
        }
        return Note(
            id: noteID,
            content: content,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            deletedAt: deletedAt.map(Date.init(timeIntervalSince1970:)),
            version: Version(device: device, seq: originSeq)
        )
    }
}

struct DeviceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "device"
    var id: String
    var name: String
}

struct SeenRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "seen"
    var deviceId: String
    var maxSeq: Int64

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case maxSeq = "max_seq"
    }
}
