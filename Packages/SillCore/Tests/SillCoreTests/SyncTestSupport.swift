import Foundation

@testable import SillCore

/// An in-memory replica for sync tests.
struct Replica {
    let name: String
    let store: NoteStore

    init(_ name: String, kind: DeviceKind = .current) throws {
        self.name = name
        store = try NoteStore(database: try AppDatabase.inMemory(), deviceName: name, deviceKind: kind)
    }

    var id: DeviceID { store.deviceID }

    /// Live notes as id → content, for equality checks between replicas.
    func liveContents() throws -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: try store.liveNotes().map { ($0.id, $0.content) })
    }
}

/// One sync round exactly as the protocol runs it: the client's changes are applied first,
/// then the server answers with everything the client has not seen.
enum SyncRound {
    @discardableResult
    static func run(client: Replica, server: Replica) throws -> (server: ApplyResult, client: ApplyResult) {
        let toServer = try client.store.changes(since: try server.store.vector())
        let serverResult = try server.store.apply(
            toServer, senderID: client.id, senderName: client.name, senderVector: try client.store.vector()
        )
        let toClient = try server.store.changes(since: try client.store.vector())
        let clientResult = try client.store.apply(
            toClient, senderID: server.id, senderName: server.name, senderVector: try server.store.vector()
        )
        return (serverResult, clientResult)
    }
}

/// Deterministic RNG (SplitMix64) so a failing simulation can be replayed from its seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
