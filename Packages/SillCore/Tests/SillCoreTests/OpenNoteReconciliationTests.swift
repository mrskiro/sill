import Foundation
import Testing
@testable import SillCore

@Suite struct OpenNoteReconciliationTests {
    let mac = UUID(), phone = UUID()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ content: String, device: UUID, seq: Int64, deleted: Bool = false) -> Note {
        Note(id: UUID(uuidString: "22222222-0000-0000-0000-000000000000")!, content: content,
             createdAt: t0, updatedAt: t0, deletedAt: deleted ? t0 : nil, version: Version(device: device, seq: seq))
    }

    @Test func cleanEditorReloadsARemoteVersion() {
        let open = note("base", device: mac, seq: 1)
        let remote = note("remote edit", device: phone, seq: 4)
        #expect(OpenNoteReconciliation.decide(open: open, editorText: "base", current: remote) == .reload(remote))
    }

    @Test func sameVersionIsUnchangedEvenWhenDirty() {
        let open = note("base", device: mac, seq: 1)
        #expect(OpenNoteReconciliation.decide(open: open, editorText: "base typed", current: open) == .unchanged)
    }

    @Test func dirtyEditorKeepsTypingAndLeavesTheMergeToSave() {
        let open = note("base", device: mac, seq: 1)
        let remote = note("remote edit", device: phone, seq: 4)
        #expect(OpenNoteReconciliation.decide(open: open, editorText: "base typed", current: remote) == .unchanged)
    }

    @Test func dirtyEditorThatAlreadyMatchesTheRemoteJustReloads() {
        let open = note("base", device: mac, seq: 1)
        let remote = note("same text", device: phone, seq: 4)
        #expect(OpenNoteReconciliation.decide(open: open, editorText: "same text", current: remote) == .reload(remote))
    }

    @Test func remoteDeleteIsAcceptedOnlyByACleanEditor() {
        let open = note("base", device: mac, seq: 1)
        let tombstone = note("", device: phone, seq: 4, deleted: true)
        #expect(OpenNoteReconciliation.decide(open: open, editorText: "base", current: tombstone) == .deletedRemotely)
        #expect(OpenNoteReconciliation.decide(open: open, editorText: "base more", current: tombstone) == .unchanged)
        #expect(OpenNoteReconciliation.decide(open: open, editorText: "base", current: nil) == .deletedRemotely)
    }
}
