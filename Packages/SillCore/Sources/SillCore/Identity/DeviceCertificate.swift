import CryptoKit
import Foundation
import SwiftASN1
import X509

/// A device's self-signed X.509 certificate and the key behind it. Pure value; the Keychain
/// side lives in `IdentityStore`. Peers pin the fingerprint, so nothing about the certificate
/// chain matters beyond "the same key as last time".
public struct DeviceCertificate: Sendable {
    public let deviceID: DeviceID
    public let privateKey: P256.Signing.PrivateKey
    public let certificateDER: Data

    public static let validity: TimeInterval = 10 * 365 * 24 * 60 * 60

    /// SHA-256 over the DER bytes. This is what pairing exchanges and validators compare.
    public var fingerprint: Data {
        Self.fingerprint(of: certificateDER)
    }

    public static func fingerprint(of certificateDER: Data) -> Data {
        Data(SHA256.hash(data: certificateDER))
    }

    /// Generates a fresh P-256 key and a self-signed certificate naming the device.
    public static func generate(deviceID: DeviceID, now: Date = Date()) throws -> DeviceCertificate {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName(deviceID.uuidString)
            OrganizationName("Sill")
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(validity),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                try Critical(BasicConstraints.notCertificateAuthority)
                try Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return DeviceCertificate(deviceID: deviceID, privateKey: key, certificateDER: Data(serializer.serializedBytes))
    }

    /// Parses a certificate produced by `generate` and returns the device id it names.
    public static func deviceID(inCertificate der: Data) throws -> DeviceID {
        let certificate = try Certificate(derEncoded: Array(der))
        for element in certificate.subject {
            for attribute in element where attribute.type == .RDNAttributeType.commonName {
                if let id = UUID(uuidString: attribute.value.description) { return id }
            }
        }
        throw IdentityError.malformedCertificate
    }
}

public enum IdentityError: Error, Equatable {
    case malformedCertificate
    case keychain(OSStatus, String)
    case identityNotFound
}
