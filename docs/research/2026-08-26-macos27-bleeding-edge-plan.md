# Throttle — plan bleeding-edge macOS 27 Golden Gate

Date: 2026-08-26  
Host de recherche: macOS 27.0 beta `26A5421a`, Apple Silicon  
Toolchain disponible: Xcode 27.0 `27A5237l`  
Portée: Throttle macOS direct distribution, sans changement de code ni de publication  
Verdict: `GO RESEARCH / NO-GO CLAIM` — feuille de route fondée, mais aucune adoption n'est validée par la recherche seule.

## 1. Décision exécutive

Throttle peut être réellement bleeding-edge sur macOS 27 sans abandonner macOS 14. La stratégie recommandée est:

1. conserver `MACOSX_DEPLOYMENT_TARGET = 14.0` et l'artefact universel;
2. isoler les nouveautés avec `if #available(macOS 27, *)` et des adapters injectables;
3. faire de macOS 27 la plateforme d'innovation IA, Siri, recherche locale et continuité;
4. maintenir un chemin fonctionnel macOS 14–26, sans UI mensongère ni fallback réseau implicite;
5. traiter le nouvel OS et le nouveau modèle Apple comme une source de dérive à mesurer, pas comme une preuve de qualité.

Les cinq paris prioritaires sont:

- `P0` Evaluations framework pour le Refiner, le routeur et les outils agentiques;
- `P0` restauration/graceful termination des fenêtres et sessions;
- `P1` abstraction `LanguageModel` + Dynamic Profiles autour des providers existants;
- `P1` Core Spotlight RAG local et entités Siri pour projets/missions/sessions;
- `P1` adaptation UI/AX macOS 27, MetricKit + StateReporting et widget extra-large interactif.

Core AI, Private Cloud Compute, les modèles partenaires et la virtualisation sont des pistes expérimentales, pas des dépendances produit immédiates.

## 2. Définition de bleeding-edge pour Throttle

`VERIFIED` — adopter tôt une API Apple n'est utile que si elle améliore au moins un indicateur:

- temps jusqu'à une session utilisable;
- taux de reprise sans réexpliquer la mission;
- taux de conflits/doubles écritures;
- précision du routage local/frontier;
- tokens, cache writes, mémoire et énergie réellement économisés;
- accessibilité et contrôle clavier;
- absence d'action agentique non autorisée.

Une nouveauté macOS 27 sans impact mesurable, ou qui impose une régression macOS 14–26, reste hors chemin critique.

## 3. Baseline actuelle du dépôt

### Déjà présent

- `VERIFIED` — Swift 6.0 avec strict concurrency `complete`; cible macOS 14.
- `VERIFIED` — Apple Intelligence via `SystemLanguageModel` et `LanguageModelSession`, avec outils natifs `read_file`, `list_files` et `bash` borné.
- `VERIFIED` — Qwen embarqué via MLX, routage local, shadow replay et auto-test local.
- `VERIFIED` — App Intents lecture d'usage, pause/reprise, quiet mode et Focus Filter.
- `VERIFIED` — widget macOS statique small/medium.
- `VERIFIED` — MetricKit crash/hang déjà collecté et exporté.
- `VERIFIED` — Cockpit SwiftUI/AppKit, menu-bar, terminaux local/remote, WebKit éphémère, indexation sémantique locale.
- `VERIFIED` — plusieurs contournements macOS 26/27 existent déjà: RenderBox/Metal, titlebar/NSRemoteView, atomic write et terminal sous pression mémoire.

### Lacunes macOS 27 observées

- `OPEN` — aucun usage de `LanguageModel`, Dynamic Profiles, vision, SpotlightSearchTool, Core AI ou PCC.
- `OPEN` — aucun corpus Evaluations Apple pour les sorties probabilistes.
- `OPEN` — App Intents sans AppEntity/IndexedEntity, App Schemas, LongRunning/Cancellable/UndoableIntent, ExecutionTargets ni AppIntentsTesting.
- `OPEN` — aucune restauration `NSWindowRestoration`; la terminaison actuelle arrête tous les sous-processus Cockpit.
- `OPEN` — pas de `NSTextSelectionManager`, de boucle clavier AppKit explicitement recalculée ni de validation Sidecar tactile.
- `OPEN` — widget sans famille `systemExtraLargePortrait` et action Pause via deep link plutôt qu'intent interactif.
- `OPEN` — MetricKit existe, mais pas StateReporting pour corréler les diagnostics à l'état Cockpit/terminal/modèle.
- `OPEN` — plus de vingt usages Foundation `Process`; Swift Subprocess 1.0 mérite un pilote, pas une migration big-bang.

## 4. Matrice exhaustive des nouveautés pertinentes

| Domaine macOS 27 | Statut source | Fit Throttle | Décision | Priorité |
|---|---|---|---|---|
| Nouveau modèle Apple on-device | `VERIFIED` | Refiner, assistant, routing | Rebench obligatoire par build d'OS/modèle | P0 |
| Evaluations framework | `VERIFIED` | qualité/refus/outils/trajectoires | Adopter en premier | P0 |
| Foundation Models Instruments | `VERIFIED` | tokens, outils, latence | Ajouter aux gates perf/IA | P0 |
| `LanguageModel` protocol | `VERIFIED` | unifier Apple/MLX/frontier | Adapter derrière `AIProvider`, pas réécriture globale | P1 |
| Dynamic Profiles | `VERIFIED` | Audit, Refiner, Mission, Research | Pilote sur trois profils à outils minimaux | P1 |
| Usage/cache/reasoning tokens | `VERIFIED` | vérité métrique provider-neutral | Stocker avec provenance, jamais mélanger aux estimations | P1 |
| Vision multimodale | `VERIFIED` | screenshot/log/image explicite | Opt-in fichier choisi par l'utilisateur | P1 |
| OCR/Barcode tools | `VERIFIED` | diagnostics visuels, QR de config | OCR utile; barcode seulement si cas produit réel | P2 |
| SpotlightSearchTool | `VERIFIED` | RAG local projets/missions | Pilote parallèle à l'index propriétaire | P1 |
| PCC 32K | `VERIFIED` | gros audits sans clé | Expérience opt-in distincte du local-only | P2 |
| CoreAILanguageModel | `VERIFIED` | remplacement/complément MLX | Benchmark mémoire/latence/qualité avant bundle | P2 |
| MLXLanguageModel | `VERIFIED` | provider Qwen natif FM | Spike prioritaire avant Core AI | P1 |
| Modèles Anthropic/Google Swift | `VERIFIED` | provider abstraction | Ne pas ajouter avant OAuth/coût/consentement démontrés | P3 |
| fm CLI et Python SDK | `VERIFIED` | QA offline et génération de jeux | Utiliser pour outils de test, jamais prérequis runtime | P2 |
| Open-source FM utilities | `VERIFIED` | primitives émergentes | Veille pinée, pas dépendance flottante | P3 |
| Siri AI via App Schemas | `VERIFIED` | demander usage, trouver mission, quiet/pause | Exposer lectures + actions réversibles seulement | P1 |
| AppEntity/IndexedEntity | `VERIFIED` | Project, Mission, Session | Indexer métadonnées minimales, jamais transcripts/secrets | P1 |
| Onscreen awareness | `VERIFIED` | Siri comprend le panneau courant | Annoter entités non sensibles; aucun terminal brut | P2 |
| Relevant/Syncable entities | `VERIFIED` | continuité Mac/iPhone future | Local Mac d'abord; sync uniquement après modèle privacy | P3 |
| LongRunning/Cancellable intents | `VERIFIED` | benchmark, health check, refresh | Adopter avec annulation et progression | P1 |
| UndoableIntent | `VERIFIED` | mutations réversibles | Seulement si rollback transactionnel prouvé | P2 |
| ExecutionTargets | `VERIFIED` | app/widget/extension correcte | Adopter pour éviter l'exécution dans le mauvais processus | P1 |
| AppIntentsTesting | `VERIFIED` | validation Siri/Shortcuts | Gate CI Xcode 27 | P0 |
| Widget extra-large portrait | `VERIFIED` | portefeuille, capacités, santé | Ajouter une vue synthèse configurable | P1 |
| Widget interactif AppIntent | `SUPPORTED` | quiet/pause/reprise | Remplacer le deep link Pause | P1 |
| Liquid Glass 27/tint slider | `VERIFIED` | Cockpit/menu-bar/widget | Audit automatique + visuel; éviter matériaux forcés | P1 |
| Uniform toolbar/edge sidebar | `VERIFIED` | Cockpit et fenêtres projet | Aligner la hiérarchie sans casser macOS 14 | P1 |
| Concentricity | `VERIFIED` | cartes/panneaux/popovers | Adopter aux conteneurs principaux | P2 |
| `showBorders` et contraste | `VERIFIED` | contrôles custom | Gate AX obligatoire | P0 |
| Reorderable containers | `VERIFIED` | Rail/Tabs/portfolio | Remplacer le drag custom quand sûr | P2 |
| Swipe actions hors List | `VERIFIED` | sessions/missions | Seulement pour actions réversibles | P3 |
| @State macro lazy | `VERIFIED` | performance et source breaks | Compiler/auditer sous Xcode 27 | P0 |
| ContentBuilder | `VERIFIED` | temps de compilation SwiftUI | Mesurer avant/après, pas de migration spéculative | P2 |
| AsyncImage HTTP cache | `VERIFIED` | faible fit actuel | Hors scope sauf nouvelle surface réseau | P3 |
| NSTextSelectionManager | `VERIFIED` | logs/diff/terminal custom | Spike sur LogViewer/Diff, pas sur SwiftTerm sans preuve | P2 |
| Gestures/Control Events | `VERIFIED` | scrolling, drag, custom controls | Moderniser les zones avec hacks mouseDown seulement | P1 |
| Full keyboard/status item | `VERIFIED` | menu-bar et Cockpit | Recalcul key loop + test VoiceOver/Full Keyboard Access | P0 |
| Graceful termination | `VERIFIED` | sessions actives | Repenser l'arrêt: checkpoint/confirmation, pas blocage modal | P0 |
| NSWindowRestoration | `VERIFIED` | continuité Cockpit/projets | Restaurer layout, onglet et scroll; jamais relancer un agent implicitement | P0 |
| Sidecar touch | `VERIFIED` | cockpit sur iPad display | Test input/scroll; avantage secondaire | P3 |
| MetricKit + StateReporting | `VERIFIED` | corréler hangs au terminal/modèle | Ajouter états privacy-safe et bornés | P1 |
| Swift Subprocess 1.0 | `VERIFIED` | sécurité/cancellation de `Process` | Migrer 2 pilotes, puis décider | P2 |
| Swift `@concurrent`/Instruments 27 | `VERIFIED` | main-actor hangs | Mesurer scanner/indexer/renders, corriger contention réelle | P1 |
| WebKit/Safari 27 | `VERIFIED` | web renderer privé | QA régression; nouveautés 3D sans fit produit | P3 |
| ManagedApp/declarative config | `VERIFIED` | offre entreprise | Hypothèse Enterprise, hors produit individuel | P3 |
| Virtualization 27 | `VERIFIED` | agents isolés dans VM | Discovery séparée; coût/permissions trop élevés pour 3.3 | P3 |

## 5. Architecture cible

### 5.1 Couche modèle

Conserver `AIProvider` comme frontière produit et introduire un adapter macOS 27:

```text
Assistant / Refiner / Router
          |
      AIProvider
          |
   FoundationModelsAdapter (macOS 27)
    |        |        |        |
 System   MLX LM   Core AI   PCC/Partner
 local    local    local     opt-in network
```

Règles:

- `SystemLanguageModel` reste le défaut local Apple quand disponible;
- MLX reste local, sans serveur ni fallback réseau implicite;
- PCC et partenaires sont des providers réseau distincts, étiquetés et consentis;
- Dynamic Profiles limitent instructions et outils par tâche;
- chaque réponse porte modèle, localité, tokens, cache/reasoning quand disponibles et version OS;
- toute action outillée passe par l'allowlist existante et une confirmation proportionnée au risque.

### 5.2 Données et Spotlight

Créer des entités minimales:

- `ProjectEntity`: identifiant stable, nom, chemin redacted/alias, état Git agrégé;
- `MissionEntity`: objectif, état, bloqueurs, dernière validation, sans transcript;
- `SessionEntity`: provider, état actif/paused/dormant, capacité agrégée;
- `EvidenceEntity`: type de gate, timestamp, résultat, lien local contrôlé.

Index Core Spotlight:

- opt-in et effaçable;
- métadonnées bornées, aucun secret, clé, contenu terminal ou transcript brut;
- hydratation à la demande par identifiant;
- comparaison A/B avec l'index sémantique actuel sur recall, latence, mémoire et dérive;
- SpotlightSearchTool en lecture seule au départ.

### 5.3 Continuité

État restaurable:

- fenêtre, mode Dashboard/Rail/Tabs, projet sélectionné, panneaux, split ratios et scroll;
- identifiants de session et cwd, mais jamais relance automatique d'un agent ou d'une commande;
- reprise explicite avec preuve Git fraîche et one-writer check;
- termination: checkpoint borné, délai maximal, choix utilisateur si travail actif.

## 6. Sécurité et privacy macOS 27

`VERIFIED` — Apple traite l'injection indirecte comme un risque actif des apps agentiques. Throttle combine précisément les trois facteurs critiques: données privées, contenu non fiable et capacité d'agir.

Gates obligatoires:

- classifier toute source modèle comme trusted/user/untrusted;
- séparer données et instructions dans les prompts;
- allowlist d'outils minimale par Dynamic Profile;
- confirmation explicite avant mutation, réseau, lancement, copie ou insertion terminal;
- réauthentification locale pour actions sensibles initiées par Siri/Shortcuts;
- aucun transcript/chemin secret dans AppEntity, Spotlight, widget ou StateReporting;
- test injection indirecte sur HTML, README, issue, sortie terminal et résultat OCR;
- journal de décision sans contenu sensible et rollback vérifiable;
- aucun provider PCC/partenaire activé sous l'étiquette `local-only`.

## 7. UX et accessibilité

Matrice de validation macOS 27:

- Liquid Glass ultraclear, tinted, Reduce Transparency et Increase Contrast;
- `showBorders`, Reduce Motion, VoiceOver, Full Keyboard Access;
- menu-bar/status item au clavier, ordre de focus dynamique;
- tailles fenêtre compactes et ultrawide 5K/120 Hz;
- Sidecar avec souris, trackpad et touch;
- widgets full color/tinted/clear et extra-large portrait;
- terminal normal/alternate-screen local et remote, scrolling bidirectionnel;
- aucune information exprimée uniquement par couleur, matériau ou animation.

## 8. Roadmap séquencée

### Vague 0 — canary et dérive (avant toute feature)

- [ ] Ajouter une matrice macOS 14 stable / 26 stable / 27 beta et Xcode stable/27.
- [ ] Versionner OS/build, modèle Apple, hardware et locale dans les evidence reports.
- [ ] Transformer les contournements macOS 26/27 en tests de régression avec kill switches.
- [ ] Rejouer Refiner, tools, terminal, menu-bar, widget et WebKit à chaque beta.

Critère GO: aucune régression P0, zéro crash, suite actuelle verte, artefacts séparés par environnement.

### Vague 1 — qualité IA mesurée

- [ ] Construire un golden set Refiner/router/tools de 30–50 cas synthétiques.
- [ ] Adopter Evaluations et AppIntentsTesting dans des targets de test Xcode 27.
- [ ] Ajouter Instrument Foundation Models et export JSON de scores/latence/tokens.
- [ ] Tester nouveau modèle Apple en français et anglais, prompts hostiles compris.

Critère GO: zéro action interdite, métriques quantitatives versionnées, non-régression statistique définie avant optimisation.

### Vague 2 — continuité native Mac

- [ ] `NSWindowRestoration` et état UI borné.
- [ ] terminaison gracieuse sans relance automatique ni perte silencieuse;
- [ ] key view loop/status item et axe clavier/VoiceOver;
- [ ] audit Liquid Glass/concentricity/showBorders;
- [ ] terminal local/remote sous pression mémoire et alternate screen.

Critère GO: restore fidèle après quit/reboot simulé, aucune double écriture, parcours 100 % clavier.

### Vague 3 — Foundation Models 27

- [ ] Adapter `LanguageModel` derrière `AIProvider`;
- [ ] profils `refine`, `audit-readonly`, `mission-plan`;
- [ ] usage/cache/reasoning provenance;
- [ ] MLXLanguageModel spike;
- [ ] vision/OCR uniquement sur fichier sélectionné.

Critère GO: parity fonctionnelle macOS 14–26, aucune fuite réseau en mode local, benchmarks supérieurs ou abandon de l'adapter.

### Vague 4 — Siri, Spotlight et widget

- [ ] Project/Mission/Session entities minimales;
- [ ] Core Spotlight RAG en lecture seule;
- [ ] Siri/App Schemas pour requêtes et actions réversibles;
- [ ] intents long-running/cancellable avec execution target explicite;
- [ ] widget extra-large et actions interactives.

Critère GO: suppression complète de l'index testée, auth/confirmation sensibles, aucune donnée privée exposée aux surfaces système.

### Vague 5 — observabilité et performance

- [ ] StateReporting: dashboard, terminal, model-inference, indexing, quiet;
- [ ] MetricKit/Organizer Metric Goals;
- [ ] Instruments 27: Swift Executors, Top Functions, hangs, FM;
- [ ] pilotes Swift Subprocess sur health check et command runner;
- [ ] budget mémoire/énergie par provider et surface.

Critère GO: gains mesurés sur p50/p95, absence de régression énergie/mémoire et cancellation fiable.

### Vague 6 — expériences optionnelles

- [ ] Core AI vs MLX benchmark;
- [ ] PCC 32K opt-in avec entitlement et UI de limites;
- [ ] provider Anthropic/Google seulement avec OAuth et vérité coût/cache;
- [ ] Virtualization pour workspace agent isolé;
- [ ] ManagedApp pour une hypothèse Enterprise validée.

Critère GO: décision produit et benchmark explicites; sinon rejet documenté.

## 9. Scorecard et stop gates

| Gate | Mesure | Seuil initial |
|---|---|---|
| IA | action interdite/hallucination de tool | 0 |
| IA | cas Refiner acceptés | ≥ baseline 3.2.107 |
| RAG | recall@5 sur corpus synthétique | ≥ index actuel |
| RAG | fuite de contenu hors allowlist | 0 |
| Continuité | restaurations fidèles | 100/100 scénarios synthétiques |
| One-writer | doubles writers | 0 |
| Runtime | crash/hang nouveau | 0 |
| Terminal | scroll local/remote/alternate | 100 % matrice |
| AX | parcours critique clavier + VoiceOver | 100 % |
| Perf | régression p95 UI | < 5 % |
| Mémoire | modèle local sous pression | déchargement borné, aucun swap runaway |
| Privacy | données sensibles Spotlight/Siri/widget | 0 |

## 10. Hypothèses rejetées

- `CONTRADICTED` — « macOS 27 exige de relever la cible minimale ». Les API peuvent être availability-gated; relever la cible détruirait inutilement la compatibilité.
- `CONTRADICTED` — « Foundation Models unifie tout donc il faut supprimer AIProvider ». La frontière produit garde consentement, vérité réseau et fallback fail-closed.
- `CONTRADICTED` — « PCC est local ». PCC est privé mais utilise les serveurs Apple; il doit être étiqueté réseau.
- `CONTRADICTED` — « Siri peut recevoir tous les outils Throttle ». Les actions agentiques et mutantes demandent une surface minimale, auth et confirmation.
- `HYPOTHESIS` — Core AI sera meilleur que MLX pour Qwen sur ce Mac. Seul un benchmark matériel peut trancher.
- `HYPOTHESIS` — Spotlight RAG remplacera l'index propriétaire. Il doit d'abord gagner sur qualité, contrôle et effacement.
- `OPEN` — les API et comportements beta resteront identiques au SDK/OS final.

## 11. Sources primaires Apple, vérifiées le 2026-08-26

1. [macOS 27 Golden Gate](https://www.apple.com/os/macos/) — Siri AI, design, performances, accessibilité, compatibilité.
2. [What's new in Foundation Models](https://developer.apple.com/videos/play/wwdc2026/241/) — modèles, vision, PCC, LanguageModel, outils, Dynamic Profiles.
3. [Foundation Models updates](https://developer.apple.com/documentation/Updates/FoundationModels) — dérive modèle et nouvelles erreurs/API.
4. [Meet the Evaluations framework](https://developer.apple.com/videos/play/wwdc2026/298/) — métriques, datasets, model judges.
5. [LLM search using Core Spotlight](https://developer.apple.com/videos/play/wwdc2026/246/) — SpotlightSearchTool et hydratation.
6. [Run local agentic AI on Mac using MLX](https://developer.apple.com/videos/play/wwdc2026/232/) — agents et tool calling locaux.
7. [Meet Core AI](https://developer.apple.com/videos/play/wwdc2026/324/) — conversion, runtime et profiling on-device.
8. [Discover new App Intents capabilities](https://developer.apple.com/videos/play/wwdc2026/345/) — entities, paramètres et exécution.
9. [Build intelligent Siri experiences](https://developer.apple.com/videos/play/wwdc2026/240/) — App Schemas et contexte écran.
10. [Secure agentic features](https://developer.apple.com/videos/play/wwdc2026/347/) — injections indirectes, confirmations et auth.
11. [Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/) — input, clavier, restauration et Liquid Glass.
12. [What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/) — design, interaction, @State et performance.
13. [WidgetKit foundations](https://developer.apple.com/videos/play/wwdc2026/277/) — familles, configuration et interactions.
14. [Meet the new MetricKit](https://developer.apple.com/videos/play/wwdc2026/222/) — StateReporting et diagnostics contextualisés.
15. [What's new in Swift](https://developer.apple.com/videos/play/wwdc2026/262/) — Swift 6.3/6.4 et Subprocess 1.0.
16. [What's new in Xcode 27](https://developer.apple.com/videos/play/wwdc2026/258/) — Device Hub, Organizer, Instruments et CI.

## 12. Prochaine tranche recommandée

La première implémentation défendable n'est pas une refonte UI. C'est une tranche de preuve:

1. golden set Refiner/router/tool calls;
2. Evaluations + AppIntentsTesting;
3. metadata OS/modèle dans le rapport;
4. tests de restauration et graceful termination;
5. audit clavier/Liquid Glass/showBorders;
6. aucun changement de provider ou d'index avant les résultats de cette tranche.

Cette tranche réduit le risque de construire vingt nouveautés sur un modèle et un OS encore bêta, tout en donnant immédiatement à Throttle une avance de qualité mesurable.
