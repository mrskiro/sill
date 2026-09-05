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

public enum SyncError: Error, Equatable {
    case unexpectedMessage(String)
    case notPaired
    case pairingRejected
    case identityMismatch
    case protocolVersion(Int)
    case closed
}
