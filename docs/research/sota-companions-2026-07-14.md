# SOTA — outils compagnons agents de code (deep research 2026-07-14)

105 agents, 5 angles, verification adversariale 3 voix/claim, sources primaires fetchees live le 2026-07-14.

## Synthese

Mi-2026, l'axe metering est totalement commoditisé : ccusage (15+ agents, local-first), Claude-Code-Usage-Monitor (prédictif P90/burn-rate), CCSeva (menu-bar Swift natif avec jauges « server-truth » OAuth) et ClaudeBar (11 providers) couvrent déjà tokens, fenêtres 5h/hebdo, coût par session et prédiction de cutoff — Throttle n'y est plus unique, seulement en retard sur le multi-provider et l'endpoint OAuth. Le cockpit multi-sessions a un leader financé (Conductor, multi-vendor, git-worktrees + review-and-merge) et Anthropic a shippé en first-party le remote-control mobile de sessions locales (exécution 100% locale, mode serveur 32 sessions) ainsi que l'offload cloud avec portabilité complète de transcript (--teleport) — ce qui érode frontalement le companion iOS et une partie du pivot remote-control de Throttle. Les niches encore réellement vides où Throttle est positionné : (1) le handoff local→distant d'une session CLI en cours (le CLI officiel est one-way cloud→local, feature requests ouvertes), exactement le créneau de l'offload LXC ; (2) les utilisateurs API-key/Bedrock/gateway explicitement exclus du Remote Control first-party ; (3) l'observabilité/adoption de sessions locales arbitraires (le server mode ne gère que les sessions qu'il spawn) ; (4) l'optimisation cache-aware opérationnalisée (ordering prefix-cache, right-sizing de modèle sensible au cache, hit-rate comme levier de plan) — documentée par Anthropic mais qu'aucun outil tiers ne mesure ni ne pilote encore.

## Findings verifies

### 1. [high] Metering multi-agent local-first : ccusage est la référence de l'axe usage-metering — CLI local qui lit les logs de 15-16 agents (Claude Code, Codex, OpenCode, Amp, Droid, Goose, Copilot CLI, Gemini CLI…) sans rien uploader, estime le coût USD par tables de pricing et comptabilise séparément cache-creation vs cache-read. Le parsing JSONL local + cost-estimation avec comptabilité cache est devenu LE standard de la catégorie.

**Evidence:** Trois claims fusionnés, tous vérifiés 3-0 sur source primaire : tagline ccusage.com verbatim (15 agents nommés), repo 17.2k stars, v20.0.17 du 2026-07-10, formule de coût publiée (LiteLLM pricing, cache 5m/1h/read séparés), mode --offline. Seul flux réseau = téléchargement du pricing public, jamais d'upload — même positionnement no-data-path que Throttle.
**Vote:** 9-0 (3 claims x 3-0)
**Sources:** https://ccusage.com/, https://github.com/ryoppippi/ccusage

### 2. [high] Le metering prédictif est commoditisé côté CLI : Claude-Code-Usage-Monitor (Python, ~8.4k stars, v4.0.0 juin 2026) tracke tokens/messages/coût en temps réel contre les fenêtres 5h glissantes et ship burn-rate analytics, prévision d'expiration de session et prédictions P90 — les « predictive cap nudges » ne sont plus une capacité unique dans le segment CLI.

**Evidence:** Deux claims 3-0. README vérifié verbatim 2026-07-14 : 'Burn Rate Analytics', 'Session Forecasting: Predicts when sessions will expire', 'P90 Calculator'. Nuance du vérificateur : le 'Machine Learning' est en réalité de la statistique P90 — le label est marketing, mais la conclusion concurrentielle tient. Le moat 'predictive cap nudges' de Throttle ne vaut plus que par l'UX menu-bar, pas par la capacité.
**Vote:** 6-0 (2 claims x 3-0)
**Sources:** https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor

### 3. [high] CCSeva est le concurrent le plus direct du meter de Throttle : menu-bar macOS Swift natif (NSStatusItem+NSPopover+SwiftUI, ~3 MB, macOS 14+, migré depuis Electron) qui couvre déjà toute la surface plan-limits visée — blocs 5h avec burn rate et projection de fin de fenêtre, rollups hebdo alignés sur les limites Claude, et surtout des jauges 'server-truth' tirées du vrai endpoint OAuth usage (utilisation cross-device + heure de cutoff prédite), avec fallback estimation locale. Data path local-first, parsing incrémental de ~/.claude/projects/**/*.jsonl au format ccusage.

**Evidence:** Trois claims 3-0. Vérifié jusque dans le code : swift/Sources/CCSeva/Limits/OAuthLimitsProvider.swift appelle GET api.anthropic.com/api/oauth/usage et parse five_hour/seven_day/seven_day_opus/seven_day_sonnet — le shape de réponse est daté 2026-06 dans les commentaires. C'est le point où Throttle est le plus en retard s'il n'interroge pas cet endpoint : CCSeva affiche la vérité serveur (multi-machines) là où le parsing JSONL seul ne voit qu'une machine. Caveat : le dernier binaire taggé (v1.3.0) est encore l'ère Electron, l'app Swift semble build-from-source.
**Vote:** 9-0 (3 claims x 3-0)
**Sources:** https://github.com/Iamshankhadeep/ccseva

### 4. [high] Le metering consolide vers le multi-provider : ClaudeBar (menu-bar macOS, 1.3k stars, v0.4.71 du 2026-07-13) tracke session/hebdo/par-modèle en temps réel pour 11 providers (Claude, Codex, Gemini, Copilot, Antigravity, Z.ai, Kimi, Kiro, Amp, OpenCode Go, Oh My Pi) ; le pattern 5h/hebdo est standard dans au moins 6 outils actifs, et le plafond du multi-provider est encore plus haut (CodexBar revendique ~59 providers).

**Evidence:** Trois claims 3-0. README vérifié verbatim, release la veille de la recherche. Le vérificateur corrobore la tendance avec CodexBar (~59 providers) et coding_agent_usage_tracker. Implication : un meter Claude-only est un désavantage structurel croissant ; la différenciation de Throttle doit venir des autres axes (cockpit/offload), pas du meter.
**Vote:** 9-0 (3 claims x 3-0)
**Sources:** https://github.com/tddworks/ClaudeBar, https://github.com/steipete/CodexBar

### 5. [high] Cockpit multi-sessions : Conductor (Mac, YC S24, ~$22M Series A) fait tourner en parallèle des agents Claude Code, Codex ET Cursor, chacun dans un workspace isolé par git worktree ; sa proposition de valeur est visibilité de flotte + workflow review-and-merge diff-first (PR en un clic), pas du multiplexing de terminaux. Le cockpit est donc devenu multi-agent-vendor, avec une couche revue de code que le cockpit de Throttle (terminaux SwiftTerm + rail) n'a pas.

**Evidence:** Deux claims 3-0, homepage vérifiée live 2026-07-14 + reviews tierces indépendantes (codepick.dev, julianastrada.com) confirmant worktree-isolation et modèle diff-first, utilisateurs cités chez Linear/Vercel/Notion/Stripe. Retard de Throttle : pas de review/merge layer ni de multi-vendor ; avantage résiduel : Conductor ne fait ni metering ni offload.
**Vote:** 6-0 (2 claims x 3-0)
**Sources:** https://www.conductor.build/

### 6. [high] Offload/portabilité : Claude Code supporte en first-party les sessions cloud sur VMs Anthropic avec teleport du transcript complet + branche vers le terminal local (--teleport) — la portabilité de transcript est standard, plus une niche tierce. MAIS le handoff CLI est one-way (cloud→local uniquement) : pousser une session CLI locale en cours vers le cloud est impossible depuis le CLI (seul le Desktop a 'Continue in'), avec feature requests ouvertes (#56687, #14666). Le handoff local→distant d'une session en cours est LE gap que l'offload LXC de Throttle occupe.

**Evidence:** Deux claims 3-0, doc officielle vérifiée verbatim 2026-07-14 : 'From the CLI, session handoff is one-way… you can't push an existing terminal session to the web'. Caveats : research preview, réservé aux plans claude.ai (pas API key/Bedrock/Vertex), exige git propre + branche pushée. Nuance : /remote-control couvre partiellement le besoin utilisateur (continuer à interagir depuis ailleurs) sans être un vrai handoff de transcript.
**Vote:** 6-0 (2 claims x 3-0)
**Sources:** https://code.claude.com/docs/en/claude-code-on-the-web, https://github.com/anthropics/claude-code/issues/56687

### 7. [high] Optimisation cache (axe 4) : le canon officiel Anthropic est prefix-matching avec layout static-first/dynamic-last (system prompt+tools cachés globalement → CLAUDE.md par projet → contexte session → messages), et le right-sizing de modèle mi-session est contre-productif car les caches sont par-modèle (basculer Opus→Haiku à 100k tokens coûte plus cher que rester sur Opus). Tout 'model right-size nudge' — feature au backlog de Throttle — doit impérativement être cache-aware ; aucun outil tiers identifié ne mesure ni ne pilote encore cette dimension.

**Evidence:** Deux claims 3-0, blog officiel (Thariq Shihipar, équipe Claude Code, 2026-04-30) vérifié verbatim, section 'Don't change models mid-session' ; arithmétique de break-even validée par le vérificateur sous pricing courant ; prescription officielle = subagent hand-off plutôt que switch mid-session. Le blog note aussi que l'ordering est 'surprisingly fragile' (timestamps, ordre des tools) — argument pour un détecteur de cache-bust, présent dans le backlog Throttle et absent du marché.
**Vote:** 6-0 (2 claims x 3-0)
**Sources:** https://claude.com/blog/lessons-from-building-claude-code-prompt-caching-is-everything, https://code.claude.com/docs/en/prompt-caching

### 8. [medium] Le cache hit rate est un levier mesurable de rendement de plan : Anthropic lie explicitement le hit rate du prompt cache à la générosité des rate limits d'abonnement, les cache-read tokens comptent contre le quota du plan, et les compteurs cache_creation/cache_read sont exposés par réponse (statusline, OpenTelemetry) — un axe de metering que Throttle pourrait instrumenter (score de cache-efficiency par session/projet) et qu'aucun outil recensé n'exploite.

**Evidence:** Vote 2-1. La citation blog est vérifiée verbatim mais décrit une économie au niveau de la flotte ('helps us create more generous rate limits'), pas une personnalisation par utilisateur ; l'effet par-utilisateur (cache miss = requêtes plus chères = quota consommé plus vite) vient des docs officielles et de l'issue #24147 ('Cache read tokens consume 99.93% of usage quota'). Le levier de mesure est solide, l'interprétation causale fine reste partiellement inférée.
**Vote:** 2-1
**Sources:** https://claude.com/blog/lessons-from-building-claude-code-prompt-caching-is-everything, https://code.claude.com/docs/en/prompt-caching, https://github.com/anthropics/claude-code/issues/24147

### 9. [high] Mobile/remote-control : Anthropic occupe déjà la niche en first-party sur deux fronts. (a) Les sessions cloud persistent hors navigateur et se pilotent depuis l'app mobile Claude (steering, feedback, 'watch this PR and fix CI failures'). (b) Remote Control permet de continuer une session Claude Code LOCALE depuis téléphone/tablette/navigateur (claude.ai/code + app iOS/Android), l'exécution restant entièrement sur la machine locale (QR pairing, push notifications, Trusted Devices) — c'est frontalement le créneau du companion iOS et du pivot remote-control de Throttle.

**Evidence:** Deux claims 3-0, docs officielles vérifiées live 2026-07-14, corroboration tierce (DataCamp, DevOps.com). Précision du vérificateur : le control-plane relaye via l'API Anthropic en TLS (outbound-only) même si l'exécution est locale. C'est le risque 'Anthropic ships its own' déjà identifié pour le Cockpit — il s'est matérialisé pour le remote-control mobile. La différenciation Throttle doit être ce que le first-party ne fait pas (voir finding suivant).
**Vote:** 6-0 (2 claims x 3-0)
**Sources:** https://code.claude.com/docs/en/claude-code-on-the-web, https://code.claude.com/docs/en/remote-control

### 10. [high] Limites du first-party = niches résiduelles pour Throttle : Remote Control ship un server mode gérant une flotte de sessions locales (capacité 32 par défaut, isolation git-worktree optionnelle) — la gestion de flotte locale first-party existe donc — MAIS (1) il ne gère que les sessions qu'il spawn lui-même, sans adopter ni observer les sessions locales démarrées indépendamment (pas de dashboard local, l'UI est la liste claude.ai/code) ; (2) il est en research preview, exige OAuth claude.ai, et exclut explicitement API keys, Bedrock/Vertex/Foundry et tout proxy ANTHROPIC_BASE_URL (depuis v2.1.196) — laissant les utilisateurs API-key/gateway sans remote-control, et l'observabilité cross-session de sessions arbitraires sans solution first-party.

**Evidence:** Deux claims 3-0, table de flags vérifiée verbatim (--capacity 32, --spawn worktree) plus la restriction v2.1.196 sur ANTHROPIC_BASE_URL. Le vérificateur souligne explicitement : 'it does not adopt or observe independently-started local sessions' et 'third-party terminal-wrapper remote tools can still serve API-key/gateway users' — les deux angles exacts du cockpit Throttle (observation de sessions arbitraires) et de son positionnement no-OAuth-dependency.
**Vote:** 6-0 (2 claims x 3-0)
**Sources:** https://code.claude.com/docs/en/remote-control
