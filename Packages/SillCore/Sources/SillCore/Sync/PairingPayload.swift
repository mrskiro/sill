import Foundation

/// What the Mac's QR code carries. The token is single-use and expires with the pairing window;
/// the fingerprint lets the phone verify it is talking to this Mac before sending the token.
public struct PairingPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var deviceID: DeviceID
    public var name: String
    public var fingerprint: Data
    public var token: Data

    public static let currentVersion = 1

    public init(deviceID: DeviceID, name: String, fingerprint: Data, token: Data) {
        version = Self.currentVersion
        self.deviceID = deviceID
        self.name = name
        self.fingerprint = fingerprint
        self.token = token
    }

    /// Compact text for the QR code (and for pasting on a device without a camera).
    public var qrString: String {
        let data = try! JSONEncoder().encode(self)
        return "sill:" + data.base64EncodedString()
    }

    public init?(qrString: String) {
        guard qrString.hasPrefix("sill:"), let data = Data(base64Encoded: String(qrString.dropFirst(5))),
              let payload = try? JSONDecoder().decode(PairingPayload.self, from: data),
              payload.version == Self.currentVersion, payload.fingerprint.count == 32 else { return nil }
        self = payload
    }
}
