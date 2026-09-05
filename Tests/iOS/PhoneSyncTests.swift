import Network
import Testing
import UIKit

@testable import Sill
@testable import SillCore

/// Nested so it runs serially with the capture tests (they share the app).
extension PhoneFlowTests {
    @MainActor
    @Suite(.serialized)
    struct PhoneSyncFlow {
        private var model: PhoneModel { PhoneModel.shared }

        private func waitUntil(timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + timeout
            while try !condition() {
                try #require(ContinuousClock.now < deadline, "timed out waiting for condition")
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        /// A Mac on another protocol version: the phone says which app to update, stops retrying,
        /// and keeps the pairing so updating the Mac and foregrounding is enough to recover.
        @Test func aMacOnAnotherProtocolVersionStopsTheLoopWithoutLosingThePairing() async throws {
            let sync = try #require(model.sync)
            let macStore = try NoteStore(database: try AppDatabase.inMemory(), deviceName: "Old Mac")
            let macIdentityStore = IdentityStore(label: "com.mrskiro.sill.test-old-mac.\(UUID().uuidString)")
            defer { try? macIdentityStore.delete() }
            let macIdentity = try macIdentityStore.loadOrCreate(deviceID: macStore.deviceID)
            let server = SyncServer(store: macStore)
            let (ports, portSink) = AsyncStream<UInt16>.makeStream()
            let listenerTask = Task {
                try await SillListener(identity: macIdentity, server: server, advertise: false).run {
                    portSink.yield($0)
                }
            }
            var portIterator = ports.makeAsyncIterator()
            let port = try #require(await portIterator.next())
            sync.endpointOverride = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

            await sync.client.useHelloProtocolVersion(SyncMessage.protocolVersion + 1)
            let token = await server.beginPairing()
            sync.pair(
                with: PairingPayload(
                    deviceID: macStore.deviceID, name: "Old Mac", fingerprint: macIdentity.fingerprint, token: token))

            try await waitUntil { if case .failed = sync.status { return true } else { return false } }
            #expect(sync.status.text.contains("older version of Sill"))
            #expect(sync.status.text.contains("Update Sill there"))
            // The pairing survived the refusal, so the phone still knows what to dial next time.
            #expect(sync.peers.map(\.name) == ["Old Mac"])

            await sync.client.useHelloProtocolVersion(SyncMessage.protocolVersion)
            sync.stop()
            listenerTask.cancel()
            _ = try? await listenerTask.value
            sync.unpair(macStore.deviceID)
            sync.stop()
            sync.endpointOverride = nil
            #expect(sync.status == .unpaired)
        }

        @Test func phonePairsWithAMacAndNotesFlowBothWays() async throws {
            let sync = try #require(model.sync)
            #expect(sync.status == .unpaired)

            // An in-process stand-in for the Mac.
            let macStore = try NoteStore(database: try AppDatabase.inMemory(), deviceName: "Test Mac")
            let macIdentityStore = IdentityStore(label: "com.mrskiro.sill.test-mac.\(UUID().uuidString)")
            defer { try? macIdentityStore.delete() }
            let macIdentity = try macIdentityStore.loadOrCreate(deviceID: macStore.deviceID)
            let server = SyncServer(store: macStore)
            let (ports, portSink) = AsyncStream<UInt16>.makeStream()
            let listenerTask = Task {
                try await SillListener(identity: macIdentity, server: server, advertise: false).run {
                    portSink.yield($0)
                }
            }
            var portIterator = ports.makeAsyncIterator()
            let port = try #require(await portIterator.next())
            sync.endpointOverride = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

            let macNote = try macStore.createNote(content: "# From the Mac")
            let token = await server.beginPairing()
            let payload = PairingPayload(
                deviceID: macStore.deviceID, name: "Test Mac", fingerprint: macIdentity.fingerprint, token: token)
            sync.pair(with: payload)

            try await waitUntil { sync.status == .connected("Test Mac") }
            try await waitUntil { self.model.notes.contains { $0.id == macNote.id } }
            #expect(try macStore.peer(id: model.store.deviceID)?.name == UIDevice.current.name)
            #expect(sync.peers.map(\.name) == ["Test Mac"])

            // Typing on the phone → autosave → round → Mac.
            model.path = []
            model.newNote()
            let destination = try #require(model.path.last)
            let draft = model.draft(for: destination)
            draft.text = "typed on the phone"
            try await waitUntil { (try? macStore.liveNotes().contains { $0.content == "typed on the phone" }) == true }

            // Mac edits → poke → phone list.
            try macStore.updateNote(id: macNote.id, content: "# From the Mac, edited")
            await server.poke()
            try await waitUntil {
                self.model.notes.contains { $0.id == macNote.id && $0.content == "# From the Mac, edited" }
            }
            try await waitUntil { sync.lastSyncAt != nil }

            // Background: the session ends; foreground: it comes back.
            sync.stop()
            var connections = await server.connectionCount
            let deadline = ContinuousClock.now + .seconds(10)
            while connections != 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                connections = await server.connectionCount
            }
            #expect(connections == 0)
            sync.start()
            try await waitUntil { sync.status == .connected("Test Mac") }

            sync.stop()
            listenerTask.cancel()
            _ = try? await listenerTask.value
            sync.unpair(macStore.deviceID)
            sync.stop()
            sync.endpointOverride = nil
            #expect(sync.status == .unpaired)
            model.path = []
        }
    }
}
