import Foundation

extension LicenseService {
    static func activationPayload(key: String, machineID: String) -> [String: String] {
        var payload: [String: String] = [
            "licenseKey": key,
            "machineId": machineID,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        ]
        // Lets the server recognise a Mac already registered under the old drifting
        // `kern.uuid` and swap it for the stable one, instead of treating this as a
        // brand-new machine and rejecting the owner at the 3-machine limit.
        if let legacy = MachineFingerprint.legacyId, legacy != machineID {
            payload["legacyMachineId"] = legacy
        }
        return payload
    }
}
