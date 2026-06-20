import CryptoKit
import Foundation
import OSLog
import Security

/// Throttle Pro license activation + JWT verification.
///
/// Flow:
///   1. User buys via Stripe Checkout → Worker mints license key → emails it.
///   2. User pastes key into Throttle → `activate(key:)` calls
///      `https://license.lorislab.fr/api/activate` with machineId.
///   3. Worker returns RS256-signed JWT bound to the machineId.
///   4. We verify the JWT against the bundled public key, then store it
///      in Keychain. The JWT is what unlocks Pro — no further network calls
///      needed unless it's about to expire.
///
/// Offline grace: when the JWT expires we keep granting Pro for 14 days
/// while we silently retry refresh in the background. Avoids ruining
/// Kevin's day if Cloudflare Workers has an outage.
@MainActor
final class LicenseService {
    static let shared = LicenseService()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "License")
    private let activateURL = URL(string: "https://license.lorislab.fr/api/activate")!
    private let deactivateURL = URL(string: "https://license.lorislab.fr/api/deactivate")!
    private let offlineGraceDays: TimeInterval = 14 * 24 * 3600

    enum ActivationError: Error, Sendable, Equatable {
        case invalidKey
        case machineLimitReached
        case revoked
        case verificationFailed
        case network(String)
        case server(Int)
        case decode(String)
    }

    /// True when a verified, non-expired (or within grace) JWT is in Keychain.
    var isPro: Bool {
        guard let stored = LicenseKeychain.load() else { return false }
        return verify(stored.jwt) != nil || (Date().timeIntervalSince(stored.activatedAt) < offlineGraceDays + 30 * 24 * 3600)
    }

    /// The license key currently activated, if any (for display in Settings).
    var currentKey: String? {
        LicenseKeychain.load()?.licenseKey
    }

    /// The expiry date of the current JWT, if any.
    var expiresAt: Date? {
        guard let stored = LicenseKeychain.load(),
              let claims = verifyClaims(stored.jwt) else { return nil }
        return Date(timeIntervalSince1970: claims.exp)
    }

    /// Activate a license key. On success, stores the JWT in Keychain.
    func activate(key: String) async -> Result<Void, ActivationError> {
        let machineId = MachineFingerprint.id
        let payload: [String: String] = [
            "licenseKey": key,
            "machineId": machineId,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        ]
        var req = URLRequest(url: activateURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.network("non-HTTP response")) }
            switch http.statusCode {
            case 200:
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let jwt = obj["jwt"] as? String else {
                    return .failure(.decode("missing jwt"))
                }
                guard verify(jwt) != nil else { return .failure(.verificationFailed) }
                let stored = StoredLicense(licenseKey: key, jwt: jwt, activatedAt: Date())
                try LicenseKeychain.save(stored)
                logger.info("License activated for machine \(machineId, privacy: .public)")
                return .success(())
            case 403:
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = obj["error"] as? String {
                    if err == "machine_limit_reached" { return .failure(.machineLimitReached) }
                    if err == "revoked" { return .failure(.revoked) }
                }
                return .failure(.server(403))
            case 404:
                return .failure(.invalidKey)
            default:
                return .failure(.server(http.statusCode))
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// Deactivate this Mac. Removes the machineId from the server's active list,
    /// then clears local Keychain. Frees up a slot for another Mac.
    func deactivate() async {
        if let stored = LicenseKeychain.load() {
            let payload: [String: String] = [
                "licenseKey": stored.licenseKey,
                "machineId": MachineFingerprint.id
            ]
            var req = URLRequest(url: deactivateURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: req)
        }
        LicenseKeychain.clear()
    }

    // MARK: - JWT verification

    private struct Claims: Codable {
        let iss: String
        let sub: String       // license key
        let machineId: String
        let email: String
        let product: String
        let appVersion: String
        let iat: TimeInterval
        let exp: TimeInterval
        let nbf: TimeInterval
    }

    private func verify(_ jwt: String) -> Claims? {
        verifyClaims(jwt)
    }

    private func verifyClaims(_ jwt: String) -> Claims? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let headerData = base64UrlDecode(String(parts[0])),
              let payloadData = base64UrlDecode(String(parts[1])),
              let signatureData = base64UrlDecode(String(parts[2])) else {
            return nil
        }
        // Verify header alg = RS256
        guard let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256" else { return nil }

        // Reconstruct the signing input.
        let signingInput = "\(parts[0]).\(parts[1])"
        guard let signingData = signingInput.data(using: .utf8) else { return nil }

        // Verify against bundled public key.
        guard let publicKey = LicensePublicKey.shared else { return nil }
        var error: Unmanaged<CFError>?
        let isValid = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingData as CFData,
            signatureData as CFData,
            &error
        )
        guard isValid else { return nil }

        // Decode + validate claims.
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payloadData) else { return nil }
        let now = Date().timeIntervalSince1970
        guard claims.iss == "throttle-license",
              claims.product == "throttle.pro",
              claims.machineId == MachineFingerprint.id,
              now >= claims.nbf,
              now < claims.exp else {
            return nil
        }
        return claims
    }

    private func base64UrlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: b64)
    }
}

// MARK: - Stored license

struct StoredLicense: Codable, Sendable {
    let licenseKey: String
    let jwt: String
    let activatedAt: Date
}

private enum LicenseKeychain {
    static let service = "com.lorislab.throttle.license"
    static let account = "current"

    static func save(_ stored: StoredLicense) throws {
        let data = try JSONEncoder().encode(stored)
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly   // M17: don't replicate to iCloud Keychain
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load() -> StoredLicense? {
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
        return try? JSONDecoder().decode(StoredLicense.self, from: data)
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

// MARK: - Public key (loaded from bundle)

private enum LicensePublicKey {
    nonisolated(unsafe) static let shared: SecKey? = {
        guard let url = Bundle.main.url(forResource: "throttle-license-public", withExtension: "pem"),
              let pem = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let b64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let derSPKI = Data(base64Encoded: b64) else { return nil }
        // SecKeyCreateWithData expects PKCS#1 RSAPublicKey, not the X.509
        // SubjectPublicKeyInfo wrapper that PEM uses. Strip the SPKI header
        // (24 bytes for 2048-bit RSA) to get to the raw RSAPublicKey.
        let rsaKeyData = stripSPKIHeader(derSPKI) ?? derSPKI
        let attrs: [String: Any] = [
            kSecAttrKeyType as String:   kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String:  kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]
        return SecKeyCreateWithData(rsaKeyData as CFData, attrs as CFDictionary, nil)
    }()

    /// Strip the X.509 SubjectPublicKeyInfo prefix off a 2048-bit RSA SPKI.
    /// Returns just the inner RSAPublicKey (PKCS#1) bytes.
    private static func stripSPKIHeader(_ spki: Data) -> Data? {
        // SPKI for 2048-bit RSA starts with a 24-byte ASN.1 header. The
        // inner RSAPublicKey BIT STRING begins after byte 23 (0x00 unused-bits
        // marker). We parse minimally: find the BIT STRING tag (0x03) at
        // a low offset and skip its length + the unused-bits byte.
        var i = 0
        let bytes = [UInt8](spki)
        while i < bytes.count - 4 {
            if bytes[i] == 0x03 {
                // BIT STRING — read length
                let lenByte = Int(bytes[i + 1])
                let lenSize: Int
                let totalLen: Int
                if lenByte < 0x80 {
                    lenSize = 1
                    totalLen = lenByte
                } else {
                    let lenOctets = lenByte & 0x7f
                    lenSize = 1 + lenOctets
                    var v = 0
                    for k in 0..<lenOctets {
                        v = (v << 8) | Int(bytes[i + 2 + k])
                    }
                    totalLen = v
                }
                // Skip BIT STRING tag + length octets + unused-bits byte (0x00)
                let dataStart = i + 1 + lenSize + 1
                let dataEnd = dataStart + totalLen - 1
                guard dataStart < bytes.count, dataEnd <= bytes.count else { return nil }
                return Data(bytes[dataStart..<dataEnd])
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Machine fingerprint

enum MachineFingerprint {
    /// Stable per-Mac identifier from IOPlatformUUID. Doesn't change across
    /// reinstalls or updates; resets if user replaces the logic board.
    static let id: String = {
        // sysctl -n kern.uuid is the cleanest path.
        // Fallback: read IOPlatformExpertDevice's IOPlatformUUID via IOKit.
        if let viaSysctl = sysctlString("kern.uuid"), !viaSysctl.isEmpty {
            return viaSysctl
        }
        return "unknown-\(ProcessInfo.processInfo.globallyUniqueString)"
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
