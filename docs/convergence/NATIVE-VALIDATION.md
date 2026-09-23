# Qualification native — diagnostic isolé du 20 septembre 2026

> Journal historique conservé. Pour le candidat courant après refactorisation, consulter [PROGRESS](PROGRESS.md) et [le ledger de release](../../audit-output/release-3.8.0.md) ; ne pas extrapoler les anciens PASS aux sources modifiées.

## Environnement et exclusions

Xcode installé 27.0 / 27A266a, cible source macOS 14, Swift 6. Le build est exécuté depuis le worktree persistant, sur `/Volumes/DeveloperStorage/BuildScratch/throttle-convergence-20260920`. Compilation Debug arm64 non signée, action `build-for-testing` : aucune exécution de tests hébergés, aucun lancement/restart de Throttle.

Le script diagnostic conservé dans `/Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/run-native-build.py` refuse un xcodebuild déjà présent. Il surveille ensuite la présence d'un autre xcodebuild et interrompt uniquement celui qu'il a lancé. Cela ne constitue pas un verrou universel que toutes les autres sessions respecteraient. Deux tâches de build demandées (`-jobs 2`), sans garantie de limiter à deux les threads internes du compilateur Swift. Source manifest avant/après, commande, log et reçu séparés par tentative. Un résultat avec dérive de sources n'est pas PASS.

Le disque interne n'avait qu'environ 10 Go disponibles; volume externe environ 1,5 To. Aucun nettoyage d'autres caches, aucun processus tiers interrompu. SwiftPM du harness et xcodebuild sont exécutés séquentiellement pour limiter la contention.

## Préparation et erreurs réellement rencontrées

1. `build` : validation plug-in MLX CudaBuild requise, avant compilation. Code épinglé inspecté; sur macOS `isCudaEnabled` retourne false avant création de commandes.
2. `build-for-testing` : approbation macro MLXHuggingFaceMacros requise. Fichier source épinglé lu intégralement : macros SwiftSyntax de génération d'adaptateurs, pas d'appel réseau lors de leur expansion.
3. Après flags locaux `-skipPackagePluginValidation -skipMacroValidation`, caches binaires absents au chemin référencé. La copie de SourcePackages contenait des chemins absolus vers un ancien DerivedData. Les xcframeworks Sparkle/SQLCipher existaient dans la copie; seuls les deux champs `artifacts.path` du workspace-state généré isolé ont été réparés. Le JSON antérieur est conservé. Aucun changement de Package.resolved, versions ou checksum déclaré.
4. Compilation des dépendances et de la cible native : erreur `RemoteTransferGit.swift` utilise `ShellResult.ok`, renommé lors de la tranche processus. Corrigé en `succeeded && exitObserved`; les trois tests synthétiques RemoteTransferGit sont ajoutés au harness. La suite RemoteTransferJournal couplée au cockpit reste dans la cible native, pas de stubs trompeurs pour la faire passer dans le harness.

## Identité et limite de supply chain

SourcePackages est une copie isolée d'un cache local préexistant, pas un nouvel audit indépendant des dépendances. Les versions résolues sont épinglées; aucune mise à jour automatique. Les flags de validation ne changent pas la politique persistante de Xcode. La signature et la provenance des binaires embarqués devront encore être qualifiées dans une archive de release : ces lectures ne remplacent pas la vérification d'une distribution.

## Résultat terminal

Voir [PROGRESS.md](PROGRESS.md) et les reçus désignés. Tout résultat encore en cours ou interrompu est inconclusif. Aucun test GUI, VoiceOver, iCloud ou API fournisseur réel n'est déduit de cette compilation.

## Concurrence observée

Après correction de compilation, `build-20260920-222711`, `build-20260920-223016` et `build-20260920-223346` ont été interrompus par notre garde après respectivement 60,766 s, 8,152 s et 40,655 s. Les reçus et logs sont conservés sous le volume externe ci-dessus. Aucune de ces tentatives n'est PASS. Le dernier reçu a 1 027 fichiers sans dérive ; il ne représente pas un build terminé.

Lecture ciblée des processus : campagne `xcodebuild test-without-building` de captures iOS Clasp, donc bien un autre xcodebuild réel, pas un diagnostic imbriqué de notre compilation. Aucun signal envoyé à ces processus. L'outil UI de coordination a expiré deux fois, sans message envoyé.

## Compilation finale réussie

`build-20260920-225829` : **PASS**, exit0, 58,935 s après 91 s d’attente d’un créneau. 1 031 sources sans dérive, aucun concurrent détecté. [Reçu et commande](evidence/native-build/build-20260920-225829-receipt.json), [identité du candidat](evidence/native-build/candidate.json). Debug arm64, aucune signature de distribution ni lancement par build-for-testing.

L’hôte XCTest déjà présent a ensuite été audité : détection XCTest, DB mémoire, pas de services de production ni singleton, retour anticipé de termination. Quatre suites ciblées préparées pour cet hôte, sans mode demo, vrais credentials ou API : PlanIntegrationFlow, CockpitSpendView, PromptRefinerService et RemoteSessionsCredential. Leur exécution doit avoir son propre reçu, distinct de la compilation.

## Candidat final et suites natives

Après correction du texte de vérification EN/FR et d’un avertissement d’isolation Swift : build `build-20260920-230917` **PASS**, 26,418 s, aucun warning, 1 031 empreintes sources sans dérive. Puis `tests-20260920-231047` : **45 PASS, zéro échec/skip**, 88,826 s. Log : `Isolated host detected: skipping production background services`. La production installée n’a pas été redémarrée.

Le lanceur de tests vérifie avant lancement l’égalité des sources avec le build et les 115 fichiers réguliers du candidat. [Inventaire candidat](evidence/native-build/candidate-files.json), [résumé natif](evidence/native-tests-231047/summary.json). Une copie du xcresult a été utilisée pour son extraction ; xcresulttool crée un cache TestReport, ce qui a nécessité l’environnement diagnostique autorisé après deux refus filesystem. Ces refus d’extraction ne sont pas des échecs de tests.

## Archive Release non signée — tentative interrompue

`archive-20260920-231325` : arrêt par garde de concurrence après 247,221 s, exit -15, 1 031 sources sans dérive, pas d’erreur de compilation observée avant arrêt. PID concurrent 7308 ; l’observation suivante montre une compilation Velya. [Reçu](evidence/archive-attempts/archive-20260920-231325-receipt.json). Aucune archive réussie revendiquée ; caches conservés pour reprise.

La coordination UI a été refusée quand l’utilisateur a changé de session. Aucun message confirmé envoyé. Une demande de créneau de 10 min a été présentée à l’utilisateur ; la garde continue de refuser tout xcodebuild concurrent.

## Reprises pendant le créneau réservé

L’utilisateur a confirmé « Créneau réservé maintenant ». Les tentatives `archive-20260920-232142` et `archive-20260920-232542` ont cependant été interrompues par le garde après respectivement 30,526 s et 46,858 s (concurrents 12329 et 14635). Les 1 031 empreintes sont identiques avant/après chaque tentative. Reçus dans [archive-attempts](evidence/archive-attempts/). Aucun signal envoyé aux concurrents ; aucune réussite d’archive déduite de ces interruptions. Nouvelle reprise admise après disparition du concurrent.

`archive-20260920-232657` : interruption de concurrence après 18,485 s, PID 15187 ; 1 031 empreintes identiques. Une attente de 45 secondes réellement libres est utilisée avant la dernière reprise, bornée à 180 secondes d’admission.

## Résultat de la dernière reprise et blocage de coordination

`archive-20260920-232843` : **INTERROMPUE**, exit -15 après 34,550 s, malgré 45 secondes libres à l’admission. Les 1 031 empreintes sont identiques. Concurrent PID 16697, parent 92730 ; lecture ciblée confirmée : `-project Éclair.xcodeproj -scheme Eclair_macOS`. [Reçu](evidence/archive-attempts/archive-20260920-232843-receipt.json). Aucun concurrent arrêté, aucune archive Release réussie revendiquée.

UI de coordination déjà autorisée : session Éclair sélectionnée, message demandant dix minutes sans nouveau xcodebuild visible dans la saisie, mais **NON ENVOYÉ / envoi non confirmé**. Le collage a expiré après insertion visible. Deux demandes d’envoi par Entrée ont été rejetées par le contrôle automatique : l’arbre AX expose le terminal comme scrollbar focalisée, pas un champ de texte. Une capture et un clic sur la saisie ont confirmé visuellement le texte, sans résoudre cette limite AX ; aucun contournement. L’utilisateur peut transmettre le message dans la session Éclair pour obtenir une pause effective. L’heure indiquée dans ce brouillon (23 h 41) devra être ajustée si la reprise est plus tardive.

Aucun processus d’archive de cette session n’est laissé actif. La reprise utilisera le même cache et le garde, seulement après coordination effective. Les résultats Debug, noyau et natifs restent valides : aucune modification de code pendant ces tentatives ; 153 sources noyau, 77 fichiers de convergence et 1 302 fichiers originaux recontrôlés sans dérive. `git diff --check` PASS.

## Résultat final de la reprise suivante

Le contrôle initial ne détectait plus aucun xcodebuild. `archive-20260920-235130` a terminé **ARCHIVE SUCCEEDED**, exit 0, 383,098 s, aucun concurrent et 1 031 sources identiques avant/après. Les interruptions ci-dessus sont des tentatives historiques ; elles ne sont pas confondues avec ce PASS. [Reçu Release](evidence/release-archive/archive-20260920-235130-receipt.json), [identité](evidence/release-archive/candidate.json), [avertissements](evidence/release-archive/warnings.txt).

Le vérificateur existant `scripts/verify-research-vault-bundle.sh` a ensuite réussi sans option de signature. Ses opérations relues : présence des artefacts, validation plist, services Mach déclarés, chemins exécutables, inspection otool ; aucun lancement. [Reçu](evidence/release-archive/bundle-verification.json). Archive arm64 3.8.0 (226), déploiement macOS 14.0, non signée pour distribution.

Puis dix `RemoteTransferJournalTests` exécutés seuls en `test-without-building` : **10 PASS, zéro échec/skip**, 4,092 s pour le runner, résultat xcresult confirmé. Les 45 tests natifs antérieurs restent distincts. [Résumé](evidence/native-transfer-tests/summary.json). Admission vérifiant les 1 031 sources et les 115 fichiers Debug, hôte isolé confirmé dans le log, fixtures relues avant exécution, aucun concurrent. Le runner complémentaire est dans `convergence-validation-20260920/run-native-transfer-tests.py`, hors code applicatif. Ces scénarios qualifient la reprise des journaux synthétiques et la réservation locale ; pas un transfert réseau ni un upgrade complet en production.

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

## Résultat de la reprise 06:25–06:37

**Archive universelle NON QUALIFIÉE.** Trois tentatives interrompues par des xcodebuild tiers : `062536` après 275,052 s, `063138` après 246,802 s, `063710` après 2,083 s. [Synthèse et identités](evidence/universal-archive-20260921/resume-summary.json). Les 1 036 sources sont restées identiques à chaque tentative. Les deux premières avaient progressé sans erreur de compilation observée ; l’interruption ne permet aucune conclusion de réussite, notamment pour Intel. Aucun runner de cette reprise ne reste actif.

Fichiers modifiés pendant cette reprise : documents de progression/validation, ledger de release et preuves. Aucun changement applicatif ni nouvelle exécution de tests ; les reçus antérieurs sont conservés. Aucun restart, signature, envoi externe ou publication.

Prochaine tâche bloquante : suspendre effectivement les nouveaux builds des autres sessions pendant la compilation universelle, puis réutiliser `run-native-universal-archive.py` et le cache existant. Après PASS : contrôler architectures/bundle puis qualifier rendu visuel et distribution. L’absence de mécanisme commun d’exclusion des autres sessions reste le blocage opérationnel, aucun nouveau service ou contournement ajouté.

## Archive universelle réussie — 21 septembre, 07:12

**PASS : `universal-archive-20260921-070047`, 679,506 s (11 min 19 s), exit 0, aucun concurrent et 1 036 sources inchangées.** [Reçu terminal](evidence/universal-archive-20260921/universal-archive-20260921-070047-receipt.json). Admission après 120 s sans xcodebuild. Aucun lancement de l’app par l’archive ni signature de distribution.

[Candidat inventorié](evidence/universal-archive-20260921/candidate.json) : source 3.8.0 (226), minimum macOS14, SDK27 ; **10 fichiers Mach-O possèdent tous arm64 et x86_64**, y compris Throttle, widget, ResearchVaultAgent, SQLCipher et Sparkle. Bibliothèque de compatibilité Swift également arm64e. 92 fichiers réguliers et 9 liens symboliques empreintés. [Structure du bundle PASS](evidence/universal-archive-20260921/bundle-verification.json), scripts/verify-research-vault-bundle.sh sans --require-signed. Aucune déduction de fonctionnement sur machine Intel ou macOS14 à partir des architectures binaires.

[Avertissements conservés](evidence/universal-archive-20260921/warnings.txt) : fermeture Swift ambiguë dans ResearchClaimsBoard (deux architectures et lignes de diagnostic dupliquées), quatre extensions C++17 dans MLX, extraction App Intents sans dépendance, catégorie absente du helper ResearchVaultAgent. Aucun changement opportuniste des sources/dépendances pour supprimer ces avertissements.

[Revalidation finale des empreintes](evidence/universal-archive-20260921/final-source-revalidation.json) : 1 036 archive, 153 noyau, 83 fichiers de convergence sans dérive. **Aucun nouveau test exécuté pendant cette reprise** ; reçus précédents 352 noyau, 83 cas natifs distincts sur deux campagnes, 12 tests du gate conservés. git diff --check PASS.

Changements de cette reprise : documentation/preuves et déplacements vérifiés de deux caches ; aucun code applicatif modifié. L’utilisateur choisit d’envoyer lui-même la coordination, puis demande d’attendre la fin d’Éclair : aucune nouvelle saisie UI ni signal à un processus tiers. L’agent n’a pas envoyé le message préparé dans Rampart. Aucun runner de cette reprise encore actif.

Prochaine tâche : qualification visuelle/clavier/VoiceOver du candidat isolé selon COCKPIT-QA, puis version/build à partir d’un feed autoritatif accessible (dernier constat HTTP403), signature/DMG, notarisation et Sparkle dans leurs gates. L’archive universelle ferme le blocage de compilation ; **distribution toujours NO-GO**. Aucun commit, push, installation/restart, signature ou publication.


## QA visible et localisation — 21 septembre, 07:41

Nouveau helper de tests `HostedViewReview.swift`, opt-in par variable d’environnement et attente bornée à 180 s, fermeture anticipée possible. `xcodegen generate` exécuté après ajout. Locale de lancement explicite par arguments du processus (`-AppleLanguages`, `-AppleLocale`) ; les seuls `-testLanguage`/`-testRegion` ne suffisaient pas à changer les textes natifs sur cet hôte macOS. Aucun defaults persistant changé.

Builds `071751`, `072330`, `072835`, `072929` PASS. Le dernier compile la correction des quatre suggestions EN/FR et le quatrième test Assistant. Source actuelle : 1 037 empreintes stables ; SwiftLint ciblé des trois fichiers de fixtures PASS sans cache.

| Exécution | Résultat réel |
|---|---|
| visual-tests-20260921-071949 | 1 PASS, 186,202 s ; langue effective FR malgré intention initiale EN, observation réelle et Cmd-Entrée/Stop synthétiques |
| visual-tests-20260921-072423 | 1 PASS, 208,834 s ; langue effective EN, fenêtre étroite et notice d’arrêt ; défaut des suggestions découvert |
| visual-tests-20260921-073017 | 1 PASS, 60,879 s ; nouveau test des quatre suggestions anglaises, rendu réel observé |
| visual-tests-20260921-073134 | 1 PASS, 186,541 s ; nouveau test des quatre suggestions françaises, AX observé mais capture tronquée |
| visual-tests-20260921-073510 | Exit65 après arrêt de notre seul hôte bloqué dans dyld avant bootstrap XCTest ; aucun test exécuté, NON CONCLUANT |
| visual-tests-20260921-073816 | Interrompu par concurrence, 72,989 s ; hôte orphelin identifié et fermé ; NON CONCLUANT |
| universal-archive-20260921-074000 | Interrompu par concurrence, 52,674 s, 1 037 sources stables ; aucune archive qualifiée |

[Reçus et diagnostics](evidence/visible-ui-20260921/). Les quatre exécutions vertes représentent deux identifiants de test, pas quatre nouveaux tests distincts. Les 352 tests noyau n’ont pas été relancés : leurs 153 empreintes ont été revalidées sans différence. Les 83 cas natifs historiques restent attribués à leurs campagnes ; ne pas les présenter comme une campagne actuelle unique de 84 cas.

L’archive universelle `070047` précède la correction produit de localisation. Nouvelle archive courante requise ; attente de 120 s sans compilation tierce. Aucune signature ni relance de l’app installée.


## Résultat final de la reprise — 08:07

Archive corrigée `universal-archive-20260921-075037` PASS : 619,806 s, 1 037 sources stables, dix Mach-O universels et structure du bundle PASS, aucune signature/lancement. [Candidat](evidence/universal-archive-20260921-075037/candidate.json).

Régression des huit cas Assistant/Intégration : EN `080145` PASS (126,049 s), FR `080433` PASS (28,453 s), zéro échec/skip. Le démarrage EN a finalement repris après le blocage échantillonné dans dyld ; cause non établie. Les huit cas sont identiques entre langues. Dernière observation UNKNOWN `080545` interrompue par concurrence après 6,177 s ; elle reste NON CONCLUANTE même si son marqueur de revue a été atteint.
