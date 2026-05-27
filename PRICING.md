# Throttle — Pricing Structure

**Updated:** 2026-05-27  
**Source of truth for all pricing references**

---

## Current Pricing (v2.9.9)

### Free Tier
- **Price:** Free
- **What's included:**
  - Menu-bar meter (5-hour + weekly usage live)
  - Stats window (line charts, model split, per-project breakdown)
  - Desktop widget
  - Shortcuts integration
- **What's NOT included:**
  - AI Assistant
  - Optimizer (patch apply)
  - Caveman mode injection

### Pro Tier
- **Regular price:** **€29 one-time purchase**
- **Launch price:** **€19 one-time** (first 100 customers)
- **Trial:** 14 days free trial
- **Refund:** 30-day money-back guarantee

**What's included in Pro:**
- Everything in Free tier
- **AI Assistant** (embedded claude.ai session, Apple Intelligence, API key fallback)
- **Optimizer** (apply patches with diff preview + rollback)
- **Caveman mode** (65-75% output token reduction)
- **Custom rules engine** (coming in v3.0 — alerts, auto-pause, thresholds)
- **Export session history** (CSV/JSON, coming in v3.0)

---

## ROI Calculation

**For Opus-heavy users (>70% Opus in model split):**
- Average savings with Caveman mode: **65-75% output tokens**
- Reference cost @ dev-API rates: **€11,215/week** → ~€3,360/week after optimization
- **Savings:** ~€7,855/week
- **Payback period:** **12 days** (€29 / (€7,855/7 days))

**For Sonnet-heavy users:**
- Average savings with Caveman mode: **50-60% output tokens**
- Reference cost @ dev-API rates: **~€2,000/week** → ~€900/week after optimization
- **Savings:** ~€1,100/week
- **Payback period:** **2-3 weeks**

---

## Promo Codes (Active)

### ph-launch-may26
- **Discount:** 30% off
- **Valid:** 72 hours from 2026-05-26 21:00 Paris
- **Final price:** €6.30 (launch) or €20.30 (regular)
- **Status:** Active in Stripe

---

## Competitor Pricing Comparison

| Product | Price | Model | What you get |
|---------|-------|-------|--------------|
| **Throttle** | €29 one-time | One-time | Menu-bar meter + AI assistant + Optimizer + Caveman mode |
| **SessionWatcher** | $2.99 one-time | One-time | Menu-bar meter for 5 AI tools (Claude, Cursor, Copilot, Codex, Gemini) — surface-level only |
| **ClaudeUsageBar** | Free | Open-source | Menu-bar meter for Claude only — basic tracking |
| **Usage for Claude** | $? | One-time | iOS/Mac app, iCloud sync |
| **Usage4Claude** | $? | One-time | Menu-bar, color alerts, Keychain encrypted |
| **ccusage CLI** | Free | Open-source | Terminal-based analysis, no GUI, no action |

**Throttle's positioning:** Premium depth (AI assistant + optimizer) vs competitors' breadth (multi-AI) or basic tracking (free tools).

---

## Historical Pricing (DO NOT USE — for reference only)

- ❌ **€9/month subscription** — NEVER EXISTED, this was a documentation error
- ❌ **€9 one-time** — Early draft, never shipped
- ✅ **€19 launch / €29 regular** — Correct pricing since v2.9.9

---

## Where to Update Pricing

When changing pricing, update these files:

1. `/Users/kevinnadjarian/GitHub/lorislab-website/apps/throttle.html` (hero, meta description, structured data)
2. `/Users/kevinnadjarian/GitHub/Throttle/README.md` (if exists)
3. `/Users/kevinnadjarian/GitHub/Throttle/audit-output/throttle-roadmap.md` (pricing section)
4. Product Hunt listing (manual, web UI)
5. Stripe payment link (manual, dashboard)
6. X/Twitter bio or pinned tweet (if pricing mentioned)

---

*This file is the single source of truth for all pricing references. Do not create conflicting pricing docs.*
