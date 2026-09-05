import Foundation
import Network
import Security

public enum SillService {
    public static let type = "_sill._tcp"
    public static let fingerprintKey = "fp"

    /// Short, non-secret hint in the Bonjour TXT record so a client can pick its paired Mac
    /// out of several without connecting to each. Trust still comes from the full fingerprint over TLS.
    public static func fingerprintPrefix(_ fingerprint: Data) -> String {
        fingerprint.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// JSON-coded `SyncMessage`s over mutually authenticated TLS over TCP.
public typealias SillProtocol = Coder<SyncMessage, SyncMessage, NetworkJSONCoder>

/// Accepts a peer by certificate fingerprint. TLS calls this during the handshake.
public struct FingerprintPolicy: Sendable {
    public let isAcceptable: @Sendable (Data) async -> Bool

    public init(_ isAcceptable: @escaping @Sendable (Data) async -> Bool) {
        self.isAcceptable = isAcceptable
    }

    func validate(_ trust: sec_trust_t) async -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else { return false }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = DeviceCertificate.fingerprint(of: der)
        let accepted = await isAcceptable(fingerprint)
        SyncLog.write("tls peer \(SillService.fingerprintPrefix(fingerprint)) \(accepted ? "accepted" : "REJECTED")")
        return accepted
    }
}

/// The protocol stack both sides use. Peer-to-peer Wi-Fi is enabled so devices find each other
/// without a shared network.
func sillStack(identity: DeviceIdentity, policy: FingerprintPolicy) -> NWParametersBuilder<SillProtocol> {
    .parameters {
        Coder(SyncMessage.self, using: .json) {
            TLS()
                .peerAuthentication(.required)
                .localIdentity(identity.tlsIdentity)
                .certificateValidator { _, trust in await policy.validate(trust) }
        }
    }
    .peerToPeerIncluded(true)
}

/// Wraps a live connection as a `SyncChannel`. The peer certificate is taken from the TLS
/// metadata that arrives with the first message. `close()` ends `incoming`, which makes the
/// session return and, with it, the task that owns the connection.
public final class NetworkSyncChannel: SyncChannel, @unchecked Sendable {
    private let connection: NetworkConnection<SillProtocol>
    private let lock = NSLock()
    private var certificate: Data?
    public let incoming: AsyncThrowingStream<SyncMessage, any Error>
    private let continuation: AsyncThrowingStream<SyncMessage, any Error>.Continuation
    private var pump: Task<Void, Never>?

    public init(_ connection: NetworkConnection<SillProtocol>) {
        self.connection = connection
        let (stream, continuation) = AsyncThrowingStream<SyncMessage, any Error>.makeStream()
        incoming = stream
        self.continuation = continuation
        pump = Task { [weak self, connection] in
            do {
                for try await (content, metadata) in connection.messages {
                    self?.recordCertificate(from: metadata)
                    continuation.yield(content)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func send(_ message: SyncMessage) async throws {
        try await connection.send(message)
    }

    public func peerCertificate() -> Data? {
        lock.withLock { certificate }
    }

    public func close() {
        continuation.finish()
        pump?.cancel()
    }

    private func recordCertificate(from metadata: SillProtocol.Metadata) {
        guard peerCertificate() == nil else { return }
        for item in metadata.other {
            if let tls = item as? NWProtocolTLS.Metadata, let der = Self.leafCertificateDER(tls.securityProtocolMetadata) {
                lock.withLock { certificate = der }
                return
            }
        }
    }

    static func leafCertificateDER(_ metadata: sec_protocol_metadata_t) -> Data? {
        var der: Data?
        sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            if der == nil {
                der = SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data
            }
        }
        return der
    }
}

/// The Mac side: listens (optionally advertised over Bonjour) and serves every connection.
public struct SillListener: Sendable {
    public let identity: DeviceIdentity
    public let server: SyncServer
    public var advertise = true
    /// Random by default so the service name does not identify the user (TN3213 privacy note).
    public var serviceName = UUID().uuidString

    public init(identity: DeviceIdentity, server: SyncServer, advertise: Bool = true) {
        self.identity = identity
        self.server = server
        self.advertise = advertise
    }

    /// Runs until the task is cancelled. `onReady` receives the listening port.
    public func run(onReady: @escaping @Sendable (UInt16) -> Void = { _ in }) async throws {
        let server = server
        let policy = FingerprintPolicy { fingerprint in await server.isAcceptable(fingerprint: fingerprint) }
        let txt = NWTXTRecord([SillService.fingerprintKey: SillService.fingerprintPrefix(identity.fingerprint)])
        let provider: BonjourListenerProvider? = advertise
            ? BonjourListenerProvider(name: serviceName, type: SillService.type, txtRecord: txt)
            : nil
        let listener = try NetworkListener(for: provider, using: sillStack(identity: identity, policy: policy))
        listener.onStateUpdate { listener, state in
            SyncLog.write("listener state \(String(describing: state)) port=\(listener.port.map { String($0.rawValue) } ?? "-")")
            if case .ready = state, let port = listener.port { onReady(port.rawValue) }
        }
        try await listener.run { connection in
            // One connection's failure (rejected pairing, stale hello, protocol mismatch) is
            // routine and must never take the listener down with it.
            SyncLog.write("listener accepted connection")
            do {
                try await server.serve(NetworkSyncChannel(connection))
                SyncLog.write("listener session ended")
            } catch {
                SyncLog.write("listener session failed: \(error)")
            }
        }
    }
}

/// The iPhone side: find the paired Mac, connect, run the session.
public enum SillConnector {
    /// Connects and runs a client session until it ends. With `expectedFingerprint` (pairing) only
    /// that certificate is accepted; otherwise any paired peer is.
    public static func connect(
        to endpoint: NWEndpoint,
        identity: DeviceIdentity,
        client: SyncClient,
        expectedFingerprint: Data? = nil,
        pairingToken: Data? = nil
    ) async throws {
        let store = client.store
        let policy = FingerprintPolicy { fingerprint in
            if let expectedFingerprint { return fingerprint == expectedFingerprint }
            return (try? store.peer(fingerprint: fingerprint)) != nil
        }
        SyncLog.write("connect to \(endpoint) pairing=\(pairingToken != nil)")
        do {
            try await withNetworkConnection(to: endpoint, using: sillStack(identity: identity, policy: policy)) { connection in
                try await client.session(NetworkSyncChannel(connection), pairingToken: pairingToken)
            }
            SyncLog.write("connection ended normally")
        } catch {
            SyncLog.write("connection failed: \(error)")
            throw error
        }
    }

    /// Browses (including peer-to-peer Wi-Fi) until a Sill service advertising one of the given
    /// fingerprint prefixes appears; with several paired Macs, whichever is nearby wins.
    public static func findServer(fingerprintPrefixes: Set<String>) async throws -> NWEndpoint {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        SyncLog.write("browse for fp in \(fingerprintPrefixes.sorted())")
        return try await NetworkBrowser(for: .bonjour(SillService.type, includeTxtRecord: true), using: parameters)
            .onStateUpdate { _, state in SyncLog.write("browser state \(String(describing: state))") }
            .run { endpoints in
                SyncLog.write("browse results: \(endpoints.map { "\($0.name) fp=\($0.txtRecord[SillService.fingerprintKey] ?? "-")" })")
                if let match = endpoints.first(where: { endpoint in
                    endpoint.txtRecord[SillService.fingerprintKey].map(fingerprintPrefixes.contains) ?? false
                }) {
                    return .finish(match.nwEndpoint)
                }
                return .continue
            }
    }

    public static func findServer(fingerprintPrefix: String) async throws -> NWEndpoint {
        try await findServer(fingerprintPrefixes: [fingerprintPrefix])
    }
}
