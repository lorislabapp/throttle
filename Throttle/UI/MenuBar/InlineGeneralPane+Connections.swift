import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineGeneralPane {
    @ViewBuilder
    var connectionSettings: some View {
        SettingsHair()
        SettingsRow(title: "iOS companion mirror (iCloud)",
                    sub: mirrorNote.isEmpty
                        ? """
                        Publishes your live usage + cockpit state to your private iCloud so the Throttle iOS \
                        app can mirror it anywhere. Read-only, your iCloud only — no LorisLabs server, no \
                        data leaves your account.
                        """
                        : mirrorNote) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Toggle("", isOn: appState.isPro ? $mirrorOn : .constant(false))
                    .labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .disabled(!appState.isPro)
                    .onChange(of: mirrorOn) { _, on in
                        guard appState.isPro else { return }
                        UserDefaults.standard.set(on, forKey: "throttleiCloudMirrorEnabled")
                        if on {
                            CloudKitPublisher.shared.start()
                            PeerTransport.shared.start()   // LAN fast path (sub-second when same Wi-Fi)
                            mirrorNote =
                                "On — open the Throttle app on your iPhone (same iCloud account) to see the mirror."
                        } else {
                            CloudKitPublisher.shared.stop()
                            PeerTransport.shared.stop()
                            mirrorNote = "Off — the iPhone keeps its last synced snapshot."
                        }
                    }
            }
        }
        if mirrorOn && appState.isPro {
            SettingsHair()
            SettingsRow(title: "Off-Wi-Fi control (Tailscale)",
                sub:
                    """
                    This Mac's tailnet IP or MagicDNS name, so the iPhone can still reach it \
                    off your home Wi-Fi (e.g. on cellular). Leave blank to stay LAN-only.
                    """
            ) {
                TextField("100.x.x.x or mac.tailxxxx.ts.net", text: $peerFallbackHost)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 200)
                    .onChange(of: peerFallbackHost) { _, host in
                        PeerTransport.shared.fallbackHost = host
                    }
            }
        }
        SettingsHair()
        SettingsRow(title: "Cockpit: drop images as OCR text",
            sub:
                """
                Drop a screenshot into a Cockpit session as locally-OCR'd text (≈80–90% \
                fewer tokens than a vision image) — loses the visual, so hold ⌥ while \
                dropping to flip per-drop.
                """
        ) {
            Toggle("", isOn: $dropImagesAsText).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .onChange(of: dropImagesAsText) { _, on in
                    UserDefaults.standard.set(on, forKey: DroppableTerminalView.ocrDefaultsKey)
                }
        }
        SettingsHair()
        SettingsRow(title: "Team policy (managed-settings.json)",
            sub:
                """
                Export a Claude Code hardening policy (deny rules, model, output-style) \
                for an admin to deploy across a team via MDM. 100% local — Throttle \
                generates it, you distribute it.
                """
        ) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                SettingsButton(title: "Export…") { if appState.isPro { exportTeamPolicy() } }
                    .disabled(!appState.isPro)
            }
        }
        SettingsHair()
        SettingsRow(title: "Run sessions on your server",
            sub:
                """
                Offload Claude Code sessions to a Throttle Edge Agent on your own box \
                (e.g. a Proxmox LXC) to free the Mac's RAM. Throttle generates the deploy \
                + verifies the agent; you run the SSH. Measure + start/stop/pause — never \
                a data-path proxy.
                """
        ) {
            HStack(spacing: 6) {
                if !appState.isPro {
                    Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                SettingsButton(title: "Configure…") {
                    if appState.isPro { SessionOffloadWindowController.shared.show() }
                }
                    .disabled(!appState.isPro)
            }
        }
        SettingsHair()
        SettingsRow(title: "Software updates", sub: updatesSubtitle) {
            SettingsButton(title: "Check now") { UpdaterService.shared.checkForUpdates() }
        }
        SettingsNote(text: "Throttle \(currentVersionLabel) · updates are signed and verified before install.")
    }
}
