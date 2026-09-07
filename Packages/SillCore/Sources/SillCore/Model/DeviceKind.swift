import Foundation

/// What a device can do on the network. A Mac listens (and may dial); an iOS device only dials,
/// and never advertises — so dialling one is a browse that can never match.
///
/// Named for the platform rather than the form factor so an iPad needs no new case: adding one
/// later is what would hurt, because a value an older app has never heard of must not break it.
public enum DeviceKind: String, Codable, Sendable {
    case mac
    case ios
    /// A kind some later version introduced. Decoding never fails on an unfamiliar value — it
    /// lands here, and is treated like a device that has not said what it is.
    case unknown

    /// What this build runs on. Tests pass one explicitly to stand in for the other side.
    public static var current: DeviceKind {
        #if os(macOS)
            .mac
        #else
            .ios
        #endif
    }

    /// Whether dialling this kind can ever reach anything. Unknown kinds keep the old behaviour.
    public var advertises: Bool {
        self != .ios
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeviceKind(rawValue: raw) ?? .unknown
    }
}
