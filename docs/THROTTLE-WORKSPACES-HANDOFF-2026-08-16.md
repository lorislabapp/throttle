# Handoff de décision — Throttle Workspaces

Date : 2026-08-16
Destinataire : session Codex déjà active sur `/Users/kevinnadjarian/GitHub/Throttle`
Nature : contexte produit et technique à évaluer, **pas ordre d'implémentation**
Priorité : préserver l'objectif et le travail en cours de la session destinataire

## Instruction prioritaire à la session destinataire

Tu travailles déjà sur Throttle. Ce document ne remplace pas ton objectif courant et ne t'autorise pas à interrompre, réécrire ou élargir silencieusement ton chantier.

Avant toute modification :

1. relis ton objectif actuel, ton plan, les changements non committés et les validations restantes ;
2. inspecte ce handoff et le rapport SOTA lié en lecture seule ;
3. juge toi-même si Throttle Workspaces est :
   - déjà cohérent avec ton chantier ;
   - intégrable plus tard sans dérive ;
   - incompatible ou prématuré ;
4. réponds avec une recommandation motivée : `INTÉGRER MAINTENANT`, `PLANIFIER APRÈS L'OBJECTIF COURANT`, `EXTRAIRE EN EXPÉRIENCE` ou `REJETER` ;
5. n'implémente rien de ce handoff avant d'avoir protégé ou terminé ton objectif courant et d'avoir reçu une autorisation explicite si l'intégration élargit son périmètre.

Le worktree est actuellement très sale et actif. Ne pas reset, clean, stash, checkout, écraser, committer ou pousser les changements existants sans autorisation explicite. Considère tout changement préexistant comme appartenant à l'utilisateur ou à une autre session.

## Résumé exécutif

La proposition n'est pas une nouvelle application séparée ni un simple « RAM cleaner ». **Throttle Workspaces serait une capacité centrale du Throttle existant** : regrouper les processus d'un environnement de travail, enregistrer un checkpoint fiable, arrêter proprement son arbre de processus pour libérer réellement les ressources, puis reprendre le travail avec une fidélité vérifiée.

Formulation produit recommandée :

> Throttle parks heavy work, reclaims the Mac, and resumes exactly where it is safe to do so.

Verdict de la recherche : **GO étroit**, pas lancement universel.

- Premier wedge : sessions Codex CLI et Claude Code CLI déjà gérées dans le cockpit.
- Deuxième pack : Xcode, builds et Simulator, avec protections strictes.
- Usages macOS génériques : plus tard, uniquement par adaptateurs à capacités déclarées.
- La surveillance globale macOS, provisoirement appelée « Guardian », doit rester une couche complémentaire de mesure, alerte et protection. Elle ne doit pas devenir un moteur qui tue arbitrairement des applications inconnues.

## Pourquoi cette direction existe

Le besoin utilisateur initial est concret : plusieurs fenêtres et sessions Codex/Claude finissent par rendre le Mac lent ou incontrôlable, mais fermer les sessions à la main risque de perdre le contexte ou rend la reprise coûteuse.

Le marché propose déjà :

- des gouverneurs CPU comme App Tamer ;
- des boutons de fermeture globale comme QuitAll ;
- des gestionnaires de contexte comme Cove, Later, Bunch ou Snapback ;
- des cockpits d'agents et worktrees comme Hydra ou Conductor ;
- les outils natifs de pression mémoire de macOS.

La place encore défendable est la combinaison suivante :

1. unité de contrôle = workload/projet, pas PID isolé ;
2. checkpoint provider-native avant arrêt ;
3. arrêt vérifié de tous les descendants appartenant réellement au workload ;
4. mesure honnête du gain obtenu ;
5. reprise et vérification de fidélité ;
6. journal transactionnel permettant une récupération après interruption.

Le monitoring seul est une fonctionnalité. L'hibernation vérifiée peut devenir un produit.

## Ce que Throttle possède déjà

Le dépôt courant est plus proche d'un MVP que d'une création from scratch.

Observations vérifiées dans le code courant :

- `CockpitTab.hibernate()` retrouve et conserve déjà un identifiant de session Claude ou Codex ;
- la reprise utilise `claude --resume '<id>'` ou `codex resume '<id>'` ;
- `MultiCockpitModel.autoHibernateIfPressured()` réagit à la pression critique et évite la session active ;
- le mode de crowding utilise une pause réversible plutôt qu'une terminaison ;
- `SystemMemoryService.killSubtree` effectue TERM puis KILL sur les descendants survivants ;
- les onglets restaurés sont lancés paresseusement, ce qui évite de recréer immédiatement tout le working set ;
- le cockpit suit déjà activité, pression, RAM, coûts de reprise et signaux de tâches potentiellement actives.

Ces éléments sont une excellente base, mais ils ne prouvent pas encore l'absence de perte ni une reprise exacte.

Lacunes observées lors de la recherche :

- aucun test direct trouvé pour le cycle complet hibernate → kill tree → resume → verify ;
- l'identité de processus semble encore centrée sur PID/arbre courant, sans preuve complète contre le PID reuse et les frontières ambiguës ;
- le gain affiché repose en partie sur un RSS best effort qui peut devenir périmé et double-compter des pages partagées ;
- l'hibernation ne possède pas encore un journal transactionnel explicite avec états intermédiaires récupérables ;
- la capture d'un session ID puis la terminaison ne suffit pas à prouver que le provider a persisté le dernier état utile ;
- les règles de sécurité et de fidélité ne sont pas encore exposées comme contrat versionné par adaptateur.

## Définition proposée

### Workspace Capsule

Une capsule représente un environnement récupérable et contient au minimum :

- identifiant stable et nom du workspace ;
- projet/cwd et workloads associés ;
- processus, descendants et dépendances ;
- adaptateur responsable et version de son contrat ;
- checkpoint minimal local : session ID, cwd et métadonnées strictement nécessaires ;
- plan d'arrêt ;
- plan de reprise ;
- blockers détectés : tâche active, sauvegarde inconnue, build, transfert, permission manquante ;
- dernière preuve de park/wake ;
- mesure avant/après ;
- fidélité déclarée : `exact`, `semantic`, `best-effort` ou `manual`.

### Park

Pipeline recommandé :

`preflight → checkpoint → graceful stop → tree verification → resource measurement → durable parked state`

Un Park ne doit pas être marqué réussi seulement parce que le terminal a disparu. Il faut prouver que :

- le checkpoint est exploitable ;
- les processus visés sont réellement terminés ;
- aucun processus étranger n'a été touché ;
- la transition durable est cohérente ;
- le gain est mesuré avec une méthode explicitée.

### Wake

Pipeline recommandé :

`environment validation → native resume → health/fidelity verification → optional layout restore`

Le Wake doit produire un résultat explicite : `exact`, `semantic`, `degraded` ou `failed`, avec une marche de récupération manuelle si nécessaire.

### Protect

Quand la pression monte, la première réponse sûre consiste souvent à empêcher ou différer un nouveau workload lourd plutôt qu'à tuer ce qui travaille déjà.

Ordre de politique recommandé :

1. observer ;
2. prévenir ;
3. refuser ou sérialiser un nouveau lancement ;
4. proposer de parker un workload inactif et vérifié ;
5. auto-park uniquement après consentement et preuves ;
6. force-kill seulement comme geste utilisateur explicite.

## Relation avec Guardian

Guardian est la couche macOS globale étudiée dans une session séparée.

Guardian peut :

- surveiller la pression mémoire et sa tendance ;
- identifier les principaux workloads responsables ;
- avertir et expliquer ;
- appliquer une limitation douce quand elle est sûre ;
- appeler l'API de Park d'un workspace certifié ;
- empêcher la création d'une nouvelle charge sous pression critique.

Guardian ne doit pas :

- promettre de « nettoyer la RAM » ;
- tuer automatiquement une app inconnue ;
- supposer qu'un PID ou un nom de binaire représente tout un projet ;
- présenter SIGSTOP comme une libération réelle de mémoire ;
- promettre une restauration universelle sans contrat d'adaptateur.

Contrat architectural souhaité entre les deux surfaces :

- un moteur partagé de mesure et de pression ;
- une API de découverte et de Park/Wake des capsules ;
- les mêmes politiques de sécurité et de consentement ;
- un même journal local ;
- Guardian reste consommateur des capacités certifiées de Workspaces, jamais bypass du safety engine.

## Périmètre MVP recommandé

Nom de travail : **Never lose an agent session**.

Périmètre strict :

- macOS en distribution directe ;
- Codex CLI et Claude Code CLI ;
- processus appartenant au même utilisateur ;
- mode `Ask before park` par défaut ;
- aucune lecture ou transmission du contenu des transcripts si l'identité native suffit ;
- aucun contrôle générique d'app tierce dans ce MVP.

Fonctions minimales :

1. découverte robuste du workload et de ses descendants ;
2. checkpoint provider-native ;
3. dry run expliquant exactement l'action ;
4. arrêt coopératif puis escalade contrôlée ;
5. vérification de l'arbre après arrêt ;
6. reprise native ;
7. vérification de santé et de fidélité ;
8. journal crash-safe et idempotent ;
9. pression mémoire et gain observé ;
10. protections focused/working/waiting/build/tool call ;
11. fallback manuel documenté ;
12. tests de fault injection.

## Architecture cible, sans imposer un refactor immédiat

Contrat conceptuel d'adaptateur :

```text
discover() -> workload candidates
preflight(workload) -> safe | blockers | fidelity
checkpoint(workload) -> opaque local checkpoint
stop(workload, policy) -> observed result
wake(checkpoint) -> workload
verify(workload, checkpoint) -> exact | semantic | degraded | failed
```

Machine d'état conceptuelle :

```text
running
  -> preflighting
  -> checkpointed
  -> stopping
  -> parked
  -> waking
  -> verifying
  -> running
```

Erreurs durables attendues :

```text
blocked
partial-stop
wake-failed
manual-recovery-required
```

Exigences techniques :

- identité de processus composée au minimum de PID, UID, heure de démarrage et identité executable/bundle ;
- ne jamais tuer sur simple nom de binaire ;
- terminaison coopérative en premier ;
- TERM puis KILL seulement selon une politique explicite ;
- vérification après chaque transition ;
- écriture atomique du journal ;
- reprise idempotente après crash de Throttle ;
- une seule transaction automatique à la fois ;
- hystérésis et cooldown sur la pression mémoire ;
- denylist stricte des processus système essentiels ;
- aucun helper privilégié tant qu'un benchmark ne prouve pas sa nécessité.

## UX attendue

L'écran principal doit expliquer plutôt qu'inquiéter :

- pression mémoire et tendance, pas seulement « RAM libre » ;
- `Safe to park now: N workloads · estimated X GB` ;
- activité, coût, fidélité et dernier checkpoint de chaque capsule ;
- avant Park : liste des processus, méthode de reprise et blockers ;
- après Park : gain observé et processus restant éventuellement ;
- après Wake : résultat de fidélité et marche de récupération.

Politiques utilisateur :

- `Observe only` ;
- `Ask before park` ;
- `Auto-park verified idle`, opt-in ;
- `Emergency protect`, qui bloque de nouveaux workloads avant de tuer les actifs.

Ne jamais auto-parker :

- le workspace focused ;
- un agent en train de travailler ou d'attendre une interaction active ;
- un build/transfert/tool call non résolu ;
- un workload dont le checkpoint est inconnu ;
- un adaptateur `best-effort` sans consentement explicite.

## Gates binaires avant promesse commerciale

| Gate | PASS requis |
|---|---|
| Problème | 10 entretiens consentis et 5 traces locales anonymisées démontrent fréquence et impact |
| Safety | zéro perte sur 1 000 cycles synthétiques avec fault injection |
| Fidélité | au moins 99 % de Wake exact ou sémantique pour les adaptateurs supportés |
| Ressources | amélioration mesurée de pression/swap sans somme RSS naïve |
| Permissions | refus, révocation et réautorisation récupérables |
| Sécurité | threat model couvrant adapters, update, journal, PID reuse et TOCTOU |
| Accessibilité | parcours clavier/VoiceOver/Reduce Motion validé sur Mac réel |
| Distribution | Developer ID, hardened runtime, notarisation, staple et Gatekeeper sur Mac propre |
| Contre-audit | revue indépendante sans P0/P1 ouvert |

Tant que ces gates ne passent pas, les formulations « lossless », « exact resume » et « SOTA » restent des hypothèses, pas des claims marketing.

## Positionnement et modèle économique

Positionnement défendable : continuité de travail et sécurité sous pression, pas optimisation cosmétique.

Concurrents de référence :

- App Tamer : 14,95 USD, très fort sur le throttling CPU ;
- Cove : 19,99 USD à vie, très proche sur le park/restore de fenêtres et apps ;
- Conductor : orchestration/worktrees gratuits, donc l'isolation Git n'est pas différenciante ;
- QuitAll/Later/Bunch/Snapback : simplicité, recipes et restauration partielle.

Hypothèse de prix :

- gratuit : observation, dry run et un workspace manuel ;
- Pro : 39 EUR one-time seulement si la sécurité et le gain supérieur à App Tamer + Cove sont prouvés ;
- sinon revenir vers 19–29 EUR ;
- pas d'abonnement sans service récurrent démontré.

## Non-objectifs à protéger

- ne pas transformer Throttle en window manager généraliste ;
- ne pas refaire Docker ;
- ne pas copier Conductor ou Cove ;
- ne pas promettre toutes les apps ;
- ne pas ajouter un helper root par confort ;
- ne pas installer ou modifier silencieusement la configuration Claude/Codex ;
- ne pas envoyer de transcripts ou checkpoints sensibles au cloud ;
- ne pas mélanger cette direction avec la release ou le chantier courant sans décision explicite.

## Méthode d'intégration recommandée si la session juge le sujet compatible

1. Terminer ou stabiliser d'abord l'objectif courant.
2. Produire un snapshot du comportement existant de l'hibernation et de ses tests.
3. Écrire des characterization tests avant tout refactor.
4. Extraire progressivement le contrat de capsule derrière les comportements actuels.
5. Commencer par un adaptateur Codex et un adaptateur Claude, sans UI générique.
6. Ajouter journal et vérification avant l'automatisation.
7. Benchmark sur scénarios reproductibles avant changement marketing.
8. Garder l'ancien chemin derrière un rollback tant que le nouveau moteur n'a pas passé les gates.

Découpage suggéré, uniquement comme option :

- Phase A : tests et mesure du comportement existant ;
- Phase B : modèle `WorkspaceCapsule` et journal sans changer l'UX ;
- Phase C : adapters Claude/Codex ;
- Phase D : Park/Wake vérifiés en mode manuel ;
- Phase E : intégration Guardian en mode Observe/Ask ;
- Phase F : automation opt-in après preuves.

## Questions que la session destinataire doit trancher

1. Son objectif courant touche-t-il déjà `MultiCockpitModel`, `SystemMemoryService` ou la persistance des sessions ?
2. Cette proposition réduit-elle la dette du chantier courant ou crée-t-elle un refactor concurrent ?
3. Les changements locaux actuels contiennent-ils déjà une architecture plus avancée que celle observée par la recherche ?
4. Quel est le plus petit test de caractérisation ajoutable sans détourner le chantier ?
5. Faut-il garder « Workspaces » comme nom interne de capacité, sans changement de marque ?
6. Quelles affirmations peuvent être prouvées aujourd'hui, et lesquelles doivent rester `OPEN` ?

## Format de réponse demandé à la session destinataire

Répondre d'abord sans modifier le dépôt :

```text
Décision : INTÉGRER MAINTENANT | PLANIFIER APRÈS L'OBJECTIF COURANT | EXTRAIRE EN EXPÉRIENCE | REJETER

Objectif courant compris : ...
État du travail courant à préserver : ...
Chevauchement réel avec Workspaces : ...
Risques de collision : ...
Ce qui existe déjà et dépasse le handoff : ...
Plus petit prochain pas sûr : ...
Autorisation supplémentaire requise : oui/non, pourquoi
```

## Sources et artefacts

Rapport complet, concurrents, avis, architecture, marché et sources :

- `docs/research/2026-08-16-throttle-workspaces-market-product-sota.md`

DeepSearsh :

- document : `dr-44a17c5b497ab4ae`
- SHA-256 : `44a17c5b497ab4aebf9d3ad02157681644548d513e79827d46671506c859e701`
- copie : `/Users/kevinnadjarian/GitHub/DeepSearsh/library/market-and-competitors/throttle/2026-08-16-throttle-workspaces-market-product-sota--44a17c5b49.md`

NotebookLM vérifié :

- titre : `Throttle — SOTA 2026`
- UUID : `21a700d7-1ecc-4f3e-a7bf-29f46c6ff66c`
- URL : https://notebook.google.com/notebook/21a700d7-1ecc-4f3e-a7bf-29f46c6ff66c
- 38 cartes sources affichées lors de la vérification ; trois imports non exploitables, catégories couvertes ailleurs.

Limite NotebookLM : la contre-analyse avec citations a été vérifiée visuellement dans l'application, mais le validateur automatique n'a pas sérialisé les identités exactes des citations. NotebookLM reste un outil de contradiction/synthèse, pas une autorité finale.

Sources primaires principales :

- Apple memory pressure : https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac
- Apple process quit : https://support.apple.com/guide/activity-monitor/quit-a-process-actmntr1002/mac
- Apple memory pressure API : https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure
- Apple App Sandbox : https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- Codex CLI/resume : https://developers.openai.com/codex/cli
- Claude session continuity : https://code.claude.com/docs/en/desktop
- Codex global memory budget request : https://github.com/openai/codex/issues/11523
- Codex 75–85 GB report : https://github.com/openai/codex/issues/20740
- Codex repeated MCP stacks : https://github.com/openai/codex/issues/18333
- Codex WindowServer/watchdog report : https://github.com/openai/codex/issues/34685
- Claude memory exhaustion report : https://github.com/anthropics/claude-code/issues/30131
- App Tamer : https://www.stclairsoft.com/AppTamer/
- Cove : https://covemac.app/
- Later : https://github.com/alyssaxuu/later
- Bunch : https://bunchapp.co/docs/
- Snapback : https://snapbackapp.com/
- QuitAll reviews : https://setapp.com/apps/quit-all-mac/customer-reviews
- Hydra : https://github.com/jpdlr/hydra

## Rappel final

Ce handoff transfère une opportunité et ses preuves. Il ne transfère pas l'autorité d'abandonner l'objectif courant ni celle de modifier le produit immédiatement. La bonne première action est une décision d'intégration fondée sur l'état réel du chantier actif.
