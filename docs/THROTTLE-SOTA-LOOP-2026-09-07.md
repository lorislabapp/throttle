# Throttle — boucle SOTA et publication

Plan demandé et approuvé par Kevin le 7 septembre 2026 ; exécution reprise dans `build/cockpit-maintenance`, branche `fix/cockpit-state-observation`. Les trois handovers existants restent complémentaires.

## Contrat de fin

La boucle se termine lorsque G0–G9 passent : version macOS et services publiés, artefact public vérifié, mise à jour Sparkle exercée dans un environnement isolé et contre-audit final indépendant GO. Un build local ou une préparation de release ne suffit pas. Les compagnons iOS/visionOS font l'objet de contrôles de non-régression, sans nouvelle publication implicite.

## Cycle

1. Réconcilier HEAD, changements locaux, processus, stockage et preuves ; conserver les travaux existants.
2. Auditer le produit et rechercher les sources primaires actuelles en réutilisant les pistes DeepSearsh. Distinguer code, tests, binaire, runtime et publication.
3. Fixer au plus trois évolutions majeures, chacune avec critères d'acceptation. Les autres idées alimentent un backlog, sans élargissement perpétuel.
4. Corriger par lots réversibles avec reproductions ciblées, puis contrôles adaptés. Toute nouvelle défaillance pertinente retourne au lot concerné.
5. Valider l'usage Mac, la mémoire, la récupération, l'accessibilité et les services réellement embarqués. Obtenir une revue indépendante INTERIM avant publication.
6. Préparer un candidat exact, ses notes et son manifeste. Exécuter les étapes externes selon les accords concrets nécessaires, puis vérifier les octets publics et le parcours de mise à jour.
7. Après G0–G8 PASS, contre-audit indépendant final G9. Conserver les preuves et le handover final.

## Gates

| Gate | Critère |
|---|---|
| G0 | Sources réconciliées, reprise durable, stockage suffisant pour build et archives |
| G1 | Audit frais, recherche citée, opportunités arbitrées et critères fixes |
| G2 | Aucun P0/P1 ouvert de sécurité, confidentialité, perte de données/session ou crash |
| G3 | Évolutions retenues utilisables de bout en bout et mesurées |
| G4 | Concurrence, invalidation SwiftUI et limites mémoire contrôlées ; fichiers hors lint traités |
| G5 | Parcours, erreurs, clavier, VoiceOver, localisation et captures validés |
| G6 | Tests pertinents, CI fraîche, Release reconstruite, bundle et dépendances vérifiés |
| G7 | Qualification Mac réelle, charge bornée, hibernation/reprise et services runtime |
| G8 | Signature, notarisation, staging, publication et vérifications publiques PASS |
| G9 | Contre-audit indépendant final sur la révision et les artefacts publiés : GO |

## Publication et frontières

La chaîne canonique est celle de `docs/RELEASE.md` : `stage-release.py`, `publish-release.mjs`, `verify-public-release.sh`. Ne jamais utiliser le `deploy.mjs` du site. Préserver ses sept fichiers de travail. Conserver dSYMs et manifestes hors worktrees temporaires. Vérifier taille et SHA-256 du DMG téléchargé intégralement avec URL normale et cache-bust, signature, ticket/Gatekeeper, appcast, page publique et contrôle répété à T+15 min. Tester Sparkle sur une installation de qualification isolée.

Les accords nécessaires à l'installation ou au redémarrage de l'app de travail, aux uploads de notarisation et à la publication portent sur un résultat exact déjà préparé. Ne pas modifier `~/.claude.json`, importer de secrets ni étendre les droits d'un autre client/projet. NotebookLM est N/A sans accord d'upload d'un paquet précis. Pas de modification implicite du prix, du canal ou des promesses de confidentialité.

## Reprise

Lire `docs/audits/THROTTLE-SOTA-REMEDIATION-2026-09-07.md`, puis revalider les faits susceptibles de dériver. Les fichiers sous `/private/tmp` ne sont pas durables : copies de preuves dans `audit-output/sota-20260907`, rapports et décisions dans `docs`. Aucun checkpoint partiel ne vaut déclaration SOTA ni publication terminée.
