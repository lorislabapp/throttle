# Throttle Workspaces — marché, produit et architecture SOTA

Date de recherche : 2026-08-16
Statut : paquet de décision produit, pas preuve de release
Périmètre : macOS d'abord ; Codex/Claude/Xcode comme wedge ; usages génériques par adaptateurs
Méthode : corpus DeepSearsh local, dépôt courant, sources primaires live, signaux utilisateurs secondaires

## Verdict

**GO étroit, pas GO universel immédiat.** Il existe un vrai problème et une place commerciale plausible pour un produit macOS qui libère des ressources sans faire perdre l'intention de travail. En revanche, le marché ne manque ni de moniteurs, ni de boutons « quit all », ni de gestionnaires de workspaces. Le produit défendable est :

> **Throttle Workspaces — park heavy work, reclaim the Mac, resume exactly where it is safe to do so.**

La promesse ne doit jamais être « nettoyer la RAM » ni « restaurer n'importe quelle app sans perte ». macOS compresse et réutilise déjà la mémoire ; suspendre un processus économise surtout du CPU, mais ne libère pas réellement son état mémoire. La récupération de RAM exige en pratique un checkpoint puis une terminaison. Une restauration fiable n'est possible que pour les workloads dont Throttle connaît le contrat de reprise.

Le wedge initial est particulièrement fort : plusieurs sessions Codex/Claude, leurs sous-processus MCP, Xcode et les Simulators. Les agents officiels savent reprendre une session, mais ne fournissent pas encore un gouverneur global qui protège le Mac sous pression. Des issues Codex publiques décrivent des sessions multiples menant à un watchdog reboot, une croissance à 75–85 Go, des piles MCP répétées et un crash de WindowServer sur un Mac 16 Go. Ce sont des témoignages/bugs, pas une estimation de prévalence, mais ils valident l'intensité du problème.

## Échelle de preuve

- `VERIFIED` : source primaire ou dépôt courant directement observé.
- `SUPPORTED` : plusieurs signaux cohérents, avec limites explicites.
- `HYPOTHESIS` : proposition à tester avant d'en faire une promesse ou un prix.
- `CONTRADICTED` : formulation rejetée par les preuves.
- `OPEN` : preuve manquante.

## 1. Besoin utilisateur et marché

### 1.1 Le problème est réel, mais segmenté

`VERIFIED` — Apple recommande de lire la **pression mémoire**, pas la seule « RAM libre ». La pression dépend notamment de la mémoire disponible, du swap, de la mémoire wired et du cache de fichiers. La compression des apps inactives fait déjà partie du fonctionnement normal de macOS.

`VERIFIED` — Codex propose `codex resume` pour rouvrir une conversation locale enregistrée. Claude Code expose aussi resume/continue, et son Desktop peut reprendre une session CLI via `/desktop`. Throttle peut donc préserver les identités natives au lieu de copier des conversations.

`SUPPORTED` — Le problème aigu se concentre chez les utilisateurs qui combinent plusieurs workloads lourds : agents parallèles, navigateurs Chromium, MCP, builds Swift/Rust, Xcode et Simulators. Une issue Codex demande explicitement budget global, avertissements et terminaison gracieuse des arbres enfants ; d'autres montrent des scénarios extrêmes sur macOS. Ces issues prouvent l'existence et la gravité possible, pas le TAM.

`SUPPORTED` — La demande générique de « clean slate » et de restauration existe : QuitAll affiche 98 % sur 1 821 évaluations Setapp ; Cove, Later, Bunch et Snapback vendent chacun une variante de capture/restauration de contexte. Les retours négatifs récurrents concernent les régressions à chaque macOS, les permissions, les apps qui ne répondent plus, les éléments de login et la fidélité de restauration.

`OPEN` — Aucun chiffre public sérieux ne permet encore d'estimer combien de possesseurs de Mac paieraient spécifiquement pour une hibernation vérifiée. Le Stack Overflow Developer Survey 2025 compte plus de 49 000 réponses dans 177 pays, mais indique aussi que 52 % n'utilisent pas d'agents ou restent sur des outils AI simples. Le marché « tous les utilisateurs Mac » est large mais diffus ; le marché « power users de plusieurs agents locaux » est plus petit, beaucoup plus douloureux et plus facile à atteindre.

### 1.2 Opportunité commerciale réelle

Le produit peut être commercial s'il économise une panne, une perte de contexte ou plusieurs minutes de reconstruction par jour. Il devient banal s'il n'affiche qu'un graphe, quitte des apps, ou restaure seulement une liste de fenêtres.

Segments prioritaires :

| Segment | Douleur | Adaptateurs | Disposition à payer, hypothèse |
|---|---|---|---|
| Développeur multi-agent sur Mac 16–32 Go | très forte, système parfois inutilisable | Codex, Claude, terminal, MCP, Xcode, Simulator | haute si la reprise est prouvée |
| Développeur multi-projets | forte, coût de context switching | terminaux, IDE, browsers, Finder | moyenne à haute |
| Créatif/pro avec gros logiciels | forte, mais état propriétaire difficile | adapters app-specific | potentiellement haute, risque technique élevé |
| Utilisateur Mac généraliste | faible à moyenne | apps/documents génériques | faible, concurrence à 2–20 $ |
| Équipes/IT | gouvernance et stabilité | policies, fleet health, audit local | intéressante plus tard, produit différent |

**Conclusion marché :** viser les développeurs/power users d'abord, puis généraliser par packs. Ne pas lancer comme « optimiseur universel de Mac ».

## 2. Carte concurrentielle

### 2.1 Gouverneurs de ressources

#### App Tamer — concurrent adjacent le plus fort

`VERIFIED` — 14,95 $, essai 15 jours, Intel et Apple Silicon. Il limite ou stoppe automatiquement des apps en arrière-plan, exploite les efficiency cores, détecte les CPU hogs et se configure par app. La bêta 3.0 ajoute profils, règles, température, mémoire par processus, sous-processus/helpers et auto-quit.

Forces : maturité, faible prix, automatisation, contrôle multi-processus, compatibilité historique, helper privilégié éprouvé.
Faiblesses : centré CPU/batterie ; pas de capsule de travail, pas de preuve de checkpoint, pas de reprise de session métier, configuration délicate. Sa FAQ reconnaît qu'un mauvais stop peut casser Mail, notifications, services et utilitaires, et qu'une app stoppée peut apparaître bloquée.
Leçon : Throttle ne gagnera pas sur le simple throttling. Il doit savoir **pourquoi** un workload est récupérable et démontrer le résultat.

#### macOS App Nap / Activity Monitor

Forces : gratuit, natif, pression mémoire faisant autorité, aucune installation tierce.
Faiblesses : pas de workflow de park/wake explicite, pas de regroupement par projet, pas de checkpoint métier, pas de preuve de reprise.
Leçon : expliquer que Throttle orchestre la continuité ; il ne prétend pas remplacer le gestionnaire mémoire de macOS.

#### Docker Sandboxes

`VERIFIED` — `sbx create claude` accepte un plafond mémoire (`--memory`, défaut 50 % de l'hôte, maximum 32 Gio) et CPU, ainsi que clone isolé et règles réseau.
Forces : limites réelles, isolation, workloads jetables.
Faiblesses : environnement conteneurisé, poids Docker, couvre les agents lancés dedans et non le bureau Mac existant.
Leçon : offrir éventuellement un adapter Docker, mais ne pas refaire le runtime Docker.

### 2.2 Quitters et économiseurs de contexte

#### QuitAll / Quit All Apps / Quitter

Prix observés : 1,99 $ pour Quit All Apps ; 14,99 $ pour QuitAll ; Quitter est gratuit.
Forces : simplicité, exclusions, auto-quit, confirmation de sauvegarde normale.
Faiblesses : pas de restauration vérifiée ; une terminaison forcée peut perdre du travail ; compatibilité macOS fragile.
Avis : les utilisateurs valorisent fortement le « clean slate », mais signalent gels après mise à jour et comportements de login non respectés.
Leçon : une action sûre, explicable et réversible vaut plus qu'un bouton agressif.

#### Later

`VERIFIED` — cache ou ferme les apps, restaure une session, planifie la réouverture et permet des exclusions. Projet open source non maintenu, binaire non signé.
Forces : modèle mental exact « save for later », interface simple.
Faiblesses : maintenance abandonnée, distribution/trust faibles, fidélité app-specific limitée.
Leçon : prouve l'attrait de la promesse et la nécessité d'une maintenance durable.

### 2.3 Gestionnaires de workspaces

#### Cove

`VERIFIED` — concurrent produit le plus proche : capture apps, fenêtres, tabs, fichiers, Focus, terminal CWD ; « park » ferme les apps puis restaure. Prix 19,99 $ à vie, essai 14 jours, local-first, macOS 15+, distribution directe car Accessibility/AppleScript sont incompatibles avec le sandbox voulu.
Forces : UX claire, adapters riches, confidentialité, bon prix, vraie capture de contexte.
Faiblesses : ne gouverne pas la pression mémoire ni les arbres de processus, ne prouve pas le checkpoint interne d'un agent, ne mesure pas le RAM réellement récupéré.
Leçon : Cove occupe déjà « save/load your Mac workspace ». Throttle doit ajouter le **contrat de récupération et le resource governor**, pas copier le marketing.

#### Bunch

`VERIFIED` — workspaces en fichiers texte : ouvre/ferme apps, fichiers, URLs, Finder tabs et commandes.
Forces : personnalisable, scriptable, local, lisible, très bon modèle de recipes.
Faiblesses : configuration power-user, pas de capture automatique ni de safety engine.
Leçon : un format de recipe déclaratif et versionnable est une excellente surface d'extension.

#### Snapback et autres window managers

`VERIFIED` — Snapback restaure positions, displays et apps ; cœur gratuit et Pro à 9,99 $.
Forces : fidélité visuelle, clavier, multi-écrans.
Faiblesses : fenêtre/layout plutôt qu'état de workload et ressources.
Leçon : intégrer ou coexister ; ne pas devenir un énième window manager.

### 2.4 Cockpits et monitors d'agents

AgentWatch et d'autres menu-bar apps suivent CPU/RAM de Claude, Codex, Cursor, Gemini et autres. Hydra, Conductor et les apps first-party gèrent plusieurs sessions. Le dépôt Throttle avait déjà conclu que le metering multi-provider est commoditisé.

Forces concurrentes : visibilité, orchestration, worktrees, review/diff, usage/quota.
Faiblesses : observation sans politique de pression globale ; reprise native non couplée à une libération vérifiée des descendants ; pas de capsules génériques.
Leçon : **monitoring seul = feature gratuite. Hibernation fiable = produit.**

## 3. Opportunités manquées par le marché

1. **Unité de contrôle = workload, pas PID ni app.** Un Codex visible peut posséder shell, MCP, navigateur et build descendants. Un navigateur peut partager des helpers avec d'autres fenêtres. Le produit doit représenter appartenance, dépendances et frontières incertaines.
2. **Checkpoint vérifié avant arrêt.** La plupart des concurrents demandent de faire confiance à l'app. Throttle doit afficher : identité de session, dernier point persistant, fichiers modifiés, tâche active, sous-processus bloquants, stratégie de reprise et test du resume command.
3. **Mesure avant/après.** Afficher la pression, le swap, l'arbre visé, le gain estimé puis le gain observé. Ne pas sommer naïvement tous les RSS partagés.
4. **Journal transactionnel.** Une interruption entre snapshot et kill ne doit jamais transformer un workload en état ambigu. Chaque capsule a des phases et une récupération idempotente.
5. **Politique progressive.** Avertir, refuser de lancer un nouveau workload, sérialiser, park un idle vérifié, puis seulement action critique. Le focused/active/unsaved est protégé.
6. **Adaptateurs transparents.** Chaque pack publie ce qu'il capture, ce qu'il ne capture pas, les permissions, la fidélité et le mode de fallback.
7. **Personnalisation sans code obligatoire.** UI pour composer une recipe ; format texte exportable pour experts ; mode simulation montrant exactement ce qui serait arrêté/restauré.
8. **Privacy sans surveillance cloud.** Calcul et journal local, aucune lecture de transcript nécessaire pour une capsule quand l'identité native suffit.

## 4. Produit cible

### 4.1 Primitive centrale : Workspace Capsule

Une capsule contient :

- un identifiant stable et un nom de workspace ;
- des workloads et leurs dépendances ;
- l'adapter responsable et sa version ;
- le checkpoint minimal (session ID, cwd, app/document/URL autorisé, fenêtre si permission) ;
- le plan d'arrêt et le plan de reprise ;
- les blockers (processus actif, sauvegarde inconnue, audio, transfert, build, permission manquante) ;
- la dernière preuve de park/wake et la mesure de ressources ;
- un score de fidélité : `exact`, `semantic`, `best effort`, `manual`.

### 4.2 Trois actions, quatre politiques

- **Park** : préflight → checkpoint → terminaison gracieuse → vérification de l'arbre → mesure → journal durable.
- **Wake** : validation de l'environnement → lancement/reprise native → vérification de santé → restauration optionnelle du layout.
- **Protect** : empêche un nouveau workload ou réduit la concurrence quand la pression monte ; cette action est préférable à tuer ce qui travaille déjà.

Politiques :

1. `Observe only` — aucun contrôle.
2. `Ask before park` — recommandation et plan exact.
3. `Auto-park verified idle` — uniquement adapters exact/semantic, jamais le focused workload.
4. `Emergency protect` — bloque les nouveaux launches ; force-kill reste un geste utilisateur explicite.

### 4.3 Packs

**Dev Pack v1** : Codex CLI, Claude Code CLI, Terminal/iTerm/Ghostty, MCP descendants. Reprise via IDs first-party.
**Apple Dev Pack v1** : Simulator runtimes, Xcode builds, DerivedData tasks ; ne ferme pas Xcode avec document non sauvegardé.
**Browser Research Pack v2** : capture URLs/ordre quand l'autorisation existe ; sinon template/reopen best effort.
**Workspace Pack v2** : apps, documents explicitement choisis, fenêtres/displays via Accessibility.
**Custom Recipes v2** : hooks `preflight/checkpoint/stop/wake/verify`, timeouts, dépendances, secrets interdits dans l'export.

### 4.4 UX SOTA

Écran principal minimal :

- pression mémoire et tendance, pas une jauge anxiogène de RAM libre ;
- `Safe to park now: 3 workloads · estimated 6.2 GB` ;
- pour chaque capsule : activité, coût ressources, fidélité, dernier checkpoint, bouton Park/Wake ;
- explication avant action : « 14 processus seront terminés ; session Codex X reprendra avec `codex resume`; build Swift actif donc protégé » ;
- après action : gain observé, temps de reprise, erreurs, rollback/manual steps.

Accessibilité : clavier complet, VoiceOver, contraste accru, Reduce Motion, aucune dépendance à la couleur, confirmations lisibles, logs exportables sans données sensibles.

## 5. Architecture macOS recommandée

### 5.1 Distribution

`VERIFIED` — Le Mac App Store impose App Sandbox ; Apple indique qu'un app sandboxée ne peut pas terminer d'autres apps et limite les Apple Events/arbitrary app control. Le produit complet doit donc viser **Developer ID direct distribution**, hardened runtime, notarisation, staple et updater signé. Une version App Store éventuelle serait monitor-only et risque de créer une confusion produit.

### 5.2 Processus et sécurité

- Toute identité de processus doit inclure PID, uid, heure de démarrage et executable/bundle identity afin d'éviter le PID reuse.
- Ne jamais tuer un groupe sur simple nom de binaire.
- Préférer le contrat provider/app ; utiliser `NSRunningApplication.terminate()` pour les apps et une séquence coopérative pour les CLI.
- Attendre et vérifier la terminaison ; escalader SIGTERM puis SIGKILL seulement selon policy. Apple avertit qu'un force quit peut perdre des données.
- Un helper privilégié augmente énormément la surface d'attaque. Ne l'ajouter que si un benchmark démontre une capacité indispensable impossible au niveau utilisateur ; sinon gérer uniquement les processus du même utilisateur.
- Protéger systématiquement WindowServer, launchd, Finder et services essentiels ; liste deny-by-default signée et testée par version macOS.

### 5.3 Journal et reprise

Machine d'état :

`running → preflighting → checkpointed → stopping → parked → waking → verifying → running`

États terminaux d'erreur : `blocked`, `partial-stop`, `wake-failed`, `manual-recovery-required`. Chaque transition est persistée atomiquement. Un relaunch de Throttle doit pouvoir reprendre ou expliquer une transaction interrompue sans répéter aveuglément un kill.

### 5.4 Pression et décisions

- `DispatchSourceMemoryPressure` comme signal public principal (`normal`, `warning`, `critical`).
- Tendance swap/compression et ressources par workload comme contexte, sans présenter un calcul non documenté comme équivalent au kernel.
- Hystérésis, cooldown et plafond d'une seule action automatique à la fois.
- L'activité doit provenir de plusieurs signaux : processus enfants, CPU/IO récents, terminal foreground, tâche agent active, fichier de session progressant, audio/transfert.
- La règle par défaut protège le workload focused et tout état de checkpoint inconnu.

### 5.5 SDK d'adaptateurs

Contrat versionné :

```text
discover() -> workload candidates
preflight(workload) -> safe | blockers | fidelity
checkpoint(workload) -> opaque local checkpoint
stop(workload, policy) -> observed result
wake(checkpoint) -> workload
verify(workload, checkpoint) -> exact | semantic | degraded | failed
```

Les checkpoints restent locaux, chiffrés au repos si sensibles, et minimisent les données. Aucun adapter tiers ne reçoit un accès arbitraire au système : manifest de capacités, signature, timeouts, isolation de l'exécution et log d'audit.

## 6. État actuel de Throttle

`VERIFIED` dans le dépôt courant :

- `MultiCockpitModel.hibernate()` capture déjà une identité de reprise Claude/Codex puis appelle `SystemMemoryService.killSubtree`.
- le chemin Codex construit `codex resume '<id>'` ;
- `autoHibernateIfPressured()` réagit à la pression critique et protège la session focused ;
- `killSubtree` a une séquence TERM puis KILL.

`OPEN` : aucun test trouvé dans `ThrottleTests`/`ThrottleUITests` ne porte directement sur hibernate, auto-hibernate ou killSubtree. La présence du code n'établit donc ni absence de perte, ni arbre complet, ni reprise réelle, ni gain mémoire.

`SUPPORTED` — Le projet est plus proche d'un MVP qu'une création from scratch. Il faut extraire l'hibernation du cockpit agent vers un moteur de capsules, puis conserver le cockpit comme premier pack.

## 7. MVP et gates

### MVP 1 — « Never lose an agent session »

Périmètre : macOS direct, Codex CLI + Claude Code CLI, processus même utilisateur, mode Ask par défaut.

Doit livrer :

1. découverte robuste du workload et descendants ;
2. checkpoint provider-native ;
3. dry run explicable ;
4. park gracieux avec vérification ;
5. wake + test de reprise ;
6. journal crash-safe ;
7. pression mémoire + gain observé ;
8. aucune lecture/upload du contenu des transcripts ;
9. protections focused/active/build ;
10. tests de fault injection et matrice macOS.

### Gates binaires

| Gate | PASS requis |
|---|---|
| G0 Problème | 10 entretiens consentis + 5 journaux locaux anonymisés démontrent fréquence/impact |
| G1 Safety | zéro perte dans 1 000 cycles synthétiques ; chaque failure mène à recovery explicite |
| G2 Fidelity | ≥99 % de wake `exact/semantic` pour adapters supportés dans la matrice |
| G3 Resource | gain mesuré sous charge, sans RSS double-compté ; WindowServer reste responsive |
| G4 Permissions | onboarding clair, refus et révocation récupérables |
| G5 Security | threat model helper/adapters, signature, update, checkpoints, PID reuse, TOCTOU |
| G6 UX/AX | clavier, VoiceOver, contraste, Reduce Motion, erreurs et recovery sur Mac réel |
| G7 Distribution | Developer ID, hardened runtime, notarisation, staple, Gatekeeper, clean Mac |
| G8 Market | landing test et précommandes/refunds consentis ; willingness-to-pay non inventée |
| G9 Counter-audit | revue indépendante du candidat exact |

### Métriques produit

- incidents de travail perdu : cible 0 ;
- taux de wake exact/semantic ;
- temps p50/p95 de Park et Wake ;
- pression et swap avant/après ;
- Go de mémoire observé, avec méthodologie ;
- protections déclenchées et faux positifs ;
- nombre de reconstructions manuelles évitées ;
- crashes/partial-stop/manual recovery.

## 8. Modèle économique et go-to-market

`HYPOTHESIS` — Gratuit : observation, un workspace manuel, dry run.
`HYPOTHESIS` — Pro : 39 € one-time, Dev Pack, auto-park vérifié, capsules illimitées, custom recipes. Mises à niveau majeures payantes ; pas d'abonnement tant qu'il n'existe pas de service récurrent démontré.
`HYPOTHESIS` — Team plus tard : policies signées, export de diagnostics, déploiement MDM, jamais surveillance des transcripts.

Pourquoi 39 € plutôt que 10–20 $ : le produit doit prévenir une perte de travail et gouverner des agents, pas seulement ranger des fenêtres. Si le benchmark ne prouve pas ce niveau de valeur, revenir vers 19–29 €.

Canaux : communautés Codex/Claude, développeurs Apple 16 Go, Setapp seulement si le modèle économique et les permissions conviennent, contenu technique montrant des incidents reproductibles et une reprise vérifiée. Ne jamais utiliser la peur ni des captures de « RAM libre » sans pression réelle.

## 9. Risques de destruction de valeur

- Apple ou les providers ajoutent un budget global natif : rester provider-neutral et généraliser aux workloads.
- Une mauvaise règle cause une perte : mode Ask, adapters certifiés, journal transactionnel, force-kill hors automation.
- Scope creep vers terminal/IDE/window manager : intégrer par adapters et rester centré continuité + ressources.
- Permissions Accessibility/Automation trop intrusives : progressive disclosure ; le Dev Pack CLI doit fonctionner sans capture de fenêtres.
- Maintenance macOS coûteuse : support N/N-1, canary betas, matrice par adapter, kill switches de compatibilité.
- « Universal » impossible : publier une matrice honnête de fidélité, jamais une garantie globale.
- Prix indie faible : le moat est la safety evidence, pas la quantité de toggles.

## 10. Décisions recommandées

1. Renommer la direction produit **Throttle Workspaces** ou **Throttle Park** ; conserver Throttle comme marque.
2. Faire de l'hibernation vérifiée le cœur ; metering/cockpit deviennent signaux et adapters.
3. Livrer macOS Developer ID direct uniquement pour le produit complet.
4. Wedge Codex + Claude, puis Xcode/Simulator ; pas de promesse « toutes les apps ».
5. Rejeter « RAM cleaner », « lossless for every app » et « zero configuration auto-kill ».
6. Avant implémentation large : benchmark Cove + App Tamer + Throttle sur 12 scénarios, puis entretiens consentis.

## Sources principales revalidées

### Apple et plateformes

- Apple, Activity Monitor — memory pressure : https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac
- Apple, quit/force quit a process : https://support.apple.com/guide/activity-monitor/quit-a-process-actmntr1002/mac
- Apple, DispatchSourceMemoryPressure : https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure
- Apple, NSRunningApplication.forceTerminate : https://developer.apple.com/documentation/appkit/nsrunningapplication/forceterminate()
- Apple, App Sandbox : https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- Apple, configuring App Sandbox : https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox
- Apple, background processes : https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac

### Agents et incidents

- OpenAI, Codex CLI et resume : https://developers.openai.com/codex/cli
- Anthropic, Claude Code Desktop/session continuity : https://code.claude.com/docs/en/desktop
- Docker, Claude sandbox resource limits : https://docs.docker.com/reference/cli/sbx/create/claude/
- Codex #11523, global memory budget/OOM protection : https://github.com/openai/codex/issues/11523
- Codex #20740, 75–85 GB memory growth report : https://github.com/openai/codex/issues/20740
- Codex #18333, repeated MCP stacks/memory pressure : https://github.com/openai/codex/issues/18333
- Codex #34685, 16 GB WindowServer watchdog report : https://github.com/openai/codex/issues/34685
- Claude Code #30131, memory exhaustion report : https://github.com/anthropics/claude-code/issues/30131
- Stack Overflow Developer Survey 2025 : https://survey.stackoverflow.co/2025/

### Concurrents

- App Tamer : https://www.stclairsoft.com/AppTamer/
- App Tamer 3 beta : https://www.stclairsoft.com/AppTamer/beta.html
- App Tamer FAQ : https://www.stclairsoft.com/AppTamer/faq.html
- Cove : https://covemac.app/
- Later : https://github.com/alyssaxuu/later
- Bunch : https://bunchapp.co/docs/
- Snapback : https://snapbackapp.com/
- QuitAll : https://amicoapps.com/app/quitall/
- QuitAll user reviews (Setapp) : https://setapp.com/apps/quit-all-mac/customer-reviews
- Quit All Apps : https://quitallapps.app/
- AgentWatch : https://www.agentwatch.tools/
- Hydra : https://github.com/jpdlr/hydra

## Limites

- Les avis utilisateurs sont un échantillon auto-sélectionné et ne mesurent pas la prévalence.
- Les chiffres de prix et fonctionnalités sont volatils et doivent être rafraîchis avant une décision publique.
- Ce paquet n'a pas testé les concurrents localement ni exécuté un cycle réel Park/Wake de Throttle.
- L'état du dépôt est sale et actif ; aucune conclusion de release ne peut en être tirée.
- NotebookLM est utilisé ensuite pour contre-analyse, jamais comme autorité finale.
