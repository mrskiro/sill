import Foundation

/// Who dials whom. A Mac both listens and dials, so without a rule two Macs would open a session
/// each way and run every round twice. The lower device id dials; the higher one only listens.
/// Stateless and symmetric, so both ends reach the same answer without negotiating.
///
/// A phone never advertises, so it is simply never found; leaving it in the target list is harmless.
public enum SyncRole {
    public static func shouldDial(myDeviceID: DeviceID, peerID: DeviceID) -> Bool {
        myDeviceID.uuidString < peerID.uuidString
    }

    public static func dialTargets(myDeviceID: DeviceID, peers: [Peer]) -> [Peer] {
        peers.filter { shouldDial(myDeviceID: myDeviceID, peerID: $0.id) }
    }
}
