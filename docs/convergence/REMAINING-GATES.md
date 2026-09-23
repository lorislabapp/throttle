# Convergence — limites et suite de l'implémentation

Cette page décrit ce qui reste à construire ou à vérifier. Ce ne sont pas des résultats exécutés. L'autorisation d'implémenter le plan reste bornée par ses exclusions ; elle n'autorise pas installation, restart, déploiement ou publication.

## Distinction release progressive / ambition ultérieure

La décision utilisateur est consignée dans [RELEASE-SCOPE.md](RELEASE-SCOPE.md). Les lots ci-dessous décrivent la qualification de l’autonomie complète ; leur non-achèvement ne bloque pas automatiquement la release du cockpit pour projets de confiance. Les garanties manquantes restent explicitement hors périmètre. Les gates actuels du candidat sont compilation/tests, UX/AX, erreurs et consentements visibles, puis artefact/distribution dans leur phase autorisée.

## Lot 1 — preuve locale et limites

Le code de lecture s'appuie sur un descripteur de racine ouvert par le contrôleur, puis `openat` avec `O_NOFOLLOW` pour chaque composant. Le refus d'un root remplacé repose sur son identité inode/device. Les lectures refusent fichiers spéciaux et hard links ; les octets, entrées, profondeur de recherche, fichiers, résultats et appels sont bornés. Les tests de race sont des observations adversariales limitées, pas une preuve formelle contre toutes les interleavings.

Les refus de chemins sensibles et `OutboundPolicy` ne sont pas une garantie de détection de tous les secrets d'un projet. L'utilisateur doit encore autoriser le fournisseur qui reçoit du contexte ; la politique de fallback/confidentialité reste une autre frontière. Les noms d'outils typés ne donnent aucun droit d'écriture. Les fichiers retournés sont marqués comme données non fiables.

Les adaptations Apple Intelligence sont compilées et exercées directement par les tests quand le SDK est disponible ; aucun modèle n'est invoqué. L'UI utilise un `TaskLocal` pour garder la même racine et les cinq appels sur les récursions et fallbacks d'une requête. La validation de syntaxe ne remplace pas une compilation UI et un parcours d'app installé.

## Lot 2 — sous-tranche durable livrée, fermeture encore ouverte

`PlanStore` reste le journal et le propriétaire des transactions. Les intentions `verification_started` portent UUID, fence (séquence du journal), auteur, mission, empreintes d'entrée/commande et expiration. Elles sont persistées avant la commande. Le résultat doit correspondre à cette intention ; un résultat tardif après expiration est incomplet. Une intention non acquittée reste UNKNOWN après réouverture et expiration et bloque la relance. Le rebase et l'entrée UI d'intégration refusent une intention déjà présente. Ce précontrôle **ne sérialise pas atomiquement tous les effets Git** contre une nouvelle vérification concurrente.

`acknowledgeStoppedExecution` exige un observateur et une référence distincte d'arrêt ; il ne certifie rien et ne relance rien. **Le service fait confiance au contrôleur appelant pour vérifier cette observation.** L’identité du root est désormais persistée avant libération du pipe privé et diagnostiquée via MCP. Aucun inventaire durable exhaustif des descendants ni parcours GUI de reprise n’est livré. L'expiration seule n'est jamais considérée comme une preuve d'arrêt. Deux tests provoquent désormais la mort réelle d'un contrôleur synthétique avant libération du pipe. La récupération après exécution du projet et avec descendants survivants reste à qualifier.

Les outils MCP de tâches et d'intake imposent un grant explicite. `bootstrap` et `research` sont des capacités distinctes, non émises par défaut aux workers. L'autorité admise est épinglée pour la requête, relue après verrou et avant append. Claim et événements portent grant/mission ; un ancien grant du même auteur est refusé après une nouvelle mission, y compris avant l'acquittement d'un retry. Les anciens claims sans cette identité ne sont pas automatiquement réattribués : ils nécessitent une nouvelle prise en charge de confiance. Les appels Swift directs sont une frontière de confiance interne, pas une permission accessible au modèle.

Le dossier de recherche utilise le verrou de projet existant, une lecture stricte bornée et une écriture atomique synchronisée. Corruption, symlinks, hardlinks, FIFO et dépassement de taille sont refusés ; les writers concurrents conservent les contributions. La méthode legacy `load` conserve un fallback vide, mais les seuls call sites applicatifs trouvés utilisent `loadValidated`; aucun affichage GUI silencieux de corruption n'est démontré dans ce chemin. Les contrôles de chemins de ce store ne constituent pas une isolation OS contre un autre processus hostile du même UID.

Travail restant pour fermer le lot 2 :

- Étendre l’identité durable du root à la réconciliation des effets et descendants, à l’annulation et à la reprise après crash réel et plusieurs jours. Garder UNKNOWN quand l'arrêt ne peut être prouvé ; ne pas fournir un bouton de retry aveugle.
- Définir et tester l'admission commune aux effets Git et à la vérification, sans verrou global tenu pendant une commande longue. Journaliser aussi les effets de lancement/worktree : la présente intention ne couvre que la vérification.
- Qualifier le confinement réel des commandes sur fixtures : réseau, fichiers hors racine, descendants et altération des grants/évaluateurs. Aucun XPC/VM/binaire Rust/exécuteur Node qualifié n'a été installé. Un grant sous le même UID n'isole pas le worker.
- Fermer la fenêtre de révocation entre relecture et effet ; aucun mécanisme actuel ne prétend révoquer atomiquement un processus déjà lancé.
- Compiler l'application et tester `TaskLauncher`, l'UI et les sessions MCP réelles. Les capacités d'intake n'ont pas encore de parcours d'allocation GUI. Ne pas redémarrer l'app ici.

Compatibilité : les champs optionnels préservent la lecture des anciens journaux par ce code ; les nouveaux types d'événements ne sont pas lisibles par un ancien binaire. Un retour arrière doit conserver les journaux et bloquer les tâches concernées, jamais supprimer les intentions ou convertir UNKNOWN en réussite.

Critère pour lot 3 : effets admis de façon bornée, résultat observé ou explicitement inconnu, récupération vérifiée. La sous-tranche présente établit une partie de ce contrat, elle ne ferme pas la porte à elle seule.

Voir [PROCESS-RECOVERY.md](PROCESS-RECOVERY.md) pour la nouvelle sous-tranche, les sources primaires et la fermeture du cas de crash avant autorisation et les effets restant inconnus après autorisation.

## Lots 3–7 — non implémentés dans cette tranche

| Lot | Première opération nécessaire | Critère avant extension |
|---|---|---|
| 3 Preuves/Git | Remplacer le digest de seuls noms non suivis par un sujet de vérification complet ; journaliser/réconcilier la transition (OID intégré désormais immuable) | Tests de mutation après check, artefact périmé, base/task déplacés, merge réussi sans ACK et append refusé ; aucun merge dans les dépôts de l'utilisateur |
| 4 Gateway optionnel | Qualifier versions/runtime/auth/protocole et réparer les scripts générés avec artefacts immuables | Local utilisable sans Gateway ; tests de handshake par version, auth, timeout et provenance. Aucun déploiement |
| 5 Review/cockpit | Identité réelle du reviewer et portée de preuves ; réutiliser spend/inventaire existants | Scénarios UI/AX EN/FR, self-review refusée sur identité/contrat, preuves obsolètes visibles |
| 6 Cycle produit | Exercer un parcours besoin → preuve indépendante → éligibilité release | Besoin satisfait, DoD multidimensionnelle ; publication toujours distincte et non automatique |
| 7 Mesures | Baseline représentative incluant échecs et annulations | Coût par tâche acceptée, défauts échappés et latences ; observations avant Jev/routage adaptatif ; budget explicite pour appels payants |

Aucune migration des historiques/secrets de Super-Orchestrateur ou SuperGateway n'est nécessaire pour ces portes. Une éventuelle copie de code Rust devra d'abord qualifier sa licence par composant et ses dépendances. La revue documentaire conservée contient les recherches et alternatives ; ce fichier ne les transforme pas en intégrations existantes.
