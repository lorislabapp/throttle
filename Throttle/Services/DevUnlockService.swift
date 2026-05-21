import CryptoKit
import Foundation
import OSLog
import Security

/// Hidden developer-unlock backdoor for Throttle Pro.
///
/// Activated via a 10-tap gesture on the version number in the About
/// pane (the dropdown's `AboutInline` view). On the 10th tap a sheet
/// appears with a `SecureField` for the unlock key. If the key matches
/// the stored hash, an `unlocked-at` entry is written to Keychain and
/// `isUnlocked` returns true permanently — `AppState.isPro` honors it
/// alongside the trial and the JWT license, so Pro features unlock
/// without ever calling the license server.
///
/// **Security model.** The unlock key is never stored in source. The
/// constant `expectedDigest` is `SHA256(salt || key)` of a 19-character
/// random key. Salt is `throttle-dev-unlock-2026:` (constant in the
/// binary; salt's purpose is uniqueness across apps, not secrecy).
/// Compare uses `Data.constantTimeEquals` to defeat timing attacks.
/// Even if an attacker has the binary, they need to either (a)
/// preimage SHA-256 over the salted key (computationally infeasible),
/// or (b) find the original 19-char key by brute force over a
/// ~107-bit space.
///
/// The unlock state is bound to the current Mac via `MachineFingerprint`
/// — copying the Keychain entry to another Mac doesn't transfer the
/// unlock; the verifier checks the `boundMachineId` field.
@MainActor
final class DevUnlockService {
    static let shared = DevUnlockService()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "DevUnlock")
    private let salt = "throttle-dev-unlock-2026:"
    /// SHA256 hex of `salt + key`. Computed offline — never the raw key
    /// in source. Replace this constant if you rotate the unlock key.
    private let expectedDigest = "2d9dd66cf7953e4798f3cb72abd45de132bf28af64c9679c56ec57b9f2ff8803"

    /// True when a previous successful unlock was persisted to Keychain
    /// AND the entry is still bound to this Mac. Survives app restarts;
    /// invalidated only by `lock()` or by copying to a different Mac.
    var isUnlocked: Bool {
        guard let stored = DevUnlockKeychain.load() else { return false }
        return stored.boundMachineId == MachineFingerprint.id
    }

    /// Attempt to unlock with a user-supplied key. Constant-time
    /// comparison; persists on success.
    @discardableResult
    func attemptUnlock(key: String) -> Bool {
        let candidate = sha256Hex(salt + key)
        guard let candidateData = candidate.data(using: .utf8),
              let expectedData = expectedDigest.data(using: .utf8),
              candidateData.constantTimeEquals(expectedData) else {
            logger.notice("dev unlock: key rejected")
            return false
        }
        let stored = StoredUnlock(
            boundMachineId: MachineFingerprint.id,
            unlockedAt: Date()
        )
        do {
            try DevUnlockKeychain.save(stored)
            logger.notice("dev unlock: granted on machine \(MachineFingerprint.id, privacy: .public)")
            return true
        } catch {
            logger.error("dev unlock: keychain write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Remove the unlock from this Mac. Used by tests and the Settings
    /// "Lock Pro" debug option (not exposed in production UI).
    func lock() {
        DevUnlockKeychain.clear()
    }

    private func sha256Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct StoredUnlock: Codable, Sendable {
    let boundMachineId: String
    let unlockedAt: Date
}

private enum DevUnlockKeychain {
    static let service = "com.lorislab.throttle.dev-unlock"
    static let account = "current"

    static func save(_ stored: StoredUnlock) throws {
        let data = try JSONEncoder().encode(stored)
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load() -> StoredUnlock? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredUnlock.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Constant-time `Data` comparison. Standard `==` short-circuits, which
/// leaks bytewise progress to a timing attacker. We XOR every byte and
/// or-accumulate so total time is fixed for inputs of equal length.
extension Data {
    func constantTimeEquals(_ other: Data) -> Bool {
        guard self.count == other.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<self.count {
            diff |= self[i] ^ other[i]
        }
        return diff == 0
    }
}
