import Foundation
import Testing
@testable import SillCore

@Suite struct NoteStoreTests {
    private func makeStore(name: String = "Test Mac") throws -> (AppDatabase, NoteStore) {
        let db = try AppDatabase.inMemory()
        return (db, try NoteStore(database: db, deviceName: name))
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var t1: Date { t0.addingTimeInterval(60) }
    private var t2: Date { t0.addingTimeInterval(120) }

    @Test func createsNotesAndListsNewestFirst() throws {
        let (_, store) = try makeStore()
        let a = try store.createNote(content: "first", now: t0)
        let b = try store.createNote(content: "second", now: t1)

        #expect(try store.liveNotes().map(\.id) == [b.id, a.id])
        #expect(try store.lastEditedNote()?.id == b.id)
        #expect(a.version == Version(device: store.deviceID, seq: 1))
        #expect(b.version == Version(device: store.deviceID, seq: 2))
        #expect(try store.vector()[store.deviceID] == 2)
    }

    @Test func updateBumpsVersionOnlyWhenContentChanges() throws {
        let (_, store) = try makeStore()
        let note = try store.createNote(content: "draft", now: t0)

        let updated = try store.updateNote(id: note.id, content: "draft 2", now: t1)
        #expect(updated?.content == "draft 2")
        #expect(updated?.updatedAt == t1)
        #expect(updated?.version.seq == 2)

        let unchanged = try store.updateNote(id: note.id, content: "draft 2", now: t2)
        #expect(unchanged?.version.seq == 2)
        #expect(unchanged?.updatedAt == t1)
        #expect(try store.vector()[store.deviceID] == 2)
    }

    @Test func deleteHidesNoteButKeepsTombstone() throws {
        let (_, store) = try makeStore()
        let note = try store.createNote(content: "bye", now: t0)

        let deleted = try store.deleteNote(id: note.id, now: t1)
        #expect(deleted?.isDeleted == true)
        #expect(deleted?.content == "")
        #expect(deleted?.version.seq == 2)
        #expect(try store.liveNotes().isEmpty)
        #expect(try store.note(id: note.id)?.deletedAt == t1)

        let pending = try store.changes(since: VersionVector())
        #expect(pending.map(\.id) == [note.id])
        #expect(pending.first?.isDeleted == true)

        // Deleting twice does not allocate another version.
        #expect(try store.deleteNote(id: note.id, now: t2)?.version.seq == 2)
    }

    @Test func updatingDeletedNoteRevivesIt() throws {
        let (_, store) = try makeStore()
        let note = try store.createNote(content: "keep", now: t0)
        try store.deleteNote(id: note.id, now: t1)

        let revived = try store.updateNote(id: note.id, content: "keep again", now: t2)
        #expect(revived?.isDeleted == false)
        #expect(revived?.version.seq == 3)
        #expect(try store.liveNotes().map(\.id) == [note.id])
    }

    @Test func changesSinceVectorSkipsRowsTheRemoteHasSeen() throws {
        let (_, store) = try makeStore()
        try store.createNote(content: "1", now: t0)
        try store.createNote(content: "2", now: t1)
        let snapshot = try store.vector()
        let third = try store.createNote(content: "3", now: t2)

        #expect(try store.changes(since: snapshot).map(\.id) == [third.id])
        #expect(try store.changes(since: VersionVector()).count == 3)
        #expect(try store.changes(since: store.vector()).isEmpty)
    }

    @Test func aVersionCanNeverBeStoredTwice() throws {
        let (_, store) = try makeStore()
        let note = try store.createNote(content: "one", now: t0)
        let duplicate = Note(id: UUID(), content: "same version, different note", createdAt: t0, updatedAt: t0, version: note.version)
        // The schema itself refuses a second row with an existing (device, seq), whatever the code above it does.
        #expect(throws: (any Error).self) {
            try store.writer.write { db in try NoteRecord(duplicate).insert(db) }
        }
    }

    @Test func changesSnapshotPairsNotesWithTheirVector() throws {
        let (_, store) = try makeStore()
        try store.createNote(content: "a", now: t0)
        let snapshot = try store.changesSnapshot(since: VersionVector())
        #expect(snapshot.notes.count == 1)
        #expect(snapshot.vector == (try store.vector()))
    }

    @Test func saveEditWritesOnTopOfTheExpectedVersion() throws {
        let (_, store) = try makeStore()
        let note = try store.createNote(content: "base", now: t0)
        let result = try #require(try store.saveEdit(id: note.id, text: "base typed", expecting: note.version, now: t1))
        #expect(result.note.content == "base typed")
        #expect(result.note.version.seq == 2)
        #expect(result.copiedAside == nil)
        // Same text again: no new version.
        #expect(try store.saveEdit(id: note.id, text: "base typed", expecting: result.note.version)?.note.version.seq == 2)
    }

    @Test func saveEditPreservesAVersionThatArrivedUnderneathTheEditor() throws {
        let (_, store) = try makeStore()
        let phone = UUID()
        try store.addPeer(id: phone, name: "Phone", fingerprint: Data(repeating: 1, count: 32))
        let note = try store.createNote(content: "base", now: t0)
        // Sync replaces the note while the editor still holds version 1.
        var remote = note
        remote.content = "phone wrote this"
        remote.version = Version(device: phone, seq: 1)
        try store.apply([remote], senderID: phone, senderName: "Phone", senderVector: VersionVector([phone: 1, store.deviceID: 1]))

        let result = try #require(try store.saveEdit(id: note.id, text: "base typed", expecting: note.version, now: t2))
        #expect(result.note.content == "base typed")
        #expect(result.note.version.device == store.deviceID)
        #expect(result.copiedAside?.content == "phone wrote this (Conflict from Phone)")
        #expect(try store.liveNotes().count == 2)

        // Saving again with the now-current version copies nothing more.
        let again = try #require(try store.saveEdit(id: note.id, text: "base typed more", expecting: result.note.version, now: t2))
        #expect(again.copiedAside == nil)
    }

    @Test func saveEditRevivesADeletedNote() throws {
        let (_, store) = try makeStore()
        let note = try store.createNote(content: "keep", now: t0)
        let deleted = try #require(try store.deleteNote(id: note.id, now: t1))
        let result = try #require(try store.saveEdit(id: note.id, text: "keep typing", expecting: note.version, now: t2))
        #expect(result.note.isDeleted == false)
        #expect(result.copiedAside == nil)
        #expect(result.note.version.seq > deleted.version.seq)
    }

    @Test func deviceIdentityPersistsAcrossReopen() throws {
        let (db, first) = try makeStore(name: "Mac")
        let second = try NoteStore(database: db, deviceName: "Mac renamed")

        #expect(second.deviceID == first.deviceID)
        #expect(second.deviceName == "Mac renamed")
    }
}
