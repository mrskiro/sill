import Observation
import SillCore
import SwiftUI
import os

/// The Mac's sync side: listens for the iPhone, shows the pairing QR, pokes after local writes.
@MainActor
@Observable
final class MacSync {
    let store: NoteStore
    let identity: DeviceIdentity
    let server: SyncServer
    let advertise: Bool

    private(set) var port: UInt16?
    private(set) var connections = 0
    private(set) var peers: [Peer] = []
    private(set) var lastSyncAt: Date?
    private(set) var pairingPayload: PairingPayload?

    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.mrskiro.sill", category: "mac-sync")

    init(store: NoteStore, identity: DeviceIdentity, advertise: Bool) {
        self.store = store
        self.identity = identity
        self.advertise = advertise
        server = SyncServer(store: store)
        refreshPeers()
    }

    func start() {
        let listener = SillListener(identity: identity, server: server, advertise: advertise)
        // MacSync lives as long as the app; strong captures are fine and keep Swift 6 happy.
        listenerTask = Task {
            var backoff: Duration = .seconds(1)
            while !Task.isCancelled {
                do {
                    try await listener.run { port in
                        Task { @MainActor in self.port = port }
                    }
                    SyncLog.write("mac: listener ended")
                } catch is CancellationError {
                    break
                } catch {
                    self.log.error("listener stopped: \(error)")
                    SyncLog.write("mac: listener failed: \(error)")
                }
                self.port = nil
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(30))
            }
        }
        eventTask = Task {
            for await event in server.events {
                self.handle(event)
            }
        }
    }

    func stop() {
        listenerTask?.cancel()
        eventTask?.cancel()
    }

    static let pairingWindow: Duration = .seconds(120)

    @discardableResult
    func beginPairing() async -> PairingPayload {
        let token = await server.beginPairing(ttl: Self.pairingWindow)
        let payload = PairingPayload(
            deviceID: store.deviceID, name: store.deviceName, fingerprint: identity.fingerprint, token: token)
        pairingPayload = payload
        SyncLog.write("mac: pairing window open, qr \(payload.qrString.count) chars")
        Task { [weak self] in
            try? await Task.sleep(for: Self.pairingWindow)
            if self?.pairingPayload == payload { await self?.endPairing() }
        }
        return payload
    }

    func endPairing() async {
        await server.endPairing()
        pairingPayload = nil
    }

    /// After a local write: tell connected phones to start a round.
    func poke() {
        Task { [server] in await server.poke() }
    }

    func unpair(_ id: DeviceID) {
        try? store.removePeer(id: id)
        refreshPeers()
        Task { [server] in await server.revoke(peerID: id) }
    }

    var statusText: String {
        if connections > 0 { return "iPhone connected" }
        if let lastSyncAt { return "Synced \(lastSyncAt.formatted(.relative(presentation: .named)))" }
        if peers.isEmpty { return "Not paired" }
        return "iPhone not nearby"
    }

    private func handle(_ event: SyncServer.Event) {
        switch event {
        case .connections(let count):
            connections = count
        case .paired:
            pairingPayload = nil
            refreshPeers()
        case .synced(let peer):
            lastSyncAt = peer.lastSyncAt
            refreshPeers()
        }
    }

    private func refreshPeers() {
        peers = (try? store.peers()) ?? []
        lastSyncAt = peers.compactMap(\.lastSyncAt).max()
    }
}
