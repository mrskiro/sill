import Foundation

/// What a device can do on the network. A Mac listens (and may dial); a phone only dials, and
/// never advertises — so dialling one is a browse that can never match.
///
/// Sent as an optional field in `hello`: an app that predates it leaves the key out, and a peer
/// whose kind is still unknown keeps the old behaviour until it says hello once.
public enum DeviceKind: String, Codable, Sendable {
    case mac
    case phone

    /// What this build runs on. Tests pass one explicitly to stand in for the other side.
    public static var current: DeviceKind {
        #if os(macOS)
            .mac
        #else
            .phone
        #endif
    }
}
