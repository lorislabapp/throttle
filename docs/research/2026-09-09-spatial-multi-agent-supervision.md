# Spatial multi-agent supervision: what the evidence says

**Research date:** 2026-09-09
**Question:** how should a visionOS "cockpit" for supervising several concurrent coding agents (Claude Code, Codex) running on a Mac be designed, and what is known to fail?
**Status:** research report. No implementation decision is authorised by this document.

---

## Executive answer

*(≤15 lines — what a spatial multi-agent cockpit should look like and behave like, and what would make it fail.)*

1. It is **one window**, not N. Apple's own guidance is explicit: "Ideally, keep your app's interface in a single window. Multiple windows can quickly become a lot for people to manage" (WWDC23 10072). A wall of floating terminals is the failure mode, not the product.
2. The headset's job is **supervision, not authorship**. Reading dense terminal text through passthrough for hours is the weakest thing the device does; the Mac (or Mac Virtual Display) remains where you write code.
3. The default view is a **fleet overview**, not a terminal. Terminals are drilled into, one at a time, and the drill-in is where the pixels and the depth budget go.
4. Layout is **wide, not tall, world-locked, ~1 m or further away**, landscape aspect — the neck turns sideways far more comfortably than up and down (WWDC23 10076).
5. Attention is routed by an **alarm system with a rate budget**, not by per-event notifications. The process industries' benchmark — no more than one alarm per ten minutes in normal operation (HSE CHIS6, citing EEMUA 191 p.37) — is the right order of magnitude for a supervisor, and it is far below what N chatty agents will emit.
6. Signals are **graded (3 priorities, ~5/15/80 split)** and each one carries a defined response. An alarm with no defined operator action is not an alarm; it is noise.
7. **False alarms destroy the system faster than missed ones.** Below ~0.70 reliability, imperfect diagnostic automation is worse than none at all (Wickens & Dixon 2007); operators probability-match to alarm reliability (Bliss et al. 1995).
8. The hard problem is not display, it is **re-entry**. Resumption cost scales with interruption duration and demand (Monk et al. 2008); people worked in ~2.26 other contexts before resuming a suspended one (Mark et al. 2005).
9. So the cockpit's real feature is a **"what happened while I was away" reconstruction** per agent — a diff, not a scrollback.
10. Capacity is not a constant. Fan-out ≈ a function of neglect time over interaction time (Goodrich & Olsen 2003); modelled UAV operator capacity fell by up to 67% once wait times and lost situation awareness were included (Cummings & Mitchell 2008). Design for ~3–5 attended agents, not 20.
11. Approvals are the **irreversible** actions and must not ride on gaze+pinch alone; gaze selection is subject to the Midas-touch problem and Apple's own 60 pt spacing minimum exists for a reason.
12. **It fails if** it becomes a wall of live terminals, if it alarms per token, if the supervisor is left out of the loop and then asked to take over cold (Bainbridge 1983; Endsley & Kiris 1995), or if it demands sustained small-text reading through passthrough.
13. It also fails commercially if it is a worse Mac Virtual Display — the platform's actual killer app is mirroring the Mac, and any native app must beat that or complement it.
14. Nobody has shipped this. There is no verified product or research prototype for multi-LLM-agent supervision in a headset (see Q6). The nearest analogues are multi-robot supervisory control in VR and 2D parallel-agent dashboards.
15. The strongest counter-argument to the whole idea is that the 2D dashboards already work, cost nothing to wear, and can be looked at for eight hours.

---

## Method and confidence conventions

- **VERIFIED** — I (or a delegated researcher) fetched the primary source in this session and the quoted text/number is from it. A URL is given.
- **BIBLIOGRAPHIC** — the citation (title, authors, venue, year, DOI) was verified against OpenAlex/Crossref this session, but I did not read the full text; claims are limited to what the abstract states.
- **INFERENCE** — my reasoning, not a finding. Always labelled.
- **UNVERIFIED** — encountered but not confirmed; flagged as such and not relied on.

Constraint to disclose: the session's WebSearch quota (200 queries) was exhausted during the research. Later work was done by direct fetch (Apple's HIG JSON endpoints, WWDC transcripts, arXiv, OpenAlex, Crossref, HSE, FAA, PLOS). Several publisher sites (SAGE, PubMed, Ars Technica, The Verge, Reddit) refused automated fetches. Gaps are marked rather than filled from memory.

---

## Q1 — Apple's visionOS guidance for text-heavy, multi-window productivity

All quotes below are **VERIFIED** — fetched from `developer.apple.com` on 2026-09-09.

### 1.1 The cost of multiple windows — Apple says it plainly, three times

> "**Avoid displaying too many windows.** Too many windows can obscure people's surroundings, making them feel overwhelmed, constricted, and even uncomfortable. It can also make it cumbersome for people to relocate an app because it means moving a lot of windows."
> — [Spatial layout](https://developer.apple.com/design/human-interface-guidelines/spatial-layout)

> "Like other platforms, apps can have multiple windows, which are useful in certain cases… **Ideally, keep your app's interface in a single window. Multiple windows can quickly become a lot for people to manage.**"
> — [WWDC23 "Principles of spatial design" (10072)](https://developer.apple.com/videos/play/wwdc2023/10072/)

> "To keep apps ergonomically comfortable, **minimize the amount of windows needed** and keep your interface cohesive… Spatial doesn't mean buttons and UI should be arbitrarily floating in people's field of view."
> …and, praising an app for *not* splitting content across windows: "I also like how the app doesn't require separate windows for this content, **which would have resulted in maintenance by the viewer to organize and move them around.**"
> — [WWDC24 "Design great visionOS apps" (10086)](https://developer.apple.com/videos/play/wwdc2024/10086/)

> "**Choose the right moment to open a new window.** … However, **opening new windows excessively creates clutter and can make navigating your app more confusing. Avoid opening new windows as default behavior unless it makes sense for your app.**"
> — [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)

**Important nuance (VERIFIED absence):** Apple never frames the cost of many windows as a rendering/performance cost. Every statement found frames it as **ergonomic and organisational burden**. No Apple text was found linking window count to frame rate.

**Direct relevance:** "one window per agent session" is precisely the pattern Apple warns against, by name.

### 1.2 Spatial layout, comfort, distance, head-locking

> "**Center important content within the field of view.** By default, visionOS launches an app directly in front of people, placing it within their field of view."

> "**Avoid anchoring content to the wearer's head.** Although you generally want your app to stay within the field of view, anchoring content so that it remains statically in front of someone can make them feel stuck, confined, and uncomfortable, especially if the content obscures a lot of passthrough and decreases the apparent stability of their surroundings. Instead, anchor content in people's space…"
> — [Spatial layout](https://developer.apple.com/design/human-interface-guidelines/spatial-layout)

> [IMPORTANT] "The system doesn't provide information about a person's field of view."
> — same page. (I.e. you cannot query the FOV to lay out adaptively.)

The distance number is on the Eyes page:

> "**Place content at a comfortable viewing distance.** For example, to help people remain comfortable while they read or engage with content over time, aim to place it **at least one meter away.**"
> — [Eyes](https://developer.apple.com/design/human-interface-guidelines/eyes)

> "you can improve the visual comfort of your experience when you avoid requiring people to make **multiple quick eye adjustments, either over a large area or through multiple levels of depth.**"
> — [Eyes](https://developer.apple.com/design/human-interface-guidelines/eyes)

Neck ergonomics and aspect ratio:

> "Because of the neck's range of motion, **it's easier for most people to turn their head farther to the right and to the left rather than up and down.** So keep your UI in people's field of view and be careful about placing anything too high up or too far down. **If you need a large canvas for your app, go with a wider aspect ratio than taller.**"
> — [WWDC23 "Design for spatial user interfaces" (10076)](https://developer.apple.com/videos/play/wwdc2023/10076/)

> "Most of the time, place content away from people, a bit further than arm's reach, to encourage people to interact at a distance."
> — WWDC23 10072

Recentring is free:

> "**Rely on the Digital Crown to help people recenter windows in their field of view.** … **Your app doesn't need to do anything to support this action.**"
> — Spatial layout

### 1.3 Window sizing and dynamic scale

> "**Choose an initial window size that minimizes empty areas within it. By default, a window measures 1280x720 pt. When a window first opens, the system places it about two meters in front of the wearer, giving it an apparent width of about three meters.**"

> "**Choose a minimum and maximum size for each window** … If you don't set a minimum and maximum size for a window, people could make it so small that UI elements overlap or so large that your app or game becomes unusable."

> "**Retain the window's glass background.** … Removing the glass material tends to cause UI elements and text to become less legible…"
> — [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)

> "visionOS defines two types of scale… **Dynamic scale helps content remain comfortably legible and interactive regardless of its proximity to people.** … To support dynamic scaling and the appearance of depth, **visionOS defines a point as an angle**, in contrast to other platforms, which define a point as a number of pixels."
> — Spatial layout

**This matters more than it looks.** Because a point is an *angle*, a 12 pt terminal glyph subtends the same visual angle whether the window is near or far. Pushing the terminal further away to fit more of it in view does **not** buy you legibility headroom; it buys you nothing. Only increasing the point size does. (INFERENCE from the VERIFIED quote.)

### 1.4 Typography — the actual minimums

VERIFIED table from [Typography](https://developer.apple.com/design/human-interface-guidelines/typography):

| Platform | Default | Minimum |
|---|---|---|
| iOS/iPadOS | 17 pt | 11 pt |
| macOS | 13 pt | 10 pt |
| tvOS | 29 pt | 23 pt |
| **visionOS** | **17 pt** | **12 pt** |
| watchOS | 16 pt | 12 pt |

> "In general, avoid light font weights… prefer Regular, Medium, Semibold, or Bold font weights, and **avoid Ultralight, Thin, and Light font weights**."

> "SF Pro is the system font in visionOS… **visionOS uses bolder versions of the Dynamic Type body and title styles**…"

> "**In general, prefer 2D text.** The more visual depth text characters have, the more difficult they can be to read… **prefer using text that has little or no visual depth.**"

> "**Maximize the contrast between text and the background of its container.** By default, the system displays text in white, because this color tends to provide a strong contrast with the default system background material…"

> "If you need to display text that's not on a background, consider making it bold to improve legibility. In this situation, **you generally want to avoid adding shadows**…"

Why the weights are bumped (VERIFIED, WWDC23 10076):

> "**To improve the contrast of text against vibrant materials, font weight has been modified to be slightly heavier.** For example, on iOS, we use regular weight for the body text style. On this platform, we use medium. And for titles, instead of semibold, we use bold… **Consequently, the tracking has been slightly increased to help with legibility.**"

> "Even though windows can scale up to incredible large sizes, **custom smaller or lightweight fonts can still be difficult to read.** To improve that, consider increasing the weight or using a typeface designed for optimized legibility, like system fonts."

**Direct conflict with the existing product's visual language, stated honestly:** the macOS cockpit uses hairlines and tabular digits — a precise, thin, dense idiom. Apple's visionOS guidance says thin weights and hairlines are the wrong instrument on this display, and that terminal-typical 11–12 pt monospace sits *at* the platform minimum rather than comfortably above it. (INFERENCE, from VERIFIED quotes.)

Vibrancy, from [Materials](https://developer.apple.com/design/human-interface-guidelines/materials):

> "**visionOS applies vibrancy to text, symbols, and fills. Vibrancy enhances the sense of depth by pulling light and color forward from both virtual and physical surroundings.**" — with three levels: `label`, `secondaryLabel`, `tertiaryLabel`.

And from WWDC23 10076: "Colorful elements on top of the glass may be hard to see if the color of the glass is similar. **Most of the time, consider using white text or symbols so they are always clearly visible.**"

**This is a real constraint on "blue reserved for interactive elements."** Blue on glass over a variable passthrough background is exactly the case Apple flags. (INFERENCE.)

### 1.5 Depth — use sparingly

> "**Make sure depth adds value.** … Also review how often you use different depths throughout your app. **People need to refocus their eyes to perceive each difference in depth, and doing so too often or quickly can be tiring.**"

> "**Provide visual cues that accurately communicate the depth of your content. If visual cues are missing or they conflict with a person's real-world experience, people can experience visual discomfort.**"
> — Spatial layout

> "**In most cases, prefer subtle depth. It's easy to overdo…** And **not everything needs depth. Text, for example, can be distracting and difficult to read when it's 3D, especially at an angle. Keep text flat when used as an interface element.**"
> — WWDC23 10072

> "**Because we're stacking all these elements in Z, consider using push navigation for nested views**" [rather than stacking more sheets].
> — WWDC23 10076

### 1.6 Window vs Volume vs Immersive Space

> "**Prefer using a window to present a familiar interface and to support familiar tasks.** … If you want to showcase bounded 3D content like a game board, consider using a volume."
> "**Prefer using a volume to display rich, 3D content.** In contrast, if you want to present a familiar, UI-centric interface, it generally works best to use a window."
> — [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)

> "**Use windows for contained, UI-centric experiences.** … **For each key moment in your app, find the minimum level of immersion that suits it best — don't assume that every moment needs to be fully immersive.**"
> — [Designing for visionOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos)

> "**Prefer launching your app or game in the Shared Space or using the `mixed` immersion style.** Launching in the Shared Space lets people reference your app or game while using other running software, and enables seamless switching between them."
> "**Reserve immersion for meaningful moments and content.**"
> — [Immersive experiences](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences)

Immersion styles, verbatim: `mixed` blends with passthrough and defines no boundary; `progressive` partially replaces passthrough, Digital Crown adjustable over "the default range of **120- to 360-degrees**", with "an approximately **1.5-meter boundary**"; `full` is a 360° replacement, also with a ~1.5 m boundary.

**Verdict for this product:** a supervision cockpit is a "standard task", UI-centric, 2D, and must coexist with other apps. Apple's criteria point at **Shared Space + Window**, optionally `mixed`. Volume is wrong (it is for bounded 3D content viewed from any angle). Full/progressive immersion is wrong for the default state. (INFERENCE from VERIFIED criteria.)

### 1.7 Ornaments

> "**In visionOS, an ornament presents controls and information related to a window, without crowding or obscuring the window's contents.**"
> "An ornament floats in a plane that's parallel to its associated window and slightly in front of it along the z-axis. If the associated window moves, the ornament moves with it…"
> "**Consider using an ornament to present frequently needed controls or information in a consistent location that doesn't clutter the window.** Because an ornament stays close to its window, people always know where to find it."
> "**In general, keep an ornament visible.**"
> "**If you need to display multiple ornaments, prioritize the overall visual balance of the window.** … **consider constraining the total number of ornaments** to avoid increasing a window's visual weight…"
> "**Aim to keep an ornament's width the same or narrower than the width of the associated window.**"
> — [Ornaments](https://developer.apple.com/design/human-interface-guidelines/ornaments)

Placement offset (WWDC23 10076): "When ornaments sit at the bottom edge of the window, **place them so they overlap the bottom edge by 20 points.**"

**Direct application:** the fleet meter (tokens, cost, headroom) and the session rail are exactly what an ornament is for — persistent, always-locatable, not stealing content area. (INFERENCE.)

### 1.8 Text input

> "In visionOS, **the system-provided virtual keyboard supports both direct and indirect gestures and appears in a separate window that people can move where they want. You don't need to account for the location of the keyboard in your layouts.**"
> — [Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards)

> "**Recognize that people see an overlay when they use a physical keyboard with your visionOS app or game.** When people connect a physical keyboard… **the system displays a virtual keyboard overlay that provides typing completion and other controls.**"
> — [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)

> "When you use the system-provided text field in visionOS, **the system shows the entered data to the wearer, but not to anyone else**; for example, a secure text field automatically blurs when people use AirPlay…"
> — [Entering data](https://developer.apple.com/design/human-interface-guidelines/entering-data)

**Gap, stated honestly:** no visionOS-specific HIG guidance on **dictation** was found. Entering data's visionOS platform-considerations line reads only "No additional considerations for iOS, iPadOS, tvOS, visionOS, or watchOS."

Target sizing (VERIFIED, Spatial layout + WWDC23 10076):

> "place multiple, regular-size buttons so their **centers are at least 60 points apart, leaving 16 points or more of space between them.**"
> "**Interactive elements must have a tap target area with at least 60 points of space**… your UI element can be visually smaller, like the standard button, which is 44 points, as long as you add enough space around it… it always needs to have **at least eight points of empty space** around it."

### 1.9 Mac Virtual Display (context, not API)

From the [Apple Vision Pro User Guide](https://support.apple.com/guide/apple-vision-pro/use-mac-virtual-display-tan357ede966/visionos): Mac Virtual Display supports **Standard, Wide, or Ultrawide** (a **32:9** wraparound); ultrawide requires **visionOS 2.2+** and **macOS 15.2+** on Apple silicon. It is a system feature, not something a third-party app can drive.

### 1.10 Version currency — checked against WWDC26

**VERIFIED** from [WWDC26 session 287, "Build next-generation experiences with visionOS 27"](https://developer.apple.com/videos/play/wwdc2026/287/):

> "In this session, I'll take you through powerful new ways to build next-generation experiences with **visionOS 27**."
> "In **visionOS 26**, we introduced our first set of spatial accessories: the Logitech Muse and the PSVR2 Sense controller."
> "Foveated Streaming launched in **visionOS 26.4**…"

So: visionOS 26 is real, had at least a .4 release, and **visionOS 27 is the current announced release as of WWDC26**. Plan against 27.

**The "single window" guidance was NOT softened.** Nothing in the 2026 material walks it back. Session 287 restates the Shared Space model unchanged:

> "In the Shared Space, you can choose to render your app in a window or a volume, where your experience can coexist simultaneously with other applications. This allows you to organize your workspace across the infinite canvas, taking productivity to the next level."

The three immersion styles are unchanged (mixed / progressive / full), and **no new scene type beyond window / volume / immersive space was introduced.**

Two visionOS 27 changes that do matter to this product (**VERIFIED**, session 287):

> "In Safari on visionOS 27, **windows can now be adjusted to a wider aspect ratio**, letting you take full advantage of the space around you. **Larger windows will naturally curve, bringing more of your content into comfortable view.**"

> "And with **accessory widget support on visionOS**, you can extend your app to Apple Vision Pro with smaller, glanceable widgets that surface your most relevant information, right where you need it."

The curving-wide-window direction is the same conclusion the neck-ergonomics guidance reached in 2023, now expressed as system behaviour. A glanceable widget is a plausible home for the fleet meter. (INFERENCE.)

**REFUTED / not confirmed:** the claim that visionOS 26 added *persistent widgets anchored in a room*. Neither session 287 nor [session 277 "WidgetKit foundations"](https://developer.apple.com/videos/play/wwdc2026/277/) mentions room-anchoring or persistence; grepping 277 for anchor/room/persist/spatial returned zero hits. Its only visionOS line is *"The system extra large portrait family was introduced in visionOS 26"* — a widget **size**, not anchoring. Do not design against room-anchored widget persistence without re-verification.

**Also worth knowing (VERIFIED, negative finding):** the WWDC26 catalogue has **138 sessions and none about windowing, scenes, multitasking or productivity on visionOS**. There is no 2026 equivalent of the 2023 "Design for spatial user interfaces" / "Principles of spatial design" pair; 2026's spatial content is environments and rendering. **The 2023/2024 windowing and ergonomics guidance is still the current guidance because nothing has replaced it.** (INFERENCE from a verified catalogue listing.)

One more number, from [session 234](https://developer.apple.com/videos/play/wwdc2026/234/), useful as a sanity check on angular budget even though the session is about 360° environments:

> "In visionOS, viewers will see approximately **81° of the scene in their field of view**, when fully immersed."
> "For visionOS, an environment will be sharp at **40 pixels per degree**…"

---

## Q2 — Reading and writing text for long periods in a headset

### 2.1 The single most important study

**Biener, V., Kalamkar, S., Nouri, N., Ofek, E., Pahud, M., Dudley, J.J., Hu, J., Kristensson, P.O., Weerasinghe, M., Čopič Pucihar, K., Kljun, M., Streuber, S., & Grubert, J. (2022). "Quantifying the Effects of Working in VR for One Week." *IEEE TVCG* 28(11), 3810–3820 (ISMAR 2022). DOI [10.1109/TVCG.2022.3203103](https://doi.org/10.1109/TVCG.2022.3203103), arXiv [2206.03189](https://arxiv.org/abs/2206.03189).** — **VERIFIED**, numbers extracted from the paper PDF.

N=16, five days × eight hours, Quest 2 + physical Logitech keyboard + virtual curved monitor, against an equivalent physical-desktop baseline. Self-rated deltas, VR vs. physical:

| Measure | Δ |
|---|---|
| Task load | **+35%** |
| Frustration | **+42%** |
| Negative affect | +11% |
| Anxiety | +19% |
| **Eye strain** | **+48%** |
| SUS usability | **−36%** (drops VR to *below average*) |
| Flow | −14% |
| Perceived productivity | −16% |
| Wellbeing | −20% |

Simulator sickness (SSQ): VR **M=34.3 (SD 10.16)** vs. physical **M=9.21 (SD 4.47)** — the worst category on the Stanney severity classification the authors cite. Ratings decreased only slightly across the week.

Typing: physical **46.88 WPM (SD 20.92)** vs. VR **43.09 WPM (SD 23.98)**, a significant ~8% drop. Both improved over the week; the gap did not close (no DAY × ENVIRONMENT interaction).

**Dropout: 2 of 16 (12.5%).** One left after **4 hours** (migraine from headset weight); one after **~2 hours** (anxiety, nausea, disorientation).

Comfort: 11 of 16 disliked headset comfort or wanted it improved; weight and face pressure most cited; two reported skin irritation after a week of daily wear.

**The authors' own fairness note, which matters:** despite +35% relative task load, VR's *absolute* NASA-TLX score still sat within the 50th percentile of computer activities in Grier's meta-analysis. VR work was worse than a good desk, not off the charts.

**INFERENCE:** a 12.5% dropout rate inside four hours, plus +48% eye strain, is the hard ceiling on "supervise your agents from the headset all day." It is not a hard ceiling on "put the headset on for twenty minutes to see what four agents did."

### 2.2 Text presentation: head-locked long-form text is the worst case

**Rzayev, R., Ugnivenko, P., Graf, S., Schwind, V., & Henze, N. (2021). "Reading in VR: The Effect of Text Presentation Type and Location." *CHI '21*. DOI [10.1145/3411764.3445606](https://doi.org/10.1145/3411764.3445606).** — **VERIFIED** from the PDF. N=18, HTC Vive. Text location (world-fixed / edge-fixed / head-fixed) × presentation (RSVP / paragraph).

- **Head-fixed + paragraph was the worst cell on every axis**: highest raw NASA-TLX (M=42.83 vs. M=33.83 for world-fixed paragraph), most errors (M=2.17), lowest SUS (M=67.64 — the only below-average cell), lowest preference (M=2.83 of 7).
- Best usability: edge-fixed / RSVP (SUS M=79.44).
- Participants' calibrated baseline reading speed: 191 WPM (SD 44.8) — a calibration figure, **not** a VR-vs-monitor comparison. There is no verified VR-vs-monitor reading-speed delta in this report.

**This directly corroborates Apple's own guidance** ("Avoid anchoring content to the wearer's head") with independent measured data. Code and logs are paragraph-form text; head-locking them is the empirically worst configuration tested.

Secondhand within Rzayev's related work (**not independently re-read**, flagged as such): Dingler, Kunze & Outram (CHI EA '18) — participants preferred **sans-serif over serif** and **light-on-dark over dark-on-light**; Rzayev et al. (CHI 2018) — centre/bottom-centre text position beat top-right for comprehension and task load.

### 2.3 Typing in VR degrades immediately and does not recover

**Grubert, J., Witzani, L., Ofek, E., Pahud, M., Kranz, M., & Kristensson, P.O. (2018). "Text Entry in Immersive Head-Mounted Display-Based Virtual Reality Using Standard Keyboards." *IEEE VR 2018*. arXiv [1802.00626](https://arxiv.org/abs/1802.00626).** — **VERIFIED** from the arXiv PDF. 24 analysed participants, 24 hours of typing data.

- Novices retain **~60% of desktop typing speed** in VR with a physical desktop keyboard; **~40–45%** with a touchscreen keyboard.
- **No significant learning effect within the session** — the loss is immediate and does not train away quickly.

**INFERENCE:** this is decisive for input design. Composing a long steering prompt inside the headset costs you ~40% of your typing throughput before you type a character. Approvals and short steering must not require typing.

### 2.4 Why the fatigue is structural, not a software bug

**Hoffman, D.M., Girshick, A.R., Akeley, K., & Banks, M.S. (2008). "Vergence-accommodation conflicts hinder visual performance and cause visual fatigue." *Journal of Vision* 8(3):33. DOI [10.1167/8.3.33](https://doi.org/10.1167/8.3.33). PMID 18484839.** — **VERIFIED** (abstract, via NCBI E-utilities). With correct focus cues: faster stereo identification, higher stereoacuity under time limits, less depth distortion, and reduced fatigue and discomfort.

**Shibata, T., Kim, J., Hoffman, D.M., & Banks, M.S. (2011). "The zone of comfort: Predicting visual discomfort with stereo displays." *Journal of Vision* 11(8):11. DOI [10.1167/11.8.11](https://doi.org/10.1167/11.8.11). PMID 21778252.** — **VERIFIED** (abstract). Conflicts of a given dioptric magnitude are slightly less comfortable at far viewing distances; negative conflicts (behind the screen plane) worse far, positive conflicts (in front) worse near. Phoria and the zone of clear single binocular vision predict individual susceptibility.

**UNVERIFIED and deliberately not cited as a number:** the widely-repeated "~⅓ dioptre zone of comfort" figure could not be retrieved from the primary text (publisher blocked). **UNVERIFIED:** Apple has never published Vision Pro's fixed focal distance; third-party estimates disagree (~1.5–2 m vs. "about six feet"). What *is* corroborated by a technical optics analyst is that Vision Pro has **no varifocal mechanism**, so the conflict applies unmitigated.

**This is why Apple says "People need to refocus their eyes to perceive each difference in depth, and doing so too often or quickly can be tiring."** The HIG statement and the vision-science literature are the same finding. (INFERENCE linking two VERIFIED sources.)

### 2.5 Device mass

**VERIFIED** from `apple.com/apple-vision-pro/specs/` raw HTML: *"Device Weight: 26.4–28.2 ounces (750–800 grams)… Separate battery weighs 353 grams."* Third-party "600–650 g" figures in circulation are wrong or refer to a sub-configuration.

**UNVERIFIED:** Apple's own comfort/break-reminder guidance — the support page is client-rendered and could not be extracted. No specific interval should be quoted.

### 2.6 The strongest counter-evidence (stated at full strength)

**(a) Vision Pro is measurably the best passthrough for reading.** Vona, F., Schorlemmer, J., Stern, M., Ashrafi, N., Vergari, M., Kojic, T., & Voigt-Antons, J.-N. (2025). "Comparing Pass-Through Quality of Mixed Reality Devices: A User Experience Study During Real-World Tasks." arXiv [2502.06382](https://arxiv.org/abs/2502.06382). **PREPRINT, not peer reviewed.** N=31, tasks included **reading text aloud** through passthrough, on Vision Pro vs. Quest 3 vs. Varjo XR-3. Vision Pro scored best on reading-task load and lowest cybersickness; authors conclude Vision Pro's passthrough outperformed both competitors on clarity, resolution and comfort. *(Numbers came via an automated PDF summary pass rather than my own grep — treat the exact figures as lower confidence than the direction.)*

**(b) The cognitive cost of virtual monitors may be near zero; the cost is physical.** Liu, He & Billinghurst (2024), "Using Virtual Reality as a Simulation Tool for Augmented Reality Virtual Windows," arXiv [2409.16037](https://arxiv.org/abs/2409.16037) — **preprint**, N=20, EEG + NASA-TLX. **VERIFIED** from PDF: no significant difference in mental demand (M=41.60 vs. M=41.50) or total workload (Z=−1.419, p=.156). The *only* significant workload difference was **physical demand** (35.40 vs. 58.10, p<.005). Typing was faster in AR than VR-simulated-AR.

This is the strongest intellectual counter-argument in the whole report: **the penalty for headset knowledge work concentrates in comfort and typing, not in reading or window-based cognition.** It converges with Biener et al.'s own note that absolute task load stayed within normal computer-work range. If a design removes typing and shortens sessions, most of the measured penalty is designed out.

**(c) Practitioner reports are genuinely mixed, not uniformly negative** (blog/press, weighted accordingly):
- Vincent, [vincelwt.com "Coding on the Vision Pro"](https://vincelwt.com/) (Feb 2024): coded for hours over a week; needed eye breaks "every 30 mins max", weight noticeable at 45 min, "very uncomfortable" at 1h30; still valued the distraction-free focus. Launch-week hardware.
- Arian Ghashghai, [vcstuff.substack.com](https://vcstuff.substack.com/) (Feb 2024): wrote part of the post from inside the headset; called it "the screen to end all other screens" and his physical monitor setup "laughable" by comparison — while conceding it is "too heavy and uncomfortable for most consumers to tolerate for long sessions."
- Adrian Twarog (dev.to, Jul 2024), for balance: "Fonts are harder to read inside of Virtual Reality"; no native VS Code; "I wouldn't recommend using the Apple Vision Pro for coding or designing."
- **UNVERIFIED (403, snippet only):** a Gadget Hacks "M5 Review: Finally Ready for Work" piece claiming the M5 refresh's battery life and 120 Hz Mac Virtual Display materially improve sustained work. Directionally plausible; not confirmed.

**(d) The "infinite monitors" productivity claim has no controlled study behind it.** Widely repeated in press and by Immersed/Mac Virtual Display users; **no peer-reviewed measurement of task completion or productivity gain was found.** Treat as enthusiast narrative, not evidence.

### 2.7 What is genuinely unknown

- No controlled study measuring **reading small text through passthrough vs. direct view** was found. This is a real gap in the literature.
- No Vision Pro-specific longitudinal study equivalent to Biener et al. 2022 was found. The nearest identified-but-unread follow-up is "Hold Tight: Identifying Behavioral Patterns During Prolonged Work in VR Through Video Analysis," *IEEE TVCG* 2024, arXiv 2401.14920.

---

## Q3 — How real multi-window professional apps on visionOS lay out, and what is criticised

### 3.1 Terminal and developer apps that genuinely exist on visionOS

| App | Confirmation | Layout notes |
|---|---|---|
| **Prompt 3** (Panic) | Confirmed; free visionOS support with any Prompt purchase. [help.panic.com](https://help.panic.com/prompt/apple-vision-pro/) | Ships a custom **immersive space** ("Terminal 33") and a GPU-accelerated text engine for tmux/nvim density. The only shipping terminal that uses immersion as a product feature. |
| **La Terminal** (Joseph Hill & Miguel de Icaza) | **Directly fetch-verified** via [Product Hunt](https://www.producthunt.com/products/la-terminal-ssh-client-for-vision-pro) | Native visionOS-first: immersive backgrounds, a process explorer rendered as 3D panels that "pop" out of the terminal window, command search over history, AI command help, iCloud sync. |
| **Blink Shell, Build & Code** | Confirmed, visionOS 1.3+. [blink.sh](https://blink.sh/) | Connects out to VS Code / Codespaces / Gitpod — i.e. the terminal is a *client*, the editing happens elsewhere. |
| **Secure ShellFish** | Confirmed, visionOS 1.1+. [secureshellfish.app](https://secureshellfish.app/) | Notable: built-in **tmux** session persistence to survive connectivity loss; remote dirs mounted into Files. |
| **Termius** | Confirmed, visionOS 1.0+ (App Store listing, snippet not fetch-verified) | iPad UI ported; no visionOS-specific spatial redesign described. |

**No native visionOS code editor of Xcode class exists.** Xcode does not run on visionOS. The real workflow is Mac Virtual Display with Xcode/Cursor on the mirrored Mac, or a terminal client pointed at a remote box.

**Two of the five terminals independently arrived at the same idea: session persistence and remote-first.** Secure ShellFish ships tmux persistence explicitly; Blink treats the headset as a thin client. (INFERENCE from VERIFIED product pages.)

### 3.2 Productivity apps — fetch-verified minimum versions

Slack (visionOS 1.0+), Zoom Workplace (1.0+), Webex (2.0+), Microsoft Word (2.0+) — all confirmed by direct App Store fetch. **UNVERIFIED:** Notion, Bezel, Jigspace, Numerics, Widgetsmith were named in the brief but not confirmed this session. "Arthur" and Horizon Workrooms are Meta Quest, not visionOS.

### 3.3 The criticism, with sources

**Window management is the recurring, structural complaint.**

- **The Verge**, Nilay Patel, launch review: visionOS "lack[s] a window management tool similar to Exposé or Stage Manager," and the experience is "magic when it works and frustrates you completely when it doesn't." Display sharpness praised as "generally incredible"; eye/hand tracking precision called inconsistent and "frustrating" where the interface demanded precision the tracking could not deliver. → [theverge.com/24054862](https://www.theverge.com/24054862/apple-vision-pro-review-vr-ar-headset-features-price) *(quote obtained via Wikipedia's cited excerpt; The Verge blocked direct fetch)*

- **Developer-level analysis — the most useful source here.** Stuart Varrall, ["Windowing on the Vision Pro"](https://varrall.substack.com/p/windowing-on-the-vision-pro) — **directly fetched**. Documents the platform gaps behind the user complaints:
  - **No "find my window", no Mission Control/Exposé equivalent.** Lose a window in space and there is no built-in way to get it back.
  - A persistence trap: the original window group stays open when entering an immersive space; close the main window *before* exiting immersion and the app can end up with zero windows and quit.
  - `scenePhase` does not reliably report window dismissal (`dismissWindow` or the system close button) and does not support `controlActiveState` — an app cannot reliably know its own window state changed.
  - Window position cannot be programmatically restored without "very low level, and clearly unintended, trickery."

- **Apple Developer Forums** (multiple open threads, fetch-summarised): "Unable to Retain Main App Window State When Transitioning to Immersive Space"; closing/reopening a window causing a full app **restart** rather than state resumption; volumetric windows not anchoring correctly; resize state lost on reopen. There is **no singular `Window` concept in visionOS — only `WindowGroup`** — so by default a user can spawn duplicate copies of the same window.

**This is the operational risk that matters most for a cockpit.** A supervision tool whose value is "come back later and see what happened" is being built on a platform where window state, position and even *existence* are not reliably restorable, and where the app may restart on window reopen. (INFERENCE from VERIFIED developer sources.)

**Ecosystem trajectory.**
- App counts: ~600 at launch day (2024-02-01, 250+ of them pre-compatible Apple Arcade titles, [GSMArena](https://m.gsmarena.com/there_are_already_600_apps_for_the_apple_vision_pro_including_arcade_games-amp-61440.php)); "over 1,000 apps specifically designed" two weeks later ([TechCrunch](https://techcrunch.com/2024/02/14/apples-vision-pro-now-has-over-1000-apps-specifically-designed-for-the-new-device/)); **over half of Vision Pro-only apps were paid downloads**, far above the iOS norm ([TechCrunch](https://techcrunch.com/2024/02/12/over-half-of-vision-pro-only-apps-are-paid-downloads-far-more-than-wider-app-store/)) — consistent with a small enthusiast buyer base. **No comparable 2025/2026 count could be obtained**, so "the ecosystem shrank" is **not established with hard data**.
- Developer interest: [NotebookCheck](https://www.notebookcheck.net/Apple-Vision-Pro-struggling-to-attract-developer-interest.738466.0.html) cites Gurman describing Apple's own Vision Pro developer labs as "under-filled with small amounts of developers"; reports Johny Srouji calling it a "science project" and Tony Fadell saying Apple had "jumped the shark"; frames Apple's fallback as unmodified iPad-app compatibility.
- What actually arrived natively in 2026 skews to **media and gaming** — YouTube (native only in 2026), Steam Link beta, GeForce NOW — not productivity or developer tools (MacStories tag archive).
- **UNVERIFIED (403):** CNBC, "Apple's Vision Pro has a problem a year into its existence: Not enough apps" (2025-02-21) — title and URL real, body not fetchable.

**Mac Virtual Display is the platform's actual killer app, and it is a competitor.** visionOS 2.2 added wide/ultrawide up to 32:9. Reactions tracked in [lastweekinavp #41](https://lastweekinavp.substack.com/p/last-week-in-avp-41-mac-virtual-display) and an [AppleInsider thread](https://forums.appleinsider.com/discussion/238335/) titled "Apple Vision Pro's ultra-wide Mac display mirroring is the killer app" describe users abandoning physical monitors. **The counter-argument is in the same evidence:** you can already open native Safari/Notes/Slack alongside the Mac screen, so the native-app case is not fully moot — it is just narrowed to things the Mac screen cannot do.

**Not obtainable this session:** Six Colors, Ars Technica, Daring Fireball, MacStories, UploadVR, Road to VR pieces on window persistence or comfort; Reddit r/VisionPro threads (not fetchable). The specific "windows don't follow you between rooms" phrasing **could not be sourced to a named outlet** and is not asserted here, though it is consistent with the Varrall and developer-forum evidence.

---

## Q4 — Supervising several long-running autonomous processes

This is the part of the question with a century of real evidence behind it. Nothing about coding agents is new to human factors; only the vocabulary is.

### 4.1 How many parallel streams can one person supervise?

**The honest answer is that "number of streams" is the wrong unit — and every serious domain has already abandoned it.**

**Working-memory ceiling.** Cowan, N. (2001), "The magical number 4 in short-term memory: A reconsideration of mental storage capacity," *Behavioral and Brain Sciences* 24(1), 87–114, DOI [10.1017/S0140525X01003922](https://doi.org/10.1017/s0140525x01003922) — **BIBLIOGRAPHIC + abstract VERIFIED**:

> "Miller (1956) summarized evidence that people can remember about seven chunks in short-term memory (STM) tasks. However, that number was meant more as a rough estimate and a rhetorical device than as a real capacity limit… **A single, central capacity limit averaging about four chunks is implicated**…"

Four chunks is the ceiling on *what you can hold about the fleet at once*, not on how many sessions may exist.

**Interference depends on what the tasks compete for.** Wickens, C.D. (2008), "Multiple Resources and Mental Workload," *Human Factors* 50(3), 449–455, DOI [10.1518/001872008X288394](https://doi.org/10.1518/001872008x288394) — **abstract VERIFIED**. Multiple resource theory predicts that tasks interfere in proportion to their overlap along four dimensions; the model "yielded high correlations between model predictions and data" and its "most important application… is to recommend design changes when conditions of multitask resource overload exist."

**INFERENCE:** N terminal panes all compete for the *same* resource — foveal vision + verbal/spatial working memory. Multiple resource theory predicts near-maximal mutual interference. Distributing them in 3D space does not change which resource they compete for. This is the theoretical reason a spatial wall of terminals does not buy capacity.

**The best available metric: fan-out and neglect time.** Goodrich, M.A. & Olsen, D.R. (2003), "Metrics for Evaluating Human-Robot Interactions" — **abstract VERIFIED**:

> "The autonomy of a robot is measured by its **neglect time**. The **robot attention demand** metric measures how much of the user's attention is involved with instructing a robot. The **free-time** and **fan-out** metrics are two ways to measure this demand… **Reducing interaction effort without diminishing task effectiveness is the goal of human-robot interaction design.**"

The fan-out formulation is the single most transferable idea in this report: **how many agents you can supervise is a ratio of how long each one can be safely ignored to how long it takes you to service it.** It is a property of the *agents and the interface*, not of the person.

**And it collapses once you account for real human costs.** Cummings, M.L. & Mitchell, P. (2008), "Predicting Controller Capacity in Supervisory Control of Multiple UAVs," *IEEE Trans. SMC-A* 38(2), 451–460, DOI [10.1109/TSMCA.2007.914757](https://doi.org/10.1109/tsmca.2007.914757) — **abstract VERIFIED**:

> "…it is important to model the sources of wait times (WTs) caused by human-vehicle interaction… these sources of vehicle WTs include **cognitive reorientation and interaction WT, queues for multiple-vehicle interactions, and loss of situation awareness (SA) WTs. When WTs were included, predictions using a multiple homogeneous and independent UAV simulation dropped by up to 67%, with a loss of SA as the primary source of WT delays.** Moreover… **even in a highly automated management-by-exception system**, which should alleviate queuing and WTIs, **operator capacity is still affected by the SA WT, causing a 36% decrease** over the capacity model with no WT included."

Read that last sentence twice. Even a system designed exactly the way this report recommends — management by exception, alarm-driven, no polling — still lost **36%** of theoretical operator capacity purely to the time it takes a human to rebuild situation awareness. That cost is irreducible; it can only be *shortened by the interface*, which is precisely what §4.4 is about.

See also Crandall, J.W. & Cummings, M.L. (2007), "Identifying Predictive Metrics for Supervisory Control of Multiple Robots," *IEEE Trans. Robotics* 23(5), 942–951, DOI [10.1109/TRO.2007.907480](https://doi.org/10.1109/tro.2007.907480) — **abstract VERIFIED**: a metric set for a human-robot team should "contain the key performance parameters," "identify the limitations of the agents," and "have predictive power," and is used to "predict the number of robots that should be in the team."

**Air traffic control does not use a fixed number either.** Loft, S., Sanderson, P., Neal, A. & Mooij, M. (2007), "Modeling and Predicting Mental Workload in En Route Air Traffic Control: Critical Review and Broader Implications," *Human Factors* 49(3), 376–399, DOI [10.1518/001872007X197017](https://doi.org/10.1518/001872007x197017) — **abstract VERIFIED**:

> "Although task demand has a strong relationship with workload, **evidence suggests that the relationship depends on the capacity of the controllers to select priorities, manage their cognitive resources, and regulate their own performance**… **Controller workload will not be effectively modeled until controllers' strategies for regulating the cognitive impact of task demand have been modeled.**"

**And the operational system reflects that.** FAA Order JO 7210.3, Chapter 18 Section 9, "Monitor Alert Parameter" — [**VERIFIED**, fetched from faa.gov](https://www.faa.gov/air_traffic/publications/atpubs/foa_html/chap18_section_9.html):

> "The Monitor Alert Parameter (MAP) establishes a **numerical trigger value** to provide notification to facility personnel… that sector/airport efficiency may be degraded during specific periods of time… **therefore MAP is a dynamic value which will be adjusted to reflect the capabilities of the functional position or airport.**"

> "Baseline MAP values are established utilizing a **workload-based model**… The MAP value may be **dynamically adjusted** to reflect the ability of the functional position to provide air traffic service."

Four design lessons are directly readable off that document, and they are the best-validated ones in this report:

1. **There is a numeric capacity threshold, and it is explicit and visible** — not implicit in how bad things feel.
2. **It is dynamic**, adjusted for current conditions (weather, outages), not a constant.
3. **It is two-tiered**: yellow alerts are raised only "when analysis indicates that the ability of the sector to provide efficient air traffic services will be degraded"; red alerts are always raised, logged, and post-event analysed.
4. **It is predictive, not reactive.** "Set the MA look ahead value at least one hour into the future with **1.5 hours to 2.5 hours being the recommended time frame**… Action taken to address an alert should take place approximately 1 hour prior to the alerted time frame."

And a transient filter: "TM initiatives should be primarily for those time frames when the MAP value will be equaled or exceeded **for a sustained period of time (usually greater than 5 minutes)**."

Finally, the system treats *repeated alerting as a design defect*: "When a pattern of alerts is established… which requires recurring TM initiatives for resolution, additional analysis will be conducted. The analysis should result in recommendations to address the identified constraint" — i.e. **fix the sector, don't keep alarming.**

**Working answer on numbers.** No verified source gives "a person can supervise N agents." The defensible statement is: capacity = f(neglect time / interaction time), degraded ~36–67% by situation-awareness rebuild costs, against a ~4-chunk working-memory ceiling for holding fleet state. **INFERENCE: design the attended set at 3–5, allow more to exist unattended, and make the count of *agents currently demanding attention* an explicit, visible, dynamic threshold in the manner of a MAP.**

### 4.2 Signalling that something needs attention, without alarm fatigue

**The canonical disaster.** UK Health and Safety Executive, *Better alarm handling*, Chemicals Information Sheet No. 6 — [**VERIFIED**, fetched from hse.gov.uk](https://www.hse.gov.uk/pubns/chis6.pdf). On the 1994 Texaco Milford Haven explosion (26 injured, ~£48m damage):

> "There were too many alarms and they were poorly prioritised."
> "The control room displays did not help the operators to understand what was happening."
> "**In the last 11 minutes before the explosion the two operators had to recognise, acknowledge and act on 275 alarms.**"

**The rate budget.** Same document, citing EEMUA 191 p.37:

> "**Alarm rate targets: the long-term average alarm rate during normal operation should be no more than one every ten minutes; and no more than ten displayed in the first ten minutes following a major plant upset.**"

**The priority budget.** Same document, citing EEMUA 191 p.65:

> "Use about **three priorities**."
> "Base priorities on the **potential consequences if the operator fails to respond**."
> "Prioritise proportionately, eg **5% high priority, 15% medium, and 80% low**."

**The definition of an alarm.** Same document:

> "Are they all necessary, **requiring operator action**? (Note: **process status indicators should not be designated as alarms.**)"
> An effective alarm system should "'direct the operator's attention towards plant conditions requiring timely assessment or action'"… "**Only present the operator with useful and relevant alarms**"… "**Have a defined response to each alarm**"… "**Allow enough time for the operator to respond.**"

And the preconditions for the operator actually responding:

> "High operator reliability requires: very obvious display of the specific alarm; **few false alarms**; a low operator workload; **a simple well-defined operator response**; well trained operators; testing of the effectiveness of operators' responses."

**Nuisance-alarm symptoms to watch for** (same document): "are large numbers of alarms acknowledged in quick succession, or are audible alarms regularly turned off?"

**INFERENCE, and it is the sharpest single transfer in this report:** an agent finishing a tool call, printing a diff, or crossing a token threshold is a **process status indicator, not an alarm**. Under EEMUA's rule it must never be allowed to raise one. The rate budget — *one per ten minutes* — is brutal against the natural event rate of five concurrent coding agents, and it is the right budget.

**Healthcare is the modern proof that the budget is real.** Drew, B.J., Harris, P., Zègre-Hemsey, J.K., Mammone, T., Schindler, D., Salas-Boni, R., Bai, Y., Tinoco, A., Ding, Q. & Hu, X. (2014), "Insights into the Problem of Alarm Fatigue with Physiologic Monitor Devices: A Comprehensive Observational Study of Consecutive Intensive Care Unit Patients," *PLOS ONE* 9(10):e110274, DOI [10.1371/journal.pone.0110274](https://doi.org/10.1371/journal.pone.0110274) — **VERIFIED**:

> "A total of **2,558,760 unique alarms occurred in the 31-day study period**: arrhythmia, 1,154,201; parameter, 612,927; technical, 791,632."

across **77 ICU beds** — roughly **1,070 alarms per bed per day**. And:

> "**88.8% of the 12,671 annotated arrhythmia alarms were false positives.**"

Cvach, M. (2012), "Monitor Alarm Fatigue: An Integrative Review," *Biomedical Instrumentation & Technology* 46(4), 268–277, DOI [10.2345/0899-8205-46.4.268](https://doi.org/10.2345/0899-8205-46.4.268) — **abstract VERIFIED**: "Alarm fatigue is a national problem and the number one medical device technology hazard in 2012. The problem of alarm desensitization is multifaceted and related to a **high false alarm rate, poor positive predictive value**, lack of alarm standardization, and the number of alarming medical devices…"

**What false alarms actually do to a person.** Bliss, J.P., Gilson, R.D. & Deaton, J.E. (1995), "Human probability matching behaviour in response to alarms of varying reliability," *Ergonomics* 38(11), 2300–2312, DOI [10.1080/00140139508925269](https://doi.org/10.1080/00140139508925269) — **abstract VERIFIED**. With alarms at 25%, 50% and 75% true-alarm rates:

> "The results indicate that **most subjects (about 90%) do not respond to all alarms but match their response rates to the expected probability of true alarms (probability matching).** About 10% of the subjects responded in the extreme, utilizing an all-or-none strategy."

This is the cry-wolf effect measured. **Your users will not "learn to ignore the noisy ones" selectively — they will statistically down-weight *the whole channel* in proportion to its false-alarm rate.** (INFERENCE from a VERIFIED result.)

Getty, D.J., Swets, J.A., Pickett, R.M. & Gonthier, D. (1995), "System operator response to warnings of danger: A laboratory investigation of the effects of the predictive value of a warning on human response time," *Journal of Experimental Psychology: Applied* 1(1), 19–33, DOI [10.1037/1076-898X.1.1.19](https://doi.org/10.1037/1076-898x.1.1.19) — **BIBLIOGRAPHIC verified; abstract not retrievable this session.** Cited here for the framing (response time as a function of a warning's *positive predictive value*), not for a number.

**The crossover point where automation becomes worse than nothing.** Wickens, C.D. & Dixon, S.R. (2007), "The benefits of imperfect diagnostic automation: a synthesis of the literature," *Theoretical Issues in Ergonomics Science* 8(3), 201–212, DOI [10.1080/14639220500370105](https://doi.org/10.1080/14639220500370105) — **abstract VERIFIED**. 20 studies, 35 data points:

> "**The analysis revealed that a reliability of 0.70 was the 'crossover point' below which unreliable automation was worse than no automation at all.** The analysis also revealed that performance was more strongly affected by reliability in high workload conditions…"

**This is a shippable acceptance criterion.** If the cockpit's "this agent needs you" detector is right less than ~70% of the time, the evidence says the supervisor is better off with no detector. (INFERENCE from a VERIFIED number; note the 0.70 figure is a regression crossover across a heterogeneous literature, not a physical constant.)

**Graded beats binary.** Sorkin, R.D., Kantowitz, B.H. & Kantowitz, S.C. (1988), "Likelihood Alarm Displays," *Human Factors* 30(4), 445–459, DOI [10.1177/001872088803000406](https://doi.org/10.1177/001872088803000406) — **abstract VERIFIED**:

> "In a likelihood alarm display (LAD) information about **event likelihood** is computed by an automated monitoring system and **encoded into an alerting signal**… The results indicated that (1) automated monitoring systems can improve performance on primary and secondary tasks; (2) **LADs can improve the allocation of attention among tasks** and provide information integrated into operator decisions; and (3) **LADs do not necessarily add to the operator's attentional load.**"

Corroborated by Fallon, C.K., Bustamante, E.A. & Bliss, J.P. (2005), HFES Proceedings 49(17), 1677–1681, DOI [10.1177/154193120504901738](https://doi.org/10.1177/154193120504901738) — **abstract VERIFIED**: "greater SA and reduced workload when participants used a likelihood alarm display."

**INFERENCE:** the cockpit should never emit a binary "needs attention" flag. It should emit a *confidence-graded* signal — the same three-tier structure EEMUA prescribes, with the tier derived from estimated likelihood × consequence. This is the one place where the existing "precise cockpit" visual language is already correct: a meter is a likelihood display; a red dot is a binary alarm.

### 4.3 The vigilance problem, and why "just watch the agents" is not a plan

**Bainbridge, L. (1983), "Ironies of Automation," *Automatica* 19(6), 775–779** — [**VERIFIED**, full text extracted](https://www.adaptivecapacitylabs.com/IroniesOfAutomation-Bainbridge83.pdf). This paper is forty-three years old and describes the agent-supervision problem exactly.

The two ironies, verbatim:

> "The designer's view of the human operator may be that the operator is unreliable and inefficient, so should be eliminated from the system. There are two ironies of this attitude. One is that **designer errors can be a major source of operating problems.** … **The second irony is that the designer who tries to eliminate the operator still leaves the operator to do the tasks which the designer cannot think how to automate.** It is this approach which causes the problems to be discussed here, as it means that **the operator can be left with an arbitrary collection of tasks, and little thought may have been given to providing support for them.**"

The vigilance limit, verbatim:

> "We know from many 'vigilance' studies (Mackworth, 1950) that **it is impossible for even a highly motivated human being to maintain effective visual attention towards a source of information on which very little happens, for more than about half an hour.** This means that it is **humanly impossible to carry out the basic function of monitoring for unlikely abnormalities**, which therefore has to be done by an automatic alarm system…"

Skill decay, verbatim:

> "**Unfortunately, physical skills deteriorate when they are not used**, particularly the refinements of gain and timing. This means that **a formerly experienced operator who has been monitoring an automated process may now be an inexperienced one.**"

And on the temptation to inject synthetic events to keep the operator alert:

> "One method of overcoming vigilance problems which is frequently suggested is to increase the signal rate artificially. **It would be a mistake, however, to increase artificially the rate of computer failure as the operator will then not trust the system.**"

**Vigilance is not passive.** Warm, J.S., Parasuraman, R. & Matthews, G. (2008), "Vigilance Requires Hard Mental Work and Is Stressful," *Human Factors* 50(3), 433–441, DOI [10.1518/001872008X312152](https://doi.org/10.1518/001872008x312152) — **abstract VERIFIED**:

> "**Vigilance tasks have typically been viewed as undemanding assignments requiring little mental effort**… Subjective reports also show that **the workload of vigilance is high** and sensitive to factors that increase processing demands. Neuroimaging studies using transcranial Doppler sonography provide strong, independent evidence for resource changes linked to performance decrement… **physiological and subjective reports confirm that vigilance tasks reduce task engagement and increase distress**… **vigilance requires hard mental work and is stressful.**"

See, J.E., Howe, S.R., Warm, J.S. & Dember, W.N. (1995), "Meta-analysis of the sensitivity decrement in vigilance," *Psychological Bulletin* 117(2), 230–249, DOI [10.1037/0033-2909.117.2.230](https://doi.org/10.1037/0033-2909.117.2.230) — **BIBLIOGRAPHIC verified; abstract not retrievable this session** (no abstract in Crossref, publisher blocked). Cited for the existence of a genuine sensitivity decrement, not for a specific onset time.

**INFERENCE, and it is important for a headset product:** if watching is *hard, stressful work* rather than restful, then a design that asks the user to sit in a headset and watch agents is combining two independently fatiguing activities. The Biener et al. +48% eye strain and the Warm et al. "vigilance is stressful" finding stack.

**Being out of the loop makes takeover worse.** Endsley, M.R. & Kiris, E.O. (1995), "The Out-of-the-Loop Performance Problem and Level of Control in Automation," *Human Factors* 37(2), 381–394, DOI [10.1518/001872095779064555](https://doi.org/10.1518/001872095779064555) — **abstract VERIFIED**:

> "The out-of-the-loop performance problem… **leaves operators of automated systems handicapped in their ability to take over manual operations in the event of automation failure.** This is attributed to a possible loss of skills and of situation awareness (SA) arising from vigilance and complacency problems, **a shift from active to passive information processing**, and change in feedback provided to the operator… **Level of operator control in interacting with automation is a major factor in moderating this loss of SA.** Results indicated that **the shift from active to passive processing was most likely responsible for decreased SA** under automated conditions."

**Complacency cannot be trained away.** Parasuraman, R. & Manzey, D.H. (2010), "Complacency and Bias in Human Use of Automation: An Attentional Integration," *Human Factors* 52(3), 381–410, DOI [10.1177/0018720810376055](https://doi.org/10.1177/0018720810376055) — **abstract VERIFIED**:

> "**Automation complacency occurs under conditions of multiple-task load, when manual tasks compete with the automated task for the operator's attention. Automation complacency is found in both naive and expert participants and cannot be overcome with simple practice.** Automation bias results in making both omission and commission errors when decision aids are imperfect… **cannot be prevented by training or instructions**, and can affect decision making in individuals as well as in teams."

**Trust must be calibrated, not maximised.** Lee, J.D. & See, K.A. (2004), "Trust in Automation: Designing for Appropriate Reliance," *Human Factors* 46(1), 50–80, DOI [10.1518/hfes.46.1.50.30392](https://doi.org/10.1518/hfes.46.1.50.30392) — **abstract VERIFIED**: "Automation is often problematic because **people fail to rely upon it appropriately**… **trust guides reliance when complexity and unanticipated situations make a complete understanding of the automation impractical.**"

**And the choice of what to automate is a design axis, not a binary.** Parasuraman, R., Sheridan, T.B. & Wickens, C.D. (2000), "A model for types and levels of human interaction with automation," *IEEE Trans. SMC-A* 30(3), 286–297, DOI [10.1109/3468.844354](https://doi.org/10.1109/3468.844354) — **abstract VERIFIED**: automation applies to four function classes — "1) information acquisition; 2) information analysis; 3) decision and action selection; and 4) action implementation" — each across a continuum of levels, and "**automation does not merely supplant but changes human activity and can impose new coordination demands on the human operator.**"

**INFERENCE:** the cockpit's own automation should sit high on *information acquisition and analysis* (detect, rank, summarise) and low on *decision and action selection* (never auto-approve). That is exactly the split the model recommends when the cost of an incorrect action is high.

**Display design should expose the process, not just its state.** Vicente, K.J. & Rasmussen, J. (1992), "Ecological interface design: theoretical foundations," *IEEE Trans. SMC* 22(4), 589–606, DOI [10.1109/21.156574](https://doi.org/10.1109/21.156574) — **abstract VERIFIED**: EID's goals are "**not to force processing to a higher level than the demands of the task require, and to support each of the three levels of cognitive control**" (skill, rule, knowledge). HSE echoes this operationally: "Do displays and on-line help present alarm information in the best way, eg **coloured mimics instead of alarm lists**?"

**INFERENCE:** a scrolling list of agent events is the alarm-list anti-pattern. A structural display of the fleet — what each agent is doing, against its plan, with its budget — is the mimic.

### 4.4 The moment attention returns — the hardest and most valuable problem

**How long people are actually away.** Mark, G., Gonzalez, V.M. & Harris, J. (2005), "No Task Left Behind? Examining the Nature of Fragmented Work," *CHI '05*, 321–330 — [**VERIFIED**, extracted from the paper PDF](https://www.ics.uci.edu/~gmark/CHI2005.pdf):

> "The average length of time that the informants spent in central and peripheral working spheres was **11 min. 4 sec.**, (sd=18 min. 9 sec.) before switching to another working sphere or being interrupted."

> "When people did resume work on the same day, it took an average length of time of **25 min. 26 sec** (sd=54 min. 48 sec.). This may seem like a relatively short amount of time, but it is also important to consider that **before resuming work, our informants worked in an average of 2.26 (sd=2.79) working spheres.** Thus, people's attention was directed to multiple other topics before resuming work. **This was reported by informants as being very detrimental.**"

*(Note: the widely-quoted "23 minutes 15 seconds" figure is not in this paper. The verified figure is 25 min 26 s. I did not verify the 23:15 number and it is not used here.)*

**The cost of interruption is paid in stress, not time.** Mark, G., Gudith, D. & Klocke, U. (2008), "The Cost of Interrupted Work: More Speed and Stress," *CHI '08* — [**VERIFIED**, extracted from the paper PDF](https://ics.uci.edu/~gmark/chi08-mark.pdf):

> "We found that context does not make a difference but surprisingly, **people completed interrupted tasks in less time with no difference in quality.** Our data suggests that **people compensate for interruptions by working faster, but this comes at a price: experiencing more stress, higher frustration, time pressure and effort.**"

> "**After only 20 minutes of interrupted performance people reported significantly higher stress, frustration, workload, effort, and pressure.**"

**INFERENCE, and it reframes the whole product:** a supervisor of five agents is, by construction, an interrupted worker. This literature says the damage will not show up as slower work — it will show up as a person who is fried after twenty minutes. In a headset that already adds +35% task load and +42% frustration (Biener et al.), that is the thing to design against.

**Why resumption is expensive, mechanistically.** Altmann, E.M. & Trafton, J.G. (2002), "Memory for goals: an activation-based model," *Cognitive Science* 26(1), 39–83, DOI [10.1207/s15516709cog2601_2](https://doi.org/10.1207/s15516709cog2601_2) — **abstract VERIFIED**. Goals are not stored on a stack; they are memory items subject to decay and interference, retrieved by **associative priming from cues**. The model's three constraints are an interference level from residual memory for old goals, a strengthening constraint on encoding a new goal, and "**the priming constraint, which makes predictions about the role of cues in retrieving pending goals.**"

**This is the single most actionable mechanism in the report:** resumption is a *cue-driven retrieval problem*. The interface's job at re-entry is to supply the retrieval cues.

**And it scales with how long and how demanding the gap was.** Monk, C.A., Trafton, J.G. & Boehm-Davis, D.A. (2008), "The effect of interruption duration and demand on resuming suspended goals," *JEP: Applied* 14(4), 299–313, DOI [10.1037/a0014402](https://doi.org/10.1037/a0014402) — **abstract VERIFIED**:

> "**The time to resume task goals after an interruption varied depending on the duration and cognitive demand of interruptions**, as predicted by the memory for goals model… **longer and more demanding interruptions led to longer resumption times**… the interaction between duration and demand **supported the importance of goal rehearsal in mitigating decay.**"

**Rehearsal and prospective encoding help — and they can be designed in.** Trafton, J.G., Altmann, E.M., Brock, D.P. & Mintz, F.E. (2003), "Preparing to resume an interrupted task: effects of prospective goal encoding and retrospective rehearsal," *IJHCS* 58(5), 583–603, DOI [10.1016/S1071-5819(03)00023-5](https://doi.org/10.1016/s1071-5819(03)00023-5) — **BIBLIOGRAPHIC verified; abstract not retrievable.** The title states the manipulation; the finding is not quoted here because I could not read it.

**When to interrupt matters as much as whether.** Adamczyk, P.D. & Bailey, B.P. (2004), "If not now, when? The effects of interruption at different moments within task execution," *CHI '04*, 271–278, DOI [10.1145/985692.985727](https://doi.org/10.1145/985692.985727) — **abstract VERIFIED**:

> "User attention is a scarce resource, and **users are susceptible to interruption overload. Systems do not reason about the effects of interrupting a user during a task sequence.** … Our results show that **different interruption moments have different impacts on user emotional state and positive social attribution**, and suggest that a system could **enable a user to maintain a high level of awareness while mitigating the disruptive effects of interruption.**"

**And the 2002 paper that named this exact product category.** McFarlane, D.C. (2002), "Comparison of Four Primary Methods for Coordinating the Interruption of People in Human-Computer Interaction," *Human-Computer Interaction* 17(1), 63–139, DOI [10.1207/s15327051hci1701_2](https://doi.org/10.1207/s15327051hci1701_2) — **abstract VERIFIED**:

> "Interruptions occur as an unavoidable side-effect of some important kinds of human computer-based activities, for example, (a) **constantly monitor for unscheduled changes in information environments**, (b) **supervise background autonomous services**, and (c) intermittently collaborate and communicate with other people. Fortunately, **people have powerful innate cognitive abilities that they can potentially leverage to manage multiple concurrent activities if they have specific kinds of control and interaction support.**"

*(The four coordination methods are commonly summarised as immediate, negotiated, mediated and scheduled, but I did not verify those names from the paper text this session — treat the naming as **UNVERIFIED** while the study itself is verified.)*

**Situation awareness is the thing being rebuilt.** Endsley, M.R. (1995), "Toward a Theory of Situation Awareness in Dynamic Systems," *Human Factors* 37(1), 32–64, DOI [10.1518/001872095779049543](https://doi.org/10.1518/001872095779049543) — **abstract VERIFIED**: "**attention and working memory are presented as critical factors limiting operators from acquiring and interpreting information from the environment to form situation awareness**, and mental models and goal-directed behavior are hypothesized as important mechanisms for overcoming these limits."

**Synthesis for the design.** The re-entry moment should provide, per agent, in this order:
1. **What changed since you last looked** (the retrieval cue — Altmann & Trafton).
2. **Where it is against its plan** (goal-level, not event-level — Endsley's Level 2/3 SA).
3. **What it wants from you, and by when** (the defined response — EEMUA).
4. **What it will do if you say nothing** (the default; makes inaction an informed choice).

None of that is a scrollback. (INFERENCE, built on VERIFIED mechanisms.)

### 4.5 Network / security operations centres

Sundaramurthy, S.C., Bardas, A.G., Case, J.P., Ou, X., Wesch, M., McHugh, J. & Rajagopalan, S.R. (2015), "A Human Capital Model for Mitigating Security Analyst Burnout," *SOUPS 2015*, 347–359 — **abstract VERIFIED**:

> "One of the worrying issues in recent times has been the **consistently high burnout rates of security analysts in SOCs. Burnout results in analysts making poor judgments when analyzing security events as well as frequent personnel turnovers.** In spite of high awareness of this problem, **little has been known so far about the factors leading to burnout.** … we performed an **anthropological study of a corporate SOC over a period of six months** … **burnout is a human capital management problem resulting from the cyclic interaction of a number of human, technical, and managerial** [factors]."

**INFERENCE:** the closest occupational analogue to "one person supervising many autonomous processes producing high-volume, low-precision signals" is the SOC analyst, and the documented outcome is burnout and degraded judgement. That is the failure mode of a badly-designed agent cockpit for a solo developer — with the aggravating factor that a solo developer has no shift rotation.

### 4.6 What transfers, condensed

| Domain finding | Verified source | Transfer to agent supervision |
|---|---|---|
| One alarm per 10 min normal; 10 in first 10 min after upset | HSE CHIS6 / EEMUA 191 p.37 | A hard, measurable rate budget for the cockpit's attention channel |
| ~3 priorities, 5/15/80 split; each with a defined response | HSE CHIS6 / EEMUA 191 p.65 | Three tiers; no tier without a defined user action |
| Status indicators must not be alarms | HSE CHIS6 | Tool calls, diffs, token ticks → never alarms |
| 275 alarms in 11 min preceded a fatal explosion | HSE CHIS6 | Alarm floods are the documented failure mode, not an inconvenience |
| 88.8% false arrhythmia alarms; ~1,070 alarms/bed/day | Drew et al. 2014 | What an unbudgeted alarm system looks like at scale |
| Operators probability-match to alarm reliability (~90% of people) | Bliss et al. 1995 | False alarms degrade the whole channel, not just the noisy alert |
| Below 0.70 reliability, automation is worse than none | Wickens & Dixon 2007 | Shippable acceptance threshold for the "needs attention" detector |
| Likelihood displays beat binary alarms, without added load | Sorkin et al. 1988 | Graded confidence meter, not a red dot |
| Threshold is numeric, visible, dynamic, two-tier, predictive (1.5–2.5 h look-ahead), transient-filtered (>5 min sustained) | FAA JO 7210.3 §18-9 | The exact shape of a capacity/attention meter for a fleet |
| Recurring alerts ⇒ redesign the sector, not more alerting | FAA JO 7210.3 §18-9 | Repeated same-cause alarms are a product bug |
| ~30 min ceiling on monitoring for rare events | Bainbridge 1983 (citing Mackworth) | Never require sustained watching; alarm-driven only |
| Vigilance is hard mental work and stressful | Warm et al. 2008 | "Just watch the dashboard" is a cost, not a rest state |
| Passive processing ⇒ loss of SA ⇒ bad takeover | Endsley & Kiris 1995 | Re-entry must actively rebuild state, not just show it |
| Complacency arises under multi-task load; not trainable away | Parasuraman & Manzey 2010 | Cannot be fixed with docs or user education |
| Capacity −36% even in management-by-exception, from SA rebuild alone | Cummings & Mitchell 2008 | The re-entry summary *is* the capacity feature |
| Fan-out = f(neglect time / interaction time) | Goodrich & Olsen 2003 | Increase safe neglect time; decrease service time |
| ~4-chunk working memory limit | Cowan 2001 | Attended set of 3–5, not 20 |
| Resumption is cue-driven memory retrieval | Altmann & Trafton 2002 | Provide the cues explicitly at re-entry |
| Resumption cost ↑ with interruption duration and demand | Monk et al. 2008 | Longer absence ⇒ richer reconstruction |
| 25 min 26 s to resume; 2.26 intervening contexts | Mark et al. 2005 | Design for a long, contaminated gap, not a glance |
| 20 min of interrupted work ⇒ significant stress/frustration | Mark et al. 2008 | Session-length design target for the headset |
| Interruption *timing* changes emotional cost | Adamczyk & Bailey 2004 | Defer non-urgent signals to task boundaries |
| SOC analysts burn out and judge worse | Sundaramurthy et al. 2015 | The occupational endpoint of getting this wrong |

---

## Q5 — Input for a supervisor: eye-and-pinch vs keyboard vs dictation

### 5.1 Gaze is a targeting channel, not a commit channel — and it has been known since 1990

Jacob, R.J.K. (1990), "What You Look At is What You Get: Eye Movement-Based Interaction Techniques," *CHI '90*, 11–18, DOI [10.1145/97243.97246](https://doi.org/10.1145/97243.97246) — **VERIFIED**. (Journal version: *ACM TOIS* 9(3), 152–169, 1991.) The **Midas touch** problem: the eye is always looking at something, so "look = select" makes it impossible to look anywhere without acting. Jacob's resolution — gaze for targeting, a separate deliberate channel to commit — is the model Vision Pro ships 34 years later.

Apple's shipped design confirms it, **VERIFIED verbatim** from the [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures/) HIG page:

> "People use an indirect gesture by **looking at an object to target it**, and then manipulating that object from a distance — indirectly — with their hands. For example, a person can **look at a button to focus it and select it by quickly tapping their finger and thumb together.**"

Gaze focuses. Pinch commits. Apple does not publish the rationale for avoiding dwell, so the "why" below is inference, not an Apple statement.

### 5.2 What gaze pointing actually costs, measured

Zhang, X. & MacKenzie, I.S. (2007), "Evaluating Eye Tracking with ISO 9241 – Part 9," *HCI International 2007* (LNCS 4552), 779–788, DOI [10.1007/978-3-540-73110-8_85](https://doi.org/10.1007/978-3-540-73110-8_85) — **VERIFIED with numbers** from the author's own PDF:

| Technique | Throughput | Notes |
|---|---|---|
| Mouse | **4.68 bits/s** | baseline |
| Eye + spacebar (closest 2007 analogue to gaze+pinch) | **3.78 bits/s** | ~19% below mouse |

- Selection-error rate for eye+spacebar was **wildly participant-dependent: SD = 11.43%, range 3.13%–35.59%**.
- Time-out (missed) errors: **2.89%** for eye+spacebar vs **1.07%** for the mouse.

**The variance is the finding, not the mean.** A design cannot assume a stable gaze accuracy; some users will mis-select ten times more often than others. That is an argument for wide margins and a confirmation gate, not for a tuned threshold. (INFERENCE from a VERIFIED result.)

Apple's spacing rule exists for exactly this, **VERIFIED verbatim**:

> "You can help ensure that there's enough space between interactive items by using a margin of at least 16 points around the bounds of each item or by **placing items so that their centers are always at least 60 points apart**."

Note this is **centre-to-centre spacing**, not a 60×60 pt hit area (unlike iOS's 44×44 pt target rule).

### 5.3 Gaze + pinch specifically

- Pfeuffer, K., Mayer, B., Mardanbegi, D. & Gellersen, H. (2017), "Gaze + Pinch Interaction in Virtual Reality," *SUI 2017*, 99–108, DOI [10.1145/3131277.3132180](https://doi.org/10.1145/3131277.3132180) — **VERIFIED**. **Important caveat: this is the origin/concept paper.** Its own abstract says the prototypes were *"informally tested."* It is **not** measured performance data and must not be cited as such.
- Wagner, U., Lystbæk, M.N., Manakhov, P., Grønbæk, J.E.S., Pfeuffer, K. & Gellersen, H. (2023), "A Fitts' Law Study of Gaze-Hand Alignment for Selection in 3D User Interfaces," *CHI 2023*, DOI [10.1145/3544548.3581423](https://doi.org/10.1145/3544548.3581423) — **BIBLIOGRAPHIC verified; numbers not extracted.** Confirmed qualitative finding: gaze-assisted techniques beat hands-only baselines, but **gaze+pinch efficiency degrades with increasing target depth, due to parallax.**
- Lystbæk, M.N. et al. (2022), "Gaze-Hand Alignment," *PACM HCI* (ETRA 2022), DOI [10.1145/3530886](https://doi.org/10.1145/3530886) — **BIBLIOGRAPHIC verified.**
- Pfeuffer, K., Gellersen, H. & González-Franco, M. (2024), "Design Principles and Challenges for Gaze + Pinch Interaction in XR," *IEEE CG&A*, DOI [10.1109/MCG.2024.3382961](https://doi.org/10.1109/mcg.2024.3382961) — **BIBLIOGRAPHIC verified.** Post-Vision-Pro synthesis of the tradeoffs.

**The depth-parallax finding matters for a cockpit** that puts agent cards at several depths: selection accuracy degrades with depth. Combined with the HIG's "people need to refocus their eyes to perceive each difference in depth, and doing so too often or quickly can be tiring," depth-layering the interactive elements is doubly penalised. (INFERENCE from two VERIFIED sources.)

**Evidence gap, stated plainly:** targeted searches found **no peer-reviewed study benchmarking Vision Pro's own eye tracker** (accuracy, latency, ISO 9241-9 throughput). Comparable data exists for other HMDs (e.g. Schuetz & Fiehler 2022 on Vive Pro Eye, **BIBLIOGRAPHIC only**). Claims that "Vision Pro selects the wrong button" are press and anecdote, not measurement.

### 5.4 Keyboard is the only channel with confirmed near-desktop performance

Knierim, P., Schwind, V., Feit, A.M., Nieuwenhuizen, F. & Henze, N. (2018), "Physical Keyboards in Virtual Reality: Analysis of Typing Performance and Effects of Avatar Hands," *CHI 2018*, DOI [10.1145/3173574.3173919](https://doi.org/10.1145/3173574.3173919) — **abstract VERIFIED**. N=32.

- **Experienced touch typists**, with hand visualisation, reached near-outside-VR performance.
- **Inexperienced typists**, with a semi-transparent hand overlay, typed **just 5.6 WPM slower** than a regular desktop setup.

Grubert, J. et al. (2018), "Effects of Hand Representations for Typing in Virtual Reality," *IEEE VR 2018*, DOI [10.1109/VR.2018.8446250](https://doi.org/10.1109/vr.2018.8446250) — **abstract VERIFIED**. N=24, four hand representations. Fingertip visualisation and video inlay produced "statistically significant lower text entry error rates" than no-hand or IK-model representations; **"no statistical differences in text entry speed."**

**These two must be read against §2.3.** Grubert et al. (2018, *Text Entry in Immersive HMD-Based VR Using Standard Keyboards*) measured novices retaining **~60% of desktop speed**. Knierim et al. measured experienced touch typists at near-baseline. The reconciliation is that **hand visibility and prior touch-typing skill are the variables**, and both cut in the same direction: give the user a real keyboard and let them see their hands. (INFERENCE.)

**UNVERIFIED, deliberately not quoted:** virtual/pinch keyboard WPM in VR. The general finding that it is far worse is widely repeated, but no primary number was confirmed this session.

### 5.5 Dictation is fast, and leaves more residual errors

Ruan, S., Wobbrock, J.O., Liou, K., Ng, A. & Landay, J.A. (2018), "Comparing Speech and Keyboard Text Entry for Short Messages in Two Languages on Touchscreen Phones," *PACM IMWUT* 1(4), DOI [10.1145/3161187](https://doi.org/10.1145/3161187) — **abstract VERIFIED with numbers**:

> "…with speech recognition, the English input rate was **2.93 times faster (153 vs. 52 WPM)**, and the Mandarin Chinese input rate was **2.87 times faster (123 vs. 43 WPM)** than the keyboard for short message transcription under laboratory conditions… although speech made **fewer errors during entry (5.30% vs. 11.22% corrected error rate)**, it **left slightly more errors in the final transcribed text (1.30% vs. 0.79% uncorrected error rate)**."

**That last clause is the one that matters for steering an agent.** Speech is ~3× faster and *feels* cleaner during entry, but leaves ~1.6× more errors in the committed text. For a channel whose output is an instruction to an autonomous process that will act on it, residual error rate is the cost that counts, not entry speed. (INFERENCE from a VERIFIED result.)

**Code and identifiers: an honest gap.** No peer-reviewed measurement of ASR word error rate on programming identifiers or symbols was found. The indirect evidence is that the entire voice-programming field exists because plain dictation fails on code: Arnold, S.C., Mark, L. & Goldthwaite, J. (2000), "Programming by voice, VocalProgramming," *ASSETS 2000*, DOI [10.1145/354324.354362](https://doi.org/10.1145/354324.354362) — **VERIFIED**; Désilets, A. (2001), "VoiceGrip: A Tool for Programming-by-Voice," *Int. J. Speech Technology*, DOI [10.1023/A:1011323308477](https://doi.org/10.1023/a:1011323308477) — **VERIFIED**. Both built constrained command grammars rather than use open dictation.

**Social cost of voice is measured and does not fade.**
- Rico, J. & Brewster, S. (2010), "Usable Gestures for Mobile Interfaces: Evaluating Social Acceptability," *CHI 2010* — **VERIFIED** (PDF fetched from the author's page). Acceptability drops sharply with audience: roughly **~51% with strangers present vs ~88% when alone** for the conditions reported. *(Figures came through the extraction step; treat as primary but paraphrase-level precision.)*
- Koelle, M., El Ali, A., Cobus, V., Heuten, W. & Boll, S. (2017), "All about Acceptability? Identifying Factors for the Adoption of Data Glasses," *CHI 2017*, DOI [10.1145/3025453.3025749](https://doi.org/10.1145/3025453.3025749) — **abstract VERIFIED**. A longitudinal study, N=118, spanning **2014–2016**, found **"no significant change in attitude towards more positive attitude."** Negative social perception of head-worn devices **did not fade with familiarity over two years.** An expert survey (N=51) found utility and usability were valued above social acceptability for long-term adoption.
- Pandey, L., Hasan, K. & Arif, A.S. (2021), "Acceptability of Speech and Silent Speech Input Methods in Private and Public," *CHI 2021*, DOI [10.1145/3411764.3445430](https://doi.org/10.1145/3411764.3445430) — **abstract VERIFIED**. People find silent speech more socially acceptable than they are willing to tolerate its errors — a real tension for any voice-based confirm/reject UI.

**No study was found** measuring error rates for short confirmatory commands ("approve", "stop") versus open dictation. The claim that low-perplexity closed vocabularies have far lower WER is a standard ASR property but is **not backed here by a specific citation** — flagged as inference.

### 5.6 Confirmation design for irreversible actions

Norman, D.A. (1983), "Design rules based on analyses of human error," *CACM* 26(4), 254–258, DOI [10.1145/2163.358092](https://doi.org/10.1145/2163.358092) — **VERIFIED**. The slips/mistakes taxonomy: a **slip of action** is where "the user's intention was proper, but the results did not conform to intention." The remedy is a **forcing function** — making the unintended action structurally hard to complete — not a warning the user must notice afterwards.

**Synthesis (INFERENCE, resting on VERIFIED sources):** an irreversible agent action — merge, push, deploy, delete, spend — should require a **channel switch**, not a repeat of the same gesture. Gaze+pinch is the browsing channel; if approve is also gaze+pinch, an accidental pinch on a focused card is a single slip away from an irreversible act, and §5.2 says mis-selection rates vary by an order of magnitude between users. A second, distinct channel (keyboard key, a held gesture, an explicit spoken keyword within a short window) converts the slip into something structurally hard to do by accident.

### 5.7 Multimodal precedent

- Bolt, R.A. (1980), "'Put-That-There': Voice and Gesture at the Graphics Interface," *SIGGRAPH '80*, DOI [10.1145/800250.807503](https://doi.org/10.1145/800250.807503) — **VERIFIED**. The origin of combining a fast-but-ambiguous channel with a precise-but-slow one.
- Zhai, S., Morimoto, C. & Ihde, S. (1999), "Manual and Gaze Input Cascaded (MAGIC) Pointing," *CHI '99*, DOI [10.1145/302979.303053](https://doi.org/10.1145/302979.303053) — **VERIFIED**. Gaze warps the cursor near the target; the manual channel does fine positioning and commits. The direct conceptual ancestor of gaze+pinch.

**No study was found** on whether adding voice *on top of* gaze+pinch helps. That is an open gap, not a negative result.

### 5.8 Dwell, and why it is not the answer

- Majaranta, P. & Räihä, K-J. (2002), "Twenty Years of Eye Typing," *ETRA '02*, DOI [10.1145/507072.507076](https://doi.org/10.1145/507072.507076) — **VERIFIED**. The canonical dwell survey; the technique's mature home is assistive technology, where hands are unavailable.
- Velichkovsky, B., Rumyantsev, M. & Morozov, M. (2014), "New Solution to the Midas Touch Problem," *Procedia CS*, DOI [10.1016/j.procs.2014.11.012](https://doi.org/10.1016/j.procs.2014.11.012) — **VERIFIED existence**. Evidence that dwell's speed/false-positive tradeoff was still an open problem in 2014.

**INFERENCE (Apple publishes no rationale):** dwell has a structural tradeoff — short thresholds trigger Midas-touch activations during ordinary reading; long thresholds make the UI feel sluggish. In a cockpit full of dense text the user must *read*, dwell is the worst possible commit mechanism: reading is exactly the activity that produces long fixations.

### 5.9 Verdict per action type

| Action | Recommended channel | Evidence basis |
|---|---|---|
| Browse / focus an agent | Gaze | Jacob 1990; Apple HIG |
| Select / open / expand | Gaze + pinch | Apple HIG; Zhang & MacKenzie 2007 throughput acceptable |
| **Approve an irreversible action** | **Distinct second channel (keyboard key, held gesture, or explicit spoken keyword)** | Norman 1983 forcing functions; Zhang & MacKenzie error variance |
| Reject / stop / pause | Gaze + pinch is acceptable (reversible, and fail-safe direction) | INFERENCE: the error cost is asymmetric |
| Short steering ("run the tests", "use approach B") | Dictation acceptable | Ruan et al. 2018 (2.93× faster) |
| Long steering / any code, identifiers, paths | **Physical keyboard, or defer to the Mac** | Ruan et al. residual error rate; Arnold 2000/Désilets 2001; Grubert 2018 (~60% speed) |
| Anything in a shared or public space | Not voice | Rico & Brewster 2010; Koelle et al. 2017 |

---

## Q6 — Prior art for multi-agent supervision in a headset

### 6.1 The direct answer: none found

**No shipping product, and no credible research prototype, for supervising multiple autonomous AI/LLM agents inside a headset (VR/AR/visionOS) was found.** This was tested against:

- arXiv searches for `XR multi-agent LLM supervision`, `drone swarm virtual reality supervisory control`, `human swarm interaction augmented reality supervisory control` — **arXiv's own response was "produced no results"** (fetch-verified).
- Semantic Scholar API on "agent supervision extended reality" — rate-limited (429), so **inconclusive rather than negative**.
- Direct fetches for Vision Pro AI-agent-monitoring demos and spatial mission-control dashboards — nothing relevant.

Stated with the caveat it deserves: the session's WebSearch budget was exhausted, so this is **well-triangulated but not exhaustive**. It is a genuine gap, not a claim of exhaustive proof.

### 6.2 Nearest analogue A — multi-robot supervisory control in VR (real, but robots)

- Kennel-Maushart, Poranne & Coros (2021), "Manipulability optimization for multi-arm teleoperation," arXiv [2102.05414](https://arxiv.org/abs/2102.05414) — a VR interface for simultaneously controlling **multiple** collaborative robot arms. The closest published thing to "one human, one headset, several semi-autonomous agents."
- Moyen, Krohn, Lueth, Pompetzki, Peters, Prasad & Chalvatzaki (2025), "The Role of Embodiment in Intuitive Whole-Body Teleoperation for Mobile Manipulation," arXiv [2509.03222](https://arxiv.org/abs/2509.03222) — embodiment and VR feedback effects on teleoperation workload.
- Mandlekar et al. (2018), *RoboTurk*, arXiv [1811.02790](https://arxiv.org/abs/1811.02790) — crowdsourced multi-operator/multi-robot teleoperation, but **mobile device, not headset**.
- **UNVERIFIED and deliberately excluded:** NASA JPL's OnSight / ProtoSpace VR tools for Mars rover operations. Frequently cited, could not be confirmed this session (Wikipedia's JPL article has no mention; a direct jpl.nasa.gov URL 404'd). Not relied on.

### 6.3 Nearest analogue B — 2D multi-agent monitoring UIs (real, and the actual state of the art)

- **Devin 2.0 (Cognition)** — users "spin up multiple parallel Devins, each equipped with its own interactive, cloud-based IDE." → [cognition.com/blog/devin-2](https://cognition.com/blog/devin-2). The dashboard's visual layout is **not described** in the source; UI specifics **UNVERIFIED**.
- **Claude Code on the web (Anthropic)** — "run multiple tasks in parallel across different repositories from a single interface," each in "its own isolated environment with real-time progress tracking," steerable mid-run. → [claude.com/blog/claude-code-on-the-web](https://claude.com/blog/claude-code-on-the-web). Visual presentation again not detailed.
- **Cursor background agents, OpenAI Codex cloud, Factory** — real and known, but docs were not fetchable this session; **no session-verified description of their supervision UI**.
- **A long tail of community TUI/desktop dashboards** (real HN-indexed posts, repos not opened): Amux, "Claude Dashboard" (k9s-style TUI over tmux), Seshions, Claude Code Agent Farm, "Executive", Termoil, Workz (5 agents on parallel git worktrees), "Claude Control" (macOS menu-bar dashboard). **All terminal, TUI or desktop. None spatial.**

One creator's framing, quoted in the HN listing, is the cleanest statement of the problem: *"the bottleneck was never the agents, it was managing them."*

- Academic 2D adjacents: *ChatDev 2.0* (arXiv [2609.00714](https://arxiv.org/abs/2609.00714)) ships "an integrated visual interface [that] lets users author, run, monitor, and inspect" multi-agent systems; *LightVA* (arXiv [2411.05651](https://arxiv.org/abs/2411.05651)) uses a task-flow diagram to monitor an LLM agent's planning; *CivBench* (arXiv [2609.02459](https://arxiv.org/abs/2609.02459)) introduces a "Proactive Monitoring Rate" metric for tool-mediated agent oversight.

### 6.4 What this means

The intersection is empty. That is simultaneously the opportunity and the warning: **nobody has validated that spatial supervision of software agents is better than a 2D dashboard**, and the closest domain with real evidence (multi-robot supervisory control) is about spatial tasks — robots move in space, so a spatial interface has an obvious referent. Agent sessions are text. The spatial affordance has to be *earned* by something other than "it's 3D." (INFERENCE.)

---

## Ranked design decisions

Ranked by expected impact on whether the product works. Each states the evidence and the confidence.

### 1. One window. The default view is a fleet overview; terminals are drilled into, one at a time.
**Evidence:** Apple states it three separate times ("Ideally, keep your app's interface in a single window"; "Avoid displaying too many windows"; "minimize the amount of windows needed"), and re-states the Shared Space model unchanged at WWDC26. Independently, multiple resource theory (Wickens 2008) predicts N text panes interfere maximally because they compete for one resource; Cowan's ~4-chunk limit caps what can be held about the fleet. **Confidence: high** — platform guidance and cognitive theory agree, and this is the single most consequential decision.
**Consequence:** the macOS product's "many concurrent embedded terminals" layout does not port. It must be re-conceived as *one board with N cards, one of which can be expanded*.

### 2. Give the attention channel a rate budget, and enforce it in code.
**Evidence:** EEMUA 191 via HSE CHIS6 — "no more than one every ten minutes" in normal operation, "no more than ten displayed in the first ten minutes following a major plant upset"; 275 alarms in 11 minutes preceded a fatal explosion; Drew et al. 2014 measured ~1,070 alarms/bed/day with 88.8% false arrhythmia alarms as the counter-example. **Confidence: high** — this is codified industrial standard practice validated by fatalities.
**Consequence:** a hard limiter on how often the cockpit may demand attention, plus telemetry on the actual rate. If the rate exceeds budget, the product is broken and should say so.

### 3. Make "what happened while you were away" the flagship feature, not the live view.
**Evidence:** Cummings & Mitchell 2008 — even in a management-by-exception system, operator capacity fell **36%** purely from situation-awareness rebuild time. Mark et al. 2005 — 25 min 26 s to resume, through 2.26 intervening contexts. Altmann & Trafton 2002 — resumption is cue-driven memory retrieval, so the interface can supply the cues. Monk et al. 2008 — resumption cost scales with gap duration and demand. Endsley & Kiris 1995 — passive processing degrades SA and cripples takeover. **Confidence: high** — four converging peer-reviewed sources.
**Consequence:** per agent, on return: what changed, position against plan, what it wants and by when, and what it will do if you say nothing. Not a scrollback. Richer reconstruction for longer absences.

### 4. Build the capacity indicator the way ATC builds MAP.
**Evidence:** FAA JO 7210.3 §18-9 — numeric trigger, **dynamic** (adjusted to current capability), **two-tier** (yellow analysed, red always actioned and logged), **predictive** (1.5–2.5 h look-ahead), **transient-filtered** (act only on conditions sustained >5 min). **Confidence: high** — this is an operational system in continuous safety-critical use.
**Consequence:** the existing meter idiom is right; it needs a *threshold* and a *forecast*, not just a current value. "You are approaching the number of agents you can actually service" is the MAP analogue.

### 5. Require ~0.70 precision from the "needs attention" detector, or ship no detector.
**Evidence:** Wickens & Dixon 2007 — 20 studies, 35 data points; "a reliability of 0.70 was the 'crossover point' below which unreliable automation was worse than no automation at all." Bliss et al. 1995 — ~90% of people probability-match their response rate to alarm reliability, degrading the whole channel. **Confidence: medium-high** — the 0.70 figure is a regression crossover over a heterogeneous literature, not a constant, but the direction and the existence of a crossover are robust.
**Consequence:** a measurable acceptance gate before the feature ships. Measure precision on a held-out set of real sessions.

### 6. Signal likelihood, never a binary flag.
**Evidence:** Sorkin et al. 1988 — likelihood alarm displays improved attention allocation and "do not necessarily add to the operator's attentional load"; Fallon et al. 2005 — greater SA and reduced workload with an LAD. EEMUA's three priorities, based on "the potential consequences if the operator fails to respond," 5/15/80. **Confidence: high.**
**Consequence:** the existing "precise cockpit" language is already the right instrument — a graded meter, not a red dot. Three tiers, each with a defined user action; no tier without one.

### 7. Approvals require a channel switch.
**Evidence:** Norman 1983 (slips; forcing functions); Zhang & MacKenzie 2007 (gaze selection-error SD 11.43%, range 3.13%–35.59% — an order of magnitude of between-user variance); Jacob 1990 (Midas touch); Wagner et al. 2023 (gaze+pinch degrades with target depth). **Confidence: high.**
**Consequence:** browse and select with gaze+pinch. Commit an irreversible action with something else — a keyboard key, a held gesture, an explicit spoken keyword. Never the same gesture used to browse.

### 8. Redraw the typography for this display; the macOS idiom does not survive the port.
**Evidence:** visionOS minimum is **12 pt**, default **17 pt**; "avoid Ultralight, Thin, and Light font weights"; visionOS ships bolder body/title styles because "to improve the contrast of text against vibrant materials, font weight has been modified to be slightly heavier"; "prefer 2D text"; white text by default because coloured elements on glass may be hard to see. A point is an **angle**, so pushing the window further away buys no legibility. **Confidence: high.**
**Consequence:** hairlines and thin tabular digits are the wrong instrument here. Keep the *idiom* — precision, alignment, restraint — and re-express it in weights the display can hold. Re-test the reserved blue against passthrough; it may need to become a shape or position cue with white as the carrier.

### 9. Lay out wide, world-locked, at least a metre away, with as few depth planes as possible.
**Evidence:** "aim to place it at least one meter away"; "avoid anchoring content to the wearer's head"; "it's easier for most people to turn their head farther to the right and to the left rather than up and down… go with a wider aspect ratio than taller"; "People need to refocus their eyes to perceive each difference in depth, and doing so too often or quickly can be tiring." Independently corroborated by Rzayev et al. 2021, where **head-fixed paragraph text was the worst cell on task load, errors, usability and preference.** visionOS 27 moves the platform the same way: "windows can now be adjusted to a wider aspect ratio… Larger windows will naturally curve." **Confidence: high** — Apple guidance and independent measured data agree.

### 10. Shared Space + Window. Mixed immersion at most. Never full immersion by default.
**Evidence:** "Use windows for contained, UI-centric experiences"; "Prefer launching your app or game in the Shared Space"; "find the minimum level of immersion that suits it best." Volume is for bounded 3D content; a terminal is not that. **Confidence: high.**
**Note:** Prompt 3's "Terminal 33" immersive space is a real counter-example of a shipping terminal using immersion — as an *optional theme*, not the default working mode. That is the correct shape if immersion is offered at all.

### 11. Design the session at 20–30 minutes, with an explicit good exit.
**Evidence:** Biener et al. 2022 — 12.5% dropout, one participant at 4 hours and one at ~2 hours; +48% eye strain, +42% frustration, +35% task load, SSQ 34.3 vs 9.21 over a week of 8-hour days. Mark et al. 2008 — "After only 20 minutes of interrupted performance people reported significantly higher stress, frustration, workload, effort, and pressure." Bainbridge 1983 — "impossible for even a highly motivated human being to maintain effective visual attention towards a source of information on which very little happens, for more than about half an hour." **Confidence: high** — three independent lines converge on the same interval.
**Consequence:** the product's unit of use is a *check-in*, not a shift. Optimise for how fast a check-in can be completed and exited, and consider making the good exit an explicit affordance.

### 12. Persist your own state defensively; the platform will not do it for you.
**Evidence:** Varrall's developer analysis — no Exposé/Mission Control equivalent, no "find my window", `scenePhase` does not reliably report dismissal, window position not programmatically restorable "without very low level, and clearly unintended, trickery", and a documented trap where closing the main window before exiting immersion quits the app. Apple Developer Forums threads report full app **restart** on window reopen and lost resize state. There is no singular `Window` — only `WindowGroup`, so duplicates can be spawned. **Confidence: medium-high** — developer reports and forum threads, not Apple documentation.
**Consequence:** every piece of supervision state must be restorable from your own store, and the app must be correct after an unannounced restart. For a tool whose entire value is "come back later," this is existential.

### 13. Text composition leaves the headset.
**Evidence:** Grubert et al. 2018 — novices retain ~60% of desktop typing speed in VR, with **no significant learning effect within the session**. Knierim et al. 2018 — touch typists reach near-baseline *with hand visualisation*, non-touch typists are 5.6 WPM slower. Ruan et al. 2018 — dictation is 2.93× faster but leaves **1.30% vs 0.79% uncorrected errors**. Arnold 2000 / Désilets 2001 — the voice-programming field exists because open dictation fails on code. **Confidence: high.**
**Consequence:** short steering by dictation is fine. Anything containing an identifier, a path, or code goes to a physical keyboard or is deferred to the Mac. Design an explicit, graceful "finish this on the Mac" handoff rather than pretending the headset can do it.

### 14. Automate acquisition and analysis; never automate decision or action.
**Evidence:** Parasuraman, Sheridan & Wickens 2000 — four function classes (acquisition, analysis, decision/action selection, action implementation), each on a continuum; "automation does not merely supplant but changes human activity and can impose new coordination demands." Parasuraman & Manzey 2010 — complacency arises under multi-task load, is found in experts, and "cannot be overcome with simple practice"; automation bias "cannot be prevented by training or instructions." Lee & See 2004 — trust must be calibrated, not maximised. **Confidence: high.**
**Consequence:** the cockpit may detect, rank, summarise and forecast. It must not auto-approve. And because complacency cannot be trained away, "the user will learn to check" is not a mitigation.

### 15. Treat repeated same-cause alarms as a product bug, and instrument for it.
**Evidence:** FAA JO 7210.3 §18-9 — "When a pattern of alerts is established… additional analysis will be conducted. The analysis should result in recommendations to address the identified constraint," escalating to sector redesign. HSE — nuisance-alarm symptoms are "large numbers of alarms acknowledged in quick succession" or "audible alarms regularly turned off." **Confidence: high.**
**Consequence:** ship alarm-rate and acknowledge-latency telemetry as a first-class internal metric, and treat a recurring alarm pattern as a defect to fix at source rather than a threshold to tune.

### 16. Earn the spatial affordance, or do not ship it.
**Evidence:** the intersection of "multi-agent supervision" and "headset" is empty (Q6). The nearest domain with real evidence — multi-robot supervisory control in VR — is about agents that *move in space*, which gives the spatial interface a natural referent. Agent sessions are text. Meanwhile Mac Virtual Display's 32:9 ultrawide is a credible substitute for most of what a spatial cockpit would show. **Confidence: medium** — an argument from an absence, plus a real competing product.
**Consequence:** identify what the spatial version does that the 2D cockpit plus an ultrawide Mac screen cannot. Plausible candidates (all **INFERENCE**, none validated): persistent peripheral placement of a fleet meter outside the Mac screen's rectangle; a physically-stable arrangement that survives context switches; the ability to glance at fleet state without occluding the work surface. If none of these survives contact with a prototype, the honest answer is that this should stay on the Mac.

---

## What the evidence says NOT to do

Each item is an explicit prohibition with its source.

1. **Do not open one window per agent session.** Apple: "Avoid displaying too many windows… making them feel overwhelmed, constricted, and even uncomfortable"; "Ideally, keep your app's interface in a single window." This is the named anti-pattern.
2. **Do not head-lock the terminal or any long-form text.** Apple: "Avoid anchoring content to the wearer's head… can make them feel stuck, confined, and uncomfortable." Rzayev et al. 2021 measured head-fixed paragraph text as the worst condition on task load, errors, usability *and* preference.
3. **Do not put agents at different depths to encode status.** Apple: "People need to refocus their eyes to perceive each difference in depth, and doing so too often or quickly can be tiring." Wagner et al. 2023: gaze+pinch selection degrades with target depth. Two independent penalties for the same choice.
4. **Do not render terminal text in 3D, or add shadows or extrusion to it.** Apple: "In general, avoid adding depth to text. Text that appears to hover above its background is difficult to read"; "Keep text flat when used as an interface element"; "you generally want to avoid adding shadows."
5. **Do not carry hairlines and Ultralight/Thin/Light weights across from macOS.** Apple: "avoid Ultralight, Thin, and Light font weights"; visionOS deliberately ships *bolder* body and title styles for contrast against vibrant materials.
6. **Do not assume pushing a window further away lets you fit more text.** A point on visionOS is an angle; dynamic scale keeps apparent size constant. Distance buys no legibility.
7. **Do not remove the window's glass background for a "pure" dark terminal look.** Apple: "Removing the glass material tends to cause UI elements and text to become less legible."
8. **Do not rely on colour alone — including the reserved blue — for state on glass.** Apple: "Colorful elements on top of the glass may be hard to see if the color of the glass is similar… consider using white text or symbols."
9. **Do not raise an alarm for a status change.** HSE/EEMUA: "process status indicators should not be designated as alarms"; every alarm must "have a defined response." Tool calls, diffs and token ticks are status.
10. **Do not exceed the alarm rate budget.** EEMUA via HSE: one per ten minutes in normal operation, ten in the first ten minutes after an upset. 275 in 11 minutes is the documented catastrophe.
11. **Do not ship a binary "needs attention" flag.** Sorkin et al. 1988; EEMUA's three graded priorities based on consequence of non-response.
12. **Do not ship an attention detector below ~0.70 precision.** Wickens & Dixon 2007: below the crossover, "unreliable automation was worse than no automation at all." Bliss et al. 1995: users probability-match and down-weight the whole channel.
13. **Do not expect users to selectively ignore only the noisy alerts.** ~90% probability-match across the channel (Bliss et al. 1995).
14. **Do not rely on training, documentation or user vigilance to fix complacency.** Parasuraman & Manzey 2010: found in experts, "cannot be overcome with simple practice"; automation bias "cannot be prevented by training or instructions."
15. **Do not design a mode that requires sustained watching of mostly-quiet streams.** Bainbridge 1983: "humanly impossible to carry out the basic function of monitoring for unlikely abnormalities." Warm et al. 2008: vigilance "requires hard mental work and is stressful" — it is not a rest state.
16. **Do not inject synthetic activity to keep the supervisor engaged.** Bainbridge 1983: "It would be a mistake, however, to increase artificially the rate of computer failure as the operator will then not trust the system."
17. **Do not make approve and browse the same gesture.** Norman 1983 forcing functions; gaze selection error varies from 3.13% to 35.59% between users (Zhang & MacKenzie 2007).
18. **Do not use dwell selection anywhere.** Dwell's failure mode is triggering on long fixations — which is exactly what reading produces. (INFERENCE from Jacob 1990 and Majaranta & Räihä 2002; Apple publishes no rationale but ships pinch instead.)
19. **Do not dictate code, identifiers or paths.** Ruan et al. 2018: dictation leaves 1.30% vs 0.79% uncorrected errors; Arnold 2000 and Désilets 2001 exist because open dictation fails on code.
20. **Do not assume voice becomes socially acceptable with familiarity.** Koelle et al. 2017, N=118 over 2014–2016: "no significant change in attitude towards more positive attitude."
21. **Do not auto-approve anything, at any confidence level.** Parasuraman, Sheridan & Wickens 2000: keep decision/action selection low on the automation continuum when action costs are high.
22. **Do not assume the platform will restore your windows or state.** No Exposé equivalent, no "find my window", unreliable `scenePhase`, documented app restarts on window reopen (Varrall; Apple Developer Forums).
23. **Do not design for multi-hour wear.** Biener et al. 2022: 12.5% dropout, one at 4 hours and one at ~2 hours, +48% eye strain across a five-day study.
24. **Do not claim a spatial productivity benefit.** No controlled study measuring a productivity gain from virtual/"infinite" monitors was found. It is an enthusiast narrative, not evidence.
25. **Do not build this expecting to beat Mac Virtual Display at showing text.** 32:9 ultrawide Mac mirroring is the platform's actual killer app; a native cockpit must complement it, not duplicate it.

---

## Verified findings vs inference — the separation

**Verified with primary sources and links** (see the per-question sections for exact quotes and URLs):
- All Apple HIG and WWDC quotations, including the WWDC26/visionOS 27 currency check.
- Biener et al. 2022 numbers; Rzayev et al. 2021 numbers; Grubert et al. 2018 (both papers); Knierim et al. 2018; Ruan et al. 2018; Zhang & MacKenzie 2007.
- Hoffman et al. 2008 and Shibata et al. 2011 abstracts; Apple's published device weight.
- HSE CHIS6 alarm rates, priority split, and the 275-alarms figure; FAA JO 7210.3 §18-9 in full; Drew et al. 2014 numbers.
- Bainbridge 1983 verbatim; Mark et al. 2005 and 2008 verbatim from the papers.
- Abstract-level verification for: Warm et al. 2008, Endsley 1995, Endsley & Kiris 1995, Parasuraman et al. 2000, Parasuraman & Manzey 2010, Lee & See 2004, Wickens & Dixon 2007, Wickens 2008, Sorkin et al. 1988, Fallon et al. 2005, Bliss et al. 1995, Cvach 2012, Cowan 2001, Altmann & Trafton 2002, Monk et al. 2008, Adamczyk & Bailey 2004, McFarlane 2002, Loft et al. 2007, Goodrich & Olsen 2003, Crandall & Cummings 2007, Cummings & Mitchell 2008, Sundaramurthy et al. 2015, Norman 1983, Koelle et al. 2017, Pandey et al. 2021.
- The visionOS terminal apps named in Q3, and the absence of any headset multi-agent supervision prior art in Q6.

**Inference, clearly mine, not findings:**
- That a wall of terminals fails specifically because of multiple-resource competition rather than window count alone.
- That the alarm-rate budget transfers numerically from process control to agent supervision at the same order of magnitude.
- That the re-entry summary is the product's core feature rather than a convenience.
- That the "precise cockpit" visual language needs re-weighting rather than replacement.
- That approve should require a channel switch (the principle is Norman's; the application is mine).
- That the spatial affordance has not yet been earned.
- The entire ranked-decision list, which is design judgement built on the evidence above.

**Bibliographic only — cited, abstract or full text not obtained:** See et al. 1995 (no abstract available anywhere I could reach); Getty et al. 1995; Trafton et al. 2003; Wagner et al. 2023 and Lystbæk et al. 2022 (qualitative finding only, no numbers); Schuetz & Fiehler 2022.

**Explicitly unverified and not relied upon:** the "23 min 15 s" resumption figure (the verified number is 25 min 26 s); the "~⅓ dioptre zone of comfort"; Vision Pro's fixed focal distance in metres; Apple's break-reminder interval; virtual-keyboard WPM figures in VR; McFarlane's four method names; NASA JPL OnSight/ProtoSpace; room-anchored persistent widgets on visionOS (checked and **not found** in the WWDC26 sources); 2025/2026 visionOS app counts; the specific "windows don't follow you between rooms" phrasing; CNBC's 2025 app-shortage article (403); Notion/Bezel/Jigspace/Numerics/Widgetsmith on visionOS.

**Known gaps in the literature itself** (not research failures — nobody has done these):
- No controlled study of reading small text through passthrough vs. direct view.
- No Vision Pro-specific longitudinal work study equivalent to Biener et al. 2022.
- No peer-reviewed benchmark of Vision Pro's own eye tracker.
- No measurement of ASR word error rate on code identifiers.
- No study of whether adding voice on top of gaze+pinch helps.
- No controlled measurement of productivity gain from virtual monitors.
- No prior art at all for multi-agent supervision in a headset.

---

## What would change these conclusions

- A Vision-Pro-era replication of Biener et al. showing materially lower eye strain would move decision 11 (session length) and weaken the "check-in not shift" framing.
- Peer-reviewed Vision Pro eye-tracker accuracy data showing low between-user variance would weaken decision 7 (channel switch for approvals).
- Evidence of a measured productivity gain from spatial arrangement of text work would strengthen decision 16 considerably; there is currently none.
- Apple shipping reliable window persistence and a window manager would remove most of decision 12's defensive burden.
- Anyone shipping a spatial multi-agent supervisor would replace Q6's "no prior art" with real comparative data. As of 2026-09-09 there is none.

---

## Source index

**Apple (all fetched 2026-09-09)** — [Designing for visionOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos) · [Spatial layout](https://developer.apple.com/design/human-interface-guidelines/spatial-layout) · [Windows](https://developer.apple.com/design/human-interface-guidelines/windows) · [Ornaments](https://developer.apple.com/design/human-interface-guidelines/ornaments) · [Eyes](https://developer.apple.com/design/human-interface-guidelines/eyes) · [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures/) · [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) · [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) · [Immersive experiences](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences) · [Entering data](https://developer.apple.com/design/human-interface-guidelines/entering-data) · [Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards) · [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards) · [WWDC23 10072](https://developer.apple.com/videos/play/wwdc2023/10072/) · [WWDC23 10076](https://developer.apple.com/videos/play/wwdc2023/10076/) · [WWDC24 10086](https://developer.apple.com/videos/play/wwdc2024/10086/) · [WWDC25 303](https://developer.apple.com/videos/play/wwdc2025/303/) · [WWDC26 287](https://developer.apple.com/videos/play/wwdc2026/287/) · [WWDC26 234](https://developer.apple.com/videos/play/wwdc2026/234/) · [WWDC26 250](https://developer.apple.com/videos/play/wwdc2026/250/) · [WWDC26 277](https://developer.apple.com/videos/play/wwdc2026/277/) · [Mac Virtual Display user guide](https://support.apple.com/guide/apple-vision-pro/use-mac-virtual-display-tan357ede966/visionos) · [Vision Pro specs](https://www.apple.com/apple-vision-pro/specs/)

**Standards and operational documents** — [HSE, *Better alarm handling*, CHIS6](https://www.hse.gov.uk/pubns/chis6.pdf) (citing EEMUA 191) · [FAA Order JO 7210.3, Ch. 18 §9, Monitor Alert Parameter](https://www.faa.gov/air_traffic/publications/atpubs/foa_html/chap18_section_9.html) · [HSE Texaco Milford Haven 1994 case summary](https://www.hse.gov.uk/comah/sragtech/casetexaco94.htm) · ANSI/ISA-18.2 and EEMUA 191 ed.3 (2013) cited but not obtained

**Peer-reviewed literature** — full citations with DOIs are given inline in Q2, Q4 and Q5 and are not repeated here.

**Industry and practitioner sources** — [Varrall, "Windowing on the Vision Pro"](https://varrall.substack.com/p/windowing-on-the-vision-pro) · [The Verge Vision Pro review](https://www.theverge.com/24054862/apple-vision-pro-review-vr-ar-headset-features-price) · [NotebookCheck on developer interest](https://www.notebookcheck.net/Apple-Vision-Pro-struggling-to-attract-developer-interest.738466.0.html) · [TechCrunch on app counts](https://techcrunch.com/2024/02/14/apples-vision-pro-now-has-over-1000-apps-specifically-designed-for-the-new-device/) · [lastweekinavp on Mac Virtual Display](https://lastweekinavp.substack.com/p/last-week-in-avp-41-mac-virtual-display) · [Panic Prompt on Vision Pro](https://help.panic.com/prompt/apple-vision-pro/) · [La Terminal](https://www.producthunt.com/products/la-terminal-ssh-client-for-vision-pro) · [Secure ShellFish](https://secureshellfish.app/) · [Blink Shell](https://blink.sh/) · [Devin 2.0](https://cognition.com/blog/devin-2) · [Claude Code on the web](https://claude.com/blog/claude-code-on-the-web)
