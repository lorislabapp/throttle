# visionOS companion — transport constraints and market reality

Research date: **2026-09-09**. Scope: a visionOS companion to an existing macOS product
(Throttle), connecting a Vision Pro to the user's own Mac over LAN and, when away, over
Tailscale, built by a solo developer on a **standard individual Apple Developer Program
membership** with **no special entitlements**.

Method: primary sources first — Apple documentation (pulled from Apple's DocC JSON
backend, since `developer.apple.com/documentation` is a JS SPA), Apple Newsroom, Apple
Support, the App Store Review Guidelines, live `apps.apple.com` product pages read via
their embedded `serialized-server-data` (which carries **per-platform** version history),
and Apple Developer Forums threads with the responder's Apple/DTS label recorded. Analyst
and press figures are attributed to a named firm or outlet with a date. Anything that
could not be confirmed is marked **UNVERIFIED** rather than filled in.

Two premises carried into this research turned out to be wrong and are corrected in place:
the remote-desktop guideline is **4.2.7**, not 4.7; and **UTM SE was rejected from the App
Store and refused notarization, then approved on the ordinary App Store** — not "allowed
via notarization in the EU".

---

# PART A — Transport and platform constraints

## Verdict

**Yes. The transport plan is possible on a plain individual membership, with no
entitlement that Apple has to grant.**

This is a verified conclusion, not an optimistic one. Apple's Technote **TN3179
"Understanding local network privacy"** publishes the exact operation tables, and in every
one of the three cases the answer for `com.apple.developer.networking.multicast` is **not
required**:

| Case | Multicast entitlement | Local Network prompt | Confidence |
| --- | --- | --- | --- |
| `NWBrowser` on `_throttle._tcp` + `NWConnection` to the resolved endpoint | **No** | **Yes** | VERIFIED |
| TCP to a known LAN IPv4/IPv6 address, no discovery | **No** | **Yes** | VERIFIED |
| TCP to a `100.64.0.0/10` Tailscale address | **No** | **No** | VERIFIED definition → INFERENCE |
| Mac app **listening / accepting** only | n/a (never needed on macOS) | **No** | VERIFIED |
| Mac app **registering** Bonjour, or connecting out | n/a | **Yes** (macOS 15+) | VERIFIED |

The cost of the Bonjour path is **one Local Network prompt and two Info.plist keys**. The
Tailscale path appears to cost nothing at all, because Apple's own definition of "local
network" **excludes VPN interfaces**.

Three caveats that matter more than the permissions do:

1. **The real risk is lifecycle, not permissions.** Apple has documented almost nothing
   about what happens to a live socket when the headset comes off. Assume iPad-style
   suspension and design for reconnect.
2. **The Local Network prompt does not exist in the simulator.** Apple says so explicitly.
   Throttle's CI builds `ThrottleVision` for the visionOS **Simulator** with
   `CODE_SIGNING_ALLOWED=NO` (`.github/workflows/ci.yml:101-127`), so none of Part A is
   currently proven on the repo's own evidence — it is proven from Apple's documentation.
3. **App Review precedent is better than expected**, and the risk surface is *local code
   execution* (2.5.2), never *remote control*. Details in A.4.

---

## A.1 Permissions and entitlements, case by case

### The canonical source

**TN3179 — Understanding local network privacy** is the authority, and it explicitly
replaced the old forum FAQ.
<https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy>

Revision history, verbatim from the page:

- **2026-02-17** — "Updated the macOS considerations section to explain how to configure
  local network privacy on specific networks (r. 161891509). Moved version-specific
  information into the Historical considerations section."
- **2025-07-18** — added FB14321888 / FB16131937 information; macOS code-signing section.
- **2024-10-31** — "Rewritten and republished as TN3179."
- **2020-10-16** — "First posted as the Local Network Privacy FAQ on the Apple Developer Forums."

Platform table, verbatim:

| Platform | Supported | Introduced |
| --- | --- | --- |
| iOS | yes | iOS 14 |
| iPadOS | yes | iPadOS 14 |
| macOS | yes | **macOS 15** |
| tvOS | no | — |
| **visionOS** | **yes** | **visionOS 1** |
| watchOS | no | — |

And the sentence that makes every iOS rule below a visionOS rule:

> "Local network privacy works the same on iOS, iPadOS, and visionOS. Unless otherwise
> noted, assume that any info about iOS applies to all three platforms."

### The definition that settles the Tailscale question

TN3179 § *Local network operations*, verbatim:

> "A local network is an IP network associated with a broadcast-capable network interface.
> **Such interfaces include Wi-Fi and Ethernet, but not cellular (WWAN) or VPN.** A local
> network address is any address on a local network. Traffic to a local network address
> goes directly; it's not forwarded by a router."
>
> "In addition, all multicast addresses (224.0.0.0/4, ff00::/8) and the IPv4 broadcast
> address (255.255.255.255) are local network addresses."

Operations table, verbatim:

| Operation | Requires local network access |
| --- | --- |
| Making an outgoing TCP connection | **yes** |
| Listening for and accepting incoming TCP connections | **no** |
| Sending a UDP unicast | yes |
| Sending a UDP multicast | yes |
| Sending a UDP broadcast | yes |
| Connecting a UDP socket | yes |
| Receiving an incoming UDP unicast | **no** |
| Receiving an incoming UDP multicast | yes |
| Receiving an incoming UDP broadcast | yes |

> "The system implements these TCP and UDP checks **deep in the networking stack**, and
> thus they apply to **all** networking APIs. This includes Network framework, BSD
> Sockets, URL Loading System, and any APIs implemented on top of those."

There is no dodging the prompt by dropping to BSD sockets.

### What the multicast entitlement actually gates

TN3179 § *Multicast operations*, verbatim:

> "Sending or receiving multicast or broadcast traffic is a local network operation on all
> platforms… **However, iOS puts additional restrictions on these operations.** To send or
> receive multicast or broadcast traffic, sign your app with the
> `com.apple.developer.networking.multicast` entitlement."

| Operation | Multicast entitlement required |
| --- | --- |
| Sending a UDP unicast | **no** |
| Sending a UDP multicast | yes |
| Sending a UDP broadcast | yes |
| Receiving an incoming UDP unicast | **no** |
| Receiving an incoming UDP multicast | yes |
| Receiving an incoming UDP broadcast | yes |
| **Working with arbitrary Bonjour service types** | **yes** |
| **Browsing for all advertised service types** (`_services._dns-sd._udp.local.`) | **yes** |

**There is no TCP row in the multicast table at all.** TCP never requires it. Also
verbatim from TN3179 § Essentials: *"The multicast entitlement isn't required on macOS."*

From the entitlement page itself
(<https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast>),
verbatim Discussion:

> "Your app must have this entitlement to send or receive IP multicast or broadcast on
> iOS. It also allows your app to browse and advertise **arbitrary** Bonjour service types.
> This entitlement **requires permission from Apple** before you can use it in your app."

Platform availability on that page: **iOS 14.0, iPadOS 14.0, visionOS 1.0**. macOS, tvOS
and watchOS are absent — consistent with "not required on macOS". So **visionOS is not
exempt**: if you needed multicast on Vision Pro you would need the approval. You don't.

### (a) NWBrowser for a Bonjour service, then NWConnection

- **Multicast entitlement: NOT REQUIRED.** VERIFIED. Browsing one *declared, specific*
  service type is neither "arbitrary Bonjour service types" nor "browsing for all
  advertised service types" — the only two Bonjour rows in the multicast table. You
  declare the type in `NSBonjourServices` instead.
- **Local Network prompt: YES.** VERIFIED. TN3179 § *Bonjour operations*: **"All Bonjour
  operations require local network access."** (register, browse and resolve are all
  `yes`.) The subsequent TCP connect would trigger it independently anyway.
- Required Info.plist keys: `NSLocalNetworkUsageDescription` **and** `NSBonjourServices`
  containing `_throttle._tcp`.

**Apple ships a first-party sample doing exactly this architecture with no multicast
entitlement:** *Connecting iPadOS and visionOS apps over the local network* (visionOS 26.0),
<https://developer.apple.com/documentation/visionos/connecting-ipados-and-visionos-apps-over-the-local-network>.
Verbatim:

> "The sample connects the two devices over the local network using Bonjour, by adding the
> `Local Network` capability in the project's Info pane in Xcode. The app defines a service
> type of `_example._udp` to uniquely identify the app and adds it to the Info pane with
> the `NSBonjourServices` key."

The visionOS target in that sample is the browsing client — the same role Throttle's
`PeerConnector` plays. This is as close to a blessed reference architecture as exists.

### (b) Plain TCP to a known LAN address

- **Multicast entitlement: NOT REQUIRED.** VERIFIED (TCP appears nowhere in the table).
- **Local Network prompt: YES.** VERIFIED — "Making an outgoing TCP connection → yes".
  Skipping discovery does **not** skip the prompt. TN3179 warns explicitly: *"If your app
  allows people to enter an arbitrary network address, consider what happens if they enter
  a local network address."*
- `NSLocalNetworkUsageDescription` still required; `NSBonjourServices` not, if you never
  use Bonjour.

### (c) TCP to a 100.64.0.0/10 Tailscale address

- **Multicast entitlement: NOT REQUIRED.** VERIFIED (TCP unicast).
- **Local Network prompt: NO.** *Verified definition, inferred application.* TN3179's own
  definition excludes VPN interfaces: *"Such interfaces include Wi-Fi and Ethernet, but not
  cellular (WWAN) or VPN."* A Tailscale peer at 100.64/10 is reached over a `utun`
  interface owned by a `NEPacketTunnelProvider`, i.e. a VPN interface — therefore not a
  local network, therefore not a local network address, therefore the connect is not a
  local network operation. Two independent reinforcements: 100.64/10 is not on the Wi-Fi
  subnet, and traffic to it does not "go directly" in the LAN sense.
  - **Labelled INFERENCE because** Apple nowhere writes the sentence "CGNAT/Tailscale
    addresses do not prompt". The chain is built from two verified Apple statements. No
    forum thread stating it outright was found.
- **Does it work over a `NEPacketTunnelProvider` installed by another app?** INFERENCE,
  high confidence. Verified components: `NEPacketTunnelProvider`, `NETunnelProviderManager`
  and the `com.apple.developer.networking.networkextension` entitlement are all **visionOS
  1.0+**. A system VPN captures traffic app-agnostically; your app needs no entitlement to
  *use* someone else's tunnel. Relevant and verified, TN3179 § *App extension
  considerations*: *"Network Extension packet tunnel provider, app proxy provider, and DNS
  proxy provider app extensions have local network access regardless of the Local Network
  privilege state of their container app."* — Tailscale's own extension is never blocked by
  your app's privilege state.
  - **UNVERIFIED GAP:** no source, Apple's or Tailscale's, confirming a shipping Tailscale
    build for visionOS. Treat "Tailscale runs on Vision Pro" as an assumption to test on
    device, not a documented fact. **This is the single most load-bearing unverified item
    in Part A.**

### Consequence for the design

Case (c) is the only one of the three that avoids the prompt entirely. If everything were
routed over Tailscale — including on-LAN sessions, via Tailscale's own direct path — the
app could plausibly ship with **no Local Network prompt and no multicast entitlement at
all**. That is genuinely attractive under the no-entitlements constraint, and it is worth
measuring on device before committing to the Bonjour path as primary.

### Is the multicast request form still open?

- **VERIFIED (tested 2026-09-09):** `https://developer.apple.com/contact/request/networking-multicast`
  returns **HTTP 302 → `idmsa.apple.com` sign-in with the path preserved**. Control test: a
  bogus path under `/contact/request/` redirects to a generic `/contact/` instead. So the
  form **exists and is live**, merely auth-gated.
- **VERIFIED**, Apple account help —
  <https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities>:
  > "This new workflow supports automatic signing and Xcode Cloud workflows by default for
  > features such as CarPlay and **multicast networking**."
  > "**Managed capabilities require approval from Apple to use.**"
- **UNVERIFIED:** Apple publishes no approval criteria, no turnaround, and no statement on
  whether individual (non-organization) memberships are eligible. Anecdotal rejection
  reports exist; none are cited here because no primary thread could be opened.
  **Plan as if you will not get it** — which costs nothing, since none of the three cases
  need it.

### Does the prompt exist on visionOS specifically?

**VERIFIED — yes, since visionOS 1.0**, on three independent Apple sources:

1. TN3179 platform table: visionOS / yes / visionOS 1.
2. `NSLocalNetworkUsageDescription` platform metadata: iOS 14.0, iPadOS 14.0, macOS 11.0,
   tvOS 14.0, **visionOS 1.0** —
   <https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription>
3. `NSBonjourServices` platform metadata: same list including **visionOS 1.0**.

Note the apparent contradiction: the *plist key* is annotated macOS 11.0 and tvOS 14.0,
but TN3179 says macOS **enforcement** arrived in macOS 15 and tvOS is not supported at all.
The availability annotation reflects when the key was *defined*, not when the privilege was
*enforced*. Trust TN3179 for enforcement.

Two visionOS-relevant gotchas inherited from the iOS rules (both verbatim, TN3179 § iOS
considerations, which explicitly governs visionOS):

- **"The simulator doesn't support local network privacy. Test your local network privacy
  behavior on a real device."**
- **"If an iOS app is in the background and performs a local network operation while its
  Local Network privilege is undetermined, the system denies that operation without
  presenting the local network alert. The system doesn't record that decision."**

The second combines badly with A.2: a first connection attempted while the headset is off
is **silently denied**, with no prompt and no persisted state.

### Detecting denial

TN3179 § *Check for local network access*, verbatim:

> "There's no general API that returns whether the current process has local network access
> (FB8711182)."

Two supported techniques:

- **Bonjour / `NWBrowser`:** watch `stateUpdateHandler` for `.waiting(.dns(code))` where
  `Int(code) == kDNSServiceErr_PolicyDenied` (**-65570**).
- **TCP / `NWConnection`:** the connection enters `.waiting(_)` and
  `connection.currentPath?.unsatisfiedReason == .localNetworkDenied`.

Also verbatim:

> "If the user subsequently changes the Local Network privilege to grant your program local
> network access, **the system automatically retries the connection**."
> "If your program successfully made a TCP connection to a local network address and then
> the user changed the Local Network privilege to deny it local network access, **the
> connection closes**."

Design guidance, verbatim: because the OS may deny the operation *before* the user answers,
*"use an API that supports waiting for connectivity, like Network framework… If you can't
use one of these preferred APIs, add appropriate retry logic."*

There is no API to proactively raise the alert, but TN3179 documents a sanctioned
workaround: *"One approach that works well is to **connect a UDP socket to a local network
address**. This triggers the local network alert without generating any network traffic."*
Apple ships the full `triggerLocalNetworkPrivacyAlert()` sample in the technote. Connecting
a UDP socket is a *unicast* operation — no multicast entitlement.

### The macOS side of the link

Throttle's Mac app both **advertises** Bonjour (`PeerAdvertiser`) and **accepts** TCP.
TN3179 splits those cleanly:

- **"Listening for and accepting incoming TCP connections → no"** and "Receiving an
  incoming UDP unicast → no". **A Mac app that only listens and accepts needs no local
  network access at all.**
- But **"Registering a service with Bonjour → yes"**. Advertising `_throttle._tcp` alone
  triggers the prompt on **macOS 15+**.

Other macOS specifics worth designing around, all verbatim from TN3179:

- macOS auto-allows *"Any daemon started by `launchd`; Any program running as root;
  Command-line tools run from Terminal or over SSH, including any child processes they
  spawn"* — and **"The exception for `launchd` daemons doesn't apply to `launchd` agents."**
- State is **per user account**, and there is **no way to reset** a program's privilege to
  undetermined (FB14944392). Apple's own suggested workarounds are a VM snapshot or a fresh
  user account. Plan QA accordingly.
- Responsible code: *"if your app spawns a helper tool and the helper tool performs a local
  network operation, macOS considers the app to be the responsible code."* For a `launchd`
  agent not installed via `SMAppService`, set `AssociatedBundleIdentifiers`.
- Code signing: *"Local network privacy tracks the identity of your program using its code
  signature… To ensure that local network privacy reliably tracks the identity of your
  macOS program, **sign it with an Apple-issued code-signing identity**."* Throttle's
  Developer ID signing satisfies this.
- CI/dev escape hatch (macOS 15.5+): `AllowedEthernetLocalNetworkAddresses` /
  `AllowedWiFiLocalNetworkAddresses` in the `com.apple.network.local-network` domain, CIDR
  string arrays, set with `sudo`, **requires a restart**.
- Known bugs: macOS 15.1 fixed a batch of local-network bugs; FB16131937 — macOS fails to
  show the alert for very short-lived processes; FB14321888 — an iOS 18 state-desync bug
  fixed in iOS 18.6.

Supporting DTS evidence: <https://developer.apple.com/forums/thread/763753> — "Local Network
permission prompt for daemon on macOS 15", Quinn / DTS Engineer, Nov 2024: *"We believe this
is fixed in macOS 15.1."* And on the daemon-vs-agent distinction: *"A daemon running as root
can access the local network just fine. An agent running in the GUI login session can access
the local network subject to user approval. You're running as a daemon but pretending to be
a user. The system is not set up for that because it's not a supported configuration."*

---

## A.2 Background, focus, and the unworn transition

Blunt framing: **Apple has published very little here.** A.1 is almost entirely
primary-source. A.2 is thin, and every weak link is labelled.

### The most useful sentence found

**VERIFIED — Apple DTS, May 2025.** <https://developer.apple.com/forums/thread/783056>,
Quinn "The Eskimo!" @ Developer Technical Support @ Apple, verbatim:

> "I'm not aware of any specific limitations with this on visionOS. My experience is that,
> **when it comes to networking, visionOS tends to behave very much like an iPad**, so
> that's the sort of behaviour I'd expect to see here.
>
> However, background downloads are a case where it's important that you do real world
> testing. The system has complex infrastructure for deciding when to run a background
> download. That infrastructure accepts a whole bunch of inputs, and the results can change
> between platforms, OS versions, and even on specific devices."

Default mental model: **iPadOS, including iOS-style suspension.** Note this is a DTS
engineer's *expectation* ("I'm not aware of", "I'd expect"), not a spec guarantee.

### Headset removed (unworn)

**VERIFIED — Apple Staff, June 2025.** <https://developer.apple.com/forums/thread/790713>
— "Background Assets in VisionOS". The original poster asked precisely this question. Reply
from a **Frameworks Engineer (Apple Staff)**, verbatim:

> "Hello! Yes, Background Assets can download files **while Apple Vision Pro isn't being
> worn** as long as **the user has unlocked the device at least once since it was last
> restarted**. Keep in mind that when the downloads actually take place depends on several
> different factors, such as current network conditions. If you're seeing that your
> downloads are being paused when the user takes off Apple Vision Pro and are not
> subsequently resumed until the user puts it back on, then please file a feedback report…"

What this establishes: the device does not fully halt system-mediated networking when
unworn, and there is a **first-unlock gate** after restart (data-protection semantics).

What it does **not** establish: anything about a *live app-owned socket*. Background Assets
and background `URLSession` are **system-daemon-mediated** transfers that survive app
suspension by design. An `NWConnection` is not.

**COMMUNITY REPORT — not Apple, and only partially retrieved.** StackOverflow #77989399,
"How can I programmatically prevent an app from going to the background when the [Vision
Pro is removed]", states *"when the user takes off the Apple Vision Pro device, the
application goes into the background."*
<https://stackoverflow.com/questions/77989399/how-can-i-programmatically-prevent-an-app-from-going-to-the-background-when-the>
— **Honesty flag: Cloudflare blocked retrieval; only the question text is available via a
search snippet. The answers were not read.** One unverified community datapoint, reported
only because its direction agrees with the Apple Staff reply and the iPad model.

**UNVERIFIED GAP.** No Apple documentation, no WWDC session, and no DTS forum reply states
what happens to an **open TCP socket** when the headset is removed. Searches covered
"socket disconnects when headset removed", "not being worn", "takes off the headset" scoped
to the developer forums, plus visionOS lifecycle phrasings. Nothing. There is also **no
public wearing-detection API** for third-party apps in the visionOS documentation index.

**INFERENCE (state it as such in design docs):** unworn ⇒ scene backgrounded ⇒ iOS/iPadOS
suspension rules ⇒ the app stops executing ⇒ the `NWConnection` is not serviced and is torn
down by the peer's timeout or by the system. **Design for reconnect, not for persistence.**
Ship nothing whose correctness depends on the socket surviving the headset coming off.

### Focus, Shared Space vs Full Space

**VERIFIED — `ScenePhase` semantics, from an Apple engineer.**
<https://developer.apple.com/forums/thread/757429> — "Scene Phase issue with VisionOS 2.0",
responder labelled **Engineer (Apple)**, June 2024, verbatim:

> "Where you place your `scenePhase` environment variable matters—not the `onChange`.
> - If you grab it from within your `App`, you will get an **aggregate** phase for all your
>   scenes—this should become 'background' only if **all** scenes have been backgrounded.
> - However, grabbing it in a `View` will give the phase for **that view's scene only**."

Directly relevant: a socket owned at `App` level watching `@Environment(\.scenePhase)` sees
the **aggregate** — it will *not* see a phase change when one window loses focus.

**VERIFIED — scene lifecycle on window close.**
<https://developer.apple.com/documentation/visionos/handling-the-window-life-cycle-with-multiple-scenes>
(visionOS 26.0), verbatim:

> "When a person closes a window in visionOS, the system **backgrounds** that scene. When
> another nonimmersive scene of the application is open, the system also **immediately
> eliminates** the backgrounded scene. The last closed nonimmersive scene enters the
> `background` phase but doesn't immediately receive the `onDisappear` callback."

**VERIFIED — an immersive space does not hide your own windows.**
<https://developer.apple.com/documentation/swiftui/immersivespace> (visionOS 1.0):
*"For any style of immersion, **the other parts of your app's interface — namely its
windows — remain visible.**"*

**VERIFIED — but it does hide other apps'.** Apple Q&A "Building apps for visionOS",
published **2024-01-11**, <https://developer.apple.com/news/?id=prl6dp5r>: *"Windows and
volumes from other apps the user has opened are hidden when an immersive space is open."*

**VERIFIED** general warning, <https://developer.apple.com/documentation/swiftui/scenephase>:
*"When an app enters the `background` phase, **expect the app to terminate soon after**."*

**UNVERIFIED GAPS.** Nothing from Apple on gaze — no documentation that "the user looks
away" produces any lifecycle transition, and no API surfacing it. *INFERENCE: looking away
is not a lifecycle event; do not build on it.* Likewise no Apple statement on whether an
unfocused-but-visible Shared Space window leaves `active`; the visionOS 26 window-lifecycle
doc ties backgrounding to *closing*, not defocusing. *INFERENCE: a visible-but-unfocused
window stays `active`.*

### Background modes on visionOS — the definitive table

**VERIFIED.** `UIBackgroundModes` platform metadata: iOS 4.0, iPadOS 4.0, **visionOS 1.0**,
watchOS 4.0 —
<https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes>.
So `UIBackgroundModes` **is** supported on visionOS. Per-platform values from
<https://developer.apple.com/documentation/xcode/configuring-background-execution-modes>:

| Mode | Value | visionOS? |
| --- | --- | --- |
| Audio, AirPlay, Picture in Picture | `audio` | **YES** |
| **Voice over IP** | `voip` | **YES** |
| Uses Bluetooth LE accessories | `bluetooth-central` | **YES** |
| Screen Capture | `screen-capture` | **YES** |
| **Background fetch** | `fetch` | **YES** |
| **Remote notifications** | `remote-notification` | **YES** |
| **Background processing** | `processing` | **YES** |
| Location updates | `location` | NO |
| External accessory communication | `external-accessory` | NO |
| Acts as a Bluetooth LE accessory | `bluetooth-peripheral` | NO |
| Uses Nearby Interaction | `nearby-interaction` | NO |
| Push to Talk | `push-to-talk` | NO |
| Workout processing | `workout-processing` | watchOS only |

Also verbatim from that page: *"Typically, an app is in a suspended state when it's in the
background."* and *"The Background Modes capability isn't available for macOS apps."*
`BGTaskScheduler` is **visionOS 1.0+**.

Directly answering the question: **background processing YES, VoIP YES, background audio
YES, background fetch YES.**

### NEAppPushProvider

**VERIFIED — the API exists on visionOS:** `NEAppPushProvider` and `NEAppPushManager` are
both **visionOS 1.0+**, as is `com.apple.developer.networking.networkextension` with
`app-push-provider` a documented value.

**But it is almost certainly out of reach. INFERENCE, well-grounded:** Apple's account help
says *"Managed capabilities require approval from Apple to use"*, and the
`https://developer.apple.com/contact/request/local-push-connectivity` request form is live
(302 → auth, path preserved; verified against the same bogus-path control). Separately,
Local Push Connectivity is designed for **enterprise on-premises deployments on a specific
Wi-Fi network**, not consumer Mac-companion apps — even if granted it would be an awkward
fit. **UNVERIFIED:** no Apple sentence explicitly says `app-push-provider` requires
approval, and no statement on individual-membership eligibility was found.

**Treat `NEAppPushProvider` as unavailable**, same bucket as the multicast entitlement.

### NWConnection keep-alive and socket suspension

- **VERIFIED:** `NWConnection` and `NWParameters.includePeerToPeer` are both **visionOS 1.0+**.
- **VERIFIED (TN3179):** an established TCP connection to a local-network address is
  **closed by the system** if the user revokes the Local Network privilege. That is a
  disconnect cause distinct from backgrounding and must be handled.
- **UNVERIFIED GAP:** no Apple documentation on `NWConnection` keep-alive *specific to
  visionOS*, and no visionOS-specific statement about socket suspension on background.
- **INFERENCE** (leaning on Quinn's "very much like an iPad"): visionOS applies iOS-style
  suspension. The socket is not "suspended" as such — *the process stops being scheduled*,
  so nothing reads or writes it, and it dies by timeout. The supported ways to keep
  networking alive across suspension are the iOS three: background `URLSession`, a declared
  `UIBackgroundMode` that keeps you running (`audio` / `voip`), or `BGTaskScheduler`
  windows. **Not a bare `NWConnection`.**

---

## A.3 App Group and CloudKit sharing across macOS, iOS and visionOS

**Verdict: no blocker.** A visionOS target can join the same registered App Group and the
same CloudKit container as the existing macOS and iOS apps.

### App Groups — VERIFIED, with one macOS string caveat

| Evidence | Source |
| --- | --- |
| "You need to register app groups for iOS, iPadOS, tvOS, **visionOS**, and watchOS apps." | [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups) |
| visionOS provisioning profiles support the **App groups** capability | [Supported capabilities (visionOS)](https://developer.apple.com/help/account/reference/supported-capabilities-visionos) |
| `containerURL(forSecurityApplicationGroupIdentifier:)` includes **visionOS 1.0+** | [FileManager doc](https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)) |
| `com.apple.security.application-groups` entitlement page availability: iOS 3.0+, iPadOS 3.0+, macOS 10.7+, tvOS 9.0+, watchOS 2.0+ — **visionOS NOT listed** | [App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) |

**Documentation conflict, unresolved.** The entitlement page omits visionOS while the Xcode
guide, the capability matrix and the container API all include it. *INFERENCE: the
entitlement page's availability list is stale.* Do not read the omission as a prohibition;
it is worth a one-line Feedback Assistant report.

**The macOS prefix quirk is real.** Verbatim from the App Groups entitlement page:

> Format the identifier as follows: `group.<group name>` … **In macOS**, you can also
> create app groups or add apps to existing app groups using this identifier format:
> `<team identifier>.<group name>`. You don't need to register app groups that use this
> format on the Apple Developer website.

And verbatim from `containerURL(forSecurityApplicationGroupIdentifier:)`:

> **App Groups in macOS** — For a sandboxed app in macOS, the group directory is located at
> `~/Library/Group Containers/<application-group-id>`, where the application group
> identifier **begins with the developer's team identifier followed by a dot**, followed by
> the specific group name.
> **App Groups in iOS** — In iOS, the group identifier **starts with the word `group` and a
> dot**, followed by the group name.

**Conclusion: visionOS follows the iOS convention** — one registered `group.com.example.foo`.
macOS resolves the same registered group under a **team-identifier prefix**. The
`$(TeamIdentifierPrefix)` build-setting spelling is common Xcode practice; Apple documents
the *shape* but not that variable name (INFERENCE on the literal form, VERIFIED on the
prefix requirement).

Note also: an App Group is a *local* shared container, IPC and keychain-group mechanism. It
does **not** sync between devices. Cross-device sharing is CloudKit's job.

### CloudKit on visionOS — VERIFIED, all green

Platform annotations from Apple's documentation metadata:

| API | Availability |
| --- | --- |
| CloudKit framework | iOS 8.0+, macOS 10.10+, tvOS 9.0+, **visionOS 1.0+**, watchOS 3.0+ |
| CKSyncEngine | iOS 17.0+, macOS 14.0+, tvOS 17.0+, **visionOS 1.0+**, watchOS 10.0+ |
| NSPersistentCloudKitContainer | iOS 13.0+, macOS 10.15+, tvOS 13.0+, **visionOS 1.0+**, watchOS 6.0+ |
| CKSubscription | iOS 8.0+, macOS 10.10+, **visionOS 1.0+**, watchOS 3.0+, tvOS **not** supported |
| CKDatabaseSubscription | iOS 10.0+, macOS 10.12+, tvOS 10.0+, **visionOS 1.0+**, watchOS 6.0+ |
| CKRecordZoneSubscription | iOS 10.0+, macOS 10.12+, **visionOS 1.0+**, watchOS 6.0+ |

**Same container across platforms — VERIFIED.** Nothing platform-scopes a CloudKit
container; `com.apple.developer.icloud-container-identifiers` and
`com.apple.developer.icloud-services` both carry **visionOS 1.0+**. A container is bound to
the app/team, not the OS.

**visionOS-specific CloudKit limits: NONE FOUND.** The only platform exclusion anywhere
above is tvOS for `CKSubscription`. Two universal (not visionOS-specific) constraints,
verbatim: *"Only private and shared databases support database subscriptions"* and *"Don't
use CKSyncEngine to sync your app's public database."*

### Push and background notifications — VERIFIED

`aps-environment`, `registerForRemoteNotifications()`, the User Notifications framework and
the `remote-notification` / `fetch` / `processing` background modes are **all visionOS 1.0+**.
Silent push, background fetch and `BGTaskScheduler` all port over unchanged. **No documented
visionOS-specific push limit found.**

**One anomaly to note but not act on:** the visionOS row of Apple's
[capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-visionos)
does **not** list Push notifications, Background modes, or Keychain sharing — all
contradicted by the API and entitlement docs above. *INFERENCE: these are App-ID-level app
services rather than provisioning-profile capabilities on visionOS, or the matrix is
incomplete.*

### Portal flow and keychain

- Same as iOS: Signing & Capabilities → iCloud → CloudKit. Verbatim: *"Xcode automatically
  adds the Push Notifications capability to your target if you enable the CloudKit service
  because CloudKit uses push notifications."* And: *"If you later remove the iCloud
  capability in Xcode, you must manually update your App ID's configuration in your
  developer account to disable iCloud."*
- App Groups **must be registered** in the portal for visionOS (unlike macOS's unregistered
  `<teamID>.<name>` form). Maximum **1,000 app groups per account**.
- `kSecAttrAccessGroup` and `keychain-access-groups` are both **visionOS 1.0+**; no
  visionOS-specific keychain difference found. The real asymmetry is macOS — verbatim,
  `kSecAttrAccessGroup`: *"**Important:** This attribute applies to macOS keychain items
  **only if you also set a value of `true` for the `kSecUseDataProtectionKeychain` key**,
  the `kSecAttrSynchronizable` key, or both."* For one shared keychain group across Mac +
  iPhone + Vision Pro, the **macOS** side must opt into the data-protection keychain.
  Verbatim: *"App groups that you register in your Apple Developer profile also act as
  keychain access groups."*

### Repo cross-check (observed, 2026-09-09)

Throttle's `ThrottleVision` target is already configured consistently with everything above:

- `ThrottleVision/ThrottleVision.entitlements` declares `iCloud.com.lorislab.throttle`,
  CloudKit, `group.com.lorislab.throttle` and `aps-environment` — **and no multicast
  entitlement.** Correct.
- `project.yml` already declares `NSLocalNetworkUsageDescription`, `NSBonjourServices:
  [_throttle._tcp]` and `UIBackgroundModes: [remote-notification]` for the vision target.
  Correct and complete for case (a).
- **One item to verify, not a confirmed defect:** `Throttle/Throttle.entitlements` (the Mac
  target) uses the bare string `group.com.lorislab.throttle`, and the same bare string is
  hard-coded in `ThrottleWidget/ThrottleWidget.swift:26`,
  `Throttle/Intents/ThrottleIntents.swift:34` and
  `ThrottleShared/Sources/ThrottleShared/CloudKitSchema.swift:32`. Apple's
  `containerURL(forSecurityApplicationGroupIdentifier:)` documentation says the macOS group
  directory identifier "begins with the developer's team identifier followed by a dot",
  and states that specifically for a **sandboxed** Mac app. The Throttle Mac target has no
  `com.apple.security.app-sandbox` key, so the documented sandbox precondition does not
  apply and the current arrangement may be entirely correct. Flagged only because the doc
  wording is ambiguous for the non-sandboxed case; confirm at runtime that
  `containerURL(...)` returns non-nil on macOS before assuming parity.

---

## A.4 App Review precedent for remote terminals and remote control

**Verdict: no blocker, and the precedent is stronger than expected.** The enforcement risk
in this category is **local code execution**, never **remote control**.

### The guidelines

Page: <https://developer.apple.com/app-store/review/guidelines/> — footer reads
**"Last Updated: June 8, 2026"** (verbatim, fetched 2026-09-09).

**Correction: the remote-desktop carve-out is 4.2.7, not 4.7.** Verbatim:

> **4.2.7 Remote Desktop Clients:** If your remote desktop app acts as a mirror of specific
> software or services rather than a generic mirror of the host device, it must comply with
> the following:
> (a) The app must only connect to a user-owned host device that is a personal computer or
> dedicated game console owned by the user, and both the host device and client must be
> connected on a local and LAN-based network.
> (b) Any software or services appearing in the client are fully executed on the host
> device, rendered on the screen of the host device, and may not use APIs or platform
> features beyond what is required to stream the Remote Desktop.
> (c) All account creation and management must be initiated from the host device.
> (d) The UI appearing on the client does not resemble an iOS or App Store view, does not
> provide a store-like interface, or include the ability to browse, select, or purchase
> software not already owned or licensed by the user. …
> (e) Thin clients for cloud-based apps are not appropriate for the App Store.

**Read the conditional carefully.** The (a)–(e) constraints — including the LAN-only clause
— bind *only* apps that mirror **specific software or services** rather than acting as a
**generic mirror of the host device**. A generic desktop or terminal mirror falls outside
the conditional. That is precisely why Jump Desktop, Screens, TeamViewer and SSH clients
operate over the internet unchallenged, while a "stream this one game from the cloud"
client gets caught. A Mac terminal/cockpit mirror is a generic host mirror.

**2.5.2, current text, verbatim:**

> Apps should be self-contained in their bundles, and may not read or write data outside
> the designated container area, nor may they download, install, or execute code which
> introduces or changes features or functionality of the app, including other apps.
> Educational apps designed to teach, develop, or allow students to test executable code
> may, in limited circumstances, download code provided that such code is not used for
> other purposes. Such apps must make the source code provided by the app completely
> viewable and editable by the user.

**VERIFIED NEGATIVE:** the word **"interpreted" does not appear anywhere in the current
guidelines**. Neither do "terminal", "SSH", "virtual machine", or "developer tool". The
"interpreted code" phrasing people remember is historical. **UNVERIFIED** when it was
reworded — no archive access.

**4.7** ("Mini apps, mini games, streaming games, chatbots, plug-ins, and game emulators")
governs software your app *offers to others*. It does **not** govern a terminal or a
remote-control client.

**Notarization scope**, parsed from the page's ASR/NR key icons:

| Guideline | Applies to Notarization Review (EU alt. marketplaces / Web Distribution)? |
| --- | --- |
| 2.5.1, **2.5.2**, 2.5.6 | **Yes** — ASR & NR |
| **4.7, 4.7.2, 4.7.3, 4.7.5** | **Yes** — ASR & NR |
| **4.2.7 (Remote Desktop)** | **No** — App Store Review only |

So 2.5.2 follows you even outside the App Store; 4.2.7 does not.

### What actually ships — native visionOS, CONFIRMED

Method: each app's live `apps.apple.com` page was fetched and the `appPlatforms` array
bound to **that app's own adamId** was read (neighbouring apps on the same page carry their
own arrays; a naive regex produces false positives, one of which was caught and corrected
for Termius). `"vision"` present = native visionOS listing.

| App | Seller | Bundle ID | Platforms | Listing |
| --- | --- | --- | --- | --- |
| **Prompt 3** (SSH) | Panic, Inc. | `com.panic.prompt.3` | mac, phone, **vision**, pad | [id1594420480](https://apps.apple.com/us/app/prompt-3/id1594420480) |
| **La Terminal: Mosh & SSH Client** | Xibbon, Inc | `com.xibbon.LaTerminal` | phone, **vision**, pad | [id1629902861](https://apps.apple.com/us/app/id1629902861) |
| **Screens 5: VNC Remote Desktop** | Edovia Inc. | `com.edovia.screens.5` | mac, phone, **vision**, pad | [id1663047912](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912) |
| **UTM SE: Retro PC emulator** | — | `com.utmapp.UTM-SE` | phone, **vision**, pad | [id1564628856](https://apps.apple.com/us/app/utm-se-retro-pc-emulator/id1564628856) |
| **Steam Link** | Valve | `com.valvesoftware.SteamLink17` | mac, tv, phone, **vision**, pad | [id1246969117](https://apps.apple.com/us/app/steam-link/id1246969117) |

**This is the headline finding.** A native visionOS **SSH terminal** ships from Panic — a
highly scrutinised, first-party-adjacent developer. A native visionOS **VNC remote-desktop
client** ships from Edovia. A native visionOS **x86 PC emulator** ships. The category is
not merely tolerated on visionOS; it is established.

**iPad/iPhone-compatible only on Vision Pro (no `"vision"`), CONFIRMED:** Termius
(`com.crystalnix.ServerAuditor`), Blink Shell (`sh.blink.blinkshell`), Secure ShellFish,
a-Shell (`AsheKube.app.a-Shell`), iSH Shell (`app.ish.iSH`), WebSSH, **Windows App Mobile**
(Microsoft, `com.microsoft.rdc.ios` — the renamed Microsoft Remote Desktop, same App Store
ID 714464092), Jump Desktop, Splashtop, TeamViewer, AnyDesk, RealVNC Viewer, Moonlight,
Parallels Client, Delta.

**Could NOT confirm — do not cite:** Chrome Remote Desktop on iOS (no such app found; a
direct `com.google.chromeremotedesktop` lookup returns zero results — **likely does not
exist**); Parallels Access (only the different *Parallels Client* exists); "Terminus" (the
real product is *Termius*).

### Documented rejections — all are code-execution cases

**iSH — 2020. Correction: it was never actually pulled.** Primary source, the developers'
own post, <https://ish.app/blog/app-store-removal>, dated **2020-11-08**:

> On Monday, **October 26th**, just four days after we launched iSH on the App Store, we
> received a call from Apple informing us that they had found our app noncompliant with
> **section 2.5.2** … and that they would remove the app from sale if we did not submit a
> satisfactory update within two weeks.

Apple's stated objection, verbatim: iSH *"is not self-contained and has remote package
updating functionality"*, with a suggestion to *"remove the remote network activity
functionality which could allow for remote code importing into the app, such as **wget or
curl**"*. The update banner on the same post:

> **Update:** We got a call this evening from someone who runs App Review. They apologized
> for the experience we had, then told us they've **accepted our appeal and won't be
> removing iSH from the store tomorrow.**

Corroborating dated HN index entries: [24860018](https://news.ycombinator.com/item?id=24860018)
(2020-10-22), [25028252](https://news.ycombinator.com/item?id=25028252) (2020-11-08),
[25033498](https://news.ycombinator.com/item?id=25033498) (2020-11-09).

**a-Shell — 2020. SECONDARY, partially verified.** Same enforcement wave, same week. HN
[25032008](https://news.ycombinator.com/item?id=25032008) "Apple requests to remove
WebAssembly support in a-Shell" (2020-11-09) and
[25095848](https://news.ycombinator.com/item?id=25095848) "a-Shell is staying in the App
Store" (2020-11-14). Both HN submissions verified live; the underlying tweet is not
fetchable — **content UNVERIFIED**.

**iDOS — the best-documented rejection in this category.** Primary source, the developer's
own dated log, <https://litchie.com/2024/04/new-hope>. Verbatim App Review language
includes, on **2024-06-15**: *"Got a call from Apple after 2 months. They have decided that
iDOS is not a retro game console, so the new rule is not applicable. They suggested I make
changes and resubmit for review, but when I asked what changes I should make to be
compliant, they had no idea, nor when I asked what a retro game console is."* And on
**2024-07-14**: *"The app still provides emulator functionality but is not emulating a retro
game console specifically."* Approved **2024-08-12** after the rule change
([The Verge](https://www.theverge.com/2024/8/12/24218754/apple-idos-3-app-store-pc-emulator-rule-change)).

**UTM SE — 2024. Correction: the sequence is the reverse of the common retelling.**

| Date | Event | Source |
| --- | --- | --- |
| 2024-04-05 | Apple's 4.7 update permits **retro game console** emulators | [Ars Technica](https://arstechnica.com/gadgets/2024/04/apple-now-allows-retro-game-emulators-on-its-app-store-but-with-big-caveats/) |
| **2024-06-09** | Apple rejects UTM SE — *"a PC is not a console"* — **and refuses notarization** for EU marketplaces, citing 4.7. UTM declines to contest: not *"worth fighting for"* | [9to5Mac](https://9to5mac.com/2024/06/09/apple-blocks-pc-emulator-utm-app-store/) |
| 2024-06-14 | Contemporaneous note that 4.7 was **not** annotated as a Notarization rule at the time | [mjtsai.com](https://mjtsai.com/blog/2024/06/14/utm-blocked-outside-app-store-via-notarization/) |
| **2024-07-13/14** | Apple **reverses** and approves UTM SE on the ordinary App Store. *"The app is now available for free for iOS, iPadOS, and visionOS."* | [The Verge](https://www.theverge.com/2024/7/13/24198015/apple-utm-se-pc-os-emulator-for-ios) |
| **2024-08-01** | Apple codifies it: *"Updated 4.7 to clarify that PC emulator apps can offer to download games. Added 4.7, 4.7.2, and 4.7.3 to Notarization."* | **PRIMARY:** [developer.apple.com/news/?id=ty0avr2s](https://developer.apple.com/news/?id=ty0avr2s) |

**No rejection of an SSH client, terminal emulator or remote-desktop client was found.**
Every documented case in this space is an emulator or interpreter case under 2.5.2 or 4.7.
That negative result is the actionable finding: the risk is *running code locally*, not
*controlling a remote machine*.

For Throttle specifically, the design already sits on the safe side of that line: the
visionOS/iOS client is a terminal surface onto a PTY that **executes entirely on the Mac**
(`docs/remote-terminal-design.md`), which is a generic host mirror, not local code
execution.

### Apple's Mac Virtual Display, and whether there is an API

**What it is — VERIFIED (primary).** <https://support.apple.com/en-us/118521> (article dated
**2026-04-13**): *"Mac Virtual Display lets you view your Mac screen on Apple Vision Pro,
and use your Mac trackpad or mouse to share the pointer between your Mac and Apple Vision
Pro."*

Requirements (VERIFIED): macOS 14+ for basic mode; **Apple silicon + macOS 15.2+ +
visionOS 2.2+** for Wide/Ultrawide; same Apple Account with 2FA; iCloud Keychain on;
Wi-Fi + Bluetooth within **10 m**; Handoff enabled; not Guest User.

**Multi-display — VERIFIED: still NOT supported.** Verbatim, same page: *"When your Mac has
multiple displays connected to it, Mac Virtual Display shows only the one that you've set
as the main display."* And *"Mac Virtual Display connects your Apple Vision Pro to only one
Mac at a time."*

*Discrepancy flagged, not resolved:* two independent reads of Apple's resolution figures
differ in units — one gives Standard up to 5120×2880 and Ultrawide 5120×1440, the other
gives Ultrawide 10240×2880 pixels. The most likely explanation is points vs pixels. The
`en-lamr` regional mirror of article 118521 also still says "4K" where `en-us` says "5K".
Use the qualitative claim ("32:9 ultrawide, roughly two 5K displays side by side") rather
than a specific number.

**Third-party API — VERIFIED: none exists.**

- **ScreenCaptureKit**: macOS 12.3+, but iOS/iPadOS/tvOS/**visionOS only from 27.0** (beta,
  unshipped) — and it captures the *local* device's content.
- **`RemoteImmersiveSpace`** (<https://developer.apple.com/documentation/swiftui/remoteimmersivespace>,
  **macOS 26.0+**, macOS-side only) is Apple's real Mac→Vision Pro streaming API, but scoped
  to *"compositor content that your macOS app presents on a user's chosen visionOS device"*
  — authored immersive/RealityKit content, **not desktop mirroring**.
- **DriverKit** lists no visionOS availability and documents no public virtual-display class.
  `documentation/coregraphics/cgvirtualdisplay` returns **HTTP 404** — CGVirtualDisplay is
  private/undocumented, not sanctioned.

**Conclusion:** a third party must build the whole pipeline itself — Mac-side capture
(ScreenCaptureKit), encode (VideoToolbox/AVFoundation), its own transport, and a custom
visionOS renderer. Exactly what Screens 5 and Jump Desktop do. Apple offers no shortcut.

**macOS TCC gate — VERIFIED.** ScreenCaptureKit docs: *"Request screen recording permission
from the person before capturing content… add a `NSScreenCaptureUsageDescription` key."*
Refusal is real and surfaced as
[`SCStreamError.Code.userDeclined`](https://developer.apple.com/documentation/screencapturekit/scstreamerror/code/userdeclined).
Note this matters only if Throttle ever streams the Mac *screen*; the current design streams
a **PTY octet stream**, which needs no screen-recording permission at all. That is a
meaningful architectural advantage worth preserving.

---

## A.5 Open items in Part A that could not be closed

1. Apple's stated approval criteria or turnaround for the multicast entitlement — form is
   auth-walled; no 2025–2026 primary statement found.
2. Whether individual (non-organization) memberships are eligible for managed capabilities.
3. **Any Apple statement on a live socket when the headset is removed** — nothing found;
   only the Background Assets adjacency.
4. Whether an unfocused-but-visible Shared Space window leaves `ScenePhase.active`.
5. **Confirmation that Tailscale ships a visionOS build** — not verified from any source.
6. The historical "interpreted code" wording of 2.5.2 (no archive access).
7. The exact resolution figures for Mac Virtual Display (points/pixels discrepancy).

Items 3, 4 and 5 are cheap to settle empirically on a device, and given how little Apple
documents here, on-device measurement is probably the only trustworthy route.

---

# PART B — Market reality for a paid visionOS developer tool in 2026

## Verdict

**Expected value as a standalone commercial product: negative. Expected value as a
near-zero-marginal-cost windowed slice of an existing codebase: slightly positive, and only
if it stays that way.**

The honest arithmetic, using only attributed figures:

- **Installed base:** IDC estimates ~**390,000 units shipped in 2024** and ~**45,000 in
  Q4 2025**. Apple has **never** published a unit figure. A cumulative launch-to-2026 total
  from a named firm **does not exist in public**.
- **Catalogue:** native apps peaked at Apple's own "**2,500**" (Tim Cook, August 2024) and
  fell to **1,782 still active** by December 2025 (Appfigures, via *Analytics India
  Magazine*, 2025-12-24). The catalogue is **shrinking**.
- **Best-documented independent outcome:** developer **Adam Roszyk**, **17 apps**, *"about
  **$4,000** on the App Store in the last three months"* (CNBC, 2025-02-21); his own later
  X post claims **$10k cumulative gross across 30 apps over two years** (single-source,
  unaudited).
- **Hardware gate rose:** $3,499 → **$3,699** on 2026-06-25.
- **Platform owner reallocated:** Bloomberg reported Apple **disbanded the Vision Products
  Group** in August 2026, and Ming-Chi Kuo reported the head-mounted roadmap cut from seven
  products to two, both glasses.
- **Survivorship:** of the 109 visionOS-exclusive apps **Apple itself still features**,
  **47% have not been updated in 12 months** and **33% have had no update since 2024**.

The case for **not doing it** is straightforward: on the best available numbers, a paid
niche developer tool on visionOS is competing for a few hundred thousand lifetime devices,
in a catalogue that is contracting, at a moment when the vendor has publicly moved its
people to a different product category. There is no revenue figure anywhere in public that
would justify a dedicated build.

The case for a **bounded** yes is narrower and specific to this repo: `ThrottleVision`
already exists (**194 lines across 4 Swift files**, added 2026-07-10, touched once since),
reuses `ThrottlePeer` wholesale, and is already in CI. Its marginal cost so far has been
close to zero. Kept as a windowed SwiftUI slice — never a spatial/immersive product — it is
a cheap optionality bet and a credible portfolio artifact. The moment it needs its own
UI language, its own QA loop, or a $3,699 device to test, the arithmetic flips.

**Recommendation: do not build a visionOS product. Keep the visionOS target, frozen at
windowed parity, and set an explicit kill condition.**

---

## B.5 The visionOS App Store and the installed base

### Has Apple ever published Vision Pro unit sales? No — confirmed.

Apple's earnings releases report revenue only, with no Vision Pro line item; verified
directly on the Q1 FY2026 release (January 2026), where the only figure is *"quarterly
revenue of $143.8 billion, up 16 percent year over year"*.
<https://www.apple.com/newsroom/2026/01/apple-reports-first-quarter-results/>
The Vision Pro product and spec pages carry no sales or installed-base claim. 9to5Mac states
it plainly: *"Since Apple doesn't release official sales numbers, it's hard to verify the
accuracy of these various reports."* (Ryan Christoffel, 2026-01-02).

Everything below is therefore third-party.

### Unit estimates — everything that could be attributed

| Figure | Firm / person | Type | Date | Source |
| --- | --- | --- | --- | --- |
| 160,000–180,000 units in the first three days of pre-orders | **Ming-Chi Kuo** | Named analyst | 2024-01-22 | Headline verified via news index (AppleInsider); body not fetched |
| ~200,000 pre-orders | MacRumors' own estimate from shipping-date slippage | **Publication estimate, not an analyst firm** | 2024-01-29 | Headline verified; re-reported by Business Insider 2024-01-30, UploadVR 2024-01-29 |
| Fewer than 100,000 units in **any single quarter** since launch; 75% drop in US sales; **under 500,000** in year one | **IDC** | Analyst firm | 2024-07-11 | <https://9to5mac.com/2024/07/11/us-vision-pro-sales/> |
| Shipment estimates cut from 800,000 to **400,000** for 2024 | "Analysts", unnamed | ⚠️ Weak attribution — unreliable | 2024-10-18 | <https://9to5mac.com/2024/10/18/cheaper-apple-vision-pro-developers/> |
| **390,000 units shipped in 2024** | **IDC** | Analyst firm | via 2026-01-02 | <https://www.macrumors.com/2026/01/02/vision-pro-still-failing-to-catch-on/> |
| **45,000 units in Q4 2025** (the M5 launch quarter) | **IDC**, cited in a **Financial Times** report | Analyst firm, reached second-hand | FT 2025-12-31; 9to5Mac 2026-01-02 | <https://9to5mac.com/2026/01/02/m5-vision-pro-launch-likely-made-minimal-sales-impact-report/> |
| Apple cut US+UK Vision Pro digital ad spend by **>95%** in 2025 | **Sensor Tower**, via the same FT report | Third-party data firm | 2025-12-31 | same |
| Broader VR headset market down **14%** YoY | **Counterpoint Research**, via the same FT report | Analyst firm (market-level) | 2025-12-31 | same |
| "~500,000 in the first year", "~1 million sold total" by Oct 2025 | **AppleInsider, in its own voice, no firm named** | ⚠️ Publication assertion | 2026-01-01 / 2025-11-05 | <https://appleinsider.com/articles/26/01/01/analysts-need-apple-vision-pro-to-be-a-flop-whether-apple-considers-it-one-or-not> |

**A clean cumulative unit total from a named firm for launch → 2026: NO RELIABLE FIGURE
FOUND.** The only cumulative numbers located are AppleInsider's round "~1 million",
repeated twice without a source. Do not use it as an estimate.

**On disagreement between estimates:** there are too few public datapoints to disagree. IDC
is effectively the only firm producing recurring public Vision Pro unit estimates, and it
publishes directional per-period statements rather than a running total. Its methodology,
per 9to5Mac's summary, is *"large-scale panels of both consumers and businesses, where
penetration rates… are scaled-up to match the US population"* — survey-panel extrapolation,
originally **US-only**, a different methodology class from Kuo's supply-chain checks and not
directly comparable.

Fair counterpoint worth carrying: AppleInsider (2026-01-01) argues analysts have no access
to Apple's own success criteria and that pass/fail framing on unit counts is *"arbitrary
and useless."*

### The M5 refresh

**Announced 2025-10-15, on sale 2025-10-22.** M5 chip; **10% more rendered pixels**; up to
**120Hz** (from 100Hz); 16-core Neural Engine; new Dual Knit Band; 256GB/512GB/1TB. Launch
price **$3,499, unchanged**. Apple's spec page today confirms *"Apple M5 chip"*, 10-core
CPU/GPU, R1 co-processor, 23 million pixels — <https://www.apple.com/apple-vision-pro/specs/>
(fetched 2026-09-09).
Corroboration: <https://9to5mac.com/2025/10/15/apple-vision-pro-gets-the-new-m5-chip-dual-knit-band/>
and Apple Newsroom, <https://www.apple.com/newsroom/2025/10/apple-vision-pro-upgraded-with-the-m5-chip-and-dual-knit-band/>.

**Did it move the needle? No, on the only measurement available.** IDC's 45,000-unit Q4 2025
estimate covers the M5 launch quarter. 9to5Mac's headline (2026-01-02) is literally *"M5
Vision Pro launch likely made minimal sales impact"*; AppleInsider's M5 review (2025-11-05)
is *"a chip can't fix developer relations"*.

### 2026 news: production cuts, roadmap, layoffs

- **2025-12-31 — FT: "Apple cuts Vision Pro production and marketing after weak sales."**
  Origin of the whole January 2026 news cycle (Guardian 2026-01-01, PCMag 2026-01-04, Yahoo
  Finance 2026-01-02, MacRumors 2026-01-02, The Register 2026-01-02). **The FT original is
  paywalled and was not read**; contents verified only through 9to5Mac and AppleInsider,
  both of which cite it.
- **2026-04-29 — MacRumors: "Apple Has Given Up on the Vision Pro After M5 Refresh Flop"**;
  Tom's Guide the same week. Headlines and dates verified; **bodies not fetched**.
- **2026-05-10 — Gurman/Bloomberg (via MacRumors):** no new Vision Pro-style device for
  "around two more years at least"; Vision Air cancelled in 2025; VPG members reassigned to
  smart glasses. **Paywalled primary, read second-hand.**
- **2026-06-03 — Ming-Chi Kuo, on X:** incoming CEO **John Ternus** signed off on cutting
  the head-mounted roadmap from **seven products to two** — remaining: display-less AI
  glasses (**2027**) and AR/XR smart glasses (**2029 at the earliest**). Kuo: *"The Apple XR
  headset and smart glasses roadmap I put together about a year ago is no longer a useful
  reference."* <https://9to5mac.com/2026/06/03/john-ternus-scaled-back-apples-vision-products-roadmap-report/>
  - ⚠️ **Conflicting reporting.** 9to5Mac notes this *"directly contradicts Mark Gurman's
    earlier reporting that Apple was developing a slimmer Vision Pro successor"*, and
    UploadVR pushed back on 2026-06-16 with "No, Apple Didn't Cancel The Vision Headset Line
    Forever." **Do not present the cancellation as settled fact.**
- **2026-07-08 — Samsung Display scrapped the G-VR panel**, a display project for a
  lower-cost XR device positioned as the Vision Pro follow-up. Source: The Elec (Korean
  supply-chain trade press), via 9to5Mac.
- **2026-08-20/21 — layoffs.** At least **60** Vision employees cut (AppleInsider);
  **Gurman/Bloomberg** separately reported Apple **disbanded the Vision Products Group**,
  distributing staff into larger divisions, with 200+ jobs cut across Siri and Vision and
  ~100 from VPG including *"largely shutting down a Vision Pro team focused on gaming."*
  Apple's own statement: the changes are *"to evolve our business… it will also impact a
  limited number of existing roles."* Employees were told Vision Pro and visionOS are **not**
  being eliminated; Ternus publicly called Vision Pro "extraordinary" and pointed at
  enterprise/medical use. The **60 figure has the cleanest attribution**.
  <https://9to5mac.com/2026/08/20/apple-reportedly-lays-off-60-vision-employees-amid-shifting-priorities/>
- **Counterweight:** AppleInsider, 2026-05-10, *"Not dead yet: Apple Vision still has a
  future"*.

**John Ternus became CEO on 2026-09-01** (announced 2026-04-20) — confirmed via Apple.

### Countries and price

**13 countries** as of 2025-11-20: Australia, Canada, China, France, Germany, Hong Kong,
Japan, Singapore, South Korea, Taiwan, UAE, UK, US.
<https://9to5mac.com/2025/11/20/m5-vision-pro-goes-on-sale-in-two-more-countries-as-gradual-global-rollout-continues/>

**Price: $3,699 (256GB), $3,899 (512GB), $4,199 (1TB) — raised from $3,499 on 2026-06-25.**
Tim Cook told the WSJ increases were "unavoidable" due to memory/storage chip costs.
<https://www.macrumors.com/2026/06/25/apple-vision-pro-just-got-even-more-expensive/> and
<https://9to5mac.com/2026/06/25/apple-price-increases-mac-ipad-more/>.
⚠️ **Flagged conflict:** `virtual.reality.news` ran "Apple Vision Pro Price Stays at $3,499"
the same day. Two independent outlets (MacRumors, 9to5Mac) plus UploadVR and The Apple Post
say otherwise, so **$3,699 is treated as correct**, but apple.com's buy page returned 503 on
2026-09-09 (an Apple event was in progress) and the figure was **not confirmed on Apple's
own store**. Launch price was **$3,499** (Apple Newsroom, 2024-01-08).

### The catalogue

| Date | Native visionOS apps | Source | Type |
| --- | --- | --- | --- |
| 2024-02-01 | **"more than 600"** | [Apple Newsroom](https://www.apple.com/newsroom/2024/02/apple-announces-more-than-600-new-apps-built-for-apple-vision-pro/), quoting Susan Prescott | **Official Apple** |
| 2024-02-13 | **1,000+** | Apple, confirmed to press (AppleInsider, Road to VR) | Official Apple, secondary |
| 2024-06-10 | **"more than 2,000"** | Apple Newsroom, visionOS 2 | **Official Apple** |
| 2024-08 | **2,500** | **Tim Cook, earnings call** (via CNBC 2025-02-21) | **Official Apple** |
| end of 2025-01 | **fewer than 1,900 still active** | **Appfigures**, via CNBC 2025-02-21 | Third-party data firm |
| 2025-12 | **1,782 active** | **Appfigures**, via analyticsindiamag.com 2025-12-24 | Third-party data firm |
| 2026-01 | "around 3,000" designed for Vision Pro | Apple, via MacRumors 2026-01-02 | Official Apple, secondary |

**The catalogue peaked and contracted.** Note the tension in the last row: Apple's "around
3,000" (cumulative, ever built) against Appfigures' "1,782 **active**". Both can be true;
the gap is the abandonment rate.

**Compatible (unmodified iPad/iPhone) apps:** Apple's actual wording was **"more than 1
million compatible apps across iOS and iPadOS"** (Apple Newsroom, 2024-01-08 and 2024-02-01).
Appfigures' working figure was **~1.2 million** (TechCrunch, 2024-02-12). **No Apple
statement using "1.5 million" was found — do not use that number.**

**Apple stopped publishing app-count milestones after mid-2024.** Apple's visionOS 26 launch
release (2025-06-09) contains **no app count, no installed-base figure, and no adoption
figure of any kind**.
<https://www.apple.com/newsroom/2025/06/visionos-26-introduces-powerful-new-spatial-experiences-for-apple-vision-pro/>
That silence is itself a finding.

**New-app velocity collapsed early.** Appfigures via 9to5Mac (2024-07-12): *"the number of
new apps launched for the Vision Pro has fallen dramatically since January and February,"*
with nearly 300 of the top iPhone developers still absent. **Only 10 apps** were added in
**September 2024**, *"down from the hundreds released in the first two months"* (9to5Mac,
2024-10-18). Named developers on the record in that piece: Hrafn Thorisson (Aldin Dynamics)
*"We're not in a rush. We're waiting until we see a better trajectory and when the next
device comes out."*; Scott Albright (Combat Waffle Studios) *"they need to figure out what
the headset is meant for."*

**Ecosystem-health signal:** AppleInsider, 2026-06-11 — "Apple Vision Pro might be getting
one app submission a day" vs iPhone's ~1,000/hour.

### How discovery works

There is a dedicated App Store app on the device. Per Apple's Vision Pro User Guide
(<https://support.apple.com/guide/apple-vision-pro/get-apps-tanf80e4a7ca/visionos>), the
left-hand navigation has **Apps & Games** (curated new apps with **editorial stories**),
**Arcade**, and **Search** — with an explicit filter toggle between **"Apple Vision"** and
**"iPhone & iPad"** compatibility. Product pages carry the usual metadata. Siri search into
the App Store is supported. Apple also curates through the Apple Vision Pro Services Guide.

Note what Apple's guide does **not** describe: **no separate Top Charts surface is
documented for visionOS.** Apple's framing is editorial-first, not chart-driven — which
means discovery is a gift Apple gives, not a position you can earn and hold.

**Evidence on how much traffic editorial featuring drives: NO RELIABLE FIGURE FOUND.**
Nothing public from Apple or any data firm. The nearest datapoint is anecdotal and negative
(below).

### Evidence about actual sales for niche professional tools

**Be blunt: the evidence is close to non-existent, and this was searched hard** — Google
News RSS, the Hacker News Algolia API (stories and comments, multiple formulations), Road to
VR, UploadVR, 9to5Mac, TechCrunch, mobilegamer.biz, and per-app App Store listings.

**Download counts, February 2024** (Immersive Wire, via AppleInsider 2024-02-12,
<https://appleinsider.com/articles/24/02/12/dont-read-too-much-into-early-apple-vision-pro-app-sales>):

- JigSpace: **14,000 installs in the first week**
- News Ticker (top paid news app): **300+ downloads/day**
- Zenitizer: **600 downloads** as of Feb 11
- Hold On (a timer): **six downloads** as of Feb 8
- Immersive Wire: *"many developers have struggled to raise download numbers – with 1000 as
  a ceiling of sorts"*

**Dollars — the only properly-sourced figure, CNBC 2025-02-21**
(<https://www.cnbc.com/2025/02/21/apples-vision-pro-has-a-problem-a-year-into-existence-too-few-apps.html>):

> Indie developer **Adam Roszyk**'s **17 Vision Pro apps** had "cleared about **$4,000** on
> the App Store in the last three months." CNBC notes it is "not enough for Vision Pro
> development to become his full-time job."

**Single-source, unaudited (flagged):** the same developer posted on X, 2026-07-24, that his
visionOS portfolio *"crossed $10k in cumulative gross customer sales… it took me 2 years"*,
across **30 apps**, with one app (Scan Export, a LiDAR-to-USDZ tool) ≈41% of the total.
<https://x.com/RoszykAdam/status/2080439852227531146> — X was not independently fetchable;
treat as the developer's own claim.

**Second-hand and weak, included only for shape:** HN comment, user `kalleboo`, 2024-04-27,
<https://news.ycombinator.com/item?id=40176929>: *"One developer, who's app was even featured
by Apple, stated that his sales of the app on the Vision Pro 'have just about paid back the
developer strap' (a $300 accessory)."* **Reliability: LOW** — an anonymous paraphrase of an
unnamed developer about an unnamed app. Colour, not evidence.

**Christian Selig / Juno** ($4.99, launched 2024-02-02, 686 points on HN) is the most-discussed
indie visionOS app and the obvious candidate for a disclosure. He said downloads "far
surpassed expectations" but **published no numbers**.

**A recollection worth killing:** no 2024 "one month on the visionOS App Store" developer
post could be found. HN Algolia returns **zero hits** for that shape of story. Do not cite
it without a URL.

**Aggregate visionOS consumer spend: NO RELIABLE FIGURE FOUND.** No Appfigures, Sensor
Tower, Appmagic or data.ai estimate exists in public. Note the asymmetry: UploadVR could
publish "Quest Users Hit Record High In 2025 & More Than 100 Apps Made Over $1 Million"
(2026-03-17) because **Meta discloses**. Apple discloses nothing at platform level, and no
data firm has filled the gap — plausibly because the addressable revenue is too small to
model.

---

## B.6 Pricing and business models that actually work

### The structural fact: visionOS is a paid-up-front, low-ASP market

**Appfigures via TechCrunch, 2024-02-12** — the only rigorous visionOS App Store economics
analysis found anywhere, covering **700+ Vision-Pro-optimised apps**
(<https://techcrunch.com/2024/02/12/over-half-of-vision-pro-only-apps-are-paid-downloads-far-more-than-wider-app-store/>):

- **52%** of Vision-Pro-only apps are **paid up front**, vs **5%** App Store-wide.
  (9to5Mac reports the same dataset as 53%; use "~52–53%".)
- **35%** had no monetisation at all; **13%** offered subscriptions.
- **Average price $5.67**; most at **$9.99 or below**; highest single app **$98**. Buying
  every paid app on the store would have cost **$1,089.07** — a number that tells you
  exactly how small the catalogue was.
- Among *modified* iOS apps with a native Vision experience the mix inverts: **17%** paid
  up front, **58%** subscription.

**Measured again 2026-09-09**, over the 109 visionOS-exclusive apps in Apple's own featured
browse set: **44 (40%) are paid up front**, price points $0.99–$49.99, **median $8.49**.
Still ~8× the App Store-wide paid rate, two and a half years later.

### Real apps, real prices (verified live on 2026-09-09)

Sample: every app linked from Apple's visionOS App Store browse page
(`https://apps.apple.com/us/vision/apps-and-games`) and its 119 editorial collection pages —
**293 apps, of which 109 are visionOS-exclusive**. This is Apple's own curated shop window:
**survivorship-biased and best-case**. Dates below are the **visionOS** build's dates.

**Paid up front — prosumer/pro:**

| App | Price | visionOS-exclusive | Released | Last visionOS update |
| --- | --- | --- | --- | --- |
| Complete HeartX (Elsevier/3D4Medical) | **$49.99** | yes | 2024-01-17 | 2025-07-01 (still v0.8.1) |
| Things 3 for Vision (Cultured Code) | **$29.99** | yes | 2024-01-31 | 2026-08-13 |
| Animoog Galaxy (Moog Music) | **$29.99** | yes | 2024-01-24 | 2025-03-03 |
| Bezel: Spatial Phone Mirroring (Nonstrict) | **$5.00** | yes | 2024-01-29 | 2026-01-21 |
| Television: The Future of TV (Sandwich) | **$5.99** | yes | 2024-02-22 | 2025-11-16 |
| Status Bar Builder | **$4.99** | yes | 2024-02-21 | 2024-07-12 |
| Void-X | **$3.99** | yes | 2022-06-07 | 2026-07-09 |
| FlightVision Flight Tracker | **$3.99** | yes | 2024-02-12 | 2024-03-15 |
| BitMaps (Michael Steeber) | **$2.00** | yes | 2024-02-20 | 2024-06-05 |
| Level Headed: Line Tool (Dark Noise) | **$1.99** | yes | 2024-02-13 | **2024-02-16** |
| FloatNotes | **$0.99** | yes | 2024-01-31 | 2024-07-02 |

**Free + one-time unlock / à-la-carte IAP:** Splitscreen — Multi Display (free trial →
**$19.99** one-time; last updated **2024-06-29**); Flow Nodes (free → **$49.99** All Nodes
one-time, or $2.99/mo · $19.99/yr; 2025-11-12); Spatial Symphony (free → **$6.99** Pro;
**2024-01-31**); Museas and Astronoma (free → per-content **$3.99–$8.99** + tips
$4.99–$14.99; both 2026-09-04); Cyberstocks (Pro $4.99 / Plus $3.99 + tips; 2025-10-28);
MD Clock (free → Premium $4.99; 2025-12-02); Blackbox for Vision (**$9.99** + hint packs;
2026-06-19).

**Subscription:** Screens 5 ($3.99/mo · $29.99/yr · **$179.99 lifetime**; vision build
2025-12-12); Explore POV (**$9.99/mo** · $24.99/3mo · $44.99/6mo; 2025-12-23); Numerics
($5.00/mo · $50/yr; 2025-03-26); Crouton (Discover $1.99/mo · $14.99/yr; Plus $24.99
one-time; 2025-11-19); Mercury Weather ($2.99/mo · $14.99/yr · $59.99 lifetime; vision build
**2024-06-24**); Navi ($3.99/wk · $8.99/mo; **2024-06-27**); Sky Guide (PLUS $4.99 · PRO
$8.99 · $59.99/yr · **PRO Lifetime $249.99**; vision build **2024-09-17**).

**Free, funded by an off-store business — the enterprise pattern:** JigSpace: 3D
Presentations (2026-08-10), Onshape Vision / PTC (2025-12-01), ForeFlight Voyager
(2025-12-23), Spatial Analogue (2026-07-03), Lexagon / Lextech (2026-05-20), SAP Analytics
Cloud, Adobe Premiere, Zoom, Slack.

**Corrections to commonly-cited names — verified:**

- There is **no app called "Spatial"**; the real one is **Spatial Analogue** (Spatial, Inc.).
- **Complete Anatomy has no native visionOS version.** Elsevier shipped a separate, narrower
  $49.99 product, **Complete HeartX**.
- **Blackbox** (iOS, id962969578) is **not** native visionOS; the visionOS product is a
  separate $9.99 SKU, **Blackbox for Vision** (id6458588937).
- **JigSpace** splits the same way: id1111193492 is iOS-only; the visionOS product is
  **JigSpace: 3D Presentations** (id6456791766).
- **Loóna, Moonly, Netflix, Spotify** — verified **not** native visionOS.
- **TaskCraft, ArtCode, Ready Player Me** — **UNVERIFIED**, no visionOS listing found. Do
  not use.
- **Camo Camera** is native visionOS (visionOS 1.1+), free.

### Which model works — the evidence, and its irony

**Developer commentary recommends paid-up-front.** Charlie Chapman, *"How to make money on
the visionOS App Store"*, RevenueCat, **2024-04-10** (updated 2024-06-06),
<https://www.revenuecat.com/blog/growth/how-to-make-money-on-the-visionos-app-store>. He
reports his visionOS app converting better than his iOS version, attributes it to early
adopters being "less price sensitive", and recommends **many small apps, paid up front or
one-time IAP, priced high**.

**The irony is verifiable and it is the most useful single fact in Part B.** Chapman is Dark
Noise LLC. His own visionOS app, **Level Headed: Line Tool** ($1.99), shipped 2024-02-13 and
was **last updated 2024-02-16**. He wrote the playbook, shipped once, and never returned.
The app's entire purpose — helping developers level their head to take straight App Store
screenshots — is itself an artifact of the platform's tooling gaps.

**Subscriptions are rare, and the survivors avoid them.** The one solo developer in the
dataset with three visionOS-exclusive apps all still updated in September 2026 (Miguel
Garcia Gonzalez: Museas, Astronoma, Cyberstocks) uses **zero subscriptions** — free
download, à-la-carte content packs at $3.99–$8.99, and explicit tip jars.

**Read-across for a Throttle companion:** Throttle's existing model is a Pro licence. On
visionOS the market structure says a subscription-gated companion would be swimming against
the grain; a **one-time unlock or inclusion in the existing Pro entitlement** matches how the
platform actually monetises. Given the installed base, the honest expectation for
incremental revenue is **near zero either way** — which argues for bundling it into the
existing licence and spending zero effort on visionOS-specific monetisation.

### Mac-companion apps — third parties do exist

| App | What it does | Price | State |
| --- | --- | --- | --- |
| **Splitscreen — Multi Display** (Jordi Bruin, id6478007837) | Shares **additional** Mac displays to Vision Pro, including across different Apple IDs — the exact gap Apple has never closed | free trial → **$19.99** one-time | visionOS-exclusive · released 2024-02-27 · **last update 2024-06-29** |
| **Bezel: Spatial Phone Mirroring** (Nonstrict) | Mirrors an iPhone into the headset | **$5.00** | 2026-01-21 |
| **Screens 5: VNC** (Edovia) | Full VNC remote desktop | free + sub / $179.99 lifetime | vision build 2025-12-12 |
| **Portal: Remote Play** (OverSoul) | PS/Xbox/HDMI remote play | free | 2026-08-20 |
| **Steam Link** (Valve) | Steam streaming | free | universal |

**Splitscreen is the sharpest case in this report.** It occupies the single most-requested
gap Apple has left open for three OS majors, charges a healthy $19.99 one-time, and was
built by a well-known indie — and it has been **untouched for 26 months**. Its author's
other visionOS app, Navi, stopped two days earlier (2024-06-27). One developer, two
launch-window visionOS apps, both abandoned the same week of June 2024.

### Published revenue

Beyond CNBC's $4,000/quarter and the unaudited $10k/2-years figures above: **no
launch-window developer — Algoriddim, Resolution Games, Halfbrick, 3D4Medical, Cultured Code
— has disclosed visionOS revenue.** Apple has never published visionOS developer proceeds;
CNBC states this explicitly. **NO RELIABLE FIGURE FOUND.**

---

## B.7 Did "first in category" convert into durable advantage?

**Short answer: no. Being early bought an Apple feature slot, and feature slots expire.**

### The launch cohort is verified

Apple Newsroom, 2024-02-01, *"Apple announces more than 600 new apps built for Apple Vision
Pro"* named, among productivity: Box, MindNode, OmniFocus, OmniPlan, Microsoft 365,
Fantastical, **Numerics, JigSpace, Navi**, Webex, Zoom, Teams, Slack, Notion, Todoist; among
learning: solAR, **Sky Guide**, Night Sky, Exploring Mars, Insight Heart, CellWalk,
**Complete HeartX**; among games: **Blackbox, Void-X, Loóna, Super Fruit Ninja, Synth
Riders, WHAT THE GOLF?**; among music: **djay, Animoog Galaxy, AmazeVR**.

### Where they are now — measured, not asserted

A methodological point that changes the answer: **for universal apps, the visionOS build has
its own version number and its own release date, independent of the iOS binary.** Reading
the iTunes API or the default App Store page gives you the *iOS* date and will tell you an
app is actively maintained when its visionOS slice is years stale.

| App | visionOS build | iOS build | visionOS lag |
| --- | --- | --- | --- |
| Slack | 26.09.10 · 2026-09-03 | 26.09.10 · 2026-09-02 | lockstep |
| Disney+ | 5.16.4 · 2026-09-08 | 5.16.4 · 2026-09-08 | lockstep |
| Screens 5 | 5.7.10 · 2025-12-12 | 5.8.12 · 2026-07-30 | ~9 months |
| Fantastical | 4.1.4 · 2025-12-02 | 4.1.19 · 2026-09-01 | ~9 months |
| Crouton | 2025.8.3 · 2025-11-19 | 2026.1.2 · 2026-07-14 | ~10 months |
| Zoom | 6.6.5 · 2025-10-22 | 7.1.8 · 2026-09-03 | ~10.5 months |
| djay | 1.2 · 2025-09-24 | 5.6.8 · 2026-08-05 | ~11.5 months |
| Sky Guide | 1.0.4 · 2024-09-17 | 12.2.2 · 2026-08-06 | **~24 months** |
| Mercury Weather | 1.0.9 · 2024-06-24 | 3.6.3 · 2026-08-26 | **~27 months** |

Mercury Weather ships to iOS constantly and has not touched its visionOS build in over two
years. That is the honest shape of "we support visionOS".

**Across the 109 visionOS-exclusive apps Apple *currently features*:**

| Metric | Result |
| --- | --- |
| Not updated in the last 12 months | **51 / 109 (47%)** |
| No update since 2024 at all | **36 / 109 (33%)** |
| Launch cohort (first released before 2024-07-01) | 70 apps |
| …still updated in the last 12 months | **28 / 70 (40%)** |
| …no update since 2024 | **32 / 70 (46%)** |

Nearly half of the launch cohort that Apple *still puts in its own shop window* has been dark
since 2024.

**Named, by last-update date** (report as "not updated since", not "abandoned" — no
developer has publicly stated abandonment): Level Headed (31 months), Spatial Symphony (31),
Portal Vision (30), FlightVision (30), Job Simulator / Vacation Simulator, Owlchemy, $19.99
each (27), Mercury Weather's vision slice (27), Super Fruit Ninja, Halfbrick, Apple Arcade
(26), Navi (26), Splitscreen (26), Sky Guide's vision slice (24), PGA TOUR Vision (17),
Numerics' vision slice (18), Complete HeartX, $49.99, still v0.8.1 (14).

**Genuine survivors** — visionOS-exclusive, launch cohort, still shipping in 2026: JigSpace:
3D Presentations (2026-08-10), Things 3 for Vision (2026-08-13), Blackbox for Vision
(2026-06-19), Zillow Immerse (2026-04-09), Moon Player (2026-09-04), Museas / Astronoma
(2026-09-04).

### The removal case: Juno

Launched 2024-02-01 by Christian Selig at **$4.99**, because Google refused to build a
YouTube app (<https://9to5mac.com/2024/02/02/vision-pro-youtube-app-juno/>). **Removed
2024-10-01** after Google complained; 9to5Mac quotes Google saying third parties *"cannot
modify the YouTube website or use its trademarks and iconography."* Selig's reply: *"Juno is
just a web view, and acts as little more as a browser extension that modifies CSS."* He had
**"zero desire"** to fight Google after the Reddit API episode.
<https://9to5mac.com/2024/10/01/youtube-app-juno-apple-vision-pro-app-store/> ·
<https://www.macrumors.com/2024/10/01/juno-vision-pro-removed-app-store/>
Confirmed dead 2026-09-09: `apps.apple.com/us/app/juno-for-youtube/id6476961640` returns
**HTTP 404**.

### The big absences — 2026 status

| Service | Native visionOS app in Sept 2026? | Evidence |
| --- | --- | --- |
| **Netflix** | ❌ **NO** | Listing id363590051 carries no `product_media_vision_` block and no "Apple Vision" in Compatibility; iOS v18.48.1 shipped 2026-09-08 — actively maintained everywhere else |
| **Spotify** | ❌ **NO** | Listing id324684580, same test; iOS v9.1.80 shipped 2026-09-07 |
| **YouTube** | ✅ **YES — shipped 2026-02-12** | **"YouTube for visionOS"**, Google LLC, id6745572359, free, visionOS-exclusive, requires visionOS 26.0, current v1.04 (2026-07-28). Confirmed by MacRumors / 9to5Mac / TechCrunch all dated 2026-02-12, and by Apple's own editorial story |

**The sequence matters: Google had Juno killed in October 2024 and shipped its own app 16
months later, in February 2026 — two years after the platform launched.**

### What this implies (INFERENCE, grounded in the above)

1. **Early bought placement, not users.** The only launch number resembling a hit (JigSpace,
   14k installs/week) belongs to an app Apple put in its launch video. The median launch app
   was under 1,000 downloads; Hold On got six. On ~390k lifetime year-one units, first-mover
   advantage is a feature slot.
2. **Survival correlates with having a business off the headset, not with being early.**
   Every launch app still shipping in 2026 is either a shared-codebase target (Disney+,
   Slack) or enterprise-funded (JigSpace, Onshape, ForeFlight, SAP). The visionOS-only
   *consumer* apps are the stale ones. Things 3 for Vision at $29.99 is the sole clear
   exception, and Cultured Code is a 15-year-old company amortising it.
3. **Even subsidised, mandated ports rot.** Apple *pays* Apple Arcade developers and requires
   Vision Pro support. Super Fruit Ninja has not shipped a build since June 2024.
4. **Filling a platform hole is the most dangerous position, not the safest.** Juno was
   simultaneously the best proof of demand for YouTube on Vision Pro and the reason it was
   destroyed. The hole belonged to Google.
5. **Attention and revenue were uncorrelated.** Per the one developer with published
   receipts, a 699k-view viral app "barely moved the P&L" while an unglamorous
   LiDAR-export utility was 41% of gross.

---

## B.8 The realistic downside: maintenance and redundancy risk

### Version cadence and the annual tax

visionOS 1.0 (2024-02-02) → 1.1/1.2/1.3 → 2.0 (2024-09-16) → 2.6 (2025-07-29) → **26.0
(2025-09-15)** → **26.6.1 (2026-08-17, current)**. **visionOS 27 announced at WWDC26 on
2026-06-08, in beta, shipping "late 2026."**
<https://developer.apple.com/documentation/visionos-release-notes>

**One new major Xcode per visionOS major:** visionOS 1.0→Xcode 15.2 · 2→Xcode 16 · 26→Xcode
26 · 27→Xcode 27.

**The mandatory floor, verbatim from Apple** (<https://developer.apple.com/news/upcoming-requirements/>):

> "Since April 28, 2026 — Apps uploaded to App Store Connect must be built with Xcode 26 or
> later using an SDK for iOS 26, iPadOS 26, tvOS 26, **visionOS 26**, or watchOS 26."

So even a **frozen** visionOS app must be rebuilt on a new major Xcode roughly annually to
ship any update at all.

**Documented breaking changes:**

- **visionOS 2:** original StoreKit API deprecated (SKProduct, SKPayment,
  SKStoreReviewController…); `TabContent` popover modifier unavailable; RealityKit
  child-entity ordering unreliable; GameController input **breaks** without
  `GCEventInteraction` / `handlesGameControllerEvents`.
- **visionOS 26:** `ARQuickLookPreviewItem.h` moved to QuickLook; six
  `NSPersistentStoreUbiquitous*` Core Data keys removed ("Affected apps rebuilt with the 26
  SDK will get errors"); default minimum TLS moved 1.0→1.2; `Text` `+` concatenation
  deprecated; `UIScreen.mainScreen` deprecated.
- **visionOS 27 (beta):** **"Apps built with the latest SDK must adopt the scene-based life
  cycle or they fail to launch."** `FileDocument` deprecated. On Demand Resources deprecated.

**The visionOS-specific hazard, Apple's own words**
(<https://developer.apple.com/documentation/visionos/determining-whether-to-bring-your-app-to-visionos>):

> "visionOS removed many deprecated symbols entirely, turning these deprecation warnings
> into missing-symbol errors on the platform."

The same page lists ~50 frameworks that differ or are absent: **ARKit views never exist on
visionOS**, AVFoundation capture unavailable, most Core Location unavailable, Multi-Touch
capped at two touches, widgets / App Clips / keyboard / Messages extensions not loaded,
ActivityKit iOS-only, no Picture in Picture.

**Third-party engines are worse.** An Unreal Engine forum thread (2026-01-11 → 2026-02-05)
documents visionOS 26.2 regressions — level-loading crashes, *"MSAA renders everything fully
black"*, SMAA *"renders only one eye"* — with Epic's position that the platform is
"experimental" with "no roadmap to take it to Beta."
<https://forums.unrealengine.com/t/collection-of-visionos-26-2-and-vision-pro-issues-and-hopes-for-any-timeline-to-resolve-them/2691226>
*(Not directly relevant to a SwiftUI window app; included because it calibrates Apple's
partner-support posture.)*

### Simulator vs device

- **Apple silicon Mac required:** "Developing for visionOS requires a Mac with Apple silicon.
  (114799042)" — Xcode 15.2 release notes.
- **Apple's disclaimer:** simulators *"don't replicate the performance or features of a
  physical device."*
- **Documented simulator failures in Apple's release notes:** `breakthroughEffect` /
  `presentationBreakthroughEffect` *"have no effect in the simulator"* (152112050);
  SharePlay testing over FaceTime *"might cause the simulator to crash"* (153776177).
- **And the decisive one for Part A:** TN3179 — *"The simulator doesn't support local network
  privacy. Test your local network privacy behavior on a real device."*
- **Developer accounts** (r/visionosdev — ⚠️ retrieved machine-translated, so these are
  **paraphrases, not quotes**): wall/plane detection does not work in the simulator;
  windowing size modes are unsupported and undocumented; the simulator's resolution and
  aspect ratio are wrong for App Store screenshots; hand/space tracking requires a fully
  immersive space.
- **Counter-evidence — 2D window apps CAN ship simulator-only.** Michael Stelzer,
  2024-02-08, *"Develop and Release a visionOS App without Vision Pro"* — shipped BeatFabrik
  with no hardware. <https://mic.st/blog/develop-and-release-a-visionos-app-without-vision-pro/>

That the App Store contains a **$1.99 app whose only job is helping you level your head for
straight screenshots** (Level Headed) is itself the best evidence that device-only workflows
are real.

**Net for Throttle:** a windowed SwiftUI app *can* be shipped without a headset. But
**Part A's networking behaviour specifically cannot be validated in the simulator** — the
Local Network prompt does not exist there, and the unworn/background socket behaviour is the
single biggest unknown. Shipping without a device means shipping the transport unproven.

### Hardware cost in 2026

**$3,699 (256GB) / $3,899 (512GB) / $4,199 (1TB)** since 2026-06-25 (see B.5 for the flagged
conflict). **No cheaper model ever shipped**; "Vision Air" was cancelled. Independent
corroboration of the two-SKU reality: the iTunes API's `supportedDevices` for
visionOS-exclusive apps now returns `["AppleVisionPro-AppleVisionPro",
"AppleVisionProM5-AppleVisionProM5"]`.

**Solo-developer floor: $3,699 device + an Apple-silicon Mac + $99/yr**, before ZEISS
inserts.

### App Review differences

- **There are no visionOS-specific App Store Review Guidelines.** A full read returned no
  visionOS / Persona / immersive / hand-tracking clauses.
- The extra burden is in App Store Connect: visionOS 2 SDK minimum; new privacy groupings
  **"Surroundings"** (mesh, planes, scene classification, image detection) and **"Body"**
  (Hands, Head); mandatory app-motion-information disclosure.
  <https://developer.apple.com/visionos/submit/>
- **iPad/iPhone apps are auto-listed on Vision Pro**, and you can opt out: *"Your compatible
  iPad and iPhone apps will be published automatically… You can edit your app's availability
  at any time in App Store Connect."* — worth knowing: doing nothing still puts a version of
  the app in front of Vision Pro users.
- **NO RELIABLE SOURCE FOUND** for visionOS-specific rejection patterns.

### Sherlock risk — and why it is the wrong worry

| Version | Mac Virtual Display |
| --- | --- |
| visionOS 1 | Single virtual Mac display, marketed as a private, portable 4K/5K display |
| visionOS 2 (announced 2024-06-10) | *"higher resolution and larger size — creating an ultra-wide display that is equivalent to two 4K monitors side by side"* |
| visionOS **2.2** (2024-12-11) — actually shipped it | Standard 16:9 · Wide 21:9 · **Ultrawide 32:9**; needs Apple silicon + macOS 15.2 |
| visionOS 26 | **No Mac Virtual Display capability change** in Apple's press release |
| visionOS 27 (beta) | Mac 3D-model preview in your space; a widget to connect to a closed Mac; curved windows. **Still no multi-display.** |

**Apple, verbatim, still true today** (<https://support.apple.com/en-us/118521>): *"When your
Mac has multiple displays connected to it, Mac Virtual Display shows only the one that you've
set as the main display"* and *"Mac Virtual Display connects your Apple Vision Pro to only
one Mac at a time."*

**This is the most important Sherlock datapoint in the report, and it cuts the opposite way
to the usual fear.** Apple has had **three major OS versions and 31 months** and still has
not shipped multiple virtual Mac displays. Splitscreen — the third-party app that does
exactly this — was **never Sherlocked**. It died anyway, of market size.

**What Apple did absorb:** visionOS 2 took system hand gestures for Home View/Control Center,
Travel Mode, Guest User, mouse support, Magic Keyboard passthrough. visionOS 26 took spatial
**Widgets** + WidgetKit, Spatial scenes, all-new Personas, **PSVR2 Sense controller** support,
Look to Scroll, `<model>` in Safari. visionOS 27 adds Siri/Visual Intelligence, panorama →
environment conversion, curved windows, Reality Composer Pro 3 with generative assets, 3D
Gaussian Splats, Foveated Streaming.

**Documented case of a specific named visionOS app killed by an OS feature: NONE FOUND.**
Multiple targeted searches returned nothing. Apple did absorb several widget and status-bar
concepts in visionOS 26, and the third-party apps in that space (GlanceBar 2025-09-15,
Status Bar Builder 2024-07-12, BitMaps 2024-06-05) all went quiet — but **no developer said
Apple was the cause**, and abandonment on this platform is over-determined. **Do not claim
causation.**

### Specific redundancy risk for a Throttle vision companion

Mac Virtual Display already lets a Vision Pro user see their Mac — including any Throttle
window on it — at 5K. So the honest question is not "will Apple Sherlock this?" but **"what
does a native visionOS Throttle do that Mac Virtual Display does not already do?"** The only
defensible answers from the current design are: (1) it works when the Mac is *not* the
machine you are looking at — i.e. remote over Tailscale, which Mac Virtual Display's 10 m /
same-Apple-Account / Handoff requirements exclude; and (2) it persists as its own window
independent of the mirrored desktop. Both are real, both are narrow, and neither is worth a
dedicated product effort at this installed base.

### Roadmap risk

Summarised from B.5: Gurman (2026-05-10) reports no new Vision Pro-style device for ~two
years and Vision Air cancelled; Kuo (2026-06-03) reports the head-mounted roadmap cut from
seven products to two, both **glasses** (2027 and 2029); Bloomberg (2026-08-21) reports the
**Vision Products Group disbanded**, with staff distributed into larger divisions.
Employees were told visionOS is not being eliminated, and Apple/Ternus continue to point at
enterprise and medical use. **The paywalled primaries (FT, Bloomberg) were not read
directly; all of this is second-hand through MacRumors, 9to5Mac and AppleInsider, and
UploadVR has publicly disputed the strongest version of the cancellation claim.**

*INFERENCE:* even on the most charitable reading, investing net-new effort in a visionOS
consumer product in late 2026 means building for a device whose vendor has publicly moved
its people elsewhere and whose successor, if any, is two-plus years out.

---

## B.9 What this means concretely for Throttle

Facts observed in this worktree on 2026-09-09 (not research — direct inspection):

- `ThrottleVision` already exists: **4 Swift files, 194 lines total**
  (`ThrottleVisionApp.swift` 18, `VisionAppDelegate.swift` 35, `VisionCockpitView.swift` 141)
  plus Info.plist, entitlements, PrivacyInfo and an app icon.
- Added **2026-07-10** ("visionOS spatial cockpit target (mirror client)"); touched **once**
  since, in a repo-wide change on 2026-08-16. Marginal cost to date: near zero.
- It reuses `ThrottleShared/Sources/ThrottlePeer` (966 lines) wholesale and shares
  `ThrottleiOS/Services` and `MirrorUI.swift` with the iOS target — the visionOS slice is
  genuinely a thin view layer, not a parallel implementation.
- CI builds it (`.github/workflows/ci.yml:101`) for `generic/platform=visionOS Simulator`,
  Release, `CODE_SIGNING_ALLOWED=NO`, with build evidence archived. `README.md` correctly
  states "build/device validation required".
- Entitlements and Info.plist are already correct for Part A: no multicast,
  `NSLocalNetworkUsageDescription`, `NSBonjourServices: [_throttle._tcp]`, shared App Group,
  shared CloudKit container, `aps-environment`.

**The strategic read.** The visionOS target has already captured essentially all the value
it can: it proves the shared transport layer is platform-agnostic, it costs one CI job, and
it is a portfolio artifact. The market evidence says the *next* increment — a real spatial
UI, device QA, App Store listing, screenshots, review, ongoing SDK migrations — buys
approximately nothing.

**Suggested posture, for a human decision:**

1. **Keep** `ThrottleVision` as a windowed-parity slice. Do not invest in immersive spaces,
   volumes, or a visionOS-specific design language.
2. **Do not ship it to the App Store** until (and unless) there is a device to validate the
   Local Network prompt and the unworn-socket behaviour, both of which are unprovable in the
   simulator.
3. **Budget the recurring cost honestly:** one major Xcode/SDK migration per year, on a
   platform that converts deprecation warnings into build errors. The visionOS 27
   scene-based-lifecycle requirement is the next known break.
4. **Set an explicit kill condition** — e.g. if the visionOS build ever needs more than a
   trivial fix to survive an SDK migration, delete the target rather than maintain it. The
   published record shows that is what almost every other indie effectively did, just
   without deciding it.

---

## Appendix — reliability key

**VERIFIED (primary, fetched 2026-09-09 unless dated otherwise):** every TN3179 quote and
table; the multicast, App Group, CloudKit, keychain, background-mode and push platform
availability lists; the App Store Review Guidelines text and its 2026-06-08 date; the
notarization-scope table; the five native-visionOS terminal/remote apps and their platform
arrays; Mac Virtual Display's single-display limitation; the absence of any third-party
virtual-display API; Apple's app-count milestones (600 / 1,000 / 2,000 / 2,500); the
Appfigures 52% / $5.67 figures; every app price and per-platform build date in B.6/B.7;
Juno's 404; YouTube for visionOS shipping 2026-02-12; Netflix and Spotify's continued
absence; the Xcode 26 SDK floor; the visionOS deprecation-to-error hazard.

**ANALYST / THIRD-PARTY ESTIMATE (named firm, dated, methodology noted where known):** IDC
unit figures (390k in 2024; <100k any quarter; <500k year one; 45k Q4 2025); Appfigures
active-app counts (1,900 → 1,782); Sensor Tower ad-spend cut; Counterpoint's market-level
−14%; Kuo's pre-order estimates.

**SECOND-HAND (paywalled primary not read):** the FT 2025-12-31 production-cut report;
Gurman/Bloomberg's May and August 2026 reporting; Kuo's June 2026 roadmap post; the
developer's $10k X post.

**INFERENCE (labelled at each use):** the Tailscale-address prompt conclusion; the
unworn-socket behaviour; the `$(TeamIdentifierPrefix)` literal spelling; the
first-mover-advantage reading; the redundancy analysis.

**NO RELIABLE FIGURE FOUND — do not fill in:** any Apple Vision Pro unit total; a
named-firm cumulative launch-to-2026 figure; Apple's visionOS developer proceeds; aggregate
visionOS consumer spend; any launch-window developer's dollar revenue; any named app
documented as killed by an OS feature; visionOS-specific App Review rejection patterns; App
Store listings for "Spatial", TaskCraft, ArtCode or Ready Player Me; Chrome Remote Desktop
on iOS; a 2024 "one month on the visionOS App Store" post.

**Unclosed, cheap to settle on a device:** whether Tailscale ships a visionOS build; what
happens to a live `NWConnection` when the headset is removed; whether an unfocused Shared
Space window leaves `ScenePhase.active`; whether the Mac's bare `group.` App Group string
resolves for the non-sandboxed Throttle target.
