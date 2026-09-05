import Foundation

/// For each device, the highest write counter this replica has seen.
/// "Seen" means: every note version from that device up to `maxSeq` has been applied
/// (or superseded by a later version this replica also applied).
public struct VersionVector: Hashable, Sendable {
    public private(set) var maxSeq: [DeviceID: Int64]

    public init(_ maxSeq: [DeviceID: Int64] = [:]) {
        self.maxSeq = maxSeq
    }

    public subscript(device: DeviceID) -> Int64 {
        maxSeq[device] ?? 0
    }

    /// True when this replica has already seen `version` (or a later write from its device).
    public func contains(_ version: Version) -> Bool {
        self[version.device] >= version.seq
    }

    public mutating func record(_ version: Version) {
        maxSeq[version.device] = max(self[version.device], version.seq)
    }

    public mutating func merge(_ other: VersionVector) {
        for (device, seq) in other.maxSeq {
            maxSeq[device] = max(self[device], seq)
        }
    }

    public func merged(with other: VersionVector) -> VersionVector {
        var copy = self
        copy.merge(other)
        return copy
    }
}

extension VersionVector: Codable {
    // Encoded as {"<uuid>": seq} rather than Swift's default array form for UUID keys,
    // so the wire format stays readable.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Int64].self)
        var result: [DeviceID: Int64] = [:]
        for (key, value) in raw {
            guard let device = UUID(uuidString: key) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid device id \(key)"))
            }
            result[device] = value
        }
        self.init(result)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw = Dictionary(uniqueKeysWithValues: maxSeq.map { ($0.key.uuidString, $0.value) })
        try container.encode(raw)
    }
}
