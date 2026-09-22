> Snapshot historique conservé avant mise à jour du reçu courant. Ne pas utiliser comme statut actuel.

# Convergence Throttle — reprise persistante du 20 septembre 2026

**Reprise persistante intacte. Dernier reçu terminé : 311 tests réussis avant les corrections réseau/UX en cours de validation. Plan global partiel, release NO-GO.**

## Reprise suivante — validation en cours

Après 308 cas (pipe + crash), la suite `throttle-core-evidence-j5_jyfi5` a passé 311 cas avec cible Git immuable, base déplacée refusée et hooks de merge désactivés pour cette opération. Les corrections supplémentaires en cours concernent le routage sans envoi réseau implicite, le contrôle terminal séparé du miroir et le diff indisponible explicite. Les reçus 306/308/311 ne certifient pas ces modifications ultérieures.

Premier build natif non signé tenté sur DeveloperStorage, limité à deux jobs : échec de validation du plug-in MLX CudaBuild avant compilation. Log `/Volumes/DeveloperStorage/BuildScratch/throttle-convergence-20260920/build.log`. Plug-in local épinglé inspecté : sur macOS `isCudaEnabled` retourne false et ne produit aucune commande CUDA. Aucun modèle, app ou service utilisateur lancé.

## Checkout et restauration

Worktree `/Users/kevinnadjarian/GitHub/Throttle/build/convergence-recovery-20260920`, branche `codex/convergence-recovery-20260920`, base `1ac0a32f02f2cce9707779e41118ea39e7eb97d7`. Le worktree temporaire initial et ses reçus ont disparu après le redémarrage de 21:31. Les écritures de cette session ont été examinées et rejouées uniquement pour reconstruire les sources et documents ; les commandes de build, signal ou réseau historiques n'ont pas été rejouées.

Le snapshot cockpit hérité a été recopié puis recontrôlé : **aucune différence dans les 1 302 fichiers d'origine**. Le dépôt principal et les autres projets ne sont pas modifiés par les corrections ; seuls le worktree isolé et ses dossiers locaux de récupération/validation sous `build/` sont écrits. [CHANGES.md](CHANGES.md) liste les **45 fichiers cumulés** de code/tests/harness, distincts du travail hérité. La branche temporaire disparue n'a pas été nettoyée ni remplacée.

Les résultats antérieurs 279/291/293/295 et les deux échecs des premières variantes de gestion des processus sont historiques. Leurs XML/reçus temporaires ne sont plus disponibles. [HISTORICAL-PROGRESS-295.md](HISTORICAL-PROGRESS-295.md) est un texte reconstruit, pas une validation actuelle.

## Sous-tranche processus livrée

- Réutilisation de `NativeProcessIdentity`, `OwnedProcessTermination` et PlanStore.
- Wrapper fixe bloqué sur pipe ; identité noyau, groupe et boot persistés avant autorisation éphémère. La mort du contrôleur avant autorisation provoque EOF sans commande projet.
- PID conservé jusqu'à la fin du nettoyage ; signaux tardifs refusés après récolte. Le timeout est publié sous le verrou du signal.
- CLD_STOPPED est explicitement distingué d'une sortie : cette confusion avait supprimé le timeout dans les premiers essais. Seuls CLD_EXITED/CLD_KILLED/CLD_DUMPED sont des observations de terminaison.
- Diagnostic MCP ROOT_PRESENT / ROOT_EXITED_DESCENDANTS_UNKNOWN / PID_REUSED_DESCENDANTS_UNKNOWN / DIFFERENT_BOOT_EXTERNAL_EFFECTS_UNKNOWN / UNAVAILABLE. Ces lectures ne libèrent ni intention ni relance.
- Un résultat de processus non observé laisse la vérification inconnue. Une réussite de commande ne prétend plus certifier l'arrêt de tous ses descendants.

Voir [PROCESS-RECOVERY.md](PROCESS-RECOVERY.md) pour les sources primaires, les scénarios et les limites.

## Vérifications réellement exécutées après restauration

- Harness exact-source : **PASS, 306 cas**, dont **267 XCTest + 39 Swift Testing**, **96,299 s**. [Reçu](evidence/recovered-306/receipt.json), [XCTest](evidence/recovered-306/xctest.xml), [Swift Testing](evidence/recovered-306/swift-testing.xml), [log complet](evidence/recovered-306/output.log).
- Les **140 empreintes** des fichiers testés ont été vérifiées après exécution. Commande : `python3 scripts/verify-core-evidence.py --output-parent /Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/evidence --scratch-path /Users/kevinnadjarian/GitHub/Throttle/build/convergence-validation-20260920/cache --timeout-seconds 600`.
- Cinq nouveaux tests de processus : identité durable avant commande, refus avant exécution et signaux tardifs, attachement expiré/dupliqué, huit timeouts rapides et identité réutilisée/autre boot. Six tests existants d'OwnedProcessTermination sont désormais inclus, dont zombie, reparentage, descendant ignorant TERM et session étrangère préservée. Les tests existants d'intégration et de descendants passent également.
- SwiftLint strict ciblé sur les six fichiers processus/lifecycle/runner de vérification et tests concernés : sortie 0. Aucun lint global vert revendiqué.
- `xcodegen generate` après ajouts et `git diff --check` : réussis.

Cette suite compile le noyau isolé et les adaptateurs inclus, sans modèle ni API externe. Elle ne compile pas TaskLauncher, l'UI complète ou l'application signée. Une autre compilation Xcode et 67 % de mémoire libre ont été observés avant cette suite ; aucun xcodebuild ni lancement/restart de Throttle par la reprise. Les dépôts Git et processus affectés par les tests sont des fixtures synthétiques.

## Lots et prochaine tâche

| Lot | État |
|---|---|
| 0 Base et réemploi | Documenté, restauré |
| 1 Lectures sûres | Noyau testé ; app complète restante |
| 2 Exécution et récupération | Intentions, grant/mission, intake et root de processus testés ; confinement et récupération exhaustive restant |
| 3 Preuves/Git | Précontrôles ajoutés ; sérialisation et réconciliation complètes à faire |
| 4 Gateway | Non migré ; contrat/auth/runtime à qualifier |
| 5 Review/cockpit | Identité reviewer et UX/AX/EN-FR à valider |
| 6 Cycle produit | Besoin, DoD et éligibilité release à compléter |
| 7 Mesures | Baseline représentative et expériences bornées restantes |

**Prochaine tâche : valider les corrections réseau/UX et compiler l’application complète ; puis journaliser/réconcilier les effets Git et les descendants inconnus.** Ne jamais adopter un PID par son seul numéro, relancer sur simple expiration ou présenter un groupe vide comme preuve exhaustive. Conserver UNKNOWN en l'absence d'observation suffisante. Voir [REMAINING-GATES.md](REMAINING-GATES.md).

Aucun commit, push, migration inter-projets, déploiement ou publication. Aucun arbitrage produit supplémentaire inventé ; l'autonomie d'écriture non confinée n'est pas activée.
