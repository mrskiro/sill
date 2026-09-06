import Foundation
import Testing

@testable import SillCore

@Suite struct SyncRoleTests {
    private func peer(_ id: DeviceID, name: String = "Mac") -> Peer {
        Peer(id: id, name: name, fingerprint: Data(repeating: 1, count: 32), pairedAt: Date())
    }

    /// The point of the rule: of any two devices, exactly one dials. Otherwise two Macs open a
    /// session each way and run every round twice.
    @Test func exactlyOneSideOfAPairDials() {
        for _ in 0..<200 {
            let a = UUID()
            let b = UUID()
            let aDials = SyncRole.shouldDial(myDeviceID: a, peerID: b)
            let bDials = SyncRole.shouldDial(myDeviceID: b, peerID: a)
            #expect(aDials != bDials)
        }
    }

    @Test func aDeviceNeverDialsItself() {
        let id = UUID()
        #expect(!SyncRole.shouldDial(myDeviceID: id, peerID: id))
    }

    @Test func targetsAreTheHigherIDsOnly() {
        let ids = (0..<5).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        let me = ids[2]
        let targets = SyncRole.dialTargets(myDeviceID: me, peers: ids.map { peer($0) })
        #expect(targets.map(\.id) == [ids[3], ids[4]])
    }
}
