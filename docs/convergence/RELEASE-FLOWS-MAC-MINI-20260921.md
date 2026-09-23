# Publication, parcours, optimisations et Mac mini — 21 septembre 2026

## Décision actuelle

Le candidat 3.8.0 (226) est notarisé, mais **la publication générale reste NO-GO**. Le périmètre reste le cockpit pour projets de confiance. La migration Mac mini, Jev et le lab autonome complet ne sont pas des conditions supplémentaires pour cette petite release. Ils ne sont pas non plus des capacités qualifiées du candidat.

La [matrice de release](RELEASE-GATE-MATRIX.md) conserve les preuves de compilation, tests, Apple et Sparkle. Ce bilan ajoute les parcours oubliés et prépare le serveur ; il ne remplace pas les reçus historiques.

Matériel annoncé par l'utilisateur : **Mac mini M5 Pro, 64 Go, SSD 1 To**, attendu mercredi 23 septembre. Configuration déclarée, non inspectée : CPU/GPU exacts, macOS, SSD disponible et performances restent à relever sur la machine.

## Périmètre de cette revue

Lecture de la matrice, du handoff du 18 septembre, du backlog historique, des sources/test fixtures ciblées et de la roadmap. Deux revues indépendantes bornées : parcours et remote. Conclusions ci-dessous recoupées avec les call sites. Aucun build, test applicatif, appel fournisseur, SSH, achat, transfert, installation, restart ou publication pendant ce bilan. Aucune lecture de contenu de fichiers de credentials, de settings privés ou de conversations.

Worktree audité : `build/convergence-recovery-20260920`, branche `codex/convergence-recovery-20260920`, HEAD `1ac0a32f02f2cce9707779e41118ea39e7eb97d7`, diff local préservé. Ce HEAD seul ne décrit pas le candidat compilé : ses modifications locales sont essentielles.

Contrôle actuel du DMG : 34 967 080 octets, SHA-256 `126c18b30dc187c71bdede756e6446ba9245dc002278bb601b64563efc6d1878`, identique au reçu Apple/staple conservé. Aucune nouvelle notarisation. Aucun feed distant relu dans ce bilan ; fraîcheur à vérifier avant publication.

## Parcours : présent ne signifie pas qualifié de bout en bout

| Parcours | État établi | Vérification restante |
|---|---|---|
| Première ouverture → projet → plan → tâche | Onboarding et navigation présents ; logique testée historiquement (`CockpitOnboarding`, `CockpitOnboardingTests`) | Première installation réelle et parcours complet jusqu'à décision |
| Cockpit → coûts → agents externes | Réemploi TaskSpend, StatsDataService, ClaudeAgentInventory ; vues/coûts inconnus testés | Sessions/threads réels ; valeur API-équivalente distincte de facture et abonnement |
| Assistant → provider → Stop | Politique sans fallback cloud implicite et scènes EN/FR testées | Service réel, autorisation Claude web ; Stop ne prouve pas arrêt distant |
| Vérifier → diff/retry → intégrer | OID Git immuable, UNKNOWN non relançable, scènes et clavier testés | Crash après effet Git, entrées complètes figées, satisfaction du besoin indépendante |
| Achat → email → activation → refresh → désactivation | Code licence et fixtures Keychain | Parcours serveur réel, statut du backend, conservation et effacement ; aucune transaction réelle faite |
| Optimizer → proposition → diff → Apply/backup | Éditeur, Quick wins et hooks présents | Confidentialité de l'entrée, recommandations exactes, restore et concurrence sur fichiers réels : voir O01/O02 |
| Recherche → import → coffre → rappel → NotebookLM | Stores/limites et services présents | Clean install du helper, dossier illisible, service réel ; ne pas généraliser les tests du cockpit |
| Déport session → reprise → retour | Journal, Git/transcript, réconciliation et fixtures présents | Aller-retour réseau ; backend durable actuel Linux, pas macOS natif |
| Miroir compagnon → contrôle séparé → révocation | Permissions/tickets et CloudKit simulés testés | Deux Macs, appareil physique, changement de compte, réseau, suppression réelle |
| DMG → installation → Sparkle → reprise du travail | Signature/notarisation/stage qualifiés | Installation/mise à jour réellement exécutée, site rendu et contrôle des octets publics |

Preuves déjà consignées, **pas réexécutées ici** : 358 cas noyau, couverture native historique 84 cas distincts, 8 cas UI répétés EN/FR puis un cas clavier, archive/export et 6 contrôles statiques. Aucun total artificiel de tests uniques à partir de répétitions. Références exactes dans la matrice.

## Points oubliés retrouvés et acceptation minimale

### O01 — HIGH : entrée sensible de l'optimiseur

Chemin vérifié : `Throttle/UI/ProjectWindow/ProjectOptimizerTab.swift:26-29,255-268` permet `settings.local.json` et transmet `originalContents` ; `Throttle/Services/AIOptimizerService.swift:65-76,91` l'insère entier dans le message et appelle le provider. `ClaudeAPIKeyProtocol.swift:40-76` conserve le texte ; `ClaudeAPIKeyProvider.swift:96-108` construit et envoie la requête. Aucun filtrage de secrets identifié dans ce chemin. Le prompt conseille en outre de mettre les secrets dans `settings.local.json` (`AIOptimizerService.swift:50`).

Le choix distant est explicite : `AIProviderRegistry.swift:64-88` empêche l'escalade réseau implicite. Cela ne retire pas les secrets d'un fichier sélectionné. **Risque confirmé par lecture du chemin de données, pas fuite observée ni appel réellement effectué.** Le diff avant Apply arrive après la génération, donc ne constitue pas un consentement préalable à transmettre son contenu.

Remédiation minimale proposée avant publication : garder l'édition/Quick wins déterministes ; refuser la génération distante pour le fichier local sensible et définir un dossier d'entrée sûr pour les autres configurations. Ne pas promettre qu'une regex reconnaît tous les secrets. Afficher la destination avant l'appel ; ne pas restaurer silencieusement les valeurs masquées depuis une réponse LLM. Supprimer le conseil de stockage de secrets dans le prompt.

Acceptation : faux provider capturant les requêtes et sentinelles synthétiques dans clés/valeurs/hooks ; zéro sentinelle sensible envoyée, refus sans appel réseau, proposition/diff/backup encore utilisables, choix de provider inchangé. Les fichiers sensibles peuvent rester en mode déterministe. Tests NON EXÉCUTÉS.

### O02 — MEDIUM : économies annoncées et intentions modifiées

`AIOptimizerService.swift:46-51` et `SettingsAuditService.swift:59-71` présentent des ratios « 90 % », « 1/5 », « 40 % » sans baseline Throttle correspondante. Quick wins propose aussi `alwaysThinkingEnabled=false` quand l'utilisateur l'a explicitement activé, malgré le commentaire de préservation des valeurs (`SettingsAuditService.swift:32,68-70`). C'est une proposition soumise à Apply, pas une écriture automatique ; elle doit néanmoins être décrite comme un arbitrage qualité/coût, pas un durcissement systématique.

Remédiation : retirer ratios universels, préserver la préférence explicite, présenter modèle/effort comme choix séparés, ne pas appeler une règle Read une isolation système. Le coût API-équivalent n'est pas une économie d'abonnement. Acceptation : fixtures conservent les choix explicites ; bénéfices chiffrés seulement depuis mesures reproductibles. Aucun correctif applicatif effectué dans cette revue.

### R01 — compatibilité macOS du serveur distant

`edge-agent/transfer-runtime.mjs:248-254` refuse les plateformes autres que Linux et dépend de cgroup/systemd ; `fresh-runtime.mjs:81-105` réutilise ce backend. `edge-agent/README.md:3` annonce pourtant Linux/macOS. `ThrottleShared/Sources/ThrottleShared/EdgeAgentService+Deployment.swift` et `SessionOffloadSheet.swift` ciblent un déploiement Linux/Proxmox. Ne pas lancer cet installateur sur le mini.

Terminal cockpit présent (`RemoteSessionPane.swift:31-58`), sans verrou biométrique Mac malgré une ancienne mention README. Le transfert Claude/Codex possède une limite de transcript strictement inférieure à 128 Mio (`RemoteSessionsService+Transfer.swift:84-101`), indépendante des 64 Go de RAM.

Verdict : interface/capacités présentes, **pas de backend de transfert natif macOS qualifié**. Corriger les revendications et tester l'indisponibilité sur macOS ; l'adaptateur macOS durable est une tranche séparée, pas une raison de construire une architecture distribuée entière.

### D01 — documentation historique et preuves

`docs/BACKLOG.md:3-5` est explicitement archivé. Les cases cochées de ce document et les anciens checkpoints de TODO ne valent pas validation 226. Pour la release : matrice courante. Pour l'ambition : [roadmap](../research/throttle-review-2026-09-20/ROADMAP_AND_EXPERIMENTS.md). Les anciennes demandes de notarisation ne doivent plus être rejouées.

## Optimisations à garder, qualifier ou différer

- **Garder et requalifier sur échantillon** : TaskSpend/StatsDataService, mesure cache et contexte, TokoptHook, ContextTrimmerService, BrevityHookService, pause/reprise et détection de boucles existantes. Présence source/historique distincte d'un gain mesuré aujourd'hui. Les compressions doivent garder erreurs, preuves et restauration ; pas de nouvelle réécriture silencieuse des transcripts.
- **Corriger maintenant avant promesse de publication** : O01/O02. Tester aussi consentement hooks, Apply/backup/restore et fichier changé pendant proposition.
- **Mesurer sur mini** : modèle/quantification/contexte, chargement froid/chaud, keep-alive, mémoire et concurrence avec build. Réutiliser `LocalWorkerRouter` et le serveur configuré, pas un deuxième routeur. Le chemin résumé existant plafonne le contexte à 16 384 et la réponse à 768 tokens ; cela ne décrit pas toute session interactive et 64 Go ne change pas ces limites automatiquement (`LocalWorkerRouter.swift:343-425`).
- **Différer** : Jev, routage appris, gains de compression avec perte, fusion SuperGateway/Super-Orchestrateur. Baseline coût/quota par tâche acceptée avant optimisation adaptative. Déplacer ces dépôts sur une autre machine n'est pas les intégrer dans Throttle.

La documentation Anthropic actuelle distingue consommation de quota d'abonnement et estimation au tarif API ; elle propose contexte, modèle, hooks et outils ciblés, sans prouver les gains particuliers de Throttle. [Source primaire, relue le 21 septembre](https://code.claude.com/docs/en/costs).

## Inventaire de migration réellement effectué

Inventaire limité aux entrées immédiates de `~/GitHub` contenant `.git` : **135**, pas 135 dépôts indépendants garantis, ni audit récursif complet. Lecture des métadonnées de trois projets seulement ; aucun contenu privé envoyé au web.

| Projet | Snapshot observé | Implication |
|---|---|---|
| Throttle principal | `32988f4`, `feat/research-vault-lots-1-4`, 0 modification suivie au principal, 15 entrées worktree dont 2 signalées prunable | Le candidat est dans un autre worktree sale. Des worktrees sont hors `~/GitHub`. Aucun prune ni nettoyage effectué. Le statut `-uno` ne couvre pas les fichiers non suivis. |
| Super-Orchestrateur | `7d1a644`, `endgame/phase-5-production-release`, 36 entrées suivies modifiées | Cloner GitHub seul perdrait ces modifications. Aucun diff de contenu inspecté ici. |
| SuperGateway | `f61e761`, `main`, 4 entrées suivies modifiées | Même réserve ; ni fusion ni migration produit décidée. |

Les caches Throttle et artefacts préservés sur `/Volumes/DeveloperStorage` créent des dépendances externes au dossier GitHub. Relever les liens sans les suivre aveuglément. Git bundle transporte objets/refs ; les métadonnées de worktrees dépendent de leurs chemins. [Git bundle](https://git-scm.com/docs/git-bundle), [Git worktree/repair](https://git-scm.com/docs/git-worktree), relus le 21 septembre.

`RemoteTransferGit.swift:17-70` sait capturer un arbre dirty via index privé et ref de transfert sans toucher l'index utilisateur. Cela n'est pas un export intégral de toutes branches/stashes/worktrees/objets LFS/sous-modules/secrets. Les fichiers ignorés ne sont inclus que selon `.throttleinclude` ; ne pas y ajouter globalement les secrets.

## Plan Mac mini M5 Pro / 64 Go / 1 To

### M0 — préparer sans déplacer

Inventaire exhaustif à compléter après choix des premiers projets : HEAD/branches/refs locales non poussées/stashes, worktrees et chemins communs, index/staged/unstaged, non suivis et ignorés nécessaires, sous-modules/LFS, sessions actives, liens externes. Consigner un handoff par tâche (objectif, faits, preuves, commandes, blocages, prochaines actions) et un manifeste de fichiers. Ne pas copier les jetons dans ces documents. Préserver sauvegarde complète et source ; ne pas nettoyer avant migration. Priorité proposée : un dépôt pilote de confiance, puis Throttle et autres dépôts actifs, archive à la demande.

### M1 — mercredi : machine native accessible

Relever matériel effectif, OS, Xcode/SDK/CLI, versions Git/Node/Swift, SSD libre et réseau. Installer/configurer seulement après autorisation portant sur ce Mac. SSH natif avec accès limité et clés de machine vérifiées ; transport privé (tunnel SSH ou réseau privé existant), sans port Ollama ouvert à Internet. [Apple Remote Login](https://support.apple.com/en-euro/guide/mac-help/mchlp1066/mac). Un compte autorisé suffit ; pas d'accès disque complet automatique.

Architecture initiale : MacBook pilote, mini exécute les CLI officielles et builds natifs ; partage d'écran pour les parcours graphiques lorsque autorisé. Une connexion SSH n'emporte ni session graphique, ni permissions TCC, ni clés de signature. Tester reboot et récupération avec FileVault ; ne pas désactiver FileVault ni activer autologin pour simuler du headless fiable.

### M2 — dépôt pilote et reprise du travail

Figer les writers du projet avec coordination, sauvegarder, copier vers un emplacement neuf ; préserver objets/refs, changements staged/unstaged, fichiers non suivis sélectionnés et dépendances. Recréer les worktrees et remapper les chemins, comparer état Git et empreintes, vérifier sous-modules/LFS. Aucun push nécessaire pour préserver du travail local. Pas de synchronisation bidirectionnelle automatique de `.git` ou des bases de sessions vivantes.

Reprise préférée : nouvelle session CLI avec handoff vérifié. Une reprise du même identifiant exige support de la version CLI, transcript exact, chemins compatibles et test d'identité/contexte ; elle n'est pas garantie pour toute session. Authentification sur le nouveau Mac via mécanismes officiels ; aucun export automatique de cookies, Keychain ou tokens. Un seul writer actif par tâche. La machine source reste intacte jusqu'à build/test et retour des changements réussis. Rollback : fermer le writer distant après état connu, conserver ses différences, revenir au poste source ; jamais écraser les deux versions divergentes.

### M3 — inférence locale privée et ressources

Ollama natif macOS comme premier chemin à qualifier, déjà consommable par Throttle ; MLX existant garde son rôle local. Pas de VM Linux imposée : elle ne remplace pas Xcode/macOS, et la documentation Ollama ne fournit pas d'accélération GPU sous Docker Desktop macOS. Configuration proposée, non appliquée : modèles locaux uniquement (`OLLAMA_NO_CLOUD=1` si version compatible), loopback via tunnel, un modèle chargé et une requête au départ. La mémoire augmente avec contexte et parallélisme : ne pas déduire un nombre de workers du seul chiffre 64 Go. [Documentation Ollama](https://docs.ollama.com/faq).

SSD 1 To : sources et travail actif prioritaires ; DerivedData/caches recréables séparés, archives/preuves préservées et rotation après vérification. Taille des données à mesurer avant choisir ce qui migre ; aucune promesse que tout le portfolio tient. Garder une réserve d'espace et un budget mémoire pour OS/build/tests ; seuils à mesurer, pas de tuning système aveugle.

Baseline proposée NON EXÉCUTÉE : 10 tâches synthétiques/publiques fixées (lecture, diagnostic build, patch court vérifié), zéro service payant. Mesurer réussite indépendante, erreurs, cold/warm/p95, mémoire/swap, GPU et file d'attente. Comparer modèle seul, build seul, puis coexistence avec un seul xcodebuild ; conserver de la capacité pour vérifier. Échec/annulation inclus. Augmenter modèle/contexte/parallélisme seulement si qualité et latence utile s'améliorent sans épuisement mémoire. Pas de choix de modèle « optimal » annoncé avant essai sur la machine.

### M4 — sessions intégrées dans Throttle

Réutiliser contrat, journal, transfert Git, retour et UI. Ajouter un backend macOS seulement après qualifier ownership, arrêt de descendants, persistance, admission et réconciliation après reboot ; launchd seul ne remplace pas cgroup ni ne prouve l'arrêt. Critères : départ/retour avec modifications non commitées, conflit local préservé, réseau coupé avant/après ACK, stop tardif, reboot, credentials révoqués, transcript trop grand. Pas de doublon ni retry aveugle sur résultat inconnu. Sans ce backend, SSH/CLI natifs restent un mode opérationnel séparé ; bouton Mac→Mac non annoncé comme disponible.

## Ordre concret de clôture

1. Traiter O01/O02 et annoncer correctement la compatibilité remote ; qualification synthétique avant nouvel artefact si code modifié. Le DMG 226 notarisé ne change pas silencieusement.
2. Fermer G07 Claude selon réponse Anthropic ou choix explicite de retrait ; conserver LorisLabs/support conformément au choix reçu. Définir/vérifier les faits restants de conservation/effacement et le texte de vente directe.
3. Parcours d'acceptation installé/mise à jour autorisé, projet jetable de confiance : ouvrir → plan → exécuter → observer coût/état → Stop → vérifier/décider → erreur/UNKNOWN → reprise. Licence avec fixture ou compte de test autorisé, jamais achat réel implicite. Site rendu et liens finaux.
4. Requalifier artefact final si corrections, feed frais, autorisation exacte de publication puis vérification publique. Le Mac mini ne bloque pas cette release.
5. Mercredi : M1/M2 pilote, M3 mesures, M4 dans une tranche ultérieure si nécessaire. La fusion des trois produits reste une décision distincte.

Ce bilan ne certifie ni tous les flows ni une optimisation universelle « SOTA ». Son résultat utile est une liste de limites reproductibles, un ordre de correction et une bascule récupérable.
