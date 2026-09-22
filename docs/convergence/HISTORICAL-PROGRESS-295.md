> **Texte historique reconstruit depuis la session après le redémarrage.** Les résultats 295 cas ont été observés avant la perte de `/private/tmp`, mais les XML/reçus de cette exécution ne sont plus disponibles. Les chemins remplacés pendant la restauration ne prouvent pas que ces tests ont été exécutés dans le nouveau worktree. Voir PROGRESS.md pour la seule validation fraîche applicable.

# Convergence Throttle — 20 septembre 2026

**Implémentation partielle du plan global. Lot 2 avancé, pas fermé.** Autorisation : « Implement the plan », puis « keep going ». Produit unique Throttle, interface native, réemploi ciblé et Gateway optionnel. Aucun transfert de données des projets sources, commit, push, publication ou restart.

## Base et propriété

Worktree `/Users/kevinnadjarian/GitHub/Throttle/build/convergence-recovery-20260920`, branche `codex/throttle-convergence-20260920`, base cockpit `1ac0a32f02f2cce9707779e41118ea39e7eb97d7`. Les 1 302 empreintes du snapshot cockpit original ont été recontrôlées en fin de reprise : aucune différence. Le dépôt principal, Super-Orchestrateur et SuperGateway n'ont reçu aucune écriture de cette mission. [baseline.json](baseline.json) identifie l'héritage, [CHANGES.md](CHANGES.md) les 40 fichiers cumulés de code/tests/harness, dont 21 changés dans cette reprise. Les fichiers de documentation et de preuve sont listés séparément.

## Lots et résultat observable

| Lot | État | Preuve / reste |
|---|---|---|
| 0 Base et réemploi | DOCUMENTÉ | [ADR](ADR-001-native-product-and-targeted-reuse.md), aucune extraction de code tiers |
| 1 Lectures sûres | NOYAU TESTÉ | Racine contrôleur, openat/NOFOLLOW, budgets et reçus ; app complète restant |
| 2 Exécution/récupération | PARTIEL, SOUS-TRANCHE NOYAU TESTÉE | Intentions persistées, fencing des résultats, identité grant/mission, intake autorisé et writers coordonnés ; processus/confinement/récupération réelle restant |
| 3 Preuves/Git | À FAIRE | Précontrôle rebase ajouté ; aucune prétention à sérialiser toute la transition Git |
| 4 Gateway | À FAIRE | Contrat runtime/protocole/auth, aucun déploiement |
| 5 Review/cockpit | À FAIRE | Identité reviewer, UX/AX/EN-FR ; réutiliser spend/inventaire |
| 6 Cycle produit | À FAIRE | Besoin satisfait et éligibilité release séparée de publication |
| 7 Mesures | À FAIRE | Baseline représentative, budgets autorisés, observations avant adaptation |

La vérification écrit désormais son intention dans le journal existant avant de lancer la commande. Un résultat absent reste UNKNOWN après réouverture et expiration ; une nouvelle vérification et un rebase déjà confrontés à cet état sont refusés. La réponse d'une ancienne tentative ne peut pas acquitter une nouvelle intention. Une observation distincte d'arrêt peut libérer l'intention sans valider le travail ; l'observateur de processus reste à construire.

Les outils MCP d'intake exigent des capacités propres. Les mutations de tâche sont liées au grant et à la mission durables : réutiliser le même nom d'auteur ne donne pas accès à une nouvelle mission. Le descripteur admis est relu et ne peut pas être remplacé pendant une requête pour élargir ses droits. Les écritures concurrentes de recherche passent par le verrou PlanStore ; une corruption existante n'est jamais remplacée par un dossier vide lors d'une écriture.

## Vérifications réellement exécutées

- Harness exact-source : **PASS, 295 cas**, 256 XCTest + 39 Swift Testing ; **137,156 s**. [Reçu](evidence/lot2-i272b6_m/receipt.json), [XCTest](evidence/lot2-i272b6_m/xctest.xml), [Swift Testing](evidence/lot2-i272b6_m/swift-testing.xml). Les **134 empreintes** de sources/test du reçu ont été recontrôlées sur le worktree après le run.
- Commande : `python3 scripts/verify-core-evidence.py --output-parent /private/tmp/throttle-convergence-evidence --scratch-path /private/tmp/throttle-convergence-swift-cache --timeout-seconds 600`. SwiftPM isolé, deux workers, fixtures locales synthétiques. Les commits et merges des tests concernent uniquement ces dépôts jetables, jamais les dépôts utilisateur.
- Nouveaux scénarios : perte d'ACK simulée par réouverture, expiration, réponse tardive, huit admissions concurrentes, récupération sans certification, intention visible avant commande, ancien grant après nouvelle mission, substitution de mission, intake sans droit, corruption préservée, huit writers de recherche, symlinks/hardlinks/FIFO/fichier trop volumineux, rebase refusé avec intention non acquittée.
- Runs intermédiaires verts : 291 puis 293 cas, conservés dans [runs.json](evidence/lot2-i272b6_m/runs.json). Ils portent sur des snapshots antérieurs et ne remplacent pas le dernier reçu. Les preuves de la précédente tranche 279 cas restent dans `evidence/receipt.json` et son historique initial.
- `swiftlint lint --quiet --strict` : sortie 0 pour les sept fichiers ciblés de lease/lifecycle/routeur/dossier et les trois nouvelles suites correspondantes. Pas de lint global vert revendiqué ; la dette existante reste séparée.
- `swiftc -frontend -parse Throttle/State/PlanIntegrationModel.swift Throttle/Services/TaskLauncher.swift` : sortie 0, **syntaxe seulement**, pas compilation des dépendances de l'app.
- `xcodegen generate` réussi après ajouts ; `git diff --check` réussi.

La collecte de version Xcode pendant une vérification lit maintenant les métadonnées installées au lieu de lancer `xcodebuild -version`. Aucune invocation xcodebuild, aucun modèle/API distant et aucun lancement de Throttle par cette reprise. Le dernier inventaire de processus via pgrep a échoué dans le sandbox (`Cannot get process list`) : ne pas en déduire qu'un créneau build est libre.

## Limites et prochaine tâche

Voir [REMAINING-GATES.md](REMAINING-GATES.md). Le harness ne compile pas l'app complète, TaskLauncher ou l'UI, et ne teste pas l'app installée. La reprise après crash réel avec processus descendants, leur confinement OS, la révocation atomique et la sérialisation Git restent NON VÉRIFIÉS ou À IMPLÉMENTER. Les contrôles de chemin et grants du même UID ne forment pas une sandbox. Les nouveaux événements exigent de conserver les journaux en cas de rollback vers un ancien binaire.

**Prochaine tâche : poursuivre le lot 2 sur l'observation des processus et la réconciliation de l'état UNKNOWN**, en réutilisant `TaskIntegrationVerifyChild` et PlanStore : identité stable, descendants, arrêt/annulation, crash et résultat externe inconnu. Puis qualifier l'admission commune aux effets Git. Ne pas lancer la migration Gateway avant fermeture de cette frontière. Aucun arbitrage produit nouveau requis pour ces fixtures ; l'autonomie d'écriture non confinée n'est pas activée.

Le snapshot documentaire précédent est conservé dans `evidence/lot1-snapshot/`. Cette livraison n'est ni une preuve de release, ni une autorisation générale d'installation, de migration ou de publication.
