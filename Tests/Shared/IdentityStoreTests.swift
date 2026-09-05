import Foundation
import Security
import SillCore
import Testing

/// Runs inside the signed app (Mac) or the simulator app (iOS): the data-protection keychain
/// needs the application-identifier entitlement that only a real app process has.
@Suite struct IdentityStoreTests {
    @Test func createsAnIdentityOnceAndReloadsTheSameOne() throws {
        let store = IdentityStore(label: "com.mrskiro.sill.test-identity.\(UUID().uuidString)")
        defer { try? store.delete() }
        let deviceID = UUID()

        #expect(try store.load() == nil)
        let created = try store.loadOrCreate(deviceID: deviceID)
        #expect(created.deviceID == deviceID)
        #expect(created.fingerprint.count == 32)

        let reloaded = try store.loadOrCreate(deviceID: deviceID)
        #expect(reloaded.deviceID == deviceID)
        #expect(reloaded.fingerprint == created.fingerprint)
        #expect(reloaded.certificateDER == created.certificateDER)

        // The SecIdentity carries a usable private key that matches the certificate.
        var keyRef: SecKey?
        #expect(SecIdentityCopyPrivateKey(reloaded.secIdentity, &keyRef) == errSecSuccess)
        let key = try #require(keyRef)
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let message = Data("sill".utf8)
        var error: Unmanaged<CFError>?
        let signatureData =
            SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) as Data?
        let signature = try #require(signatureData)
        #expect(
            SecKeyVerifySignature(
                publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, &error))
    }

    /// A reinstall recreates the database (new device id) while the Keychain keeps the old identity.
    @Test func identityLeftByAnotherDeviceIdIsReplaced() throws {
        let store = IdentityStore(label: "com.mrskiro.sill.test-identity.\(UUID().uuidString)")
        defer { try? store.delete() }
        let old = try store.loadOrCreate(deviceID: UUID())
        let fresh = UUID()
        let replaced = try store.loadOrCreate(deviceID: fresh)
        #expect(replaced.deviceID == fresh)
        #expect(replaced.fingerprint != old.fingerprint)
        #expect(try store.load()?.deviceID == fresh)
    }

    @Test func deleteRemovesEverything() throws {
        let store = IdentityStore(label: "com.mrskiro.sill.test-identity.\(UUID().uuidString)")
        _ = try store.loadOrCreate(deviceID: UUID())
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()  // idempotent
    }
}
