import AppKit
import Network
import SillCore
import Testing

@testable import Sill
@testable import SillCore

/// Two Macs in one process, each with its own store, identity, listener and dialler, talking over
/// 127.0.0.1 with the real TLS stack. Bonjour discovery is exercised on real devices.
///
/// Nested so it runs serially with the capture tests (they share the app).
extension CaptureFlowTests {
    @MainActor
    @Suite(.serialized)
    struct MacToMacSyncFlow {
        struct Side {
            let sync: MacSync
            let store: NoteStore
            let identityStore: IdentityStore
        }

        private func makeSide(_ name: String) throws -> Side {
            let store = try NoteStore(database: try AppDatabase.inMemory(), deviceName: name)
            let identityStore = IdentityStore(label: "com.mrskiro.sill.test-mac.\(UUID().uuidString)")
            let identity = try identityStore.loadOrCreate(deviceID: store.deviceID)
            return Side(
                sync: MacSync(store: store, identity: identity, advertise: false),
                store: store, identityStore: identityStore)
        }

        private func endpoint(_ port: UInt16) -> NWEndpoint {
            .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        }

        private func waitUntil(timeout: Duration = .seconds(20), _ condition: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + timeout
            while try !condition() {
                try #require(ContinuousClock.now < deadline, "timed out waiting for condition")
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        /// The Mac that pastes the code dials to pair, and `SyncRole` says it may keep dialling:
        /// the pairing session simply carries on.
        @Test func theDiallingMacPairsAndKeepsTheSession() async throws {
            try await pairAndSync(pasterIsTheDialer: true)
        }

        /// The Mac that pastes the code is the one that should be listening: it has to hand the
        /// dialling over once pairing is done, or the two end up with a session each way.
        @Test func theListeningMacPairsAndHandsTheDiallingOver() async throws {
            try await pairAndSync(pasterIsTheDialer: false)
        }

        /// Pairs two Macs by pasting a code, then checks notes travel both ways over exactly one
        /// session. `pasterIsTheDialer` picks which end shows the code, so both orderings of the
        /// two device ids are covered whichever way the random UUIDs happen to sort.
        private func pairAndSync(pasterIsTheDialer: Bool) async throws {
            let a = try makeSide("Mac A")
            let b = try makeSide("Mac B")
            defer {
                a.sync.stop()
                b.sync.stop()
                try? a.identityStore.delete()
                try? b.identityStore.delete()
            }
            a.sync.start()
            b.sync.start()
            try await waitUntil { a.sync.port != nil && b.sync.port != nil }
            a.sync.dialer.endpointOverride = endpoint(b.sync.port!)
            b.sync.dialer.endpointOverride = endpoint(a.sync.port!)

            let aDials = SyncRole.shouldDial(myDeviceID: a.store.deviceID, peerID: b.store.deviceID)
            let paster = aDials == pasterIsTheDialer ? a : b
            let shower = aDials == pasterIsTheDialer ? b : a

            // The shower shows the code; the paster pastes the same string the QR carries.
            let payload = await shower.sync.beginPairing()
            paster.sync.pair(with: try #require(PairingPayload(qrString: payload.qrString)))

            try await waitUntil {
                a.sync.peers.map(\.name) == ["Mac B"] && b.sync.peers.map(\.name) == ["Mac A"]
            }
            #expect(shower.sync.pairingPayload == nil)

            let fromB = try b.store.createNote(content: "typed on mac b")
            b.sync.poke()
            try await waitUntil { try a.store.note(id: fromB.id)?.content == "typed on mac b" }

            let fromA = try a.store.createNote(content: "typed on mac a")
            a.sync.poke()
            try await waitUntil { try b.store.note(id: fromA.id)?.content == "typed on mac a" }

            // One connection in total: the side that must not dial let its session go.
            try await waitUntil { a.sync.connections + b.sync.connections == 1 }
            #expect(a.sync.connectedCount == 1)
            #expect(b.sync.connectedCount == 1)
            #expect(a.sync.statusText == "1 device connected")

            // Whoever ends up dialling knows the peer as a target, so a dropped session is redialled
            // instead of leaving the loop with nothing to look for.
            let dialer = aDials ? a : b
            let listening = aDials ? b : a
            #expect(dialer.sync.dialer.targets.map(\.id) == [listening.store.deviceID])
            #expect(listening.sync.dialer.targets.isEmpty)

            // Drop the session from the listening end (the peer stays paired): the dialler has to
            // find its way back without anything restarting it.
            await listening.sync.server.revoke(peerID: dialer.store.deviceID)
            try await waitUntil { listening.sync.connections == 0 }
            try await waitUntil { listening.sync.connections == 1 }

            a.sync.unpair(b.store.deviceID)
            #expect(a.sync.peers.isEmpty)
        }

        /// A dialler with nothing to look for has to wake up when a peer appears: the loop parks in
        /// a Bonjour browse that never returns, so a changed target list has to restart it.
        @Test func aDiallerWithNothingToDialWakesWhenATargetAppears() async throws {
            let side = try makeSide("Mac A")
            defer {
                side.sync.stop()
                try? side.identityStore.delete()
            }
            // Nothing listens on discard: the loop fails fast instead of browsing during the test.
            side.sync.dialer.endpointOverride = endpoint(9)
            side.sync.start()
            #expect(side.sync.dialer.isDialling == false)

            let peer = Peer(
                id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, name: "Mac B",
                fingerprint: Data(repeating: 2, count: 32), pairedAt: Date())
            side.sync.dialer.setTargets([peer])
            #expect(side.sync.dialer.isDialling)
        }

        /// The paste field and the code are on screen together, so a code from this very Mac is
        /// one clipboard slip away — and every identity check downstream would compare it to itself.
        @Test func aMacRefusesItsOwnPairingCode() async throws {
            let side = try makeSide("Mac A")
            defer {
                side.sync.stop()
                try? side.identityStore.delete()
            }
            side.sync.start()
            try await waitUntil { side.sync.port != nil }

            side.sync.pair(with: await side.sync.beginPairing())

            #expect(side.sync.peers.isEmpty)
            #expect(side.sync.dialer.isDialling == false)
            #expect(side.sync.dialer.failure == "that code is from this Mac")
        }

        /// A dial that fails for good (the other Mac is on an older protocol) must not wedge the
        /// dialler: the next peer change has to start it again, and a peer that reaches us on its
        /// own has to clear the failure the status line is showing.
        @Test func aDialThatFailedForGoodDoesNotWedgeTheDialler() async throws {
            let a = try makeSide("Mac A")
            let b = try makeSide("Mac B")
            defer {
                a.sync.stop()
                b.sync.stop()
                try? a.identityStore.delete()
                try? b.identityStore.delete()
            }
            a.sync.start()
            b.sync.start()
            try await waitUntil { a.sync.port != nil && b.sync.port != nil }
            a.sync.dialer.endpointOverride = endpoint(b.sync.port!)
            await a.sync.dialer.client.useHelloProtocolVersion(SyncMessage.protocolVersion + 1)

            a.sync.pair(with: await b.sync.beginPairing())
            try await waitUntil { a.sync.dialer.failure != nil }
            #expect(a.sync.dialer.isDialling == false)
            #expect(a.sync.statusText.hasPrefix("Sync failed:"))

            // Pairing stored the peer on both sides before the handshake failed.
            #expect(a.sync.peers.map(\.name) == ["Mac B"])
            let peerB = try #require(a.sync.peers.first)
            a.sync.dialer.setTargets([peerB])
            #expect(a.sync.dialer.isDialling)

            // Mac B, now that it can be understood, reaches Mac A on its own: no failure left over.
            await a.sync.dialer.client.useHelloProtocolVersion(SyncMessage.protocolVersion)
            a.sync.dialer.stop()
            b.sync.dialer.endpointOverride = endpoint(a.sync.port!)
            b.sync.dialer.restart(targets: try b.store.peers())
            // Mac B may hand the dialling straight back if its id says so, so the session is not
            // the thing to assert on — the failure being gone is.
            try await waitUntil { a.sync.dialer.failure == nil }
        }

        /// The relay: a phone paired with one Mac sees what is written on the other, and back.
        @Test func aPhonePairedWithOneMacSyncsThroughItWithTheOther() async throws {
            let a = try makeSide("Mac A")
            let b = try makeSide("Mac B")
            let phoneStore = try NoteStore(
                database: try AppDatabase.inMemory(), deviceName: "Test iPhone", deviceKind: .phone)
            let phoneIdentityStore = IdentityStore(label: "com.mrskiro.sill.test-phone.\(UUID().uuidString)")
            let phoneIdentity = try phoneIdentityStore.loadOrCreate(deviceID: phoneStore.deviceID)
            let phoneClient = SyncClient(store: phoneStore)
            defer {
                a.sync.stop()
                b.sync.stop()
                try? a.identityStore.delete()
                try? b.identityStore.delete()
                try? phoneIdentityStore.delete()
            }
            a.sync.start()
            b.sync.start()
            try await waitUntil { a.sync.port != nil && b.sync.port != nil }
            a.sync.dialer.endpointOverride = endpoint(b.sync.port!)
            b.sync.dialer.endpointOverride = endpoint(a.sync.port!)

            let macPayload = await a.sync.beginPairing()
            b.sync.pair(with: macPayload)
            try await waitUntil { a.sync.peers.count == 1 && b.sync.peers.count == 1 }

            // The phone pairs with Mac A only; Mac B it has never met.
            let phonePayload = await a.sync.beginPairing()
            let phoneTask = Task {
                try await SillConnector.connect(
                    to: endpoint(a.sync.port!), identity: phoneIdentity, client: phoneClient,
                    expectedFingerprint: phonePayload.fingerprint, pairingToken: phonePayload.token)
            }
            defer {
                phoneTask.cancel()
            }
            try await waitUntil { try a.sync.peers.count == 2 && phoneStore.peers().count == 1 }

            let fromB = try b.store.createNote(content: "written on the far mac")
            b.sync.poke()
            try await waitUntil { try phoneStore.note(id: fromB.id)?.content == "written on the far mac" }

            let fromPhone = try phoneStore.createNote(content: "written on the phone")
            await phoneClient.localChanged()
            try await waitUntil { try b.store.note(id: fromPhone.id)?.content == "written on the phone" }

            // Unpairing the phone is none of the dialler's business: the Mac-to-Mac session stays.
            let dialling = a.sync.dialer.connectedPeer == nil ? b : a
            #expect(dialling.sync.dialer.connectedPeer != nil)
            a.sync.unpair(phoneStore.deviceID)
            #expect(dialling.sync.dialer.connectedPeer != nil)

            phoneTask.cancel()
            _ = try? await phoneTask.value
        }
    }
}
