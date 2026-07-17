import CryptoKit
import Foundation
import IOKit
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
    private let renewAheadWindow: TimeInterval = 7 * 24 * 3600   // re-mint a week before exp

    enum ActivationError: Error, Sendable, Equatable {
        case invalidKey
        case machineLimitReached
        case revoked
        case verificationFailed
        case network(String)
        case server(Int)
        case decode(String)
    }

    /// What the Keychain currently entitles this Mac to.
    enum State: Equatable, Sendable {
        case none      // no key stored
        case active    // verified, in-window JWT
        case grace     // JWT unusable (expired / other machine) but still inside offline grace
        case expired   // key stored, JWT dead, grace over — needs a re-activation
    }

    var state: State {
        guard let stored = LicenseKeychain.load() else { return .none }
        if verify(stored.jwt) != nil { return .active }
        if Date().timeIntervalSince(stored.activatedAt) < offlineGraceDays + 30 * 24 * 3600 { return .grace }
        return .expired
    }

    /// True when a verified, non-expired (or within grace) JWT is in Keychain.
    var isPro: Bool {
        switch state {
        case .active, .grace: return true
        case .none, .expired: return false
        }
    }

    /// Re-mint the JWT while we still hold the key. `activate` is the only endpoint
    /// that issues one, so without this a license silently decays to Free once the
    /// JWT's `exp` passes and the grace window runs out.
    ///
    /// Runs at launch and daily. Returns true when a fresh JWT landed in Keychain.
    /// A failure is not surfaced: we keep whatever `state` we already had, so an
    /// offline Mac rides the grace window instead of losing Pro mid-flight.
    @discardableResult
    func refreshIfNeeded() async -> Bool {
        guard let stored = LicenseKeychain.load() else { return false }
        if let claims = verifyClaims(stored.jwt),
           Date().timeIntervalSince1970 < claims.exp - renewAheadWindow {
            return false   // still comfortably valid
        }
        guard case .success = await activate(key: stored.licenseKey) else {
            logger.notice("License refresh failed; staying on \(String(describing: self.state), privacy: .public)")
            return false
        }
        logger.info("License JWT refreshed")
        return true
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
        var payload: [String: String] = [
            "licenseKey": key,
            "machineId": machineId,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        ]
        // Lets the server recognise a Mac already registered under the old drifting
        // `kern.uuid` and swap it for the stable one, instead of treating this as a
        // brand-new machine and rejecting the owner at the 3-machine limit.
        if let legacy = MachineFingerprint.legacyId, legacy != machineId {
            payload["legacyMachineId"] = legacy
        }
        var req = URLRequest(url: activateURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20   // M21: don't hang the activation indefinitely
        // L14: surface an encode failure instead of POSTing an empty body.
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(.network("could not encode activation request"))
        }
        req.httpBody = body

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

    /// Deactivate this Mac: free the server-side slot, then drop the local Keychain
    /// entry. Returns false when the server never confirmed — in that case the key
    /// stays put.
    ///
    /// The key is only shown masked in Settings, so clearing it on a failed call
    /// would leave a user with no slot freed AND no key to retry with; their only
    /// copy is a months-old purchase email.
    @discardableResult
    func deactivate() async -> Bool {
        guard let stored = LicenseKeychain.load() else { return true }
        var payload: [String: String] = [
            "licenseKey": stored.licenseKey,
            "machineId": MachineFingerprint.id
        ]
        // This Mac's slot may still be filed under the old kern.uuid — free that
        // one too, or "Deactivate" would leave a ghost occupying a slot forever.
        if let legacy = MachineFingerprint.legacyId, legacy != MachineFingerprint.id {
            payload["legacyMachineId"] = legacy
        }
        var req = URLRequest(url: deactivateURL)
        req.timeoutInterval = 15   // M21
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            // 404 = the server has no such license; nothing to free, so clearing the
            // local copy is still the right end state.
            guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
                logger.notice("Deactivation refused with \(http.statusCode, privacy: .public); keeping the key")
                return false
            }
        } catch {
            logger.notice("Deactivation failed: \(error.localizedDescription, privacy: .public); keeping the key")
            return false
        }
        LicenseKeychain.clear()
        return true
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
        let skew: TimeInterval = 300   // L13: tolerate ±5 min clock skew so a slightly-off clock doesn't void a valid license
        guard claims.iss == "throttle-license",
              claims.product == "throttle.pro",
              claims.machineId == MachineFingerprint.id,
              now >= claims.nbf - skew,
              now < claims.exp + skew else {
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
    /// Stable per-Mac identifier: IOPlatformExpertDevice's IOPlatformUUID. Survives
    /// reinstalls, OS upgrades and network changes; resets only if the logic board
    /// is replaced.
    ///
    /// Until 3.2.69 this read `kern.uuid`, which derives from the primary MAC and is
    /// NOT stable: one Mac burned all three license slots with four distinct values
    /// (E0B4A1A8…, 4FEB3A7D…, 9E45D69F…, then FE82AB17…). `legacyId` exists so the
    /// server can migrate those records in place — see `LicenseService.activate`.
    static let id: String = {
        if let viaIOKit = ioPlatformUUID(), !viaIOKit.isEmpty {
            return viaIOKit
        }
        // IOKit is the contract; these only cover a registry we can't read at all.
        if let viaSysctl = legacyId, !viaSysctl.isEmpty {
            return viaSysctl
        }
        return persistedFallbackId()
    }()

    /// The pre-3.2.70 fingerprint. Sent alongside `id` at activation so the server
    /// can swap it for the stable one without spending another machine slot.
    static let legacyId: String? = sysctlString("kern.uuid")

    private static func ioPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return prop.takeRetainedValue() as? String
    }

    /// Last resort when the IO registry is unreadable. Persisted, because the old
    /// `globallyUniqueString` fallback minted a fresh ID on every launch — each one
    /// eating a machine slot until the license locked its owner out.
    private static func persistedFallbackId() -> String {
        let key = "throttleMachineFallbackId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = "fallback-\(UUID().uuidString)"
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
