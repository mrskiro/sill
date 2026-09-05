import Foundation
import Security

/// The device identity as the Keychain holds it: a `SecIdentity` for TLS plus the DER bytes.
public struct DeviceIdentity: @unchecked Sendable {
    public let deviceID: DeviceID
    public let certificateDER: Data
    public let secIdentity: SecIdentity

    public var fingerprint: Data { DeviceCertificate.fingerprint(of: certificateDER) }
}

/// Persists one device certificate + private key in the data-protection keychain and hands
/// back the `SecIdentity` Network.framework needs. Apple has no API to build an identity in
/// memory, so the key and certificate are added as items and the identity is looked up.
public struct IdentityStore: Sendable {
    public let label: String

    public init(label: String = "com.mrskiro.sill.device-identity") {
        self.label = label
    }

    /// Returns the stored identity, creating and storing a new one on first use.
    public func loadOrCreate(deviceID: DeviceID) throws -> DeviceIdentity {
        if let existing = try load() {
            return existing
        }
        let generated = try DeviceCertificate.generate(deviceID: deviceID)
        try store(generated)
        guard let stored = try load() else { throw IdentityError.identityNotFound }
        return stored
    }

    public func load() throws -> DeviceIdentity? {
        var query = base(kSecClassIdentity)
        query[kSecReturnRef] = true
        query[kSecReturnAttributes] = false
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "load identity")
        let identity = result as! SecIdentity
        var certificate: SecCertificate?
        try check(SecIdentityCopyCertificate(identity, &certificate), "copy certificate")
        guard let certificate else { throw IdentityError.identityNotFound }
        let der = SecCertificateCopyData(certificate) as Data
        return DeviceIdentity(deviceID: try DeviceCertificate.deviceID(inCertificate: der), certificateDER: der, secIdentity: identity)
    }

    /// Removes the identity (unpairing everything, or tests cleaning up).
    public func delete() throws {
        for itemClass in [kSecClassIdentity, kSecClassCertificate, kSecClassKey] {
            let status = SecItemDelete(base(itemClass) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                try check(status, "delete \(itemClass)")
            }
        }
    }

    // MARK: - Internals

    private func store(_ material: DeviceCertificate) throws {
        guard let certificate = SecCertificateCreateWithData(nil, material.certificateDER as CFData) else {
            throw IdentityError.malformedCertificate
        }
        var addCertificate = base(kSecClassCertificate)
        addCertificate[kSecValueRef] = certificate
        try check(SecItemAdd(addCertificate as CFDictionary, nil), "add certificate")

        // The identity forms when the key's application label equals the certificate's public key hash.
        var readHash = base(kSecClassCertificate)
        readHash[kSecReturnAttributes] = true
        var attributes: CFTypeRef?
        try check(SecItemCopyMatching(readHash as CFDictionary, &attributes), "read certificate attributes")
        guard let publicKeyHash = (attributes as? [CFString: Any])?[kSecAttrPublicKeyHash] as? Data else {
            throw IdentityError.keychain(errSecInternalError, "certificate has no public key hash")
        }

        var keyError: Unmanaged<CFError>?
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let key = SecKeyCreateWithData(material.privateKey.x963Representation as CFData, keyAttributes as CFDictionary, &keyError) else {
            throw IdentityError.keychain(errSecParam, "SecKeyCreateWithData: \(keyError?.takeRetainedValue().localizedDescription ?? "?")")
        }
        var addKey = base(kSecClassKey)
        addKey[kSecValueRef] = key
        addKey[kSecAttrApplicationLabel] = publicKeyHash
        addKey[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(SecItemAdd(addKey as CFDictionary, nil), "add private key")
    }

    private func base(_ itemClass: CFString) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: itemClass, kSecAttrLabel: label]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        return query
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw IdentityError.keychain(status, "\(what): \(message)")
        }
    }
}
