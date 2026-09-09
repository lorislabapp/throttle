# Is "GOAT of agentic coding on Apple Vision Pro" a real opportunity?

Research pass — 2026-09-09. Author: Claude (Opus 5), for LorisLabs / Throttle.

Evidence convention used throughout:

- **[V]** = verified against a cited source with a date.
- **[I]** = inference by me from verified facts. Not a source claim.
- **[U]** = could not verify. Stated as unknown, never as fact.

---

## Verdict

**"GOAT of agentic coding on Vision Pro" is a mirage as a destination, and a real —
small — opportunity as a detour.**

The category is genuinely empty in the specific way you'd hope. There is no Claude app on
visionOS at all (Anthropic closed the request as *not planned*), no Cursor, no Copilot, no
Codex. The half-dozen SSH clients that do ship there (Termius, Blink, Prompt 3, Secure
ShellFish) have built **zero** agent-aware chrome — no approvals, no diffs, no usage
meters, no session model. That gap is real and verified.

But four facts kill it as a primary bet:

1. **The market is ~80–90k units sold in 2025**, down from 390k in 2024, with Apple
   reportedly cutting ad spend >95% and pushing the cheaper headset to **late 2028** while
   pivoting to smart glasses for 2027. Glasses cannot run a cockpit. The platform is
   shrinking, and its successor is the wrong shape.
2. **The ergonomics are against long coding sessions, and this is not opinion.** Apple's
   own safety page says take a break every 20–30 minutes. The one controlled study of
   working in VR for a week (n=16, 8h/day) found significantly worse eye strain, task load,
   frustration and productivity than a desk, with 12.5% dropping out on day one.
3. **You are not first.** **JarVS** (visionOS 26.2+) already ships multi-window VS Code on
   Vision Pro with git-worktree-aware window grouping and explicitly markets "running
   multiple AI coding agents in parallel". Panic shipped Prompt 3 for Vision Pro in
   **March 2026** with a bespoke immersive space. The "spatial multi-agent cockpit" idea
   has been had, and partially shipped, by other people.
4. **Your defensibility is months, not a moat.** Blink/Termius/Prompt already have the
   terminal on visionOS. What they lack — the meter, the pairing, the Mac-side session
   model — is exactly what Throttle already has, but nothing stops them building it.

**What *is* real**: the surviving pattern in headset productivity is *"extend the Mac you
already own"* (Immersed, Mac Virtual Display), not *"be the workstation"* (Horizon
Workrooms — discontinued Feb 2026; Spacetop — cancelled). And Mac Virtual Display has one
hard structural limit that a native app does not: **it is local-network-only, one Mac, one
display, within ~30 feet.** A Throttle visionOS cockpit that supervises agents on a Mac
you are *not* next to is not competing with Mac Virtual Display — it is doing the thing
MVD structurally cannot.

One genuinely encouraging number, and it is the only one arguing for spending real effort:
**~50% of Vision-only apps are paid, versus ~4% across the App Store** (Appfigures, April
2024). A tiny audience that actually pays is a much better fit for a €-priced pro tool than
a large audience that doesn't.

**Recommendation.** Do not reposition Throttle as a Vision Pro product. Do not build an
immersive space, a spatial IDE, or anything requiring new architecture. **Spend roughly one
to two weeks** turning the existing 141-line read-only ThrottleVision mirror into a real
supervision cockpit by porting the iOS terminal stack that already exists, ship it as a
free bundled surface of the existing app, and treat it as a **credibility and press asset
for the Mac product**, not a revenue line. That converts a dying platform into cheap
differentiation ("Throttle is the only Claude Code meter with a Vision Pro cockpit") at a
cost you can afford to write off. If Vision Pro unexpectedly recovers, you are positioned.
If it doesn't, you lost two weeks and gained a screenshot.

---

## 1. State of visionOS apps for developers and coding, 2026

The dominant structural fact of this whole category: **almost everything ships in iPad
compatibility mode.** A "Requires visionOS 1.0 or later" line on an App Store page usually
means the developer did nothing — the iPad binary runs in a flat window. Genuinely native
spatial work is rare and identifiable.

### SSH / terminal clients — the category exists and is crowded

| App | visionOS status | Price **[V]** | Rating **[V]** |
|---|---|---|---|
| **Termius** | Vision-compatible, visionOS 1.0+ | $15/mo or $119/yr, subscription-only | 4.7★, 19K ratings (cross-platform aggregate) |
| **Blink Shell, Build & Code** | visionOS 1.3+ | Blink+ $19.99/yr; "Build Basic" $7.99/mo (50 AI credits) | 3.1★, 418 ratings |
| **Prompt 3** (Panic) | visionOS 2.2+; **Vision Pro support shipped ~2026-03-12** | Free w/ IAP: $9.99/yr or $49.99 lifetime; free to existing owners | 4.3★, 356 ratings |
| **Secure ShellFish** | visionOS 1.1+ | Free w/ ads; Pro IAP | not captured |
| **ServerCat** | visionOS 1.0+ | Freemium (SSH is premium) | not captured |
| **a-Shell** | "Designed for iPad", visionOS 1.0+ | Free | not captured |

- **[V]** **Prompt 3 is the only SSH client found with a purpose-built spatial feature**:
  an optional cyberpunk immersive space called **"Terminal 33"**, documented on Panic's own
  help page (help.panic.com/prompt/apple-vision-pro/). Everything else is a resized iPad
  window.
- **[V]** **La Terminal** markets itself as built "from the ground up… a first-class spatial
  computing experience for command-line hackers on Vision Pro" and was a **day-one Vision
  Pro launch app** (2024), with AI command assistance and resource monitors.
  (la-terminal.net; Product Hunt.)
- **[V]** No visionOS build of **iSH** or **Terminus** (Cathay Labs) exists. The App Store
  "SSH" results on visionOS are heavily padded with near-identical low-quality clones.
- **[V]** **None of these terminals has built agent-specific chrome** — no approvals, no
  live diffs, no usage meters, no per-agent session state.

### Remote desktop / VNC / RDP — every major brand is in compatibility mode

- **[V]** **Jump Desktop** ($14.99 one-time, 4.5★/1.7K) runs as a **plain compatible iPad
  app**, "stuck in a 4:3 iPad aspect ratio that may have black bars". No spatial UI.
- **[V]** **Screens 5** (Edovia) is officially "available in compatibility mode for
  visionOS" per MacStories — though Edovia rewrote its rendering engine so text stays crisp;
  requires visionOS 2.0+. $3.99/mo, $29.49–29.99/yr, or **$179.99 lifetime**. 4.5★/536.
- **[V]** **Microsoft Windows App** (RDP) is compatibility-mode only and is listed under the
  **iPad tab, not the Vision Pro tab**. Free. No native client announced.
- **[V]** **Splashtop** (free app, subscription host access, 4.8★/4.6K aggregate) and
  **AnyDesk** (free, 4.8★ but only **18 ratings** — likely visionOS-specific) are both
  compatibility-mode.
- **[V]** **TeamViewer** ships a *different* product — **"Spatial Support"**, which uses
  iPhone LiDAR to capture 3D models of equipment for a remote expert to annotate in AR. Not
  a desktop mirror. **[U]** Its App Store listing returned HTTP 404 at fetch time —
  possibly renamed or delisted; price and rating unverified.
- **[U]** **Parsec** — no visionOS-specific confirmation found. **[V]** **Moonlight** has
  **no official visionOS app**; only an unaffiliated community port (`J5892/moonlight-visionos`),
  not on the App Store.
- **[V]** **Remio** currently ships as an iPad-compat app streaming a Mac with hardware
  H.265 decode, and is **explicitly building** a true native spatial client (gaze-as-cursor,
  pinch-as-click, per-host virtual displays) — currently at public-waitlist stage, **not
  shipped**. (remio.net/vision-pro.) The vendor's own framing is that no such client exists yet.
- **[I]** So: **there is no shipped, fully native, spatial-first remote-desktop client on
  visionOS today.** That is a verified gap — and Remio is publicly racing into it.

### Code editors and IDEs

- **[V]** **Xcode cannot run on visionOS.** Apple Developer Forums, thread 744427: "You
  cannot run macOS apps on visionOS. However, you could run Xcode on your Mac and display
  your Mac's screen contents on Vision Pro."
- **[V]** **No official native VS Code.** The feature request `microsoft/vscode#202543`
  ("Support VSCode running natively in Vision Pro") is open and unresolved.
- **[V]** **Working Copy** (Git client) confirms visionOS 2.2+ support — clone/edit/commit/push.
- **[V] — the most important competitive find in this report: JarVS**
  (App Store id6759111444, **requires visionOS 26.2+**, jarvs.space). A free host app runs on
  the user's Mac or Linux box hosting VS Code Server; the Vision Pro client renders
  **"unlimited floating VSCode windows"** as separate spatial windows, one per
  project/branch/task, with **git-worktree-aware window grouping** and voice/gesture
  controls. Billed as a **one-time purchase**; **[U]** exact price unverified (App Store
  fetch rate-limited), and it has too few ratings to show a score.
  **[V]** JarVS explicitly markets support for **"running multiple AI coding agents in
  parallel"**.
  **[I]** This is the single closest existing product to the concept in the brief. It is
  indie, it is new, it has no reviews yet, and it is thin-client + always-on host — the same
  architecture Throttle would use. **You would not be creating this category; you would be
  entering it second, against someone whose whole product is this.**
- **[V]** "VisionCode" / "vCode" and similar names are a trap — plain iOS mobile code
  editors with no visionOS design. **SuperCode** and **CodeEditorView** are GitHub
  hobby/library projects, not products.
- **[V]** No Apple, Microsoft, JetBrains or Google native visionOS IDE exists.

### AI / agent tools on visionOS

- **[V]** **ChatGPT** has a native visionOS app (launched 2024-02-02, one of "more than 600
  apps built for visionOS" at launch), multimodal. **[V]** The free tier reportedly isn't
  available on visionOS — ChatGPT Plus ($20/mo) required (secondary source, soft).
- **[V]** **Claude is not available on visionOS at all** — not native, not "Designed for
  iPad". The request (`anthropics/claude-code#12608`) was **closed as "not planned"**.
  Vision Pro users must use Safari.
- **[V]** **No GitHub Copilot and no Cursor presence on visionOS**, at all.
- **[I]** So the literal statement "there is no Claude surface on Apple Vision Pro" is
  **verified true as of 2026-09-09**. That is the strongest single argument for building
  this. It is undercut by the fact that Anthropic looked at it and declined.

### Multi-screen / virtual monitor

- **[V]** **Immersed** — native (Unity, immersive). Free tier gives 2 extra virtual screens
  (3 total); a **$50 IAP unlocks 2 more** (5 total); up to 2560×1400 with an Immersed Pro
  subscription. Works with **Mac, Windows and Linux** hosts. **[V]** Reviewers report harsh
  foveated rendering, off gamma, and — critically — that **Immersed cannot run alongside
  other visionOS apps** (it takes the immersive space).
- **[V]** **Splitscreen** adds a **second** Mac's screen alongside native Mac Virtual
  Display, even under a different Apple ID. **MacLink** shows **up to 3 Macs
  simultaneously**, each in its own spatial window.
- **[V]** **Virtual Desktop** (Guy Godin) is **still not shipped for visionOS**; the
  developer has said the port is far more complex than his Pico ports and Apple's stance on
  immersive PCVR streaming is unclear. No ship date.
- **[U]** Sightful Spacetop's 2026 operating status could not be re-verified in this pass
  (but see §6: Road to VR reported the Spacetop G1 hardware **cancelled**).
- **[V]** No BetterDisplay-equivalent utility on visionOS.

### What does NOT exist — the explicit list

**[V]** As of 2026-09-09, none of the following could be found to exist:

1. A Claude / Claude Code client of any kind on visionOS.
2. A Cursor, GitHub Copilot, Devin, Replit or Warp presence on visionOS.
3. A shipped, fully native, spatial-first VNC/RDP client (Remio is building one).
4. Any SSH/terminal app on visionOS with agent-aware chrome (approvals, diffs, usage,
   session state) — Prompt 3's immersive space is aesthetic, not agentic.
5. A native visionOS IDE from any platform vendor.
6. Any Claude Code **usage/cost metering** surface on visionOS.
7. Any visionOS client from the remote-agent-control field (Conductor, Omnara, Vibe Kanban,
   Sculptor, Happy — see §6).

Items 1, 4, 6 and 7 are Throttle's addressable gap. Item 6 is the one nobody else is even
adjacent to.

---

## 2. Mac Virtual Display on visionOS in 2026

### Specifications **[V]**

From Apple Support (support.apple.com/en-us/118521):

- **Standard**: up to **5K (5120×2880)** on Apple silicon Macs; ~3K cap on Intel Macs.
- **Wide**: up to **3360×1440 points (6720×2880 px)** — added in **visionOS 2.2**, requires
  Apple silicon + macOS Sequoia 15.2+. (Beta 2024-11-04 per 9to5Mac; shipped 2024-12-11 per
  MacRumors.)
- **Ultrawide**: up to **5120×1440 points (10240×2880 px)** — Apple describes it as
  equivalent to **two 5K displays side by side**, enabled by foveated rendering.

### Multiple displays and multiple Macs **[V]**

- The native feature connects to **exactly one Mac at a time**, and shows **only that Mac's
  designated main display**. A second physical monitor attached to the Mac is not exposed.
- Apple engineers were reported demoing an unreleased dual-display capability in
  February 2024 (MacRumors 2024-02-06); **it has never shipped publicly.**
- Third parties fill the gap: **Splitscreen** (adds a 2nd Mac), **MacLink** (up to 3 Macs).

### The structural limit that matters most **[V]**

Both devices must be signed into the **same Apple Account with 2FA**, with iCloud Keychain,
Wi-Fi and Bluetooth on. Per Apple Community guidance the Vision Pro must stay within roughly
**30 feet** of the Mac on the **same Wi-Fi network**.

**Mac Virtual Display is a local-network, same-room feature. It does not work over the
internet or away from the Mac.**

**[I]** This is the whole argument for a native app, and it should be the centre of any
Throttle visionOS positioning. Everything Screens, Splashtop, AnyDesk and Jump Desktop sell
is "from anywhere" — which MVD structurally cannot do.

### Latency and sharpness — genuinely contested **[V]**

- Positive: Apple Community threads report "no perceptible latency… even at distances of
  10 feet" on Apple silicon; TechRadar called Ultrawide "something you have to see to
  believe"; a MacRumors thread is titled "Mac Virtual Display — Definitely the Killer App".
  A MacRumors forum thread on visionOS 2.2 attributes the improvement to foveated rendering
  now running on the Mac.
- Negative: multiple distinct Apple Community threads titled "Excessive Lag", "Virtual
  Display lag in Vision Pro", "Virtual display latency and resolution". Intel MacBook lag
  was described as "pretty distracting" versus M1 being "night and day" better.
- **[I]** Read: on Apple silicon it is good enough that a third-party *pixel-streaming*
  competitor has no room. Do not try to out-stream Apple.

### visionOS 26 and 27 changes

- **[V]** **visionOS 26** (announced WWDC June 2025, shipped fall 2025 — the version in wide
  release today) added, Mac-adjacent: the **macOS Spatial Preview framework** (a Mac app
  pushes spatial photos / Immersive Video / 3D USD straight to Quick Look on Vision Pro, with
  SharePlay) and a redesigned Control Center with a **one-tap Mac Virtual Display connect
  button**. Neither changes MVD's core resolution or session behaviour.
- **[V]** **visionOS 27** (announced 2026-06-08/09, ships fall 2026 — in beta today) adds a
  **Mac Virtual Display accessory widget to launch sessions on locked Macs** (UploadVR
  2026-06-14) and a **Mac 3D Object Preview API**. **[U]** No source found describes any MVD
  resolution or multi-display change in visionOS 27.
- **[V]** visionOS 27 also brings **curved windows** — but **only for Safari, Freeform and
  Apple TV Multiview; it remains a private API third parties cannot use** (UploadVR
  2026-06-14).
- **[V]** **Foveated Streaming framework** (introduced visionOS 26.4, expanded in
  visionOS 27) streams a Mac/PC/cloud workstation's rendered output to the headset with
  eye-tracked foveated compression — described in developer press as turning Vision Pro into
  "a spatial terminal". **[I]** Apple is building the pipe. This helps every remote-display
  app equally; it creates no advantage for anyone and erodes any that existed.

### Does MVD make a third-party "Mac session in the headset" app redundant?

**[I]** For *pixel mirroring*: yes, almost entirely, when you are next to your Mac on your
own Wi-Fi. Do not build that.

**[V/I]** What a native visionOS app can do that Mac Virtual Display cannot:

1. **Work away from the Mac and off its network** — MVD is same-account, same-Wi-Fi, ~30 ft.
   A native app over Tailscale works from a train.
2. **Multiple simultaneous hosts** — MVD does one Mac's one display; a native app can show
   a Mac, a Proxmox LXC and an edge agent side by side (Throttle already has all three).
3. **Semantic content instead of pixels** — a terminal rendered *natively at headset DPI* is
   sharper than the same terminal streamed as pixels, which matters a great deal at 34 PPD.
   This is the strongest technical argument and it is specific to text.
4. **Per-pane spatial placement and window persistence** — MVD is one rectangle; native
   windows can be individually snapped, locked to surfaces and restored (visionOS 26).
5. **Agent-aware chrome** — approvals, diffs, usage meters, ornaments. MVD has no idea what
   is inside the pixels.
6. **Survive the Mac being asleep or absent** — **[U]** Apple's behaviour when the Mac sleeps
   was not verified this session; general expectation is the Mac must be awake and unlocked.
   A Throttle-style architecture where the session lives on a Proxmox edge agent is
   independent of the Mac entirely.
7. **Glanceable widgets and notifications** — a wall-anchored persistent meter widget, and
   gaze-expanding notifications when an agent needs approval.

---

## 3. visionOS platform capabilities for a spatial multi-agent cockpit

### Windows, volumes, immersive spaces

- **[V]** `WindowGroup` has no documented hard cap on simultaneously open windows on
  visionOS; an app can open as many windows as it declares scenes for. The practical
  constraint is SwiftUI's 10-element limit inside a scene builder, worked around with
  `Group`. Multi-scene support requires `UIApplicationSupportsMultipleScenes = true`
  in Info.plist.
  (createwithswift.com "Implementing windows in visionOS"; Apple dev forums thread 740677.)
- **[V]** Only **one immersive space at a time** can be displayed, system-wide across
  all apps. An immersive space is exclusive — opening one hides other apps' shared-space
  content. (Apple docs + createwithswift.com "Exploring immersive spaces in visionOS".)
- **[I]** For a cockpit whose whole point is *many* terminal panes visible alongside
  Safari, Xcode-on-Mac-Virtual-Display, docs, and Messages, the **shared space with
  multiple plain windows is the right container, not an immersive space**. An immersive
  space would evict Mac Virtual Display — which is exactly the thing the user needs
  next to the cockpit. This is a design constraint, not a preference.

### Window persistence and anchoring

- **[V]** visionOS 26 (released 2025-09-15) added persistence for **windowed apps and
  widgets**: windows can be snapped to surfaces or locked from the window controls, and
  are restored in place across reboot. Before visionOS 26 there was essentially no
  persistence across reboots — everything closed.
  (MacRumors 2025-09-15; Six Colors "visionOS 26 Review" 2025-10; Apple docs "Adopting
  best practices for scene restoration".)
- **[V]** Widgets built with WidgetKit can be anchored to walls/surfaces and persist
  across restarts, with customizable frame width, colour and depth.
  (Road to VR, "Apple Details Vision Pro's New Persistent Widget System"; MacRumors 2025-09-15.)
- **[V]** Developer-side, it is **not** possible to programmatically persist and restore
  a window's or volume's *position* from app code — position persistence is a user/system
  affordance, not an API. Developers have filed enhancement requests.
  (Apple dev forums thread 735362 "Restore window positions on visionOS".)
- **[I]** Consequence for a cockpit: **you cannot ship a "save my spatial layout"
  feature** as a first-class app capability. You can persist *which* windows to reopen
  and their content, and let visionOS restore where the user pinned them. Marketing must
  not promise layout save/restore; it can promise "your panes come back with their
  sessions attached".

### Ornaments

- **[V]** Ornaments float alongside a window holding controls without occluding content;
  toolbars and tab bars render as ornaments by default. Custom ornaments use
  `.ornament(visibility:attachmentAnchor:contentAlignment:ornament:)`. Ornaments follow
  the window when it moves. From visionOS 26 an ornament can attach to a **parent
  ornament** via `parent(_:)`.
  (Swift with Majid "visionOS ornaments in SwiftUI"; createwithswift.com "Creating
  Ornaments in visionOS".)
- **[I]** This is the single best fit for Throttle's existing design language: the
  **binding meter, the 5h/7d windows and the per-session status live as an ornament
  under each terminal pane**, always visible, never stealing terminal rows. That is a
  genuinely spatial rendering of a thing that on macOS has to fight for menu-bar space.

### Input: keyboard, trackpad, eye+pinch, dictation

- **[V]** Vision Pro supports Apple Magic Keyboard and **Apple Magic Trackpad**
  (older removable-battery trackpads and third-party trackpads are not supported).
  (Apple Support HT/118516 "Use Bluetooth accessories with your Apple Vision Pro";
  MacRumors Vision Pro Bluetooth accessories guide.)
- **[V]** visionOS 2.5 added **Keyboard Awareness** — a Magic Keyboard or MacBook
  keyboard remains visible inside an immersive environment. (Apple Support 121164.)
- **[V]** Dictation is a first-class text-entry method; visionOS 2 added **Look to
  Dictate** (look at the mic icon to start dictating), and visionOS 2.4+ supports voice
  commands for editing text while dictating. (Apple Support "Enter text and use Dictation
  on Apple Vision Pro".)
- **[V]** visionOS 26 added **Look to Scroll**: look near the edge of a view to scroll it;
  apps opt in with the new `scrollInputBehavior` modifier. Apple positions it as most
  useful for non-interactive content such as text. (Step Into Vision, "Spatial SwiftUI:
  Using Look to Scroll"; Apple dev forums 793858.)
- **[I]** Look to Scroll is a real, free ergonomic win for a **terminal scrollback pane**
  — scrolling a long agent transcript by glance rather than by pinch-drag. It is exactly
  the "non-interactive text" case Apple calls out. Cheap to adopt, distinctive in demo.
- **[I]** The input model settles the product shape: **typing prompts in the headset with
  eye+pinch is not viable for real work**; a paired Magic Keyboard or dictation is
  required. That argues the cockpit's primary input is *supervisory* (approve, steer,
  read, re-prompt short) rather than *authoring*. That is a very good fit for agentic
  coding specifically, and a bad fit for "write code in the headset".

### Text legibility limits

- **[V]** iFixit's teardown estimates Vision Pro at **~34 pixels per degree** average
  (assuming ~100° FOV), versus ~25 PPD for Quest 3 and ~19 PPD for PSVR2, despite a
  physical ~3,380 PPI panel. (iFixit "Vision Pro Teardown Part 2", 2024-02.)
- **[V]** Commentary on that number puts the *angular* resolution roughly equivalent to a
  **1080p 27" monitor viewed from ~24 inches** — i.e. the headset is not a Retina
  substitute for fine text, and reviewers recommend a real 4K/5K display for fine work.
  (Cult of Mac / AppleInsider coverage of the iFixit teardown, 2024-02; kguttag.com
  optics analysis 2024-03-01 argues Vision Pro optics are blurrier/lower-contrast than
  Quest 3 — a dissenting but sourced view.)
- **[V]** Apple's HIG for visionOS: SF Pro is the system font; visionOS uses **bolder**
  Dynamic Type body/title styles than iOS; and Apple explicitly says to **prefer 2D text**
  because visual depth on glyphs hurts readability. (Apple HIG, Typography.)
- **[I]** Direct product consequence: a headset terminal must default to a **larger,
  heavier monospace type than a Mac terminal** — fewer columns, more weight. The honest
  design target is roughly "80 columns, comfortably", not "200 columns because the window
  can be huge". Any pitch built on "infinite screen real estate for code" is fighting the
  angular resolution. The pitch that survives is **fewer, larger, well-placed panes**.

### visionOS 27 (WWDC 2026) — what is and is not available to third parties

Context: **[V]** visionOS 27 was announced 2026-06-08 at WWDC 2026 and Apple said it
ships to all users "this fall" — so as of 2026-09-09 it is in developer beta and
visionOS 26 is the shipping release. (9to5Mac 2026-06-08; MacRumors 2026-06-09;
UploadVR 2026-06-14; AppleInsider 2026-06-08.)

Relevant to a text-heavy productivity app:

- **[V]** **Curved windows** arrive in visionOS 27 — but only for Safari, Freeform and
  Apple TV Multiview. UploadVR states it "remains a private API; third-party developers
  cannot implement curved windows in the Shared Space". (UploadVR 2026-06-14.)
  → **[I]** The most obviously valuable feature for a wide code/terminal surface is
  Apple-only. Plan without it.
- **[V]** **Mac Virtual Display gains an accessory widget to launch sessions on locked
  Macs.** (UploadVR 2026-06-14.)
- **[V]** **Mac 3D Object Preview API** — Mac apps can spawn 3D objects on visionOS,
  editable with gaze-and-pinch, with edits reflected back on macOS; SharePlay supported.
  (UploadVR 2026-06-14.) → **[I]** Not useful for terminals, but it is a signal that
  Apple is building *Mac-app-drives-visionOS-surface* plumbing. Worth watching: a future
  generalisation of that could subsume "Mac app projects a pane into the headset".
- **[V]** **Accessory Widgets** — extra-small widgets (battery, timers, stock prices,
  smart-home). (UploadVR 2026-06-14.) → **[I]** The natural home for a persistent,
  wall-anchored **binding-meter widget** that survives reboot and needs no app window.
- **[V]** **Gaze-expanding notifications** — notifications expand on gaze without a pinch.
  (UploadVR 2026-06-14; MacRumors 2026-06-09.) → **[I]** Directly relevant: an agent
  finishing or asking for approval is a notification; expanding it by looking at it is
  the lowest-friction supervision loop the platform offers.
- **[V]** **Device Hub in Xcode 27** lets developers remotely launch an experience on
  Vision Pro. (UploadVR 2026-06-14.) → **[I]** Reduces the dev-loop pain of building for
  a device you have to keep putting on.
- **[V]** Other visionOS 27 additions (held-object tracking, IR-LED tracked-accessory
  framework, Gaussian splats, cloth sim, reverb mesh, spatial panoramas, unfoveated
  4K recording up to 3 min, spatial Siri with Visual Intelligence, redesigned Control
  Center, improved Dwell Control). (UploadVR 2026-06-14; AppleInsider 2026-06-08;
  MacRumors 2026-06-09.) → **[I]** None of these move the needle for a coding cockpit.
  The 2026 visionOS release is a media/AI/accessory release, not a productivity release.

### SharePlay

- **[V]** visionOS 26 added shared spatial experiences for multiple people in the same
  room; existing SharePlay apps work without additional code, and Quick Look allows
  handing off virtual objects during SharePlay. (Apple newsroom 2025-06;
  MacRumors 2025-09-15.)
- **[I]** For a solo-dev product this is a demo feature, not a revenue feature. Pair
  programming inside headsets requires two Vision Pros in one room. Deprioritise.

### Networking and background — what a Throttle visionOS app may legally do

- **[V]** visionOS supports Bonjour service discovery and the standard local-network
  privacy flow (`NSLocalNetworkUsageDescription` + `NSBonjourServices`), the same as iOS.
  Third-party DNS-SD browsers ship on visionOS 1.0+. (Nonstrict, "Request and check local
  network permission on iOS and visionOS", 2024; App Store listing for Discovery —
  DNS-SD Browser, visionOS 1.0+.)
  → **[V/I]** This matters because it means **Throttle's existing Bonjour + TLS-PSK peer
  transport needs no special entitlement on visionOS.** Local-network *usage* is a
  privacy prompt, not the restricted **multicast entitlement** (which is required only
  for raw multicast/broadcast beyond Bonjour). Throttle already ships `_throttle._tcp`
  via NSBonjourServices in the visionOS Info.plist, which is the permitted path. [I on
  the entitlement boundary — verified only that Bonjour-based discovery works without
  one, not an Apple statement that multicast entitlement is never needed.]
- **[V]** Push notifications reach Vision Pro whether the app is open, backgrounded or
  closed, via APNs. (Apple Support "See and open your notifications on Apple Vision Pro";
  Pushwoosh visionOS SDK docs.)
- **[U]** **ActivityKit / Live Activities on visionOS: unverified.** A third-party SDK
  vendor's documentation asserts Live Activities are supported on Vision Pro, but I could
  not confirm this against Apple's ActivityKit availability line before exhausting the
  session's web-search budget. **Do not plan a visionOS Live Activity without checking
  ActivityKit's availability annotation in the SDK first** — this is a one-minute check
  in Xcode and it gates a real feature (long-running agent progress on the glance layer).

### App Review risk for a remote-terminal app

- **[V]** Guideline **2.5.2** requires apps to be self-contained and forbids downloading,
  installing or executing code. It has been enforced against shell apps: **iSH** was found
  non-compliant because it "is not self-contained and has remote package updating
  functionality", and Apple suggested removing remote network functionality that could
  allow remote code import (wget/curl-like). (Apple App Review Guidelines; Michael Tsai,
  "iSH and a-Shell vs. the App Store", 2020-11-09.)
- **[I]** Throttle's shape is **materially safer than iSH's**: it executes nothing
  locally. It renders an octet stream from a PTY that is already running on the user's own
  Mac, attached per-session over an authenticated channel. That is the same category as
  every shipping SSH client and remote-desktop app, which Apple has approved for years.
  The risk is real but low, and it is reduced further by: never spawning a process from
  the headset, requiring Mac-side confirmation for first attach, and describing the app
  as a remote *viewer/controller* of the user's own machine.
- **[I]** The genuinely risky move would be shipping a *hosted* agent the app talks to,
  or any path where the headset can cause arbitrary new code to run on a machine the user
  did not pre-authorise. Throttle's existing doctrine (the Mac only accepts an attach for
  a session already spawned there; the app never SSHes or deploys) is the correct
  guardrail and should be stated in the review notes.

---

## 4. Ergonomic and human-factors limits for long coding sessions in a headset

This is the section that most constrains the product, and the evidence is unusually
clear and unusually unfavourable.

### Apple's own guidance is the ceiling

- **[V]** Apple Support, *How to safely use your Apple Vision Pro*: **"As you become
  acclimated to using Vision Pro, take a break every 20 to 30 minutes, then adjust the
  time based on your comfort level."** It also tells users to stop immediately on eye
  strain, headache, or blurred/double vision.
  (https://support.apple.com/en-us/118507)
- **[I]** Apple's own vendor guidance describes a **20–30 minute working unit**. Any
  product pitched as "your all-day IDE" is contradicting the manufacturer. A product
  pitched as *"check in on your agents, steer them, take the headset off"* is aligned
  with it. That is a design constraint with a marketing consequence.

### Weight

- **[V]** Apple's current specs page lists Vision Pro (M5) at **26.4–28.2 oz
  (750–800 g)** including Light Seal and band; the tethered battery is a further **353 g**
  off-head. (https://www.apple.com/apple-vision-pro/specs/)
- **[V]** Earlier outlets (Macworld, MacRumors, Jan 2024) cited **600–650 g** for the
  launch unit. **[U]** The discrepancy between the 2024 figures and the current
  750–800 g spec is **not reconciled** by the sources found — it may be a
  configuration/measurement-basis difference. Do not quote a single weight as settled.
- **[V]** The **M5 Vision Pro** shipped 2025-10-22 at $3,499 with a new **Dual Knit
  Band** (3D-knitted, tungsten counterweight in the lower strap), 10% more rendered
  pixels, up to 120 Hz (from 100 Hz), ~2.5–3 h battery.
  (Apple Newsroom 2025-10-15; 9to5Mac 2025-10-15.)
- **[V]** Reviewers report the Dual Knit Band feels "noticeably lighter" despite being
  ~150 g heavier than the Solo Knit, because of balance. (MacDailyNews 2025-10-23;
  UploadVR hands-on; iPhone J.D. review 2025-11.)

### Legibility and eye load

- **[V]** iFixit: ~**34 PPD average**, **~44.4 PPD peak centre**, against the ~80 PPD
  Apple internally calls "retinal". An iPhone 15 Pro Max at one foot averages ~94 PPD.
  (iFixit, "Vision Pro Teardown Part 2", 2024-02.)
- **[V]** VR text-legibility literature: Wang et al. (IEEE VRW 2020) recommend **≥12 pt
  at 0.5 m**; Borg et al. (2015) recommend 5–17 dmm standing and ≥9 dmm walking; text
  rotated ≥60° needs substantially larger sizes; users prefer larger text in the
  periphery than in the centre. (IEEE Xplore 9090496; Springer multivocal review
  10.1007/s10055-024-00949-6.)
- **[U]** No study isolating **foveated rendering's effect on text legibility** was found.
  Gap, not a refutation.
- **[V]** Vergence–accommodation conflict is established peer-reviewed display science:
  outside the zone of comfort it increases time-to-fixate, degrades stereoacuity and
  causes visual fatigue. (Hoffman et al., *Journal of Vision*, 2008; PubMed 18484839.)
- **[V]** A 2025 tear-film study (*Nature Scientific Reports*, n=14, 30-min VR session)
  found lipid-layer interference grade and ocular surface temperature both rose over the
  session, consistent with heat-driven tear evaporation.
  (https://www.nature.com/articles/s41598-025-16634-w)
  **[U]** Blink-rate direction under VR is **contested** across sources; do not assert it.

### The one direct experiment on working in VR for a week

- **[V]** Biener, Grubert et al., *Quantifying the Effects of Working in VR for One Week*
  (arXiv:2206.03189, June 2022; later IEEE TVCG). **n=16**, **8 hours/day for 5 days**
  (40 hours), against a physical-desktop baseline. The VR condition was **significantly
  worse on task load, frustration, negative affect, anxiety, eye strain, system usability,
  flow, self-rated productivity, well-being and simulator sickness**. **2 of 16 (12.5%)
  dropped out on day one** with migraine, nausea and anxiety. Some measures improved
  modestly over the week — weak adaptation, not resolution.
  Caveat **[V]**: this predates Vision Pro and used earlier-generation HMDs, so it is
  evidence about VR knowledge work in general, not about Vision Pro specifically.
- **[I]** This is the most important single citation in this report. It is the closest
  thing to a controlled test of the exact proposition "do your day job in a headset", and
  it came out clearly against. A responsible product built on this platform should be
  designed for **short, high-value visits**, not for displacing the desk.

### Field reports from people who actually tried it

- **[V]** Stephen Robles, *One Year with Apple Vision Pro* (beard.fm, 2025-02-02):
  "I vastly prefer working on my Studio Display. I feel much faster, and I don't have to
  wear something heavy on my face to do it." Comfort/eye strain onset after "a couple
  hours". **~50 uses in 12 months** (~$87/session amortised).
- **[V]** Hacker News, *Ask HN: Is anyone working at least 4 hours daily on an Apple
  Vision Pro?* (June 2026, item 48275508) — genuinely split. Pro: *oreb* ~8 h/day while
  travelling ("noise-cancelling headphones for the eyes"); *f7f7f7* 4+ h/day for over a
  year with no eye strain; *peroids* 8+ h/day and now prefers it to monitors. Con:
  *elisbce* — weight alone is a dealbreaker; *BoorishBears* — lens/FOV quality can't
  replace monitors; *porcoda*/*ladberg* — sustainable for 4 h in constrained settings
  (planes, trains) but they prefer real screens otherwise.
- **[V]** dev.to, *I tried the Apple Vision Pro as a Developer* — would not recommend it
  for coding/design today: no native VS Code, roughly double the time to do anything,
  impractical for multi-hour work.
- **[I]** The pattern across the positive reports is decisive and useful: the enthusiasts
  are almost all describing **constrained contexts** — travelling, planes, no desk, no
  monitors, privacy needed. That is the real market. It is not "replace your Studio
  Display"; it is "the 8 hours where you don't have your Studio Display".

### Adoption

- **[V]** IDC-sourced estimates: ~**390,000 units in 2024**, falling to ~**45,000 in
  Q4 2025** and roughly **80,000–90,000 for full-year 2025**.
  (MacRumors 2026-01-02; iPhoneinCanada 2026-01-01.)
- **[V/reported]** Apple reportedly cut Vision Pro digital ad spend by **>95%** in key
  markets in 2025 and slashed production via Luxshare. (Hypebeast 2026-01;
  MacDailyNews 2026-01-02.) Reported, not Apple-confirmed.
- **[U]** Cumulative installed base ~475,000–500,000, and a claim that enterprise is
  ~75% of purchases with 50+ Fortune 100 orgs — **single unverified aggregator source**.
  Do not use these numbers publicly.
- **[V]** Counterpoint: the standalone VR/MR headset category contracted **14% YoY in
  H1 2025** (cited secondhand via Treeview; primary Counterpoint page not reached).

---

## 5. App Store realities for visionOS in 2026

### Catalogue size — the honest answer is that nobody credible has published a 2026 number

- **[V]** 2024-02-13, Apple (Greg Joswiak): **"over 1,000" native visionOS apps**,
  two weeks after launch. (AppleInsider / 9to5Mac 2024-02-13.)
- **[V]** 2024-01-26, Appfigures: ~**300** apps "built for" Vision Pro pre-launch, against
  1M+ total App Store apps available (because visionOS runs iOS/iPadOS apps largely
  unmodified); **305,000 apps opted out** of visionOS availability. Utilities,
  Productivity, Entertainment, Education and Health & Fitness were ~50% of native apps.
- **[V]** 2024-04-05, Appfigures: **523 Vision-only native apps**, plus **1,288** existing
  iOS apps that added Vision support. Native submissions spiked pre-launch (73 → 82 → 150
  per week) then fell "exponentially" after launch. **~50% of Vision-only apps are paid,
  versus ~4% paid across the App Store overall.**
- **[U]** Every 2026 figure found (**~3,000** / **4,200** / **12,000** visionOS apps) traces
  only to unattributed aggregator/SEO blogs, and they are mutually inconsistent. **None is
  usable.** Apple appears not to have published a native-app count since February 2024 —
  itself a signal.
- **[I]** The two Appfigures data points are the only trustworthy shape we have, and the
  shape is: a small native catalogue, a post-launch collapse in new native submissions,
  and an audience that is **an order of magnitude more willing to pay for apps than the
  general App Store**. That last number (50% paid vs 4% paid) is the single most
  encouraging fact in this entire report for a paid pro tool.

### What sells, and at what price

- **[V/partial]** Named apps with prices found: **Juno** (YouTube client by Christian
  Selig) at **$4.99**; **AmazeVR Concerts** around **$13**; **ChatGPT** on visionOS
  requires a **ChatGPT Plus subscription ($20/month)** because the free tier isn't
  available there. These came from secondary sources and were **not** re-verified against
  live App Store listings — treat the exact figures as soft.
- **[V]** Productivity apps present on the platform include SAP Analytics Cloud,
  Microsoft 365 (Word/Excel/Teams), Zoom, Webex and Fantastical — mostly
  account-level-subscription products, not visionOS-priced.
- **[U]** A claim of "**average visionOS app ~$14,800 net revenue in Feb 2026, ~3x other
  platforms**", attributed to Sensor Tower, **could not be traced to any actual Sensor
  Tower report**. Possible search-summarisation artifact. **Do not repeat it.**
- **[U]** No named indie developer publicly disclosing real visionOS revenue was found.
  Genuine evidence gap.
- **[V/opinion]** vrc.org.au (2026-03-27) models a hypothetical: 5% of an installed base
  under 500,000 discovering your app, 10% converting at $9.99 → ~$25,000 gross, and
  concludes visionOS "is not a main revenue pillar" for indies in 2026. This is the
  author's illustrative arithmetic, **not measured data**, but the arithmetic is sound.

### Discovery and the value of being early

- **[U]** No rigorous, dated study of visionOS App Store discovery mechanics was found;
  what exists is ASO-agency marketing content. Treat "editorial featuring matters" as
  folklore, not evidence.
- **[V/indirect]** The Appfigures submission spike (73 → 150/week) was explicitly driven
  by developers chasing day-one category placement — evidence that developers *believed*
  early mattered, not that it paid.
- **[I]** With a native catalogue this small and a category ("developer tools on
  visionOS") this empty, being early plausibly still buys the top slot on a search for
  "claude", "terminal", "agent" or "coding" on the visionOS store — but the top slot in a
  category nobody browses is worth very little. **Early matters for credibility and press,
  not for volume.**

---

## 6. Competitive risk

### Apple

- **[V]** Xcode does not and cannot run on visionOS; it runs on macOS only.
- **[V]** 2026-02-03: **Apple and Anthropic shipped Xcode 26.3 with a native Claude Agent
  SDK integration** — full Claude Code functionality (subagents, background tasks,
  plugins) inside Xcode on the Mac, via MCP. Anthropic's own framing mentions building
  "from iPhone to Mac to Apple Vision Pro" — i.e. Vision Pro as a *build target*, not as a
  place the agent runs. (anthropic.com/news/apple-xcode-claude-agent-sdk; VentureBeat.)
- **[V]** WWDC 2025 (visionOS 26) and WWDC 2026 (visionOS 27) shipped **no** coding or
  developer-surface features for the headset. visionOS 27 is a media/AI/accessory release.
- **[V]** **Foveated Streaming framework** (introduced visionOS 26.4, expanded in
  visionOS 27) streams a Mac/PC/cloud workstation's rendered output to the headset with
  eye-tracked foveated compression. Developer press describes it as turning Vision Pro
  into "a spatial terminal". (UploadVR 2026-06-14; blakecrosley.com.)
  **[I]** This is **the most consequential platform fact in this report after the
  ergonomics.** It is Apple building the *pipe*, not the product. It lowers the cost of
  high-quality remote rendering for everyone — including Throttle — but it equally lowers
  it for La Terminal, Blink, Termius and anyone else. It is a tailwind that erases a moat,
  not one that creates one.
- **[V]** **Spatial Preview framework** (visionOS 27) lets a Mac app push content to a
  Vision Pro's Quick Look **without a dedicated visionOS app**.
  **[I]** Watch this. If Apple generalises "a Mac app projects a pane into the headset",
  the entire premise of a separate visionOS binary weakens.
- **[V]** Hardware trajectory is against the category: the **cheaper/slimmer Vision Pro
  successor is now reported for late 2028** (MacRumors 2026-06-01), and Apple's reported
  near-term wearable priority is **smart glasses (N50), unveiling WWDC 2027, shipping late
  2027** — a camera/mic/speaker/Siri device explicitly *not* spatial computing
  (MacRumors 2026-05-31; 9to5Mac 2026-05-31).
  **[I]** Glasses cannot run a coding cockpit. So Apple is unlikely to sherlock this — and
  equally unlikely to grow the market you'd be building for. Low platform risk, low
  platform upside.

### Anthropic

- **[V]** **No Claude app on visionOS.** A GitHub request to allow the Claude iPad app on
  Vision Pro (claude-code issue #12608) was **closed as "not planned"** with no maintainer
  response.
- **[V]** Anthropic's actual 2026 remote surfaces are phone and web, not headset:
  **Remote Control** (shipped 2026-02-25) bridges a local terminal session to claude.ai/code
  and the Claude iOS/Android apps for monitoring, approving and steering; **Teleport** pulls
  a cloud session down into a local terminal. (TechRadar; docs.bswen.com 2026-03-30.)
  **[I]** This is Throttle's known first-party threat — already logged in memory as the
  "Anthropic Remote Control threat" (2026-07-14). It commoditises *remote supervision of a
  Claude Code session from a phone*. It does not touch visionOS. But an app whose visionOS
  value proposition is "supervise your agent from elsewhere" is building on a beach that
  Anthropic already owns on the phone.

### OpenAI and others

- **[V]** OpenAI shipped a **ChatGPT app for Vision Pro on 2024-02-02** — a general chat
  assistant, not a coding cockpit.
- **[V]** **Codex is macOS/Windows desktop + cloud sandbox** (macOS app 2026-02-02, Windows
  2026-03-04). No visionOS mention anywhere.
- **[V]** No evidence found that Cursor, GitHub Copilot Workspace, Devin/Cognition, Replit
  or Warp has shipped, announced or previewed anything for visionOS or Quest. GitHub
  "Copilot Vision" (GA 2026-07-01) is image/PDF attachment in chat, unrelated to headsets.

### The remote-agent-control field (all phone/web, none on visionOS)

- **[V]** **Conductor** (MeriaApp) — native macOS parallel Claude Code/Codex orchestration
  with git worktrees; free today, Pro (~$50/mo) and Teams (~$60/user/mo) announced.
  **Omnara** (YC S25) — voice-first remote control via iOS, web and Apple Watch; free tier
  plus paid. **Vibe Kanban** — free/OSS web dashboard for parallel agents. **Happy /
  happy-coder** — free/OSS E2E-encrypted mobile+web Claude Code and Codex client with
  realtime voice. **Sculptor** (Imbue) — free/MIT desktop UI for parallel containerised
  agents. **Terragon Labs — shut down 2026-01-16**, repo archived.
- **[V]** **None of them has a visionOS client.**
- **[I]** Two readings. Optimistic: the visionOS lane is genuinely empty. Pessimistic:
  a dozen well-funded teams looked at the same platform and none thought it was worth a
  build. Given §4 and §5, the pessimistic reading is better supported.

### The real competitor: terminals that already ship on visionOS

- **[V]** **La Terminal** — built "from the ground up… a first-class spatial computing
  experience for command-line hackers on Vision Pro", a **day-one Vision Pro launch app**
  (2024), with AI command assistance, resource monitors and an immersive UI.
  (la-terminal.net; Product Hunt.)
- **[V]** **Blink Shell** — visionOS 1.3+, full emulation, Mosh, SSH, Secure Enclave keys.
  **Termius** — visionOS 1.0+. **Prompt** (Panic) — one subscription across
  iPad/iPhone/Mac/Vision Pro.
- **[V]** **None of them has built agent-specific chrome** — approvals, live diffs, usage
  meters, per-session state. They are general terminals that can `ssh` to a box running
  `claude`.
- **[I]** This is simultaneously the opportunity and the risk, and it should be stated
  plainly: **the gap is real, and it is a weekend of work for any of them to close.**
  Throttle's defensibility on visionOS is not the terminal — SwiftTerm is public and they
  already ship terminals. It is the **usage meter, the Mac-side session model, the
  pairing, and the agent-aware chrome** that already exist in the Throttle codebase and
  do not exist in theirs. That is a head start measured in months, not a moat.

### Read-across from other headset productivity bets

- **[V]** **Sightful cancelled the Spacetop G1 AR laptop** after "overwhelming feedback",
  pivoting to software-only on Windows AI PCs. (Road to VR.)
- **[V]** **Meta discontinued Horizon Workrooms** as a standalone app effective
  **2026-02-16**, folding it into general platform features; Reality Labs cut ~10%
  (1,000+ jobs). (Road to VR; Meta Help 2464765133873078.)
- **[V/soft]** **Immersed** is reported as the surviving leader in VR productivity with
  1.5M+ users across Quest, Vision Pro and Pico, plus its own headset ("Visor") and an AI
  assistant ("Curator"). **[U]** These figures come from an aggregator, not from Immersed
  or a research firm — corroborate before quoting.
- **[I]** The pattern is consistent and worth internalising: **native immersive workspaces
  have failed twice (Workrooms, Spacetop); "use the headset as extra screens for the
  computer you already own" is the pattern that survived (Immersed, Mac Virtual Display).**
  A Throttle cockpit that *extends the Mac you already own* is on the surviving side of
  that line. A Throttle cockpit that tries to *be* the workstation is on the dead side.


---

## What Throttle already has (repo state, verified in this worktree 2026-09-09)

This determines the effort estimates below. All verified by reading the tree at
`/Users/kevinnadjarian/GitHub/Throttle/build/integration-3.6.0`:

- **`ThrottleVision/` target exists and builds.** `project.yml:341` — platform visionOS,
  `deploymentTarget: "26.0"`, bundle `com.lorislab.throttle.vision`, category
  `public.app-category.developer-tools`. Sources are `ThrottleVision/` plus
  `ThrottleiOS/Services` (minus `EdgeSessionsService.swift`) plus `MirrorUI.swift`.
- **It is only 194 lines.** `ThrottleVisionApp.swift` (18), `VisionAppDelegate.swift` (35),
  `VisionCockpitView.swift` (141). A single plain `WindowGroup` at 900×620 showing a
  read-only meter, two window plates, three stats and a session grid. Doctrine comment in
  the file still says *"measure-only, no remote control"*.
- **CI already builds it.** `.github/workflows/ci.yml:101` — a `visionos-build` job on
  `macos-26`, Release, `generic/platform=visionOS Simulator`, with evidence artefacts.
  (Simulator only — explicitly not device or App Store acceptance.)
- **The terminal stack already exists on iOS and is UIKit-based**, so it is portable:
  `ThrottleiOS/Views/RemoteTerminalView.swift` (a `UIViewRepresentable` over SwiftTerm),
  `TerminalHost.swift`, `TerminalAccessory.swift`, `EdgeTerminalView.swift`,
  `Services/TerminalLockState.swift`, `Services/EdgeSessionsService.swift`.
- **SwiftTerm supports visionOS.** Its `Package.swift` declares `visionOS(.v1)`. Throttle
  already depends on it for the iOS target (`project.yml:304`).
- **Networking is already correct for visionOS.** `ThrottleVision/Info.plist` already
  declares `NSBonjourServices: _throttle._tcp` and `NSLocalNetworkUsageDescription`;
  entitlements carry CloudKit, the app group and `aps-environment`. No restricted
  entitlement is involved.
- **`ThrottleShared/Package.swift` declares only `.macOS(.v14), .iOS(.v17)`** — it builds
  for visionOS today by inheritance, but the platform is not declared explicitly.
- **The design is already written.** `docs/remote-terminal-design.md` explicitly scopes the
  remote terminal to "the phone (and visionOS)", and its increments 1–3 (protocol frames,
  Mac PTY bridge, iOS SwiftTerm client) are the exact substrate a visionOS cockpit needs.

**[I]** The honest summary: **the visionOS app is a stub of the read-only mirror, and the
hard parts (transport, pairing, PTY bridge, terminal rendering) are already shipped on
another surface in the same repo.** That is why the moves below are cheap. It is also why
they are not a moat.

---

## Ranked product moves for Throttle

Ordered by (value ÷ effort), with the risk that actually matters for each. Effort is in
solo-developer days of focused work, assuming the existing codebase.

### 1. Port the iOS terminal into ThrottleVision — "supervise, don't author"

**Effort: 3–5 days. Risk: low.**

Add `SwiftTerm` to the `ThrottleVision` target, bring `RemoteTerminalView`, `TerminalHost`,
`TerminalAccessory` and `TerminalLockState` across, and open **one `WindowGroup` per attached
session** so each agent is its own draggable pane in the shared space. Keep the existing
meter as the app's home window.

Why first: it converts a stub into the only agent-aware terminal on the platform, it reuses
code that is already written and already reviewed, and it is the minimum that makes the app
worth a screenshot. **[V]** It also does not need an immersive space — which matters,
because an immersive space would evict Mac Virtual Display, and Immersed is a documented
cautionary tale of exactly that (it "cannot run alongside other visionOS apps").

Risks: **[V]** App Review guideline 2.5.2 has been enforced against shell apps (iSH, 2020).
Mitigate in the review notes: the app executes nothing, spawns nothing, and only attaches to
a PTY already running on the user's own Mac over an authenticated, pre-paired channel — the
same shape as every approved SSH client. **[I]** Also: type must be larger and heavier than
on the Mac; target ~80 comfortable columns, not maximum density.

### 2. Type and ergonomics pass tuned to 34 PPD

**Effort: 1–2 days. Risk: very low.**

Set a visionOS-specific monospace default at a size chosen against the legibility evidence
(**[V]** ~34 PPD average / ~44 peak, vs ~80 for "retinal"; VR literature recommends ≥12 pt
at 0.5 m), prefer heavier weights per Apple's HIG note that visionOS uses bolder Dynamic
Type, and keep all text strictly 2D (**[V]** HIG: "prefer 2D text… the more visual depth
text characters have, the more difficult they can be to read").

Then adopt **Look to Scroll** (`scrollInputBehavior`, visionOS 26) on the terminal scrollback
— **[V]** Apple positions it precisely for non-interactive text. Scrolling a long agent
transcript by glance is the cheapest genuinely-spatial moment in the whole product and it
demos well.

Risk: essentially none. This is the highest confidence-per-hour item in the list.

### 3. The binding meter as an ornament, and as a persistent widget

**Effort: 2–3 days (ornament) + 2–3 days (WidgetKit). Risk: low.**

**[V]** Ornaments float beside a window without occluding it and follow it when it moves;
toolbars already render as ornaments. Put the utilisation ring, the 5h/7d windows and the
per-session state in a **bottom ornament under each terminal pane** — status that costs zero
terminal rows, which is the thing that is genuinely better in a headset than on a Mac.

Then ship a **WidgetKit spatial widget** for the meter. **[V]** visionOS 26 widgets anchor to
walls or surfaces and persist across reboots; visionOS 27 adds extra-small Accessory Widgets.
A binding meter pinned to the wall of the room, visible with no app open, is the single most
defensible "why is this on a headset" artefact Throttle could ship — and **[V]** no competitor
on the platform has any usage-metering surface at all.

Risk: **[V]** developers *cannot* programmatically persist window positions — persistence is a
user affordance. So never market "saves your layout". Market "your meter stays on the wall",
which is true.

### 4. Approval loop via notifications

**Effort: 2–3 days. Risk: low, with one thing to verify first.**

**[V]** Push notifications reach Vision Pro whether the app is open, backgrounded or closed;
`aps-environment` is already in the entitlements. **[V]** visionOS 27 adds **gaze-expanding
notifications** — a notification expands by looking at it, no pinch. An agent asking for
approval is exactly that shape: glance, read, approve, look away.

**[U] Verify first:** ActivityKit / Live Activities availability on visionOS could not be
confirmed this session (only a third-party SDK vendor's doc asserts it). **Check the
`@available` annotation on ActivityKit in Xcode before planning a visionOS Live Activity** —
it is a one-minute check and it gates whether long-running agent progress can live on the
glance layer.

### 5. Position explicitly against Mac Virtual Display's blind spot

**Effort: 1 day (copy, screenshots, listing). Risk: low, but it is the whole story.**

**[V]** MVD is same-Apple-Account, same-Wi-Fi, ~30 feet, one Mac, one display. Every word of
Throttle's visionOS listing should live in that gap: *supervise the agents running on the
Mac you are not sitting at.* Lead with multi-host (Mac + Proxmox edge agent), with native
text sharpness rather than streamed pixels, and with the usage meter.

**[I]** Do not claim to replace Mac Virtual Display. The correct pitch is that Throttle's
panes sit **beside** it: MVD for Xcode, Throttle panes for the agents. That is also the
honest workflow.

### 6. Declare visionOS in `ThrottleShared/Package.swift`, add a device gate to CI

**Effort: half a day. Risk: none.**

`platforms:` currently lists only macOS and iOS. Add `.visionOS(.v1)` (or 26) so the
dependency graph is explicit rather than accidental. **[V]** CI already builds
ThrottleVision on the simulator; per repo doctrine that is explicitly *not* device or App
Store proof, so the device validation gate stays open and should stay named as open.

### 7. SharePlay pair-supervision — **do not build**

**Effort: 5+ days. Risk: high. Recommendation: skip.**

**[V]** visionOS 26 shared spatial experiences require multiple Vision Pros, and existing
SharePlay apps work without extra code. **[I]** For a solo dev selling to individual
developers, this is a demo you cannot afford to maintain for an audience of approximately
zero. Revisit only if an enterprise buyer asks and pays.

### 8. An immersive-space "cockpit environment" — **do not build**

**Effort: 10+ days. Risk: high. Recommendation: skip.**

**[V]** Only one immersive space can exist system-wide, so entering one evicts Mac Virtual
Display and every other app. **[V]** Immersed is documented as suffering exactly this. **[V]**
The visually appealing alternative — curved windows — is a **private API** in visionOS 27
that third parties cannot use. **[I]** Prompt 3's "Terminal 33" is the ceiling here, and it
is aesthetic, not functional. Spend the ten days on the Mac product.

### 9. Repositioning Throttle as a Vision Pro product — **do not do**

**Risk: high, and it is the strategic error the rest of this report exists to prevent.**

**[V]** ~80–90k units in 2025 (down from 390k); ad spend reportedly cut >95%; cheaper model
pushed to late 2028; Apple's 2027 wearable is smart glasses, which cannot run this UI. **[V]**
Working-in-VR evidence is negative (Biener et al., n=16, 40 hours: significantly worse eye
strain, task load and productivity; 12.5% day-one dropout). **[V]** Apple's own guidance is a
break every 20–30 minutes.

Ship the cockpit as a **bundled free surface of the Mac app**, priced at zero, positioned as
proof that Throttle is the most complete Claude Code cockpit on Apple platforms. **[V]** The
one number that argues for more than that — ~50% of Vision-only apps are paid vs ~4%
store-wide (Appfigures, 2024-04) — justifies *making it good*, not *betting on it*.

---

## Open questions and verification gates

Things this report could not close. None should be asserted publicly until checked.

1. **[U] ActivityKit on visionOS** — gates move #4's glance layer. Check the `@available`
   line in Xcode. One minute.
2. **[U] JarVS's price, traction and exact feature set** — the closest competitor, and its
   App Store page was rate-limited. Buy it and use it before designing move #1's window model.
3. **[U] Does Mac Virtual Display work while the Mac sleeps?** Determines how strong the
   "works when the Mac is away" claim can be. Testable in ten minutes with a headset.
4. **[U] Every 2026 visionOS app-count figure** (3,000 / 4,200 / 12,000) is unattributed and
   mutually inconsistent. The last trustworthy data points are Appfigures, April 2024.
   Do not quote a 2026 catalogue size.
5. **[U] The "Sensor Tower $14,800 average visionOS app revenue" figure could not be traced
   to any Sensor Tower report.** Treat as probably spurious. Never repeat it.
6. **[U] Vision Pro weight** — Apple's current spec says 750–800 g; 2024 outlets said
   600–650 g. Unreconciled. Quote Apple's page or nothing.
7. **[U] Immersed's "1.5M+ users"** comes from an aggregator, not from Immersed. Corroborate
   before using it as evidence the niche is viable.
8. **[U] No named indie developer's actual visionOS revenue was found** — positive or
   negative. A genuine evidence gap, not a finding of absence.
9. **[I→verify] App Review** — the 2.5.2 read is my inference from the iSH precedent plus the
   existence of approved SSH clients. If move #1 proceeds, write the review note first and
   consider a pre-submission question to App Review.
10. **[V→watch] Apple's Spatial Preview / Foveated Streaming frameworks.** If Apple
    generalises "a Mac app projects a pane into the headset", the case for a separate
    visionOS binary weakens considerably. Re-check at WWDC 2027.

---

## Sources

### Platform and Apple primary
- Apple Support — How to safely use your Apple Vision Pro: https://support.apple.com/en-us/118507
- Apple Support — Use your Mac with Apple Vision Pro: https://support.apple.com/en-us/118521
- Apple Support — Use Mac Virtual Display: https://support.apple.com/guide/apple-vision-pro/use-mac-virtual-display-tan357ede966/visionos
- Apple Support — Use Bluetooth accessories with Apple Vision Pro: https://support.apple.com/en-us/118516
- Apple Support — Enter text and use Dictation on Apple Vision Pro: https://support.apple.com/guide/apple-vision-pro/enter-text-and-use-dictation-tana14220eef/visionos
- Apple Support — About visionOS 2 Updates: https://support.apple.com/en-us/121164
- Apple — Vision Pro Technical Specifications: https://www.apple.com/apple-vision-pro/specs/
- Apple Newsroom — visionOS 26 (2025-06): https://www.apple.com/newsroom/2025/06/visionos-26-introduces-powerful-new-spatial-experiences-for-apple-vision-pro/
- Apple Newsroom — Vision Pro upgraded with M5 (2025-10-15): https://www.apple.com/newsroom/2025/10/apple-vision-pro-upgraded-with-the-m5-chip-and-dual-knit-band/
- Apple Developer — WWDC26 visionOS guide: https://developer.apple.com/wwdc26/guides/visionos/
- Apple Developer — Adopting best practices for scene restoration: https://developer.apple.com/documentation/visionos/adopting-best-practices-for-scene-restoration
- Apple Developer Forums 744427 (Xcode cannot run on visionOS): https://developer.apple.com/forums/thread/744427
- Apple Developer Forums 735362 (cannot restore window positions): https://developer.apple.com/forums/thread/735362
- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/

### visionOS 26 / 27 coverage
- UploadVR — visionOS 27 is a much bigger update (2026-06-14): https://www.uploadvr.com/visionos-27-announced-apple-vision-pro-wwdc-26/
- 9to5Mac — visionOS 27 announced (2026-06-08): https://9to5mac.com/2026/06/08/visionos-27-announced-with-new-features-for-vision-pro/
- MacRumors — visionOS 27: Siri AI, eye-aware notifications, curved windows (2026-06-09): https://www.macrumors.com/2026/06/09/visionos-27-siri-ai-eye-aware-notifications/
- AppleInsider — visionOS 27 (2026-06-08): https://appleinsider.com/articles/26/06/08/spatial-computing-apple-intelligence-upgrades-collide-in-visionos-27
- blakecrosley.com — What's new in visionOS 27 for spatial devs: https://blakecrosley.com/blog/whats-new-visionos-27
- MacRumors — Apple releases visionOS 26 (2025-09-15): https://www.macrumors.com/2025/09/15/apple-releases-visionos-26/
- Six Colors — visionOS 26 review (2025-10): https://sixcolors.com/post/2025/10/visionos-26-review-keep-moving-toward-the-future/
- Road to VR — visionOS 26 persistent widget system: https://www.roadtovr.com/apple-vision-pro-visionos-26-persistent-widgets/
- 9to5Mac — visionOS 2.2 Wide/Ultrawide MVD (2024-11-04): https://9to5mac.com/2024/11/04/visionos-2-2-adds-new-wide-and-ultrawide-settings-for-mac-virtual-display/
- MacRumors — visionOS 2.2 released (2024-12-11): https://www.macrumors.com/2024/12/11/apple-releases-visionos-2-2/
- MacRumors — Apple engineers with two Mac displays (2024-02-06): https://www.macrumors.com/2024/02/06/vision-pro-virtual-display-multiple-macs/
- Apple Developer video — Spatial Preview framework (WWDC26 session 287): https://developer.apple.com/videos/play/wwdc2026/287/

### SwiftUI / visionOS development
- createwithswift.com — Implementing windows in visionOS: https://www.createwithswift.com/implementing-windows-in-visionos/
- createwithswift.com — Exploring immersive spaces in visionOS: https://www.createwithswift.com/exploring-immersive-spaces-in-visionos/
- createwithswift.com — Creating ornaments in visionOS: https://www.createwithswift.com/creating-ornaments-in-visionos/
- Swift with Majid — visionOS ornaments in SwiftUI: https://swiftwithmajid.com/2024/01/30/visionos-ornaments-in-swiftui/
- Step Into Vision — Spatial SwiftUI: Using Look to Scroll: https://stepinto.vision/example-code/spatial-swiftui-using-look-to-scroll/
- Nonstrict — Request and check local network permission on iOS and visionOS: https://nonstrict.eu/blog/2024/request-and-check-for-local-network-permission/
- SwiftTerm (declares visionOS v1): https://github.com/migueldeicaza/SwiftTerm
- Michael Tsai — iSH and a-Shell vs. the App Store (2020-11-09): https://mjtsai.com/blog/2020/11/09/ish-and-a-shell-vs-the-app-store/

### Apps and competitors
- JarVS — Multi-window VS Code on Vision Pro: https://jarvs.space/ · https://apps.apple.com/us/app/jarvs/id6759111444
- Panic — Will Prompt 3 support Apple Vision Pro: https://help.panic.com/prompt/apple-vision-pro/
- Prompt 3 App Store: https://apps.apple.com/us/app/prompt-3/id1594420480
- Blink Shell App Store: https://apps.apple.com/us/app/blink-shell-build-code/id1594898306
- Termius App Store: https://apps.apple.com/us/app/termius-modern-ssh-client/id549039908
- La Terminal for Vision Pro: https://la-terminal.net/blog/la-terminal-for-vision-pro
- MacStories — Screens VNC in compatibility mode for visionOS: https://www.macstories.net/linked/screens-vnc-app-now-available-in-compatibility-mode-for-visionos/
- MacRumors Forums — Jump Desktop on Apple Vision Pro: https://forums.macrumors.com/threads/jump-desktop-on-apple-vision-pro.2419120/
- Remio — Vision Pro native client (waitlist): https://remio.net/vision-pro
- microsoft/vscode#202543 — native VS Code on Vision Pro: https://github.com/microsoft/vscode/issues/202543
- Splitscreen: https://www.splitscreen.vision/ · MacLink: https://maclink.space/vision-pro
- UploadVR — Immersed for Vision Pro: https://www.uploadvr.com/immersed-for-apple-vision-pro-virtual-extra-mac-monitors/
- TeamViewer — Apple Vision Pro remote support: https://www.teamviewer.com/en-us/insights/apple-vision-pro-new-era-of-remote-support/

### Agents and competitive landscape
- Anthropic — Apple's Xcode now supports the Claude Agent SDK (2026-02-03): https://www.anthropic.com/news/apple-xcode-claude-agent-sdk
- VentureBeat — Apple integrates Claude and Codex into Xcode 26.3: https://venturebeat.com/technology/apple-integrates-anthropics-claude-and-openais-codex-into-xcode-26-3-in-push
- anthropics/claude-code#12608 — Claude iPad app on Vision Pro, closed not planned: https://github.com/anthropics/claude-code/issues/12608
- TechRadar — Anthropic Remote Control: https://www.techradar.com/pro/anthropic-reveals-remote-control-a-mobile-version-of-claude-code-to-keep-you-productive-on-the-move
- docs.bswen.com — Claude Code Teleport vs Remote Control (2026-03-30): https://docs.bswen.com/blog/2026-03-30-claude-code-teleport-remote/
- VentureBeat — OpenAI launches ChatGPT app for Apple Vision Pro: https://venturebeat.com/ai/openai-launches-chatgpt-app-for-apple-vision-pro
- GitHub Changelog — Copilot Vision GA (2026-07-01): https://github.blog/changelog/2026-07-01-copilot-vision-is-generally-available/
- Hacker News — Show HN: Omnara: https://news.ycombinator.com/item?id=44878650
- Vibe Kanban: https://vibekanban.com/ · slopus/happy: https://github.com/slopus/happy
- Imbue — Sculptor announce: https://imbue.com/blog/sculptor-announce
- terragon-labs/terragon-oss (shut down 2026-01-16): https://github.com/terragon-labs/terragon-oss
- MeriaApp/conductor: https://github.com/MeriaApp/conductor

### Market, hardware and ergonomics
- MacRumors — Vision Pro still failing to catch on (2026-01-02): https://www.macrumors.com/2026/01/02/vision-pro-still-failing-to-catch-on/
- MacRumors — Slimmer, lighter Vision Pro late 2028 (2026-06-01): https://www.macrumors.com/2026/06/01/slimmer-lighter-apple-vision-pro-late-2028/
- MacRumors — Apple Glasses late 2027 (2026-05-31): https://www.macrumors.com/2026/05/31/apple-glasses-late-2027-report/
- 9to5Mac — Apple glasses late 2027, Vision Air by 2029: https://9to5mac.com/2026/05/31/apple-glasses-launching-late-2027-with-vision-air-to-follow-by-2029/
- Hypebeast — Vision Pro faces cuts as spatial bet stalls (2026-01): https://hypebeast.com/2026/1/apple-vision-pro-faces-cuts-as-spatial-bet-stalls
- Road to VR — Sightful cancels Spacetop, pivots to Windows software: https://roadtovr.com/ar-latop-spacetop-cancelled-windows-software-pivot/
- Road to VR — Meta discontinues Horizon Workrooms (effective 2026-02-16): https://roadtovr.com/meta-horizon-workrooms-discontinued-2026/
- iFixit — Vision Pro Teardown Part 2, display resolution (2024-02): https://www.ifixit.com/News/90409/vision-pro-teardown-part-2-whats-the-display-resolution
- Cult of Mac — Vision Pro pixels per degree: https://www.cultofmac.com/news/vision-pro-teardown-pixels-per-inch-degree
- kguttag.com — Vision Pro optics analysis (2024-03-01): https://kguttag.com/2024/03/01/apple-vision-pros-optics-blurrier-lower-contrast-than-meta-quest-3/
- Biener, Grubert et al. — Quantifying the Effects of Working in VR for One Week (arXiv:2206.03189, 2022-06; later IEEE TVCG): https://arxiv.org/abs/2206.03189
- IEEE TVCG 2024 — Hold Tight: behavioral patterns during prolonged work in VR: https://dl.acm.org/doi/10.1109/TVCG.2024.3372048
- Hoffman et al. — Vergence–accommodation conflicts hinder visual performance (Journal of Vision, 2008): https://jov.arvojournals.org/article.aspx?articleid=2122611
- Nature Scientific Reports (2025) — tear film dynamics during VR headset use: https://www.nature.com/articles/s41598-025-16634-w
- Wang et al., IEEE VRW 2020 — VR text legibility: https://ieeexplore.ieee.org/iel7/9086528/9090398/09090496.pdf
- Springer — multivocal review of VR text legibility (2024): https://link.springer.com/article/10.1007/s10055-024-00949-6
- Stephen Robles — One Year with Apple Vision Pro (2025-02-02): https://beard.fm/blog/one-year-with-apple-vision-pro
- Hacker News — Ask HN: working 4+ hours daily on a Vision Pro (2026-06): https://news.ycombinator.com/item?id=48275508
- dev.to — I tried the Apple Vision Pro as a Developer: https://dev.to/adriantwarog/i-tried-the-apple-vision-pro-as-a-developer-3do6

### App Store market
- AppleInsider — 1,000 native visionOS apps (2024-02-13): https://appleinsider.com/articles/24/02/13/apple-vision-pro-now-has-1000-native-apps-on-the-visionos-app-store
- Appfigures — pre-launch native app counts (2024-01-26): https://appfigures.com/resources/insights/20240126?f=1
- Appfigures — There are no new apps for Vision Pro (2024-04-05): https://appfigures.com/resources/insights/20240405?f=4
- TechCrunch — iPhone/iPad apps on the visionOS App Store (2023-09-05): https://techcrunch.com/2023/09/05/apple-says-iphone-and-ipad-apps-will-show-up-on-the-visionos-app-store-from-the-get-go
- TechCrunch — indie apps and games on Vision Pro (2024-03-22): https://techcrunch.com/2024/03/22/apple-vision-pro-apps/
- vrc.org.au — Vision Pro developer adoption stalling (2026-03-27): https://vrc.org.au/blog/2026-03-27-apple-vision-pro-developer-adoption-stalling/
