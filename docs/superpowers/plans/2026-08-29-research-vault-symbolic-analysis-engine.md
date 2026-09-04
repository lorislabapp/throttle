# Research Vault — moteur d'analyse symbolique, provenance et rétractation

Date : 2026-08-29  
Statut : plan de mise en place complet, implémentation non commencée  
Cible : après stabilisation des Lots 1 et 2 Research Vault en cours  
Distribution : aucune publication, aucun upload, aucune mutation d'appcast

## Décision

Construire un moteur Swift natif, typé et volontairement limité dans
`ResearchVaultKit`. Lemmalog sert d'oracle différentiel épinglé et de corpus
d'idées ; il ne devient ni une dépendance runtime, ni une autorité, ni un
processus livré dans Throttle.

La première version utilise un recalcul complet déterministe. L'évaluation
incrémentale, la négation et les agrégats ne sont promus qu'après équivalence
mesurée avec cet oracle simple. Les modèles produisent exclusivement des faits
candidats en quarantaine. Ils ne peuvent ni promouvoir un fait, ni installer
une règle, ni attribuer seuls un statut de preuve.

## Résultat produit recherché

Throttle doit pouvoir répondre de façon reproductible :

- pourquoi une conclusion est tenue pour vraie ;
- quelles preuves approuvées la soutiennent ;
- quelles conclusions dépendent d'une source révisée ou retirée ;
- ce qui est contradictoire, remplacé, périmé ou encore ouvert ;
- ce qui a changé entre deux générations du coffre.

Nom produit provisoire : **Analysis State — Why we believe this**. Ne pas
présenter la fonction comme une mémoire autonome ou une source de vérité.

## Baseline fraîche

### Throttle

- Le checkout est volontairement sale ; les modifications existantes restent
  propriété de l'utilisateur et ne doivent pas être stashed, reset ou
  réécrites.
- `ResearchEvidenceStatus` couvre `VERIFIED`, `SUPPORTED`, `HYPOTHESIS`,
  `OPEN`, `CONTRADICTED`, `STALE`.
- Les imports possèdent une frontière `quarantined` / `approved`.
- Les receipts sont scellés et rattachent claims, sources, SHA-256, projet,
  sensibilité et activité d'agent.
- SQLCipher v4 filtre les lectures normales sur les receipts approuvés.
- Le Workbench détecte déjà les différentes versions d'un locator et liste
  les claims directement impactés par leurs `evidenceIDs`.
- BM25 reste la baseline de retrieval ; le challenger dense n'est pas promu.
- L'autorité d'écriture et les clés restent derrière le service XPC Throttle.

Manques actuels : faits typés, dépendances entre claims, règles versionnées,
validité temporelle, fermeture transitive, rétractation, génération dérivée et
graphe de preuve `why`.

### Audit reproductible Lemmalog

Référence auditée : `JordyZomer/lemmalog` commit
`7d6f1541130aba53949a2da90cc3e134cb0aac01`, daté du 2026-08-28.

- Version Cargo `0.1.0`, Rust 2021, licence MIT.
- Environ 9 379 lignes Rust, tests compris ; 16 fichiers source principaux,
  10 suites d'intégration et trois exécutables.
- Pas de `build.rs` observé. Dépendances directes optionnelles :
  `serde_json` et `ureq`.
- Test local `cargo test --all-features -- --skip
  synthetic_long_horizon_suite` : 66 tests passés, zéro échec.
- Les tests vérifiés couvrent notamment oracle naïf, équivalence
  incrémental/rebuild, rétractation, négation stratifiée, temporalité,
  provenance et arbre `why`.
- `synthetic_long_horizon_suite` n'a pas terminé après plus de six minutes en
  Debug et a été interrompu. Il reste `OPEN` et devient un benchmark de risque,
  pas une preuve verte.
- GitHub ne montre pas de CI Rust publique ni de release stable au moment de
  l'audit.

Conclusion : bon oracle de laboratoire ; maturité insuffisante pour une
dépendance d'autorité livrée.

## Fondations de recherche retenues

| Statut | Décision | Preuve / limite |
|---|---|---|
| VERIFIED | Modéliser Entity, Activity, Agent et dérivations, sans imposer RDF. | W3C PROV-DM/PROV-O ; standard d'échange, pas architecture de stockage. |
| VERIFIED | Une provenance riche peut être calculée avec des annotations algébriques. | Green, Karvounarakis, Tannen, *Provenance Semirings* ; la v1 Throttle n'implémente pas le formalisme complet. |
| VERIFIED | Recalcul et maintenance incrémentale doivent être comparés sur la même sémantique. | Littérature DBSP/differential Datalog et tests Lemmalog. |
| VERIFIED | Les CTE récursifs SQLite savent parcourir un graphe. | Documentation SQLite ; insuffisant seul pour règles, preuve et rétractation générale. |
| VERIFIED | La mémoire persistante d'agents est une surface de poisoning. | OWASP Agent Security et travaux primaires 2026 ; impose quarantaine et autorité liée à l'origine. |
| SUPPORTED | Un petit moteur Swift positif suffit au MVP Throttle. | Alignement avec le corpus et les règles ciblées ; à confirmer par golden set. |
| HYPOTHESIS | Les relations symboliques améliorent les scénarios de révision/contradiction sans dégrader BM25. | À mesurer en shadow mode. |
| OPEN | Seuils absolus de latence, mémoire et énergie sur machines supportées. | Doivent être établis par benchmark frais, idle-host et Release. |

Sources primaires :

- W3C PROV : https://www.w3.org/groups/wg/prov/publications/
- Provenance Semirings : https://www.cs.ucdavis.edu/~green/papers/pods07.pdf
- DBSP : https://arxiv.org/abs/2203.16684
- SQLite recursive CTE : https://www.sqlite.org/lang_with.html
- Soufflé : https://github.com/souffle-lang/souffle
- Datafrog : https://github.com/rust-lang/datafrog
- Ascent : https://docs.rs/ascent/latest/ascent/
- OWASP AI Agent Security :
  https://cheatsheetseries.owasp.org/cheatsheets/AI_Agent_Security_Cheat_Sheet.html
- Étude memory poisoning : https://arxiv.org/abs/2606.04329
- Autorité liée à l'origine : https://arxiv.org/abs/2606.24322

## Invariants non négociables

1. Seuls des receipts `approved` peuvent produire des faits de base actifs.
2. Un contenu, un résumé ou une citation ne confère jamais d'autorité.
3. L'origine et la sensibilité sont propagées dans toute dérivation.
4. Une conclusion ne peut pas obtenir une sensibilité inférieure à celle de
   ses prémisses.
5. Une conclusion dérivée ne peut pas être `VERIFIED` automatiquement.
6. Tout résultat dérivé possède un `why` borné jusqu'aux faits de base.
7. Retirer une prémisse invalide toutes les dérivations qui n'ont plus de
   preuve alternative.
8. Les faits dérivés sont un cache reconstruisible, jamais la vérité canonique.
9. Les rule packs sont intégrés, versionnés et hashés par Throttle ; aucune API
   MCP, XPC ou LLM ne permet d'installer une règle.
10. Toute requête reste bornée par projet, sensibilité, taille, profondeur,
    temps et nombre de résultats côté serveur.
11. BM25 reste disponible et indépendant du moteur symbolique.
12. Aucun code Rust, serveur MCP Lemmalog ou corpus de benchmark tiers n'entre
    dans l'app distribuée sans une décision et un gate de supply chain séparés.

## Architecture cible

```text
sources / receipts d'agents / NotebookLM
                    |
                    v
          intake -> quarantaine -> revue humaine
                    |
                    v
          approved ResearchReceipt (canonique)
                    |
            extraction déterministe
          ou candidats LLM quarantined
                    |
                    v
         ResearchVaultReasoning (Swift pur)
          | base facts + rule pack hash
          | full fixed point (oracle v1)
          | proof DAG + change set
                    |
       cache SQLCipher lié à baseGeneration
                    |
        XPC owner/query boundary (DTO bornés)
          |                 |
      Workbench          MCP read-only
```

### Nouveau module

Créer `ResearchVaultReasoning`, dépendant uniquement de
`ResearchVaultModel`. Il ne dépend ni de SQLCipher, ni de XPC, ni de MCP, ni
d'un modèle. Cette cible contient sémantique, évaluateur naïf, proof DAG,
diff/retraction et fixtures.

`ResearchVaultSQLCipher` persiste les faits de base et un cache dérivé identifié
par `(baseGeneration, rulePackID, rulePackHash, engineVersion)`. Un mismatch
supprime/reconstruit le cache de façon fail-closed.

### Contrat minimal

```swift
public struct ResearchFact: Codable, Hashable, Sendable {
    public let id: String
    public let predicate: ResearchPredicate
    public let arguments: [ResearchTerm]
    public let projectKey: String
    public let sensitivity: ResearchSensitivity
    public let validFrom: Date?
    public let validUntil: Date?
    public let assertedAt: Date
    public let evidenceIDs: [String]
    public let sourceReceiptIDs: [String]
}

public struct ResearchDerivation: Codable, Hashable, Sendable {
    public let conclusionFactID: String
    public let ruleID: String
    public let premiseFactIDs: [String]
}
```

Les identifiants sont dérivés d'une sérialisation canonique versionnée. Les
dates sont des intervalles demi-ouverts `[validFrom, validUntil)` ; l'absence de
borne signifie inconnue, pas éternelle. `assertedAt` reste distinct de la date
de validité métier.

### Relations MVP

- `supports(claim, evidence)`
- `contradicts(claimA, claimB)`
- `supersedes(newClaim, oldClaim)`
- `dependsOn(claim, premise)`
- `validAt(claim, instant)`
- vues dérivées : `impacted`, `stale`, `current`, `unresolvedContradiction`

Le MVP n'inclut pas : règle textuelle libre, négation non stratifiée,
agrégats, fuzzy entity merge, probabilités, actions autonomes ou write MCP.

## Programme de deep research restant

Chaque workstream s'arrête lorsque son critère est satisfait. Les résultats
doivent être ajoutés à un ledger avec `VERIFIED/SUPPORTED/HYPOTHESIS/OPEN`.

### R1 — Sémantique produit et golden scenarios — P0

Questions : quelles conclusions réelles les utilisateurs veulent-ils voir
rétractées ? Quelle différence compréhensible entre contradiction,
supersession, stale et absence de preuve ?

Travail : annoter 50 à 100 scénarios réels désensibilisés issus de recherches
Throttle, avec état avant/après révision, conclusions attendues et preuve.

Stop gate : deux annotateurs obtiennent un accord documenté sur le résultat
attendu ; chaque relation MVP possède cas positif, négatif, ambigu et temporel.

### R2 — Sémantique Datalog minimale — P0

Comparer recalcul naïf, semi-naïf, DRed/scoped recompute, Datafrog, Ascent et
Lemmalog sur les seuls besoins du golden set. Formaliser sûreté des variables,
stratification, terminaison et déduplication.

Stop gate : une spec exécutable définit le fixed point positif et un oracle
naïf ; les zones non prouvées restent exclues de la v1.

### R3 — Provenance et preuves alternatives — P0

Décider si le proof DAG conserve toutes les preuves ou seulement un ensemble
minimal déterministe ; étudier explosion combinatoire, cycles et pagination.

Stop gate : retirer une preuve conserve correctement une conclusion soutenue
par une preuve alternative ; `why` reste borné et signale explicitement la
troncature.

### R4 — Temps et révisions — P0

Valider temps de validité versus temps d'observation, bornes inconnues,
événements rétroactifs, clock skew et source corrigée.

Stop gate : table de vérité complète pour les intervalles et tests de voyage
dans le temps ; aucune date manquante n'est transformée en vérité permanente.

### R5 — Extraction et résolution d'entités — P0

Comparer extraction déterministe, structured output local et saisie manuelle.
Mesurer précision/rappel séparément ; tester noms proches, alias, homonymes,
dates relatives, négation et citations incomplètes.

Stop gate : aucune extraction automatique ne contourne la quarantaine ; un
alias ambigu produit `OPEN`, jamais un merge silencieux. Les seuils de qualité
sont préenregistrés après annotation, pas choisis après les résultats.

### R6 — Threat model et memory poisoning — P0

Tester source hostile, prompt indirect, trusted-tool echo, summarization
laundering, corroboration Sybil, rule injection, explosion de graphe,
cross-project inference et sensibilité déclassée.

Stop gate : origine non malléable conservée de la source à chaque conclusion ;
zéro promotion, règle ou élargissement de scope par contenu.

### R7 — UX, accessibilité et erreurs humaines — P1

Prototyper `Why`, `What changed`, contradiction et retraction. Tester clavier,
VoiceOver, Reduce Motion, grands graphes, preuve tronquée et source absente.

Stop gate : un utilisateur peut distinguer fait de base, conclusion dérivée et
hypothèse sans explication externe ; toutes les fonctions essentielles sont
accessibles sans visualisation graphique.

### R8 — Performance, énergie et packaging — P1

Mesurer Release sur corpus 1k/10k/100k faits, graphes profonds/larges,
rétractation massive, cold/warm start, mémoire et énergie. Comparer full
rebuild, scoped recompute, Lemmalog et BM25 seul.

Stop gate : budgets établis sur machine idle avec variance et artefact de
mesure ; aucun seuil n'est déclaré réussi depuis un run Debug ou un hôte
saturé.

### R9 — Licence et supply chain — P1

Conserver commit, archive hash, licence MIT, SBOM et liste des dépendances de
l'oracle. Confirmer qu'aucun dataset LongMemEval/LoCoMo n'est redistribué sans
droits explicites.

Stop gate : oracle reproductible en développement et absent du graphe de
dépendances/bundle Release.

## Lots d'implémentation

### Gate préalable G0 — stabiliser le chantier existant

- Terminer ou isoler explicitement les Lots 1/2 actuels.
- Snapshot frais `git status`, writers actifs, version, tests package et build
  app.
- Ne pas ouvrir simultanément une migration SQLCipher concurrente.
- Créer un ADR décidant moteur Swift + oracle Lemmalog non livré.

Sortie : baseline reproductible. Si les lots existants ne sont pas verts, ce
plan reste en attente.

### Lot A — corpus, oracle et contrats

Fichiers prévus :

- `docs/adr/0003-symbolic-analysis-engine.md`
- `Packages/ResearchVaultKit/Tests/Fixtures/ReasoningGoldenSet/`
- `Packages/ResearchVaultKit/Tests/Fixtures/LemmalogOracle/manifest.json`
- `Packages/ResearchVaultKit/Sources/ResearchVaultReasoning/ResearchFact.swift`
- `Packages/ResearchVaultKit/Sources/ResearchVaultReasoning/ResearchRule.swift`

Étapes : figer golden scenarios, sérialisation canonique, prédicats, termes,
intervalles, rule pack et format d'oracle. Aucun moteur encore.

Gate A : fixtures hashées, déterministes, sans donnée restricted et validées
manuellement.

### Lot B — oracle Swift par recalcul complet

Créer évaluateur positif naïf : validation de règles, joins déterministes,
fixed point, déduplication, limites de ressources et erreurs typées.

Tests : ordre d'insertion, idempotence, cycles positifs, règle unsafe,
terminaison, sérialisation, fuzz parser si un parser existe. Préférer des règles
Swift typées sans parser dans cette phase.

Gate B : même résultat byte-stable pour tous les ordres d'entrée ; zéro règle
unsafe acceptée ; 100 % du golden set.

### Lot C — proof DAG et rétractation par rebuild

Ajouter dérivations, preuves alternatives, `why`, `impacted`, `whatChanged`.
Une rétractation déclenche d'abord un rebuild complet ; comparer avant/après.

Gate C : aucune resurrection de conclusion ; chaque conclusion possède une
preuve valide ; preuve alternative correctement conservée.

### Lot D — persistence SQLCipher v5

Migration additive et transactionnelle :

- `reasoning_base_facts`
- `reasoning_fact_evidence`
- `reasoning_generations`
- `reasoning_derived_cache`
- `reasoning_derivations`

Le cache porte base generation, rule pack hash et engine version. Backup,
restore, crash au milieu de migration et rollback doivent être testés.

Gate D : v4→v5, fresh v5, rollback et reopen verts ; les quarantined ne créent
aucun fait ; mismatch de génération purge le cache.

### Lot E — projection de receipts vers faits candidats

Créer une projection déterministe pour les relations explicites. Ajouter
ensuite un extractor local optionnel en structured output, dont chaque sortie
reste `OPEN` et quarantined avec origine liée.

Gate E : aucun fait actif sans revue ; toute citation résout vers un source ID
du receipt ; refus fail-closed des entités/dates ambiguës.

### Lot F — XPC et gateway shadow mode

DTO bornés : `ReasoningQuery`, `ReasoningResult`, `ProofPage`, `ChangeSet`.
L'autorisation est calculée côté service depuis l'identité et intersectée avec
projet/sensibilité. Activer le calcul en shadow sans modifier les réponses BM25.

Gate F : zéro différence sur comportement production existant ; zéro fuite
cross-scope ; timeouts et caps prouvés ; Release direct stdio toujours refusé.

### Lot G — comparaison différentielle Lemmalog

Convertir uniquement le sous-ensemble commun du golden set. Comparer oracle
Swift, moteur Swift optimisé éventuel et commit Lemmalog épinglé. Générer des
petits programmes aléatoires valides et injecter additions/retraits.

Gate G : 10 000 programmes déterministes en CI locale et campagne étendue
100 000 avant promotion ; full rebuild == incrémental ; chaque divergence est
un blocker, jamais une tolérance.

### Lot H — incrémentalité optionnelle

Implémenter semi-naïf pour additions, puis scoped recompute pour retraits.
Conserver un mode rebuild de contrôle et une vérification échantillonnée en
Debug/diagnostic.

Gate H : équivalence byte-stable avec rebuild, gain Release statistiquement
significatif et aucun dépassement mémoire/énergie. Sinon conserver rebuild.

### Lot I — Workbench

Ajouter vues textuelles accessibles :

- `Why we believe this`
- `What changed`
- `Impacted claims`
- `Unresolved contradictions`
- indicateur base/derived/hypothesis et génération du moteur.

Le graphe visuel est secondaire et ne remplace jamais la liste VoiceOver.

Gate I : navigation claim→proof→source exacte ; clavier/VoiceOver ; preuve
tronquée explicitement ; essentiel utilisable sans modèle.

### Lot J — MCP read-only

Exposer après shadow :

- `research_vault_why`
- `research_vault_what_changed`
- ressources paginées de proof.

Aucun outil d'installation de règle, de promotion ou de rétractation. Les
mutations restent owner-only et à confirmation humaine.

Gate J : réponses bornées, citations exactes, absence de contenu sensible sur
stderr, compatibilité protocoles existants et tests de payload hostile.

### Lot K — hardening et readiness locale

- Property tests, mutation tests des règles et fuzz.
- Corpus poisoning, denial-of-service et cross-project.
- Crash recovery, backup/restore, migration et corruption.
- Debug + Release package, app build, strict concurrency, SwiftLint,
  `git diff --check`, secret scan, SBOM/licences.
- Runtime clavier/VoiceOver et benchmark idle-host.

Gate K : GO local seulement. Signature, notarisation, Sparkle, site et appcast
restent des gates de release séparés avec autorisation exacte.

## Matrice de validation

| Dimension | Critère de promotion |
|---|---|
| Correction | Golden set 100 %, rebuild/incrémental identiques, zéro divergence oracle. |
| Provenance | 100 % des dérivés ont une preuve jusqu'à des receipts approved. |
| Rétractation | Zéro conclusion ressuscitée sans preuve alternative active. |
| Sécurité | Zéro promotion implicite, règle injectée, fuite de scope ou downgrade de sensibilité. |
| Extraction | Précision/rappel publiés avec ambiguïtés ; échec = quarantaine ou OPEN. |
| Retrieval | Aucun recul MRR/nDCG/abstention/citation de la baseline BM25. |
| Performance | Budgets Release idle-host préenregistrés et respectés aux tailles cibles. |
| Résilience | Migration, crash, backup/restore et cache invalidation reproductibles. |
| UX/A11y | Preuve exacte navigable au clavier et VoiceOver, sans dépendre d'un graphe. |
| Supply chain | Oracle épinglé, licencié, hashé et absent du bundle Release. |

## Critères d'arrêt / NO-GO

- Le golden set ne montre pas de gain produit au-delà de la vue revisions
  actuelle : arrêter le moteur, améliorer uniquement la projection UI.
- L'extraction ne sépare pas fiablement fait, négation et hypothèse : garder la
  saisie/revue manuelle, ne pas automatiser.
- Le moteur Swift diverge de l'oracle naïf : ne pas intégrer SQLCipher/XPC.
- L'incrémental diverge ou n'apporte pas de gain significatif : conserver le
  rebuild complet.
- Le proof DAG ne peut pas être borné sans perdre l'honnêteté de la réponse :
  afficher `truncated` et paginer ; ne jamais résumer comme preuve complète.
- Une autorité peut être élevée par contenu ou corroboration non indépendante :
  NO-GO production.
- Lemmalog apparaît dans le link graph ou le bundle Release : NO-GO tant qu'une
  décision explicite de distribution Rust n'est pas approuvée.

## Ordre recommandé

```text
G0 stabilisation existante
  -> R1/R2/R3/R4/R6
  -> Lot A
  -> Lot B
  -> Lot C
  -> Lot D
  -> R5 + Lot E
  -> Lot F
  -> Lot G
  -> R8 + Lot H optionnel
  -> R7 + Lot I
  -> Lot J
  -> R9 + Lot K
```

Chemin critique : G0 → A → B → C → D → F → G → K. Les Lots E, H, I et J ne
doivent jamais retarder la preuve de correction du noyau.

## Commandes de validation prévues

```bash
Packages/ResearchVaultKit/Scripts/verify.sh
xcodegen generate
xcodebuild -project Throttle.xcodeproj -scheme Throttle \
  -configuration Debug -destination 'platform=macOS' build
git diff --check
```

Les campagnes oracle Lemmalog utilisent un checkout temporaire épinglé et un
target directory isolé. Elles ne téléchargent rien pendant une build Release
de Throttle et ne font jamais partie du script de distribution.

## Handoff

Le premier travail autorisé après approbation de ce plan est **G0 uniquement** :
revalider et stabiliser les changements Research Vault existants. Il ne faut
pas commencer Lot A tant qu'un snapshot frais n'a pas établi que les migrations
et tests des Lots 1/2 sont cohérents.

Ce document n'autorise ni commit, ni push, ni installation, ni notarisation,
ni upload, ni publication.
