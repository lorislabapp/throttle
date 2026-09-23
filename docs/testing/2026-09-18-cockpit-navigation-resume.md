# Reprise cockpit-navigation — 18 septembre 2026

Worktree : `/Users/kevinnadjarian/.claude/worktrees/throttle-project-overview`.
Branche : `feat/cockpit-navigation`, HEAD initial `1ac0a32`.
Le handoff annonçait encore `691499f` ; le commit suivant ajoute le handoff lui-même.
Lecture initiale : status, diff, BACKLOG, handoff, puis TODO et inventaire des worktrees.
Modification préexistante préservée : `project.yml`, build 225 → 226.
Logs et dossiers de build préexistants conservés. Aucun commit, push, upload,
redémarrage, installation, import du coffre ni mutation d'Éclair effectués par Codex.

## §6, dans l'ordre

1–4. Restent humains : essai du build, choix 225/226, publication et specs/date
du Mac mini. L'application installée inspectée est **3.8.0 (224)** ; cela ne
prouve ni test du DMG 225 ni validation des lots D/E.

5. La CLI locale **2.1.276**, son aide et `claude agents --json` ont été relus.
Deux agents background bloqués, aucune ligne cloud, aucun champ de coût.
La [documentation officielle de l'inventaire](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)
décrit les kinds interactive/background et distingue cet inventaire local des
Projects cloud. L'[annonce Projects](https://claude.com/blog/projects-redesigned)
mentionne l'usage par projet, sans établir ici de contrat d'export par thread.
**Aucun endpoint privé ni estimation de quota par thread n'a été ajouté.**
Une éventuelle ligne cloud affiche désormais « Non mesuré ». Le parseur cloud
reste une compatibilité anticipée, pas un connecteur cloud prouvé.

La vérification a également trouvé un faux zéro local : TaskSpend convertissait
une erreur SQL ou un transcript non encore ingéré en coût nul mesuré.
Le coût est maintenant optionnel ; chaque session trouvée doit avoir des événements
ingérés. Une lecture défaillante ou une session manquante rend la tâche non mesurée.
Un zéro effectivement observé reste mesuré. Les tarifs viennent toujours de
`StatsDataService.cockpitSessionCostEUR` ; aucune seconde table de prix.
Cartes et total distinguent l'inconnu, portent `≈` devant la valeur API-équivalente
et maintiennent la distinction avec l'abonnement. Le total reste un sous-total
des tâches mesurées, accompagné du nombre de tâches non mesurées.

6. Toujours bloqué sur un vrai échantillon cloud. Un fixture ne prouve ni
découverte réelle ni `claude attach` sur un thread Projects. Aucun agent lancé.

7. Correction du chargement initial et du rafraîchissement : `.task` était
attaché à une carte conditionnelle dont la liste initiale était vide, donc le
premier chargement pouvait ne jamais commencer. La tâche est maintenant portée
par un conteneur permanent, charge immédiatement puis attend 4 secondes entre
les lectures. Annulation à la sortie, lectures séquentielles et publication
des résultats interdite après annulation. Le callback d'ouverture et le loader
injectables permettent de tester sans toucher aux terminaux ni à la CLI réelle.

8. Tests de vues hébergées ajoutés : vide → agent → vide, arrêt du polling,
absence de chevauchement des lectures, exclusion d'une session déjà ouverte,
cloud non mesuré, vrai zéro, total partiel et mention d'abonnement.
Ils exercent SwiftUI et son arbre d'accessibilité dans l'hôte XCTest isolé.
Cela ne remplace pas le parcours manuel dans Throttle installé, le test réel
du bouton d'attachement, VoiceOver ni l'inspection visuelle de toute la page Flux.

9. Éclair T1.1 confirmé en lecture seule : `claimed`, propriétaire
`claudeCode:345CEB07`, mission `C911FAF0-1ACE-4854-96DA-E062FAA29F96`.
Un seul événement, `claimed`, daté du 17 septembre à 12:18:37Z.
Le flux signale déjà l'absence de session et propose d'ouvrir pour relancer/libérer.
**Décision produit manquante** : qui peut libérer automatiquement une attribution
et quelle preuve d'arrêt suffit, notamment pour une session distante ou externe ?
L'absence d'onglet local seule ne prouve pas l'arrêt de l'agent. Aucune mutation
du plan d'Éclair ni nouvelle règle de récupération automatique.

10. Coffre : trois sources enregistrées. DeepSearsh/library a zéro fingerprint
persisté ; Research et Research/Eclair en ont chacun 134. Ce sont des métadonnées,
pas une preuve d'import complet. Les 2 534 Markdown DeepSearsh sont lisibles en
UTF-8, non vides et tous sous la limite de 512 KiB de l'importeur. Le dossier
défaillant et sa raison restent à relever dans le nouveau build : `folderErrors`
est un état de vue non persisté, et le build installé 224 précède ces correctifs.
Aucun déchiffrement, import, retrait de dossier ou modification de préférences.

11. Handoff périmé sur la CI : SwiftLint est déjà épinglé à **0.63.2** et le
[dernier run main](https://github.com/lorislabapp/throttle/actions/runs/35105598562)
du 16 septembre est **success**, sur `cfe0778b3bfe063ed6a47a3cccbc74bb15d1740c`.
Cela ne valide pas le HEAD local ni ce diff, qui ne sont pas poussés.

12. BACKLOG est archivé ; TODO renvoie encore à des checkpoints d'autres worktrees.
Cette note est le reçu de la reprise courante et ne transforme pas ces anciennes
cases en tâches exécutées ou en preuves actuelles.

## Validation et concurrence

- `xcodegen generate` exécuté après chaque ajout de fichier source/test.
- Parsing Swift des huit fichiers Swift concernés : succès.
- SwiftLint local 0.65.1 ciblé : succès après deux corrections de longueur de ligne.
- Contrôle complet `scripts/verify-swiftlint.sh`, avec binaire 0.63.2 séparé dans
  `/private/tmp/throttle-swiftlint-0.63.2-codex` : **0 violation**.
  Reçu : `/private/tmp/throttle-codex-cockpit-lint-20260918.json`.
- `git diff --check` : succès au contrôle intermédiaire.
- XCTest final : **23/23 réussis, zéro échec, zéro skip**, confirmé par le résumé
  natif `xcresulttool get test-results summary` : TaskSpend 7, inventaire 5,
  vues hébergées 4, PlanFlow 5, catalogue français 2.
- Commande : `xcodebuild test -project Throttle.xcodeproj -scheme Throttle
  -destination platform=macOS,arch=arm64 -skipPackagePluginValidation
  -skipMacroValidation -parallel-testing-enabled NO -jobs 2 CODE_SIGNING_ALLOWED=NO`,
  avec `-only-testing:ThrottleTests/<suite>` pour les cinq suites ci-dessus et
  réutilisation explicite du DerivedData de ce worktree.
- Log final : `/private/tmp/throttle-codex-cockpit-tests-20260918-094637.log`.
- Résultat natif :
  `/Users/kevinnadjarian/Library/Developer/Xcode/DerivedData/Throttle-aavzcufhxiijzicnkcmlowyzptsy/Logs/Test/Test-Throttle-2026.09.18_09-46-40-+0200.xcresult`.
- Résumé exporté : `/private/tmp/throttle-codex-cockpit-xcresult-summary-20260918.json`.
- Échecs intermédiaires conservés : `...tests-20260918-093711.log` (nom de
  protocole AX du helper) et `...tests-20260918-094229.log` (4 tests de vues,
  11 assertions AX en échec ; 19 autres tests réussis).
  Le helper final active AX uniquement dans le processus XCTest et restaure
  l'état désactivé après chaque fenêtre. Les sélecteurs publics permettent de
  lire les nœuds SwiftUI, qui ne déclarent pas le protocole complet AppKit.
  Les fenêtres sont hors écran, et tous leurs agents et coûts sont synthétiques.
- Le contrôle lint complet final est conservé dans
  `/private/tmp/throttle-codex-cockpit-lint-final-20260918.json`.
- Non exécutés : suite entière, test d'attachement réel, UI de l'app installée,
  qualification du coffre dans le nouveau build, archive finale/signature.
  Des avertissements préexistants `ResearchClaimsBoard` et `FlowWording` ont
  été observés lors des premières compilations ; leurs fichiers ne sont pas modifiés.

Une archive concurrente Throttle (PID 99757) a démarré entre les inspections et
les modifications. Codex n'a pas lancé de second xcodebuild et a suspendu les
éditions de code dès détection. Cette archive a échoué : le projet chargé avant
XcodeGen ne connaissait pas le nouveau TaskSpendReadout.swift, alors que les
sources modifiées le référençaient. Les références sont présentes dans le projet
régénéré. L'archive est à refaire par son propriétaire ; elle n'est pas une preuve
de validation de ce snapshot. Des builds Velya ont ensuite occupé le créneau.
Les trois lancements de test ont attendu l'absence de tout xcodebuild et vérifié
l'espace libre : 5,97 Gio, 3,89 Gio puis 3,86 Gio. Cache Debug existant réutilisé,
deux jobs, tests séquentiels. Aucun processus tiers arrêté.

## Prochaine tâche

Après reconstruction de l’archive : faire tester par Kevin le candidat contenant ces
modifications, relever l'erreur du dossier dans le coffre, puis décider de la
règle de libération des attributions interrompues. Le coût/discovery cloud attend
toujours une interface documentée et un vrai thread accessible.

## Fichiers modifiés par cette reprise

- `Throttle/Services/TaskSpend.swift` : présence d'événements exigée, coût optionnel, injection du dossier de fixtures.
- `Throttle/Services/ClaudeAgentInventory.swift` : documentation corrigée sur la portée locale/cloud.
- `Throttle/UI/Cockpit/Navigation/OutsideAgentsCard.swift` : chargement, polling, annulation, cloud non mesuré et callback testable.
- `Throttle/UI/Cockpit/Navigation/CockpitTodayView.swift` : passage des sessions connues et callback d'attachement.
- `Throttle/UI/Cockpit/Navigation/ProjectFlowView.swift` : réutilisation des composants de coût.
- `Throttle/UI/Cockpit/Navigation/TaskSpendReadout.swift` (nouveau) : libellé par tâche et total du plan.
- `Throttle/Resources/Localizable.xcstrings` : cinq libellés français.
- `ThrottleTests/ServiceTests/TaskSpendTests.swift` : trois nouvelles régressions, données temporaires et SQLite en mémoire.
- `ThrottleTests/ServiceTests/CockpitSpendViewTests.swift` (nouveau) : quatre tests SwiftUI/AX isolés.
- `docs/TODO.md` : lien vers cette reprise, explicitement limitée à cette branche.
- Ce rapport `docs/testing/2026-09-18-cockpit-navigation-resume.md` (nouveau).

Le diff `project.yml` 225 → 226 était déjà présent et n'a pas été modifié par
cette reprise. Le projet Xcode généré est ignoré par Git mais contient bien les
deux nouveaux fichiers Swift. Les logs et dossiers de build présents au départ
ne sont ni supprimés ni ajoutés à Git.
