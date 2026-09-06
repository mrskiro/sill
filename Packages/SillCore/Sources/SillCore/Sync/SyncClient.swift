import Foundation
import os

/// The connecting side (the iPhone). One session per connection; rounds are started here:
/// on connect, after local edits (`localChanged()`), and when the server pokes.
/// Implemented as a single event loop over a small state machine.
public actor SyncClient {
    public let store: NoteStore
    private var events: AsyncStream<Event>.Continuation?
    /// One client can run sessions back to back (a reconnect). Only the session that still owns
    /// `events` may clear it, or a slow teardown silences the session that replaced it.
    private var sessionGeneration = 0
    private let log = Logger(subsystem: "com.mrskiro.sill", category: "sync-client")

    /// UI-facing notifications.
    public enum SessionEvent: Sendable, Equatable {
        case connected(Peer)
        /// `changed` is false for a round that applied nothing, so a Mac relaying between two
        /// peers can stop instead of poking the other side after every empty round.
        case synced(Peer, changed: Bool)
        case ended
    }
    public nonisolated let sessionEvents: AsyncStream<SessionEvent>
    private let sessionSink: AsyncStream<SessionEvent>.Continuation

    private enum Event: Sendable {
        case message(SyncMessage)
        case localChange
        case closed
    }

    private enum Phase {
        case pairing
        case hello
        case idle
        case inRound(pending: [Note])
    }

    /// A server that accepts TLS but never answers the handshake is dropped after this long.
    public let handshakeTimeout: Duration

    /// Always the constant in the apps; tests move it to put the two ends on different versions.
    private var helloProtocolVersion = SyncMessage.protocolVersion

    func useHelloProtocolVersion(_ version: Int) {
        helloProtocolVersion = version
    }

    public init(store: NoteStore, handshakeTimeout: Duration = .seconds(15)) {
        self.store = store
        self.handshakeTimeout = handshakeTimeout
        (sessionEvents, sessionSink) = AsyncStream.makeStream()
    }

    /// Runs a session until the channel closes. Pass `pairingToken` (from the QR) on first contact.
    /// TLS has already checked the server's certificate; the session binds it to a paired device.
    public func session(_ channel: any SyncChannel, pairingToken: Data? = nil) async throws {
        defer {
            channel.close()
            sessionSink.yield(.ended)
        }
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        sessionGeneration += 1
        let generation = sessionGeneration
        events = continuation
        defer { if sessionGeneration == generation { events = nil } }
        let pump = Task {
            do {
                for try await message in channel.incoming { continuation.yield(.message(message)) }
            } catch {
                // Treated as a close below.
            }
            continuation.yield(.closed)
        }
        defer { pump.cancel() }

        var phase: Phase
        var peer: Peer?
        var serverVector = VersionVector()
        var roundRequested = false
        let watchdog = Task { [handshakeTimeout] in
            try await Task.sleep(for: handshakeTimeout)
            SyncLog.write("client: handshake timed out")
            channel.close()
        }
        defer { watchdog.cancel() }

        if let pairingToken {
            try await channel.send(.pair(.init(token: pairingToken, deviceID: store.deviceID, name: store.deviceName)))
            phase = .pairing
        } else {
            try await sendHello(over: channel)
            phase = .hello
        }

        for await event in stream {
            switch (phase, event) {
            case (.pairing, .closed), (.pairing, .message(.bye)):
                throw SyncError.pairingRejected
            case (.hello, .message(.bye(let reason))) where SyncMessage.protocolVersion(inByeReason: reason) != nil:
                throw SyncError.protocolVersion(SyncMessage.protocolVersion(inByeReason: reason) ?? 0)
            case (.hello, .closed), (.hello, .message(.bye)):
                throw SyncError.notPaired
            case (_, .closed), (_, .message(.bye)):
                return

            case (.pairing, .message(.paired(let server))):
                let (fingerprint, certificateDeviceID) = try channel.peerIdentity()
                guard certificateDeviceID == server.deviceID else { throw SyncError.identityMismatch }
                try store.addPeer(id: server.deviceID, name: server.name, fingerprint: fingerprint)
                peer = try store.peer(id: server.deviceID)
                try await sendHello(over: channel)
                phase = .hello
            case (.pairing, .message):
                throw SyncError.pairingRejected

            case (.hello, .message(.hello(let hello))):
                guard hello.protocolVersion == SyncMessage.protocolVersion else {
                    throw SyncError.protocolVersion(hello.protocolVersion)
                }
                let (fingerprint, certificateDeviceID) = try channel.peerIdentity()
                if peer == nil { peer = try store.peer(fingerprint: fingerprint) }
                guard let known = peer, hello.deviceID == known.id, certificateDeviceID == known.id else {
                    throw SyncError.notPaired
                }
                serverVector = hello.vector
                watchdog.cancel()
                log.info("session with \(known.name, privacy: .public)")
                SyncLog.write("client: session with \(known.name)")
                sessionSink.yield(.connected(known))
                try await startRound(since: serverVector, over: channel)
                phase = .inRound(pending: [])
            case (.hello, .message):
                throw SyncError.unexpectedMessage("expected hello")

            case (.idle, .localChange), (.idle, .message(.poke)):
                try await startRound(since: serverVector, over: channel)
                phase = .inRound(pending: [])

            case (.inRound(var pending), .message(.changes(let notes))):
                pending.append(contentsOf: notes)
                phase = .inRound(pending: pending)
            case (.inRound(let pending), .message(.changesDone(let vector))):
                guard let known = peer else { throw SyncError.notPaired }
                let applied = try store.apply(
                    pending, senderID: known.id, senderName: known.name, senderVector: vector)
                try store.markSynced(peerID: known.id)
                if let synced = try store.peer(id: known.id) {
                    sessionSink.yield(.synced(synced, changed: applied.changedAnything))
                }
                serverVector = vector
                if roundRequested {
                    roundRequested = false
                    try await startRound(since: serverVector, over: channel)
                    phase = .inRound(pending: [])
                } else {
                    phase = .idle
                }
            case (.inRound, .localChange), (.inRound, .message(.poke)), (.hello, .localChange),
                (.pairing, .localChange):
                // A trigger while busy: run another round as soon as this one ends.
                roundRequested = true

            case (_, .message(let other)):
                log.debug("ignoring \(String(describing: other), privacy: .public)")
            }
        }
    }

    /// Call after local writes; starts a round if a session is active.
    public func localChanged() {
        events?.yield(.localChange)
    }

    public var isConnected: Bool { events != nil }

    // MARK: Internals

    private func sendHello(over channel: any SyncChannel) async throws {
        try await channel.send(
            .hello(
                .init(
                    deviceID: store.deviceID, name: store.deviceName, protocolVersion: helloProtocolVersion,
                    vector: try store.vector())))
    }

    private func startRound(since serverVector: VersionVector, over channel: any SyncChannel) async throws {
        let snapshot = try store.changesSnapshot(since: serverVector)
        for start in stride(from: 0, to: snapshot.notes.count, by: 100) {
            try await channel.send(.changes(Array(snapshot.notes[start..<min(start + 100, snapshot.notes.count)])))
        }
        try await channel.send(.changesDone(snapshot.vector))
    }
}
