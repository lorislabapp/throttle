import CryptoKit
import Foundation

/// Remembers that the user agreed to run one exact command in one project.
///
/// `.throttle/plan.json` is a file in the repository, so its `verify` command is
/// shell written by whoever wrote the repository. Cloning a project and opening it
/// must not run what it asks for; the grant is keyed by the command's hash, so
/// editing the command asks again.
enum VerifyConsent {

    private static let storageKey = "planVerifyConsent"

    static func key(project: URL, command: String) -> String {
        let material = project.standardizedFileURL.path + "\u{0}" + command
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isGranted(project: URL, command: String,
                          defaults: UserDefaults = .standard) -> Bool {
        let granted = defaults.array(forKey: storageKey) as? [String] ?? []
        return granted.contains(key(project: project, command: command))
    }

    static func grant(project: URL, command: String, defaults: UserDefaults = .standard) {
        var granted = defaults.array(forKey: storageKey) as? [String] ?? []
        let key = key(project: project, command: command)
        guard !granted.contains(key) else { return }
        granted.append(key)
        defaults.set(granted, forKey: storageKey)
    }
}
