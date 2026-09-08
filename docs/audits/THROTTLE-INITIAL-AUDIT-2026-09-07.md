# INDEPENDENT APPLE APP AUDIT & MONETIZATION REPORT

AUDIT-MANIFEST

- Audit FULL initial consolidé par Codex ; contre-revue indépendante initiale par Lovelace. Ce rapport précède la remédiation et ne vaut pas revue finale G9.
- Projet : `/Users/kevinnadjarian/GitHub/Throttle/build/cockpit-maintenance`, branche `fix/cockpit-state-observation`, HEAD `cc40cfb8125d8d05256b3ee8a9e7c385de95aebb`.
- SNAPSHOT-START : `2026-09-07T17:39:24.541307+00:00`.
- SNAPSHOT-END : `2026-09-07T17:58:41.739036+00:00`.
- Diff suivi inchangé : `e8420694939ae36e4d8ada0b12a4ff27fa677b4c0d6671e445c4bd2d6462102e` ; index vide. Deux fichiers modifiés et trois fichiers non suivis préexistants au snapshot : baseline, MultiCockpitRoot, SessionStateDot, ses tests et handover Codex. L'audit n'a pas modifié le produit. Rapports écrits après END.
- Environnement : macOS 27 beta / Xcode 27 beta ; canal macOS Developer ID. SwiftLint 0.63.2. L'app de travail installée est distincte de la source auditée et de la 3.5.2 publiée.
- Caches et tests : `/private/tmp`, copie isolée du package Vault ; le vérificateur de frontière de dépendances a produit un cache manifeste ignoré. Saturation du disque pendant les tests ; cache Vault récupéré, puis suppression autorisée de 1,7 Go d'intermédiaires Éclair inactifs. 2,7 Go libres à END : capacité de release encore à sécuriser.

Valid for SNAPSHOT-END at 2026-09-07T17:58:41.739036+00:00

## EXECUTIVE VERDICT

**NO-GO — remédiation produit et qualification requises.** Quatre P1 confirmés par inspection indépendante concernent la continuité des conversations, l'exclusivité d'écriture lors d'un handoff, l'autorité des permissions et les projets de la bibliothèque. Le paquet Vault présente aussi un test OCR en échec. Aucune exploitation ni perte de données utilisateur n'a été provoquée. Les tests réussis ne ferment pas les parcours runtime ni la release.

Le meilleur axe de valeur est la continuité fiable entre agents et les preuves locales retrouvables. La multiplication de terminaux seule est déjà proposée ailleurs ; cette conclusion est une inférence produit, pas une mesure de demande commerciale.

## 1. SYSTEM & SURFACE MAP

| Surface | Technologies / owner | Tests actuels | Build | Runtime / distribution |
|---|---|---|---|---|
| App macOS / Cockpit, Plan | SwiftUI, AppKit, SwiftTerm, Swift 6 / Throttle | 580 tests, 5 skipped, 0 failure avec artefacts Debug existants | Fresh Release NOT RUN | PTY/UI/VoiceOver NOT RUN |
| Partage iOS/visionOS | ThrottleShared | 42 PASS, build SwiftPM courant | Package PASS ; apps NOT RUN | Appareils NOT RUN |
| Research Vault / agent embarqué | SQLCipher, XPC, ingestion, recherche, MCP | Pipeline PARTIAL ; OCR FAIL | Debug package construit ; Release NOT RUN | Helper signé installé NOT RUN |
| edge-agent | Node, contrat mission / Throttle | npm test PASS | N/A pour test Node | Hôte distant NOT RUN |
| Publication/site | Stage, publication ciblée, Sparkle | Inspection scripts | Candidat NOT RUN | Octets publics et mise à jour NOT RUN dans cet audit |
| CI | macos-26, Xcode stable, lint épinglé | Dernier état vert du handover, historique | Nouvelle révision NOT RUN | Ne prouve pas le candidat courant |

## 2. SCORES & TECHNICAL SCORECARD

| Dimension | Score /10 | Confiance | Preuve |
|---|---|---|---|
| Architecture et concurrence | Unknown | Medium | STATIC CURRENT, F-001/F-002/F-005 |
| Sécurité/privacy | Unknown | Medium | STATIC CURRENT ; tests d'autorisation insuffisants |
| Produit/UX/AX | Unknown | Low | Wiring partiel, parcours visuel NOT RUN |
| Qualité automatisée | Unknown | Medium | TEST CURRENT mais tests macOS sans reconstruction |
| Distribution readiness | 2 | High sur NO-GO | Absence de candidat qualifié et quatre P1 |
| Viabilité commerciale | Unknown | Low | Pas de funnel, rétention ou revenus vérifiés |

## 3. STRENGTH REGISTER & SOTA COMPLIANCE

- [VERIFIED] STATIC CURRENT : séparation XPC owner/query et exigences de signature dans ResearchVaultXPC ; SQLCipher, validation des lots et transactions. Limite : runtime signé non exercé.
- [VERIFIED] TEST CURRENT : suite macOS sans échec sur artefacts existants, 42 tests partagés et tests edge-agent réussis.
- [SUPPORTED] STATIC CURRENT : fournisseur de synthèse Vault sur l'appareil ; endpoints workers explicitement configurés. Ne pas confondre serveur local et calcul sur ce Mac.
- [VERIFIED] TEST antérieur au START, preuve conservée : 12 tests ciblés du filtre/invalidation. Leur résultat ne prouve pas la consommation mémoire de l'interface.
- [SUPPORTED] STATIC CURRENT : pipeline de release canonique et baseline SwiftLint relative, reconstruite avec la version CI exacte.

## 4. FAILURE REGISTER & GAP ANALYSIS

Tous les mécanismes F-001 à F-005 sont antérieurs à la remédiation. Voir la contre-revue copiée dans l'index pour leurs lignes exactes et reproductions statiques.

| ID | Sévérité / preuve | Constat et cause | Acceptation |
|---|---|---|---|
| F-001 | P1 CURRENT [FAILING] STATIC High | refreshStats remplace l'identité native par le transcript le plus récent du même cwd ; coût et reprise peuvent changer de conversation | Deux sessions et un agent externe même cwd gardent leurs identités ; aucune adoption ambiguë ; restaurer/reprendre exactement |
| F-002 | P1 CURRENT [FAILING] STATIC High | hibernate retourne avant sortie ; continueMission démarre la cible ; descendants reparentés oubliés lors de KILL | Arrêt borné vérifié sur processus possédés avant spawn ; timeout visible et bloquant ; test enfant ignorant TERM |
| F-003 | P1 CURRENT [FAILING] STATIC High | Auto-approbation accepte options mutantes ; texte terminal non authentifié utilisé comme requête ; wiring ordinaire perd la commande | Aucun texte terminal seul ne produit une acceptation ; UI reflète capacité ; tests mutations/prose/entrée périmée |
| F-004 | P1 CURRENT [FAILING] STATIC High | Runtime livré autorise seulement throttle/cheatcode alors que Connect Library produit des projets arbitraires | Enregistrement owner explicite, import/recherche nouveau projet ; query tiers toujours restreint ; erreurs justes |
| F-005 | P2 CURRENT [FAILING] STATIC High | OutputCollector garde toute la sortie de vérification jusqu'à 900 s | Rétention en bytes bornée pendant drainage, queue de sortie utile, troncature visible, UTF-8 robuste |
| F-006 | P2 CURRENT [FAILING] TEST High | ResearchDocumentTextExtractorTests.scannedPDFIsRecoveredByOCR lève unsupportedOrUnreadable ; cause Unknown | Reproduire en environnement viable, corriger cause, PDF scanné et textuel passent ; ne pas ignorer le test |
| F-007 | P2 CURRENT [FAILING] STATIC High | MultiCockpitRoot/Model dépassent les limites de fichier ; Workbench comporte aussi une désactivation file_length | Extraire par responsabilités en conservant observation, comportement et tests ; pas d'extension du baseline |
| F-008 | P1 release CURRENT [SUPPORTED] STATIC High | Vérification publique cache-bust limitée au HEAD DMG ; absence de parcours Sparkle réel pour candidat | Téléchargements complets normal/cache-bust avec hash et taille exacts ; mise à jour isolée et T+15 min |

Angles morts : P0 non confirmé, signature réelle helper, passage veille/reboot, corruption/backup, UI, AX, companions et réseau de production restent Unknown/NOT RUN. Les avertissements QoS observés dans les tests Plan justifient une mesure ciblée, pas un crash confirmé.

## 5. PRIVACY, SECURITY & CLAIM TRACEABILITY

| Promesse | État | Action |
|---|---|---|
| Une seule session écrit après handoff | Contradictoire statiquement, F-002 | Gate d'arrêt effectif |
| Auto-approve seulement lecture prouvée | Contradictoire, F-003 | Retirer l'autorité du texte PTY |
| Bibliothèque globale multi-projets | Bloquée, F-004 | Scope owner explicite sans élargir CheatCode |
| Synthèse locale | Source compatible ; runtime Unknown | Vérifier flux réels, préserver absence de fallback implicite |

Gitleaks 8.30.1 : quatre détections triées, aucun secret confirmé. Deux sont des clés UserDefaults (MCPHealth/ThresholdFired), une fixture synthétique de redaction et la clé PUBLIQUE Sparkle. Rapport conservé redacted ; ne pas annoncer un scan à zéro détection. Aucun secret envoyé à un service. NotebookLM N/A.

## 6. PRODUCT, UX, ACCESSIBILITY & LOCALIZATION

Interaction ledger : Cockpit reprise/hibernate/handoff → STATIC FAIL F-001/F-002 ; Settings permission → STATIC FAIL F-003 ; Connect Library → STATIC FAIL F-004 ; Plan verify → STATIC FAIL F-005. Tous ces parcours restent Runtime NOT RUN. Le scan d'actions retourne suspicious=0, ce qui ne couvre pas ces erreurs de wiring.

L'invalidation doit rester au niveau du point d'état, pas de la racine ni de la barre de menus. Vivantes = processus présent ; Actives = signal d'activité dans la fenêtre de 60 s. Ne pas raccourcir à 6 s ni substituer isLive à isSpawned. Captures des trois layouts, états vides/erreurs, clavier, VoiceOver, Dynamic Type/contraste et langues doivent être qualifiés sur le candidat. Les correctifs de localisation postérieurs à l'artefact 3.5.2 restent à distribuer.

## 7. COMMERCIAL VIABILITY & MONETIZATION

[OPPORTUNITY] Concurrence actuelle couverte dans le paquet de recherche associé : worktrees et sessions multi-agents sont proposés par les éditeurs. Valeur plausible de Throttle : préserver conversations/coûts/continuité et accès privé aux preuves du travail. Willingness-to-pay, funnel et rétention Unknown. Pas de prix, paywall ou promesse de marché modifiés sur une simple inférence.

## 8. PRODUCT ROADMAP

G0 stockage/reprise → G1 recherche et décisions → G2 F-001 à F-004 → G3 parcours retenus → G4 F-005/F-007 → G5 UI/AX/locales → G6 tests/CI/bundle → G7 usage Mac → G8 publication → G9 indépendant final. F-006 doit être résolu avant G6. Les problèmes de sécurité priment sur les nouvelles fonctions. Au plus trois évolutions, sans remplir artificiellement ce quota.

## 9. VALIDATION LEDGER

| Contrôle | Résultat | Limite |
|---|---|---|
| xcodebuild test-without-building macOS | PASS, 580 tests, 5 skipped, 0 failure, exit 0 | Artefacts Debug existants ; pas un build frais ni validation UI |
| swift test ThrottleShared scratch isolé | PASS, 42 tests | Compagnons complets non construits |
| edge-agent npm test | PASS | Aucun déploiement distant |
| ResearchVaultKit Scripts/verify.sh copie isolée | FAIL/PARTIAL, test OCR échoue ; SQLCipher 25 et gateway 7 passent | Pipeline complet non achevé, cache supprimé pour manque de disque |
| verify-research-vault-dependencies.sh | PASS après rerun hors sandbox | Frontière statique uniquement |
| Gitleaks dir redacted | 4 faux positifs triés | Scan répertoire, pas preuve d'absence absolue |
| Snapshot START/END | PASS, diff suivi identique | Fichiers de rapport postérieurs exclus |
| Fresh Release, signatures, UI, publication | NOT RUN | Gates ouvertes |

## 10. EVIDENCE INDEX

- `audit-output/sota-20260907/initial/` : START/END, logs tests/macOS/shared/edge/Vault, frontière, scan actions et Gitleaks.
- `audit-output/sota-20260907/initial/throttle-independent-initial-20260907.md` : contre-revue initiale indépendante avec chemins/lignes F1–F5 correspondant à F-001–005.
- `audit-output/cockpit-maintenance-20260907/FocusedTests.xcresult` : 12 tests ciblés précédents, preuve séparée.
- `docs/THROTTLE-SOTA-LOOP-2026-09-07.md` : contrat approuvé et critères G0–9.
- `docs/research/2026-09-07-throttle-sota-evidence.md` : sources actuelles et arbitrages, recherche poursuivie après END ; ne modifie pas rétroactivement les constats de source de cet audit.
