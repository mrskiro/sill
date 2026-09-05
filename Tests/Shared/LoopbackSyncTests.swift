import Foundation
import Network
import SillCore
import Testing

/// Real Network.framework stack (TLS mutual auth with pinned self-signed certificates, JSON Coder)
/// between two in-process replicas over 127.0.0.1. Bonjour discovery is exercised on real devices.
@Suite struct LoopbackSyncTests {
    struct Side {
        let store: NoteStore
        let identityStore: IdentityStore
        let identity: DeviceIdentity

        init(_ name: String) throws {
            store = try NoteStore(database: try AppDatabase.inMemory(), deviceName: name)
            identityStore = IdentityStore(label: "com.mrskiro.sill.test-loopback.\(UUID().uuidString)")
            identity = try identityStore.loadOrCreate(deviceID: store.deviceID)
        }
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func startListener(_ mac: Side, server: SyncServer) async throws -> (task: Task<Void, any Error>, port: UInt16) {
        let (ports, continuation) = AsyncStream<UInt16>.makeStream()
        let task = Task {
            try await SillListener(identity: mac.identity, server: server, advertise: false).run { continuation.yield($0) }
        }
        var iterator = ports.makeAsyncIterator()
        let port = try #require(await iterator.next())
        return (task, port)
    }

    @Test func pairsAndSyncsOverMutualTLS() async throws {
        let mac = try Side("Mac"), phone = try Side("iPhone")
        defer { try? mac.identityStore.delete(); try? phone.identityStore.delete() }
        let server = SyncServer(store: mac.store), client = SyncClient(store: phone.store)
        let token = await server.beginPairing()
        let phoneNote = try phone.store.createNote(content: "typed on the phone")

        let listener = try await startListener(mac, server: server)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port)!)
        let clientTask = Task {
            try await SillConnector.connect(to: endpoint, identity: phone.identity, client: client,
                                            expectedFingerprint: mac.identity.fingerprint, pairingToken: token)
        }

        try await waitUntil { try mac.store.note(id: phoneNote.id)?.content == "typed on the phone" }
        #expect(try mac.store.peer(id: phone.store.deviceID)?.fingerprint == phone.identity.fingerprint)
        #expect(try phone.store.peer(id: mac.store.deviceID)?.fingerprint == mac.identity.fingerprint)

        let macNote = try mac.store.createNote(content: "typed on the mac")
        await server.poke()
        try await waitUntil { try phone.store.note(id: macNote.id)?.content == "typed on the mac" }

        try phone.store.updateNote(id: macNote.id, content: "edited on the phone")
        await client.localChanged()
        try await waitUntil { try mac.store.note(id: macNote.id)?.content == "edited on the phone" }

        clientTask.cancel()
        listener.task.cancel()
        _ = try? await clientTask.value
        _ = try? await listener.task.value
    }

    /// A rejected pairing attempt must not take the listener down: the next, correct attempt succeeds.
    @Test func listenerSurvivesARejectedPairing() async throws {
        let mac = try Side("Mac"), phone = try Side("iPhone")
        defer { try? mac.identityStore.delete(); try? phone.identityStore.delete() }
        let server = SyncServer(store: mac.store), client = SyncClient(store: phone.store)
        let token = await server.beginPairing()
        let listener = try await startListener(mac, server: server)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port)!)

        let wrong = Task {
            try await SillConnector.connect(to: endpoint, identity: phone.identity, client: client,
                                            expectedFingerprint: mac.identity.fingerprint, pairingToken: Data(repeating: 0xFF, count: 16))
        }
        await #expect(throws: (any Error).self) { try await wrong.value }
        #expect(try mac.store.peers().isEmpty)

        let note = try phone.store.createNote(content: "second attempt")
        let right = Task {
            try await SillConnector.connect(to: endpoint, identity: phone.identity, client: client,
                                            expectedFingerprint: mac.identity.fingerprint, pairingToken: token)
        }
        try await waitUntil { try mac.store.note(id: note.id) != nil }
        right.cancel()
        listener.task.cancel()
        _ = try? await right.value
        _ = try? await listener.task.value
    }

    @Test func unknownCertificateNeverGetsASession() async throws {
        let mac = try Side("Mac"), stranger = try Side("Stranger")
        defer { try? mac.identityStore.delete(); try? stranger.identityStore.delete() }
        let server = SyncServer(store: mac.store), client = SyncClient(store: stranger.store)
        let listener = try await startListener(mac, server: server)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port)!)

        // Not pairing, not paired: the TLS handshake must fail on one side or the other.
        let clientTask = Task {
            try await SillConnector.connect(to: endpoint, identity: stranger.identity, client: client,
                                            expectedFingerprint: mac.identity.fingerprint)
        }
        let outcome = await clientTask.result
        #expect(throws: (any Error).self) { try outcome.get() }
        #expect(try mac.store.peers().isEmpty)
        #expect(await server.connectionCount == 0)
        listener.task.cancel()
        _ = try? await listener.task.value
    }
}
