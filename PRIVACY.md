# Throttle privacy and data-flow map

Last reviewed: 2026-09-21. This document describes the repository source. App Store privacy labels, signed artifacts and deployed services must be verified separately before release. Source-map corrections: 2026-09-22 (T1.2).

Throttle is local-first and contains no advertising or third-party analytics SDK. It is not an offline-only app: enabled features use the network and some features move user-selected data between the user's devices or self-hosted systems.

| Feature | Data | Destination | Trigger/control | Local retention |
|---|---|---|---|---|
| Local meter and cockpit | token counts, timestamps, model/session metadata; terminal I/O stays inside the launched provider process | local Mac | opening/running Throttle | SQLite and provider-native session files |
| Project Assistant | messages, selected project context and tool results | on-device Apple/MLX model, explicitly selected Ollama server, or explicitly selected Anthropic API/web session | provider choice followed by a request; unavailable local processing does not authorize cloud fallback | view-scoped transcript locally; remote retention depends on the selected provider/server and is not established by this source review |
| Research Vault | user-selected research receipts, bounded excerpts, provenance, hashes and optional on-device drafts | local, separately signed Throttle helper over authenticated XPC | explicit helper enablement, receipt import, Inbox selection, search or synthesis | SQLCipher database; master key in Keychain; security-scoped Inbox bookmark in app preferences |
| Exact usage | account usage response, not message content | Anthropic OAuth usage endpoint, then embedded authenticated claude.ai session on failure | explicit Exact Mode | bounded cached snapshot |
| Assistant / Prompt Refiner | submitted messages or draft and assembled project context | selected/available AI provider; Claude API or claude.ai for network providers | user requests an answer/refinement; provider fallback can select a network provider; Refiner local-only (enabled by default) excludes both network providers | provider-specific; claude.ai conversations also persist server-side |
| Embedded model installation | model identifier and download requests | Hugging Face | loading the on-device model when weights are needed | local model cache |
| Web research | requested URLs and page requests, including page subresources | requested websites via embedded WebKit | Web research enabled and render requested | ephemeral WebKit website data store |
| Research Vault URL intake | requested HTTPS URL | selected website | explicit URL import | extracted receipt and provenance in local vault after intake/review |
| License | license key, device fingerprint, app version and optional legacy device assertion | `license.lorislab.fr` activation service | activation and license refresh | signed token in Keychain; deployed server retention is not established by this source review |
| Updates | appcast and update package | LorisLabs update host | Sparkle setting | Sparkle-managed cache |
| iOS/vision mirror | usage/cockpit snapshot and LAN pairing material | user's private CloudKit database and paired Mac on the same local network | companion mirror opt-in | encrypted CloudKit record; App Group cache/history |
| LAN remote terminal | terminal output and user keystrokes | paired Mac on the local network | user opens a running session; device-owner unlock for input | terminal view only |
| Self-hosted Edge | session metadata, terminal I/O, selected transcript/repository bundle | endpoint configured from the macOS app | explicit macOS setup, attach or offload | self-hosted tmux/session storage and bounded transfer files |
| Claude↔Codex handoff | reviewed objective, Git branch/HEAD/status and mission provenance | target CLI process on the same Mac | explicit handoff confirmation | Throttle mission ledger and provider-native session |
| AI optimization | selected configuration or transcript content included in the request | on-device model or explicitly selected Assistant provider/server, as above | optimization request; preview/apply controls the subsequent local write, not transmission | proposal locally; remote retention depends on the selected provider/server |
| Config editing | selected local configuration file and accepted proposal | local filesystem | explicit preview/apply | backup plus reversible local edit |

## Secrets

Client bearer tokens, license material and API keys belong in Keychain or an equivalently scoped secret store. Secrets must never appear in logs, generated reports, shell profiles, command-line arguments or committed configuration. Provider authentication remains owned by the provider CLI.

## User controls

- Assistant providers, companion mirroring and remote control require their respective choices or enablement. Update checks follow Sparkle settings (automatic checks are enabled in the source configuration); license refresh follows activation. Do not treat the whole app as offline until a network feature is explicitly selected.
- Network behavior depends on the feature controls above. Provider fallback can
  use the network; choosing a local-first workflow alone is not an offline guarantee.
- Research Vault is opt-in. Throttle never sends its database key, vault path or
  security-scoped Inbox access to CheatCode; cross-app access is bounded to cited
  query results by signed client identity.
- Handoffs show the target and bounded context before launch.
- iPhone LAN terminal input starts locked and relocks after inactivity/backgrounding.
  Mac Edge input has no equivalent biometric or inactivity lock.
- App Store companions restrict remote input to the user's paired Mac on the local network; off-LAN Edge control is not exposed there.
- Mirror data is scrubbed locally when the iCloud identity changes.
- Disabling the mirror stops publishing; it does not delete an existing server record. The separate deletion action requires an available iCloud account and reports failure if deletion cannot complete.
- Stopping an Assistant response cancels local consumption. It does not recall data already sent or prove that remote processing/billing stopped.
- Optimizer changes are previewed and backed up before write.

## Source evidence and remaining limits

The Assistant routing boundary is implemented by `AIProviderRegistry` and `AIProviderRoutingPolicy`; `EmbeddedModelProvider` distinguishes on-device and self-hosted destinations. `ClaudeAPIKeyProvider` sends requests to `https://api.anthropic.com/v1/messages`; `ClaudeWebSessionProvider` uses the selected authenticated web session. Project tool access is bounded by `AssistantProjectTools`. These source boundaries do not establish a remote provider's retention or deletion policy.

`CloudKitPublisher.stop()` and `deleteMirror()` implement separate opt-out and deletion operations. `LicenseService+Payload.swift` defines activation fields. This review did not inspect real account contents, credentials or the deployed license backend. Provider/server retention, deletion procedures and the final public privacy text remain release checks; no retention duration is inferred here.

Source references for these corrections: [ExactModeService](Throttle/Network/ExactModeService.swift),
[AIProviderRegistry](Throttle/Services/AIProviderRegistry.swift),
[PromptRefinerService](Throttle/Services/PromptRefinerService.swift),
[ClaudeWebSessionProvider](Throttle/Services/ClaudeWebSessionProvider.swift),
[EmbeddedModelProvider](Throttle/Services/EmbeddedModelProvider.swift),
[WebRenderer](Throttle/Services/WebRenderer.swift),
[URL intake](Throttle/Services/ResearchVaultURLIntake.swift) and
[Mac Edge terminal](Throttle/UI/Cockpit/RemoteSessionPane.swift).

## Apple privacy manifests

The iOS app declares both app-only UserDefaults (`CA92.1`) and App Group UserDefaults (`1C8F.1`). The iOS widget and visionOS app declare App Group access (`1C8F.1`). These required-reason declarations do not by themselves prove App Store privacy-label correctness; inspect the final archive's privacy report.

## Not collected by LorisLabs through the apps

The source contains no advertising identifier, cross-app tracking or analytics/crash-reporting SDK. User-controlled CloudKit, peer and self-hosted Edge transfers are not represented as developer analytics collection, but they remain real network/data paths disclosed above.
