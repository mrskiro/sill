import Foundation
import Testing
@testable import SillCore

@Suite struct SyncResolutionTests {
    let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ content: String, by device: UUID, seq: Int64, at: Date? = nil, deleted: Bool = false) -> Note {
        Note(id: UUID(uuidString: "11111111-0000-0000-0000-000000000000")!, content: content,
             createdAt: t0, updatedAt: at ?? t0, deletedAt: deleted ? (at ?? t0) : nil,
             version: Version(device: device, seq: seq))
    }

    @Test func decideFollowsTheVectorRules() {
        let mine = note("x", by: a, seq: 3)
        let theirs = note("y", by: b, seq: 5)

        #expect(SyncResolution.decide(incoming: theirs, local: nil, senderVector: VersionVector(), localVector: VersionVector()) == .insert)
        #expect(SyncResolution.decide(incoming: theirs, local: nil, senderVector: VersionVector(), localVector: VersionVector([b: 5])) == .keep)
        #expect(SyncResolution.decide(incoming: mine, local: mine, senderVector: VersionVector(), localVector: VersionVector()) == .keep)
        // Sender had seen my version → theirs descends from mine.
        #expect(SyncResolution.decide(incoming: theirs, local: mine, senderVector: VersionVector([a: 3]), localVector: VersionVector([a: 3])) == .overwrite)
        // I had seen theirs → mine descends from theirs.
        #expect(SyncResolution.decide(incoming: theirs, local: mine, senderVector: VersionVector([b: 5]), localVector: VersionVector([a: 3, b: 5])) == .keep)
        // Neither → concurrent.
        #expect(SyncResolution.decide(incoming: theirs, local: mine, senderVector: VersionVector([b: 5]), localVector: VersionVector([a: 3])) == .concurrent)
    }

    @Test func newerEditWinsAndOlderBecomesConflictCopy() {
        let older = note("old text", by: a, seq: 1, at: t0)
        let newer = note("new text", by: b, seq: 1, at: t0.addingTimeInterval(10))
        let resolution = SyncResolution.resolve(local: older, incoming: newer) { $0 == self.a ? "Mac" : "iPhone" }

        #expect(resolution.winner == newer)
        let copy = resolution.conflictCopy
        #expect(copy?.content == "old text (Conflict from Mac)")
        #expect(copy?.id == SyncResolution.conflictCopyID(noteID: older.id, loserVersion: older.version))
        // Symmetric: resolving from the other side produces the same copy.
        let mirrored = SyncResolution.resolve(local: newer, incoming: older) { $0 == self.a ? "Mac" : "iPhone" }
        #expect(mirrored.winner == newer)
        #expect(mirrored.conflictCopy == copy)
    }

    @Test func equalTimestampsBreakTiesByDeviceIDDeterministically() {
        let fromA = note("a", by: a, seq: 1)
        let fromB = note("b", by: b, seq: 1)
        let one = SyncResolution.resolve(local: fromA, incoming: fromB) { _ in "x" }
        let two = SyncResolution.resolve(local: fromB, incoming: fromA) { _ in "x" }
        #expect(one.winner == fromB)
        #expect(two.winner == fromB)
        #expect(one.conflictCopy == two.conflictCopy)
    }

    @Test func identicalContentNeedsNoCopy() {
        let x = note("same", by: a, seq: 2)
        let y = note("same", by: b, seq: 9)
        let resolution = SyncResolution.resolve(local: x, incoming: y) { _ in "x" }
        #expect(resolution.conflictCopy == nil)
        #expect(resolution.winner == y)
    }

    @Test func liveNoteBeatsTombstone() {
        let live = note("keep me", by: a, seq: 4)
        let dead = note("", by: b, seq: 7, at: t0.addingTimeInterval(100), deleted: true)
        #expect(SyncResolution.resolve(local: live, incoming: dead) { _ in "x" } == SyncResolution(winner: live, conflictCopy: nil))
        #expect(SyncResolution.resolve(local: dead, incoming: live) { _ in "x" } == SyncResolution(winner: live, conflictCopy: nil))
    }

    @Test func blankLoserIsNotCopied() {
        let blank = note("  \n", by: a, seq: 1, at: t0)
        let text = note("text", by: b, seq: 1, at: t0.addingTimeInterval(1))
        #expect(SyncResolution.resolve(local: blank, incoming: text) { _ in "x" }.conflictCopy == nil)
    }

    @Test func conflictMarkerGoesOnTheFirstNonBlankLine() {
        #expect(NoteTitle.markingConflict(in: "# Title\nbody", from: "iPhone") == "# Title (Conflict from iPhone)\nbody")
        #expect(NoteTitle.markingConflict(in: "\n\n  x", from: "Mac") == "\n\n  x (Conflict from Mac)")
        #expect(NoteTitle.markingConflict(in: "", from: "Mac") == " (Conflict from Mac)")
    }

    @Test func uuidV5IsStableAndWellFormed() {
        let ns = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")! // DNS namespace
        // Known RFC 4122 test vector: uuid5(DNS, "www.example.com")
        #expect(UUID.v5(namespace: ns, name: "www.example.com").uuidString == "2ED6657D-E927-568B-95E1-2665A8AEA6A2")
    }
}
