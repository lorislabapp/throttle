# Progression de la revue — 20 septembre 2026

**État final : revue documentaire terminée, aucune implémentation commencée.** Les checkpoints ci-dessous sont chronologiques et conservés ; leurs « prochaines étapes » historiques sont remplacées par ce statut. Livrables : [revue principale](../THROTTLE_RESEARCH_ARCHITECTURE_REVIEW.md), [sources/claims](SOURCES_AND_CLAIMS.md), [décisions](DECISIONS.md), [roadmap/expériences](ROADMAP_AND_EXPERIMENTS.md), [index de code](CODE_REFERENCES.md), [validation finale](validation.json).

Périmètre autorisé : lecture et livrables documentaires seulement. Aucun build/test, modification applicative/configuration, import DeepSearsh, compte ou dépense.
Baseline workspace : /Users/kevinnadjarian/GitHub/Throttle, feat/research-vault-lots-1-4, 32988f4fc99071a95b3684efa9684b57c7d6e810, préexistant ?? .throttle/. Comparer les branches cockpit 1ac0a32 + diff préservé, workflow-contracts b2d03c2 et macos27 6ed630f avant toute recommandation d’ajout.
Instructions contribution anciennes : Throttle Meter/21 tests/macOS ancien ; ne pas les confondre avec le produit courant. Skills sota-deep-research/deepsearsh lus ; leurs imports/rebuilds de corpus ne sont pas autorisés par cette mission et ne seront pas exécutés.

## Lectures
R1 intégral 1–755, R2 intégral 1–445, R3 intégral 1–1285. Autres inventoriés dans input-manifest.json, pas encore lus.
R1 est bien la revue hostile. R1 recommande 6 primitives plutôt que 19 composants. Citations opaques exportées sans résolution ; chiffres à rechercher. R1 présente un calcul indépendant 1000 actions explicitement illustratif, mais sa formule finale de utility multiplie encore des probabilités non justifiées : ne pas reprendre comme métrique.
R2 propose cinq agents (173–199) puis configuration adaptative (409–419), non étayée comme nécessité par les études de texte/QA. Retenir séparation du contexte/preuves et contrefactuels testables ; refuser cross-provider comme garantie. Seuil deux retries (388) déclaré proposition, pas résultat. Statique peut démontrer un défaut sans reproduction dangereuse : éviter exigeance universelle d’exploitation.
R3 routeur outcome+bandit trop précoce sans données ; garder filtre déterministe/privacy, versions, états indisponibles, coût terminal et sélection biaisée (795–824). Incohérence hiérarchie universelle tests>acceptation humaine (670–690) pour validité produit ; pas de hiérarchie hors proposition précise. Tarifs/modèles/Apple disponibles doivent être revalidés. Promesses Jev fournisseur seulement. Ne pas construire ModelAdapter si AgentRuntime/ModelProvider le couvrent.

## Recherche locale
Global RAG appelé limit=6, pistes ResearchVaultKit/XPC/raisonnement symbolique et release. Pas preuve indépendante. Index DeepSearsh Throttle disponible, choisir sources exactes après cartographie plutôt que recharger corpus.

## Prochaines étapes
Lire R4–R8 intégralement ; cartographier code/tests/main vs branches ; registre questions ; vérifier sources primaires prioritaires dont TypeSafe/YouTube ; décisions/contre-audit/roadmap ; contrôler références et absence de modifications produit.

## Checkpoint — audit et sources primaires
Les huit rapports ont été lus intégralement, par segments; toutes les lacunes de sortie tronquée ont été relues. Le manifeste porte COMPLETE pour R1–R8. R8 propose Temporal; cette prescription ne résiste pas à la présence de PlanStore et du release effect ledger dans C.

C = cockpit 1ac0a32 + diff préexistant; B = workspace 32988f4. C possède déjà WorkContract, EvidenceReceipt/VerificationContract, ReviewGate, BudgetAdmissionStore, PlanMCPAuthority et WorkflowReleaseLedgerStore. Ne pas reconstruire.

Constats statiques prioritaires: BashSandbox allowlist de binaires sans grammaire d'arguments; AssistantToolExecutor lecture HOME sans la même interdiction de secrets; CapabilityHostService build arbitraire de projet, validations plugins/macros désactivées, environnement hérité, tampon de sortie non borné pendant collecte, acquittement réseau ignoré. Même code B/C. PlanStore est coopératif et le dit; MCP legacy sans grant reste accepté. Vérification lie deux SHA mais empreinte untracked = noms seulement; résultat XCResult trouvé par mtime; merge par nom de branche après assessment. Runtime différent n'authentifie pas le reviewer. UI integrated → shipped.

SDK local Xcode27 27A266a, OS27 26A428; cible macOS app14, iOS17, visionOS26. FoundationModels PCC déclaré macOS27, indisponibilité/quota distincts. Pas d'inférence lancée.

Web: TypeSafe primaire (Choice/Score/Noul/confidence/state/models/jaggedness), Eigent anglais retrouvé; vidéo inaccessible et recherches ID sans transcription. Temporal idempotence, LangGraph persistence, Anthropic harness/sandbox, MCP security, AppleSDK/AX, SQLite, W3CPROV/SLSA, SDKs/frameworks, UTBoost, Guo2017, Kim2025, RouteLLM consultés. Premiers essais Jev externes trouvés mais corpus réduit et référence LLM; pas de calibration SDLC démontrée.

Prochaine étape: rédaction registres Claims/Decisions, revue principale, expériences et roadmap; contre-audit final documentaire. Aucun build/test/produit exécuté ni modifié.

## Checkpoint final — contre-audit documentaire

19 sections, 32 propositions examinées, 37 entrées de sources, 13 domaines complémentaires, décisions D01–18/D20, tranches S0–S5 et expériences E1–E4 rédigés. Références des fichiers abrégés résolues dans l'index ; originaux relus intégralement et empreintes recontrôlées.

Correction substantielle : F10 initial supposait un problème d'affichage depuis l'enum shipped. Lecture de FlowWording et du catalogue EN/FR : Integrated/Intégré et explication de fusion déjà corrects. Le renommage UI proposé a été retiré. Les checkpoints précédents ne constituent pas le verdict final. Les dépendances croisées D03/04/05/08/17/18 et D06/07/13 ont été distinguées entre prérequis minimaux et qualifications ultérieures pour éviter une roadmap circulaire. Le budget E3 inclut explicitement répétitions et retries dans son plafond.

Contrôles exécutés : intégrité SHA-256 des huit originaux et des snapshots de sources suivies B/C, état Git/HEAD, JSON, liens documentaires et index de code, espaces/conflits de diff. Aucun build, test applicatif, script de dépôt, appel de modèle, installation, restart, commit ou publication. Résultats détaillés dans validation.json. Une première génération d'index a refusé BackendCapabilityProfile.swift : il s'agit d'un symbole dans BudgetAdmissionModels.swift, corrigé dans l'index sans fichier inventé.

Limites : transcription YouTube inaccessible, bibliographie opaque partielle, aucune qualification actuelle de confinement/recovery/UX/appareils ou release. Les protocoles sont conçus, non exécutés.

Prochaine tâche : arbitrer les conclusions puis autoriser explicitement S1 dans un checkout choisi, avec périmètre et validations. Ne pas fusionner les worktrees ni reconstruire leurs capacités pendant cette revue.
