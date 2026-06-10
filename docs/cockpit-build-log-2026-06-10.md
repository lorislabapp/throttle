# Throttle Cockpit — build log (2026-06-10)

Source NotebookLM. Ce qui a été implémenté dans la fenêtre Cockpit ce jour, par-dessus
le spike (terminal + meter). Complète `UI-SPEC-cockpit.md`, `cockpit-direction-2026-06`,
`cockpit-scope-decision-2026-06`. Le cockpit compile et tourne (build Debug).

## Architecture livrée

- **CockpitQueries.swift** (extension `StatsDataService`) — requêtes réelles hors-main :
  session courante (`MAX(timestamp)`), tokens/coût €/nb-messages par session, model-split
  session, **burn-rate** (échantillon 15 min global, nil si pas assez de signal), liste des
  sessions récentes, modèle courant, chemin JSONL d'une session.
- **CockpitData.swift** — `CockpitData` (tous champs optionnels → masqués si pas réels) +
  `CockpitViewModel` (recharge toutes les 10 s hors-main) + `ConfigWeight.read()` (lit
  `~/.claude`).
- **CockpitTerminalController** — passe-plat : tape une commande dans l'unique terminal
  SwiftTerm (`send(txt:)`). Aucun stockage de session.
- **CockpitWindowRoot.swift** — full (Strip A + Rail B) / compact (HUD).

## Surfaces

**Strip A (décision)** : `BINDING NOW` hero (fenêtre la plus proche du cap, exact-or-estimate
avec ≈ muted) · `FORECAST` · `THIS SESSION` (tokens · ≈€ · all-time).

**Rail B repliable « Environnement & sources de coût »** : `OTHER WINDOWS` · `MODEL SPLIT`
session (>70% Opus = cost-heavy) · `CONFIG WEIGHT` (CLAUDE.md ≈tok / MCP / skills) ·
`RECENT SESSIONS`.

**Compact** : HUD glass ambiant qui grossit/se colore sous pression. Toggles full/compact + rail.

## Multi-session (analytique, pas exécution)

Conforme à la reco notebook « séparer l'analytique de l'exécution ». Le panneau RECENT
SESSIONS liste les sessions récentes avec **projet (repo) en nom** (tiré du chemin
`~/.claude/projects/<repo>/<id>.jsonl`), âge, tokens, ≈€, top-model. Bouton **Resume** =
passe-plat `claude --resume <id>` dans l'unique terminal. **Zéro onglet** (non-goal Warp tenu).

## Sélecteur de modèle (l'action de la couche décision)

Menu `Opus ▾` dans la barre du haut = modèle courant de la session. Options Opus/Sonnet/Haiku
avec **l'impact chiffré** (« Sonnet · ~5× cheaper », « Haiku · ~19× cheaper »), calculé sur
les taux output réels de `PlanAdvisor` (pas en dur). Clic = passe-plat `/model <name>`. Bouton
**« Switch to Sonnet »** ré-armé dans l'at-limit banner (visible seulement sur Opus). Sur le
wedge : « switch to Sonnet » est l'action n°1 au cap, et le modèle est le plus gros levier
(cap weekly-Opus séparé + ~5× le coût).

## Réalisme / règle d'or « jamais un chiffre faux » (corrections après 1er run réel)

- **Forecast** : masqué quand l'ETA dépasse le reset de la fenêtre (tu resets avant de capper →
  rien à signaler) ; le compte de messages est supprimé s'il est > 500 (fini « 180h / 67572 msgs »).
  Toujours `≈` + tag *est*.
- **€ = valeur API-équivalente**, pas la dépense réelle (utilisateur en abonnement) : préfixe `≈`,
  caption « API value », format adaptatif (€150k / €1092 / €7.87). Devient l'argument d'éco.
- **MCP** lus depuis `~/.claude.json` (+ `settings.json`), pas seulement settings.json → le compte
  réel apparaît (ex: 11).

## Caveats connus / à suivre

- `/model` et Resume n'agissent que si `claude` tourne dans le terminal (passe-plat).
- Nom de repo avec tiret (ex: `Lumen-Cam`) → affiché par son dernier segment (limite du décodage).
- « THIS SESSION » = session la plus récente globalement, pas forcément celle du terminal du
  cockpit tant qu'on n'y a pas lancé `claude` (sémantique à affiner).
- Pas encore : MCP health (probe `list_tools` + p50/zombie), bouton Optimize du config weight,
  résumé/objet de session (au-delà du nom de repo).
