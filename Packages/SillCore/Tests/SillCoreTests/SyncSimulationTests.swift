import Foundation
import Testing

@testable import SillCore

/// Randomised multi-device simulation. Properties checked after a full sweep:
/// 1. every replica ends with the same live notes,
/// 2. no text a user wrote is lost unless a later edit was made with knowledge of it.
@Suite struct SyncSimulationTests {
    struct UserWrite {
        let noteID: UUID
        let content: String?  // nil for a delete
        let version: Version
        let vectorAtWrite: VersionVector
    }

    @Test(arguments: [UInt64](1...16))
    func replicasConvergeAndPreserveEveryUnsupersededEdit(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        let replicas = [try Replica("Mac"), try Replica("iPhone"), try Replica("iPad")]
        let hub = replicas[0]
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = 0.0
        var writes: [UserWrite] = []
        var knownIDs: [UUID] = []

        for step in 0..<400 {
            clock += Double(Int.random(in: 0...3, using: &rng))  // ties on purpose
            let now = t0.addingTimeInterval(clock)
            let replica = replicas.randomElement(using: &rng)!
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...2:
                let note = try replica.store.createNote(content: "s\(step) \(replica.name) new", now: now)
                knownIDs.append(note.id)
                writes.append(
                    UserWrite(
                        noteID: note.id, content: note.content, version: note.version,
                        vectorAtWrite: try replica.store.vector()))
            case 3...6:
                guard let id = knownIDs.randomElement(using: &rng), try replica.store.note(id: id) != nil else {
                    continue
                }
                let before = try replica.store.vector()
                if let note = try replica.store.updateNote(id: id, content: "s\(step) \(replica.name) edit", now: now) {
                    writes.append(
                        UserWrite(noteID: id, content: note.content, version: note.version, vectorAtWrite: before))
                }
            case 7:
                guard let id = knownIDs.randomElement(using: &rng) else { continue }
                let before = try replica.store.vector()
                if let note = try replica.store.deleteNote(id: id, now: now), note.deletedAt == now {
                    writes.append(UserWrite(noteID: id, content: nil, version: note.version, vectorAtWrite: before))
                }
            default:
                guard replica.id != hub.id else { continue }
                try SyncRound.run(client: replica, server: hub)
            }
        }

        // Full sweep: two passes through the hub carry everything everywhere.
        for _ in 0..<2 {
            for replica in replicas where replica.id != hub.id {
                try SyncRound.run(client: replica, server: hub)
            }
        }

        // 1. Convergence.
        let expected = try hub.liveContents()
        for replica in replicas {
            #expect(try replica.liveContents() == expected, "replica \(replica.name) diverged (seed \(seed))")
        }
        // Extra sweep is a no-op.
        for replica in replicas where replica.id != hub.id {
            let result = try SyncRound.run(client: replica, server: hub)
            #expect(result.server == ApplyResult() && result.client == ApplyResult(), "not quiescent (seed \(seed))")
        }

        // 2. Preservation. A write is legitimately superseded only by a later write or delete of the
        //    same note made by someone who had already seen it (or by the same device's own next write).
        let survivors = expected.values
        for write in writes {
            guard let content = write.content else { continue }
            let superseded = writes.contains { later in
                later.noteID == write.noteID && later.version != write.version
                    && (later.version.device == write.version.device
                        ? later.version.seq > write.version.seq
                        : later.vectorAtWrite.contains(write.version))
            }
            if !superseded {
                let survived = survivors.contains { $0 == content || $0.hasPrefix(content + " (Conflict from") }
                #expect(survived, "lost '\(content)' (seed \(seed))")
            }
        }
    }
}
