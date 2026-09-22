# Optimiseur — correctifs O01/O02, candidat source 3.8.0 (227)

> Actualisation du 22 septembre : **227 installé**, signature stricte et Gatekeeper PASS, noyau369 PASS et smoke6/6 PASS. UI optimiseur non qualifiée complètement ; DMG externe inaccessible. Les états antérieurs ci-dessous sont historiques. [Reprise et preuves fraîches](CONTINUATION-227-20260922.md).

21 septembre 2026. Corrections autorisées par « keep going alors ». Worktree `build/convergence-recovery-20260920`, branche `codex/convergence-recovery-20260920`, base `1ac0a32`, travail préexistant préservé. Aucun commit/push, appel fournisseur, installation, redémarrage de Throttle installé ou publication.

## Résultat et limite

O01/O02 corrigés au niveau source et noyau : **369 tests PASS**, dont 11 nouveaux (330 XCTest + 39 Swift Testing), campagne finale 98,058 s. Le candidat source est **227** ; le DMG226 reste intact et notarisé mais ne contient pas ces corrections. Build natif227 refusé avant lancement : environ831Mo disponibles, seuil2Gio. Aucun artefact227 à installer.

## Modifications

- `AIOptimizerService.swift` : génération réservée à CLAUDE.md sur modèle de l'appareil. Settings refusés au service, même si une UI omettait la restriction. Serveur LAN/cloud refusés aussi ; aucune regex de secrets ne sert d'autorisation réseau. Flux interrompu, cancellation, fichier vide, délimiteurs absents/dupliqués, clôture de bloc manquante et sortie dépassant256Kio refusés. Aucun retry implicite. Une proposition inchangée conserve les octets originaux.
- `AIProvider.swift` / `AIProviderRegistry.swift` : classification de destination, résolution locale filtrée avant les probes réseau. Préférence Assistant conservée : un choix distant rend l'optimiseur indisponible avec explication, sans changement de compte ni facture implicite.
- `SettingsAuditService.swift` : aucune prescription de modèle ou désactivation du raisonnement, ratios inventés supprimés. Formats inconnus de permissions refusés sans remplacement ; modèle, effort, hooks et credentials restent inchangés. Les raisons ne recopient pas les credentials. Règles proposées avant Apply ; aucune prétention de sandbox OS.
- `ProjectOptimizerTab.swift` et extraction `ProjectOptimizerTab+Actions.swift` : portée locale annoncée avant génération ; bouton IA réservé aux instructions, Quick wins déterministe pour settings. Invalidation/cancellation au changement de projet, fichier ou écran ; résultats tardifs ignorés et ancienne référence de rollback effacée. Édition/Apply désactivés pendant génération. « No changes proposed » remplace le faux verdict « Already optimal ».
- `Localizable.xcstrings` :11 entrées EN/FR. Format et modifications préexistantes préservés depuis le checkpoint vérifié, sans réécriture générale du catalogue.
- `project.yml` : build macOS227, version3.8.0 ; compagnons inchangés. XcodeGen exécuté après les ajouts Swift et le bump.
- `scripts/verify-core-evidence.py` : sources exactes des deux services et deux nouvelles suites incluses dans le noyau ; seuls les providers des tests sont simulés.

## Vérifications réellement exécutées

| Contrôle | Résultat |
|---|---|
| AIOptimizerPrivacyTests |7cas PASS : refus réseau sans appel, settings refusés sur tous providers, deux kinds locaux via doubles, sorties invalides, octets inchangés, stream échoué sans retry, cancellation avant appel |
| SettingsAuditPreservationTests |4cas PASS : préférences/credentials/hooks préservés, préférences absentes non ajoutées, formats inconnus inchangés, idempotence |
| Noyau complet |369PASS,0erreur ; [reçu](evidence/optimizer-20260921/core-final/receipt.json), logs et xUnit à côté |
| Lint |SwiftLint0.63.2 global strict sans cache PASS ; baseline/règles inchangées. Une première passe0.65.1 avec violations intermédiaires n'est pas une preuve finale |
| Syntaxe Swift |swiftc frontend parse des fichiers modifiés PASS ; ne vaut pas typecheck natif |
| Génération/diff |XcodeGen PASS ; git diff --check PASS |
| Build natif |NON EXÉCUTÉ, admission disque refusée avant xcodebuild ; [reçu et empreintes](evidence/optimizer-20260921/native-build-admission.json) |
| UI FR/EN, modèles locaux réels, Apply/restore |NON EXÉCUTÉS pour ces changements ; scènes cockpit226 historiques seulement |
| Archive/signature/notarisation227 |NON EXÉCUTÉES |

Première campagne369PASS,126,124s, conservée en externe sous `throttle-core-evidence-r5wd63ag`. La campagne finale `throttle-core-evidence-j8i4e8ah` ajoute le cas de clôture de bloc incomplet dans un test existant : ne pas additionner les deux totaux. [Synthèse](evidence/optimizer-20260921/validation.json).

## Préservation et disque

L'ancien hôte `isolated-host-20260921-092038` est préservé sur DeveloperStorage avec SHA-256/modes/liens/attributs étendus identiques, lien à l'ancienne adresse et retrait du seul doublon. [Reçu](evidence/optimizer-20260921/isolated-host-20260921-092038-preservation.json). La première tentative s'est arrêtée avant copie faute d'API Python xattr ; reprise avec xattr macOS sans assouplir la comparaison.

L'hôte suivant100617 reste utilisé par trois processus dont les parents sont d'autres instances Codex : ni déplacé ni arrêté. La procédure des six hôtes s'est arrêtée ici ; les quatre suivants sont intacts. Ne pas relancer ce script aveuglément. Aucun gain d'espace suffisant. Aucun cache ou fichier d'un autre projet touché.

## Reprise concrète

1. Retrouver au moins2Gio libres stables (marge3–5Gio préférable) et aucun xcodebuild concurrent. Exécuter le runner existant `build/convergence-validation-20260920/run-native-build.py` depuis le worktree. Il n'arrête que son enfant en cas de concurrence.
2. Compiler227 puis préparer un nouvel hôte isolé avec ces octets. Ne pas réutiliser les runners épinglés à100452/123340 ni lancer les anciens hôtes préservés comme s'ils étaient le candidat courant.
3. Qualifier FR/EN : settings sans IA, choix distant non contacté, modèle local indisponible explicite, proposition/échec, changement de projet en vol, Quick wins conservant les choix, Apply/backup/restore sur fixture. La présente correction protège les réponses tardives ; elle ne fournit pas une transaction filesystem inter-processus. Vérifier les modifications concurrentes du fichier avant Apply et le parcours de création d'un fichier absent (FileEditor.write existant exige une source présente).
4. Fermer G07Claude, faits opérateur et parcours réel d'installation/update dans leurs autorisations. Nouvelle archive/export/signature/notarisation pour les octets227 : aucun transfert de l'accord d'envoi du DMG226 à un autre artefact.

Restriction volontaire : génération de settings par modèle différée, édition et checks locaux conservés. Serveur Mac mini inchangé pour ses autres usages explicites. Aucune route Assistant/LocalWorker retirée.
