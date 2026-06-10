# Throttle Cockpit — direction décision (2026-06-06)

Source NotebookLM. Résume la décision de design du **Cockpit window** de Throttle prise
le 6 juin 2026, après un passage par le pipeline Claude Design (4 directions générées) et
synthèse. À lire avec `UI-SPEC-cockpit.md` (le spec d'implémentation détaillé).

## Contexte

Le Cockpit est une **fenêtre macOS redimensionnable** (900×600 par défaut) qui embarque un
vrai terminal `claude` (SwiftTerm `LocalProcessTerminalView`, toujours sombre) entouré de la
**couche décision** de Throttle. Le terminal est un conteneur commodité ; le produit, c'est
l'instrument autour. Positionnement validé par la recherche (verdict NARROW-SCOPE GO) :
ne PAS concurrencer les terminaux (Warp/Ghostty), le wedge = cockpit-autour-de-l'agent. Le
moat = la couche décision (binding number, exact mode, surtout les **nudges prédictifs de cap**
que le dashboard d'Anthropic ne fait pas).

## Les 4 directions Claude Design

- **A — The Instrument Strip** : un bandeau d'instruments fixe en haut (binding hero · forecast
  prédictif · coût session) au-dessus d'un terminal pleine largeur. Glanceable, toujours au même
  endroit. Coût : ~64pt verticaux permanents.
- **B — The Inspector Rail** : terminal large + rail droit repliable (binding hero · forecast ·
  coût · model split · other windows · session history). Profondeur à la demande, un tap pour
  replier. Coût : largeur horizontale quand ouvert.
- **C — The Ambient HUD** : terminal plein cadre ; une puce glass discrète en haut-droite qui
  ne grossit / se colore / révèle son forecast que sous pression. Focus maximal, zéro chrome
  jusqu'à ce qu'il y ait quelque chose à dire.
- **D — The Prompt Gauge** (surprise) : pas de bandeau — la headroom vit DANS le prompt shell
  (segment powerline `~/app  97%  6m left`) + un footer fin pour le coût. L'instrument disparaît
  dans le terminal. Flow total, mais le moins de place pour le détail.

## Synthèse verrouillée — « un cockpit, deux niveaux de densité + un mode focus »

A et B portaient tous les deux le binding hero → empilés bêtement = couche décision en double.
Résolution : **leur donner des rôles distincts** (pas de redondance).

| Niveau | Chrome | Porte | Toggle |
|---|---|---|---|
| **Full** (défaut) | strip **A** en haut + rail **B** repliable à droite | strip = la *décision* ; rail = le *détail* | le rail se replie via l'icône panel |
| **Compact** (focus) | puce **HUD (C)** en overlay sur le terminal | binding seul, grossit/se colore sous pression | toggle "focus" masque strip+rail |
| *(plus tard)* Prompt gauge (D) | segment powerline DANS le prompt shell | binding % + time-to-cap | intégration shell PS1 opt-in, PAS en v1 |

- **Strip (A)** possède les 3 chiffres de décision : `BINDING NOW` hero · `FORECAST` nudge · `THIS SESSION` coût.
- **Rail (B)** possède la profondeur : `MODEL SPLIT` · `OTHER WINDOWS` · `SESSION HISTORY`. Repliable.
- **Compact (C)** = un `ZStack` overlay glass en haut-droite — trivial et fidèle.
- **D hors v1** : mettre la jauge dans le prompt n'est pas du chrome SwiftUI, ça demande de
  modifier le PS1 du shell (intégration type Starship). Reporté à une intégration shell optionnelle.

Donc : **strip+rail (A+B) = full · HUD (C) = compact · prompt-gauge (D) = phase shell-integration.**

## Règles d'affichage (état réel des données)

Le mock Design a des chiffres pour tout ; en vrai, on n'affiche QUE ce qui est réel — jamais un
chiffre inventé. Si un feed manque, on masque la cellule plutôt que la fausser.

- **Solide aujourd'hui** (données réelles dans `appState`) : les 3 fenêtres % (exact-or-estimate),
  le binding (max pct), reset times, pills EXACT/PRO/FREE, concise toggle. → strip + rail "other
  windows" + HUD marchent à 100%.
- **À brancher / vérifier dans les services** : le **nudge prédictif** (« ≈6m · ≈4 msgs au cap »)
  — LE différenciateur, demande un burn-rate forecast ; vérifier si `PlanAdvisor`/`ExactModeService`
  l'expose ou s'il faut le calculer. Idem coût €/session, model split, session history.

## Tones / seuils

`tone(pct)` : crit ≥ 95 (rouge) · warn ≥ 80 (ambre) · sinon neutre (graphite). Le binding = la
fenêtre la plus proche de son cap. AtLimitBanner n'apparaît que si le binding est ≥ 80%. Couleur
UNIQUEMENT sous pression réelle ; l'accent (`#0071E3`) réservé à l'interactif (liens, actions,
toggle ON), jamais aux données.

## Plan d'implémentation (2 options proposées à Kevin)

- **Option A (préférée)** : coder d'abord le squelette full (strip+rail+HUD) sur les données déjà
  solides (%, binding, pills, windows, concise) → cockpit pixel-fidèle tout de suite, puis brancher
  nudge/coût/split/history au fur et à mesure.
- **Option B** : audit des services d'abord (ce que `PlanAdvisor`/`ExactModeService`/`StatsDataService`
  exposent vraiment), puis tout coder d'un coup.
