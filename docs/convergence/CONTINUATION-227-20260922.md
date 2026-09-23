# Reprise mission 2E0B57C1 — candidat installé 3.8.0 (227)

22 septembre 2026. Reprise Claude Code → Codex. **227 installé, signature et Gatekeeper valides ; validation complète de l’optimiseur encore ouverte. NO-GO publication maintenu.**

## Réconciliation

- Dépôt principal : `feat/research-vault-lots-1-4`, HEAD `32988f4`, cinq entrées non suivies initiales conservées.
- Travail de convergence retrouvé dans `build/convergence-recovery-20260920`, branche `codex/convergence-recovery-20260920`, base `1ac0a32`. Les 72 fichiers suivis modifiés et les fichiers non suivis préexistants sont conservés. Aucun changement produit dans cette reprise.
- `/Applications/Throttle.app` indique 3.8.0 (227). Le processus graphique observé utilise ce chemin ; un autre processus du même binaire appartient à l’outillage de la session. Aucun processus arrêté ni application relancée.
- Environ 43 Gio disponibles à la reprise. `/Volumes/DeveloperStorage` absent : le DMG227 et ses reçus externes ne sont pas accessibles. Leur identité, ticket DMG et signature Sparkle ne sont pas revalidés ici. Le handoff indique une notarisation acceptée, mais ne remplace pas ces reçus.

## Preuves fraîches

| Vérification | Résultat et portée |
|---|---|
| Noyau source courant | **369 PASS**, 330 XCTest + 39 Swift Testing, 123,332 s, codes de sortie 0/0, aucune erreur. Les 11 cas optimiseur sont inclus. [Reçu](evidence/continuation-227-20260922/throttle-core-evidence-pt_uw2qx/receipt.json). |
| Sources du noyau | Aucune différence d’empreinte avec le reçu final optimiseur du 21 septembre. [Comparaison](evidence/continuation-227-20260922/continuation.json). Ne lie pas à elle seule les sources à l’archive227 externe. |
| App installée | `codesign --verify --deep --strict` PASS ; `spctl --assess --type execute` PASS, `source=Notarized Developer ID`. [Identité et empreintes](evidence/continuation-227-20260922/installed-app.json). |
| Smoke statique | **6/6 PASS** : bundle, Dock, identifiant, signature Developer ID app/widget, équipe, helper Research Vault. [Log](evidence/continuation-227-20260922/smoke.log). Aucun lancement par ce script. |
| Ticket sur l’app | `stapler validate /Applications/Throttle.app` exit65 : aucun ticket agrafé à l’app. Gatekeeper accepte toutefois cette app. Ne pas assimiler cette observation à une absence de notarisation du DMG, non accessible. |
| Git | `git diff --check` PASS. Aucun commit, push, nettoyage, stash, installation, signature ou upload. |
| UI réelle | Cockpit et vue projet observés en français. Menu « Project stats + optimizer » observé puis actionné, mais aucune fenêtre de projet constatée. Plusieurs actions refusées par CUA : « The user changed … Re-query the latest state ». Pas de conclusion sur une panne produit. |

Les premières commandes de signature dans le sandbox ont produit `invalid signature`, `internal error in Code Signing subsystem` et des erreurs LaunchServices. Leur exécution autorisée hors sandbox a validé la signature et Gatekeeper. Ces premières erreurs ne sont donc pas une preuve de corruption.

## Prochaine tâche non terminée

1. Terminer la vérification UI avec la fenêtre disponible : onglet Optimizer, `settings` et `settings.local` sans bouton IA, message de traitement local, choix distant refusé, indisponibilité locale explicite. Ne pas modifier la préférence Assistant ni envoyer une configuration à un fournisseur.
2. Sur fixture isolée : changement de projet/fichier en vol, proposition/échec, Quick wins préservant les choix, Apply/backup/restore. Les cas création de fichier absent et modification concurrente avant Apply restent à qualifier ; le code existant de FileEditor exige une source présente. Ne pas appliquer une fixture à un vrai projet.
3. Retrouver DeveloperStorage et rattacher le DMG227 exact aux reçus archive/export/notary/Sparkle ; ne pas reconstruire ou renvoyer un paquet déjà accepté pour compenser un reçu momentanément inaccessible.
4. Le parcours de mise à jour Sparkle, la décision Claude et les faits opérateur de confidentialité restent ouverts. L’installation observée ne les clôt pas. Aucun accord public n’est inféré.

Cette reprise met à jour les preuves et le suivi seulement. L’ancien blocage disque et les mentions « aucun artefact227 » du 21 septembre sont historiques, remplacés par l’installation vérifiée ci-dessus.
