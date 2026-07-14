# Output styles / caveman — deep research FINALE 2026-07-14

107 agents, verification adversariale complete (reprise post-spend-limit).

## Synthese

Les output styles Claude Code fonctionnent mécaniquement mais leurs économies réelles sont très inférieures aux 65-75% revendiqués : les benchmarks indépendants mesurent -1% à -18% avec des instructions de concision minimales, ~-8,5% de tokens de sortie sur des tâches agentiques réelles, et les tokens de sortie ne représentent que ~7-16% de la facture de Kevin (le cache-read domine) — l'impact économique est donc structurellement borné à quelques pourcents de session complète. Le symptôme observé ("style actif dans settings.json mais aucun effet visible") a deux explications documentées : (1) depuis v2.1.73 le style est figé au démarrage de session pour préserver le prompt cache — tout changement mid-session ne s'applique qu'au prochain /clear ou nouvelle session, ce qui est fatal avec les sessions longues/résumées de Kevin ; (2) /config écrit outputStyle dans .claude/settings.local.json au niveau projet, qui shadow silencieusement le réglage global ~/.claude/settings.json. Piège supplémentaire : un style custom SUPPRIME les instructions d'ingénierie intégrées de Claude Code sauf si keep-coding-instructions: true est dans le frontmatter. L'alternative la plus fiable pour un outil comme Throttle est le hook UserPromptSubmit (injection additionalContext garantie à chaque tour, positionnement récent) + SessionStart avec matcher "compact" (ré-injection après compaction), plutôt que de compter sur un system prompt lu une fois. Recommandation Throttle : une directive de concision courte ("be brief" capture l'essentiel des gains), injectée par hooks, avec keep-coding-instructions: true si un style est utilisé, vérification du shadowing local, et un messaging honnête (~4-25% de session, pas 65-75%).

## Findings

### 1. [high] Les revendications 65-75% d'économie ne se reproduisent pas : elles ne mesurent que les tokens de sortie sur des micro-benchmarks. Mesures réelles : -1% à -2% (Haiku), -11% à -18% (Sonnet), -5% à -7% (Opus) avec un CLAUDE.md de concision minimal (le repo drona23 rétracte lui-même son headline de 63%) ; ~-8,5% de sortie sur tâches agentiques (JetBrains) ; ~25% de session complète au mieux selon Decrypt (estimation journalistique, probablement un plafond — mesuré : 4-10%). Le post Reddit original (180→45 tokens sur une web search) et le repo caveman-skill (-61% moyen via tiktoken) sont des micro-benchmarks single-shot output-only.

**Evidence:** SUMMARY.md : "The published 63% reduction does not reproduce on the current minimal CLAUDE.md. Real effect ranges from ~-2% (haiku) to -11% (opus, excl. T4)." Decrypt : "Real-world sessions counting all this input, account for savings around 25%, not 75%." Le repo caveman-skill lui-même plafonne les attentes réelles à 12-24% de session.
**Vote:** 3-0 (claims 0, 16, 17, 18 fusionnées)
**Sources:** https://github.com/drona23/claude-token-efficient/benchmark/SUMMARY.md, https://decrypt.co/363440/devs-claude-talk-like-caveman-cut-costs-work-better, https://blog.jetbrains.com/ai/2026/07/speak-to-ai-agents-like-cavemen-tosave-tokens/, https://github.com/Shawnchee/caveman-skill

### 2. [high] L'impact économique de la compression de sortie est structurellement borné : les tokens de sortie ne représentent que ~10-30% d'une facture Claude Code typique (vérifié sur la DB Throttle de Kevin : 7,4-16,3% par modèle, le cache-read domine massivement), et les tokens de thinking/reasoning ne sont pas touchés par le style.

**Evidence:** Vérification sur les 580k+ usage_events de Kevin : output = 7,4-16,3% du coût par modèle (opus-4-8 : 38,3 Md tokens cache-read vs 144 M output). Même une réduction de sortie de 60% ne toucherait donc que quelques pourcents du coût total.
**Vote:** 2-1 (claim 20)
**Sources:** https://andrew.ooo/posts/caveman-claude-code-skill-token-savings-review/, ~/Library/Application Support/com.lorislab.throttle/usage.db (vérification indépendante du verificateur), https://github.com/anthropics/claude-code/issues/24147

### 3. [medium] Des réductions ~60% de tokens de sortie sont atteignables, mais uniquement avec un profil compressé agressif qui sacrifie les garde-fous (fabrication/re-read guards) : -62% Opus, -32% Sonnet, -22% Haiku. Et une instruction d'une ligne "be brief." capture l'essentiel des gains à elle seule (419 tokens vs 401-449 pour Caveman, qualité égale ou supérieure) — le style élaboré n'apporte presque rien de plus.

**Evidence:** SUMMARY.md : "The compressed profile drops fabrication and re-read guards in exchange for shorter output. Use when token cost dominates and the workload is low-risk." Benchmark HN 24 prompts x 5 bras : "be brief." égale les variantes Caveman. Caveats : N=5, single-run, tâches Q&A non-agentiques.
**Vote:** 3-0 + 2-1 (claims 1, 19)
**Sources:** https://github.com/drona23/claude-token-efficient/benchmark/SUMMARY.md, https://andrew.ooo/posts/caveman-claude-code-skill-token-savings-review/, https://news.ycombinator.com/item?id=47954745

### 4. [high] Mécanique d'injection : les instructions du style custom sont ajoutées à la FIN du system prompt, et Claude Code injecte des reminders d'adhérence pendant la conversation (mécanisme anti-drift documenté, via <system-reminder> dans les messages pour préserver le cache). PIÈGE MAJEUR : un style custom SUPPRIME par défaut les instructions d'ingénierie intégrées (scoping, vérification, commentaires) — keep-coding-instructions vaut false par défaut ; un style "caveman" sans ce flag dégrade silencieusement le comportement de code.

**Evidence:** Docs officielles : "Custom output styles leave out Claude Code's built-in software engineering instructions... unless keep-coding-instructions is set to true" (default: false) ; "All output styles trigger reminders for Claude to adhere to the output style instructions during the conversation."
**Vote:** 3-0 x3 + 2-1 (claims 2, 5, 8, 10 fusionnées)
**Sources:** https://code.claude.com/docs/en/output-styles, https://michaellivs.com/blog/system-reminders-steering-agents/

### 5. [high] Cause n°1 du symptôme "le style ne s'applique pas" : depuis v2.1.73, l'output style est FIGÉ au démarrage de session (explicitement pour le prompt caching — /output-style déprécié puis supprimé en v2.1.91). Le system prompt est lu une seule fois ; changer le style mid-session (settings.json ou /config) n'invalide PAS le cache mais ne s'applique PAS non plus — effet uniquement après /clear ou nouvelle session. Avec le pattern de Kevin (sessions longues, résumées, jamais redémarrées), un style configuré après le démarrage reste invisible indéfiniment. Corollaire cache : le style vit dans la première couche du prefix caché ; changer de style entre sessions casse tout le cache de la nouvelle session (prefix différent), mais jamais en cours de session.

**Evidence:** CHANGELOG v2.1.73 : "Deprecated /output-style command — use /config instead. Output style is now fixed at session start for better prompt caching." Docs prompt-caching : "Changing it via /config or the outputStyle setting mid-session does not invalidate the cache, but the change also doesn't apply... The new style loads on the next /clear or restart."
**Vote:** 3-0 x4 (claims 3, 6, 7, 9, 15 fusionnées)
**Sources:** https://code.claude.com/docs/en/output-styles, https://code.claude.com/docs/en/prompt-caching, https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md (v2.1.73, ligne 2745)

### 6. [high] Cause n°2 probable : piège de scope. /config sauvegarde la sélection de style dans .claude/settings.local.json au NIVEAU PROJET, et la précédence des settings (Managed > CLI > Local > Project > User) fait qu'un outputStyle local shadow silencieusement le réglage global ~/.claude/settings.json qu'un outil comme Throttle écrirait. Vecteur supplémentaire : un plugin avec force-for-plugin:true peut aussi écraser le setting.

**Evidence:** Docs : "Your selection is saved to .claude/settings.local.json at the local project level." outputStyle est un setting de type override (seules les permission rules mergent entre scopes) — le local gagne toujours sur le user-level.
**Vote:** 3-0 (claim 4)
**Sources:** https://code.claude.com/docs/en/output-styles, https://code.claude.com/docs/en/settings

### 7. [high] Précédence vs CLAUDE.md : pas de hiérarchie formelle — couches d'injection différentes. Le style modifie le system prompt lui-même (fin du prompt, caché) ; CLAUDE.md est injecté comme user message via <system-reminder> après le system prompt (jamais dans le prefix caché, pour préserver l'économie du cache), avec un nudge textuel "These instructions OVERRIDE any default behavior" qui favorise doucement CLAUDE.md en cas de conflit.

**Evidence:** Docs : "All output styles have their own custom instructions added to the end of the system prompt. ... [CLAUDE.md] Adds a user message after the system prompt." Confirmé au niveau réseau par dbreunig.
**Vote:** 3-0 (claim 11)
**Sources:** https://code.claude.com/docs/en/output-styles, https://www.dbreunig.com (analyse wire-level 2026-04-04)

### 8. [high] Alternative la plus fiable : les hooks. UserPromptSubmit injecte son stdout/additionalContext À CHAQUE prompt soumis (canal per-message mécaniquement garanti en CLI, positionné à côté du prompt = récence maximale, re-vu à chaque tour — contrairement au system prompt one-shot). SessionStart avec matcher "compact" se déclenche au startup, resume, /clear ET après compaction — permettant de ré-injecter la directive de concision exactement là où l'effet d'un style risque de se diluer. Préférer le JSON hookSpecificOutput.additionalContext au stdout brut sur le path compact.

**Evidence:** Docs hooks : "Any text your hook script prints to stdout is added as context for Claude" ; matcher compact = "Auto or manual compaction" ; UserPromptSubmit "can't replace the prompt; it only injects additionalContext alongside it". Issue #25999 : système en production (50+ ingénieurs) reposant sur source=compact, confirmé fonctionnel.
**Vote:** 3-0 x3 (claims 12, 13, 14 fusionnées)
**Sources:** https://code.claude.com/docs/en/hooks, https://github.com/anthropics/claude-code/issues/25999

### 9. [medium] Recommandations Throttle (synthèse) : (1) diagnostiquer d'abord le shadowing — scanner .claude/settings.local.json des projets pour un outputStyle local qui masque le global ; (2) afficher un avertissement "effet au prochain /clear/redémarrage" quand Throttle écrit outputStyle (ne jamais promettre un effet immédiat) ; (3) si style custom : toujours mettre keep-coding-instructions: true dans le frontmatter pour ne pas dégrader le comportement de code ; (4) préférer l'architecture hooks (UserPromptSubmit + SessionStart matcher compact) pour une directive de concision courte type "be brief" — plus fiable que le style, résiste à la compaction, gratuit en cache ; (5) messaging honnête : annoncer ~4-25% de session complète maximum, pas 65-75% (chiffre output-only non reproductible) — cohérent avec la doctrine measure-first de Throttle ; (6) mesurer l'effet réel via la DB usage de Throttle (output tokens/turn avant/après) plutôt que de citer des benchmarks communautaires.

**Evidence:** Dérivé des mécaniques documentées (fixed-at-session-start, settings precedence, keep-coding-instructions default false, hooks additionalContext) et des benchmarks mesurés (drona23, JetBrains, HN, DB Throttle).
**Vote:** synthèse
**Sources:** Synthèse des claims 0-20 ci-dessus
