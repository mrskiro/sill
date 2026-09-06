import Network
import Observation
import SillCore
import SwiftUI
import os

/// The Mac's dialling half — what makes Mac ↔ Mac sync possible. It mirrors the phone's connect
/// loop without the foreground/background rules: a Mac dials whenever it has a peer that
/// `SyncRole` says it should dial, and keeps the session open.
///
/// Which peers those are is decided by `MacSync`, which restarts the loop whenever the peer list
/// changes. Pairing is one special first session and ignores the rule.
@MainActor
@Observable
final class MacDialer {
    let store: NoteStore
    let identity: DeviceIdentity
    let client: SyncClient

    private(set) var connectedPeer: Peer?
    /// Set when a session failed in a way retrying cannot fix (protocol version).
    private(set) var failure: String?
    /// Tests (and a Mac that cannot browse) dial this instead of looking for the peer over Bonjour.
    var endpointOverride: NWEndpoint?
    /// Session events, after `connectedPeer` has been updated.
    var onEvent: ((SyncClient.SessionEvent) -> Void)?

    /// Between `restart` and `stop`. A loop that ran out of targets returns, so `loopTask == nil`
    /// on its own does not mean the dialler was stopped.
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var loopGeneration = 0
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPairing: PairingPayload?
    @ObservationIgnored private(set) var targets: [Peer] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.mrskiro.sill", category: "mac-dialer")

    init(store: NoteStore, identity: DeviceIdentity) {
        self.store = store
        self.identity = identity
        client = SyncClient(store: store)
        eventTask = Task { [weak self] in
            guard let events = self?.client.sessionEvents else { return }
            for await event in events { self?.handle(event) }
        }
    }

    /// (Re)starts the loop for `targets`. Cancelling the old loop drops its session, which is also
    /// how a peer we should no longer dial (unpaired, or now the listening side) is let go.
    func restart(targets: [Peer]) {
        self.targets = targets
        stop()
        isRunning = true
        guard !targets.isEmpty || pendingPairing != nil else { return }
        loopGeneration += 1
        let generation = loopGeneration
        loopTask = Task { await self.run(generation: generation) }
    }

    /// A new peer list without dropping the session in progress: the loop reads it on its next
    /// turn, so a session that ends later reconnects to whoever is still a target. A loop that had
    /// run out of targets has returned, so it needs starting again.
    func setTargets(_ targets: [Peer]) {
        self.targets = targets
        if isRunning, loopTask == nil { restart(targets: targets) }
    }

    func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        connectedPeer = nil
    }

    /// Pair with the Mac whose code was pasted: dial it once with the token, whatever `SyncRole` says.
    func pair(with payload: PairingPayload) {
        SyncLog.write("mac: pairing with \(payload.name) fp=\(SillService.fingerprintPrefix(payload.fingerprint))")
        failure = nil
        pendingPairing = payload
        restart(targets: targets)
    }

    /// After a local write: start a round if a session is open.
    func localChanged() {
        Task { [client] in await client.localChanged() }
    }

    // MARK: - Internals

    private func run(generation: Int) async {
        // Only the loop that still owns `loopTask` may clear it; a restarted loop must not be clobbered.
        defer { if loopGeneration == generation { loopTask = nil } }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            let pairing = pendingPairing
            pendingPairing = nil
            let prefixes: Set<String> =
                pairing.map { [SillService.fingerprintPrefix($0.fingerprint)] }
                ?? Set(targets.map { SillService.fingerprintPrefix($0.fingerprint) })
            guard !prefixes.isEmpty else { return }
            do {
                let endpoint: NWEndpoint
                if let endpointOverride {
                    endpoint = endpointOverride
                } else {
                    endpoint = try await SillConnector.findServer(fingerprintPrefixes: prefixes)
                }
                try await SillConnector.connect(
                    to: endpoint, identity: identity, client: client,
                    expectedFingerprint: pairing?.fingerprint, pairingToken: pairing?.token)
                backoff = .seconds(1)
            } catch is CancellationError {
                break
            } catch let error as SyncError where error.isUnrecoverable {
                // Retrying cannot fix a version mismatch. Stop and say so; the next peer change
                // (or app update) starts the loop again.
                log.error("dial failed for good: \(error)")
                SyncLog.write("mac: not retrying: \(error)")
                failure = error.localizedDescription
                return
            } catch {
                log.error("dial failed: \(error)")
                SyncLog.write("mac: dial failed: \(error)")
                // A code that was refused (expired, or the window was cancelled) is worth saying
                // out loud: nothing else on screen would explain why nothing happened.
                if pairing != nil { failure = "pairing rejected" }
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    private func handle(_ event: SyncClient.SessionEvent) {
        switch event {
        case .connected(let peer):
            failure = nil
            connectedPeer = peer
        case .synced(let peer, _):
            connectedPeer = peer
        case .ended:
            connectedPeer = nil
        }
        onEvent?(event)
    }
}
