import Foundation

/// Wire messages. JSON via Network.framework's `Coder`; the in-memory channel used in tests
/// carries the same values. Keep this small: every case here is protocol surface.
public enum SyncMessage: Codable, Sendable, Equatable {
    public static let protocolVersion = 1

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

        public init(deviceID: DeviceID, name: String, protocolVersion: Int = SyncMessage.protocolVersion, vector: VersionVector) {
            self.deviceID = deviceID
            self.name = name
            self.protocolVersion = protocolVersion
            self.vector = vector
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

    public init(id: DeviceID, name: String, fingerprint: Data, pairedAt: Date, lastSyncAt: Date? = nil) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt
        self.lastSyncAt = lastSyncAt
    }
}
