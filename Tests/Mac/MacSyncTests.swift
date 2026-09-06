import AppKit
import Network
import SillCore
import Testing

@testable import Sill

/// Nested so it runs serially with the capture tests (they share the app).
extension CaptureFlowTests {
    @MainActor
    @Suite(.serialized)
    struct MacSyncFlow {
        private var app: AppDelegate { AppDelegate.shared }

        private func waitUntil(timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + timeout
            while try !condition() {
                try #require(ContinuousClock.now < deadline, "timed out waiting for condition")
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        @Test func phonePairsWithTheRunningAppAndNotesFlowBothWays() async throws {
            let sync = try #require(app.sync)
            try await waitUntil { sync.port != nil }
            #expect(sync.statusText == "Not paired")

            // An in-process stand-in for the phone.
            let phoneStore = try NoteStore(
                database: try AppDatabase.inMemory(), deviceName: "Test iPhone", deviceKind: .phone)
            let phoneIdentityStore = IdentityStore(label: "com.mrskiro.sill.test-phone.\(UUID().uuidString)")
            defer { try? phoneIdentityStore.delete() }
            let phoneIdentity = try phoneIdentityStore.loadOrCreate(deviceID: phoneStore.deviceID)
            let client = SyncClient(store: phoneStore)
            let phoneNote = try phoneStore.createNote(content: "# From the phone")

            let payload = await sync.beginPairing()
            #expect(sync.pairingPayload == payload)
            #expect(PairingPayload(qrString: payload.qrString) == payload)
            #expect(QRCodeView.image(for: payload.qrString) != nil)

            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: sync.port!)!)
            let phoneTask = Task {
                try await SillConnector.connect(
                    to: endpoint, identity: phoneIdentity, client: client,
                    expectedFingerprint: payload.fingerprint, pairingToken: payload.token)
            }

            // The sidebar's observation picks up the synced note.
            try await waitUntil { self.app.model.notes.contains { $0.id == phoneNote.id } }
            try await waitUntil {
                sync.peers.map(\.name) == ["Test iPhone"] && sync.pairingPayload == nil && sync.connections == 1
            }
            #expect(sync.statusText == "1 device connected")

            // Typing on the Mac → autosave → poke → phone.
            app.newNote()
            let textView = try #require(app.panel.contentView?.firstDescendant(of: MarkdownTextView.self))
            textView.insertText("typed on the mac", replacementRange: NSRange(location: 0, length: 0))
            try await waitUntil { (try? phoneStore.liveNotes().contains { $0.content == "typed on the mac" }) == true }

            phoneTask.cancel()
            _ = try? await phoneTask.value
            try await waitUntil { sync.connections == 0 }
            #expect(sync.statusText.hasPrefix("Synced"))

            sync.unpair(phoneStore.deviceID)
            #expect(sync.peers.isEmpty)
        }
    }
}
