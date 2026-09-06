import Foundation

/// Wire messages. JSON via Network.framework's `Coder`; the in-memory channel used in tests
/// carries the same values. Keep this small: every case here is protocol surface.
public enum SyncMessage: Codable, Sendable, Equatable {
    public static let protocolVersion = 1

    /// A refusal for version reasons: `bye("protocol-version:1")`. Frozen wire surface — a peer
    /// that speaks a later version still has to send this exact shape, because v1 apps are the
    /// ones that have to understand the refusal, and v1 can no longer be changed.
    public static var versionByeReason: String { "protocol-version:\(protocolVersion)" }

    /// The peer's version if `reason` is such a refusal.
    public static func protocolVersion(inByeReason reason: String?) -> Int? {
        guard let reason, reason.hasPrefix("protocol-version:") else { return nil }
        return Int(reason.dropFirst("protocol-version:".count))
    }

    case hello(Hello)
    /// Client → server, only while the server shows a pairing QR.
    case pair(Pair)
    /// Server → client, after a successful `pair`.
    case paired(PeerInfo)
    case changes([Note])
    /// Ends a batch; carries the sender's vector after all its writes so far.
    case changesDone(VersionVector)
    /// Server → client: "I have new changes, start a round".
    case poke
    case bye(String?)

    public struct Hello: Codable, Sendable, Equatable {
        public var deviceID: DeviceID
        public var name: String
        public var protocolVersion: Int
        public var vector: VersionVector
        /// Optional on the wire: an app from before this field simply leaves it out, and the peer
        /// keeps treating its kind as unknown. Adding it needs no protocol version bump; raising
        /// the version would instead cut off every app that has not been updated yet.
        public var kind: DeviceKind?

        public init(
            deviceID: DeviceID, name: String, protocolVersion: Int = SyncMessage.protocolVersion,
            vector: VersionVector, kind: DeviceKind? = nil
        ) {
            self.deviceID = deviceID
            self.name = name
            self.protocolVersion = protocolVersion
            self.vector = vector
            self.kind = kind
        }
    }

    public struct Pair: Codable, Sendable, Equatable {
        public var token: Data
        public var deviceID: DeviceID
        public var name: String

        public init(token: Data, deviceID: DeviceID, name: String) {
            self.token = token
            self.deviceID = deviceID
            self.name = name
        }
    }
}

public struct PeerInfo: Codable, Sendable, Equatable {
    public var deviceID: DeviceID
    public var name: String

    public init(deviceID: DeviceID, name: String) {
        self.deviceID = deviceID
        self.name = name
    }
}

/// A trusted device: paired once, then recognised by its certificate fingerprint.
public struct Peer: Equatable, Sendable, Identifiable {
    public var id: DeviceID
    public var name: String
    public var fingerprint: Data
    public var pairedAt: Date
    public var lastSyncAt: Date?
    /// Nil until the peer has said hello with a version of the app that reports it.
    public var kind: DeviceKind?

    public init(
        id: DeviceID, name: String, fingerprint: Data, pairedAt: Date, lastSyncAt: Date? = nil,
        kind: DeviceKind? = nil
    ) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt
        self.lastSyncAt = lastSyncAt
        self.kind = kind
    }
}
