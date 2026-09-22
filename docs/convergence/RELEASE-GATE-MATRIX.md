# Throttle 3.8.0 — candidat installé 227, preuves historiques 226

État du 21 septembre 2026. **NO-GO distribution** tant que les gates bloquants ci-dessous restent ouverts. Cette matrice consolide l'état courant ; les rapports détaillés et les reçus historiques restent conservés. Un PASS porte uniquement sur la preuve et le périmètre indiqués, pas sur toutes les capacités de Throttle.

**Dernière actualisation : 22 septembre.** App **3.8.0 (227) installée** : signature stricte/Gatekeeper PASS, smoke6/6 PASS. Noyau source revalidé :369 PASS, aucune dérive depuis le reçu optimiseur. UI optimiseur encore incomplète ; DMG227 et reçus de build/signature Sparkle inaccessibles sans DeveloperStorage. [Reprise et preuves fraîches](CONTINUATION-227-20260922.md). **NO-GO publication** maintenu. Le tableau ci-dessous conserve les gates historiques226/227 du21 septembre ; les mentions disque/absence de binaire227 sont remplacées par cette actualisation, sans transférer au227 les preuves du226.

## Identité et périmètre

Worktree `build/convergence-recovery-20260920`, branche `codex/convergence-recovery-20260920`, base `1ac0a32f02f2cce9707779e41118ea39e7eb97d7`, modifications locales conservées. Le candidat Debug `100452` épingle **1 047 entrées sources/configuration**. Les documents de revue et leurs preuves sont exclus de cet inventaire de build.

Périmètre approuvé : [cockpit progressif pour projets de confiance](RELEASE-SCOPE.md). Pas de sandbox de code hostile, d'autonomie produit intégrale ni de garantie exactly-once. La plateforme d'exécution reste macOS ; la présence de slices Intel ne prouve pas un parcours sur Intel ou macOS 14.

Depuis le build100452, seules les fixtures HostedViewReview.swift et PlanIntegrationViewTests.swift ont changé : activation, montage NSHostingController et dimensionnement. Build121114 PASS, 1047 sources stables ; aucune source produit modifiée. Les preuves natives antérieures restent liées à leur fixture originale, les octets compilés ne sont pas supposés identiques.

## Gates de publication

| Gate | État et preuve acquise | Ce qui reste requis / responsable |
|---|---|---|
| G01 — sources, génération, qualité | **PASS local** : xcodegen après les ajouts Swift ; lint strict 0.63.2, zéro nouvelle violation, baseline conservée. [Reçu lint](evidence/final-release-20260921/swiftlint-receipt.json). | Toute modification applicative ultérieure invalide les preuves concernées ; revalidation différentielle puis candidat final. |
| G02 — logique et refus | **PASS local source227** :369cas,330XCTest+39SwiftTesting,98,058s,11nouveaux cas optimiseur. [Reçu](evidence/optimizer-20260921/core-final/receipt.json). | Ne certifie ni UI native, ni services réels ni confinement OS. |
| G03 — compilation courante | **BLOQUÉ avant lancement pour227** : espace système inférieur à2Gio. [Admission](evidence/optimizer-20260921/native-build-admission.json). Debug123340/archive124258 restent PASS historiques du226. | Compiler et qualifier227 ; ne pas installer226 en annonçant ces corrections. |
| G04 — native et langues | **PASS ciblé, régression de fixture résolue** :8/8 EN123427,8/8 FR123449,0échec/skip. Les deux captures UNKNOWN réussissent après conteneur explicite. [EN](evidence/release-finalization-20260921/isolated-functional-ui-tests-20260921-123427-summary.json), [FR](evidence/release-finalization-20260921/isolated-functional-ui-tests-20260921-123449-summary.json). Historique84 cas distincts conservé. | Services simulés, app hôte114759 + module XCTest123340, sources produit identiques ; pas de qualification des services réels. Échecs antérieurs conservés. |
| G05 — clavier critique / FQ-01 | **PASS borné aux fixtures** : Send/Stop antérieurement observés ; Retry revalidé sur la fixture finale123619, Tab/Espace/Tab. [Observations](evidence/release-finalization-20260921/keyboard-container-observations.json). XCTest1/1 PASS. | Navigation clavier OFF restaurée ; fixture sans worktree, pas de réparation Git réelle ou de qualification VoiceOver générale. |
| G06 — mise à niveau / FQ-02 | **PASS borné** : quatre scénarios avec les vrais lecteurs source 223/courant, octets préservés, ancien append refusé sur événement inconnu, retour courant conservant UNKNOWN et invalidant l'ancien check. [Reçu](evidence/release-continuation-20260921/two-reader-receipt.json). Aucun changement de schéma SQL dans la plage comparée. | [Récupération](RELEASE-RECOVERY.md) par correctif supérieur ; pas de downgrade automatique sûr. Pas d'installation historique ni d'identité établie avec le DMG public 223. |
| G07 — Claude / FINAL-NET-03 | **BLOQUÉ fournisseur** : demande humaine Anthropic `215476024504261`, selon message utilisateur ; aucune approbation reçue. Route inchangée en attendant. | Autorisation applicable, ou décision explicite de retirer/désactiver cette capacité avec traitement des préférences. Ni avertissement seul ni remplacement silencieux par une API payante. |
| G08 — confidentialité / FINAL-NET-01/04 | **PARTIEL** : flux source, backend local et [brouillon FR/EN](PRIVACY-PUBLIC-DRAFT.md). Décision utilisateur du 21 septembre : conserver LorisLabs / LorisLabs Team et `support@lorislab.fr`, sans ajouter son nom personnel. Choix de présentation clos ; identité juridique non confirmée, clarification différée. | Continuer la préparation avec cette présentation, sans redemander le même choix ni déclarer la conformité acquise. Rétention/effacement/déploiement et traitement des demandes restent à vérifier. Ajouter Throttle à la politique et adapter les conditions qui parlent seulement d’achats Apple malgré Stripe pour Throttle. |
| G09 — signature et paquet / FQ-07 | **PASS LOCAL** : archive124258,export125404,signatures strictes app/widget/helper/Sparkle,TeamTDV6D5L785,timestamps,hardened runtime,profils/CloudKit Production/App Group,absence de get-task-allow,slices arm64/x86_64. Contrôle statique dépôt6/6 PASS. DMG avant staple34 964 760octets (identité finale G11) ; copie/montage conformes. [Reçu](evidence/release-finalization-20260921/signed-export-125404/package-receipt.json). | Notarisation/Gatekeeper G12 distincts. Pas de runtime Intel/macOS14, CloudKit réel ni installation de ce paquet. |
| G10 — scripts de distribution | **PASS offline** : 10 tests publieur, 20 staging, 11 feed, 4 CI et 6 validateur de preuves. Pas de clé privée ni upload pour ces tests. | Les mocks/fixtures ne remplacent pas l'artefact signé, le serveur et la mise à jour réelle. |
| G11 — identité publique du candidat | **IDENTITÉ FINALE LOCALE ÉPINGLÉE** :3.8.0(226),DMG notarialisé34 967 080octets,SHA-256 `126c18b30dc187c71bdede756e6446ba9245dc002278bb601b64563efc6d1878`. | Feed à revalider au staging, numéro non réservé. Toute mutation DMG invalide la signature Sparkle. |
| G12 — notarisation / Gatekeeper | **PASS** : Apple Accepted,ID `eb6ffb07-5ee3-4a66-9713-a63acd7df982`,ticket staplé/validé,signature DMG valide,Gatekeeper `Notarized Developer ID`. [Reçu](evidence/release-finalization-20260921/signed-export-125404/notarized-package-receipt.json). | Ne prouve pas le parcours d’installation/mise à jour ou le fonctionnement de tous les services. Aucun app launch ni upload public. |
| G13 — Sparkle / staging / site | **PASS CRYPTOGRAPHIQUE LOCAL** :signature Ed25519 liée au DMG staplé et à la clé publique de l’export, avant/après copie. Feed frais:max223<226. Appcast/page/DMG stagés ;32 formulations et3 métadonnées ajustées, texte visible intégralement relu. [Revue du stage](evidence/release-finalization-20260921/signed-export-125404/stage-final-review.json). | Revue visuelle tentée mais bloquée par Safari privé verrouillé/outil UI ; mise à jour réelle NON EXÉCUTÉE ; confidentialité/conditions/Claude non clos. Revalider fraîcheur du feed et hash avant tout upload. |
| G14 — publication / après-release | **NON EXÉCUTÉ**. Aucun commit, push, upload public ou restart. | Accord précis sur artefacts et destinations ; vérifier ensuite octets servis, feed, caches et parcours de mise à jour. Responsable d'incident et réparation en avant documentés. |
| G15 — optimiseur / revue des parcours | **CORRIGÉ source+noyau** :settings déterministes sans modèle,IA instructions sur appareil uniquement,préférences préservées et gains inventés retirés.11cas avec doubles/sentinelles PASS. [Correctif](OPTIMIZER-HARDENING-20260921.md). | Build227 et parcours UI FR/EN restent à exécuter. Les constats du bilan décrivent l’avant-correctif. Mac→Mac natif reste une tranche séparée. |

## Limites à garder visibles, sans les confondre avec un défaut démontré

| Domaine / constats | Périmètre de la preuve | Condition pour promettre davantage |
|---|---|---|
| VoiceOver parlé / FQ-03 | Noms/rôles/états AX testés ; aucune validation des annonces vocales. Aucun nouveau toggle VoiceOver prévu. | Revue humaine ou outil capable d'observer les annonces. Un défaut concret bloquant Stop/consentement serait bloquant. |
| Rendu exhaustif / FQ-04 | Fenêtres réelles observées sur scènes synthétiques FR/EN ; PNG cacheDisplay défectueux non utilisés comme preuve d'une régression produit. | Matrice complète tailles/thèmes/écrans non exécutée. Ne pas annoncer une certification générale d'accessibilité. |
| Runtime Intel/macOS 14 | Cibles source et archives historiques universelles ; machine actuelle Apple Silicon/SDK27. | Essais sur environnement représentatif, distincts de lipo. Aucune suppression implicite du support Intel. |
| CloudKit / CLOUD-01/02/03, FINAL-NET-05 | Opt-in/compte/échec testés avec backend injecté ; la qualification de l'archive signée reste G09. Deux Macs peuvent cibler le même record, reprise de save après échec non qualifiée. | Compte/production, conflits multi-Mac, opt-out/suppression/réseau réels avec données de test autorisées ; aucune promesse de synchronisation garantie. |
| Compagnon, Keychain, fournisseurs / FQ-05 | Contrôle séparé du miroir ; tickets/révocations/callbacks et sauvegardes testés avec fixtures. Arrêt local distinct de l'arrêt de facturation. | Réseau TLS/appareil, Keychain et fournisseurs réels non qualifiés. Rester opt-in, sans fallback externe implicite. |
| Processus/NotebookLM / NET-06 | Timeout et annulation bornés sur fixtures ; réemploi ChildControl. | Service réel et descendants détachés restent hors preuve. Aucun nouvel appel distant ou installation pour cette release. |
| Autonomie / ARCH-01/02, SEC-01/02, FQ-06 | OID immuable et UNKNOWN réduisent des risques ; worker sous UID utilisateur, preuves modifiables au même UID, inputs non totalement figés. | Confinement effectif, journal/réconciliation de tous les effets, identité complète des entrées et tests adversariaux dans une tranche dédiée. Aucune formule « exactly once ». |
| Privacy manifest / SEC-03 | Écart documentaire macOS distinct des règles App Store d'autres plateformes. | Audit des compagnons avant soumission ; ne pas inventer une obligation de notarisation macOS à partir d'une règle iOS. |

## Constats corrigés et rattachement des preuves

- FINAL-NET-02 : identifiant matériel retiré d'OSLog ; inclus dans Debug `100452`.
- FINAL-NET-06 : réponse de credentials non imprimée ; tests publieur comprenant réponse partielle sensible PASS, sans secret réel.
- FINAL-NET-07 et SEC-04 : réemploi KeychainStore, pas de suppression avant sauvegarde, fixture compatibilité JSON et renouvellement échoué incluse dans les 358 cas. Le Keychain réel reste distinct.
- NET-01/05 : préférence explicite indisponible conservée, défaut/fallback sur appareil ; tests de politique PASS.
- NET-02/03/04 et UX-04 : tickets de contrôle, cancellation et diff erreur/retry corrigés ; contrôles natifs ciblés PASS, limites réseau/clavier ci-dessus.

Les rapports [réseau](../../audit-output/release-final-network-20260921.md), [UX/QA](../../audit-output/release-final-uxqa-20260921.md) et [distribution](../../audit-output/release-final-distribution-20260921.md) contiennent les chemins/symboles et critères détaillés. Les anciennes mentions « à exécuter » y sont historiques lorsqu'un reçu ci-dessus apporte le résultat.

## Ordre de clôture et arrêt utile

1. Clavier, archive, export, notarisation et staging local terminés : ne pas répéter ces opérations sans changement invalidant leurs preuves. Poursuivre la confidentialité et les validations finales du site et du parcours de mise à jour, dans les autorisations disponibles.
2. Conserver la présentation LorisLabs et le contact historique selon la décision utilisateur du 21 septembre ; clarification juridique différée, pas de conformité présumée. Vérifier les autres faits opérateur et décider la route Claude à partir de la réponse ou d'un arbitrage explicite. Tout changement source déclenche sa revalidation et une nouvelle identité d'artefact.
3. Après clôture des gates : revalider le candidat et le feed, obtenir l'accord public précis puis contrôler la publication. L'accord de notarisation déjà exécuté n'autorise ni installation ni publication.

La disponibilité d'un outil ou d'une identité de signature n'est pas une autorisation de publication. Jev, moteur de décision séparé, migration Super-Orchestrateur/SuperGateway et auto-modification ne sont pas requis pour cette release. Leur [roadmap](../research/throttle-review-2026-09-20/ROADMAP_AND_EXPERIMENTS.md) reste distincte.

## Dernière reprise — 21 septembre, 11:40

- Deux archives signées autorisées (111256,112754) interrompues par compilations tierces après75,592s et38,798s. Aucun PASS ni paquet signé qualifié ;1047 sources stables pendant ces tentatives. L'archive unsigned111137 a été arrêtée volontairement pour passer à la signature autorisée.
- Un cas XCTest existant répété deux fois (112157,112442) : **1 Passed,0failed,0skipped** à chaque fois,134,396s et182,841s. Ces succès ne valident pas Retry au clavier ; [observations et restauration OFF](evidence/release-finalization-20260921/keyboard-observations.json).
- Le témoin AppKit/SwiftUI reçoit Tab/Espace et incrémente les compteurs. Les fenêtres produit activent explicitement l'app ; la fixture ne le faisait pas. Correction limitée à cette fixture, hypothèse à revalider au runtime. Aucun bouton ni logique produit modifié.
- Brouillons [site v2](evidence/release-finalization-20260921/website-copy-v2-manifest.json) et [notes FR/EN HTML](evidence/release-finalization-20260921/release-notes-draft.html) prêts pour revue, non stagés/non publiés.
- À11:37,1,7Gio libres, inférieur au seuil de build. Le contrôle automatique a refusé avant exécution le déplacement de deux caches supplémentaires. Accord précis demandé ; aucun de ces chemins modifié.
- Prochaine action : espace suffisant, build de la fixture, hôte interne distinct, essai clavier et restauration, puis archive signée/export/DMG. Les autorisations locales précises reçues persistent ; ne pas les redemander. Les uploads gardent leurs gates propres.

## État courant après déplacement autorisé — 21 septembre,12:03

**Déplacement terminé**, aucun accord supplémentaire à demander pour ces deux caches. ResearchVaultKit :9331 entrées ; ThrottleShared :5113 entrées. Contrôles lsof, empreintes/modes/liens avant/après, copie externe et ancien chemin par symlink, puis retrait des seuls doublons validés. [Reçus Vault](evidence/release-finalization-20260921/workflow-vault-cache-relocation.json) et [Shared](evidence/release-finalization-20260921/workflow-shared-cache-relocation.json). Environ1Gio libéré ; l'espace global a ensuite baissé jusqu'à994Mo à12:00. Ne pas attribuer cette baisse à une application précise sans preuve.

Build114759 PASS32,507s, puis115329 PASS16,328s,1047 sources sans dérive. Seuls HostedViewReview et PlanIntegrationViewTests diffèrent de100452 ; aucune source produit modifiée. Lint global strict PASS854fichiers, règles/baseline inchangées.

Le test diff EN114959 termine PASS(1cas,0échec/skip),126,056s. Son diagnostic confirme active=true,key=true,keyboard=true mais responder=NSWindow après Tab. L'activation seule ne résout donc pas le focus. La seconde fixture reprend le montage NSHostingController et les styles initiaux du vrai cockpit ; un message synthétique distinct rendra l'effet de Retry observable. Elle compile dans115329 mais son runtime n'est PAS exécuté : toutes les préparations de copie/clone suivantes se sont arrêtées à leurs assertions préalables, avant création d'un nouvel hôte, faute de réserve disque.

L'hôte114859 reste préservé ; il n'est pas celui de la dernière fixture. Navigation clavier OFF restaurée. Aucun xcodebuild détenu encore actif, aucun restart installé, aucune archive signée terminée ni DMG créé. L'accord de signature locale persiste.

**Prochaine tâche** : disposer d'un espace libre stable (marge opérationnelle recommandée5Gio, gate de build2Gio), préparer le module de test115329 dans un hôte interne distinct, tester le clavier puis archive/export/DMG sur un créneau exclusif. Reprendre les gates fournisseur/confidentialité et les accords d'envoi seulement après artefact qualifié.

## État courant — 21 septembre, 12:22

- Déplacement autorisé achevé :14 444 entrées préservées et vérifiées, anciens chemins symlink toujours valides.
- Build121114 PASS16,375s,1047 sources stables ; lint ciblé des deux fixtures PASS. Aucun nouveau fichier de projet, pas de xcodegen supplémentaire nécessaire.
- Retry clavier120437 PASS borné : Tab/Espace/Tab observés ; test XCTest1/1 PASS et résultat xcresult extrait. Navigation clavier OFF restaurée. Aucun VoiceOver ni restart installé.
- Régression120630 :6/8 PASS,2 captures UNKNOWN FR/EN en échec ; résultat xcresult conservé. Correctif sizingOptions compilé121114, runtime NON EXÉCUTÉ. Les deux préparations d'hôte ont été refusées avant création/copie par le seuil disque, sans baisser la réserve.
- Archive signée121313 : **interrupted-concurrency**, exit -15,470,634s,1047 sources sans dérive. Un xcodebuild tiers75289 déclenche l'arrêt de notre enfant seulement. Aucun échec de compilation observé ne vaut PASS ; ni export ni DMG qualifié.
- À12:21:49,1 331 200 000 octets libres : sous le seuil d'admission2Gio. Ne pas relancer en boucle. Aucun nouveau cache déplacé ou supprimé.

[État et reçu d'archive](evidence/release-finalization-20260921/resume-1222-state.json). Prochaine tâche : réserve disque stable et aucun xcodebuild tiers, préparer l'hôte121114 via `build/convergence-validation-20260920/throttle-prepare-sizing-host.py`, lancer `run-sizing-functional-ui-tests.py en` puis `fr`. Le script de préparation garde son seuil et épingle les sources ; les runners sont créés uniquement après succès. Puis archive signée via runner existant, export et qualification locale. Helpers préparatoires conservés dans le dossier validation (`throttle-export-approved.py`, `throttle-qualify-signed-app.py`), **non exécutés**. Signature/DMG déjà autorisés ; uploads toujours distincts. G07/G08 nécessitent encore les faits fournisseur/opérateur.

## Reprise à partir du paquet —21 septembre,12:59

Le [candidat exact](evidence/release-finalization-20260921/release-candidate-3.8.0-226.json) remplace les mentions historiques d’archive/DMG en attente. Tests ciblés, clavier et paquet local qualifiés. Les deux opérations restant externalisées sont la notarisation Apple (accord précis demandé, non reçu à cet enregistrement) et la publication (aucun accord sur le stage final). Après accord notary, envoyer ce DMG une fois, conserver l’ID opaque, réconcilier tout résultat inconnu avant une nouvelle soumission, puis staple/Gatekeeper. Recalculer le hash après staple avant signature Sparkle et staging. Aucun app launch implicite.
