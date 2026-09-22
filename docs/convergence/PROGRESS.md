# Convergence Throttle — reprise persistante du 20 septembre 2026

**État courant au 21 septembre,10:09 :358 tests noyau PASS, SwiftLint strict global PASS, Debug100452 PASS,84 cas natifs en neuf suites +8 répétitions FR PASS sur hôte interne100617.100 empreintes de convergence,155 du noyau et1047 sources natives sans dérive. Archive093142 historique après corrections ; prochaine archive après décision Claude web. Aucun signataire Developer ID, upload, installation ou restart exécuté.**

## Reprise et identité

Worktree `/Users/kevinnadjarian/GitHub/Throttle/build/convergence-recovery-20260920`, branche `codex/convergence-recovery-20260920`, base `1ac0a32f02f2cce9707779e41118ea39e7eb97d7`. Sources restaurées depuis les écritures examinées de la session après disparition du worktree temporaire au redémarrage. Aucune commande historique de build, signal ou réseau rejouée. Les 1 302 empreintes du cockpit original ont été recontrôlées sans différence. Le dépôt principal et Super-Orchestrateur/SuperGateway restent préservés.

[CHANGES.md](CHANGES.md) et [changes.json](changes.json) distinguent les corrections cumulées des fichiers hérités. Les archives de reprise persistantes se trouvent dans `/Users/kevinnadjarian/GitHub/Throttle/build/convergence-recovery-inputs-20260920`. Les anciens résultats 279–295 sans reçus survivants ne sont pas revendiqués comme preuves actuelles ; les reçus 306, 337 et 352 sont conservés séparément.

## Périmètre courant

Voir [RELEASE-SCOPE.md](RELEASE-SCOPE.md), décision utilisateur explicite. Les promesses de confinement de code hostile, de récupération exhaustive des effets Git et d'autonomie produit complète sont différées. Cela ne dispense pas des tests du candidat, des parcours UI/accessibilité, ni de la qualification de distribution.

Corrections cumulées : lecture projet bornée, autorité MCP épinglée, intention durable de vérification et admission par pipe, identité de processus et UNKNOWN conservé, fusion de l'OID vérifié, diff en erreur explicite, routage local par défaut et serveur choisi séparément, contrôle terminal distinct du miroir, flux API borné et complet requis pour les outils, annulation de consommation reliée à l'UI. Réemploi de PlanStore, TaskSpend, ClaudeAgentInventory et StatsDataService.

## Vérifications réellement exécutées

- **352 tests PASS : 313 XCTest + 39 Swift Testing, 111,885 s.** [Reçu](evidence/core-352/receipt.json), [XCTest](evidence/core-352/xctest.xml), [Swift Testing](evidence/core-352/swift-testing.xml), [log](evidence/core-352/output.log). Exécution `throttle-core-evidence-lk8javop`, 153 empreintes sources recontrôlées sans dérive à son achèvement.
- Couverture inclut fixtures Git et descendants, crash réel avant admission, racines et lectures adversariales, grants/mission/retry, matrice de routage (11), révocation du contrôle terminal (3), SSE tronqué/malformé/bornes, RemoteTransferGit (3), Keychain simulé (10) et processus NotebookLM (5).
- Cette suite n'exécute ni GUI, ni fournisseur, ni compte CloudKit, ni Keychain réel. PlanIntegrationFlow, PromptRefiner et RemoteSessionsCredential sont hors du reçu noyau ; ils ont désormais un reçu natif distinct ci-dessous. Les dix tests du journal RemoteTransfer ont depuis réussi dans le reçu natif complémentaire ci-dessous.
- **Build natif non signé PASS** : `build-for-testing`, 26,418 s, 1 031 fichiers sources sans dérive, aucune concurrence pendant ce build. [Reçu](evidence/native-build/build-20260920-230917-receipt.json). Erreur `RemoteTransferGit` corrigée et anciennes tentatives interrompues conservées dans [NATIVE-VALIDATION.md](NATIVE-VALIDATION.md).
- **45 tests natifs PASS, zéro échec et zéro skip**, candidat final : `tests-20260920-231047`, 88,826 s. [Résumé xcresult](evidence/native-tests-231047/summary.json), [inventaire](evidence/native-tests-231047/tests.json), [reçu](evidence/native-tests-231047/tests-20260920-231047-receipt.json). Hôte XCTest isolé confirmé dans le log ; aucun restart de l’app installée. Vues de dépenses et arbre AX anglais exercés, pas tout le parcours utilisateur.
- SwiftLint strict ciblé final : SSE/protocole/provider, client/processus NotebookLM, Keychain et tests nouveaux sans violation. Gate peer/process/routage également validé précédemment. Dette de taille/complexité de grandes vues legacy toujours présente ; aucun lint global vert revendiqué.
- `xcodegen generate` après les derniers ajouts et `git diff --check` : réussis.

**Sources figées et empreintes du reçu recontrôlées : aucune dérive.** Le refactor SSE, Keychain et helper NotebookLM sont couverts au niveau noyau ; compilation native et quatre suites ciblées sont également réussies. Les parcours produit complets restent à observer.

## Commandes et prochaine étape

Harness : `python3 scripts/verify-core-evidence.py --output-parent /Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/evidence --scratch-path /Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/cache --timeout-seconds 600`.

Build : runner `/Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/run-native-build.py`, DerivedData et dépendances isolés sur DeveloperStorage, deux jobs. Admission si aucun xcodebuild et interruption de notre seul enfant si concurrence. La campagne Clasp a libéré le créneau : admission du build après 91 s. L’accès UI a finalement fonctionné en désignant `/Applications/Throttle.app` (identifiant ambigu entre copies), mais la tentative de message a été interrompue par un changement UI utilisateur ; aucun envoi confirmé. Aucun redémarrage de l’app installée.

Prochaine étape : archive Release non signée de diagnostic, puis parcours UX restant du candidat et qualification de distribution. [Verdict](../../audit-output/pre-submission-verdict.md) et [roadmap hors release progressive](REMAINING-GATES.md).

Aucun commit, push, migration inter-projets, signature, installation, déploiement ou publication. L'autorisation UI de coordination n'est pas une autorisation de redémarrer un nouveau candidat.

## Créneau confirmé

L’utilisateur a confirmé « Créneau réservé maintenant » pour environ 10 min. La reprise de l’archive attend 10 s sans xcodebuild et au moins 2 Gio système disponibles, puis utilise le cache sur DeveloperStorage. Cette réservation n’autorise ni signature ni publication.

## Point de reprise final — archive encore bloquée

La dernière archive `archive-20260920-232843` a été interrompue après 34,550 s par un nouveau build Éclair (`Eclair_macOS`). Aucun succès Release revendiqué. [Détails et reçus](NATIVE-VALIDATION.md#résultat-de-la-dernière-reprise-et-blocage-de-coordination). La coordination UI a laissé un message visible mais non envoyé : Entrée refusée par le contrôle automatique faute de cible AX de saisie vérifiable. Aucun processus tiers arrêté, aucune relance de l’app installée.

Prochaine tâche : obtenir une pause effective des nouveaux builds Éclair et autres sessions, puis relancer `run-native-archive.py` avec son garde. Après PASS seulement : inspecter le bundle non signé, puis compléter la QA produit et les gates de distribution. Cette reprise n’a changé que la documentation et les preuves ; aucun nouveau changement applicatif. Point de sauvegarde persistant rafraîchi dans `convergence-recovery-inputs-20260920`.

## Reprise réussie — archive et transfert

**Archive Release non signée PASS** : `archive-20260920-235130`, exit 0, **383,098 s**, 1 031 sources sans dérive et aucun concurrent. [Reçu](evidence/release-archive/archive-20260920-235130-receipt.json), [candidat](evidence/release-archive/candidate.json). Version source 3.8.0 (226), arm64, minimum macOS 14.0, SDK 27.0. L’app n’a pas été lancée par l’archive. Cinq avertissements conservés : un Swift dans ResearchClaimsBoard, quatre C++17/Metal dans MLX ; aucune erreur.

**Bundle structurel PASS** : [reçu](evidence/release-archive/bundle-verification.json). Artefacts, plist LaunchAgent et liens SQLCipher/Sparkle vérifiés sans `--require-signed`. 92 fichiers réguliers et 9 liens symboliques inventoriés et empreintés. Ce contrôle ne qualifie ni Developer ID, ni notarisation, ni fonctionnement du helper.

**Dix tests RemoteTransferJournal PASS**, zéro échec/skip : `transfer-tests-20260920-235818`, runner 4,092 s. [Résumé](evidence/native-transfer-tests/summary.json), [inventaire](evidence/native-transfer-tests/tests.json). Même candidat Debug et mêmes 1 031 empreintes ; hôte XCTest isolé confirmé. Fixtures dans des répertoires temporaires, journal injecté et commandes générées sans démarrer d’agent ni appeler le serveur. Les lectures de préférences existantes ne constituent pas une isolation complète de tous les defaults de l’application ; aucune écriture de préférences par ces scénarios relevée. Total natif ciblé actuel : **55 tests (45 + 10)**, distinct des **352** du noyau.

Blocage de concurrence levé pour cette exécution. Les refus UI antérieurs restent historiques : aucun message de coordination revendiqué envoyé. Prochaine tâche : qualification des parcours cockpit FR/EN, clavier/accessibilité, arrêt/changement de projet et consentements, puis version/build et candidat signé dans leur périmètre autorisé. Aucune relance de l’app installée, signature, publication ou modification applicative pendant cette reprise.

## Qualification étendue autorisée le 21 septembre — en cours

L’utilisateur a demandé de poursuivre toutes les étapes de préparation. Trois groupes de tests supplémentaires sont préparés : vraie vue Assistant (actions AX et saisie), rendu Plan/UNKNOWN/diff FR/EN, garde de livraison terminal et pairing dégradé. Seams d’injection minimales ; aucun compte ou provider réel. Les reçus de build et archive du 20 septembre restent historiques pour le snapshot antérieur ; les sources applicatives modifiées exigent une nouvelle compilation. Les 153 empreintes du noyau sont encore identiques au reçu 352.

Identité Developer ID Application du Team TDV6D5L785 observée valide hors sandbox, sans export de clé ni signature effectuée. Le feed public recontrôlé retourne encore HTTP 403 : aucun numéro de distribution réservé. Correction du gate de script en cours pour empêcher de continuer sur un feed indisponible ou un build trop ancien. Brouillons de textes dans [RELEASE-COPY-DRAFT.md](RELEASE-COPY-DRAFT.md), sans publication.

Dernier build natif de qualification : `build-20260921-003158` PASS, 14,269 s, 1 036 sources identiques avant/après. Deux erreurs de compilation de fixtures ont été corrigées (visibilité Observable, capture self). Première campagne de 74 : 70 PASS, 4 échecs de fixtures (rafraîchissement UI non attendu et AppState mémoire manquant pour trois tests Assistant). Fixtures corrigées puis recompilées ; seul le binaire du plugin XCTest diffère entre les deux candidats Debug, pas le code de production. Revalidation en cours, interrompue par des xcodebuild tiers ; aucune réussite complète de 83 tests encore revendiquée.

Le contrôle de distribution a maintenant son reçu parent : [12 tests fixtures PASS](evidence/release-gate-20260921/receipt.json), syntaxe Bash valide. Aucun réseau ni signataire pendant ces tests. Les profils Developer ID existants ont été inspectés uniquement sur leurs métadonnées : Team et identifiants cohérents, non expirés ; pas de blob de profil ou clé copié.

## Qualification du 21 septembre — tests ciblés terminés

Build Debug `build-20260921-003158` PASS, 1 036 sources sans dérive. [16 tests UI/CloudKit PASS](evidence/native-cockpit-20260921/ui-cloud-tests-20260921-003925-summary.json), zéro échec/skip, runner 6,122 s : Assistant 3, PlanIntegrationView 4, CloudKitPublisher 9. Hôte XCTest isolé observé ; aucun redémarrage de l’app installée. CloudKit et fournisseur sont simulés.

[83 cas natifs distincts ont un résultat PASS](evidence/native-cockpit-20260921/combined-coverage.json) : 67 cas inchangés de la campagne `002937` et 16 de `003925`. Ce n’est pas une campagne unique entièrement verte. La première campagne conserve ses quatre échecs de fixtures ; les fixtures ont été corrigées et leurs tests ont réussi. [Comparaison des deux bundles](evidence/native-build-20260921/candidate-comparison.json) : seul le plugin XCTest a changé, les octets de production sont identiques. Les interruptions de concurrence restent des résultats non concluants.

Les captures PNG et arbres AX sont conservés dans [ui-attachments](evidence/native-cockpit-20260921/ui-attachments/manifest.json). Inspection visuelle de trois captures : textes UNKNOWN français présents, erreur diff distincte du vide ; des boutons et bulles apparaissent blancs sans leur texte. Ces captures hors écran ne qualifient pas le rendu final : cause de rendu/capture à distinguer par observation d’une fenêtre réelle du candidat isolé. La capture Assistant mélange « Vous » avec le fournisseur de fixture anglais malgré la locale de vue en_US ; localisation complète non qualifiée. Aucune conclusion VoiceOver/clavier complet tirée des appels AX directs.

Douze tests du gate de distribution et sa syntaxe Bash PASS. Feed public HTTP403 : version/build de distribution toujours non réservés. Signature, DMG, notarisation, Sparkle, mise à jour réelle et publication non exécutés. L’archive arm64 du 20 septembre reste historique après les modifications applicatives de qualification. Archive universelle actuelle en attente de créneau ; aucun abandon implicite du support Intel.

## Point de reprise checkpoint-20260921-005103

L’attente d’admission de 360 s s’est terminée sans archive lancée : trois xcodebuild tiers encore observés à 00:50, dont de nouveaux processus. [Reçu d’admission](evidence/universal-archive-admission-20260921.json). Aucun processus tiers arrêté. Il n’y a plus de runner Throttle actif après cette attente.

Dernière preuve nouvelle : 16 tests ciblés PASS ; couverture native cumulée de 83 cas distincts, Debug PASS, sources identiques aux reçus. [Revalidation des empreintes](evidence/source-revalidation-20260921.json). Aucun nouveau changement de code depuis ce build. Les documents et preuves de qualification ont été actualisés ; le manifeste contient 83 fichiers code/tests/harness cumulés.

Prochaine tâche : exécuter `/Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/run-native-universal-archive.py` lorsque `pgrep -x xcodebuild` est réellement vide. Le runner archive arm64+x86_64 sans signer ni lancer l’app, et interrompt uniquement son propre enfant si concurrence. Ensuite vérifier les deux architectures et la structure du bundle. Résultat Intel UNKNOWN tant que cette archive n’a pas terminé. Préserver les reçus arm64 historiques sans les présenter comme ceux du candidat courant.

En parallèle de la future qualification : lever la limite des captures selon [COCKPIT-QA.md](COCKPIT-QA.md), puis version/build depuis un feed autoritatif accessible, signature et distribution dans leurs gates. Pas de relance de l’app installée, commit/push, notarisation ou publication. Sauvegarde persistante `checkpoint-20260921-005103` dans `convergence-recovery-inputs-20260920`, sans écraser les précédentes.

## Reprise du 21 septembre à 06:25 — archive en cours

Aucun xcodebuild actif à l’admission, 2,6 Gio disponibles sur le disque système et 1,5 Tio sur DeveloperStorage. Archive `universal-archive-20260921-062536` lancée par le runner gardé : Release, arm64+x86_64, non signée, pas de lancement de l’app. Les 83 empreintes du manifeste correspondent toujours. Résultat EN COURS, aucune réussite revendiquée avant reçu terminal.

Archive `universal-archive-20260921-062536` INTERROMPUE après 275,052 s : nouveau xcodebuild PID15957, notre seul enfant arrêté par le garde. Aucune erreur de compilation observée avant interruption, 1 036 empreintes stables. [Reçu](evidence/universal-archive-20260921/universal-archive-20260921-062536-receipt.json). Reprise bornée préparée depuis le cache, aucune qualification Intel ou Release complète déduite de cette tentative.

Seconde tentative `universal-archive-20260921-063138` INTERROMPUE après 246,802 s par xcodebuild PID20771. Aucune erreur de compilation observée ; 1 036 empreintes stables. [Reçu](evidence/universal-archive-20260921/universal-archive-20260921-063138-receipt.json). Aucun outil de messagerie inter-sessions découvert ; pas de nouvelle tentative UI après les refus antérieurs. Une dernière attente bornée est en cours.

## Résultat de la reprise 06:25–06:37

**Archive universelle NON QUALIFIÉE.** Trois tentatives interrompues par des xcodebuild tiers : `062536` après 275,052 s, `063138` après 246,802 s, `063710` après 2,083 s. [Synthèse et identités](evidence/universal-archive-20260921/resume-summary.json). Les 1 036 sources sont restées identiques à chaque tentative. Les deux premières avaient progressé sans erreur de compilation observée ; l’interruption ne permet aucune conclusion de réussite, notamment pour Intel. Aucun runner de cette reprise ne reste actif.

Fichiers modifiés pendant cette reprise : documents de progression/validation, ledger de release et preuves. Aucun changement applicatif ni nouvelle exécution de tests ; les reçus antérieurs sont conservés. Aucun restart, signature, envoi externe ou publication.

Prochaine tâche bloquante : suspendre effectivement les nouveaux builds des autres sessions pendant la compilation universelle, puis réutiliser `run-native-universal-archive.py` et le cache existant. Après PASS : contrôler architectures/bundle puis qualifier rendu visuel et distribution. L’absence de mécanisme commun d’exclusion des autres sessions reste le blocage opérationnel, aucun nouveau service ou contournement ajouté.

## Reprise persistante à 06:38

Cache de tests noyau inactif déplacé vers DeveloperStorage avec copie vérifiée de 3 368 entrées et lien conservant le chemin d’accès. Aucun artefact de preuve supprimé ; [reçu](evidence/cache-relocation-20260921.json). Espace système remonté à environ 1,7 Gio.

Archive `064038` interrompue après 64,891 s par PID28336, identifié en lecture seule comme `Rampart_iOS build` dans le dépôt Rampart. Sources stables. La session Rampart a été sélectionnée via UI ; le texte de coordination jusqu’à 07:00 a été inséré et observé, mais Entrée refusée par le contrôle automatique (focus AX scrollbar, collage annoncé en timeout). Aucun envoi revendiqué. Autorisation précise de l’appui sur Entrée demandée, en attente. Une nouvelle attente d’admission automatique est active.

Archive `064446` arrêtée volontairement après 143,982 s : disque système saturé, aucun concurrent. Notre seul xcodebuild PID30510 interrompu ; le statut brut failed/-15 n’est pas une erreur de compilation. [Cause](evidence/universal-archive-20260921/low-disk-stop-064446.json).

Ancien DerivedData `build/workflow-contracts-8a91a20b/build/dd-l10n` inactif déplacé intégralement sur DeveloperStorage avec ditto : 46 482 entrées vérifiées, résultats de tests conservés, chemin original maintenu par symlink. Aucune source de cet ancien worktree modifiée. [Reçu](evidence/legacy-cache-relocation-20260921.json). Espace système observé après déplacement : 5,85 Gio.

L’utilisateur a choisi d’envoyer lui-même le message Rampart ; aucune nouvelle action de saisie UI autorisée/prévue par l’agent. Envoi utilisateur non observé et non revendiqué. Archive en attente automatique d’un créneau de 15 s sans xcodebuild, avec au moins 2 Gio système libres.

Archive `065022` interrompue après 328,157 s par PID38495, identifié comme build du projet/scheme Éclair dans le dépôt Éclair. Sources toujours stables. La compilation avait dépassé SwiftSyntax et progressé vers les modules produit sans erreur observée ; aucune archive complète revendiquée. Coordination manuelle laissée à l’utilisateur ; l’agent n’a pas envoyé le message Rampart.

Archive `065654` interrompue après 62,867 s par PID39780 (même parent Éclair92730). Deuxième demande de coordination manuelle précise, jusqu’à 07:15, en attente de réponse. Admission suivante exige 120 s continus sans xcodebuild et >2 Gio libres, attente bornée à 900 s. Aucun signal envoyé aux processus tiers.

## Archive universelle réussie — 21 septembre, 07:12

**PASS : `universal-archive-20260921-070047`, 679,506 s (11 min 19 s), exit 0, aucun concurrent et 1 036 sources inchangées.** [Reçu terminal](evidence/universal-archive-20260921/universal-archive-20260921-070047-receipt.json). Admission après 120 s sans xcodebuild. Aucun lancement de l’app par l’archive ni signature de distribution.

[Candidat inventorié](evidence/universal-archive-20260921/candidate.json) : source 3.8.0 (226), minimum macOS14, SDK27 ; **10 fichiers Mach-O possèdent tous arm64 et x86_64**, y compris Throttle, widget, ResearchVaultAgent, SQLCipher et Sparkle. Bibliothèque de compatibilité Swift également arm64e. 92 fichiers réguliers et 9 liens symboliques empreintés. [Structure du bundle PASS](evidence/universal-archive-20260921/bundle-verification.json), scripts/verify-research-vault-bundle.sh sans --require-signed. Aucune déduction de fonctionnement sur machine Intel ou macOS14 à partir des architectures binaires.

[Avertissements conservés](evidence/universal-archive-20260921/warnings.txt) : fermeture Swift ambiguë dans ResearchClaimsBoard (deux architectures et lignes de diagnostic dupliquées), quatre extensions C++17 dans MLX, extraction App Intents sans dépendance, catégorie absente du helper ResearchVaultAgent. Aucun changement opportuniste des sources/dépendances pour supprimer ces avertissements.

[Revalidation finale des empreintes](evidence/universal-archive-20260921/final-source-revalidation.json) : 1 036 archive, 153 noyau, 83 fichiers de convergence sans dérive. **Aucun nouveau test exécuté pendant cette reprise** ; reçus précédents 352 noyau, 83 cas natifs distincts sur deux campagnes, 12 tests du gate conservés. git diff --check PASS.

Changements de cette reprise : documentation/preuves et déplacements vérifiés de deux caches ; aucun code applicatif modifié. L’utilisateur choisit d’envoyer lui-même la coordination, puis demande d’attendre la fin d’Éclair : aucune nouvelle saisie UI ni signal à un processus tiers. L’agent n’a pas envoyé le message préparé dans Rampart. Aucun runner de cette reprise encore actif.

Prochaine tâche : qualification visuelle/clavier/VoiceOver du candidat isolé selon COCKPIT-QA, puis version/build à partir d’un feed autoritatif accessible (dernier constat HTTP403), signature/DMG, notarisation et Sparkle dans leurs gates. L’archive universelle ferme le blocage de compilation ; **distribution toujours NO-GO**. Aucun commit, push, installation/restart, signature ou publication.


## Revue réelle et correction de localisation — 21 septembre, 07:44

Le helper de revue visible est limité à l’hôte XCTest isolé, activé explicitement et borné à 180 s. Après `xcodegen generate`, Debug `build-20260921-072929` PASS, 1 037 sources stables. Nouvelle correction produit : quatre suggestions Assistant correctement localisées EN/FR, validées par le nouveau test `testEmptyStateMatchesSelectedLanguage` dans les deux langues.

Quatre exécutions ciblées PASS au total (`071949`, `072423`, `073017`, `073134`), portant sur deux identifiants de test ; pas quatre nouveaux cas distincts. Rendu réel EN clair, redimensionnement, Cmd-Entrée puis Stop observés sur données synthétiques. La capture sombre FR tronquée ne qualifie pas son rendu. Les PNG `cacheDisplay` restent défectueux même pour une fenêtre visible : aucun bug de contraste produit établi à partir d’eux. [QA et limites](COCKPIT-QA.md), [reçus](evidence/visible-ui-20260921/).

UNKNOWN : premier lancement bloqué dans dyld avant bootstrap, arrêté sur son seul hôte vérifié (exit65), puis reprise interrompue par compilation tierce. Ces tentatives ne valident pas l’écran. Archive corrigée `074000` interrompue après 52,674 s par concurrence. La dernière archive réussie `070047` est donc historique et précède la correction de localisation.

Les compilations tierces observées à 07:44 sont des captures UI Clasp ; aucun processus tiers signalé, aucun message envoyé. Attente bornée de 900 s avec admission après 120 s continus sans xcodebuild. **84 fichiers cumulés** dans le manifeste ; 153 empreintes du reçu noyau inchangées, sans relance des 352 tests. NO-GO distribution maintenu ; feed/build de distribution, VoiceOver, parcours réels, signature/notarisation/Sparkle restent ouverts.


## Archive corrigée et régression UI — 21 septembre, 08:04

Après attente de 120 s sans xcodebuild, `universal-archive-20260921-075037` **PASS**, exit0, 619,806 s, aucune concurrence et 1 037 empreintes inchangées. [Candidat et architectures](evidence/universal-archive-20260921-075037/candidate.json), [reçu](evidence/universal-archive-20260921-075037/universal-archive-20260921-075037-receipt.json), [structure du bundle](evidence/universal-archive-20260921-075037/bundle-verification.json). Cette archive comprend la correction produit de localisation. Les dix binaires sont arm64+x86_64 ; 92 fichiers réguliers et neuf symlinks inventoriés. Non signée, non lancée, non installée. Avertissements conservés sans correction opportuniste ; pas de qualification runtime Intel/macOS14 déduite de lipo.

`functional-ui-tests-20260921-080145` : **8 tests PASS**, zéro échec, runner 126,049 s et assertions ~1,13 s. L’hôte a d’abord été échantillonné bloqué dans `dyld/open`, puis a démarré et achevé les tests ; un lecteur indépendant du plist a également repris. Cause du délai NON ÉTABLIE. Ne pas présenter ce délai comme une défaillance d’assertion ni attribuer la reprise à une action non démontrée. [Résumé xcresult](evidence/visible-ui-20260921/functional-ui-tests-20260921-080145-summary.json).


## Point de reprise consolidé — 08:07

- Tests EN `functional-ui-tests-20260921-080145` : **8 PASS**, zéro échec/skip, 126,049 s (délai du chargeur puis assertions ~1,13 s).
- Tests FR `functional-ui-tests-20260921-080433` : **8 PASS**, zéro échec/skip, 28,453 s. [Résumé FR](evidence/visible-ui-20260921/functional-ui-tests-20260921-080433-summary.json). Ces campagnes couvrent les mêmes huit cas ; ne pas les additionner en seize cas distincts.
- Nouvelle tentative visuelle UNKNOWN `080545` : marqueur de revue atteint, puis arrêt automatique par concurrence après 6,177 s. Aucun screenshot observé ni PASS terminal pour cette tentative. Hôte terminé ; aucun processus tiers touché.
- [Revalidation finale](evidence/visible-ui-20260921/final-source-revalidation.json) : 1 037 empreintes archive, 153 noyau et 84 fichiers de convergence sans dérive. Les 352 tests noyau et les campagnes historiques de 83 cas natifs n’ont pas été relancés.

Fichiers de cette tranche : `ProjectAssistantTab.swift`, `Localizable.xcstrings`, les fixtures `ProjectAssistantViewTests.swift`, `PlanIntegrationViewTests.swift`, nouveau `HostedViewReview.swift` ; projet régénéré, documentation/preuves mises à jour. Les modifications héritées sont préservées. Aucun commit/push, signature, installation/restart, migration ou publication.

Prochaine tâche : terminer les observations réelles `unknown-fr`, `diff-en`, `empty-fr` avec `run-native-visual-tests.py` lors d’un créneau libre ; conserver le garde de concurrence. Puis VoiceOver/navigation complète, parcours des consentements/services et upgrade/rollback dans un environnement autorisé. Feed inaccessible au dernier contrôle : aucun nouveau numéro de distribution fixé. L’archive est prête pour la suite des contrôles locaux, pas pour une publication.


## Refactorisations de lint et qualification courante — 08:43

SwiftLint officiel0.63.2 (empreinte du portable vérifiée contre GitHub) : 45 écarts corrigés sans modifier la baseline, puis analyse complète stricte PASS. Extractions Assistant/Plan, scripts et polling ClaudeWebSession, modèles d’intégration et tests ; pas de changement intentionnel des comportements. Scripts JS reconstruits identiques selon vérification textuelle indépendante de la compilation. `xcodegen generate` exécuté après tous les nouveaux fichiers Swift.

Noyau : première tentative `n9d6age7` échoue avant tout cas exécuté, Swift signale `_DarwinFoundation1` défini par le chemin du cache déplacé et son ancien lien. Aucun cache supprimé. Reprise `y1rcopli` dans un cache externe neuf : **352 cas PASS, 120,028 s**, 313 XCTest +39 SwiftTesting, zéro erreur, sources empreintées. [Reçu](evidence/core-refactor-20260921/throttle-core-evidence-y1rcopli/receipt.json). Le harness regroupe désormais les méthodes de `+Integration` dans leur vraie suite ; aucun test déplacé n’est omis. Six tests Python du validateur PASS.

Gate appcast : onze tests PASS. Staging : vingt tests PASS, dont CryptoKit réel et refus de feed invalide/égal/futur avant création de stage ; pas de clé privée ni réseau. [Reçu](evidence/distribution-preflight-20260921/stage-tests-final-receipt.json). `PRIVACY.md` et brouillon FR/EN actualisés depuis le code, sans inventer la rétention des services déployés.

Build `084023` interrompu après42,701s par concurrent3092 (parent92730), sans erreur de compilation observée ; 1046 sources stables. Seul notre enfant arrêté. [Reçu](evidence/native-refactor-20260921/build-20260921-084023-receipt.json). Attente bornée de900s, admission après120s libres et >2Gio système. Checkpoint vérifié `checkpoint-20260921-084220`, 440 fichiers sauvegardés.


Debug `build-20260921-084810` PASS, 40,631s, aucune concurrence, 1046 sources stables. 115 fichiers du bundle de test épinglés pour les runners suivants. [Reçu](evidence/native-refactor-20260921/build-20260921-084810-receipt.json). La campagne native attend84 cas distincts, dont le nouveau test d’accueil localisé ; la précédente couverture83 ne comprenait pas ce cas. Tentative `qualified-tests-20260921-084930` interrompue à2,122s par le concurrent7783 ; aucun cas terminé revendiqué, lancement effectif du host non établi. Nouvelle admission bornée en cours. Quatre tests supplémentaires des assertions CI de release PASS.


## Arrêt de l’attente bornée — 09:06

[Admission native](evidence/native-refactor-20260921/test-admission.json) : aucun créneau de120s libre pendant900s ; tests84 NON EXÉCUTÉS dans cette reprise. Notre unique tentative précédente `084930` avait été interrompue après2,122s. Aucun runner de compilation ou de test de cette session ne reste actif ; aucun processus tiers arrêté. Les résultats352 noyau/Debug/lint/41 tests Python restent distincts des tests natifs non requalifiés.

Dernier ajustement documentaire : `PRIVACY.md` ne présente plus toutes les fonctions réseau comme opt-in, puisque le projet active les contrôles Sparkle automatiques. [Delta documentaire explicite](evidence/native-refactor-20260921/documentation-only-delta.json) : aucune autre entrée source du build modifiée,115 fichiers de son bundle inchangés ; les futurs runners utilisent ce snapshot compatible tout en gardant le reçu original. Aucun code applicatif modifié après compilation.

Prochaine commande quand aucun xcodebuild tiers n’est actif : `python3 -B /Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/run-native-qualified-tests.py en`. Puis exporter/vérifier les84 cas avec `/Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/export-qualified-evidence.py <label>`, lancer `run-native-functional-ui-tests.py fr` (8cas), enfin l’archive universelle gardée. Les helpers d’export, d’inventaire d’archive et de checkpoint sont conservés dans le dossier de validation persistant, avec les runners ; la reprise ne dépend pas de /private/tmp.

Toujours manquants : qualification native actuelle, archive universelle renouvelée, signature/helper/entitlements, DMG/notarisation/Sparkle, mise à jour et services réels, contrôle vocal et parcours clavier complet. Aucun commit, push, installation/restart, signature ou publication exécuté.


## Reprise et correction de l’identité de test — 09:25

L’autorisation utilisateur «go for it» poursuit la préparation locale. L’interprétation initiale incluant la signature a ensuite été refusée par le contrôle automatique à09:31 : un accord explicite de signature reste requis. Aucun GO de notarisation ni upload public n’est acquis. Identité Developer ID valide recontrôlée en lecture seule ; feed relu à09:14:51, maximum223 et candidat226 admissible, SHA256 `72bbb708b43e651bf24eaa7d3f67a1e44b229ac63dd5df59c3345b789ca4b7b1`. Aucun binaire envoyé à Apple.

La campagne native84 `091041` est interrompue à42,674s par concurrence. Sept suites suivantes se terminent avec67 cas PASS sur l’ancien hôte ; leurs reçus/xcresult sont conservés. L’utilisateur signale ensuite des demandes répétées «Throttle souhaite accéder aux fichiers d’un volume amovible». Arrêt immédiat de notre batch22174, alors en attente : aucun descendant actif ni app installée arrêté.

Les diagnostics TCC montrent un conflit réel entre la règle Developer ID de `com.lorislab.throttle` installé et le cdhash de l’hôte ad hoc portant le même identifiant. Les demandes alternaient entre l’app hôte sur DeveloperStorage et les outils attribués à l’app installée. [Diagnostic et correction](evidence/native-refactor-20260921/removable-volume-diagnosis.json). Aucun changement de la base TCC, aucune réinitialisation ou extension de permissions.

Nouvel hôte interne `com.lorislab.throttle.test-host`, nom affiché «Throttle Test Host». Copie exacte vérifiée avant changement exclusif du plist d’identité, signature ad hoc et signature du binaire hôte ; pas de modification de son code source ni de l’app installée. Fichiers temporaires, produit et résultats sur disque interne. Métadonnées de couverture source externe retirées du xctestrun : cette campagne vérifie les cas, pas un pourcentage de couverture de lignes. [Préparation](evidence/native-refactor-20260921/isolated-host-preparation.json).

Premier contrôle `isolated-suite-CockpitSpendViewTests-20260921-092247` :4 cas PASS dans le résultat terminal, exit0 ; aucun prompt ni conflit TCC Throttle entre09:22:45 et09:23:00. Le wrapper a signalé à tort une interruption après la fin effective, car il testait les concurrents après son sommeil sans relire l’exit de son enfant. Garde corrigé dans les runners suivants ; reçu original conservé avec interprétation explicite.

Les neuf anciens lanceurs de tests partageant l’identité de production refusent désormais l’exécution ; code original préservé en `.pre-isolation-20260921.txt`. Utiliser `run-isolated-suite.py`, `run-isolated-functional-ui-tests.py` et `run-isolated-suite-batch.py` dans le dossier de validation persistant. Le premier essai de copie sandbox a échoué sur les métadonnées de libswift ; la copie complète suivante a été vérifiée avant lancement.


## Qualification native terminée et signature bloquée — 09:31

**84 cas distincts PASS**, neuf suites complètes sur les mêmes1046 sources compatibles avec le build ; [agrégat contrôlé](evidence/native-refactor-20260921/isolated-combined-coverage.json). Ce n’est pas une campagne monolithique unique. **8 contrôles FR PASS**, `isolated-functional-ui-tests-20260921-092951`,4,110s, zéro échec/skip. [Couverture FR](evidence/native-refactor-20260921/isolated-functional-ui-tests-20260921-092951-coverage.json). Les8 sont une seconde exécution de cas déjà inclus dans84, pas8 cas distincts supplémentaires.

[Observation TCC](evidence/native-refactor-20260921/tcc-post-isolation.json) : zéro prompt/conflit Throttle observé depuis09:22:45 jusqu’à09:29:10. Services de production désactivés : marqueur de bootstrap observé dans les logs du nouvel hôte. Aucun contrôle vocal supplémentaire, VoiceOver laissé OFF.

Le contrôle automatique refuse l’archive signée au motif que «go for it» n’autorise pas explicitement l’usage de la clé privée Developer ID. Aucune signature exécutée ; l’export FR contenu dans le même appel refusé a ensuite été exécuté seul. [Blocage d’autorité](evidence/native-refactor-20260921/signing-approval-block.json). Le runner signé est désormais bloqué par défaut avec un argument d’approbation explicite ; ne pas l’utiliser sans accord utilisateur précis. Une archive universelle **non signée**, CODE_SIGNING_ALLOWED=NO, est lancée séparément comme préparation sûre, pas comme contournement de la signature.


Contrôle complémentaire TCC jusqu’à09:38:50 : les deux requêtes RemovableVolumes observées sont déjà `Allowed (User Consent)`, `DB Action:None`, aucun échec de correspondance de signature. Le filtre large trouve aussi des diagnostics `promptType` et des politiques d’autres services ; ils ne constituent pas des dialogues affichés. [Interprétation](evidence/native-refactor-20260921/tcc-post-isolation-followup.json). À09:39,96 empreintes de convergence et155 du reçu noyau correspondent toujours ; `git diff --check` PASS.


## Archive actuelle terminée —09:45

`universal-archive-20260921-093142` **PASS**, exit0,732,876s, aucun concurrent,1046 sources inchangées. [Reçu](evidence/universal-archive-20260921-093142/universal-archive-20260921-093142-receipt.json), [candidat](evidence/universal-archive-20260921-093142/candidate.json), [structure](evidence/universal-archive-20260921-093142/bundle-verification.json). Les dix binaires Mach-O incluent arm64+x86_64 ;92 fichiers réguliers et9 liens inventoriés. Version3.8.0(226), minimum déclaré macOS14, SDK27. Avertissements existants conservés (closure ResearchClaimsBoard, Metal/C++17, métadonnées helper). Aucune signature de distribution, aucun lancement/installation ni appel de notarisation. L’archive ne qualifie pas le runtime Intel/macOS14.

Prochaine étape bloquée : accord explicite pour signer localement le même candidat avec Developer ID Application Christine Martin(TDV6D5L785) et préparer un DMG neuf, timestamp Apple compris. Le contrôle automatique a refusé l’accès à la clé privée avant toute exécution ; ne pas passer `--approved-local-signing` sans cet accord. Notarisation et publication nécessitent ensuite leurs autorisations distinctes. Le futur runner doit recontrôler les sources, l’espace disque et l’exclusivité xcodebuild. Aucune nouvelle modification applicative dans cette reprise ; correctif de harness TCC, documentation et preuves seulement.


## Finalisation demandée — 21 septembre

Les revues finales sont dans `audit-output/release-final-{network,distribution,uxqa}-20260921.md`. Les corrections sont limitées aux constats démontrés :

- Le journal de licence n’inclut plus l’identifiant matériel. La sauvegarde utilise le `KeychainStore` existant, sans supprimer l’ancienne valeur avant une écriture qui pourrait échouer.
- Un journal de tâche corrompu ou contenant un événement inconnu est refusé avant toute commande Git de rebase/intégration. Ce contrôle ne rend pas atomiques les effets Git et l’écriture du journal face à une modification concurrente.
- Le publieur n’imprime plus les réponses contenant potentiellement des credentials, archive via arguments structurés, borne les requêtes et réconcilie les offsets d’upload. Dix tests Node offline PASS.
- Les déclarations sur les optimisations IA indiquent désormais la destination choisie, distinctement de l’application locale du résultat.

**358 cas noyau PASS**, 319 XCTest +39 Swift Testing,94,728s : [reçu](evidence/final-release-20260921/core-358/receipt.json). Six nouveaux cas couvrent les journaux invalides, le format ancien réouvert avec intention UNKNOWN et le renouvellement de licence refusé sans perte. SwiftLint0.63.2 strict global PASS,854 fichiers. Debug `build-20260921-100452` PASS,36,480s,1047 sources stables ; nouvelle campagne native terminée :84 cas en neuf suites, puis8 répétitions françaises. [Couverture](evidence/final-release-20260921/combined-native-coverage.json). Une tentative PlanIntegrationFlow a été interrompue par concurrence ; la reprise a terminé PASS.

Clavier observé sur l’hôte084810 : Cmd–Entrée envoie puis arrête la réponse synthétique, avec focus dans l’éditeur conservé. La fixture termine exit0 et un cas PASS, mais son wrapper signale à juste titre la dérive des sources pendant l’exécution. Observation conservée pour ce précédent candidat, pas qualification exacte du candidat suivant. [Preuve](evidence/final-release-20260921/keyboard-observation.json). VoiceOver non utilisé.

La comparaison avec le commit de release3.7.2(223), `d734b864ab83db050f4c55de2f94556e66308369`, montre que PlanStore, Migrations et DatabaseManager sont identiques. De nouveaux types d’événements rendent en revanche un downgrade aveugle dangereux. La stratégie proposée est un correctif de version supérieure préservant les journaux ; aucune restauration ni migration de données utilisateur effectuée. L’identité du DMG public avec ce commit n’est pas démontrée.

Le backend de licence a été retrouvé et inspecté en lecture seule dans `/Users/kevinnadjarian/GitHub/throttle-license-worker`. Son code local conserve les données de licence sans TTL ; désactiver un Mac ne supprime pas le dossier client. La révision déployée et les rétentions des services tiers ne sont pas prouvées par cette inspection.

La route Claude web reste une décision produit en attente. Les sources officielles Anthropic demandent un accord préalable pour offrir connexion/quotas claude.ai dans un produit tiers, même avec Agent SDK. Recommandation : route API existante et modèles locaux ; aucune substitution payante silencieuse. L’utilisateur a demandé ce qu’était le choix SOTA, la recommandation lui a été expliquée ; aucun changement de cette route sans sa décision.

La préparation locale et les corrections continuent ; signature Developer ID, DMG, notarisation et publication n’ont pas été exécutés. La nouvelle source applicative impose une nouvelle archive. Les preuves précédentes restent conservées et datées.

## Préparation poursuivie en attendant Anthropic — 21 septembre,10:53

Support humain confirmé par le message fourni par l'utilisateur, conversation `215476024504261`; aucune réponse d'approbation ni changement de route. Travail réalisé dans le même worktree, sans code applicatif modifié.

- Deux fixtures du candidat100452 relancées sur l'hôte interne : `isolated-visual-tests-20260921-103413` et `103820`, chacune1 cas Passed, aucun échec/skip ; ce sont des répétitions de la couverture84. Send/Stop Cmd–Entrée observés en FR, focus conservé. Tab/Shift-Tab/Ctrl-Tab ne quittent pas l'éditeur, Tab/Option-Tab n'atteignent pas Retry. Diagnostic global en lecture seule `AppleKeyboardUIMode=0`; ni réglage système ni VoiceOver changé. Pas de réussite clavier complète revendiquée.
- Quatre scénarios PASS avec les vrais lecteurs223 et courant : format historique, nouveaux champs optionnels, événement inconnu terminal et intermédiaire. Les journaux restent byte-identiques lors des lectures/refus ; retour courant reconstruit l'intention UNKNOWN malgré le cache dérivé ancien, sans garder le check vert. Harness reproductible `build/convergence-validation-20260920/two-reader-20260921`, compilation SwiftPM isolée11,84s ; sources manifestées. Pas de base de production ni de Git historique manipulés.
- Brouillon confidentialité FR/EN, patch local de trois métadonnées et du paragraphe de confiance du site, procédure de récupération et vérifications post-publication préparés. [Liens](RELEASE-COPY-DRAFT.md#compléments-préparés-à-1046--non-publiés). Aucun texte publié.
- Relectures publiques : santé licence HTTP200 `ok`, page/privacité HTTP200, appcast maximum223 inchangé. Lecture Cloudflare des déploiements exit1 sans réponse exploitable ; arrêt après cet échec. Aucun secret/client consulté ; révision déployée et politique de conservation non prouvées.
- Signature locale refusée avant exécution par le contrôle automatique, faute d'accord exact pour la clé Developer ID. Identité publique recontrôlée disponible, aucune signature réalisée. Archive unsigned104203 interrompue par concurrence à147,781s ; attente120s libres puis104730 interrompue à202,786s. Aucun processus tiers arrêté. Pas de nouveau candidat universel validé.

[Preuves et limites](evidence/release-continuation-20260921/), [ledger de release](../../audit-output/release-3.8.0.md). Revalidation1047 sources Debug sans changement et diff-check PASS. Le script Python de gate a créé un `.pyc` qui apparaît comme1048e entrée dans la seconde archive ; ce seul fichier généré a été retiré, sans nettoyage de caches utilisateurs. Pas de nouveau fichier Swift du projet : pas de génération Xcode supplémentaire nécessaire.

Prochaine tâche : signature locale explicitement autorisée et archive sur un créneau exclusif ; préparer ensuite le DMG exact avant toute demande d'envoi Apple. Les faits opérateur de confidentialité et le contrôle clavier avec navigation activée restent nécessaires ; la demande Anthropic suit son cours. Aucun runner archive/test de cette reprise laissé actif après les deux interruptions.

## Reprise du21septembre — consolidation, clavier et signature locale

[Matrice courante](RELEASE-GATE-MATRIX.md) créée ; brouillon public v2 et notes HTML FR/EN ajoutés. Confidentialité : proposition opérationnelle sourcée CNIL, entité/contact et pratiques effectives toujours à établir. Anthropic inchangé/en attente.

Accord précis reçu pour Developer ID3.8.0(226),TeamTDV6D5L785,timestamp Apple,DMG local et Navigation clavier temporaire/restaurée. Deux archives signées interrompues par concurrence, aucune erreur de compilation observée ni réussite déduite. Aucun upload/restart.

Deux répétitions d'un test natif PASS ; Retry clavier non qualifié. Témoin AppKit/SwiftUI positif, fixture HostedViewReview corrigée pour activation conforme aux fenêtres produit et diagnostic. Swift6 typecheck/lint ciblé PASS ; nouveau build bloqué par disque1,7Gio. Déplacement de deux caches supplémentaires refusé avant exécution par contrôle automatique ; accord exact demandé. Sources produit inchangées, une fixture modifiée depuis100452. Reçus dans evidence/release-finalization-20260921.

Prochaine tâche : espace sûr, build/vérification de fixture, clavier puis archive signée/DMG en créneau exclusif. Autorisations locales reçues persistantes ; notary/publication attendent artefacts/gates et accords distincts.

Contrôle final : SwiftLint global strict PASS sur854fichiers, baseline inchangée. Une copie documentaire Package.swift a été renommée .swift.txt sans changer ses octets pour ne pas être analysée comme source applicative ; reçu du premier échec conservé. git diff --check PASS. Navigation clavier OFF et panneau Général restaurés. Aucun runner détenu encore actif. Déplacement des deux caches supplémentaires toujours en attente de réponse précise, non exécuté.

## État courant après déplacement autorisé — 21 septembre,12:03

**Déplacement terminé**, aucun accord supplémentaire à demander pour ces deux caches. ResearchVaultKit :9331 entrées ; ThrottleShared :5113 entrées. Contrôles lsof, empreintes/modes/liens avant/après, copie externe et ancien chemin par symlink, puis retrait des seuls doublons validés. [Reçus Vault](evidence/release-finalization-20260921/workflow-vault-cache-relocation.json) et [Shared](evidence/release-finalization-20260921/workflow-shared-cache-relocation.json). Environ1Gio libéré ; l'espace global a ensuite baissé jusqu'à994Mo à12:00. Ne pas attribuer cette baisse à une application précise sans preuve.

Build114759 PASS32,507s, puis115329 PASS16,328s,1047 sources sans dérive. Seuls HostedViewReview et PlanIntegrationViewTests diffèrent de100452 ; aucune source produit modifiée. Lint global strict PASS854fichiers, règles/baseline inchangées.

Le test diff EN114959 termine PASS(1cas,0échec/skip),126,056s. Son diagnostic confirme active=true,key=true,keyboard=true mais responder=NSWindow après Tab. L'activation seule ne résout donc pas le focus. La seconde fixture reprend le montage NSHostingController et les styles initiaux du vrai cockpit ; un message synthétique distinct rendra l'effet de Retry observable. Elle compile dans115329 mais son runtime n'est PAS exécuté : toutes les préparations de copie/clone suivantes se sont arrêtées à leurs assertions préalables, avant création d'un nouvel hôte, faute de réserve disque.

L'hôte114859 reste préservé ; il n'est pas celui de la dernière fixture. Navigation clavier OFF restaurée. Aucun xcodebuild détenu encore actif, aucun restart installé, aucune archive signée terminée ni DMG créé. L'accord de signature locale persiste.

**Prochaine tâche** : disposer d'un espace libre stable (marge opérationnelle recommandée5Gio, gate de build2Gio), préparer le module de test115329 dans un hôte interne distinct, tester le clavier puis archive/export/DMG sur un créneau exclusif. Reprendre les gates fournisseur/confidentialité et les accords d'envoi seulement après artefact qualifié.

## Reprise 21 septembre, 12:14

Les deux déplacements autorisés sont terminés (14 444 entrées vérifiées). Test clavier120437 PASS : Tab → Retry, Espace → rafraîchissement, Tab → nouveau Retry ; navigation système OFF restaurée. Les8 tests120630 ont révélé2 échecs de capture UNKNOWN (assertions fonctionnelles passent). Correctif de dimensionnement compilé121114 PASS, lint ciblé strict PASS ; runtime corrigé encore non exécuté faute de réserve pour le nouvel hôte. Archive signée locale en cours sous garde-fous, aucun résultat acquis. Voir la [matrice consolidée](RELEASE-GATE-MATRIX.md) pour les gates courants. Aucun upload ni restart installé.

## Arrêt borné —21 septembre,12:22

Archive121313 interrompue par concurrence après470,634s,1047 sources stables ; pas de PASS. Environ1,3Go libres, admission2Gio non satisfaite. Cache relocation terminée ; Retry clavier PASS limité ; correctif de capture compile, les8 tests corrigés restent NON EXÉCUTÉS. Aucun processus détenu volontairement laissé en arrière-plan. Voir [état courant et reprise](RELEASE-GATE-MATRIX.md).

## Revalidation de fixture —21 septembre,12:42

Build123340 PASS16,369s,1047 sources stables. sizingOptions seul ne suffisait pas (123001 :6/8 PASS) ; conteneur VStack et surface420x420 explicites corrigent les deux captures UNKNOWN, assertions conservées. Campagnes123427EN et123449FR :8/8 PASS chacune,0échec/skip, résultats xcresult extraits. Cas clavier123619 :1/1 PASS, Tab/Espace/Tab observés via CUA ; Navigation clavier OFF restaurée. Ces17 exécutions correspondent à8 cas distincts. Aucun changement produit ni restart installé.

Les anciens artefacts cockpit-maintenance du7septembre ont été préservés sur DeveloperStorage avec empreintes/modes/liens/attributs vérifiés, lien à l’ancien chemin, retrait du seul doublon. Contact de confidentialité existant retrouvé :support@lorislab.fr sous LorisLabs/LorisLabs Team ; identité juridique toujours non précisée dans le texte public. [Matrice courante](RELEASE-GATE-MATRIX.md).

Les deux caches .build du checkout principal sont désormais préservés sur DeveloperStorage :Vault25 678entrées /2 684 621 667octets,Shared4 316entrées /267 262 503octets. SHA-256/modes/liens identiques ; tous les attributs source conservés,226 attributs com.apple.provenance supplémentaires uniquement sur la copie Vault, explicitement consignés. Aucun attribut retiré. Anciennes adresses par symlink, seuls doublons vérifiés retirés, inactivité contrôlée avant/après. Les caches de compilateur peuvent contenir des chemins absolus : toute réutilisation future doit être qualifiée ; le runner release utilise son scratch externe distinct. [Reçus](evidence/release-finalization-20260921/disk-preservation-summary.json).

## Archive signée réussie —21 septembre,12:54

Archive124258 PASS,exit0,652,471s,aucune interruption concurrente,1047 sources stables et identiques au build UI testé123340. App non lancée, aucun upload. Export Developer ID vers dossier neuf `release-3.8.0-226-20260921-125404` en cours ; qualification des entitlements/signatures et DMG encore à exécuter.

## Paquet local terminé —21 septembre,12:59

Archive124258 PASS652,471s ; export125404 PASS49,037s ; signatures/entitlements/profils/architectures app/widget/helper et contrôle Sparkle PASS. Commande lipo -verify_arch refusée par l’outil local :diagnostics conservés ; vérification stricte de l’ensemble renvoyé par -archs égale {arm64,x86_64}. Contrôle statique smoke-test6/6 PASS, sans lancer l’app.

DMG signé avec timestamp Apple :`/Volumes/DeveloperStorage/BuildScratch/throttle-convergence-20260920/release-3.8.0-226-20260921-125404/Throttle-3.8.0.dmg`,34 964 760octets,SHA-256 `3fc63cc76f577a614ed22e8ff3dd6079e452d4e9fadddcc36f91ae1fbac2a261`. Copie et image montée en lecture seule identiques à l’export ; montage démonté, app exportée inchangée. Aucun upload ni installation/restart.

Accord précis demandé pour la notarisation de cet artefact, encore NON EXÉCUTÉE. Le skill publish-apple impose cet accord avant premier envoi et un accord distinct avant publication. G07 Anthropic et G08 identité opérateur/rétention/effacement restent ouverts ; contact historique support@lorislab.fr retrouvé et repris dans le brouillon. [État courant](RELEASE-GATE-MATRIX.md).

## Notarisation et staging local terminés —21 septembre,13:09

Accord utilisateur précis reçu. Une soumission Apple `eb6ffb07-5ee3-4a66-9713-a63acd7df982`,Accepted ; log rattache le SHA-256 envoyé au candidat. Staple et validation PASS, signature DMG valide, Gatekeeper Notarized Developer ID. DMG final34 967 080octets,SHA-256 `126c18b30dc187c71bdede756e6446ba9245dc002278bb601b64563efc6d1878`. Aucun upload public, installation ou app launch.

Signature Sparkle locale et vérification CryptoKit contre SUPublicEDKey de l’export PASS avant/après copie. Feed relu:max223<226 ; stage neuf créé dans le dossier125404. Texte visible complet de la page relu,32 formulations et3 descriptions corrigées,liens/scripts/styles/prix conservés. Revue visuelle finale et parcours réel de mise à jour NON EXÉCUTÉS. Le stage reste non approuvé pour publication :Anthropic, identité opérateur et conservation/effacement, politique/conditions Throttle, puis accord public précis et fraîcheur des artefacts. Anciennes demandes d’accord notary de ce journal sont clôturées par le reçu ; ne pas renvoyer le DMG.

Prévisualisation locale du stage tentée via serveur127.0.0.1 limité à la page et180s. Safari présente sa fenêtre privée verrouillée ; l’outil UI refuse com.apple.LocalAuthenticationRemoteService lors de la tentative de nouvelle fenêtre normale. Aucun mot de passe saisi, aucune fenêtre privée déverrouillée, aucun contournement. Revue visuelle finale NON VÉRIFIÉE ; preuve dans website-visual-block.json.

## Présentation opérateur conservée — 21 septembre 2026

L'utilisateur demande de rester comme auparavant pour le nom légal. Décision consignée : conserver LorisLabs / LorisLabs Team et support@lorislab.fr dans la préparation, sans ajouter son nom personnel ni inventer une société. Présentation ajoutée au brouillon FR/EN et G08 actualisé. La clarification juridique est différée, sans validation de conformité ; ne pas répéter cette question pour continuer la préparation. Rétention/effacement/déploiement, Anthropic et validations finales restent distincts. Aucun changement de code, de paquet notarisé, de site public ou de service externe. Aucun build/test applicatif nécessaire pour cette modification documentaire.

## Bilan des parcours et préparation Mac mini — 21 septembre 2026

[Bilan vérifié et plan](RELEASE-FLOWS-MAC-MINI-20260921.md) ajoutés sur demande utilisateur. Matériel annoncé : M5 Pro,64Go,1To, mercredi23septembre. Deux revues bornées et lectures primaires Apple/Git/Ollama/Claude ; aucun build/test applicatif ni action distante. DMG final34967080octets et SHA126c18b3…d1878 revérifiés identiques au reçu notarisé.

Deux omissions produit : O01 chemin optimizer/settings.local vers provider choisi sans filtrage identifié (aucune fuite observée), O02 gains chiffrés non démontrés/préférence thinking modifiée en proposition. G15 ajouté, pas de modification applicative. Le backend de transfert/nouvelle session impose Linux/systemd ; Mac→Mac natif non prêt malgré README Linux/macOS. Plan SSH natif/pilote/migration vérifiée puis adaptation bornée séparé de la release.

Inventaire initial135 entrées Git immédiates ;15 worktrees enregistrés Throttle dont2 prunable,aucun nettoyage. Super-Orchestrateur36 entrées suivies modifiées,SuperGateway4 ; fichiers non suivis non inventoriés à ce stade. Migration complète non effectuée et aucun secret collecté. Ne pas cloner seulement GitHub ou copier uniquement son dossier en supposant préserver tout le travail. Publication toujours NO-GO ; prochaines corrections bornées O01/O02 puis gates fournisseur/confidentialité et parcours final autorisé.

## Correctifs optimiseur — candidat source227, 21 septembre

[Correctifs, preuves et reprise](OPTIMIZER-HARDENING-20260921.md). O01/O02 corrigés : settings sans modèle, IA instructions locale seulement, préférences préservées, ratios inventés retirés ;11cas nouveaux. Noyau369PASS (330XCTest+39SwiftTesting),98,058s final ;lint0.63.2 global strict PASS ;XcodeGen et syntaxe Swift PASS. Source227 non compilé nativement : admission refusée avant xcodebuild à environ831Mo libres (minimum2Gio). UI optimiseur, archive/export/signature227 NON EXÉCUTÉS. Paquet226 notarisé conservé inchangé, ne couvre pas ces corrections. Un ancien hôte092038 préservé/vérifié sur DeveloperStorage ; arrêt avant l'hôte100617 utilisé par d'autres Codex, aucun processus arrêté. Aucune installation/restart/publication. Prochaine tâche : espace suffisant puis build227, nouvel hôte de tests et parcours optimiseur FR/EN.


## Reprise Claude → Codex — 22 septembre

[Reprise227 et preuves fraîches](CONTINUATION-227-20260922.md). App3.8.0(227) déjà installée et exécutée depuis /Applications ; signature stricte/Gatekeeper PASS, smoke6/6 PASS. Noyau369PASS en123,332s,0/0,aucune dérive source depuis le reçu optimiseur. DeveloperStorage absent : DMG227/reçus externes non relus. UI cockpit/projet FR observée, optimiseur non atteint de façon vérifiable avec changements de fenêtre concurrents ; gate conservé ouvert. Aucun changement produit, restart, installation, commit, upload ou publication. Prochaine tâche : contrôle Optimizer sur fenêtre disponible puis fixture isolée et rattachement des reçus externes.
