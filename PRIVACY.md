# Throttle privacy and data-flow map

Last reviewed: 2026-08-15. This document describes the repository source. App Store privacy labels, signed artifacts and deployed services must be verified separately before release.

Throttle is local-first and contains no advertising or third-party analytics SDK. It is not an offline-only app: enabled features use the network and some features move user-selected data between the user's devices or self-hosted systems.

| Feature | Data | Destination | Trigger/control | Local retention |
|---|---|---|---|---|
| Local meter and cockpit | token counts, timestamps, model/session metadata; terminal I/O stays inside the launched provider process | local Mac | opening/running Throttle | SQLite and provider-native session files |
| Exact usage | account usage response, not message content | Anthropic via the user's authenticated web session | explicit Exact Mode | bounded cached snapshot |
| License | license token and product/device assertions | LorisLabs license service | activation/validation | token in Keychain |
| Updates | appcast and update package | LorisLabs update host | Sparkle setting | Sparkle-managed cache |
| iOS/vision mirror | usage/cockpit snapshot and LAN pairing material | user's private CloudKit database and paired Mac on the same local network | companion mirror opt-in | encrypted CloudKit record; App Group cache/history |
| LAN remote terminal | terminal output and user keystrokes | paired Mac on the local network | user opens a running session; device-owner unlock for input | terminal view only |
| Self-hosted Edge | session metadata, terminal I/O, selected transcript/repository bundle | endpoint configured from the macOS app | explicit macOS setup, attach or offload | self-hosted tmux/session storage and bounded transfer files |
| Claude↔Codex handoff | reviewed objective, Git branch/HEAD/status and mission provenance | target CLI process on the same Mac | explicit handoff confirmation | Throttle mission ledger and provider-native session |
| Optimizers/config tools | selected Claude configuration or transcript file | local filesystem unless the user explicitly selects Edge | explicit preview/apply | backup plus reversible local edit |

## Secrets

Client bearer tokens, license material and API keys belong in Keychain or an equivalently scoped secret store. Secrets must never appear in logs, generated reports, shell profiles, command-line arguments or committed configuration. Provider authentication remains owned by the provider CLI.

## User controls

- Networked and configuration-changing features are opt-in.
- Handoffs show the target and bounded context before launch.
- Remote terminal input starts locked and relocks after inactivity/backgrounding.
- App Store companions restrict remote input to the user's paired Mac on the local network; off-LAN Edge control is not exposed there.
- Mirror data is scrubbed locally when the iCloud identity changes.
- Optimizer changes are previewed and backed up before write.

## Apple privacy manifests

The iOS app declares both app-only UserDefaults (`CA92.1`) and App Group UserDefaults (`1C8F.1`). The iOS widget and visionOS app declare App Group access (`1C8F.1`). These required-reason declarations do not by themselves prove App Store privacy-label correctness; inspect the final archive's privacy report.

## Not collected by LorisLabs through the apps

The source contains no advertising identifier, cross-app tracking or analytics/crash-reporting SDK. User-controlled CloudKit, peer and self-hosted Edge transfers are not represented as developer analytics collection, but they remain real network/data paths disclosed above.
