import Foundation
import Testing

@testable import SillCore

@Suite struct SyncRoundTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func createEditDeleteFlowBothWays() throws {
        let mac = try Replica("Mac")
        let phone = try Replica("iPhone")

        let note = try mac.store.createNote(content: "from mac", now: at(0))
        try SyncRound.run(client: phone, server: mac)
        #expect(try phone.store.note(id: note.id)?.content == "from mac")
        #expect(try phone.store.note(id: note.id)?.version == note.version)  // adopted as-is

        try phone.store.updateNote(id: note.id, content: "edited on phone", now: at(10))
        try SyncRound.run(client: phone, server: mac)
        #expect(try mac.store.note(id: note.id)?.content == "edited on phone")

        try mac.store.deleteNote(id: note.id, now: at(20))
        try SyncRound.run(client: phone, server: mac)
        #expect(try phone.store.note(id: note.id)?.isDeleted == true)
        #expect(try phone.store.liveNotes().isEmpty)
        #expect(try mac.liveContents() == phone.liveContents())
    }

    @Test func roundIsIdempotentAndQuietWhenNothingChanged() throws {
        let mac = try Replica("Mac")
        let phone = try Replica("iPhone")
        try mac.store.createNote(content: "a", now: at(0))
        try phone.store.createNote(content: "b", now: at(1))
        try SyncRound.run(client: phone, server: mac)

        let second = try SyncRound.run(client: phone, server: mac)
        #expect(second.server == ApplyResult())
        #expect(second.client == ApplyResult())
        #expect(try phone.store.changes(since: try mac.store.vector()).isEmpty)
        #expect(try mac.store.changes(since: try phone.store.vector()).isEmpty)
    }

    @Test func concurrentEditsKeepBothTextsAndConverge() throws {
        let mac = try Replica("Mac")
        let phone = try Replica("iPhone")
        let note = try mac.store.createNote(content: "# Meeting\n- a", now: at(0))
        try SyncRound.run(client: phone, server: mac)

        try mac.store.updateNote(id: note.id, content: "# Meeting\n- a\n- mac line", now: at(10))
        try phone.store.updateNote(id: note.id, content: "# Meeting\n- a\n- phone line", now: at(20))
        let results = try SyncRound.run(client: phone, server: mac)

        #expect(results.server.conflicts == 1)
        #expect(results.server.conflictCopies == 1)
        #expect(results.client.conflicts == 0)  // the client only adopts the server's resolution

        let macLive = try mac.liveContents()
        #expect(macLive == (try phone.liveContents()))
        #expect(macLive[note.id] == "# Meeting\n- a\n- phone line")  // newer edit stays in place
        let copy = macLive.values.first { $0.hasPrefix("# Meeting (Conflict from Mac)") }
        #expect(copy == "# Meeting (Conflict from Mac)\n- a\n- mac line")
        #expect(macLive.count == 2)

        // A further round changes nothing.
        let again = try SyncRound.run(client: phone, server: mac)
        #expect(again.server == ApplyResult() && again.client == ApplyResult())
    }

    @Test func editWinsOverConcurrentDelete() throws {
        let mac = try Replica("Mac")
        let phone = try Replica("iPhone")
        let note = try mac.store.createNote(content: "draft", now: at(0))
        try SyncRound.run(client: phone, server: mac)

        try mac.store.deleteNote(id: note.id, now: at(10))
        try phone.store.updateNote(id: note.id, content: "draft, continued", now: at(5))
        try SyncRound.run(client: phone, server: mac)

        #expect(try mac.store.note(id: note.id)?.content == "draft, continued")
        #expect(try mac.store.note(id: note.id)?.isDeleted == false)
        #expect(try mac.liveContents() == phone.liveContents())
    }

    @Test func sameTextOnBothSidesIsNotAConflict() throws {
        let mac = try Replica("Mac")
        let phone = try Replica("iPhone")
        let note = try mac.store.createNote(content: "x", now: at(0))
        try SyncRound.run(client: phone, server: mac)
        try mac.store.updateNote(id: note.id, content: "same", now: at(1))
        try phone.store.updateNote(id: note.id, content: "same", now: at(2))
        let results = try SyncRound.run(client: phone, server: mac)
        #expect(results.server.conflicts == 1)
        #expect(results.server.conflictCopies == 0)
        #expect(try mac.liveContents().count == 1)
        #expect(try mac.liveContents() == phone.liveContents())
    }

    @Test func typingDuringTheRoundStillConvergesWithoutDuplicates() throws {
        let mac = try Replica("Mac")
        let phone = try Replica("iPhone")
        let note = try mac.store.createNote(content: "base", now: at(0))
        try SyncRound.run(client: phone, server: mac)
        try mac.store.updateNote(id: note.id, content: "mac edit", now: at(10))
        try phone.store.updateNote(id: note.id, content: "phone edit", now: at(11))

        // Phase 1: client → server (server resolves: phone edit wins, mac edit copied).
        let toServer = try phone.store.changes(since: try mac.store.vector())
        try mac.store.apply(
            toServer, senderID: phone.id, senderName: phone.name, senderVector: try phone.store.vector())
        // The user keeps typing on the phone before phase 2 arrives.
        try phone.store.updateNote(id: note.id, content: "phone edit, more", now: at(12))
        // Phase 2: server → client.
        let toClient = try mac.store.changes(since: try phone.store.vector())
        try phone.store.apply(toClient, senderID: mac.id, senderName: mac.name, senderVector: try mac.store.vector())

        try SyncRound.run(client: phone, server: mac)
        let macLive = try mac.liveContents()
        #expect(macLive == (try phone.liveContents()))
        #expect(macLive[note.id] == "phone edit, more")
        #expect(macLive.values.filter { $0.contains("Conflict from") }.count == 1)
        #expect(macLive.values.contains("mac edit (Conflict from Mac)"))
    }

    @Test func changesTravelThroughAHubToAThirdDevice() throws {
        let mac = try Replica("Mac")
        let phone = try Replica("iPhone")
        let pad = try Replica("iPad")
        let fromPhone = try phone.store.createNote(content: "phone note", now: at(0))
        try SyncRound.run(client: phone, server: mac)
        try SyncRound.run(client: pad, server: mac)

        #expect(try pad.store.note(id: fromPhone.id)?.content == "phone note")
        #expect(try pad.store.note(id: fromPhone.id)?.version.device == phone.id)  // origin preserved

        try pad.store.updateNote(id: fromPhone.id, content: "edited on pad", now: at(5))
        try SyncRound.run(client: pad, server: mac)
        try SyncRound.run(client: phone, server: mac)
        #expect(try phone.store.note(id: fromPhone.id)?.content == "edited on pad")
        #expect(try mac.liveContents() == phone.liveContents())
        #expect(try mac.liveContents() == pad.liveContents())
    }
}
