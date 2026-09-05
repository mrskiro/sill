import Foundation
import Testing

@testable import SillCore

/// What happens when the two apps are not on the same protocol version. The apps update at
/// different times (App Store on the phone, a download on the Mac), so this path is ordinary.
@Suite struct ProtocolVersionTests {
    private let newer = SyncMessage.protocolVersion + 1
    private let older = SyncMessage.protocolVersion - 1

    /// The one that actually happens: a real client and a real server, one app behind the other.
    /// The server refuses before it says hello, so the refusal has to travel as a `bye` reason —
    /// a bare close reads as "not paired" and would send the phone back into its retry loop.
    @Test func aRealSessionBetweenVersionsTellsBothSidesWhichAppIsBehind() async throws {
        let pair = try SyncSessionTests.Pair()
        try pair.pairDirectly()
        await pair.client.useHelloProtocolVersion(newer)

        let session = pair.connect()

        await #expect(throws: SyncError.protocolVersion(newer)) { try await session.server.value }
        // The phone learns the Mac's version, not "not paired".
        await #expect(throws: SyncError.protocolVersion(SyncMessage.protocolVersion)) {
            try await session.client.value
        }
        let error = SyncError.protocolVersion(SyncMessage.protocolVersion)
        #expect(error.isUnrecoverable)
        #expect(error.localizedDescription.contains("older"))
    }

    /// Frozen wire surface: a v1 app has to be able to read a refusal from a much later peer.
    @Test func theRefusalIsSpelledOutOnTheWire() {
        #expect(SyncMessage.versionByeReason.hasPrefix("protocol-version:"))
        #expect(SyncMessage.protocolVersion(inByeReason: SyncMessage.versionByeReason) == SyncMessage.protocolVersion)
        #expect(SyncMessage.protocolVersion(inByeReason: "protocol-version:42") == 42)
        #expect(SyncMessage.protocolVersion(inByeReason: "not paired") == nil)
        #expect(SyncMessage.protocolVersion(inByeReason: nil) == nil)
    }

    @Test func serverRejectsAHelloFromAnotherVersion() async throws {
        let pair = try SyncSessionTests.Pair()
        try pair.pairDirectly()
        let (macEnd, phoneEnd) = InMemoryChannel.pair()
        macEnd.peerCertificateDER = pair.phoneCertificate.certificateDER
        phoneEnd.peerCertificateDER = pair.macCertificate.certificateDER
        let serverTask = Task { try await pair.server.serve(macEnd) }

        try await phoneEnd.send(
            .hello(
                .init(
                    deviceID: pair.phone.id, name: "iPhone", protocolVersion: newer,
                    vector: try pair.phone.store.vector())))

        await #expect(throws: SyncError.protocolVersion(newer)) { try await serverTask.value }
        #expect(macEnd.sent == [.bye(SyncMessage.versionByeReason)])
    }

    @Test func clientRejectsAHelloFromAnotherVersion() async throws {
        let pair = try SyncSessionTests.Pair()
        try pair.pairDirectly()
        let (macEnd, phoneEnd) = InMemoryChannel.pair()
        macEnd.peerCertificateDER = pair.phoneCertificate.certificateDER
        phoneEnd.peerCertificateDER = pair.macCertificate.certificateDER
        let clientTask = Task { try await pair.client.session(phoneEnd, pairingToken: nil) }

        try await macEnd.send(
            .hello(
                .init(
                    deviceID: pair.mac.id, name: "Mac", protocolVersion: older,
                    vector: try pair.mac.store.vector())))

        await #expect(throws: SyncError.protocolVersion(older)) { try await clientTask.value }
    }

    /// The phone shows this string. It must not name a device: both ends raise the same error.
    @Test func theMessageSaysWhichSideToUpdate() {
        let theirsIsNewer = SyncError.protocolVersion(newer).localizedDescription
        #expect(theirsIsNewer.contains("newer"))
        #expect(theirsIsNewer.contains("Update this app"))
        let theirsIsOlder = SyncError.protocolVersion(older).localizedDescription
        #expect(theirsIsOlder.contains("older"))
        #expect(theirsIsOlder.contains("Update Sill there"))
        for error in [theirsIsNewer, theirsIsOlder] {
            #expect(!error.contains("Mac") && !error.contains("iPhone"))
            // Not "The operation couldn't be completed. (SillCore.SyncError error 4.)"
            #expect(!error.contains("couldn't be completed"))
        }
    }

    @Test func onlyAVersionMismatchStopsTheRetryLoop() {
        #expect(SyncError.protocolVersion(newer).isUnrecoverable)
        for error: SyncError in [.notPaired, .pairingRejected, .identityMismatch, .closed, .unexpectedMessage("hello")]
        {
            #expect(!error.isUnrecoverable)
            #expect(error.localizedDescription.hasSuffix("."))
        }
    }
}
