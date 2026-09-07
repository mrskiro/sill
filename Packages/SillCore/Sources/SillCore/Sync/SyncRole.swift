import Foundation

/// Who dials whom. A Mac both listens and dials, so without a rule two Macs would open a session
/// each way and run every round twice. The lower device id dials; the higher one only listens.
/// Stateless and symmetric, so both ends reach the same answer without negotiating.
///
/// An iOS device never advertises, so dialling one is a browse that can never match (and a
/// local-network prompt for nothing). Peers say what they are in `hello`, so those are left out.
/// A peer that has not said hello since the field existed stays a candidate: the first hello
/// settles it.
public enum SyncRole {
    public static func shouldDial(myDeviceID: DeviceID, peerID: DeviceID) -> Bool {
        myDeviceID.uuidString < peerID.uuidString
    }

    public static func dialTargets(myDeviceID: DeviceID, peers: [Peer]) -> [Peer] {
        peers.filter { ($0.kind?.advertises ?? true) && shouldDial(myDeviceID: myDeviceID, peerID: $0.id) }
    }
}
