import Foundation
import Testing
@testable import SillCore

/// Server and client actors talking over in-memory channels: pairing, hello, rounds, pokes.
@Suite struct SyncSessionTests {
    struct Pair {
        let mac: Replica, phone: Replica
        let server: SyncServer, client: SyncClient
        let macCertificate: DeviceCertificate, phoneCertificate: DeviceCertificate
        var macFingerprint: Data { macCertificate.fingerprint }
        var phoneFingerprint: Data { phoneCertificate.fingerprint }

        init() throws {
            mac = try Replica("Mac"); phone = try Replica("iPhone")
            server = SyncServer(store: mac.store); client = SyncClient(store: phone.store)
            macCertificate = try DeviceCertificate.generate(deviceID: mac.id)
            phoneCertificate = try DeviceCertificate.generate(deviceID: phone.id)
        }

        /// Starts a session; returns tasks so tests can wait for them to end.
        func connect(pairingToken: Data? = nil) -> (server: Task<Void, any Error>, client: Task<Void, any Error>, channels: (InMemoryChannel, InMemoryChannel)) {
            let (macEnd, phoneEnd) = InMemoryChannel.pair()
            macEnd.peerCertificateDER = phoneCertificate.certificateDER
            phoneEnd.peerCertificateDER = macCertificate.certificateDER
            let serverTask = Task { try await server.serve(macEnd) }
            let clientTask = Task { try await client.session(phoneEnd, pairingToken: pairingToken) }
            return (serverTask, clientTask, (macEnd, phoneEnd))
        }

        func pairDirectly() throws {
            try mac.store.addPeer(id: phone.id, name: "iPhone", fingerprint: phoneFingerprint)
            try phone.store.addPeer(id: mac.id, name: "Mac", fingerprint: macFingerprint)
        }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pairingWithTheTokenTrustsBothSidesThenSyncs() async throws {
        let pair = try Pair()
        let note = try pair.phone.store.createNote(content: "from phone")
        let token = await pair.server.beginPairing()
        let session = pair.connect(pairingToken: token)

        try await waitUntil { try pair.mac.store.note(id: note.id)?.content == "from phone" }
        #expect(try pair.mac.store.peer(id: pair.phone.id)?.fingerprint == pair.phoneFingerprint)
        #expect(try pair.phone.store.peer(id: pair.mac.id)?.fingerprint == pair.macFingerprint)
        #expect(await !pair.server.isPairing)
        #expect(try pair.mac.store.peer(id: pair.phone.id)?.lastSyncAt != nil)

        session.channels.0.close()
        _ = try? await session.server.value
        _ = try? await session.client.value
    }

    @Test func wrongTokenIsRejected() async throws {
        let pair = try Pair()
        _ = await pair.server.beginPairing()
        let session = pair.connect(pairingToken: Data(repeating: 0xFF, count: 16))
        await #expect(throws: SyncError.pairingRejected) { try await session.server.value }
        await #expect(throws: SyncError.pairingRejected) { try await session.client.value }
        #expect(try pair.mac.store.peers().isEmpty)
    }

    @Test func unknownDeviceWithoutPairingIsRefused() async throws {
        let pair = try Pair()
        try pair.phone.store.addPeer(id: pair.mac.id, name: "Mac", fingerprint: pair.macFingerprint)
        let session = pair.connect()
        await #expect(throws: SyncError.notPaired) { try await session.server.value }
        await #expect(throws: SyncError.notPaired) { try await session.client.value }
    }

    @Test func localEditsAndServerPokesEachStartARound() async throws {
        let pair = try Pair()
        try pair.pairDirectly()
        let session = pair.connect()
        try await waitUntil { try pair.mac.store.peer(id: pair.phone.id)?.lastSyncAt != nil }

        // Phone edits → phone triggers a round → Mac has it.
        let phoneNote = try pair.phone.store.createNote(content: "typed on phone")
        await pair.client.localChanged()
        try await waitUntil { try pair.mac.store.note(id: phoneNote.id) != nil }

        // Mac edits → poke → phone has it.
        let macNote = try pair.mac.store.createNote(content: "typed on mac")
        await pair.server.poke()
        try await waitUntil { try pair.phone.store.note(id: macNote.id) != nil }

        // Concurrent edit on both, then a round: both texts survive on both sides.
        try pair.mac.store.updateNote(id: phoneNote.id, content: "mac version", now: Date().addingTimeInterval(1))
        try pair.phone.store.updateNote(id: phoneNote.id, content: "phone version", now: Date().addingTimeInterval(2))
        await pair.client.localChanged()
        try await waitUntil { try pair.mac.liveContents() == pair.phone.liveContents() && pair.mac.liveContents().count == 3 }
        #expect(try pair.mac.liveContents()[phoneNote.id] == "phone version")
        #expect(try pair.mac.liveContents().values.contains("mac version (Conflict from Mac)"))

        session.channels.1.close()
        _ = try? await session.server.value
        _ = try? await session.client.value
        #expect(await pair.server.connectionCount == 0)
        #expect(await !pair.client.isConnected)
    }

    @Test func pairingPayloadRoundTripsThroughTheQRString() {
        let payload = PairingPayload(deviceID: UUID(), name: "Mac", fingerprint: Data(repeating: 7, count: 32), token: Data(repeating: 9, count: 16))
        #expect(payload.qrString.hasPrefix("sill:"))
        #expect(PairingPayload(qrString: payload.qrString) == payload)
        #expect(PairingPayload(qrString: "sill:not-base64!") == nil)
        #expect(PairingPayload(qrString: "https://example.com") == nil)
    }

    @Test func serverReportsConnectionsPairingAndSyncs() async throws {
        let pair = try Pair()
        let token = await pair.server.beginPairing()
        let events = pair.server.events
        let session = pair.connect(pairingToken: token)
        var seen: [SyncServer.Event] = []
        for await event in events {
            seen.append(event)
            if case .synced = event { break }
        }
        #expect(seen.first == .connections(1))
        #expect(seen.contains { if case .paired(let peer) = $0 { return peer.id == pair.phone.id } else { return false } })
        session.channels.0.close()
        _ = try? await session.server.value
        _ = try? await session.client.value
    }

    /// A write that lands while a batch is being sent must still reach the peer in the next round.
    /// (Regression: the vector was read after the batch, so the receiver "saw" a row it never got.)
    @Test func writeDuringABatchIsNotLostToThePeer() async throws {
        let pair = try Pair()
        try pair.pairDirectly()
        let session = pair.connect()
        try await waitUntil { try pair.mac.store.peer(id: pair.phone.id)?.lastSyncAt != nil }

        // While the phone is sending its batch, the user types another note on the phone.
        let first = try pair.phone.store.createNote(content: "first")
        nonisolated(unsafe) var slipped: Note?
        session.channels.1.onSend = { message in
            if case .changes = message, slipped == nil {
                slipped = try? pair.phone.store.createNote(content: "typed mid-batch")
            }
        }
        await pair.client.localChanged()
        try await waitUntil { try pair.mac.store.note(id: first.id) != nil }
        session.channels.1.onSend = nil
        let late = try #require(slipped)

        await pair.client.localChanged()
        try await waitUntil { try pair.mac.store.note(id: late.id)?.content == "typed mid-batch" }

        session.channels.1.close()
        _ = try? await session.server.value
        _ = try? await session.client.value
    }

    @Test func pairingWindowExpires() async throws {
        let pair = try Pair()
        let token = await pair.server.beginPairing(ttl: .milliseconds(30))
        #expect(await pair.server.isPairing)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await !pair.server.isPairing)
        let session = pair.connect(pairingToken: token)
        await #expect(throws: SyncError.pairingRejected) { try await session.server.value }
        await #expect(throws: SyncError.pairingRejected) { try await session.client.value }
    }

    @Test func tokenComparisonIsExactAndLengthChecked() {
        #expect(SyncServer.tokensMatch(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!SyncServer.tokensMatch(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!SyncServer.tokensMatch(Data([1, 2, 3]), Data([1, 2])))
    }

    @Test func silentPeerIsDroppedAfterTheHandshakeTimeout() async throws {
        let mac = try Replica("Mac")
        let server = SyncServer(store: mac.store, handshakeTimeout: .milliseconds(50))
        let (macEnd, phoneEnd) = InMemoryChannel.pair()
        macEnd.peerCertificateDER = try DeviceCertificate.generate(deviceID: UUID()).certificateDER
        let serving = Task { try await server.serve(macEnd) }
        // The phone never says anything.
        _ = phoneEnd
        let started = ContinuousClock.now
        try await serving.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await server.connectionCount == 0)
    }

    @Test func helloFromAnUnpairedClientEndsTheSessionCleanly() async throws {
        let pair = try Pair()
        try pair.mac.store.addPeer(id: pair.phone.id, name: "iPhone", fingerprint: pair.phoneFingerprint)
        // Phone never paired the Mac: it must refuse before saying hello.
        let session = pair.connect()
        await #expect(throws: SyncError.notPaired) { try await session.client.value }
        session.channels.0.close()
        _ = try? await session.server.value
    }
}
