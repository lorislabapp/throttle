# Validation du workflow et des tests — 8 septembre 2026

> Reprise ultérieure : les deux sessions sont réunies sur `3abf6a6` dans `build/context-testing-3.6.0`. Le repli OCR et les suites finales passent ; voir [le rapport d’intégration actuel](../../build/context-testing-3.6.0/docs/testing/2026-09-08-integration-3.6.0.md). Ce document conserve les preuves du snapshot initial.

Périmètre initial : Throttle, ses packages, expériences de contexte et commandes de validation communes. Les autres applications ne sont pas modifiées. Aucun déploiement, installation, commit ou changement de configuration d’agent.

Snapshot initial : `feat/research-vault-lots-1-4` à `ce083dec72bd06b8c4ba2b6e379e6de3424b5da7`, `.install-backups/` préexistant non suivi. Worktree `plan-store` à `42f26e9`, consulté seulement. Espace libre initial : 2,2 Gio ; privilégier les suites isolées sans dépendances lourdes.

## Plan et journal

| Lot | Résultat attendu | État et preuve |
|---|---|---|
| T1 — validateurs de résultats | Un échec reconnu ne devient pas un succès détecté ; inconnus et succès restent distincts | CORRIGÉ ET TESTÉ. Compteurs mixtes, ordre inversé, erreurs seules, contradiction entre frameworks, compteurs invalides et prose |
| T2 — mesures de récupération | Questions sans réponse et récupération mesurées séparément ; valeurs invalides refusées | CORRIGÉ ET TESTÉ. Dénominateurs distincts, effectifs exposés ; absence de mesure ne vaut pas 100 % ; NaN/Inf/hors bornes refusés ; test statistique stable à grand effectif |
| T3 — mesure du coût | Inclure les tentatives ratées et ne pas inventer un coût lorsque les mesures sont incomplètes | CORRIGÉ ET TESTÉ. Tous les deltas observés / succès ; ancrage avant fenêtre, coût absent/négatif et remise à zéro traités explicitement |
| T4 — exécution et preuve | Commande légère reproductible, sources exactes, tests négatifs et résultat final exploitable | IMPLÉMENTÉ. 39 tests Swift ciblés et 9 tests de vérificateurs passent ; job CI ajouté mais non exécuté sur GitHub |
| T5 — pilote | Instrument prêt pour dix tâches réelles, cas de contexte et reprise, sans résultats fictifs | PRÊT. [Protocole](workflow.md) et [registre](pilot-10-tasks.csv) ; 0/10 observations, aucun gain de productivité annoncé |
| C1 — paquet de contexte | Budget respecté après numérotation ; original réellement récupérable | CORRIGÉ ET TESTÉ. Hash vérifié à la lecture et avant réutilisation ; métadonnées bornées ; échec de stockage explicite |

Chaque lot : régression avant correction, modification minimale, suite ciblée, inspection du diff et mise à jour de ce journal. Retour arrière : retrait du seul diff de ce travail après revue, sans toucher aux modifications préexistantes.

## Résultat local et preuves

**Le socle ciblé passe. La validation globale reste incomplète : un test OCR Research Vault échoue.** La recherche de référence reste consultable dans [le rapport SOTA](2026-09-08-research-background.md), qui décrit le snapshot avant ces changements.

| Vérification effectuée | Résultat et portée |
|---|---|
| Sources exactes Swift isolées | 39/39 : détecteur, coût, intégrité/budget du contexte, récupération et critères de promotion. [Reçu final](evidence/2026-09-08/core/receipt.json), deux rapports XML et log dans le même dossier |
| Réducteur de contexte Node | 16/16 tests, dont 144 variantes déterministes de préservation des erreurs ; protocole MCP réel par stdio |
| Corpus du réducteur | 12/12 cas synthétiques ; ce n’est pas un benchmark de tâches réelles ni de modèle local |
| Vérificateurs Python/shell | 9/9 : faux succès, absence de rapport/cas/fichier/outil, erreur au niveau de suite, tests ignorés, duplication et redaction des résultats de grep |
| Edge agent | Deux groupes d’autotests passent : contrats de mission et échappement shell |
| Compilation ResearchVaultKit | Debug natif, `--build-tests`, 2 jobs, dépendances déjà résolues : réussie, y compris le consommateur `BenchmarkMain` |
| ResearchVaultKit XCTest | 42/42, aucun échec ; SQLCipher réel, sauvegarde, rollback, portée et intégrité. [Rapport](evidence/2026-09-08/vault-final-xctest.xml) |
| ResearchVaultKit Swift Testing | 97/98 réussis ; OCR du PDF scanné en échec, y compris hors sandbox. [Rapport complet](evidence/2026-09-08/vault-final-swift-testing.xml) |
| SwiftLint 0.65.1 | Mode strict sur les 12 fichiers Swift concernés : passe |
| Contrôles de diff / syntaxe | `git diff --check`, YAML de CI, shell et registre CSV : passent |

Les nombres des suites se recouvrent : **ne pas les additionner pour annoncer un total de tests uniques**. La suite isolée recopie des tests également présents dans le package.

Régressions reproduites avant correction : quatre nouveaux tests Node rouges ; métriques de récupération rouges ; cinq des six scénarios de contexte rouges (corruption, hash malformé, dépassement du budget, métadonnées surdimensionnées, stockage indisponible). Les rapports Swift avant correction sont conservés dans `evidence/2026-09-08/before-retrieval` et `before-context`. Les autres contrôles sont des tests de non-régression ; ils ne constituent pas une campagne exhaustive de mutation testing.

## Revue des implémentations de tests

La revue a couvert les entrées de CI, les scripts de validation, l’inventaire des suites et les implémentations critiques de contexte/résultat/recherche. Ce n’est pas une lecture exhaustive de chaque test du portefeuille.

- **Existant à conserver :** tests SQLCipher transactionnels, frontière de projets et sensibilité, altération d’enveloppes, idempotence ; tests de vrai Git dans le worktree `plan-store` ; script de crash et oracle différentiel dans Research Vault.
- **Faux succès corrigés :** résumés contradictoires, scores de récupération gonflés par l’abstention, coût excluant les échecs, absence d’oracle traitée comme un succès. Les assertions négatives de CI utilisent désormais `assert-no-match.sh` : seul le code 1 de grep prouve l’absence ; erreur de lecture ou outil absent fait échouer le contrôle.
- **Couverture CI ajoutée :** job indépendant `validator-evidence`, sans hôte GUI, modèle, corpus privé ni MLX. Les reçus sont imprimés dans les logs CI. Vérification aussi de la présence de `jq` et du refus d’un identifiant simulateur `null`.
- **Limites restantes :** la CI principale construit l’app macOS mais ne teste pas toute sa suite hébergée ; le script spécialisé Research Vault couvre davantage que le nouveau job. Le benchmark de récupération fondé sur titres/sections ne remplace pas les vraies questions françaises/anglaises, ambiguës, périmées et hors projet.
- **Télémétrie :** le détecteur voit encore une fin de terminal et les résumés peuvent être répétés/dédupliqués. Son indicateur de coût reste une estimation locale, distincte du coût total par tâche réellement acceptée du pilote.

## Échec OCR et contraintes d’environnement

Le test `scannedPDFIsRecoveredByOCR` a échoué dans la suite, puis hors sandbox. Un diagnostic temporaire utilisant la même fixture a produit une image lisible, inspectée visuellement. L’appel direct à Vision échoue aussi ; après récupération d’espace, les révisions 3, 2 et 1 ont toutes renvoyé `e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)`. Le défaut est donc reproductible dans le moteur OCR local, indépendamment de l’extraction PDF. La cause racine (runtime, ressources ou autre état de la machine) n’est pas établie.

Le test n’a été ni ignoré ni affaibli ; le code OCR n’a pas été modifié. L’environnement utilise Xcode 27 beta/macOS 27. L’espace libre a varié de 2,2 Gio à environ 100 Mio ; seuls les `.build` temporaires créés par cette intervention ont été retirés, en conservant leurs rapports et sources, pour récupérer environ 1,4 Gio. Pas de nettoyage d’autres projets, de modification de services système ni de changement de configuration.

Pour clôturer la validation globale : rétablir un environnement OCR fonctionnel et rejouer ce test puis la suite concernée ; exécuter la suite hébergée macOS et les parcours UI dans un environnement disposant de suffisamment d’espace ; observer les dix tâches réelles. Aucun de ces résultats n’est déduit des tests ciblés.

## Ce que nous retenons de la vidéo

| Technique | Application à Throttle |
|---|---|
| Tests unitaires et contrat avant code | Corriger les validateurs avec entrées adverses et résultats attendus indépendants |
| Tests d’intégration réels | Conserver les tests utilisant de vrais dépôts Git, SQLite/SQLCipher et frontières IPC ; distinguer ceux qui tournent en CI |
| Simulation et injection de pannes | Variations déterministes de logs, budgets, ordre des événements, erreurs, interruptions et données invalides ; graine reproductible quand aléatoire |
| Tests de propriétés / métamorphiques | Ajouter du bruit ou changer l’ordre ne doit pas effacer un échec ; ajouter des questions sans réponse ne doit pas améliorer le rappel positif |
| Mutation testing | Contrôles négatifs ciblés sur les oracles ; vérifier que les anciennes implémentations échouent |
| Revue de sécurité automatisée | Complément aux contrôles déterministes, pas preuve d’absence de faille ; aucun pentest d’infrastructure lancé |
| Simulation formelle exhaustive | Non déduite de la simulation ; à réserver éventuellement à une petite machine à états |
| Réécriture globale / Rust partout | Non retenue ; aucune preuve de bénéfice pour Throttle actuel |

## Inventaire initial

- `ThrottleTests` : tests macOS du produit ; la CI consultée construit macOS mais n’exécute pas toute cette suite.
- `ThrottleiOSTests` : état de verrouillage du terminal ; exécution simulateur en CI.
- `ThrottleShared/Tests` : contrats partagés et transport pair ; commande SwiftPM en CI.
- `Packages/ResearchVaultKit/Tests` : ingestion, métriques, stockage, SQLCipher, raisonnement, IPC, sécurité, synthèse et clés ; script complet spécialisé, absent de la CI principale consultée.
- `Packages/ResearchVaultKit/Scripts/verify*.sh` : oracles différentiels, récupération de crash, frontières de dépendances, processus MCP et restrictions Release.
- `experiments/local-context-refinery` : tests Node et petit corpus d’évaluation ; absents de la CI principale consultée.
- `experiments/local-delegation-bench` : quatre cas historiques, modèle requis ; pas une mesure de fiabilité générale.
- `edge-agent` : autotests de contrats et échappement ; pas un essai du service déployé.
- `scripts/smoke-test.sh` : contrôles de bundle et signature ; pas une validation du parcours utilisateur.
- `plan-store` : tests réels de Git et tests de projection/événements ; dans un autre worktree, pas une preuve d’intégration de cette branche.

## Limites qui restent distinctes

Tests de code, suite complète macOS, UI, application installée, appareil et distribution sont des preuves séparées. Les résultats de dix tâches ne pourront pas être remplacés par dix tests synthétiques. L’audit de chaque application du portefeuille est un périmètre distinct de cette première passe.
