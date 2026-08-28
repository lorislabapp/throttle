# Research Vault — Full SOTA + import NotebookLM (design validé)

Date : 2026-08-29
Statut : design approuvé en session (sections 1-3) ; spec en attente de revue Kevin
Référence : `docs/research/2026-08-27-throttle-research-vault-cheatcode-full-sota.md` (dossier),
ADR 0001/0002, `docs/integration/CHEATCODE-RESEARCH-VAULT-REVIEW-HANDOFF-2026-08-27.md`
Cible : Throttle 3.4.0 (aucune release dans ce travail ; G8 distribution = gate séparé)

## Décision

Boucler les Phases 2-5 du dossier dans cette version, avec l'import des sources
des notebooks NotebookLM existants livré en premier. Le dossier disait
« NO-GO implémentation monolithique » : on garde exactement ses gates, mais on
exécute tous les lots, dans l'ordre ci-dessous, chacun gaté séparément.

Décisions produit prises par Kevin :

- Périmètre : Phases 2-5 complètes + import NotebookLM.
- Import : one-shot par notebook d'abord, sync opt-in ensuite.
- Notebooks prioritaires : **360** (166 sources, 11 titres dupliqués) et
  **Throttle - Documentation**.
- Sensibilité par défaut des sources importées : `internal` (révisable par
  source en revue de quarantaine).
- Mécanisme : **l'app pilote le gateway** `notebooklm-sota` en client MCP stdio
  (approche A), pas de daemon de sync continu, pas de dépendance à une session
  agent externe.

## État de départ (inventaire 2026-08-29)

- Phase 0 (ADR + benchmark) : DONE — mais golden set synthétisé à l'exécution,
  pas versionné sur disque.
- Phase 1 (modèle + SQLCipher + FTS5 + import DeepSearsh) : DONE.
- Phase 2 (intake) : PARTIAL — inbox + importer NotebookLM (dossier d'export)
  existent ; pas de quarantaine, parseurs (10 formats) coincés dans la cible
  app, pas d'export Markdown dérivé, pas d'intake URL.
- Phase 3 (MCP + agents) : PARTIAL — MCP read-only (`research_vault_search`,
  `research_vault_health`), écriture owner-only via XPC ; pas d'outil write,
  pas de ressources URI, pas de négociation `2026-07-28`, aucun hook
  `Stop`/`SubagentStop`/`SessionEnd`.
- Phase 4 (challenger retrieval) : NOT STARTED — évaluateur seul
  (`RetrievalBenchmark` : Recall@k/MRR/nDCG@k), zéro code embeddings/vec.
- Phase 5 (Workbench) : PARTIAL (~30 %) — recherche + import + toggle agent +
  synthèse locale ; pas de notebooks/vues, claims, contradictions, timeline,
  audit taxonomie, ni accessibilité.

## Lot 1 — fermer l'intake (Phase 2)

- Déplacer le jeu de parseurs (`md, markdown, txt, csv, json, jsonl, html,
  htm, rtf, docx, pdf`) de `NotebookLMMigrationImporter` (cible app) vers la
  cible package `ResearchVaultIngestion`, avec les mêmes plafonds
  (256 docs / 512 KB / 480 000 chars) ; l'app et le chemin agent/MCP
  consomment le même code.
- **Quarantaine** : nouvel état `quarantined` dans le store ; tout import
  (inbox, DeepSearsh, NotebookLM, URL) atterrit en quarantaine ; le Workbench
  liste les éléments en attente avec approuver/rejeter par source ; rien ne
  devient preuve sans geste humain. Migration transactionnelle du schéma.
- **Export Markdown dérivé** : export explicite par receipt/source vers un
  dossier choisi ; dérivé jetable, jamais source de vérité.
- **Intake URL** : fetch gaté par la `WebURLPolicy` existante → texte →
  candidat en quarantaine. Pas de crawling, une URL = une source.

Gate Lot 1 : import 2× sans duplication, changement de source détecté,
symlink/TOCTOU/oversize refusés, zéro promotion silencieuse.

## Lot 2 — import NotebookLM

- `NotebookLMGatewayClient` (cible app) : client MCP stdio qui spawn le
  binaire du gateway via le login shell (même pattern que `MCPHealthService`),
  appels sérialisés, timeouts explicites, aucune autre surface du gateway
  utilisée que `nlm_list_notebooks`, `nlm_list_sources`, `nlm_export_source`.
- **Job d'import reprenable** : list → export **par index** → dossier de
  staging avec sidecar de provenance par source
  `{notebookURL, index, titre, exportedAt, sha256}` → checkpoint persisté
  (indices faits). 166 sources ≈ 1-2 h (WebView sérialisé) : job de fond avec
  progression visible, pause/reprise, reprise idempotente après crash.
- Ingestion : `NotebookLMMigrationImporter` enrichi pour lire les sidecars ;
  la provenance (notebook + index + titre) entre dans le receipt. Les titres
  dupliqués (11 dans 360) sont désambiguïsés par index et présentés côte à
  côte en revue de quarantaine.
- Sensibilité `internal` par défaut, révisable par source. Re-run = idempotent
  par hash (fondation de la sync du Lot 5).
- UI Workbench : « Importer depuis NotebookLM… » → liste des notebooks
  (nom + sourceCount) → sélection → progression n/N.

Gate Lot 2 : re-run sans doublon ; interruption/kill puis reprise sans perte ni
double ; aucune donnée envoyée à Google au-delà des appels de listing/export
du gateway ; provenance complète sur chaque source importée.

## Lot 3 — fermer MCP + agents (Phase 3)

- Outil MCP **write** `research_vault_submit_receipt` : atterrit en
  **quarantaine**, jamais de commit direct ; outils read/write séparés ;
  la promotion reste owner-only via XPC (ADR 0002 inchangé).
- Ressources `throttle-research://receipt/…` et `throttle-research://source/…`
  (lecture citée).
- Double protocole : legacy `2024-11-05` conservé + `2026-07-28`
  (`server/discover`, stateless) ; aucune sécurité fondée sur `roots/list` ;
  chemins/identifiants explicites dans les paramètres ; `stderr` sans contenu.
- Hooks `Stop` / `SubagentStop` / `SessionEnd` bornés : produisent des
  **candidats** de receipt liés au parent ; transcript brut = fallback
  candidat uniquement.

Gate Lot 3 : chaque sous-agent relié au parent ; aucun double commit ; aucun
transcript entier promu silencieusement ; restart/crash idempotent.

## Lot 4 — challenger retrieval (Phase 4)

- **Golden set versionné sur disque** (committé) : figé depuis DeepSearsh +
  corpus importé, sans données restreintes ; baseline BM25 mesurée et
  enregistrée dessus.
- Adapter d'embeddings : NLEmbedding local d'abord, MLX en option ; A/B
  sqlite-vec vs Vec1 via `RetrievalBenchmark` existant.
- Métriques claims (RAGChecker-like) + vérificateur de citations.
- **Règle de promotion** : BM25 reste la production tant que le challenger ne
  gagne pas de façon statistiquement et produit-significative sans casser
  latence/mémoire/énergie (évidence DeepSearsh : dense seul = 0,0).

Gate Lot 4 : promotion uniquement sur gain significatif mesuré sur le golden
set versionné.

## Lot 5 — Workbench « NotebookLM local » + sync (Phase 5)

- **Notebooks locaux = vues enregistrées** (filtres projets/sources/thèmes/
  dates), jamais des copies de corpus.
- Panneau sources : hash, origine (dont notebook NLM + index), fraîcheur,
  sensibilité.
- Vue **Claims** : preuve / hypothèse / contradiction / question ouverte ;
  toute synthèse navigue vers la preuve exacte ; aucun statut inventé.
- Timeline + versions ; diff source révisée → claims affectés ; audit de
  dérive taxonomique.
- **Sync NotebookLM opt-in** : toggle par notebook, re-run du job Lot 2
  (idempotent par hash), nouveautés → quarantaine ; jamais de sync silencieuse.
- Accessibilité : VoiceOver, navigation clavier, Reduce Motion.
- Design language « precise cockpit » : hairlines, tabular digits, bleu
  réservé à l'interactif, pas de Canvas/`.shadow`/`.contentTransition`
  (garde macOS 26.5) ; fonctionnalités essentielles disponibles sans modèle.

Gate Lot 5 : synthèse → preuve exacte navigable ; essentiel utilisable sans
modèle ; audit accessibilité passé.

## Transversal

- Chaque lot : tests package (`Packages/ResearchVaultKit/Scripts/verify.sh`,
  qui stage `SQLCipher.framework` — un `swift test` nu ne linke pas),
  `xcodegen generate` après tout ajout/suppression de fichier, build
  `xcodebuild -scheme Throttle -configuration Debug`.
- Topologie synthèse inchangée (dossier §8) : local strict fail-closed, MLX
  pour `confidential`/`restricted`, jamais de bascule cloud implicite.
- Tout reste local ; le seul trafic sortant est le gateway NotebookLM déjà
  utilisé par Kevin.
- Interdits sans OK explicite de Kevin : install/relance de l'app, commit,
  push, publication, toucher `~/.claude.json` (redémarre Throttle).

## Hors périmètre

- CheatCode (consommation du package commun) — après ce chantier.
- Daemon de sync continu (approche C rejetée).
- Backend cloud, TOON/rewriting, auto-routing — NO-GO doctrine inchangés.
