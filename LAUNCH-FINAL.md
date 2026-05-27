# THROTTLE LAUNCH — Lundi 26 Mai 2026 (Final)

## 🎯 STRATÉGIE VALIDÉE (NotebookLM + Competitor Research)

**Changes from original plan:**
- ❌ DROP r/ClaudeAI (Rule 4 ban confirmed)
- ✅ ADD r/ShowYourApp, r/IMadeThis (self-promo friendly)
- ✅ Launch time: 21:00 Paris (12:01 AM PT Tuesday for full 24h PH cycle)
- ✅ Add promo code PRODUCTHUNT30 (-30% = €6.30 for 72h)
- ✅ Emphasize "Free tier" as trial (meter-only, no new code needed)

---

## ⏰ TIMELINE — Lundi 26 Mai 2026

### Matin (8h-20h):
- **8h-12h:** Create assets
  - Screenshots via Xcode Canvas (4 variants)
  - 30s video demo (QuickTime recording)
  - GIF animé (export from video)

- **12h-15h:** Asset polish
  - Compress video (ffmpeg)
  - Optimize screenshots (PNG crush)
  - Test all links

- **15h-20h:** Final checks
  - Spell-check all posts
  - Verify Stripe payment link works
  - Test DMG download

### Soir (21h-23h) — LAUNCH:

**21:00 Paris (12:01 AM PT)** → Product Hunt
**21:30 Paris** → Twitter thread
**22:00 Paris** → r/SideProject  
**22:30 Paris** → r/ShowYourApp
**23:00 Paris** → r/IMadeThis

**Mardi 27 Mai:**
**10:00 Paris** → r/MacApps (1 post/30 days rule)

---

## 💳 STRIPE PROMO CODE — ph-launch-may26

**✅ ALREADY CREATED via API:**

- **Coupon ID:** `ph-launch-may26`
- **Discount:** 30% off
- **Duration:** Once (applies to single purchase)
- **Status:** Active
- **Payment link (coupon auto-applied):** `https://buy.stripe.com/cNi4gA8LvdeM9jp7Ijds402?prefilled_promo_code=ph-launch-may26`

**Mention in all posts:**
> "🎁 Product Hunt exclusive: Use code **ph-launch-may26** for 30% off (€6.30 instead of €9) — valid 72 hours."

**Note:** If needed, users can also enter `ph-launch-may26` manually at checkout.

---

## 📱 PRODUCT HUNT

### Tagline:
```
Cut Claude Code token usage by 70% — never hit limits mid-session
```

### Description:
```
Throttle is a native macOS menu bar app that gives you real-time usage tracking + token optimization for Claude Code.

**The Problem:**

Claude Code has zero usage visibility. You're mid-workflow with an AI agent (iterating on complex tasks, using tools, building features), then suddenly: "You've hit your limit." Session dead, context lost.

After hitting this limit 3 times in one week, I reverse-engineered Claude Code's tracking and built Throttle.

**The Solution:**

1. **Real-time usage meter** (5-hour + weekly limits)
   Never get blindsided again. Menu bar shows exactly where you stand.

2. **Token optimizer** (70% config savings + 60-90% CLI savings)
   - Compresses CLAUDE.md (95KB → 28KB)
   - RTK proxy filters git/ls/grep output before Claude sees it
   - Routes memory files by project
   
3. **ROI tracker**
   Live savings display: "≈€207 saved total"
   Milestone badges: 🌱 1d Pro → 🏆 Max 20×

**Safe by Design:**

Unlike aggressive token optimizers that silently rewrite output (breaking git diffs, hiding errors), Throttle only:
- Compresses config files (transparent, reversible)
- Filters CLI commands you approve
- Never touches your agent's code or conversation

**Pricing:**

- Free tier: Menu bar meter (track 5h + weekly usage)
- Pro (€9 one-time): Full optimizer + RTK proxy + ROI tracker

🎁 **Product Hunt exclusive:** Use code **ph-launch-may26** for 30% off (€6.30) — valid 72 hours.

Built for developers running agent workflows, building with AI, or hitting Claude Code limits regularly.

Native Swift 6, macOS 14+, < 10MB, zero telemetry.
```

### First Comment (Maker):
```
Hey Product Hunt! 👋

I'm Kevin, and I built Throttle after reverse-engineering where my Claude Code tokens were actually going.

**The backstory:**

I'm a solo dad of 4, building dev tools at night (Apple engineer by day). I run a homelab (Proxmox + OPNsense + Wazuh) and build everything with Claude Code.

Last month I hit the 5-hour limit 3 times in one week — always mid-session, no warning, just "You've reached your limit" and my entire context gone.

I was furious. So I dug into `~/.claude/projects/*/conversation.jsonl` and discovered:
- Every session ships 30-50K tokens of config before I even type
- CLAUDE.md alone was 95KB
- `git status` outputs were 2,000 tokens each
- Memory files were loading for projects I wasn't even touching

**What I built:**

Throttle is the menu bar app I wish existed:

1. **Real-time meter** — I can SEE my usage approaching limits (5h window + weekly caps)
2. **Config optimizer** — Compresses CLAUDE.md to 28KB, routes memory files, cleans settings
3. **RTK proxy** — CLI hook that strips verbose output (git/ls/grep) to essentials

Result: 70% savings on config, 60-90% on CLI operations.

**Why native macOS?**

I wanted something that:
- Runs silently in the menu bar
- Doesn't need Node/Python/Docker
- Respects privacy (zero telemetry, local-only)
- Feels like a Mac app

**Lessons from building this:**

1. The "compaction tax" is real — Claude Code's session-start overhead is massive
2. Most devs have NO IDEA where their tokens go until they're throttled
3. Pricing one-time vs subscription for dev tools is still controversial (I chose one-time)

Happy to answer any questions about:
- How the JSONL parsing works
- The RTK proxy architecture
- Why I chose €9 pricing
- How to avoid the pitfalls of "aggressive" token optimizers

If you use Claude Code on a Mac and this sounds useful, I'd love your feedback!

Download: https://lorislab.fr/apps/throttle.html

🎁 Use code **ph-launch-may26** for 30% off today (€6.30 instead of €9).
```

---

## 🐦 TWITTER THREAD

**Tweet 1 (Hook):**
```
Last month Claude Code ate €127 of my tokens.

Most of them were... useless.

After hitting the 5-hour limit 3× in one week, I reverse-engineered where they go.

Here's what I found (and the menu bar app I built to fix it) 🧵
```

**Tweet 2 (Problem):**
```
Claude Code has ZERO usage visibility.

You're iterating with an agent, building features, using tools...

Then: "You've reached your limit."

Session dead. Context lost. Momentum killed.

No warning. No meter. Just a wall.
```

**Tweet 3 (Discovery):**
```
I dug into ~/.claude/projects/*/conversation.jsonl

Every session ships 30-50K tokens BEFORE you type:
• CLAUDE.md: 95KB
• settings.json: bloated
• Memory files: loading for unused projects
• git status: 2,000 tokens per call

I call this the "compaction tax"
```

**Tweet 4 (Solution - Meter):**
```
So I built Throttle — a native macOS menu bar app.

Part 1: Real-time meter
• 5-hour rolling window (the hidden limit)
• Weekly usage (200K/500K tokens)
• Live MCP monitoring

Never get blindsided again.

[Screenshot: menu bar meter]
```

**Tweet 5 (Solution - Optimizer):**
```
Part 2: Token optimizer (70% savings)

• Config compression: CLAUDE.md 95KB → 28KB
• RTK proxy: Filters git/ls/grep output before Claude sees it
• Memory routing: Only load relevant projects

Example: git status 2,000 tokens → 200 tokens

[Screenshot: €207 saved banner]
```

**Tweet 6 (Safe by Design):**
```
Unlike aggressive token optimizers that silently rewrite output (breaking git diffs, hiding errors), Throttle only:

✅ Compresses config (reversible)
✅ Filters CLI you approve
❌ Never touches your agent code

Safe by design. No surprises.
```

**Tweet 7 (ROI):**
```
The math:

Max 20× plan = €184/month
Config (70%) + RTK (60-90%) ≈ €3.75/day saved

Throttle (€9 one-time) pays for itself in 2.4 days.

Live ROI tracker shows: "🏆 Saved €207 total"

[Screenshot: milestone badges]
```

**Tweet 8 (CTA):**
```
Launching on @ProductHunt today!

€9 one-time (no subscription)
macOS native, < 10MB
Free tier: menu bar meter

🎁 PH exclusive: Code ph-launch-may26 for 30% off (€6.30) — 72h only

If you build with Claude Code, I'd love your feedback:
https://lorislab.fr/apps/throttle.html

#ClaudeCode #MacApps #ProductivityTools
```

**Tag:** @AnthropicAI @ClaudeAI

---

## 📝 REDDIT POSTS

### r/SideProject

**Title:**
```
I burned €127 on Claude Code tokens in one month — here's the Mac menubar app I built to fix it (with real numbers)
```

**Body:**
```
Hey r/SideProject,

Solo dev dad of 4 here. I build dev tools at night while my kids sleep.

Last month I hit Claude Code's 5-hour limit 3 times in one week — always mid-session, no warning. After the third time, I was done being surprised.

**What I discovered:**

I reverse-engineered `~/.claude/projects/*/conversation.jsonl` (Claude Code's local usage logs) and found:

- Every session ships 30-50K tokens BEFORE you even type
- CLAUDE.md alone: 95KB
- `git status` outputs: 2,000 tokens each
- Memory files loading for projects I'm not touching

I call this the "compaction tax" — the overhead Claude Code ships with every session.

**What I built:**

**Throttle** — native macOS menu bar app:

1. **Real-time usage meter**
   - 5-hour rolling window (the invisible limit nobody tells you about)
   - Weekly caps (200K/500K depending on plan)
   - Live MCP server monitoring
   
   Never get blindsided mid-session again.

2. **Token optimizer** (70% config savings + 60-90% CLI savings)
   - Compresses CLAUDE.md (95KB → 28KB)
   - RTK proxy: CLI hook that strips `git status`, `ls`, `grep` output before Claude sees it
   - Memory routing: Only loads relevant project files
   
   Example: Normal `git status` = 2,000 tokens. RTK version = 200 tokens.

3. **ROI tracker**
   - Live savings display: "≈€207 saved total"
   - Milestone badges: 🌱 1d Pro → 🏆 Max 20× (€184 paid back)
   - Plan advisor: Tells you if you're overpaying

**Safe by design:**

I've seen Reddit threads destroying token optimizers that silently rewrite output (breaking git diffs, hiding errors). Throttle doesn't do that.

It only:
- Compresses config files (transparent, reversible)
- Filters CLI commands you approve
- Never touches your agent's code or conversation

**Technical:**

- Native Swift 6 (strict concurrency, no Electron)
- Local JSONL parser (reads Claude Code's usage logs)
- Privacy-first: zero telemetry, everything stays on your Mac
- < 10MB, menu bar app

**Pricing:**

- Free tier: Menu bar meter (track usage, avoid limits)
- Pro (€9 one-time): Full optimizer + RTK proxy + ROI tracker

🎁 **Launching on Product Hunt today** — use code **ph-launch-may26** for 30% off (€6.30 instead of €9), valid 72h.

**Why I'm sharing:**

I built this for myself, but I'm genuinely curious:
- Do other Claude Code users hit these same limits?
- Is real-time visibility something you'd want?
- What would you pay for 70% token savings?

I'm not asking you to buy it — I want honest feedback from people who actually use Claude Code daily.

**Download:** https://lorislab.fr/apps/throttle.html
**Product Hunt:** [link after launch]

Happy to answer technical questions about the JSONL parsing, RTK proxy architecture, or why I chose one-time pricing vs subscription!
```

---

### r/ShowYourApp

**Title:**
```
Throttle — macOS menu bar app to cut Claude Code token usage by 70% (launching on PH today!)
```

**Body:**
```
Hey r/ShowYourApp!

I just launched **Throttle** on Product Hunt — a native macOS menu bar app that gives you real-time Claude Code usage tracking + token optimization.

**The problem I was solving:**

I kept hitting Claude Code's 5-hour limit mid-session with no warning. After the 3rd time in one week, I reverse-engineered where my tokens were going.

Turns out: 30-50K tokens ship with EVERY session before you even type (CLAUDE.md, settings, memory files).

**What Throttle does:**

1. **Real-time meter** in your menu bar (5h + weekly usage)
2. **Token optimizer** that compresses config files + filters CLI output (70% savings)
3. **ROI tracker** showing exactly how much you've saved

**Tech stack:**

- Swift 6 (native macOS, no Electron)
- Menu bar app, < 10MB
- Zero telemetry, local-only

**Pricing:**

- Free: Menu bar meter
- €9 one-time: Full optimizer

🎁 **PH launch special:** Code **ph-launch-may26** for 30% off (€6.30) — valid 72h

**Would love your feedback:**

- Download: https://lorislab.fr/apps/throttle.html
- Product Hunt: [link after launch]

Screenshot attached showing the menu bar UI + €207 saved banner!
```

---

### r/IMadeThis

**Title:**
```
I made a Mac menu bar app to track Claude Code usage and cut token costs by 70%
```

**Body:**
```
After hitting Claude Code's usage limit 3 times in one week (always mid-session, no warning), I built **Throttle** — a native macOS menu bar app.

**What it does:**

- Shows real-time usage in your menu bar (5h + weekly limits)
- Compresses config files (95KB → 28KB = 70% savings)
- Filters CLI output before Claude sees it (60-90% savings on git/ls/grep)
- Tracks ROI with milestone badges (🏆 €184 saved = Max 20× paid back)

**Built with:**

- Swift 6, native macOS
- Menu bar app, < 10MB
- Zero telemetry

**Launching on Product Hunt today!**

- Free tier: Menu bar meter
- €9 one-time: Full optimizer

🎁 Code **ph-launch-may26** for 30% off (72h only)

Link: https://lorislab.fr/apps/throttle.html

[Screenshot]
```

---

### r/MacApps (Mardi 27 Mai)

**Title:**
```
Throttle – Native macOS menu bar app to optimize Claude Code workflows (feedback welcome)
```

**Body:**
```
Hey r/MacApps,

I built **Throttle** — a native macOS menu bar app for developers using Claude Code.

**Background:**

Claude Code has no usage visibility. You're coding, then suddenly: "You've reached your limit." Session dead, context lost.

After hitting this 3× in one week, I reverse-engineered the tracking and built a menu bar solution.

**Features:**

1. **Real-time meter** (5h + weekly usage)
2. **Token optimizer** (70% config savings + 60-90% CLI savings via RTK proxy)
3. **ROI tracker** (milestone badges: €184 saved = Max 20× paid back)

**Why macOS native:**

- Swift 6, no Electron
- < 10MB, menu bar app
- Zero telemetry, local-only
- Feels like a Mac app (not a web wrapper)

**Pricing:**

- Free: Menu bar meter
- €9 one-time: Full optimizer

Just launched on Product Hunt (#X of the day) — would love feedback from Mac users!

**Download:** https://lorislab.fr/apps/throttle.html

[Screenshots: menu bar + dropdown + €207 saved banner]
```

---

## ✅ PRE-LAUNCH CHECKLIST

### Assets:
- [ ] 30s video demo (problem → solution → ROI)
- [ ] 4 screenshots (hero €207, medium €45, early €5, free tier)
- [ ] Demo GIF (menu bar meter updating)
- [ ] Product Hunt thumbnail (1270×760)

### Links:
- [ ] Stripe promo code PRODUCTHUNT30 active
- [ ] DMG download tested
- [ ] lorislab.fr/apps/throttle.html live
- [ ] All links work (no 404s)

### Content:
- [ ] Product Hunt listing ready (save as draft)
- [ ] Twitter thread in notes app (ready to post)
- [ ] Reddit posts in text files (ready to copy/paste)
- [ ] Spell-check everything

### Tech:
- [ ] Throttle v2.9.9 signed
- [ ] Appcast.xml updated
- [ ] Demo mode tested (screenshots generated)
- [ ] Menu bar meter works

---

## 📊 SUCCESS METRICS

**Week 1 target:** 10-29 sales @ €9 (abort if 0-2)

**Product Hunt:**
- Top 10 of the day = success
- Top 5 = excellent
- Top 3 = viral

**Reddit:**
- > 50 upvotes = good
- > 100 upvotes = excellent
- < 10 upvotes = wrong subreddit or bad timing

**Twitter:**
- > 10 RT = good
- > 50 RT = excellent
- @AnthropicAI RT = jackpot

---

**READY TO LAUNCH! 🚀**
