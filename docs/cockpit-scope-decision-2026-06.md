# Throttle Cockpit — décision de scope : intégrations vs environnement local (2026-06-07)

Source NotebookLM. Tranche la question « le cockpit doit-il se connecter à des services
tiers (GitHub, etc.) et/ou détecter l'environnement Claude Code local (MCP, skills, hooks…) ? »
contre le verdict NARROW-SCOPE GO de la recherche. Complète `UI-SPEC-cockpit.md` et
`cockpit-direction-2026-06.md`.

## Verdict en une ligne

**Intégrations type GitHub = NON (scope creep mortel). Détection de l'environnement Claude Code
local = OUI (c'est le wedge, focus absolu).**

## (A) Connexions à des services tiers (GitHub PR/issues/CI, Jira, cloud…) → REFUSER

- Re-fait de Throttle un terminal/IDE → concurrence frontale-perdante contre Warp ($73M,
  800k devs) et VS Code. « A paid general-purpose terminal is not viable. »
- Détruit l'USP #1 : la vie privée. Le pitch est « Everything stays on your Mac. No telemetry,
  no cloud, no account. » Brancher GitHub = comptes/OAuth/réseau = USP cassée.
- Aucun angle coût : savoir qu'une PR est mergée ne prédit pas le burn-rate ni ne sauve de tokens.
- Action : refuser catégoriquement toute gestion de code source / intégration cloud.

## (B) Détecter l'environnement LOCAL (MCP, skills, sub-agents, hooks, slash commands, settings, CLAUDE.md) → FOCUS ABSOLU

Reframe clé : **ce n'est pas « afficher la config », c'est une radiographie des SOURCES DE COÛT
du contexte.** Chaque élément a un poids token mesurable (chiffres des sources v3.0) :

| Source locale | Coût token | Levier |
|---|---|---|
| CLAUDE.md | 5–10k / démarrage de session | > 200 lignes = gras → déplacer vers skills (on-demand) |
| Serveurs MCP | 2–10k chacun | un MCP zombie fait boucler l'agent → brûle la fenêtre 5h |
| Skills | jusqu'à 20k | chargés inutilement |
| Extended thinking | ~40% des coûts | `/effort lower` |
| Memory files | cumulé, souvent périmé | fichiers inutilisés 30j+ encore chargés |

Pourquoi c'est le moat : Throttle audite DÉJÀ `CLAUDE.md` + `settings.json` et propose des
patchs 1-clic via l'assistant IA. L'étendre à MCP/skills/hooks dans le cockpit finit le travail.
Anthropic ne fait PAS : health MCP (`list_tools` + schema-drift), gestion native des hooks,
« poids » de la config. Son dashboard ne montre que des barres opaques.

La ligne à ne pas franchir même dans (B) : **detect → cost-attribute → optimize 1-clic.** Pas
« manager tout l'écosystème ». Filtre de chaque feature : *« est-ce que ça empêche de frapper le
cap 5h sans prévenir, ou ça réduit les tokens ? »* Sinon → dehors.

## Le piège « faux-GitHub » qui est en fait légitime

**Coût/usage attribué par repo** (tokens par projet) : Throttle a déjà une fenêtre par-projet
qui lit `~/.claude/projects/<repo>/`. C'est LOCAL, pas une intégration. « Ce repo t'a coûté X
tokens cette semaine » = sur le wedge. La distinction : lire le dossier local, jamais appeler
l'API GitHub.

## Conséquence sur le design du cockpit

Le **Rail B devient « Environnement & sources de coût »** (au lieu de session-history, faible
ROI) : `OTHER WINDOWS` · `MODEL SPLIT` (>70% Opus = signal coût) · `MCP HEALTH`
(ok/dégradé/zombie + p50) · `CONFIG WEIGHT` (CLAUDE.md/skills/MCP en k tokens + bouton
Optimize). Un rail qu'on garde OUVERT parce qu'on agit dessus, pas qu'on contemple.

GitHub/services tiers/features-terminal = **non-goals explicites** dans `UI-SPEC-cockpit.md`.
