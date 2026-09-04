# Throttle Research Vault × CheatCode — dossier de décision FULL SOTA

Date : 2026-08-27  
Portée : Throttle, DeepSearsh et bénéfices partagés avec CheatCode  
Statut : recherche et architecture de référence ; aucune modification produit ni preuve de release  
Verdict : **GO architecture / NO-GO implémentation monolithique ou ingestion indiscriminée**

## 1. Décision exécutive

Il faut intégrer les capacités durables de DeepSearsh dans Throttle, mais **ne pas embarquer le dépôt Python, son corpus ou son daemon tels quels**. La cible recommandée est un coffre de recherche natif, chiffré, versionné et provider-neutral : **Throttle Research Vault**.

Le même cœur doit pouvoir être consommé par CheatCode. Throttle apporte déjà la capture multi-agent, MCP, l'index des sessions, le rendu web et les modèles locaux. CheatCode apporte déjà le socle de sécurité le plus avancé : SQLCipher + FTS5 + sqlite-vec dans un seul cœur, clés par workspace, grants lecture/écriture séparés, revue humaine avant promotion et défenses contre l'injection de prompt.

La source de vérité n'est pas le RAG, un embedding, un résumé, NotebookLM ou une page Markdown. Elle est constituée de :

1. sources immuables et hashes vérifiés ;
2. provenance source → activité → agent → artefact ;
3. affirmations atomiques et liens précis vers leurs preuves ;
4. décisions humaines, statuts de preuve et historique de révision ;
5. politiques d'accès et de rétention.

Les index, embeddings, résumés, vues Obsidian et réponses LLM restent des dérivés supprimables et reconstruisibles.

## 2. Ce qui existe réellement aujourd'hui

### 2.1 Throttle

`VERIFIED` — Throttle possède déjà :

- un index local SQLite FTS5 des transcripts Claude Code, incrémental par `mtime`, dans `Throttle/Services/TranscriptIndex.swift` ;
- un serveur MCP stdio porté par le binaire signé `Throttle --mcp-server`, partagé avec Claude Code et Codex ;
- des outils `search_sessions`, `throttle_recall`, `throttle_semantic_search`, `throttle_read`, synthèse locale, rendu web et recherche grounded ;
- un index sémantique local `NLEmbedding` + stockage vectoriel Swift ;
- un cache web adressé par contenu et une indexation automatique de dépôts.

Limites :

- l'index de transcripts lit directement un format JSONL fournisseur non contractuel et ne couvre explicitement que `~/.claude/projects` ;
- les messages sont recherchables, mais ne deviennent pas des artefacts de recherche structurés ;
- le serveur annonce actuellement MCP `2024-11-05` et seulement la capacité `tools` ;
- les index sémantiques Throttle et DeepSearsh sont parallèles et non gouvernés par un benchmark commun ;
- la base des transcripts n'est pas le coffre chiffré et cloisonné requis pour des connaissances sensibles.

### 2.2 DeepSearsh

`VERIFIED` — DeepSearsh fournit une chaîne locale déterministe : inbox, déduplication par contenu, conservation des origines, catalogue, FTS5, index hybride, vérification et archive. Il reste CLI-only et sans fallback cloud.

`VERIFIED` — Son golden set actuel de 18 questions donne un signal décisif :

- grep recall@5 : `0,056` ;
- BM25 : `0,778` ;
- hybride avec poids dense ≤ 0,3 : `0,778` ;
- dense seul : `0,0` ;
- dense trop pondéré : dégradation à `0,667`.

Conclusion : ajouter un vector store n'est pas une amélioration en soi. BM25 reste la baseline de production jusqu'à ce qu'un modèle dense, sparse appris ou late-interaction apporte un gain significatif sur un jeu plus large.

### 2.3 CheatCode

`VERIFIED` — CheatCode possède déjà une implémentation utile au cœur commun :

- compilation statique d'un seul moteur SQLCipher + FTS5 + sqlite-vec ;
- vérification fail-closed de `PRAGMA cipher_version` ;
- clé maître Keychain `WhenUnlockedThisDeviceOnly`, dérivation HKDF par workspace ;
- base chiffrée par projet, embeddings inclus ;
- recherche BM25 + vectorielle fusionnée par RRF ;
- séparation `privacyAbsolute` / `boost`, consentement réunion-scopé et citations obligatoires pour le réseau ;
- filtrage d'injections et validation de citations en sortie ;
- revue humaine avant écriture de connaissance.

Limites du schéma actuel :

- `chunks` ne porte pas encore source originale, hash, version, activité, agent, droits, sensibilité, fraîcheur ou statut de preuve ;
- FTS, chunk et vec sont synchronisés manuellement, sans journal d'ingestion ni génération d'index ;
- aucun `cipher_integrity_check`, protocole de backup/restore ou migration crash-safe n'est démontré dans les extraits inspectés ;
- sqlite-vec `vec0` reste une dépendance distincte de Vec1, le nouveau moteur ANN officiel SQLite ;
- la présence d'une citation `[E#]` ne prouve pas à elle seule l'entailment de chaque affirmation.

## 3. Leçons de l'article Automato

La partie publique de l'article *I built an AI-assisted Knowledge Management system for you* décrit un système Claude + Obsidian dans lequel l'humain reste l'auteur et le propriétaire de l'organisation.

### À reprendre

- deux axes distincts : structure stable et thèmes évolutifs ;
- types de documents explicites ;
- classification assistée, mais taxonomie contrôlée par l'utilisateur ;
- mise à jour automatique des vues et index ;
- audit périodique des liens, comptes, thèmes forcés et dérive ;
- proposition d'un nouveau thème sans création silencieuse ;
- préservation du texte et de la voix originale ;
- délégation des tâches linguistiques à faible risque, pas des décisions déterministes sensibles.

### À ne pas copier

- la grille 3×3 comme taxonomie universelle ;
- Obsidian ou les index Markdown comme vérité canonique ;
- une dépendance à Claude ou à un fournisseur unique ;
- la sauvegarde Notion/cloud par défaut ;
- l'auto-classification sans confiance, provenance ni file de revue ;
- l'hypothèse que Notes et Articles couvrent réunions, décisions, audits, incidents, code et preuves.

### Adaptation proposée

Les axes du Research Vault doivent être extensibles :

- projet / workspace ;
- domaine : architecture, sécurité, produit, UX, marché, juridique, QA… ;
- type : source, recherche, décision, audit, incident, benchmark, réunion… ;
- statut : inbox, needs-review, accepted, rejected, superseded ;
- preuve : `VERIFIED`, `SUPPORTED`, `HYPOTHESIS`, `CONTRADICTED`, `OPEN`, `STALE` ;
- sensibilité : public, internal, confidential, restricted ;
- fraîcheur et date de revalidation ;
- thèmes utilisateur avec définition, alias et historique merge/split.

## 4. Positionnement face aux outils existants

| Produit/concept | Force publique observée | Limite pour notre besoin | Leçon à prendre |
|---|---|---|---|
| Obsidian Bases | Markdown et propriétés locales, vues calculées | pas une chaîne de preuve multi-agent ni un store chiffré transactionnel | excellent export et UI de vues, pas backend canonique |
| DEVONthink | ingestion documentaire mature, recherche et IA en arrière-plan, modèles locaux ou serveur | architecture propriétaire et pas orientée receipts d'agents | qualité d'inbox, classement et maintenance documentaire |
| AnythingLLM | application locale prête à l'emploi, workspaces, modèles locaux, RAG et agents | workspaces de chat/RAG, provenance et gouvernance des claims non établies par le marketing | onboarding modèle et expérience chat-documents |
| Khoj | second brain open source, formats multiples, self-hosting et recherche naturelle | stack serveur/Docker/Python et frontières local/private variables selon déploiement | connecteurs et portabilité |
| NotebookLM | excellente synthèse et navigation par sources | cloud, inventaire parfois dégradé, synthèse non probante | UX source-first et contre-revue |
| DeepSearsh | provenance, inbox, déduplication, bibliothèque locale vérifiée | CLI Python séparé, schéma document plutôt que claim graph | pipeline déterministe à porter |
| Article Automato | taxonomie humaine, audit de dérive, voix préservée | modèle personnel et structure rigide | gouvernance humaine du classement |

Le différenciateur défendable n'est donc pas « chat with your docs ». C'est : **capture automatique mais contrôlée de recherches multi-agent + coffre de preuves local chiffré + provenance vérifiable + continuité entre outils + promotion humaine vers les connaissances métier**.

## 5. Architecture cible

```text
Codex hooks ─┐
Claude hooks ├─> ResearchReceipt queue ─┐
autres agents┘                          │
                                       ├─> Intake / quarantine / review
Finder Inbox ──────────────────────────┤          │
Web, PDF, repos ───────────────────────┘          v
                                  ResearchVaultCore
                        ┌────────────────────────────────┐
                        │ encrypted source objects       │
                        │ SQLCipher metadata + FTS5      │
                        │ provenance + claims + policies │
                        │ index generations + audit log  │
                        └────────────────────────────────┘
                           │          │             │
                       MCP API    Workbench     optional export
                           │          │          Finder/Obsidian
                   Codex/Claude   local notebooks
                                      │
                              optional local synthesis
```

### 5.1 Packaging recommandé

Créer un package Swift indépendant `ResearchVaultKit`, consommé statiquement par Throttle et CheatCode :

```text
ResearchVaultKit/
├── ResearchVaultModel       # types, provenance, policies, receipts
├── ResearchVaultStore       # SQLCipher, migrations, CAS chiffré
├── ResearchVaultRetrieval   # FTS5, fusion, rerank adapters, eval
├── ResearchVaultIngestion   # Finder, files, web, session adapters
├── ResearchVaultMCP         # legacy + MCP 2026-07-28
└── ResearchVaultTesting     # fixtures, hostile corpus, benchmarks
```

Chemin de réduction de risque : développer d'abord le package sous `Throttle/Packages/ResearchVaultKit`, stabiliser ses interfaces, puis l'extraire en dépôt privé versionné lorsque CheatCode l'adopte. Ne pas dupliquer le code entre les deux apps.

Le bundle contient le moteur, les migrations, les schémas, les prompts versionnés et une taxonomie de départ minimale. Il ne contient jamais le corpus utilisateur. Les modèles optionnels sont installés à la demande avec manifeste, licence, hash et taille affichés.

### 5.2 Stockage

```text
~/Library/Application Support/Throttle/ResearchVault/
├── vault.ccsql
├── objects/                 # objets source chiffrés
├── derived/                 # index reconstruisibles
├── jobs/                    # imports/reindex resumables
├── backups/
└── audit/
```

Pour éviter qu'un hash public révèle qu'un document connu existe dans le coffre, le nom d'objet peut être un identifiant HMAC par coffre. Le SHA-256 réel reste dans la base chiffrée pour vérification et migration. Les gros objets sont chiffrés séparément par AES-GCM ; métadonnées, texte normalisé, FTS et vecteurs restent dans SQLCipher.

SQLCipher chiffre aussi les pages WAL avec la clé de base selon sa documentation. Il faut conserver `SQLITE_TEMP_STORE=2`, HMAC de pages et secure-delete tant qu'un benchmark n'établit pas un besoin supérieur. Les clés ne doivent jamais apparaître dans logs, crash reports, arguments CLI ou préférences.

### 5.3 Schéma canonique minimal

```text
vaults(id, schema_version, created_at, policy_id)
projects(id, stable_key, title, sensitivity, retention_policy)
entities(id, object_id, media_type, byte_size, plaintext_sha256, created_at)
origins(id, entity_id, kind, locator, observed_at, source_modified_at, rights)
activities(id, kind, provider, session_id, agent_id, parent_agent_id,
           started_at, ended_at, tool_version, prompt_version)
documents(id, entity_id, project_id, type, title, status, language,
          sensitivity, accepted_by, accepted_at, supersedes_id)
claims(id, document_id, normalized_text, evidence_status, valid_from,
       valid_until, reviewed_at)
evidence_edges(claim_id, entity_id, locator, exact_quote_hash, relation,
               confidence, created_by_activity_id)
chunks(id, entity_id, locator, text, token_count, chunker_version)
index_generations(id, kind, model_id, model_hash, parameters, corpus_hash,
                  created_at, status)
classifications(document_id, axis, value, confidence, proposed_by, reviewed_at)
receipts(id, activity_id, project_id, receipt_hash, ingestion_status)
audit_events(id, actor, operation, target, policy_decision, timestamp)
```

Ce modèle reprend le noyau W3C PROV : `Entity`, `Activity`, `Agent`, `wasDerivedFrom`, `used`, `wasGeneratedBy` et `wasAttributedTo`, sans imposer RDF dans l'implémentation.

## 6. Capture de toutes les recherches d'agents

### 6.1 Contrat `ResearchReceipt`

Chaque session ou sous-agent ayant réellement fait de la recherche doit terminer par un reçu typé :

```json
{
  "schemaVersion": 1,
  "receiptId": "uuid",
  "sessionId": "provider-session-id",
  "agentId": "provider-agent-id",
  "parentAgentId": null,
  "project": "stable-project-key",
  "question": "question étudiée",
  "findings": [
    {"claim": "...", "status": "SUPPORTED", "evidenceIds": ["..."]}
  ],
  "sources": [
    {"kind": "url", "locator": "https://...", "observedAt": "...", "sha256": "..."}
  ],
  "openQuestions": [],
  "sensitivity": "internal",
  "createdAt": "...",
  "contentHash": "..."
}
```

Le reçu est la frontière stable. Le format interne des transcripts fournisseurs ne l'est pas.

### 6.2 Hooks

`VERIFIED` — Codex annonce les hooks comme généralement disponibles pour scanner les secrets, valider, journaliser et créer des mémoires. Claude Code expose `Stop`, `SubagentStop`, `PreCompact` et `SessionEnd`, avec `session_id`, `transcript_path`, `cwd` et un chemin distinct pour le transcript du sous-agent.

Architecture :

1. `PostToolUse` ou l'outil de recherche marque la session `research-active` localement.
2. `research_commit` écrit le receipt explicitement.
3. `Stop`/`SubagentStop` vérifie la présence du receipt et peut demander une seule continuation bornée.
4. `SessionEnd` ne fait qu'écrire une petite tâche dans la queue ; aucun parsing lourd dans son budget court.
5. un worker Throttle ingère, classifie, déduplique et place en revue.
6. le watcher de transcripts ne crée que des **candidats**, jamais des connaissances acceptées.

Le raw transcript reste dans un store séparé avec rétention configurable. Par défaut, le Research Vault conserve le receipt, les preuves et le résultat accepté, pas toute la conversation.

### 6.3 Finder Inbox

Le dossier doit être choisi avec `NSOpenPanel`, persisté par security-scoped bookmark pour rester compatible avec un futur sandbox et surveillé via FSEvents ou une stratégie équivalente.

États visibles :

```text
Inbox → Quarantine → Needs Review → Accepted
                         └────────→ Rejected
Accepted → Superseded / Stale
```

Règles d'ingestion : fichiers réguliers seulement, pas de suivi implicite des symlinks/hardlinks/packages, limites de taille et de décompression, OCR borné, hash après lecture stable, protection TOCTOU, MIME détecté et non seulement extension, parsing hors processus pour formats hostiles.

Les dossiers Finder sont une surface d'entrée et d'export. Déplacer un fichier dans `Accepted` ne doit pas être le seul signal canonique : la transition transactionnelle dans la base fait foi.

## 7. Recherche et RAG SOTA, mais mesurés

### Pipeline recommandé

1. filtre d'accès : projet, sensibilité, type, validité et fraîcheur ;
2. FTS5/BM25 avec tokenizer Unicode et synonymes contrôlés ;
3. récupération sémantique optionnelle ;
4. fusion RRF ;
5. reranking optionnel borné ;
6. diversification par source et date ;
7. assembly d'un evidence packet exact ;
8. génération structurée locale ;
9. vérification claim → evidence ;
10. abstention ou affichage des contradictions.

### Choix vectoriel

- **Production initiale : BM25**, car c'est le seul gain déjà mesuré sur DeepSearsh.
- **Expérience A : modèle multilingue léger** déjà compatible avec MLX/Swift.
- **Expérience B : BGE-M3**, capable de dense, sparse et multi-vector dans plus de 100 langues et jusqu'à 8192 tokens, mais trop coûteux pour être choisi sans mesure Apple Silicon.
- **Expérience C : ColBERTv2**, late interaction plus fine, mais coût de stockage/compute supérieur malgré sa compression.
- **Store ANN : Vec1 0.7**, officiel SQLite et NEON ARM, à évaluer contre sqlite-vec ; version trop récente pour une migration immédiate.

Aucun modèle n'est promu s'il n'améliore pas Recall@k/MRR/nDCG avec un coût acceptable. La dimension, le tokenizer, la révision, le hash des poids et la génération d'index sont persistés.

### Évaluation obligatoire

Le golden set DeepSearsh de 18 questions doit devenir un corpus consenti d'au moins 200 tâches :

- Throttle et CheatCode ;
- français, anglais et requêtes croisées ;
- noms propres, versions, numéros, décisions, contradictions, questions temporelles ;
- sources identiques révisées ou superseded ;
- absence de réponse ;
- projet et sensibilité adverses.

Comparer aveuglément : grep, BM25, BM25 + expansion, dense, sparse appris, RRF, RRF + reranker. Publier Recall@5/10, MRR, nDCG, précision des citations, couverture des claims, abstention correcte, latence p50/p95, mémoire, énergie et taille d'index.

RAGChecker est une bonne inspiration pour séparer erreurs de retrieval et erreurs de génération, mais ses juges LLM ne remplacent pas une vérité terrain et une revue humaine.

## 8. Interface « NotebookLM local »

Il faut construire cette expérience, mais après le coffre et l'évaluation.

Un notebook local est une **vue enregistrée**, pas une copie de corpus :

- filtre de projets, sources, thèmes et dates ;
- panneau des sources avec hash, origine, fraîcheur et sensibilité ;
- chat/recherche avec citations exactes ;
- vue Claims distinguant preuve, hypothèse, contradiction et question ouverte ;
- timeline et versions ;
- diff source révisée → claims affectés ;
- audit de dérive taxonomique ;
- export Markdown/Obsidian explicite ;
- synthèse ou audio optionnels et dérivés.

Foundation Models convient à la classification, extraction, tagging, résumé et génération structurée lorsque le modèle est disponible. Sa fenêtre de contexte et ses changements avec l'OS imposent chunking, prompts versionnés, tests par version et fallback déterministe. Le mode local strict ne doit jamais basculer silencieusement vers Private Cloud Compute.

La topologie recommandée est **hybride par politique, pas hybride par défaut** :

- retrieval BM25/citations toujours local et disponible sans modèle ;
- MLX sur le Mac pour les tâches courtes, les données `confidential` ou
  `restricted`, et le fonctionnement hors réseau ;
- LLM privé Proxmox seulement pour les contextes `public` ou `internal`, les
  comparaisons/synthèses longues et les batchs, après authentification mutuelle,
  chiffrement du transport, limites de taille et preuve de non-rétention ;
- aucune bascule cloud implicite ; toute nouvelle classe de backend exige une
  extension du contrat et une revue de politique ;
- si le serveur n'est pas authentifié ou indisponible, fallback MLX puis
  retrieval-only avec citations, jamais baisse silencieuse de confidentialité.

## 9. MCP moderne

Le serveur actuel Throttle doit rester compatible avec ses clients legacy, mais ajouter une voie moderne.

### Point SOTA découvert

La spécification MCP `2026-07-28` est stateless, remplace le handshake historique par `server/discover`, déplace les tâches longues dans une extension et déprécie **Roots**, Sampling et Logging. Les nouvelles intégrations ne doivent donc plus fonder leur sécurité sur `roots/list`.

Décision :

- double compatibilité legacy `2024-11-05` / moderne `2026-07-28` ;
- allowlists et bookmarks stockés par Throttle ;
- chemins ou identifiants de source explicites dans les paramètres ;
- ressources `throttle-research://...` ;
- `stderr` sans contenu pour les diagnostics stdio ;
- Tasks extension seulement pour import, OCR, migration et reindex lorsqu'un client l'annonce ;
- fallback par job local explicite pour les clients legacy.

### Surface minimale

Lecture :

- `research.search`
- `research.read`
- `research.claims`
- `research.status`
- `research.verify_citations`

Écriture séparée :

- `research.commit_receipt`
- `research.import_candidate`
- `research.accept_candidate`
- `research.reject_candidate`
- `research.propose_taxonomy_change`

Les opérations de promotion, export cloud, suppression ou modification de taxonomie exigent une autorisation explicite liée à la requête. Une instruction trouvée dans une page, un PDF, un mail ou un transcript ne peut jamais accorder une capacité.

## 10. Threat model et confidentialité

| Menace | Contrôle obligatoire | Gate |
|---|---|---|
| prompt injection indirecte dans source | contenu balisé comme données non fiables, aucune capacité dérivée du texte, output structuré et vérifié | corpus hostile + zéro action non autorisée |
| exfiltration cross-project | policy avant retrieval, clés et DB par domaine sensible, tests de non-interférence | zéro chunk hors scope sur corpus adversarial |
| poison de corpus | quarantine, origine/hash, signature de promotion humaine, rollback | restauration exacte d'une génération antérieure |
| fuite au repos | SQLCipher + objets AEAD + Keychain, pas d'index plaintext | inspection fichiers/WAL/temp/swap contrôlée |
| déduplication révélatrice | identifiants CAS HMAC par coffre | aucun hash public visible hors DB chiffrée |
| transcript fournisseur instable | adapters versionnés + receipts stables | fixtures par version, échec fail-closed |
| import PDF/HTML hostile | limites, parsing isolé, type réel, timeout, pas de scripts | corpus zip-bomb/PDF/OCR hostile |
| corruption/crash | transactions, journal de jobs, integrity checks, backup chiffré | kill aux phases critiques puis reprise idempotente |
| modèle compromis | manifeste, hash, licence, provenance des poids, sandbox inference | hash mismatch refuse le chargement |
| cloud accidentel | `privacyAbsolute` coupe tout réseau, export séparé et confirmé | instrumentation réseau à zéro durant scénario strict |
| sur-agence LLM | read/write tools séparés, confirmation et validation déterministe | tests OWASP injection/excessive agency |

Les regex de CheatCode constituent une défense en profondeur utile, mais pas une solution générale à l'injection. OWASP rappelle que RAG et fine-tuning ne suppriment pas ce risque : l'autorisation et les side effects doivent rester déterministes hors du modèle.

## 11. Bénéfices précis par produit

### Throttle

- transforme le moteur de mémoire de sessions en véritable mémoire de recherche multi-agent ;
- regroupe DeepSearsh, cache web, index sémantique et MCP ;
- rend chaque résultat traçable et partageable entre Codex/Claude sans copier tout le transcript ;
- fournit le futur Workbench local et le Finder Inbox ;
- permet de packager un moteur unique dans le binaire signé.

### CheatCode

- enrichit les notes/réunions acceptées avec provenance, versions, statut de preuve et contradictions ;
- réutilise le même moteur d'évaluation retrieval et les mêmes manifests de modèle ;
- permet une continuité meeting → décision → recherche → preuve, sans fusionner les permissions ;
- conserve ses DB/clefs par projet et son gate humain avant écriture ;
- peut exposer ses recherches via une vue locale sans transférer CV, voix, transcripts ou documents métier.

### Frontière importante

CheatCode ne doit pas automatiquement partager son corpus avec Throttle. Le package est commun ; les coffres, clés, politiques et grants restent séparés. Un lien entre coffres est une capability explicite, read-only par défaut, avec sélection des documents et journal d'audit.

## 12. Plan d'implémentation priorisé

### Phase 0 — ADR et benchmark, 3–5 jours

- figer le modèle de menace et les invariants ;
- extraire un golden set élargi depuis DeepSearsh sans données restreintes ;
- mesurer BM25 actuel et définir budgets ;
- écrire l'ADR package, chiffrement, receipts et double MCP ;
- décider la politique de migration des deux stores existants.

Gate : aucun code de store avant schéma, migration et critères de destruction/restauration approuvés.

### Phase 1 — `ResearchVaultModel` + store, 1–2 semaines

- modèles provenance/claims/receipts ;
- SQLCipher et objets chiffrés ;
- migrations transactionnelles ;
- FTS5 BM25 ;
- import DeepSearsh idempotent en lecture seule ;
- tests d'intégrité, corruption, crash et séparation de coffres.

Gate : recherche exacte, provenance complète, reprise après kill, zéro plaintext de contenu dans DB/WAL/temp.

### Phase 2 — intake, Finder et migration, 1 semaine

- dossier choisi + bookmark ;
- quarantine/review ;
- parsers Markdown/texte/URL, PDF ensuite ;
- reçu de migration avec comptes/hashes ;
- export Markdown dérivé.

Gate : import 2× sans duplication, changement source détecté, symlink/TOCTOU/oversize refusés.

### Phase 3 — MCP + agents, 1–2 semaines

- outils read/write séparés ;
- ressources URI ;
- legacy et `2026-07-28` ;
- receipts Codex/Claude ;
- hooks `Stop`, `SubagentStop`, `SessionEnd` bornés ;
- raw transcript uniquement comme fallback candidat.

Gate : chaque sous-agent est relié au parent ; aucun double commit ; aucun transcript entier promu silencieusement ; restart/crash idempotent.

### Phase 4 — retrieval challenger, 1–2 semaines

- adapters d'embeddings ;
- A/B BM25/dense/BGE-M3/late interaction selon faisabilité ;
- Vec1 contre sqlite-vec ;
- RAGChecker-like claim metrics ;
- citation verifier.

Gate : promotion uniquement sur gain statistiquement et produit-significatif sans casser latence/mémoire/énergie.

### Phase 5 — Workbench, 2 semaines

- notebooks locaux/saved views ;
- sources, claims, contradictions, timeline ;
- audit de taxonomie ;
- synthèse Apple/MLX avec fallback ;
- accessibilité clavier/VoiceOver/Reduce Motion.

Gate : toute synthèse navigue vers la preuve exacte ; aucun statut de preuve inventé ; fonctionnalités essentielles sans modèle.

## 13. Critères de succès

### Retrieval

- Recall@10 ≥ 0,95 sur le golden set accepté ;
- MRR/nDCG publiés par langue et catégorie ;
- précision entités critiques ≥ 0,99 ;
- zéro fuite cross-project/sensibilité ;
- p95 recherche FTS ≤ 100 ms à taille DeepSearsh actuelle ;
- p95 hybride ≤ 250 ms sur Mac 16 Go de référence.

### Grounding

- 100 % des affirmations factuelles affichées possèdent un lien de preuve ou sont marquées hypothèse ;
- citation correcte au niveau locator ≥ 0,99 ;
- abstention ≥ 0,99 lorsque preuves absentes ou interdites ;
- contradictions visibles, jamais fusionnées silencieusement.

### Ingestion et durabilité

- import idempotent ;
- migration vérifiée par hash et compte ;
- reprise après crash à chaque transition ;
- export complet lisible sans dépendance propriétaire ;
- reconstruction de tous les index dérivés depuis sources + métadonnées.

### Confidentialité

- zéro réseau en mode strict ;
- zéro contenu dans logs/telemetry/crash reports ;
- suppression d'un projet et de ses clés vérifiable ;
- partage inter-projet impossible sans grant explicite ;
- aucune action write déclenchée par une source ou sortie LLM.

## 14. Rejets et NO-GO

- `NO-GO` embarquer `/Users/kevinnadjarian/GitHub/DeepSearsh` ou Python dans l'app finale.
- `NO-GO` faire de Markdown/Obsidian la vérité canonique.
- `NO-GO` indexer et promouvoir tous les transcripts sans revue ni rétention.
- `NO-GO` remplacer BM25 par un vector store sans benchmark.
- `NO-GO` mutualiser les clés ou corpus Throttle/CheatCode.
- `NO-GO` utiliser MCP Roots comme nouvelle frontière de sécurité : cette capacité est dépréciée en 2026-07-28.
- `NO-GO` laisser un LLM classifier, accepter, supprimer, exporter ou modifier la taxonomie sans autorisation déterministe.
- `NO-GO` appeler « SOTA », « sécurisé » ou « entièrement local » avant les gates de runtime, réseau, corruption, device et distribution.

## 15. NotebookLM créé pour cette recherche

- Titre : `Throttle Research Vault × CheatCode — SOTA 2026`
- ID : `01c273b1-61ac-4fcc-bdf7-bf566a0814d4`
- URL : <https://notebook.google.com/notebook/01c273b1-61ac-4fcc-bdf7-bf566a0814d4>
- Inventaire vérifié : `21/21`, `complete=true`, `degraded=false`.
- Contenu : uniquement les 21 URLs publiques listées ci-dessous ; aucun fichier, code, transcript ou rapport local n'a été uploadé.
- Synthèse : `BLOCKED`. Une première réponse n'offrait pas d'identités/citations structurées ; après réconciliation 21/21, les essais suivants ont échoué sur absence de citations structurées puis timeout de navigation/identity check. Aucun résultat NotebookLM n'est utilisé comme preuve dans ce dossier.

## 16. Evidence ledger

| État | Conclusion | Preuve | Limite |
|---|---|---|---|
| VERIFIED | Throttle a déjà MCP, FTS sessions, index sémantique et web cache | code actuel Throttle | pas encore un coffre unifié |
| VERIFIED | CheatCode a déjà SQLCipher + FTS5 + sqlite-vec et clés par workspace | code actuel CheatCode | schéma provenance incomplet |
| VERIFIED | BM25 porte le recall DeepSearsh mesuré | golden set 18 questions | jeu trop petit pour généraliser |
| VERIFIED | MCP 2026-07-28 déprécie Roots/Sampling/Logging | publication et SEP MCP | adoption client à vérifier |
| VERIFIED | NotebookLM possède 21 sources complètes | inventaire live du notebook | synthèse chat bloquée |
| SUPPORTED | SQLCipher convient au coffre chiffré | design Zetetic + implémentation CheatCode | audits runtime/backup manquants |
| SUPPORTED | receipts + hooks couvrent sessions et sous-agents | docs officielles Codex/Claude | adapters et formats à maintenir |
| SUPPORTED | modèle PROV convient à la provenance | recommandation W3C PROV-O | mapping relationnel à concevoir |
| HYPOTHESIS | BGE-M3 ou ColBERT améliore FR/EN | papiers primaires | aucune preuve Apple/ce corpus |
| HYPOTHESIS | Vec1 dépassera sqlite-vec à grande échelle | extension officielle SQLite 0.7 | trop récent, migration non justifiée |
| OPEN | demande utilisateur pour le Workbench local | analogues et intuition produit | tests utilisateurs manquants |
| OPEN | meilleure frontière package/repo à long terme | analyse des deux dépôts | dépend de gouvernance/versioning |

## 17. Sources publiques actuelles

1. Automato, *AI-assisted Knowledge Management* — <https://automato.substack.com/p/ai-assisted-knowledge-management-4u>
2. Obsidian Bases — <https://obsidian.md/help/bases>
3. DEVONthink AI — <https://www.devontechnologies.com/apps/devonthink/ai>
4. AnythingLLM — <https://anythingllm.com/>
5. Khoj — <https://docs.khoj.dev/>
6. SQLite FTS5 — <https://www.sqlite.org/fts5.html>
7. SQLite Vec1 — <https://sqlite.org/vec1/doc/trunk/doc/vec1.md>
8. SQLCipher Design — <https://www.zetetic.net/sqlcipher/design/>
9. MCP 2026-07-28 — <https://blog.modelcontextprotocol.io/posts/2026-07-28/>
10. MCP SEP-2577 — <https://modelcontextprotocol.io/seps/2577-deprecate-roots-sampling-and-logging>
11. Codex Hooks — <https://learn.chatgpt.com/docs/hooks>
12. Claude Code Hooks — <https://code.claude.com/docs/en/hooks>
13. Apple, accès fichiers macOS — <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>
14. Apple Foundation Models — <https://developer.apple.com/documentation/FoundationModels/>
15. W3C PROV-O — <https://www.w3.org/TR/prov-o/>
16. Lewis et al., RAG — <https://proceedings.neurips.cc/paper/2020/hash/6b493230205f780e1bc26945df7481e5-Abstract.html>
17. RAGChecker — <https://arxiv.org/abs/2408.08067>
18. BGE-M3 — <https://arxiv.org/abs/2402.03216>
19. ColBERTv2 — <https://arxiv.org/abs/2112.01488>
20. NIST AI 600-1 — <https://www.nist.gov/publications/artificial-intelligence-risk-management-framework-generative-artificial-intelligence>
21. OWASP Prompt Injection — <https://genai.owasp.org/llmrisk/llm01-prompt-injection/>

## 18. Documents DeepSearsh réutilisés

1. `CheatCode — pile IA/LLM, ressources et performance SOTA`  
   `library/market-and-competitors/cheatcode/2026-08-16-ai-llm-resource-performance-sota--531a21bb04.md`  
   Origines : CheatCode `docs/research/2026-08-16-ai-llm-resource-performance-sota.md` et archive inbox  
   SHA-256 : `531a21bb04ca2f6399172ede0081e30fceb8e90c2952da6aa3e3c5833d02200a`

2. `05 — Vector store local chiffré + embeddings on-device`  
   `library/market-and-competitors/cheatcode/05-vector-store-chiffre--9893e175fa.md`  
   Origine : CheatCode `Doc/DeepResearsh/05-vector-store-chiffre.md`  
   SHA-256 : `9893e175fae6bf20a61de8565930a6cea67f273ed24df3f0b975fdc58d90721b`  
   Usage : hypothèses historiques revalidées contre code actuel et sources SQLCipher/SQLite.

3. `Throttle Workspaces — marché, produit et architecture SOTA`  
   `library/market-and-competitors/throttle/2026-08-16-throttle-workspaces-market-product-sota--30cafe32eb.md`  
   Origines : Throttle et Throttle-macos27-sota `docs/research/2026-08-16-throttle-workspaces-market-product-sota.md`  
   SHA préfixe : `30cafe32eb40894c`

4. `Handoff de décision — Throttle Workspaces`  
   `library/evidence-and-decisions/throttle/throttle-workspaces-handoff-2026-08-16--9dd2813ecf.md`  
   Origines : Throttle et Throttle-macos27-sota  
   SHA-256 : `9dd2813ecf3af43e445f4f3490faefb1c6fd6266223938edbc07efc2f6d1bf0f`

5. `Throttle — NotebookLM synthesis, revalidated`  
   `library/notebooklm-synthesis/throttle/throttle-notebooklm-synthesis-20260816--1a30db7a15.md`  
   Origine : `Throttle/audit-output/Throttle-notebooklm-synthesis-20260816.md`  
   SHA-256 : `1a30db7a15d29a755375c8886ee7d7111c139f3a189845ea972f5b40fb712db5`

## 19. Prochaine décision recommandée

Autoriser une tranche locale bornée **Phase 0 + squelette Phase 1 seulement** : ADR, schéma, package Swift, golden set et store de test. Ne pas encore modifier les hooks globaux, migrer DeepSearsh, activer un watcher Finder, toucher CheatCode ou remplacer ses stores. Ces actions viennent après revue du présent dossier et après preuve que le package commun ne réduit pas les frontières de confidentialité de CheatCode.

## 20. Checkpoint d’implémentation — 2026-08-27 15:14 Europe/Paris

La recommandation de la section 19 a été exécutée puis dépassée par gates
locaux successifs. Ce checkpoint remplace donc la section 19 comme état courant,
sans transformer les preuves locales en readiness de distribution.

### Implémenté dans `Packages/ResearchVaultKit`

- modèle canonique `ResearchReceipt` par session/agent, provenance et SHA-256 ;
- autorisation explicite projet + sensibilité, sans wildcard implicite ;
- objets AES-GCM avec identités HMAC par vault ;
- clés séparées dérivées par HKDF et racine Keychain device-only ;
- SQLCipher officiel 4.18.0, schéma transactionnel v2, FTS5 et filtres SQL ;
- backup/restore chiffré sous clé distincte, staging atomique et contrôles HMAC ;
- probes inter-processus d’écriture et migration interrompues en Debug/Release ;
- import DeepSearsh strictement read-only : confinement, fichier régulier,
  symlink, taille, UTF-8 et hash revalidés ;
- Inbox Finder `*.research-receipt.json`, batch fail-closed et idempotent ;
- chunking Markdown déterministe et recherche d’un meilleur chunk unique par
  document ;
- Gateway local citation-first pour Workbench/MCP, avec autorisation immuable ;
- outils de preuve `catalog-probe`, `crash-probe` et `benchmark`.

### Preuves fraîches

- `Scripts/verify.sh` : exit 0 ;
- Debug : 29 XCTest + 15 Swift Testing, zéro échec ;
- Release : 29 XCTest + 15 Swift Testing, zéro échec ;
- crash Debug et Release : ligne commitée conservée, écritures non commitée et
  migration v99 annulées, quick-check et HMAC valides ;
- snapshot DeepSearsh : SHA-256
  `e000726cc6b60dc6d470cf2516b4b81b2c1d593a613e7b84e1078f78c84f95b4`,
  1 954 entrées scannées, 38 documents Throttle acceptés, 526 532 octets ;
- benchmark SQLCipher 4.18.0 : 38 documents, 440 chunks, 5 requêtes,
  Recall@5 `1.0`, MRR `0.867`, nDCG@5 `0.90`, p95 final sous charge
  `26.94 ms` ;
- le document courant `dr-6c9c61119a3627fc` est inclus via sa référence
  secondaire `throttle`, avec hash revalidé.

### Frontières encore ouvertes

- aucun helper signé/embarqué dans Throttle ; l’app utilise GRDB/system SQLite,
  donc charger aussi le XCFramework SQLCipher dans le même processus exige une
  preuve de link-map absente ;
- aucun changement CheatCode ; son amalgamation SQLCipher + sqlite-vec interdit
  l’ajout direct d’un second core SQLite ;
- aucun test device, archive, notarisation, distribution ou production ;
- benchmark lexical petit et intentionnellement ciblé ; semantic/hybride reste
  un challenger, pas une dépendance ;
- aucune étude utilisateur du Workbench local.

Verdict courant : **GO package local et handoff IPC ; NO-GO intégration
in-process, publication ou affirmation FULL SOTA produit**.

## 21. Gate final du core local et du serveur MCP

Le scope local demandé est désormais fermé : **FULL SOTA vérifié pour le core,
le package et le serveur MCP autonome**, pas pour une release Throttle signée.

- vrai processus stdio testé end-to-end : `initialize`, `tools/list`, `health`,
  `search` ; 38 documents et 440 chunks ;
- clé fixe disponible uniquement en compilation Debug ; le binaire Release
  rejette le flag avant tout accès Keychain ;
- production configurée exclusivement sur Keychain
  `WhenUnlockedThisDeviceOnly`, non synchronisable ;
- origins multi-projet filtrées selon le grant avant persistance et citation ;
- backup evidence compte désormais reçus, documents et chunks, puis prouve la
  recherche du document après restauration sous une nouvelle clé ;
- helper Release : aucun `libsqlite3`, symboles SQLite résolus par
  `SQLCipher.framework` uniquement ;
- bundle final non signé et non installé :
  `/private/tmp/research-vault-mcp-20260827-final`, 4,8 Mo ;
- SHA-256 du helper :
  `3e91ba9fef20e4b89a4b49bd2d45618f3cb4566e2c3c4506597c01d89dfadb96` ;
- manifest `SHA256SUMS` : tous les fichiers `OK` ;
- Gitleaks sur le package : zéro secret ; `git diff --check` : propre.

Limites séparées : le helper n’est ni signé, ni embarqué, ni installé, ni
enregistré dans un client MCP. Ces actions modifient le produit ou l’état local
et nécessitent leurs propres gates de signature/link-map/autorisation. Le
warning `watchOS(.v4)` vu sous Xcode 27 provient du manifeste officiel
SQLCipher.swift 4.18.0 ; aucun warning contrôlé n’a été masqué.

## 22. Checkpoint XPC embarqué et synthèse hybride — 2026-08-27 18:16 Europe/Paris

Le helper est désormais réellement embarqué, mais toujours non signé et non
enregistré :

- cible Xcode `ResearchVaultAgent`, LaunchAgent sous
  `Contents/Library/LaunchAgents` et app agent sous
  `Contents/Library/LoginItems` ;
- `SMAppService` explicite, sans auto-enregistrement au lancement ;
- build Release complet Throttle : `BUILD SUCCEEDED` sur le graphe de 104
  targets avec DerivedData et clones de packages isolés ;
- gate `Scripts/verify-research-vault-bundle.sh` : PASS sur le bundle exact ;
- Throttle conserve son `libsqlite3`/GRDB existant et ne charge pas SQLCipher ;
  l'agent charge son SQLCipher embarqué et aucun `libsqlite3` système ;
- `ResearchVaultSynthesis` formalise retrieval-only, MLX same-device et serveur
  privé authentifié ; 4/4 tests de routage sécurité passent ;
- vérification complète du package repassée après intégration : Debug, Release,
  crash recovery, IPC, benchmark/MCP DeepSearsh et refus stdio Release verts.

Gate non franchie : zéro identité de signature valide sur la machine au moment
du test. Les exigences Team ID/bundle ID, clients négatifs, enregistrement
launchd, Keychain/App Sandbox, runtime `dladdr` et intégration CheatCode restent
ouverts. Verdict : **GO implémentation locale non signée ; NO-GO livraison
cross-app/production**.
