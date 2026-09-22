# Release progressive : mise à niveau, récupération et contrôle après publication

Procédure préparée le 21 septembre 2026 pour 3.8.0 (226). **Aucune installation, restauration, modification du flux public ou publication exécutée par ce document.**

## Avant d'autoriser la distribution

1. Figer le choix de la route Claude. La demande Anthropic `215476024504261` attend une réponse humaine ; une transmission au support n'est pas une approbation. Aucun fallback payant implicite.
2. Revalider l'identité des sources, la version et le maximum du flux public au moment du staging. Le résultat 226 > 223 n'est pas une réservation.
3. Obtenir un artefact signé Developer ID avec app, widget, helper et Sparkle cohérents : Team, versions, architectures, profils et entitlements effectifs. L'archive unsigned n'est pas un paquet distribuable.
4. Après accord exact d'envoi à Apple : notarisation acceptée, ticket attaché, Gatekeeper et intégrité du paquet vérifiés. Signer les octets finaux pour Sparkle et vérifier la signature avec la clé publique embarquée.
5. Terminer les faits opérateur de [confidentialité](PRIVACY-PUBLIC-DRAFT.md) et appliquer les corrections de texte à la source publique fraîche. Relire les métadonnées sociales et le paragraphe de confidentialité, pas uniquement le numéro de version.
6. Faire valider l'artefact, ses empreintes et sa destination avant l'upload public. Ne pas installer ou redémarrer l'app utilisée par l'utilisateur pendant la préparation.

## Compatibilité des données : ce qui est démontré

[Quatre scénarios à deux lecteurs réels](evidence/release-continuation-20260921/two-reader-receipt.json) utilisent les sources historiques `d734b864ab83db050f4c55de2f94556e66308369` et les sources courantes, copiées sans modification et compilées dans deux exécutables séparés. [Manifeste](evidence/release-continuation-20260921/two-reader-source-manifest.json).

- Le lecteur courant relit le journal créé par le lecteur 223 sans changer ses octets.
- Les champs optionnels supplémentaires d'un événement connu restent sur disque après lecture ancienne.
- Un nouveau type terminal ou intermédiaire rend la chaîne invalide pour le lecteur ancien ; son append est refusé sans troncature.
- Le lecteur courant reconstruit l'intention de vérification toujours en attente après la lecture ancienne et la réécriture de son cache dérivé. L'expiration de l'intention ne vaut pas résultat.

Le statut historique peut rester `done`. Le lecteur courant invalide l'ancien `lastCheck` et conserve `pendingVerification` ; les gardes d'action et l'interface doivent consulter ces champs. Un libellé de statut seul ne permet jamais de reprendre ou fusionner. L'ancien lecteur conserve même un ancien contrôle vert malgré `chainValid=false` : c'est une raison concrète de **ne pas revenir aveuglément à 223**.

Ces preuves sont synthétiques. Elles ne prouvent pas que le DMG public 223 provient exactement du commit comparé. Elles n'exécutent pas les effets Git de l'ancien binaire et ne constituent pas une installation réelle. Le schéma SQL et son code d'ouverture sont identiques à ce commit ; aucune nouvelle migration SQL n'est nécessaire pour cette tranche.

## En cas de régression sur un projet

1. Stopper les nouvelles actions du contrôleur sur le projet concerné. Une annulation locale ne prouve pas qu'un processus ou effet distant a cessé.
2. Conserver `.throttle` au complet, les références Git, les worktrees et les preuves. Ne pas nettoyer un journal invalide, effacer un événement inconnu ou réexécuter une commande dont le résultat est inconnu.
3. Pour une copie cohérente, arrêter les écritures du projet avec l'accord de son opérateur. Une base SQLite active doit être sauvegardée avec son mécanisme de sauvegarde cohérente ; copier seulement `usage.db` en ignorant WAL n'est pas une sauvegarde qualifiée.
4. Diagnostiquer sur une copie isolée. Identifier les processus par leur identité effective, et observer HEAD, worktree et résultats avant de décider d'une reprise. Ne pas conclure « rien n'a été fait » à partir d'un timeout.
5. Préférer un correctif **de version supérieure**, comprenant les événements existants. Tester la copie et ses empreintes avant toute opération sur le projet actif. Un correctif de lecteur ne donne pas l'autorisation de relancer l'action.
6. Une restauration d'une sauvegarde ancienne doit réconcilier les effets postérieurs ; elle ne doit pas écraser silencieusement les journaux nouveaux. Une descente de version n'est pas la procédure normale de récupération.

## Contrôle post-publication — NON EXÉCUTÉ

| Contrôle | Preuve attendue | Arrêt / incident |
|---|---|---|
| Téléchargement public | GET de l'URL exacte, taille et SHA-256 égaux au paquet approuvé ; contrôler les caches et redirections. | Octets différents, 404 ou mauvais build : suspendre la promotion ; ne pas signer de nouveaux octets par opportunisme. |
| Mise à jour Sparkle | Flux monotone, signature valide contre la clé embarquée, installation et ouverture sur un environnement de test expressément autorisé. | Ne pas considérer la présence du XML comme une mise à jour réussie. |
| Journaux | Copie synthétique conservée, nouveau lecteur accepte les anciens événements, inconnus restent bloqués. | Aucun nettoyage automatique pour faire disparaître UNKNOWN. |
| Licence | Santé HTTP puis activation/refresh/désactivation sur une licence de test dédiée autorisée ; valeur Keychain préservée si renouvellement échoue. | Le contrôle de santé seul ne clôt pas ce parcours ; ne pas consommer une activation cliente. |
| Services facultatifs | Seulement les parcours promis dans cette release, avec appareils/comptes autorisés ; refus visible en indisponibilité. | Pas de fallback vers un fournisseur payant ou de partage implicite. |
| Confidentialité et retour utilisateur | Texte public conforme au déploiement, support joignable, rapports expurgés et périmètre minimal. | Ne pas collecter automatiquement journaux de terminal, code, identifiants matériels ou credentials. |

Si le paquet doit être retiré, toute modification publique doit être explicitement autorisée. Retirer un téléchargement n'efface pas les installations déjà mises à jour et ne rend pas l'ancien lecteur compatible. Préparer un correctif en avant, conserver les preuves et annoncer des limites factuelles plutôt qu'un rollback non démontré.

Le détail des commandes de signature/export/DMG est maintenu dans [la revue distribution](../../audit-output/release-final-distribution-20260921.md), afin de ne pas créer une seconde procédure divergente.
