import Foundation
import Security

/// Minimal Keychain wrapper for the small secrets Throttle holds (the edge-agent
/// bearer token, the LAN pairing secret). `WhenUnlockedThisDeviceOnly` — never
/// synced to iCloud, never leaves the device, unavailable while locked. Replaces
/// plaintext UserDefaults storage for anything that can control a remote session.
public enum KeychainStore {
    /// Store (or delete when `value` is nil) a UTF-8 string under `account`.
    @discardableResult
    public static func set(_ value: String?, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lorislab.throttle",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lorislab.throttle",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
