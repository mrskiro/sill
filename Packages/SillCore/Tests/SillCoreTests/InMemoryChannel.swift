import Foundation
@testable import SillCore

/// Two cross-wired channels: whatever one sends, the other receives.
final class InMemoryChannel: SyncChannel, @unchecked Sendable {
    let incoming: AsyncThrowingStream<SyncMessage, any Error>
    private let inbound: AsyncThrowingStream<SyncMessage, any Error>.Continuation
    private var outbound: AsyncThrowingStream<SyncMessage, any Error>.Continuation?
    private let lock = NSLock()
    private(set) var sent: [SyncMessage] = []
    /// What this end believes the peer's certificate is (tests build DER via DeviceCertificate).
    var peerCertificateDER: Data?

    private init() {
        (incoming, inbound) = AsyncThrowingStream.makeStream()
    }

    static func pair() -> (InMemoryChannel, InMemoryChannel) {
        let a = InMemoryChannel(), b = InMemoryChannel()
        a.outbound = b.inbound
        b.outbound = a.inbound
        return (a, b)
    }

    func send(_ message: SyncMessage) async throws {
        lock.withLock { sent.append(message) }
        guard let outbound else { throw SyncError.closed }
        outbound.yield(message)
    }

    func peerCertificate() -> Data? {
        peerCertificateDER
    }

    func close() {
        inbound.finish()
        outbound?.finish()
    }
}
