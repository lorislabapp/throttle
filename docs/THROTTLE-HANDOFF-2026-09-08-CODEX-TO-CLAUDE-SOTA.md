# Handover Codex → Claude Code — intégration SOTA

Enregistré le 8 septembre 2026 à la demande de Kevin. Ceci est un passage de
relais, pas une déclaration de plan terminé ni une autorisation de nettoyage.

## 0. Reprise Claude Code — état au 9 septembre 2026 (lire en premier)

- **B est vert** : `qualification/3.6.0-release-loop-ci` @ `f846790`, run CI
  34281635340 entièrement PASS (macOS 646 cas, iOS, Vault Debug/Release,
  visionOS, quality, validator-evidence). Huit lots `cbb0936`→`f846790`,
  détaillés dans [le journal release](testing/2026-09-08-release-loop.md).
  Deux correctifs produit réels (arrêt confirmé malgré un zombie non récolté ;
  hibernation qui récolte son shell), trois correctifs de qualification.
- **A est sauvegardé** : `feat/context-testing-3.6.0` @ `083b615`, poussé.
- **Réconciliation A→B faite, locale seulement** :
  `integration/3.6.0-sota-release` @ `c2888fa` dans
  `build/integration-3.6.0`, **non poussée, jamais compilée en CI**. Table
  des 9 conflits dans le journal. Prochaine étape = push + un run CI, sur
  accord explicite de Kevin (dépôt public : minutes gratuites).
- Non committé : le paragraphe « CI n°8 » du journal dans le worktree B
  (déjà repris dans la branche d'intégration) ; les 21 fichiers de
  `~/GitHub/Throttle` (`feat/research-vault-lots-1-4`), jamais touchés.
- Les sections 1–6 ci-dessous restent valables pour les gates non fermés :
  benchmark corpusDrift, dix tâches réelles, parcours appareils/sessions,
  artefact signé. Verdict **NO-GO publication** inchangé.

## 1. Checkout exact et précautions

- Dossier de départ de la session : `/Users/kevinnadjarian/GitHub/Throttle`.
- **Travailler dans** `/Users/kevinnadjarian/GitHub/Throttle/build/context-testing-3.6.0`.
- Branche vérifiée : `feat/context-testing-3.6.0`.
- HEAD vérifié : `cdae2c718ac47bbfae19ca2f6fa17ceb077d89d7`.
- Worktree très sale, avec plusieurs sessions Claude/Codex concurrentes. Des
  modifications CI, ResearchVault, CloudKit, iOS, widgets, release et Cockpit
  appartiennent à d'autres travaux. Refaire `git status --short` et lire les
  diffs avant toute modification. Ne pas attribuer tout le diff à ce chantier.
- Aucun reset, clean, stash, commit, push, arrêt de processus, installation,
  relance, publication ou changement de configuration autorisé par ce document.

## 2. Demande et état réel

Kevin demande l'intégration dans Throttle des outils/workflows IA utiles, avec
une version native lorsque pertinente, et une qualification personnelle puis
produit. Le plan complet n'est **pas terminé**.

Référence de reprise principale : [journal d'intégration](testing/sota-integration-ledger.md).
Il contient le contrat produit, les lots L0–L8, leurs dépendances, les limites,
les résultats successifs et les intégrations différées. Lire ce fichier en entier.
Les recherches existantes sont des pistes historiques, pas une validation runtime.

Implémentation de ce chantier déjà présente :

- Diagnostics typés et minimisés, aperçu avant export aux deux points d'entrée,
  export de la valeur figée ; archive limitée à `summary.txt`, sans logs bruts.
  `DiagnosticReport`, `DiagnosticArchive`, `DiagnosticsPreviewView` et contrôleur.
- Mutations `PlanStore` sérialisées par projet, verrou coopératif, append durable,
  refus des journaux invalides ; préparation/claim transactionnels dans TaskLauncher.
- `WorkflowEvidenceReceipt` branché sur la vérification et sa projection UI :
  distinguer succès d'une commande, couverture et validité des entrées.
- Retry MCP opt-in via paire `event_id` / `expected_seq`, contrôle de l'intention,
  refus d'état périmé, routeur réel testable. Les anciens clients restent legacy.
  [Contrat MCP et exemple synthétique](testing/sota-mcp-retry-contract.md).
- Vérificateurs avec inventaires, reçus et hashes ; option `--derived-data-path`
  pour réutiliser uniquement notre cache macOS sans assouplir les gates.

Limites : verrou ≠ authentification, chaîne de hash ≠ signature ; les reçus ne
couvrent pas encore toutes les dépendances, variables d'environnement et fichiers
non suivis. L1/L2 restent partiels. L3–L8 restent à conduire selon le journal.

## 3. Preuves à ne pas surinterpréter

Ces résultats sont ceux des checkpoints enregistrés, pas un nouveau test de
l'ensemble du diff actuel. Aucun build/test relancé pendant ce handover.

- Suite légère : **121 cas réussis** (110 XCTest + 11 Swift Testing), sources
  exactes au checkpoint. [Reçu](testing/2026-09-08-sota-mcp-retry-evidence.json).
- Suite macOS hébergée complète : **build réussi ; 675 cas inventoriés,
  670 réussis et 5 skips explicitement autorisés**. Aucun cas manquant ni échec
  natif dans l'inventaire réconcilié.
- **Reçu strict en échec**, uniquement pour `sources_changed_or_not_recorded` :
  `Packages/ResearchVaultKit/Scripts/verify-ipc-boundary.sh` a changé pendant
  l'exécution concurrente. Ne jamais convertir ce reçu en PASS manuellement.
  [Résumé durable](testing/2026-09-08-sota-full-macos-evidence.json).
- Reçu brut : `/private/tmp/throttle-sota-macos/throttle-macos-g3m_prz3/evidence/receipt.json`.
  Existence et SHA-256 revérifiés pendant ce handover :
  `c7b6a20c8b43dad0f4033a4c53d38b9e4106967ba8b26d75178196a50ae0b189`.
- 14 tests de régression du vérificateur macOS réussis au dernier checkpoint.
  SwiftLint local 0.65.1 n'est pas la preuve du résultat CI épinglé 0.63.2.
- Warnings Thread Performance Checker de priorité/inversion à investiguer.
  Pas de validation humaine UI/VoiceOver, de runtime macOS 14, de services iCloud
  privés, de XPC signé, de clean-user ni de distribution prouvée par cette suite.

## 4. Blocage immédiat : espace disque

Dernier `df -h /System/Volumes/Data` pendant ce handover : **112 Mio disponibles**.
Valeur volatile : l'espace est passé de 1,8 Gio à ce niveau avec d'autres sessions
actives. Ne pas lancer de build lourd avant une nouvelle mesure et suffisamment
de marge. Le vérificateur exige **10 Gio libres** ; ne pas abaisser ce seuil.

Kevin a demandé d'inspecter les caches sans impacter les sessions. L'inventaire
élargi propose **35 chemins exacts, 8,42 Gio mesurés** :
[liste de nettoyage](testing/cache-cleanup-candidates-2026-09-08.md).

**Aucune suppression effectuée. Aucun GO reçu pour supprimer ces 35 chemins.**
La dernière demande est d'enregistrer le handover, pas de lancer le nettoyage.
Demander l'autorisation sur cette liste, puis recontrôler immédiatement tailles,
identités, symlinks, processus/arguments et fichiers ouverts. Exclure toute cible
redevenue active. L'absence de référence observée n'est pas une garantie d'absence
de réutilisation future ; supprimer un cache impose une recompilation et le gain
APFS réel n'est pas garanti. Ne pas répéter des suppressions si d'autres builds
consomment aussitôt l'espace.

Préserver sessions/historiques Claude/Codex, worktrees, produits, apps installées,
logs, xcresult, reçus, modèles et données temporaires métier. Un autre dossier
Kernel (`/private/tmp/kernel-full-fix.Au33Ty`) a été exclu car référencé par ibtoold.

Deux caches de cette tâche à **conserver**, existence revérifiée au handover :

- `/private/tmp/throttle-sota-macos/throttle-macos-g3m_prz3/DerivedData`
- `/private/tmp/throttle-sota-core/throttle-core-evidence-sxxgc7jc/package/.build`

Les chemins `/private/tmp` peuvent disparaître au redémarrage. Vérifier leur
existence, ne pas considérer un ancien reçu comme une preuve du checkout courant.

## 5. Ordre de reprise

1. Confirmer checkout/HEAD/diffs, espace et sessions actives. Ne pas arrêter les
   autres sessions. Résoudre le manque d'espace avec autorisation explicite.
2. Coordonner une fenêtre sans écriture concurrente sur les sources du snapshot.
   Avec au moins 10 Gio libres et le cache encore présent, relancer depuis le
   checkout exact :

   ```sh
   python3 -B scripts/verify-macos-evidence.py \
     --output-parent /private/tmp/throttle-sota-macos \
     --derived-data-path /private/tmp/throttle-sota-macos/throttle-macos-g3m_prz3/DerivedData
   ```

   Lire le reçu final, l'inventaire et la stabilité des sources. Un exit code seul
   ou 670 tests verts ne ferme pas la gate de snapshot.
3. Terminer L1 : acceptation réelle aperçu/export/annulation/fermeture, clavier,
   français et VoiceOver ; politiques de sortie et isolation sur les autres flux.
4. Terminer L2 : autorité des appelants, crash recovery, retries end-to-end,
   couverture complète des entrées et import natif des résultats.
5. Continuer L3–L8 selon leurs dépendances et gates : workflow Cockpit, eval/review,
   recherche/contexte gouverné, QA Apple/visuelle, signaux produit et kits opt-in.
   Pas de nouveau SaaS/model/compiler/payment backend à reconstruire par défaut.

Ne pas confondre ce chantier avec la boucle release/CloudKit/iOS concurrente.
Le prochain résultat recherché est un reçu macOS stable et fidèle, pas une release.

## 6. Ajout de la session parallèle : boucle release / contexte / testing

Ajout demandé par Kevin le 8 septembre 2026 pour préserver ses crédits. Cette
session s'arrête au handover ; **ne pas confondre ses sources avec celles des
sections 1–5**. Le chantier a commencé par la recherche sur le workflow IA,
la gestion du contexte et Rust, puis la correction des tests et des frontières
de confidentialité/distribution. Swift est conservé pour Throttle ; aucune
réécriture Rust globale n'est décidée.

### Checkout de qualification distinct

- **Dossier :** `/Users/kevinnadjarian/GitHub/Throttle/build/release-loop-ci`.
- **Branche :** `qualification/3.6.0-release-loop-ci`.
- Base commune : `cdae2c718ac47bbfae19ca2f6fa17ceb077d89d7`.
- Commits créés et poussés : `5b1f0f651c676667d6140b086b2d98ecacf420f7`, puis
  **`a6dd34387081853a225818918244273659d17604`**, dernier HEAD au handover.
- **PR draft #3 :** https://github.com/lorislabapp/throttle/pull/3, vers `main`.
- **Un troisième lot corrigé est présent mais NON committé/poussé.** Aucune
  troisième CI n'a été lancée, conformément au passage de relais demandé.
- Le lot PlanStore/diagnostics des sections 1–5 est exclu de cette branche.
  Les premiers correctifs release existaient dans `context-testing-3.6.0`, mais
  les corrections les plus récentes sont uniquement dans `release-loop-ci`.
  Ne pas copier un worktree entier par-dessus l'autre ni écraser l'option
  `--derived-data-path` ajoutée par la deuxième session.

Références : [journal release](../../release-loop-ci/docs/testing/2026-09-08-release-loop.md),
[candidat](../../release-loop-ci/docs/testing/2026-09-08-ci-candidate.md),
[workflow et pilote](../../release-loop-ci/docs/testing/workflow.md),
[recherche initiale](../../release-loop-ci/docs/testing/2026-09-08-research-background.md).
Les deux premiers documents contiennent des checkpoints intermédiaires ; le
présent ajout et le snapshot final décrivent ce qui reste non committé.

### Ce qui est implémenté

- Publisher CloudKit : générations, opt-out, annulation et révocation synchrone
  sur notification de compte. Sept tests ciblés et régression reproduite avant
  correction.
- Companion : vérification d'identité, rejet des réponses tardives, purge du
  cache, des surfaces et des anciens callbacks LAN. Widget publié seulement
  après vérification ; remplacement réel du moteur SwiftTerm et invalidation
  des réponses Face ID anciennes. 26 tests portables, contrepreuve par mutation.
- Research Vault : limites cohérentes de clés projet (128) et de l'enveloppe IPC
  (65 536 octets), neuf tests de clés et 21 tests XPC en processus.
- Staging : signature Ed25519 obligatoire sur les octets du DMG, nouveau dossier
  exclusif, revérification après copie ; 15 tests et archive historique vérifiée.
- CI : suites macOS/iOS indépendantes, inventaires natifs comparés aux résultats,
  preuves et hashes conservés ; Vault Debug complet et validateurs indépendants.
- Troisième lot **non committé** : ActivityKit correctement isolé et opérations
  update/end ordonnées (cinq tests portables) ; test français indépendant de la
  langue du runner ; fixture Cockpit stable, sans création continue de descendants,
  et lecture d'errno avant XCTest, sans assouplir l'arrêt sécurisé du produit.
- Troisième lot également : Vault Debug/Release en matrice indépendante, vrai
  rollback après crash Release et refus CLI explicite, binaires du même scratch ;
  CLI confinée par `sandbox-exec` (pas de réseau, fork, Mach IPC, écriture hors
  fixture ou lecture Keychains). 46 tests du validateur Vault passent, dont sept
  nouveaux tests réels de confinement, sans trousseau utilisateur.
- Build Release visionOS indépendant ajouté, à exécuter.
- Faux verts CI corrigés : `bash -n` et contrôles de notarisation fichier par
  fichier, quatre tests négatifs ; vérificateur de bundle refusant toute lecture
  `codesign` en échec, neuf tests. Ces tests simulent les signatures ; ils ne
  qualifient pas une signature réelle du candidat.

### Résultats distants exacts : ne pas annoncer une CI verte

Dernier run : https://github.com/lorislabapp/throttle/actions/runs/34260476621,
HEAD de branche `a6dd343`, commit de fusion testé
`1064a75f8b6731fec537b3cdf122f9016dc05f7f`.

- `quality` **PASS**, dont build macOS Release sans signature ;
  `validator-evidence` **PASS**.
- Vault Debug **PASS** : 42 XCTest + 115 fonctions Swift Testing, zéro omission,
  20 arguments annoncés et terminés par le runtime. OCR scanné réussi sous
  macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3. Deux runs Vault réussis ; 121 sources et
  15 artefacts du second ont été comparés au candidat, sans différence.
- macOS **FAIL** : 645 cas, 638 réussis, deux échecs et cinq skips autorisés.
  Échecs : traduction française dépendant de la langue du runner et
  `testHibernateConfirmsBothTerminalTreesBeforeReleasingViewsAndKeepsNativeIdentity`.
  Les corrections non committées doivent être réellement rejouées en CI.
  L'échec Cockpit n'a pas été reproduit dans 30 essais locaux du mini-harness ;
  il ne faut pas affirmer qu'un bug produit est démontré ou définitivement résolu.
  La fixture stabilisée passe ensuite 20/20 essais natifs ciblés, avec escalade
  KILL et processus voisin préservé ; ce n'est pas la suite hébergée complète.
- iOS **FAIL compilation** : ActivityKit non Sendable, corrigé dans le troisième
  lot ; la compilation et les tests UIKit/SwiftTerm restent à confirmer.
- Avant les sept derniers tests de confinement : **142 tests Python réussis**.
  Le validateur Vault a ensuite été rejoué seul : **46/46 réussis**. Ne pas en
  déduire une exécution globale fraîche des 149 cas du snapshot final.
  Reçu de confinement copié dans les preuves ; aucun log complet des 46 cas
  n'avait été sauvegardé, limite explicitement enregistrée dans ce reçu.
- SwiftLint **0.63.2** strict et `git diff --check` ont passé avant les tout derniers
  ajustements fixture/confinement ; relancer sur le snapshot gelé. Exécutable
  disponible : `/private/tmp/throttle-swiftlint-0.63.2/swiftlint`.

Autres preuves locales : oracle épinglé concordant sur **10 000 programmes**,
rollback SQLCipher Debug écriture/migration, hook idempotent, frontières IPC et
graphe de dépendances, processus MCP réel **65 documents / 738 passages**.
Ces essais utilisent uniquement des bases temporaires ; pas de modification des
services installés. Les sources du package réutilisé depuis l'autre checkout ont
été comparées au candidat (71 fichiers identiques pour MCP/hook).

### Échecs et validations encore ouverts

1. **Rejouer la CI du troisième lot**, sans affaiblir les oracles. Les vrais tests
   iOS, Cockpit, Vault Release/crash/refus et le build visionOS sont prioritaires.
2. **Réconcilier explicitement les deux branches** avant une preuve globale : les
   670 tests de l'autre session ne valident pas automatiquement ce candidat.
3. **Benchmark refusé pour corpusDrift.** Le corpus privé a changé (65 documents) ;
   ne pas remplacer le hash attendu pour rendre le test vert. Retrouver le corpus
   figé ou préparer une nouvelle référence revue indépendamment. Aucun corpus ou
   requête privé envoyé dans la PR. Le jeu dérivé des titres ne démontre pas la
   qualité sur des questions humaines indépendantes.
4. **Dix tâches réelles mesurées sur au moins deux projets**, exigence confirmée
   par Kevin : **0/10 entièrement mesurées**. Une demande de tâches a été envoyée,
   sans réponse à ce checkpoint. Ne pas compter dix tests synthétiques, inventer
   du temps humain/coût ou transformer des succès incomplets en pilote mesuré.
5. Parcours réels compte iCloud, widget quand l'app est absente, Live Activity,
   notifications, Face ID, terminal, VoiceOver ; identité/reprise fournisseur,
   Quit réel et conversation Mac→Linux→Mac. Les essais antérieurs de lignes vides
   ne prouvent pas le transfert d'une conversation.
6. Nouvel artefact exact signé, qualification du bundle, puis notarisation et
   distribution. Le DMG de `3abf6a6` ne contient pas ces corrections. Aucune
   publication, installation ou soumission Apple effectuée par cette session.

**Verdict actuel : NO-GO publication.** Le plus gros de ces correctifs techniques
est écrit ; les validations natives/terrain ci-dessus restent nécessaires.

### Preuves et commandes de reprise

Preuves compactes déjà copiées dans
`build/release-loop-ci/docs/testing/evidence/2026-09-08-release-loop/` ; snapshot
de passation : `handoff-snapshot.json` dans ce dossier. Les logs complets locaux
sont sous `/private/tmp/throttle-release-loop-20260908/`. Le xcresult complet du
dernier macOS est conservé localement et dans l'artefact GitHub de ce run ; les
rapports extraits sont conservés dans le dépôt. Vérifier les fichiers après reboot.

```sh
cd /Users/kevinnadjarian/GitHub/Throttle/build/release-loop-ci
git status --short
git diff --check
df -h .
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v
THROTTLE_SWIFTLINT_BIN=/private/tmp/throttle-swiftlint-0.63.2/swiftlint scripts/verify-swiftlint.sh
gh pr checks 3 --repo lorislabapp/throttle
```

Les tests de serveur HTTP local, CryptoKit et sandbox imbriquée nécessitent les
droits d'exécution adéquats : une interdiction sandbox n'est pas un défaut produit
ni un PASS. Après revue/gel/commit et push autorisés, la PR déclenche la nouvelle
CI ; attendre ses résultats finaux, télécharger les reçus et vérifier les sources.
Mettre aussi à jour la description de PR et les journaux avec le résultat réel.

Espace disque très volatil. Cette session a supprimé avec autorisation seulement
trois caches de compilation qu'elle avait créés, vérifiés inactifs (649 Mo) :
`/private/tmp/throttle-liveactivity-concurrency-20260908/.build`,
`/private/tmp/throttle-companion-account-proof/package/.build`,
`/private/tmp/throttle-cloudkit-publisher-20260908-opzgkc5n/.build`.
Leurs sources et preuves sont conservées. Cela ne vaut pas autorisation de
supprimer les 35 chemins proposés par l'autre session. Les deux caches à conserver
de la section 4 n'ont pas été touchés.
