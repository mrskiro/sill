import Foundation
import Testing

@testable import SillCore

@Suite struct SyncRoleTests {
    private func peer(_ id: DeviceID, name: String = "Mac", kind: DeviceKind? = nil) -> Peer {
        Peer(id: id, name: name, fingerprint: Data(repeating: 1, count: 32), pairedAt: Date(), kind: kind)
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

    /// A phone never advertises, so dialling one is a browse that can never match. A peer that has
    /// not said hello since `kind` existed stays a candidate rather than being dropped.
    @Test func phonesAreNeverDialledAndUnknownPeersStillAre() {
        let ids = (0..<3).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        let me = ids[0]
        let targets = SyncRole.dialTargets(
            myDeviceID: me,
            peers: [peer(ids[1], name: "iPhone", kind: .phone), peer(ids[2], name: "Old Mac", kind: nil)])
        #expect(targets.map(\.id) == [ids[2]])

        let macs = SyncRole.dialTargets(myDeviceID: me, peers: [peer(ids[1], kind: .mac)])
        #expect(macs.map(\.id) == [ids[1]])
    }
}
