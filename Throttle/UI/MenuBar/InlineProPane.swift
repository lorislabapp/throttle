import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct InlineProPane: View {
    @Environment(AppState.self) var appState
    @State var licenseStatus: String = ""
    @State var activating = false
    @State var connectionStatus: String = ""
    @State var testing = false
    @State var signedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            licenseBlock
            SettingsHair()
            exactBlock
        }
        .task { signedIn = ExactModeService.shared.hasFreshSnapshot }
    }

    // MARK: License

    @ViewBuilder
    var licenseBlock: some View {
        let trial = TrialService.shared
        let licenseState = LicenseService.shared.state
        let trialActive = trial.isActive && licenseState == .none
        SettingsGroupHeader(label: "License")
        if let key = LicenseService.shared.currentKey, licenseState != .none {
            let expired = licenseState == .expired
            SettingsRow(title: "Throttle Pro", sub: licenseSubtitle(key: key, expired: expired)) {
                Text(expired ? "EXPIRED" : "PRO").font(.system(size: 9.5, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(expired ? Color.red : Color.secondary)
            }
            HStack(spacing: 9) {
                if expired {
                    // The key is still ours — re-activating re-mints the JWT. Never
                    // send an expired-but-valid customer to the checkout page.
                    SettingsButton(title: "Reactivate", primary: true) { reactivateStoredKey() }
                        .disabled(activating)
                }
                Spacer(minLength: 0)
                SettingsButton(title: "Deactivate this Mac", role: .destructive) {
                    Task {
                        let freed = await LicenseService.shared.deactivate()
                        appState.refreshProStatus()
                        licenseStatus = freed
                            ? String(localized: "Deactivated.")
                            : String(localized: "Couldn't reach the license server — this Mac still holds its slot. Your key is untouched; try again later.")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        } else if trialActive {
            trialBannerView(daysLeft: trial.daysLeft)
            buyRow
        } else {
            SettingsNote(text: "Unlock Exact mode, Stats history and projections.")
            buyRow
        }
        if !licenseStatus.isEmpty {
            Text(licenseStatus)
                .font(.system(size: 11))
                .foregroundStyle(licenseStatus.hasPrefix("✓") || licenseStatus.hasPrefix("Deactiv") ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    func licenseSubtitle(key: String, expired: Bool) -> String {
        let masked = String(key.prefix(8)) + "····" + String(key.suffix(4))
        if expired {
            return String(localized: "Key \(masked) · lapsed on this Mac — reactivate to restore Pro")
        }
        if let exp = LicenseService.shared.expiresAt {
            return "Key \(masked) · renews \(exp.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Key \(masked)"
    }

    /// Re-mint the JWT from the key already in Keychain — the fix path for a license
    /// that lapsed because the Mac was offline (or the app wasn't running) through
    /// both `exp` and the grace window.
    func reactivateStoredKey() {
        guard let key = LicenseService.shared.currentKey else { return }
        activating = true
        licenseStatus = String(localized: "Reactivating…")
        Task {
            let result = await LicenseService.shared.activate(key: key)
            await MainActor.run {
                activating = false
                switch result {
                case .success:
                    licenseStatus = String(localized: "✓ Pro restored on this Mac.")
                    appState.refreshProStatus()
                case .failure(let err):
                    licenseStatus = describeLicenseError(err)
                }
            }
        }
    }

    var buyRow: some View {
        HStack(spacing: 9) {
            SettingsButton(title: "Buy Pro · €29", primary: true) {
                if let url = URL(string: "https://lorislab.fr/throttle/buy") { NSWorkspace.openInBackground(url) }
            }
            Button {
                activateFromClipboard()
            } label: {
                Text("Paste license key").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .disabled(activating)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.bottom, 11)
    }

    func trialBannerView(daysLeft: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            (Text("\(daysLeft)").font(.system(size: 12, weight: .semibold).monospacedDigit())
             + Text(daysLeft == 1 ? " day left in your Pro trial." : " days left in your Pro trial."))
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
    }

    func activateFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            licenseStatus = String(localized: "Clipboard is empty. Copy the key from your purchase email first.")
            return
        }
        guard raw.uppercased().hasPrefix("THROTTLE-") else {
            licenseStatus = String(localized: "That doesn't look like a Throttle license key (starts with THROTTLE-).")
            return
        }
        activating = true
        licenseStatus = String(localized: "Activating…")
        Task {
            let result = await LicenseService.shared.activate(key: raw.uppercased())
            await MainActor.run {
                activating = false
                switch result {
                case .success:
                    licenseStatus = String(localized: "✓ Pro activated on this Mac.")
                    appState.refreshProStatus()
                case .failure(let err):
                    licenseStatus = describeLicenseError(err)
                }
            }
        }
    }

    func describeLicenseError(_ err: LicenseService.ActivationError) -> String {
        switch err {
        case .invalidKey:           return String(localized: "Invalid license key.")
        case .machineLimitReached:  return String(localized: "Already activated on 3 Macs. Deactivate one first.")
        case .revoked:              return String(localized: "License revoked. Contact support@lorislab.fr.")
        case .verificationFailed:   return String(localized: "Server response failed signature check. Don't trust this network.")
        case .network(let m):       return String(localized: "Network error: \(m)")
        case .server(let code):     return String(localized: "Server error \(code). Try again later.")
        case .decode(let m):        return String(localized: "Couldn't decode response: \(m)")
        }
    }
}
