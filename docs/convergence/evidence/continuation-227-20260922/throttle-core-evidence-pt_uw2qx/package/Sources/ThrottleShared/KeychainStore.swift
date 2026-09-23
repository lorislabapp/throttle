import Foundation
import Security

/// Minimal Keychain wrapper for the small secrets Throttle holds (the edge-agent
/// bearer token, the LAN pairing secret). `WhenUnlockedThisDeviceOnly` — never
/// synced to iCloud, never leaves the device, unavailable while locked. Replaces
/// plaintext UserDefaults storage for anything that can control a remote session.
public enum KeychainStore {
    /// Synchronous Security calls are injectable only for deterministic tests.
    /// Production does not replace a process-global backend.
    struct Operations {
        let update: ([String: Any], [String: Any]) -> OSStatus
        let add: ([String: Any]) -> OSStatus
        let delete: ([String: Any]) -> OSStatus

        static var system: Operations {
            Operations(
                update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
                add: { SecItemAdd($0 as CFDictionary, nil) },
                delete: { SecItemDelete($0 as CFDictionary) }
            )
        }
    }

    /// Store a UTF-8 value without deleting an existing credential first.
    /// Only nil requests deletion; missing items already satisfy that request.
    @discardableResult
    public static func set(_ value: String?, account: String,
                           service: String = "com.lorislab.throttle") -> Bool {
        set(value, account: account, service: service, using: .system)
    }

    @discardableResult
    static func set(_ value: String?, account: String,
                    service: String = "com.lorislab.throttle", using operations: Operations) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let value else {
            let status = operations.delete(base)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = operations.update(base, attributes)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let add = base.merging(attributes) { _, value in value }
        let added = operations.add(add)
        // A concurrent writer may create the same account between update and add.
        if added == errSecDuplicateItem {
            return operations.update(base, attributes) == errSecSuccess
        }
        return added == errSecSuccess
    }

    public enum ReadResult: Equatable {
        case found(String)
        case missing
        case unavailable(OSStatus)
    }

    /// Missing is the only outcome that permits automatic credential creation.
    /// Locked, denied and malformed values must not be treated as absent.
    public static func read(account: String) -> ReadResult {
        read(account: account) { query in
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            return (status, out as? Data)
        }
    }

    static func read(account: String,
                     using lookup: ([String: Any]) -> (OSStatus, Data?)) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lorislab.throttle",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let (status, data) = lookup(query)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data, let value = String(data: data, encoding: .utf8) else {
            return .unavailable(errSecDecode)
        }
        return .found(value)
    }

    /// Compatibility for callers that only display an optional credential.
    /// Creation/migration must use `read` and distinguish unavailable from missing.
    public static func get(account: String) -> String? {
        guard case let .found(value) = read(account: account) else { return nil }
        return value
    }
}
