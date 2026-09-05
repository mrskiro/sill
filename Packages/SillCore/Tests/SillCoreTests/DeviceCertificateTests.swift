import CryptoKit
import Foundation
import Testing
import X509

@testable import SillCore

@Suite struct DeviceCertificateTests {
    @Test func generatesASelfSignedCertificateNamingTheDevice() throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let material = try DeviceCertificate.generate(deviceID: id, now: now)

        let certificate = try Certificate(derEncoded: Array(material.certificateDER))
        #expect(certificate.subject == certificate.issuer)
        #expect(certificate.subject.description.contains(id.uuidString))
        #expect(certificate.notValidBefore <= now)
        #expect(certificate.notValidAfter > now.addingTimeInterval(9 * 365 * 24 * 60 * 60))
        #expect(certificate.publicKey.isValidSignature(certificate.signature, for: certificate))
        #expect(try DeviceCertificate.deviceID(inCertificate: material.certificateDER) == id)
    }

    @Test func fingerprintIsSHA256OfTheDER() throws {
        let material = try DeviceCertificate.generate(deviceID: UUID())
        #expect(material.fingerprint == Data(SHA256.hash(data: material.certificateDER)))
        #expect(material.fingerprint.count == 32)
        let other = try DeviceCertificate.generate(deviceID: UUID())
        #expect(material.fingerprint != other.fingerprint)
    }

    @Test func rejectsCertificatesThatDoNotNameADevice() throws {
        #expect(throws: (any Error).self) {
            try DeviceCertificate.deviceID(inCertificate: Data([0x30, 0x00]))
        }
    }
}
