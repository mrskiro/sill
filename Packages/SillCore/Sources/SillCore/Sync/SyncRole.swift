import Foundation

/// Who dials whom. A Mac both listens and dials, so without a rule two Macs would open a session
/// each way and run every round twice. The lower device id dials; the higher one only listens.
/// Stateless and symmetric, so both ends reach the same answer without negotiating.
///
/// A phone never advertises, so it is never found. It stays in the target list all the same — the
/// `peer` table records no device kind — which costs a Mac whose phone sorts above it a browse that
/// can never match (and the local-network prompt that comes with it). Telling the kinds apart needs
/// a field in `hello`, so it waits for the next protocol version.
public enum SyncRole {
    public static func shouldDial(myDeviceID: DeviceID, peerID: DeviceID) -> Bool {
        myDeviceID.uuidString < peerID.uuidString
    }

    public static func dialTargets(myDeviceID: DeviceID, peers: [Peer]) -> [Peer] {
        peers.filter { shouldDial(myDeviceID: myDeviceID, peerID: $0.id) }
    }
}
