import Foundation

/// Cover the preparation interval before the durable journal exists. Every local
/// launch gate reads this reservation, including another tab for the same native
/// conversation. After begin(), the journal takes over before this is released.
@MainActor
enum RemoteTransferReservation {
    private struct Key: Hashable { let runtime: String; let nativeID: String }
    private static var owners: [Key: UUID] = [:]

    static func acquire(runtime: String, nativeID: String) -> UUID? {
        let key = Key(runtime: runtime, nativeID: nativeID.lowercased())
        guard owners[key] == nil else { return nil }
        let token = UUID()
        owners[key] = token
        return token
    }

    static func contains(runtime: String, nativeID: String) -> Bool {
        owners[Key(runtime: runtime, nativeID: nativeID.lowercased())] != nil
    }

    static func contains(runtime: String) -> Bool {
        owners.keys.contains { $0.runtime == runtime }
    }

    static func release(runtime: String, nativeID: String, token: UUID) {
        let key = Key(runtime: runtime, nativeID: nativeID.lowercased())
        if owners[key] == token { owners.removeValue(forKey: key) }
    }
}
