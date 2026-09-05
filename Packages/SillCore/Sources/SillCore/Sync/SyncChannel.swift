import Foundation

/// One bidirectional message pipe to a peer. Network.framework provides the real one;
/// tests use an in-memory pair. `incoming` ends when the peer goes away.
public protocol SyncChannel: Sendable {
    func send(_ message: SyncMessage) async throws
    var incoming: AsyncThrowingStream<SyncMessage, any Error> { get }
    /// The peer's certificate (DER). For TLS channels it is known once the first message has
    /// arrived, so callers read it after receiving, never before.
    func peerCertificate() -> Data?
    func close()
}

extension SyncChannel {
    /// Fingerprint and device id bound to the peer's certificate.
    func peerIdentity() throws -> (fingerprint: Data, deviceID: DeviceID) {
        guard let der = peerCertificate() else { throw SyncError.identityMismatch }
        return (DeviceCertificate.fingerprint(of: der), try DeviceCertificate.deviceID(inCertificate: der))
    }
}

public enum SyncError: Error, Equatable, LocalizedError {
    case unexpectedMessage(String)
    case notPaired
    case pairingRejected
    case identityMismatch
    case protocolVersion(Int)
    case closed

    /// Shown to the user (the phone puts it under the note list), so every case reads as a
    /// sentence. `.protocolVersion` never says "Mac" or "iPhone": both sides raise it, and each
    /// one means "the device at the other end".
    public var errorDescription: String? {
        switch self {
        case .unexpectedMessage(let expected): "The other device sent something unexpected (expected \(expected))."
        case .notPaired: "The other device is not paired with this one."
        case .pairingRejected: "Pairing was refused. Show the pairing code on the Mac again."
        case .identityMismatch: "The other device did not prove it is the one you paired with."
        case .protocolVersion(let theirs):
            theirs > SyncMessage.protocolVersion
                ? "The other device runs a newer version of Sill. Update this app to keep syncing."
                : "The other device runs an older version of Sill. Update Sill there to keep syncing."
        case .closed: "The connection closed."
        }
    }

    /// Reconnecting cannot fix these, so the phone stops its retry loop instead of spinning:
    /// only updating one of the two apps changes the answer.
    public var isUnrecoverable: Bool {
        if case .protocolVersion = self { return true }
        return false
    }
}
