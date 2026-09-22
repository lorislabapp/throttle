# Qualification ciblée pair / contrôle terminal

2026-09-21 — worktree `build/convergence-recovery-20260920`, base `1ac0a32f02f2cce9707779e41118ea39e7eb97d7`, modifications locales.

## État de preuve

**Tests écrits, NON EXÉCUTÉS dans cette lane.** Compilation et exécution sont centralisées par le parent. Les résultats précédents (352 core, 55 natifs) ne qualifient pas ces nouvelles modifications tant qu'une nouvelle preuve n'est pas produite.

Deux frontières de production ont été rendues injectables sans changer leur politique :

- `PeerTransport.deliverControl` contient la garde déjà exécutée après le saut vers MainActor : ticket toujours valide ET réglage de contrôle actif.
- `PeerTerminalBridge` conserve ses gardes à l'entrée et avant injection; son terminal, sa permission et ses sorties peuvent être fournis par une fixture, sans ouvrir un cockpit ou PTY.
- L'initialisation de `PeerTransport` utilise le même switch de lecture Keychain, avec effets explicites injectables. Le constructeur de production continue de fournir les wrappers habituels.

## Protocole natif préparé

Exécuter `ThrottleTests/PeerTerminalBoundaryTests` (12 tests) dans l'hôte natif isolé déjà prévu pour les tests, avec les sources réellement régénérées par xcodegen. Ne pas lancer Throttle utilisateur.

| Situation | Assertion attendue |
|---|---|
| Ticket capturé, livraison MainActor mise en file, révocation puis nouveau consentement avant livraison | Ancienne commande refusée; un nouveau ticket peut attacher |
| Ticket valide mais réglage de contrôle désactivé à la livraison | Aucune attache, entrée ni sortie réseau |
| Ancien listener arrêté puis remplacé avant livraison | Entrée de l'ancien ticket refusée |
| Appel direct au bridge avec contrôle désactivé | Aucun contournement de la garde transport |
| Révocation après attache | Tap supprimé, callback de sortie ancien sans effet, ancienne attache non restaurée par nouveau consentement |
| Déplacement d'attache | Ancienne sortie détachée; entrée et sortie uniquement pour nouvelle session |
| UUID absent/invalide ou entrée sans attache | Aucun effet |
| Keychain inaccessible | Ni lecture legacy, ni génération, ni écriture, ni publication de pairing |
| Pairing trouvé mais invalide | Aucun remplacement automatique |
| Écriture legacy refusée | Copie conservée, identité non publiée |
| Écriture legacy réussie | Persistance avant suppression |
| Écriture nouvelle identité refusée | Identité éphémère non publiée |

Les tâches MainActor de la fixture simulent la mise en file du callback après réception. Elles appellent la vraie branche finale de production. Elles ne simulent pas une négociation TLS réussie et ne constituent pas une preuve de transport réseau.

## Limites ouvertes

Aucun listener, socket LAN, vrai trousseau, valeur secrète, modèle, serveur distant ou appareil n'est utilisé par ces tests. Aucun `PeerTransport.start()` n'est appelé. Les permissions système, poignée de main TLS-PSK, rejet d'un secret distant incorrect, reconnexion sur appareil, arrière-plan iOS et rendu/accessibilité des réglages restent **OPEN**. Ces parcours exigent un hôte isolé et une autorisation de transport/dispositif explicite; ils ne sont pas réputés vérifiés par les doubles de terminal.

La transaction inter-processus « lecture absent → création » du Keychain reste une limite distincte. Cette tranche vérifie l'absence de remplacement automatique après indisponibilité, pas une garantie exactly-once de création.

## Exécution parent du 21 septembre

Les 12 tests PeerTerminalBoundaryTests ont réussi dans `cockpit-tests-20260921-002937`. Les quatre échecs de cette campagne concernent d’autres fixtures UI, corrigées ensuite. Preuve : [inventaire XCTest](evidence/native-cockpit-20260921/cockpit-tests-20260921-002937-tests.json). Les sources de cette frontière n’ont pas changé depuis. Livraison, callbacks et persistance sont injectés ; transport TLS, Keychain système et appareil distant restent NON EXÉCUTÉS.
