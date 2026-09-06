import Observation
import SillCore
import SwiftUI
import os

/// The Mac's sync side: listens for other devices, dials the Macs it should (`MacDialer`),
/// shows the pairing code, and pokes after local writes.
///
/// With two Macs and a phone, one Mac ends up relaying: what arrives on one connection has to be
/// pushed out over the other, which is what the cross-poking in `handle(_:)` does.
@MainActor
@Observable
final class MacSync {
    let store: NoteStore
    let identity: DeviceIdentity
    let server: SyncServer
    let dialer: MacDialer
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
        dialer = MacDialer(store: store, identity: identity)
        refreshPeers()
        dialer.onEvent = { [weak self] event in self?.handle(event) }
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
        updateDialTargets(restart: true)
    }

    func stop() {
        listenerTask?.cancel()
        eventTask?.cancel()
        dialer.stop()
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

    /// Pair with another Mac by pasting the code it shows.
    func pair(with payload: PairingPayload) {
        dialer.pair(with: payload)
    }

    /// After a local write: tell every connected device to start a round.
    func poke() {
        Task { [server] in await server.poke() }
        dialer.localChanged()
    }

    func unpair(_ id: DeviceID) {
        // Only the dialled peer's session has to go: unpairing the phone must not tear down a
        // healthy Mac-to-Mac session that has nothing to do with it.
        let wasDialled = dialer.connectedPeer?.id == id || dialer.targets.contains { $0.id == id }
        try? store.removePeer(id: id)
        refreshPeers()
        Task { [server] in await server.revoke(peerID: id) }
        updateDialTargets(restart: wasDialled)
    }

    /// Devices with a session open right now, either end.
    var connectedCount: Int {
        connections + (dialer.connectedPeer == nil ? 0 : 1)
    }

    var statusText: String {
        let connected = connectedCount
        if connected > 0 { return connected == 1 ? "1 device connected" : "\(connected) devices connected" }
        if let failure = dialer.failure { return "Sync failed: \(failure)" }
        if let lastSyncAt { return "Synced \(lastSyncAt.formatted(.relative(presentation: .named)))" }
        if peers.isEmpty { return "Not paired" }
        return "No devices nearby"
    }

    private func handle(_ event: SyncServer.Event) {
        switch event {
        case .connections(let count):
            connections = count
        case .paired:
            pairingPayload = nil
            refreshPeers()
            dialer.clearFailure()
            updateDialTargets()
        case .synced(let peer, let changed):
            lastSyncAt = peer.lastSyncAt
            refreshPeers()
            // A peer that reached us on its own settles whatever a failed dial had to say.
            dialer.clearFailure()
            // Relay: what this peer just sent us has to reach the Mac we dial as well.
            if changed { dialer.localChanged() }
        }
    }

    private func handle(_ event: SyncClient.SessionEvent) {
        switch event {
        case .connected:
            refreshPeers()
            // Pairing dialled a peer the list did not have yet; without this the loop would have
            // nothing to redial once this session ends.
            updateDialTargets()
        case .synced(let peer, let changed):
            lastSyncAt = peer.lastSyncAt
            refreshPeers()
            // Relay, the other way round.
            if changed { Task { [server] in await server.poke() } }
            // Pairing dials whatever `SyncRole` says; once the round is done, hand the dialling
            // back to the Mac whose id owns it, so the two never hold a session each way.
            if !SyncRole.shouldDial(myDeviceID: store.deviceID, peerID: peer.id) {
                updateDialTargets(restart: true)
            }
        case .ended:
            // A session that pairs and then fails the handshake (protocol mismatch) has already
            // stored the peer: pick it up so Settings can show and unpair it. The dialler is left
            // alone here — it drives its own retry, and only `MacSync` ever restarts it.
            refreshPeers()
        }
    }

    /// Recomputes who this Mac should be dialling. `restart` drops the session in progress, which
    /// is what unpairing and handing the dialling over need; otherwise a live session is kept.
    private func updateDialTargets(restart: Bool = false) {
        let targets = SyncRole.dialTargets(myDeviceID: store.deviceID, peers: peers)
        if restart {
            dialer.restart(targets: targets)
        } else {
            dialer.setTargets(targets)
        }
    }

    private func refreshPeers() {
        peers = (try? store.peers()) ?? []
        lastSyncAt = peers.compactMap(\.lastSyncAt).max()
    }
}
