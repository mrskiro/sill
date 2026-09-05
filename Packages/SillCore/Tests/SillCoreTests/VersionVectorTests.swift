import Foundation
import Testing
@testable import SillCore

@Suite struct VersionVectorTests {
    let mac = UUID()
    let phone = UUID()

    @Test func containsAndRecord() {
        var vector = VersionVector()
        #expect(!vector.contains(Version(device: mac, seq: 1)))

        vector.record(Version(device: mac, seq: 3))
        #expect(vector.contains(Version(device: mac, seq: 3)))
        #expect(vector.contains(Version(device: mac, seq: 1)))
        #expect(!vector.contains(Version(device: mac, seq: 4)))
        #expect(!vector.contains(Version(device: phone, seq: 1)))

        vector.record(Version(device: mac, seq: 2))
        #expect(vector[mac] == 3)
    }

    @Test func mergeTakesMaxPerDevice() {
        let a = VersionVector([mac: 5, phone: 1])
        let b = VersionVector([mac: 2, phone: 4])
        let merged = a.merged(with: b)
        #expect(merged == VersionVector([mac: 5, phone: 4]))
    }

    @Test func encodesAsObjectKeyedByDeviceID() throws {
        let vector = VersionVector([mac: 7])
        let data = try JSONEncoder().encode(vector)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(json == [mac.uuidString: 7])
        #expect(try JSONDecoder().decode(VersionVector.self, from: data) == vector)
    }
}
