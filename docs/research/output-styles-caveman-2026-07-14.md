# Output styles / caveman — deep research COMPLETE 2026-07-14

107 agents, verification adversariale 3 voix/claim, synthese finale.

## Synthese

Les output styles "caveman" ne tiennent pas leurs promesses de 63-75% d'économie : les mesures reproductibles donnent -1% à -18% de tokens de sortie pour un profil terse sûr, ~25% en session complète au mieux (estimation Decrypt), et ~14% de coût réel même avec un profil agressif qui sacrifie les garde-fous — parce que les tokens de sortie ne pèsent que 9-15% de la facture réelle (télémétrie Throttle) et que les tokens de thinking sont intouchés. L'explication n°1 du symptôme observé ("style actif dans settings.json mais aucun effet") est documentée : le style est lu UNE SEULE FOIS au démarrage de session (verrouillé depuis v2.1.73 pour préserver le prompt cache) — tout changement mi-session est invisible jusqu'à /clear ou nouvelle session ; l'explication n°2 est le shadowing par .claude/settings.local.json (écrit par /config, précédence Local > User). Piège supplémentaire : keep-coding-instructions vaut false par défaut, donc un style de compression supprime silencieusement les instructions d'ingénierie intégrées de Claude Code. Les alternatives plus fiables sont les hooks : UserPromptSubmit (directive de brièveté ré-injectée à CHAQUE tour, en fin de contexte = récence maximale) et SessionStart avec matcher "compact" (ré-injection après compaction, là où l'effet du style se perd). Pour Throttle : écrire le style avec keep-coding-instructions: true, détecter le shadowing local, prévenir que l'effet n'arrive qu'à la prochaine session, préférer une instruction courte type "be brief" (capture l'essentiel du gain), et surtout mesurer via usage.db plutôt que promettre des pourcentages marketing.

## Findings

### 1. [high] Les économies revendiquées (63-75% de tokens de sortie) ne se reproduisent pas : un profil terse sûr mesure -1% à -2% (Haiku), -11% à -18% (Sonnet), -5% à -7% (Opus) sur harness claude -p ; Decrypt estime ~25% en session réelle ; le repo caveman-skill lui-même avoue 12-24% de gain réel malgré ses micro-benchmarks à -61%.

**Evidence:** SUMMARY.md (mis à jour 2026-07-14) : "The published 63% reduction does not reproduce on the current minimal CLAUDE.md." Decrypt : "Real-world sessions counting all this input, account for savings around 25%, not 75%." Le README de caveman-skill publie -61% moyen (tiktoken, 4 tâches) mais caveate lui-même : "Estimated real-world session savings: 12-24%... this is the honest number, not a marketing number." Le post Reddit original (180→45 tokens = 75%) est la source du chiffre viral, pas une mesure contrôlée.
**Vote:** Fusion des claims [0][16][17][18] — votes 3-0, 3-0, 2-1, 3-0
**Sources:** https://github.com/drona23/claude-token-efficient/benchmark/SUMMARY.md, https://decrypt.co/363440/devs-claude-talk-like-caveman-cut-costs-work-better, https://github.com/Shawnchee/caveman-skill

### 2. [medium] Des réductions ~60% de sortie SONT atteignables, mais uniquement avec un profil compressé agressif qui supprime les garde-fous anti-fabrication et anti-relecture (-62% Opus, -32% Sonnet, -22% Haiku) — et même là, le coût réel ne baisse que d'environ 14% (Opus : $0.3997→$0.3451) car le fichier d'instructions injecté ajoute des tokens d'entrée.

**Evidence:** "The compressed profile drops fabrication and re-read guards in exchange for shorter output. Use when token cost dominates and the workload is low-risk." N=5, single session, auto-étiqueté "directional signal only".
**Vote:** Claim [1] — vote 2-1
**Sources:** https://github.com/drona23/claude-token-efficient/benchmark/SUMMARY.md

### 3. [high] Plafond économique structurel : les tokens de sortie ne représentent que ~10-15% d'une facture Claude Code typique (mesuré sur la propre usage.db de Throttle : 12.0% opus, 9.5% sonnet, 15.1% haiku), l'entrée (dominée par les cache reads) fait 85-90%, et les tokens de thinking sont intouchés par le style — la compression de sortie a donc un impact borné quoi qu'il arrive.

**Evidence:** Vérification empirique contre la télémétrie réelle de Kevin avec ratios de prix Anthropic ; corroboré par l'issue #24147 ("Cache read tokens consume 99.93% of usage quota"). Le blog sous-estime même la dominance de l'entrée pour les gros utilisateurs de cache.
**Vote:** Claim [20] — vote 3-0
**Sources:** https://andrew.ooo/posts/caveman-claude-code-skill-token-savings-review/, ~/Library/Application Support/com.lorislab.throttle/usage.db (télémétrie locale, ~89k events), https://github.com/anthropics/claude-code/issues/24147

### 4. [medium] Une instruction d'une ligne ("be brief.") capture l'essentiel du gain à elle seule (~34% de tokens, qualité 0.985 vs 0.975 pour Caveman Full — benchmark Max Taylor, 24 prompts), et un prompt artisanal de 6 lignes (caveman-micro, 85 tokens) bat le skill Caveman complet (552 tokens) sur le ratio qualité/tokens — la complexité du style caveman n'apporte rien.

**Evidence:** Deux benchmarks indépendants convergents (le vérificateur a corrigé l'attribution : deux auteurs distincts, pas un seul). Cohérent avec le test SkillsBench de JetBrains (8.5% d'économie de sortie sur 86 tâches agentiques).
**Vote:** Claim [19] — vote 3-0
**Sources:** https://andrew.ooo/posts/caveman-claude-code-skill-token-savings-review/, https://maxtaylor.me/articles/i-benchmarked-caveman-against-two-words, https://github.com/kuba-guzik/caveman-micro

### 5. [high] Mécanique d'injection : les instructions du style sont ajoutées à la FIN du system prompt, tandis que CLAUDE.md arrive comme user message APRÈS le system prompt — deux couches distinctes sans précédence formelle. Claude Code injecte en plus des rappels d'adhérence (<system-reminder>) pendant la conversation, le mécanisme anti-drift documenté — mais son efficacité réelle est contestée (issue #6450 : styles ignorés malgré les rappels en contexte long).

**Evidence:** Doc officielle verbatim : "All output styles have their own custom instructions added to the end of the system prompt. All output styles trigger reminders for Claude to adhere to the output style instructions during the conversation." + table comparative : CLAUDE.md "Adds a user message after the system prompt". Corroboré par les analyses de reverse-engineering du system prompt.
**Vote:** Fusion des claims [5][10][11] — tous votés 3-0
**Sources:** https://code.claude.com/docs/en/output-styles, https://github.com/anthropics/claude-code/issues/6450, https://dbreunig.com (How Claude Code Builds a System Prompt)

### 6. [high] EXPLICATION PRINCIPALE du symptôme observé : le style est lu UNE SEULE FOIS au démarrage de session. Depuis v2.1.73 (commande /output-style dépréciée, supprimée en v2.1.91), le style est verrouillé au démarrage explicitement "for better prompt caching" : le changer mi-session (settings.json ou /config) n'invalide PAS le cache mais ne s'applique PAS non plus — effet uniquement au prochain /clear ou nouvelle session. Le system prompt étant la première couche du prefix caché (matching exact), un changement de style ne casse le cache qu'à la nouvelle session.

**Evidence:** Doc verbatim : "Output style is part of the system prompt, which Claude Code reads once at session start. Changing it via /config or the outputStyle setting mid-session does not invalidate the cache, but the change also doesn't apply." Changelog : "Output style is now fixed at session start for better prompt caching."
**Vote:** Fusion des claims [3][6][7][9][15] — tous votés 3-0
**Sources:** https://code.claude.com/docs/en/output-styles, https://code.claude.com/docs/en/prompt-caching, https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md (v2.1.73, ligne 2745)

### 7. [high] EXPLICATION SECONDAIRE (piège de scope) : sélectionner un style via /config l'écrit dans .claude/settings.local.json au niveau PROJET LOCAL, qui shadow silencieusement le outputStyle global de ~/.claude/settings.json (précédence documentée : Managed > CLI args > Local > Project > User). Un outil tiers qui écrit le global peut être neutralisé par un fichier local rassis sans aucun avertissement.

**Evidence:** Doc verbatim : "Your selection is saved to .claude/settings.local.json at the local project level." + ordre de précédence explicite dans la page settings.
**Vote:** Claim [4] — vote 3-0
**Sources:** https://code.claude.com/docs/en/output-styles, https://code.claude.com/docs/en/settings

### 8. [high] PIÈGE DE QUALITÉ : keep-coding-instructions vaut false par défaut — un style custom de compression supprime les instructions d'ingénierie logicielle intégrées de Claude Code (scoping des changements, vérification du travail, commentaires) sans aucun avertissement runtime. Un style 'caveman' sans ce flag dégrade donc le comportement de codage, pas seulement le verbiage.

**Evidence:** Doc verbatim : "Custom output styles leave out Claude Code's built-in software engineering instructions, such as how to scope changes, write comments, and verify work, unless keep-coding-instructions is set to true." Table frontmatter : Default = false.
**Vote:** Fusion des claims [2][8] — tous deux votés 3-0
**Sources:** https://code.claude.com/docs/en/output-styles

### 9. [high] Alternatives plus fiables via hooks : (a) SessionStart avec matchers startup/resume/clear/COMPACT — le stdout du hook est ajouté au contexte, permettant de ré-injecter les instructions de concision APRÈS compaction, exactement là où l'effet du style se perd ; (b) UserPromptSubmit injecte son stdout/additionalContext À CHAQUE prompt soumis (canal par-message, ne peut pas remplacer le prompt), placé en fin de contexte (récence) alors que le contexte SessionStart est en tête de conversation — la brièveté ré-affirmée à chaque tour est mécaniquement plus robuste au drift qu'un system prompt lu une fois.

**Evidence:** Doc verbatim : "Any text your hook script prints to stdout is added as context for Claude" ; matcher compact = "Auto or manual compaction" ; placement : SessionStart "at the start of the conversation, before the first prompt", UserPromptSubmit "alongside the submitted prompt". Caveats : régression historique #15174 (stdout du matcher compact non injecté, v2.0.76, fermée) et #49063 (additionalContext perdu dans l'extension VSCode ; le CLI fonctionne).
**Vote:** Fusion des claims [12][13][14] — tous votés 3-0
**Sources:** https://code.claude.com/docs/en/hooks, https://github.com/anthropics/claude-code/issues/15174, https://github.com/anthropics/claude-code/issues/49063

### 10. [high] Recommandations pour Throttle : (1) NE PAS vendre l'output style comme lever d'économie majeur — plafond réel ~10-15% de la facture, gains mesurés -2% à -11% pour un profil sûr ; (2) si style configuré : toujours keep-coding-instructions: true dans le frontmatter, style COURT (une ligne 'be brief'-like capture l'essentiel, un gros style ajoute des tokens d'entrée à chaque requête) ; (3) après écriture du setting, afficher 'effet à la prochaine session / après /clear' — jamais promettre un effet immédiat ; (4) détecter et signaler le shadowing par .claude/settings.local.json dans les projets actifs ; (5) pour un effet robuste au drift et à la compaction, préférer un hook UserPromptSubmit (directive par tour) + SessionStart matcher compact — c'est le mécanisme garanti, pas le style ; (6) mesurer l'effet réel avant/après via usage.db plutôt que citer des pourcentages communautaires.

**Evidence:** Chaque recommandation découle directement d'un finding vérifié 3-0 : read-once (rec 3), settings.local.json (rec 4), keep-coding-instructions default false (rec 2), hooks documentés (rec 5), plafond économique mesuré sur la propre DB de Throttle (rec 1, 6).
**Vote:** 
**Sources:** Synthèse des findings ci-dessus (docs officielles code.claude.com + benchmarks drona23/Shawnchee/maxtaylor + télémétrie usage.db)
