import Foundation
import os

/// The listening side (the Mac). Serves any number of connections; each runs `serve(_:)`.
/// Trust: a connection is served only if its certificate fingerprint belongs to a paired peer,
/// or if it presents the current pairing token first.
public actor SyncServer {
    public let store: NoteStore
    private var pairingToken: Data?
    private var channels: [UUID: any SyncChannel] = [:]
    private let log = Logger(subsystem: "com.mrskiro.sill", category: "sync-server")

    /// UI-facing notifications.
    public enum Event: Sendable, Equatable {
        case connections(Int)
        case paired(Peer)
        case synced(Peer)
    }
    public nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    public init(store: NoteStore) {
        self.store = store
        (events, eventSink) = AsyncStream.makeStream()
    }

    // MARK: Pairing window

    /// Starts accepting one unknown device; returns the one-time token to put in the QR code.
    @discardableResult
    public func beginPairing() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes)
        pairingToken = token
        return token
    }

    public func endPairing() {
        pairingToken = nil
    }

    public var isPairing: Bool { pairingToken != nil }

    /// Whether the TLS layer should let a certificate through. Called from the validator.
    public func isAcceptable(fingerprint: Data) -> Bool {
        if pairingToken != nil { return true }
        return (try? store.peer(fingerprint: fingerprint)) != nil
    }

    // MARK: Serving

    /// Runs one connection to completion. The peer's certificate (validated by TLS already)
    /// binds the session to a device, not just to what `hello` claims.
    public func serve(_ channel: any SyncChannel) async throws {
        let id = UUID()
        channels[id] = channel
        eventSink.yield(.connections(channels.count))
        defer {
            channels[id] = nil
            channel.close()
            eventSink.yield(.connections(channels.count))
        }

        var inbox = channel.incoming.makeAsyncIterator()

        // First message: either `pair` (pairing window) or `hello` (known peer).
        guard let first = try await inbox.next() else { return }
        let (peerFingerprint, certificateDeviceID) = try channel.peerIdentity()
        var peer = try store.peer(fingerprint: peerFingerprint)
        switch first {
        case .pair(let pair):
            guard let token = pairingToken, token == pair.token else {
                SyncLog.write("server: pairing rejected (window open: \(pairingToken != nil))")
                try await channel.send(.bye("pairing rejected"))
                throw SyncError.pairingRejected
            }
            SyncLog.write("server: paired \(pair.name)")
            guard pair.deviceID == certificateDeviceID else { throw SyncError.identityMismatch }
            try store.addPeer(id: pair.deviceID, name: pair.name, fingerprint: peerFingerprint)
            pairingToken = nil
            peer = try store.peer(id: pair.deviceID)
            if let peer { eventSink.yield(.paired(peer)) }
            try await channel.send(.paired(PeerInfo(deviceID: store.deviceID, name: store.deviceName)))
            guard case .hello(let hello)? = try await inbox.next() else { throw SyncError.unexpectedMessage("expected hello after pairing") }
            try await handshake(hello, peer: &peer, certificateDeviceID: certificateDeviceID, channel: channel)
        case .hello(let hello):
            try await handshake(hello, peer: &peer, certificateDeviceID: certificateDeviceID, channel: channel)
        default:
            throw SyncError.unexpectedMessage("expected pair or hello")
        }
        guard let peer else { throw SyncError.notPaired }
        log.info("session with \(peer.name, privacy: .public)")
        SyncLog.write("server: session with \(peer.name)")

        var pending: [Note] = []
        while let message = try await inbox.next() {
            switch message {
            case .changes(let notes):
                pending.append(contentsOf: notes)
            case .changesDone(let clientVector):
                try store.apply(pending, senderID: peer.id, senderName: peer.name, senderVector: clientVector)
                pending = []
                try await sendChanges(since: clientVector, over: channel)
                try store.markSynced(peerID: peer.id)
                if let synced = try store.peer(id: peer.id) { eventSink.yield(.synced(synced)) }
            case .bye:
                return
            case .hello, .pair, .paired, .poke:
                log.debug("ignoring \(String(describing: message), privacy: .public)")
            }
        }
    }

    /// Tells every connected client to start a round (called after local writes).
    public func poke() async {
        for channel in channels.values {
            try? await channel.send(.poke)
        }
    }

    public var connectionCount: Int { channels.count }

    // MARK: Internals

    private func handshake(_ hello: SyncMessage.Hello, peer: inout Peer?, certificateDeviceID: DeviceID, channel: any SyncChannel) async throws {
        guard hello.protocolVersion == SyncMessage.protocolVersion else { throw SyncError.protocolVersion(hello.protocolVersion) }
        guard hello.deviceID == certificateDeviceID, var known = peer, known.id == hello.deviceID else {
            try await channel.send(.bye("not paired"))
            throw SyncError.notPaired
        }
        if known.name != hello.name {
            try store.addPeer(id: known.id, name: hello.name, fingerprint: known.fingerprint, now: known.pairedAt)
            known.name = hello.name
            peer = known
        }
        try await channel.send(.hello(.init(deviceID: store.deviceID, name: store.deviceName, vector: try store.vector())))
    }

    private func sendChanges(since vector: VersionVector, over channel: any SyncChannel) async throws {
        let outbound = try store.changes(since: vector)
        for start in stride(from: 0, to: outbound.count, by: 100) {
            try await channel.send(.changes(Array(outbound[start..<min(start + 100, outbound.count)])))
        }
        try await channel.send(.changesDone(try store.vector()))
    }
}
