# Intégration contexte / tests sur 3.6.0

**Résultat : intégration locale validée.** Le snapshot final passe 627 tests macOS, avec cinq omissions opt-in et zéro échec, ainsi que les suites Research Vault et les validateurs. Les améliorations restent non committées dans le worktree ci-dessous. Le pilote mesuré et l’exécution distante de CI restent ouverts.

Base : `3abf6a6`, branche source `release/3.6.0-219`, worktree source `build/cockpit-maintenance`, propre au démarrage. Nouveau worktree isolé : `build/context-testing-3.6.0`, branche `feat/context-testing-3.6.0`. La branche principale conserve le travail précédent et `.install-backups/`.

## Contrat de cette reprise

Réunir les deux deltas sans perdre le repli OCR CPU, les contrôles de provenance des reçus et le ratchet SwiftLint 0.63.2 ; faire passer les tests ciblés, la suite Research Vault et la suite macOS du résultat combiné ; qualifier les previews isolées possibles sans installer/remplacer l’app de travail. Aucun commit, push, téléchargement de release, changement de service ou publication implicite.

La preuve antérieure de 608 tests réussis et cinq ignorés concerne la session release, pas les nouvelles modifications. L’archive/DMG préparés par cette session ne contiennent pas nos changements et ne valent pas artefacts du résultat intégré.

## Journal

- Découverte : le commit 3abf6a6 inclut déjà `ResearchDocumentOCR`, qui tente le processeur après erreur de l’accélérateur et conserve ce choix pour le document seulement. Le blocage OCR historique doit donc être revalidé sur ce code, pas réparé une seconde fois.
- Réunion locale : les changements s’appliquent sans conflit hors CI ; fusion à trois versions de la CI réussie, avec conservation du pin 0.63.2 et des contrôles de publication de la session release.
- Adaptation nécessaire du vérificateur isolé : six fichiers composent maintenant `ResearchVaultIPCModel`. Ils sont tous copiés sans transformation et liés aux hashes de preuve.
- Intégration : les modifications de contexte, de métriques et de validateurs sont présentes avec les contrôles de provenance de la release. SwiftLint reste épinglé à 0.63.2. La première suite macOS combinée passe : 627 réussis, cinq ignorés, zéro échec.
- UI : qualification dans une copie temporaire ad hoc, identifiant distinct `com.lorislab.throttle.context-testing-ui`, hôtes isolés `-researchVaultApprovalTest` et `-globalRAGOnboardingTest`. La phrase de recherche du portefeuille était en anglais dans l’interface française ; ajout de sa traduction dans le catalogue existant, reconstruction puis vérification visuelle et AX de « Recherche dans Portfolio. ». La copie est fermée ; le binaire installé conserve son hash initial.
- Revalidation après traduction : le build de tests réussit, puis le disque se sature pendant l’exécution. Erreurs POSIX 28 / Cocoa 640 et `git index-pack` explicites ; le résumé xcresult incomplet retourne `unknown` et zéro test. Ce résultat ne vaut pas un succès. Rapport et log conservés ; seuls les caches et la copie UI produits par cette intervention sont retirés. La reprise complète utilise les mêmes binaires, sans affaiblir ni ignorer les tests concernés.
- Reprise terminée : `TEST EXECUTE SUCCEEDED`, code 0 ; le reçu xcresult final confirme 632 cas, 627 réussis, cinq ignorés et zéro échec. Les 559 empreintes du build final sont inchangées.

## Résultats du code intégré

Les preuves compactes sont conservées dans [le dossier d’intégration](evidence/2026-09-08-integration). Les résultats du [rapport initial](2026-09-08-workflow-validation.md) concernent le snapshot précédent.

| Vérification | Résultat et limite |
|---|---|
| macOS, première exécution complète | 627 réussis, cinq ignorés, zéro échec ; avant la seule modification du catalogue de traduction. [Résumé xcresult](evidence/2026-09-08-integration/macos-summary.json) |
| macOS, reconstruction et exécution finales | `TEST BUILD SUCCEEDED`, puis reprise `TEST EXECUTE SUCCEEDED` : 627 réussis, cinq ignorés, zéro échec. [Reçu final xcresult](evidence/2026-09-08-integration/recovered-macos-summary.json). L’exécution intermédiaire invalide après saturation est conservée séparément |
| ResearchVaultKit | 42/42 XCTest et 107/107 Swift Testing, zéro échec/omission. [XCTest](evidence/2026-09-08-integration/vault-xctest.xml), [Swift Testing](evidence/2026-09-08-integration/vault-swift-testing.xml) |
| Régression OCR | `scannedPDFIsRecoveredByOCR` passe en 178,420 s. Le repli CPU livré par l’autre session résout cette fixture ; ce temps ne qualifie pas la latence en usage réel |
| Sous-ensemble Swift de contexte et validateurs | 39/39 ; sources exactes, tous les cas attendus terminés. [Reçu](evidence/2026-09-08-integration/core/receipt.json) |
| Vérificateurs Python/shell | 12/12, dont les trois fixtures HTTP de vérification de publication ; exécution hors sandbox nécessaire au serveur de test sur loopback |
| Réducteur de contexte | 16/16 tests, dont 144 variantes déterministes de conservation d’erreurs ; évaluation synthétique 12/12, sans modèle appelé |
| Edge agent | 32/32 tests ; aucune cible distante contactée pour cette suite |
| SwiftLint | 0.63.2, vérificateur global strict, zéro nouvelle violation ; le seul changement produit ultérieur est le catalogue de traduction |
| Interface | Previews Research Vault et onboarding du portefeuille inspectées visuellement et via AX ; traduction reconstruite vérifiée. Captures et arbres AX archivés |

Ces nombres se recouvrent : ne pas les additionner en total de tests uniques. La suite du package n’est pas le script spécialisé complet `Packages/ResearchVaultKit/Scripts/verify.sh`, qui inclut des entrées/corpus et contrôles supplémentaires.

Les cinq omissions macOS restent explicites : deux tests MLX opt-in (dont un téléchargement de modèle de 968 Mo), une proposition GlobalRAG avec modèle local, une route Ollama privée et une fixture d’exports NotebookLM. Les avertissements d’inversion de priorité dans les tests Git/plan-store sont conservés dans les résultats ; l’absence d’échec ne prouve pas une interface toujours réactive.

L’inspection de previews ne qualifie pas VoiceOver, la navigation complète au clavier, les consentements système, un import réel de documents, les services externes ni l’application installée. Les sources Swift, tests, `project.yml` et catalogue final sont liés à [559 empreintes](evidence/2026-09-08-integration/final-source-snapshot.json), revérifiées après reconstruction. Aucun fichier de ce périmètre n’a dérivé.

## Ce qui reste réellement ouvert

- Exécuter le job CI ajouté sur GitHub après intégration/push autorisés. Ses commandes passent localement ; aucun résultat distant n’est inventé. La CI actuelle construit l’app macOS mais ne lance toujours pas toute la suite hébergée ; le job indépendant couvre le sous-ensemble des validateurs.
- Mesurer les dix tâches du pilote, y compris les échecs, le coût de toutes les tentatives, le temps humain et les régressions. L’intégration présente fournit une observation réelle mais pas une comparaison ni une mesure de coût/temps complète.
- Qualifier les parcours avec données/services réels et la latence OCR quand ces usages seront ciblés. Les cinq tests opt-in ne sont pas remplacés par leurs doubles locaux.
- Toute préparation d’un nouvel artefact signé devra repartir du résultat intégré. Le DMG déjà préparé dans `build/cockpit-maintenance` reste celui de `3abf6a6` ; il ne contient pas ce delta.

La recherche et ces tests étayent les corrections. Ils ne suffisent pas à déclarer le portefeuille « SOTA » ou à prouver un multiplicateur de productivité. Swift reste le choix pour les interfaces Apple ; Rust reste une option à évaluer pour un nouveau cœur portable ou système, avec mesure des coûts de FFI, compilation et distribution.

## Rejouer la suite macOS

Avec les dépendances déjà résolues et suffisamment d’espace libre, la commande complète utilisée est :

```sh
xcodebuild test -project Throttle.xcodeproj -scheme Throttle \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/throttle-integration-20260908/DerivedData \
  -clonedSourcePackagesDirPath /private/tmp/throttle-cockpit-maintenance-derived/SourcePackages \
  -disableAutomaticPackageResolution -skipPackagePluginValidation \
  -skipMacroValidation -jobs 2 -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/Throttle-NewRun.xcresult
```

Choisir un dossier de résultat neuf. La dernière reprise utilise `test-without-building` sur le build final, avec les mêmes paramètres de projet/destination/dépendances. Les résultats xcresult complets restent sous `/private/tmp/throttle-integration-20260908/` ; leurs résumés et logs compressés sont archivés ici pour survivre à un nettoyage de `/tmp`. Les caches de compilation retirés seront reconstruits par la commande complète.

## Pilote réel

Cette intégration est une première tâche réelle observable. Le contrat est celui ci-dessus ; les coûts et le temps humain ne sont pas mesurés rétrospectivement. Ne pas transformer les cas de tests en tâches du pilote, ni déclarer une comparaison de productivité sans référence comparable.
