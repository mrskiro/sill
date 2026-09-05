import Network
import Observation
import SillCore
import SwiftUI
import os

/// The phone's sync side. While the app is in the foreground it looks for the paired Mac,
/// keeps a session open, and reconnects with backoff. Pairing is one special first session.
@MainActor
@Observable
final class PhoneSync {
    enum Status: Equatable {
        case unpaired
        case searching
        case pairing
        case connected(String)
        case failed(String)

        var text: String {
            switch self {
            case .unpaired: "Not paired"
            case .searching: "Looking for your Mac…"
            case .pairing: "Pairing…"
            case .connected(let name): "Connected to \(name)"
            case .failed(let message): "Sync failed: \(message)"
            }
        }
    }

    let store: NoteStore
    let identity: DeviceIdentity
    let client: SyncClient
    private(set) var status: Status = .unpaired {
        didSet { if status != oldValue { SyncLog.write("phone status: \(status.text)") } }
    }
    private(set) var peers: [Peer] = []
    private(set) var lastSyncAt: Date?
    /// Tests (and a device without Bonjour) dial this instead of browsing.
    var endpointOverride: NWEndpoint?

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var loopGeneration = 0
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPairing: PairingPayload?
    @ObservationIgnored private let log = Logger(subsystem: "com.mrskiro.sill", category: "phone-sync")

    init(store: NoteStore, identity: DeviceIdentity) {
        self.store = store
        self.identity = identity
        client = SyncClient(store: store)
        refreshPeers()
        eventTask = Task {
            for await event in client.sessionEvents { self.handle(event) }
        }
    }

    /// Foreground: run the connect loop.
    func start() {
        guard loopTask == nil else { return }
        loopGeneration += 1
        let generation = loopGeneration
        loopTask = Task { await self.run(generation: generation) }
    }

    /// Background: drop the connection; the Mac cannot reach us anyway.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func pair(with payload: PairingPayload) {
        SyncLog.write("phone: pairing with \(payload.name) fp=\(SillService.fingerprintPrefix(payload.fingerprint))")
        pendingPairing = payload
        stop()
        start()
    }

    func unpair(_ id: DeviceID) {
        try? store.removePeer(id: id)
        refreshPeers()
        stop()
        status = peers.isEmpty ? .unpaired : .searching
        start()
    }

    /// After a local write: start a round if connected.
    func localChanged() {
        Task { [client] in await client.localChanged() }
    }

    var isPaired: Bool { !peers.isEmpty }

    // MARK: - Internals

    private func run(generation: Int) async {
        // Only the loop that still owns `loopTask` may clear it; a restarted loop must not be clobbered.
        defer { if loopGeneration == generation { loopTask = nil } }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            let pairing = pendingPairing
            pendingPairing = nil
            let targets: Set<String> =
                pairing.map { [SillService.fingerprintPrefix($0.fingerprint)] }
                ?? Set(peers.map { SillService.fingerprintPrefix($0.fingerprint) })
            guard !targets.isEmpty else {
                status = .unpaired
                return
            }
            status = pairing == nil ? .searching : .pairing
            do {
                let endpoint: NWEndpoint
                if let endpointOverride {
                    endpoint = endpointOverride
                } else {
                    endpoint = try await SillConnector.findServer(fingerprintPrefixes: targets)
                }
                try await SillConnector.connect(
                    to: endpoint, identity: identity, client: client,
                    expectedFingerprint: pairing?.fingerprint, pairingToken: pairing?.token
                )
                backoff = .seconds(1)
                status = .searching
            } catch is CancellationError {
                break
            } catch let error as SyncError where error.isUnrecoverable {
                // A version mismatch cannot be retried away. Stop the loop and say why; the next
                // foreground (or an app update) starts it again.
                log.error("session failed for good: \(error)")
                SyncLog.write("phone: not retrying: \(error)")
                // Pairing may have stored the Mac just before the mismatch; without this the peer
                // is missing from the unpair list and the next foreground has nothing to dial.
                refreshPeers()
                status = .failed(error.localizedDescription)
                return
            } catch {
                log.error("session failed: \(error)")
                status = .failed(pairing == nil ? error.localizedDescription : "pairing rejected")
                refreshPeers()
                if peers.isEmpty { return }
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
        if case .connected = status { status = .searching }
    }

    private func handle(_ event: SyncClient.SessionEvent) {
        switch event {
        case .connected(let peer):
            status = .connected(peer.name)
            refreshPeers()
        case .synced(let peer):
            lastSyncAt = peer.lastSyncAt
        case .ended:
            if case .connected = status { status = .searching }
        }
    }

    private func refreshPeers() {
        peers = (try? store.peers()) ?? []
        lastSyncAt = peers.compactMap(\.lastSyncAt).max()
    }
}
