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
