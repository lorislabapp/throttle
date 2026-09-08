# Qualification 3.6.0 : journal de la branche candidate

Branche : `qualification/3.6.0-release-loop-ci`, base `cdae2c7`, candidats
`5b1f0f6` puis `a6dd34387081853a225818918244273659d17604`.
[PR de qualification #3](https://github.com/lorislabapp/throttle/pull/3).
Le lot PlanStore/diagnostics de la session concurrente reste dans
`build/context-testing-3.6.0` ; il n'est pas inclus dans cette sélection.

Ce journal remplace l'état de qualification du journal antérieur de ce worktree
concurrent. Les résultats historiques conservent leur date et leurs sources.

## Contrat

Reproduire, corriger, vérifier le comportement et conserver la preuve. Un résultat
absent, un outil défaillant ou une entrée périmée ne peut pas fermer un contrôle.
Le pilote obligatoire reste dix tâches réelles entièrement mesurées sur au moins
deux projets : les tests synthétiques et les tâches sans coût/temps humain ne
comptent pas. Aucun multiplicateur de productivité ni statut « SOTA » n'est déduit
des nombres de tests.

## Preuves acquises

| Contrôle | Résultat et portée |
|---|---|
| Sources de la CI Vault | 121 entrées et 15 artefacts du second run vérifiés ; aucune différence avec `a6dd343` |
| Vault Debug, CI stable | 42 XCTest + 115 fonctions Swift Testing, zéro omission ; 20 arguments annoncés et terminés par le runtime. Deux runs réussis |
| OCR scanné | Test réel réussi en CI Xcode 26.6/macOS 26.6.2 ; échecs locaux macOS 27 bêta conservés, sans modification du test ou de l'OCR |
| macOS Release | Compilation et contrôles quality réussis sur `a6dd343` ; ce build sans signature n'est pas un artefact de distribution |
| Validateurs Python | 120 réussis sur `a6dd343`, plus validateurs Swift/contexte et évaluations exécutés par la CI |
| Publisher iCloud | Sept tests ciblés ; reproduction de la réactivation après opt-out et de la notification différée, puis correction |
| Companion | 26 tests portables, avec contrepreuve par mutation. Les tests UIKit et les surfaces système restent distincts |
| Clés projet / XPC | Neuf tests de limites et 21 tests en processus ; contrôles 128 caractères et enveloppe de 65 536 octets. La CI Vault rejoue l'ensemble |
| Oracle symbolique | Accord sur 10 000 programmes avec l'oracle épinglé ; aucune exhaustivité formelle revendiquée |
| Crash Debug | Vrais processus temporaires SQLCipher : rollback d'écriture et de migration réussis |
| MCP et hook | Processus réel : 65 documents/738 passages ; hook idempotent au redémarrage. Aucun service installé modifié |
| Frontières Vault | Contrôles IPC et graphe de dépendances réussis ; le contrôle de bundle optionnel n'a pas été exécuté par le contrôle de graphe |
| Staging | 15 tests, signature Ed25519 vérifiée sur les octets copiés, refus d'un répertoire existant ; archive historique seulement |

Les sources du package utilisé pour les contrôles locaux MCP/hook ont été
comparées au candidat : 71 fichiers identiques. Cela ne qualifie pas l'application
installée ni le service XPC signé.

La première CI (`34254678879`, sources `5b1f0f6`) a détecté deux erreurs de
compilation des tests/UI, corrigées dans `a6dd343`. Le second run
[`34260476621`](https://github.com/lorislabapp/throttle/actions/runs/34260476621)
a détecté le passage d'une référence ActivityKit non Sendable entre domaines
d'isolation. La correction conserve la révocation immédiate et ordonne les mises
à jour avant la terminaison. Son exécution iOS native doit encore être vérifiée.

## Contrôles encore ouverts

| Gate | Condition de fermeture |
|---|---|
| Suite macOS actuelle | Fin complète du run et comparaison inventaire/résultats, dont six parcours Cockpit avec processus bornés |
| iOS / visionOS | Tests iOS réellement terminés après correction ActivityKit ; compilation Release visionOS des services partagés |
| Vault Release | Suite native complète, crash Release et refus explicite des modes Debug/direct stdio |
| Benchmark de recherche | Corpus figé reproductible ou nouvelle référence revue indépendamment : le corpus actuel diverge, le benchmark refuse de démarrer |
| Comptes et appareils | Changement réel iCloud, widget app absente, Live Activity, notifications, Face ID et terminal ; preuve native nécessaire |
| Sessions | Identité fournisseur, reprise, Quit réel et conversation Mac→Linux→Mac ; les anciens essais de lignes vides ne les prouvent pas |
| UX/accessibilité | Parcours utilisateur, clavier/VoiceOver et observations de performance |
| Pilote | 0/10 tâches entièrement mesurées ; premières tâches sur deux projets demandées, pas de mesures inventées |
| Distribution | Nouvel artefact exact après stabilisation ; signature, notarisation et acceptation de l'artefact restent séparées |

Le refus du benchmark est conservé dans `retrieval-gate.json`. Le corpus privé et
ses requêtes ne sont pas envoyés sur GitHub. Le jeu actuel dérive des titres et
sections ; il ne remplace pas un jeu de questions humaines indépendant.

## CI n°3 — troisième lot rejoué (run 34260476621 → 34265419804, HEAD `cbb0936`)

Le troisième lot a été committé et poussé le 8 septembre 2026 au soir, après
149/149 tests Python, SwiftLint 0.63.2 épinglé et `git diff --check` sur le
snapshot gelé. Résultat distant exact :

- `ios-tests` **PASS** : la correction ActivityKit est confirmée par une vraie
  compilation et les tests UIKit/SwiftTerm. `visionos-build`, `quality` et
  `validator-evidence` **PASS**.
- `vault-tests (release)` **FAIL** en 64 s à la compilation : `@testable import
  ResearchVaultIngestion` → `ModuleNotTestable`. `-c release` n'active pas la
  testabilité ; le vérificateur ne passait pas `-Xswiftc -enable-testing`.
  Corrigé pour les deux configurations (la matrice ne doit différer que par
  `-c`), avec assertion dans `test_vault_evidence.py`. Conséquence assumée :
  les binaires Release utilisés par les gates crash/refus sont compilés avec
  testabilité — un build de qualification, pas un artefact de distribution.
- `vault-tests (debug)` **FAIL** : 1 fonction Swift Testing sur 157,
  `ResearchVaultMCPProtocolHandlerTests.unknownTool`, `SQLCipher operation
  failed (key, code 1)` à `sqlite3_key`. Les sources du package sont inchangées
  depuis le run n°2 vert (le lot ne touchait que `Scripts/verify-crash-recovery.sh`).
  Classé intermittent ; **le test n'est pas modifié**, un second échantillon est
  demandé à la CI n°4. Gate ouvert tant que la cause n'est pas nommée.
- `macos-tests` **FAIL** : 645 cas, 3 échecs, tous dans `CockpitLifecycleTests`
  avec la fixture stabilisée (1 seul au run n°2) : `testHibernate…` (5,99 s),
  `testModelStop…` (5,70 s) et le tearDown de `testUnknownOwner…` (2,11 s), même
  message « Session stop could not be confirmed ». Lecture des durées : le test
  voisin `testHandoff…` passe en 1,68 s ≈ délai de grâce TERM → sur le runner
  hébergé, TERM ne termine pas l'arbre et l'escalade KILL ne se confirme pas
  toujours dans les 2 s. Non reproduit localement (20/20, session précédente).
  Le run contient 523 avertissements Thread Performance Checker (QoS UI en
  attente d'un thread Default). Action : **diagnostic uniquement** — les
  messages d'assertion listent désormais les membres survivants et les occupants
  du groupe (`proc_listpids` `PROC_PGRP_ONLY`, zombies inclus). Aucun délai
  produit relevé, aucun oracle assoupli. Gate ouvert.

L'édition Swift n'a pas été compilée localement (1,8 Gio de disque) ; la CI n°4
en est la vérification. Les artefacts complets du run n°3 restent sur GitHub.

## CI n°4 — quatrième lot (run 34269208573, HEAD `2e5193e`)

- `vault-tests (release)` **PASS** : la testabilité manquante était bien la
  cause. `vault-tests (debug)` **PASS** : second échantillon vert pour
  `unknownTool`, sans modification du test — l'échec du run n°3 est donc
  intermittent ; sa cause (`sqlite3_key` → SQLITE_ERROR) reste non nommée et
  le gate reste ouvert tant qu'elle ne l'est pas.
- `ios-tests` **FAIL** `command_timeout_or_interruption`, 0 cas : le log
  s'arrête juste après la sélection de destination du simulateur, avant toute
  compilation. Sources iOS identiques au run n°3 (vert). Classé infrastructure
  du runner hébergé ; aucun changement de code, à rejouer.
- `macos-tests` **FAIL** : 2 échecs Cockpit (`testHibernate…`, `testModelStop
  Failure…`), un jeu différent de celui du run n°3 — non déterministe. Les
  messages de diagnostic ajoutés au lot 4 nomment enfin la cause :
  `member 38722 not inspectable, kill(pid,0)=0 errno=3 ; member 38723
  kill=-1 errno=3 ; group 38722 kill(-group,0)=-1 errno=1 occupants=[38722 ?]`.
  Lecture : le shell racine est un **zombie** (le noyau ne garde que son code
  de sortie, `proc_pidinfo` ne le décrit plus, `kill(-groupe,0)` répond EPERM
  au lieu d'ESRCH) ; le fils `sleep` est parti. Le processus a bien terminé,
  mais son parent — le gestionnaire de sortie de SwiftTerm, sur la file
  principale — ne l'a pas encore récolté, et `OwnedProcessTermination.awaitExit`
  exigeait ESRCH sur le groupe. La confirmation dépendait donc de la latence
  de la file principale, jamais garantie sur un runner chargé (523
  avertissements Thread Performance Checker au run n°3) et pas davantage dans
  l'app réelle.

### Correction (cinquième lot)

`OwnedProcessTermination` reconnaît maintenant l'état noyau via `sysctl
KERN_PROC_PID` (`kernelState(of:)`, `isZombie`) : un membre zombie est un
reçu de sortie, et un groupe qui ne subsiste que par des zombies est
considéré parti (`onlyZombies(in:)`, liste `proc_listpids PROC_PGRP_ONLY` ;
une liste vide ou tronquée reste inconnue, donc refusée). Un processus vivant,
stoppé ou remplacé bloque toujours la confirmation ; aucun délai relevé, aucun
`waitpid` ajouté (la récolte reste à SwiftTerm, sinon course sur le code de
sortie). Test de régression `testUnreapedZombieIsAnExitReceiptUntilItsParentReaps`
(le fils se stoppe, est capturé vivant, sort sans être récolté ; `stop` doit
confirmer ; récolte en fin de test → ESRCH).

Preuves locales sur macOS 27 : `swiftc -typecheck` des deux fichiers produit ;
harnais autonome compilé avec ces mêmes fichiers reproduisant la signature CI
(`kill(-groupe,0)=-1 errno=1` sur un zombie non récolté) puis `stop() → stopped`
et ESRCH après récolte ; SwiftLint 0.63.2 exit 0 ; `git diff --check` propre.
Le harnais a d'abord révélé une course dans le test (CONT envoyé avant l'arrêt
du shell → stoppé pour toujours) ; le test attend désormais `SSTOP`. La suite
XCTest complète n'a pas été exécutée localement : CI n°5.

## CI n°5 — cinquième lot (run 34274128067, HEAD `fc4dde9`)

- `ios-tests` **PASS** : le timeout du run n°4 était bien l'infrastructure.
  `vault-tests` Debug et Release **PASS** (troisième échantillon vert pour
  `unknownTool`). `quality`, `validator-evidence`, `visionos-build` **PASS**.
- `macos-tests` **FAIL** : 646 cas, **1** échec. Le correctif produit est
  confirmé : chaque arrêt Cockpit est désormais confirmé (`testModelStop…`
  0,13 s contre 5,7 s ; `testUnknownOwner…` 0,06 s contre 2,1 s ; le nouveau
  test zombie passe). L'échec restant est dans `assertGone` du test
  `testHibernate…` : `errno 1 ≠ ESRCH` sur le groupe — le shell sorti n'est
  pas encore récolté au moment de l'assertion. Ce n'est plus l'oracle produit
  qui échoue, mais l'assertion de test, plus stricte que lui.
- Constat annexe, vérifié dans SwiftTerm 1.14.0 (`LocalProcess.deinit`) :
  le moniteur de sortie est annulé **sans** `waitpid` quand la vue est
  libérée. Avec l'oracle corrigé, `hibernate()` pouvait libérer le terminal
  avant la récolte et laisser un zombie par session hibernée.

### Sixième lot

`hibernate()` attend maintenant, après confirmation et avant de libérer les
vues, que plus aucune racine ne soit un zombie (`awaitReaping`, borne 1 s,
`Task.sleep` sur l'acteur principal pour laisser courir le gestionnaire de
SwiftTerm). La récolte reste à SwiftTerm ; aucun `waitpid` produit. Le test
`testHibernate…` vérifie explicitement que les groupes sont oubliés du noyau
(ESRCH) après hibernation — preuve de non-fuite — et `assertGone` tolère un
groupe qui ne subsiste que par des zombies, en nommant ses occupants.
`holdsOnlyZombies` devient interne pour être partagé par le test.

Preuves locales : `swiftc -typecheck` des fichiers produit autonomes,
SwiftLint 0.63.2 exit 0, `git diff --check` propre. `CockpitTab+Runtime.swift`
n'est pas typecheckable isolément ; CI n°6.

## CI n°6 — sixième lot (run 34276972984, HEAD `75d1c53`)

- Vault Debug/Release, visionOS, quality, validator-evidence **PASS**.
- `macos-tests` **FAIL** : 646 cas, 1 échec, toujours `testHibernate…`, cette
  fois sur la nouvelle preuve de non-fuite (`eventually { reaped }`, 3 s) :
  après 1 s d'attente cédée à la file principale puis 3 s supplémentaires, le
  shell sorti n'était toujours pas récolté par SwiftTerm sur le runner. Les six
  `OwnedProcessTerminationTests` passent (zombie compris) et les cinq autres
  parcours Cockpit passent en 0,06–0,28 s : l'oracle est bon, la récolte par
  SwiftTerm ne peut simplement pas être attendue sur une file affamée.
- `ios-tests` **FAIL** `command_timeout_or_interruption`, 2ᵉ fois sur 3 runs.
  Reçu : `build-for-testing` 155 s (ok) puis `test-without-building
  -enumerate-tests` **expiré à 300 s** (exit 124). Le runner froid démarre le
  simulateur à l'intérieur de cette étape.

### Septième lot

- `hibernate()` : après l'attente cédée (1 s), Throttle récolte lui-même
  (`waitpid` `WNOHANG`) toute racine encore zombie **dont il est le parent
  direct**, puis libère les vues. Les deux appelants de `waitpid` — SwiftTerm
  et ce repli — s'exécutent sur l'acteur principal, donc jamais en concurrence ;
  la libération qui suit annule définitivement le moniteur de SwiftTerm. Cela
  remplace l'énoncé « aucun waitpid » du cinquième lot, avec cette analyse de
  course. Le test de non-fuite est inchangé.
- Vérificateur iOS : démarrage explicite et reçu du simulateur
  (`xcrun simctl bootstatus <udid> -b`, 600 s) avant `xcodebuild`, et budget
  d'énumération porté de 300 à 600 s au vu des durées observées. Aucun oracle
  de test modifié ; 149/149 tests Python.

Preuves locales : `swiftc -typecheck` des fichiers produit autonomes,
SwiftLint 0.63.2 exit 0, `git diff --check` propre. CI n°7.

## CI n°7 — septième lot (run 34279369825, HEAD `0def4c3`)

- `ios-tests` **PASS** avec le démarrage explicite du simulateur ; Vault
  Debug/Release, visionOS, quality, validator-evidence **PASS**.
- `macos-tests` : **646 cas, 646 réussis** (5 skips autorisés), y compris
  `testHibernate…` en 1,7 s avec sa preuve de non-fuite. Le job reste rouge
  pour une seule erreur du **vérificateur** : `unknown_test_node_type:Failure
  Message`. Lecture de `tests.json` : les cinq nœuds concernés sont les motifs
  des cinq skips autorisés (« Test skipped - Set THROTTLE_RUN_EMBEDDED_MODEL_TEST=1… »
  etc.), que xcresulttool 26.6 étiquette « Failure Message » là où le
  vérificateur n'attendait que « Skip Message ». L'erreur était présente dans
  chaque run précédent, masquée par de vrais échecs.

### Huitième lot

Le vérificateur accepte « Failure Message » et « Skip Message » **uniquement**
sous un cas `Skipped` figurant dans les skips autorisés ; un message sous un
cas réussi ou échoué, ou imbriqué, est refusé (`message_outside_allowed_skip`).
Trois cas négatifs ajoutés ; 150/150 tests Python. Aucun changement Swift.

## CI n°8 — huitième lot (run 34281635340, HEAD `f846790`) : **première CI entièrement verte**

`quality`, `validator-evidence`, `vault-tests (debug)`, `vault-tests (release)`,
`macos-tests` (646 cas, 5 skips autorisés), `ios-tests`, `visionos-build` :
tous **PASS**. Le dépôt étant public, ces runs n'ont consommé aucune minute
facturable.

Ce que cette CI verte prouve : les suites natives et les vérificateurs sur
runner hébergé, pour ce candidat seul. Ce qu'elle ne prouve pas, inchangé :
la réconciliation avec `feat/context-testing-3.6.0` (9 conflits mesurés à
blanc), le benchmark de recherche (corpusDrift), les dix tâches réelles,
les parcours comptes/appareils/sessions, et l'artefact signé. Le verdict
**NO-GO publication** tient.

## Réconciliation avec `feat/context-testing-3.6.0` (9 septembre 2026)

Branche d'intégration `integration/3.6.0-sota-release`, créée depuis `f846790`
(B, CI verte) et fusionnant `083b615` (A, chantier SOTA/PlanStore/diagnostics
et confidentialité companion). Fusion à blanc préalable : 9 conflits.

| Fichier | Tranché | Pourquoi |
|---|---|---|
| `.github/workflows/ci.yml` | B | surensemble de A (mêmes étapes + iOS, visionOS, faux verts corrigés) |
| `ThrottleiOS/Services/ThrottleLiveActivity.swift` | B | `LiveActivityOperationQueue` prouvée en CI ; A portait l'ancienne version à jeton de génération, entièrement remplacée |
| `ThrottleiOS/Views/RemoteTerminalView.swift` | B | contenu identique des deux côtés |
| `ThrottleTests/ServiceTests/CockpitLifecycleTests.swift` | B | mêmes tests, fixture stabilisée et diagnostics prouvés (646/646) |
| `scripts/verify-vault-tests.py`, `test_vault_evidence.py` | B | surensemble (matrice Debug/Release, confinement, testabilité) |
| `scripts/verify-macos-evidence.py`, `test_macos_evidence.py` | B **+ port de A** | B ajoute `--scheme`/`--destination` ; l'option `--derived-data-path` de A est portée dans `build_arguments` avec un test (le cache seul change, jamais les rapports) |
| `docs/testing/2026-09-08-release-loop.md` | B | journal continué ici |

Tout le reste de A (125 fichiers : PlanStore, diagnostics, reçus de workflow,
retry MCP, tests de confidentialité iOS, vérificateurs core, journaux SOTA)
fusionne sans conflit. Sur l'arbre fusionné : 151/151 tests Python,
SwiftLint 0.63.2 exit 0 (baseline de A comprise), `git diff --check` propre,
`swiftc -typecheck` des fichiers produit autonomes. **Aucune compilation
native du candidat unifié n'a encore eu lieu** : c'est la CI de cette branche,
à lancer sur accord explicite. Les 670 tests locaux de A comme les 646 de B
ne valent pas pour l'arbre fusionné.

## Conservation et verdict

Les preuves compactes sont dans [evidence/2026-09-08-release-loop](evidence/2026-09-08-release-loop).
Les logs natifs compressés restent associés à leurs reçus d'origine ; le manifeste
local donne l'empreinte des fichiers conservés. Gitleaks a signalé 51 entrées de
ces preuves : chacune a été vérifiée comme une empreinte SHA-256 correspondant
au fichier indiqué, et non comme un secret. Aucune exclusion globale ajoutée.

**NO-GO publication** tant qu'un gate obligatoire reste ouvert. Le DMG antérieur
de `3abf6a6` ne contient pas ces corrections. Aucune installation, soumission
Apple ou publication n'a été effectuée pendant cette qualification. L'accord
d'upload sera demandé sur l'artefact concret, conformément au skill de publication.
