# Throttle : workflow, contexte et choix de Rust

Recherche au 8 septembre 2026 · Pour Kevin · Décisions pour l’ensemble des projets pilotés avec Throttle

## Décision proposée

**Priorité au contexte pertinent et aux preuves de résultat. Rust reste un choix par composant.** Throttle possède déjà une partie importante des mécanismes envisagés. La prochaine étape utile consiste à les mesurer ensemble sur nos tâches, puis à corriger les limites démontrées.

Confiance **élevée** dans cette direction ; confiance **insuffisante** pour déclarer le workflow actuel « SOTA » ou chiffrer un gain de productivité. Nous avons examiné des sources et du code, sans exécuter une comparaison des workflows ni qualifier l’application installée.

Trois décisions :

1. Renforcer l’existant `plan-store` et la qualité des preuves, sans recréer un second système de tâches.
2. Évaluer la chaîne complète du contexte : trouver, sélectionner, transmettre, conserver et réactualiser les bonnes informations.
3. Garder Swift/SwiftUI pour nos applications Apple ; envisager Rust pour les composants partagés, les protocoles, les outils système et les services dont les contraintes le justifient.

## 1. Ce que signifie « SOTA » pour nous

Une architecture récente ou une collection de modèles ne suffit pas. Pour nos usages, une amélioration doit augmenter le nombre de résultats acceptés, réduire le temps de contrôle et de reprise de Kevin, et préserver les contraintes de sécurité et de confidentialité.

Les indicateurs principaux seraient : résultat accepté, temps humain actif, délai total, coût complet des tentatives, corrections après validation et temps de reprise après interruption. Les tokens, le nombre de commits et les tests exécutés sont des indicateurs intermédiaires.

Ce choix correspond au déplacement du travail vers la vérification et l’intégration décrit par DORA, mais les données DORA sont observationnelles : elles ne démontrent pas un effet causal pour notre portefeuille. [DORA, 10 mars 2026](https://dora.dev/insights/balancing-ai-tensions/)

### Pourquoi les études de productivité semblent se contredire

| Preuve | Résultat rapporté | Limite pour notre décision |
|---|---|---|
| Essai METR, juillet 2025 | 16 développeurs expérimentés, 246 tâches : 19 % de temps supplémentaire avec les outils IA étudiés | Dépôts familiers et outils du début 2025 ; pas notre environnement de septembre 2026 |
| Trois essais en entreprise, publication février 2026 | 4 867 développeurs ; estimation de 26,08 % de tâches supplémentaires | Assistant de complétion, contextes différents ; pas une mesure de notre orchestration |
| Suivi METR, février 2026 | Signaux de gains, mais les auteurs jugent l’estimation peu fiable | Sélection des participants et tâches, rémunération modifiée, temps difficile à mesurer avec plusieurs agents |

Sources : [METR 2025](https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/), [Cui et al., Management Science](https://pubsonline.informs.org/doi/abs/10.1287/mnsc.2025.00535), [METR 2026](https://metr.org/blog/2026-02-24-uplift-update/).

**Conclusion :** les gains dépendent du travail, du modèle et de l’organisation. Les témoignages de l’entretien donnent des pistes ; ils ne prouvent ni un multiplicateur universel ni que les seniors bénéficient toujours davantage de l’IA.

## 2. Baseline locale : ce qui existe réellement

Lecture effectuée dans le dépôt principal, branche `feat/research-vault-lots-1-4`, HEAD `ce083dec72bd06b8c4ba2b6e379e6de3424b5da7`. L’état Git initial contenait seulement `.install-backups/` non suivi. Le worktree `plan-store`, HEAD abrégé `42f26e9`, a également été consulté. Leur présence ne démontre pas leur intégration dans l’application installée.

| Capacité | Observation dans les fichiers actuels | Conséquence |
|---|---|---|
| Suivi par tâche | `PlanModels`, `PlanStore` et `PlanProjection` existent dans le worktree `plan-store` : journal, propriétaire, revue, vérification et intégration | Améliorer ce modèle existant |
| Validation liée au code | `TaskIntegrationService` associe la vérification aux SHA de la tâche et de la base ; l’intégration compare le reçu à cet état et vérifie la propreté | La liaison Git existe déjà ; examiner son extension au contrat de test, à l’environnement et aux artefacts |
| Exécution de vérification | Commande configurable, temporisation, gestion des processus ; verdict issu du résultat du processus | Pour les suites critiques, ajouter un reçu final structuré et un périmètre attendu au contrat de commande |
| Coût et tests | `TestOutcomeDetector` reconnaît des résumés textuels ; `TestOutcomeStore` calcule un coût par exécution verte | Un résumé de terminal reste un signal, pas une preuve complète d’acceptation |
| Réduction du contexte | `ContextFirewall` sélectionne des extraits exacts, numérotés, et peut conserver l’original par identifiant | Mesurer ce qui manque dans les extraits, pas seulement ce qui a été économisé |
| Réhydratation | `ContentStore` conserve des blocs ; purge par défaut à 30 jours ; échec de stockage possible | Un pointeur n’est pas une archive durable et doit avoir un état de disponibilité explicite |
| Recherche de code | `SemanticIndex.searchHybrid` reclasse des candidats denses par recouvrement lexical, ou utilise un repli lexical | Ce n’est pas équivalent à deux recherches indépendantes BM25+dense fusionnées par RRF |
| Recherche interprojets | `GlobalRAGService` classe notamment les métadonnées par recouvrement lexical, avec bonus de portée/configuration | Le score n’est pas une probabilité que le résultat soit correct ou suffisant |
| Évaluation du contexte | Research Vault contient des métriques de récupération et de citations ; deux expériences de réduction/délégation existent | Réutiliser les instruments, vérifier leur branchement effectif et élargir les cas |
| Langage Apple | `project.yml` déclare Swift 6.0 et la concurrence stricte | Nous disposons déjà d’un compilateur contraignant |

Références locales : [PlanModels](/Users/kevinnadjarian/GitHub/Throttle/.claude/worktrees/plan-store/Throttle/Models/PlanModels.swift), [intégration](/Users/kevinnadjarian/GitHub/Throttle/.claude/worktrees/plan-store/Throttle/Services/TaskIntegrationService.swift), [vérification](/Users/kevinnadjarian/GitHub/Throttle/.claude/worktrees/plan-store/Throttle/Services/TaskIntegrationServiceVerify.swift), [résultats de tests](/Users/kevinnadjarian/GitHub/Throttle/Throttle/Services/TestOutcomeStore.swift), [ContextFirewall](/Users/kevinnadjarian/GitHub/Throttle/Throttle/Services/ContextFirewall.swift), [ContentStore](/Users/kevinnadjarian/GitHub/Throttle/Throttle/Services/ContentStore.swift), [SemanticIndex](/Users/kevinnadjarian/GitHub/Throttle/Throttle/Services/SemanticIndex.swift), [GlobalRAG](/Users/kevinnadjarian/GitHub/Throttle/Throttle/Services/GlobalRAGService.swift), [métriques](/Users/kevinnadjarian/GitHub/Throttle/Packages/ResearchVaultKit/Sources/ResearchVaultIngestion/RetrievalQualityGate.swift), [configuration](/Users/kevinnadjarian/GitHub/Throttle/project.yml).

### Un résultat local qui justifie la priorité contexte

L’audit DeepSearsh/Research Vault du 4 septembre rapporte, sur 60 vraies questions dont 43 répondables, un Recall@5 de 0,568 pour la fusion RRF et un problème non résolu d’abstention. Il relève aussi une ancienne dégradation silencieuse de la recherche dense.

Ce sont **des mesures historiques lues dans un rapport**, non reproduites aujourd’hui. Le Recall@5 n’est pas le pourcentage de tâches finalement réussies. Le rapport démontre surtout l’intérêt d’un jeu de vraies questions et de l’observation des replis. Sa recommandation d’un reranker reste à tester ; elle ne constitue pas une loi universelle.

La documentation de l’expérience de délégation locale précise elle-même que quatre cas sont trop peu pour borner un taux d’échec. L’expérience de réduction de logs distingue également corpus synthétique et validation sur des traces représentatives. [Audit local du 4 septembre](/Users/kevinnadjarian/GitHub/DeepSearsh/library/audits-and-reviews/deepsearsh/20260904--retrieval-audit-deepsearsh-research-vault--a84063aea5.md), [délégation](/Users/kevinnadjarian/GitHub/Throttle/experiments/local-delegation-bench/README.md), [réduction de logs](/Users/kevinnadjarian/GitHub/Throttle/experiments/local-context-refinery/README.md).

## 3. Gestion du contexte : ce que nous devrions améliorer

### A. Garder un socle court, stable et applicable

Conserver les contraintes de travail et les particularités difficiles à découvrir dans le code. Déplacer les guides spécialisés vers des skills chargés au besoin. Évaluer les répétitions, contradictions et instructions devenues inutiles avant toute suppression.

L’étude *Evaluating AGENTS.md*, version du 23 juin 2026, ne trouve pas d’amélioration générale du succès dans ses configurations et constate plus de 20 % de coût supplémentaire en moyenne. Elle souligne toutefois l’utilité des conventions non standard. Ce n’est pas une invitation à enlever les contraintes importantes. [Gloaguen et al.](https://arxiv.org/abs/2602.11988)

Anthropic rapporte, en juillet 2026, avoir fortement réduit son propre prompt système sans perte mesurable dans ses évaluations. C’est un résultat fournisseur, spécifique à ses modèles et tests. Pour nous : réévaluer les anciennes règles, sans recopier ce taux de réduction. [Anthropic, 24 juillet 2026](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models)

Les mécanismes des fournisseurs diffèrent : Codex documente une découverte hiérarchique d’AGENTS.md ; Claude Code documente CLAUDE.md et peut y importer AGENTS.md. Les skills utilisent un chargement progressif. Une configuration commune doit conserver ces différences et respecter l’intention actuelle de Kevin. [OpenAI : AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md), [OpenAI : skills](https://learn.chatgpt.com/docs/build-skills), [Claude Code : mémoire](https://code.claude.com/docs/en/memory).

### B. Distinguer quatre types de contexte

| Type | Contenu utile | Politique proposée |
|---|---|---|
| Contraintes | Autorisations, périmètre, règles de sécurité | Conserver précisément ; faire appliquer les limites sensibles par les outils |
| État de la tâche | Objectif, décisions, changements, blocage, prochaine étape | Petit état structuré, révisé à chaque jalon |
| Sources de travail | Code courant, protocoles, diagnostics, tests | Récupération ciblée avec chemin, version et accès à l’original |
| Connaissance durable | Décisions réutilisables, recherche, leçons | Provenance, date, portée, statut et conditions de revalidation |

Cette proposition s’appuie sur les stratégies de récupération à la demande et de notes structurées d’Anthropic. Elle reste à mesurer dans Throttle. [Context engineering, septembre 2025](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)

Un préprint d’août 2026 observe une perte de règles lors de compactions répétées et propose des politiques par type d’information. C’est une alerte expérimentale, pas une mesure des sessions actuelles de Kevin. [The Compaction Cliff](https://arxiv.org/abs/2608.22752)

### C. Trouver les bons fichiers avant de compresser davantage

Comparer, sur les mêmes tâches : recherche exacte, navigation par symboles, recherche lexicale, recherche dense multilingue, fusion des candidats et reranking. Inclure les questions françaises visant du code ou une documentation anglaise.

Deux résultats récents empêchent de choisir une architecture uniquement sur sa réputation : *ContextBench* mesure la récupération intermédiaire sur 1 136 tâches ; *Agent Retrieval Bench* constate que les familles de recherche gagnantes diffèrent selon les tâches et les budgets. Le second inclut aussi des cas sans réponse et des contrôles sur le mauvais dépôt. [ContextBench, février 2026](https://arxiv.org/abs/2602.05892), [Agent Retrieval Bench, juillet 2026](https://arxiv.org/abs/2607.24882).

**Recommandation :** essayer une vraie union lexicale+dense puis un reranker comme variantes expérimentales. Garder `rg` et les références de symboles comme baselines. Ne pas lancer une nouvelle architecture de mémoire avant de savoir où la chaîne actuelle perd l’information.

### D. Réduire les répétitions en conservant les diagnostics utiles

Conserver l’erreur primaire, son emplacement et ses explications causales ; replier les répétitions et garder un accès au log complet. Les messages de compilation détaillés ont amélioré les réparations dans une expérience contrôlée sur Shplait. Cette preuve ciblée ne justifie ni les logs intégraux systématiques ni leur résumé agressif. [Type-Error Ablation, juin 2026](https://arxiv.org/abs/2606.01522)

Le rapport Chroma de 2025 montre que la longueur et les distracteurs peuvent dégrader la récupération sur les modèles testés. Il ne fixe pas un seuil universel valable pour les modèles actuels. [Context Rot](https://www.trychroma.com/research/context-rot)

**Point crucial pour Throttle : stocker l’original ne garantit pas que l’agent pensera à le rouvrir.** La réversibilité des octets et la conservation des informations nécessaires au raisonnement sont deux propriétés différentes. Mesurer les omissions, les demandes de réhydratation et le succès final.

### E. Respecter les mécanismes natifs et le cache

La compaction de Responses peut contenir des éléments opaques chiffrés. Son contrat API ne doit pas être assimilé à un format de transcription portable entre fournisseurs. Conserver le mécanisme natif ; transporter entre agents un état de travail explicite et des références vérifiables. [OpenAI : compaction](https://developers.openai.com/api/docs/guides/compaction)

Le cache de prompt réutilise un préfixe commun : il évite du calcul mais ne remplace ni une mémoire documentaire ni la sélection de contexte. Séparer socle stable et faits variables ; mesurer les lectures de cache disponibles, en distinguant coûts estimés et dépenses réelles. Ne pas supposer que Throttle contrôle l’assemblage interne de chaque client natif. [OpenAI : prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)

## 4. Workflow : renforcer les preuves, limiter les boucles

Le contrat d’une tâche devrait préciser son résultat attendu et les vérifications pertinentes. Le reçu de validation devrait identifier : dépôt/worktree, état du code, commande, environnement, périmètre, résultat final et artefacts. Une nouvelle modification doit rendre visibles les preuves à refaire.

Pour le chemin d’intégration propre, conserver les garde-fous Git existants. Pour les diagnostics effectués sur un arbre modifié, une identité HEAD seule est insuffisante : ajouter une empreinte des entrées pertinentes. Ne pas exiger de commit simplement pour enregistrer une preuve locale.

Étendre le reçu existant avec une identité du contrat de vérification et de l’environnement. Un script qui sort en zéro prouve ce que ce script vérifie réellement ; pour XCTest, par exemple, un résultat final exploitable apporte plus qu’une phrase détectée dans un terminal.

Anthropic distingue explicitement le résultat observé dans l’environnement et ce que l’agent raconte. Ses guides recommandent des évaluateurs adaptés et calibrés. Dans une autre étude de cas, l’entreprise a également retiré de l’orchestration devenue superflue avec de nouveaux modèles. [Évaluations d’agents, janvier 2026](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents), [Conception de harness, mars 2026](https://www.anthropic.com/engineering/harness-design-long-running-apps).

La branche `plan-store` exige déjà une autre famille de runtime pour certains verdicts. C’est une diversité utile, mais **deux modèles peuvent partager une erreur**. Le critère décisif reste une vérification du comportement, issue du besoin et indépendante des choix d’implémentation. Une revue différente complète cette preuve.

Pour les simulations, viser les machines à états de Throttle : interruption du handoff, événements dupliqués/désordonnés, fournisseur indisponible, journal tronqué, disque plein et résultat périmé. FoundationDB fournit un exemple de pannes reproductibles par graine ; cela ne prouve pas tous les comportements possibles d’une application. [FoundationDB](https://apple.github.io/foundationdb/client-testing.html)

### Valeur propre de Throttle

Cursor documente déjà des environnements isolés et des artefacts de vérification comme captures et logs. Leur existence ne prouve pas leur qualité ni leur disponibilité dans nos comptes. [Cursor Cloud Agents](https://cursor.com/docs/cloud-agent)

Notre hypothèse de valeur : **une continuité locale, vérifiable, entre projets et fournisseurs**, avec une présentation claire de ce qui reste à faire. Elle doit être démontrée par une réduction du contrôle et des reprises, avant de justifier une extension du produit.

## 5. Rust : avantages et inconvénients pour les futurs projets

| Avantage | Coût ou limite |
|---|---|
| Sûreté mémoire et prévention des data races en Safe Rust | Ne couvre pas les erreurs métier, deadlocks, autorisations ou toutes les races logiques ; `unsafe` et FFI ajoutent des obligations |
| Diagnostics de compilation exploitables par un agent | Types, traits, lifetimes et async peuvent aussi multiplier les itérations |
| Contrôle des ressources et performances natives | Le gain d’une application dépend des algorithmes, I/O et architectures ; il faut le mesurer |
| Cœur partagé entre plateformes | Bindings, conversions, builds et cycles de vie interlangages à maintenir |
| Éditions et écosystème structurés | Les éditions peuvent introduire des changements incompatibles opt-in ; les crates et versions minimales évoluent |

Sources : [Rustonomicon : races](https://doc.rust-lang.org/nomicon/races.html), [éditions Rust](https://doc.rust-lang.org/edition-guide/editions/), [enquête Rust 2025 publiée en mars 2026](https://blog.rust-lang.org/2026/03/02/2025-State-Of-Rust-Survey-results/), [UniFFI : async](https://mozilla.github.io/uniffi-rs/latest/futures.html).

Les lenteurs de compilation et l’espace disque restent des préoccupations déclarées dans l’enquête Rust. Pour nous, elles comptent parce qu’elles allongent la boucle de retour de l’agent. UniFFI facilite l’interopérabilité, mais sa documentation actuelle ne promet pas une propagation générique directe de l’annulation : ce comportement doit être conçu et vérifié.

**La preuve favorable à Rust n’est pas une preuve de supériorité pour l’IA.** Google décrit des résultats industriels favorables dans Android par rapport au C++. C’est observationnel et cela ne compare pas Rust à Swift avec nos agents. [Google, novembre 2025](https://blog.google/security/rust-in-android-move-fast-fix-things/)

À l’inverse, Rust-SWE-bench, accepté à ICSE 2026, recense des difficultés de compréhension du dépôt et de respect des types/traits sur 500 tâches. Les modèles évalués ne sont pas ceux de septembre ; ses scores ne se comparent pas directement à un benchmark Python différent. [Rust-SWE-bench](https://arxiv.org/abs/2602.22764)

Swift 6 apporte déjà une vérification complète des data races dans son mode de langage. Cela ne rend pas automatiquement sûrs les usages qui contournent les contrôles et ne prouve pas la correction fonctionnelle. Throttle déclare ce mode dans sa configuration. [Guide Swift](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/)

### Politique de choix proposée

| Projet | Choix de départ | Quand Rust devient pertinent |
|---|---|---|
| Application Apple native | Swift/SwiftUI | Composant borné dont le partage ou les contraintes sont démontrés |
| Cœur commun Apple/Android | Rust candidat sérieux avec interfaces natives | API compacte, stable, testable, réutilisée réellement |
| CLI, agent système, proxy, protocole, parseur | Rust candidat fort | Entrées non fiables, concurrence, mémoire/latence contraintes |
| Backend CRUD surtout dépendant d’API/BDD | Écosystème maîtrisé et adapté au produit | Besoin mesuré de ressources, partage ou traitement intensif |
| Prototype web ou expérimentation IA | Langage de l’écosystème et des SDK utiles | Extraction ultérieure d’une partie devenue stable et critique |
| Throttle existant | Conserver Swift | Nouveau composant portable évalué séparément |

Ce tableau est une **recommandation**, pas un classement expérimental. Pour un candidat Rust, comparer un seul composant à contrat identique : délai jusqu’à acceptation, temps de compilation, interventions humaines, mémoire, latence et complexité des bindings. Arrêter si le bénéfice ne compense pas la frontière supplémentaire.

## 6. Expériences prioritaires et critères de décision

| Ordre | Expérience bornée | Critère de décision |
|---|---|---|
| 1 | Cartographier quel moteur et quel reçu chaque action réellement utilisée appelle | Identifier le chemin installé, la version, les replis et les preuves manquantes |
| 2 | Réutiliser les vraies questions de récupération ; ajouter mauvais dépôt, question sans réponse, ancien état, français vers anglais | Comparer récupération et abstention séparément ; ne pas améliorer le score en cachant les cas difficiles |
| 3 | Pilote de dix tâches réelles avec reçu enrichi | Vérifier que le dispositif réduit le travail de contrôle ; dix tâches ne prouvent pas un gain statistique |
| 4 | 20–30 cas rejouables de reprise, contexte et faux succès | Détecter les cas critiques prévus, sans nouvelle régression ; répéter les cas variables |
| 5 | Variante de contexte unique à la fois | Comparer contexte actuel, instructions resserrées, récupération améliorée, puis réduction de logs |
| 6 | Composant Rust si un besoin concret apparaît | Conserver uniquement si avantage mesuré face au choix naturel du projet |

Pour les comparaisons : figer versions de modèle/outils et critères, réinitialiser les fixtures, alterner l’ordre des variantes et isoler les tâches. Comptabiliser aussi les abandons, les erreurs d’infrastructure et les tentatives ratées. Sur un petit pilote, publier les résultats bruts et les exemples ; sur une extension suffisante, utiliser des comparaisons appariées et des intervalles d’incertitude.

Mesures contexte : rappel des sources nécessaires, précision, abstention, conservation des diagnostics critiques, tokens réellement disponibles, latence, RAM, réhydratations et réussite finale. Séparer questions répondables et non répondables pour éviter un score agrégé trompeur.

Mesures workflow : tâches acceptées, faux « terminé », minutes humaines, délai, coût estimé complet, reprise et réouvertures à 7–14 jours. Le coût complet inclut les échecs et revues ; il ne se déduit pas simplement de la moyenne des seules exécutions vertes.

Un zéro échec sur une petite batterie constitue un passage de contrôle local, jamais une garantie d’absence de défaut. Définir les seuils et budgets avant de voir les résultats, proportionnellement au risque.

## 7. Sécurité, confidentialité, UX et limites opérationnelles

Le contexte interprojets augmente la portée d’une information périmée ou malveillante. Garder les sources comme données, leur provenance et leur périmètre ; ne pas transformer un ancien accord ou une note extraite en autorisation actuelle. Le filtrage par mots ou une extraction AST ne rend pas une source automatiquement fiable.

Appliquer les contraintes sensibles dans les outils : accès limités, validation des entrées, isolation et protection des secrets. OWASP décrit les risques de contenus et de descriptions d’outils malveillants ; aucune instruction textuelle seule n’établit une frontière de sécurité. [OWASP MCP Security](https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html)

Côté interface, privilégier quatre informations lisibles : **résultat attendu, vérifications, limite restante, prochaine action**. Prévoir navigation clavier, libellés VoiceOver et états compréhensibles sans couleur. Ce sont des critères de conception proposés ; aucune validation d’accessibilité n’a été effectuée ici.

Maintenir les distinctions entre source, tests, build, application installée, essai physique et distribution. Les métadonnées de preuve ne doivent pas embarquer des secrets d’environnement. Les opérations de publication restent séparées du statut d’une tâche de développement.

## 8. Registre des conclusions

`VERIFIED` signifie ici observation directe d’un fichier ou d’un contrat documentaire. `SUPPORTED` signifie résultat étayé mais limité. `HYPOTHESIS` désigne notre proposition à tester. `OPEN` reste non mesuré. `STALE` désigne un état historique à actualiser ; `CONTRADICTED` une généralisation non soutenable.

| Affirmation | Statut | Fondement et limite |
|---|---|---|
| Plan-store contient déjà tâches, revue et vérification liée aux SHA | VERIFIED — source | Fichiers du worktree ; installation non contrôlée |
| Davantage d’instructions rend toujours un agent meilleur | CONTRADICTED | AGENTS.md 2026 ; effets dépendent du contenu et du système |
| Le contexte pertinent est une priorité pour nous | SUPPORTED | Audit local + ContextBench ; gain de notre prochaine variante OPEN |
| Un reranker améliorera forcément Throttle | HYPOTHESIS | Piste cohérente, à comparer aux baselines sur nos questions |
| Réversibilité des données = aucune perte de raisonnement | CONTRADICTED | Conservation externe et utilisation effective ne sont pas équivalentes |
| Une revue par un autre modèle prouve la correction | CONTRADICTED | Accord des modèles insuffisant ; évaluateurs à calibrer |
| Rust fournit des garde-fous utiles | VERIFIED — contrat | Limites de Safe Rust, unsafe/FFI et logique à respecter |
| Rust est le meilleur langage pour tous nos agents | OPEN / non établi | Aucune comparaison pertinente ne permet cette conclusion |
| Le workflow actuellement installé est SOTA | OPEN | Pas de benchmark de bout en bout ni de qualification installée |
| Les chiffres du 4 septembre décrivent la performance actuelle | STALE pour usage courant | Rapport consulté, mesures non rejouées |

## 9. Provenance et portée de la recherche

Les liens proches des affirmations constituent le registre des sources publiques. Documents officiels consultés le 8 septembre 2026 ; les pages sans date sont des documentations évolutives. Les prépublications sont identifiées comme telles. Les principales affirmations des deux recherches déléguées ont été réouvertes par le coordinateur.

Recherche locale réutilisée, sous `/Users/kevinnadjarian/GitHub/DeepSearsh` :

| Document | Identité et origine | Usage |
|---|---|---|
| Audit de récupération — DeepSearsh et Research Vault | `dr-a84063aea5054657`, SHA-256 `a84063aea505465704a61351f43a890b28e6736d8e056d7843614f73cd77fbb7` ; origine `Throttle/docs/research/2026-09-04-retrieval-audit-deepsearsh-research-vault.md` | Anciennes mesures et limites méthodologiques |
| Audit technique de Claude Code : mémoire, context engineering, hooks, subagents, Skills et MCP | `dr-1c7a0321a79cc8fd`, SHA-256 `1c7a0321a79cc8fd9c867d66bb66596c7690f220dfed68e6aec6fc222b79c4fd` ; origine `DeepSearsh/inbox-archive/Audit technique de Claude Code mémoire, context engineering, hooks, subagents, Skills et MCP.md` | Carte historique, contrats fournisseur revérifiés |
| Throttle v3.0 — Deep Technical Investigation: Polyrepo Context Routing | `dr-3b34db7826fc63e0`, SHA-256 `3b34db7826fc63e09245da6fed4679c1d0e61c62fdc8948fe2b56d121c7ba514` ; origine `DeepSearsh/inbox-archive/compass_artifact_wf-fc23c06c-4afb-4191-be1a-2db3bcc5c12d_text_markdown.md` | Hypothèses antérieures ; chiffres et labels non adoptés comme preuves courantes |

La recherche a couvert : corpus local et code actuel ; études de productivité contradictoires ; documentation des agents et du contexte ; benchmarks récents de récupération ; Rust/Swift et interopérabilité. Les recherches ciblées portaient notamment sur « AGENTS.md evaluation », « agent context retrieval », « compaction », « Rust agent compiler feedback », « METR productivity » et « agent eval harness ».

Arrêt après résolution des contradictions qui changent les décisions prioritaires : le reste dépend d’essais locaux, pas d’une accumulation de publications. Hors périmètre : audit complet de chaque projet, comparaison commerciale exhaustive, tests de pénétration, changements de configuration, migrations et release.

Livrable : rapport Markdown temporaire. Aucun code, paramètre, mémoire personnelle, index de recherche ou projet tiers modifié ; aucun corpus privé téléversé. L’outil de planification prescrit par Deep Research n’était pas disponible ; le plan a été suivi dans l’état de travail. Aucun benchmark, build ou contrôle physique n’a été exécuté pendant cette recherche.

**Prochaine étape proposée : établir une baseline reproductible du contexte et des preuves sur les chemins réellement utilisés dans Throttle, puis évaluer une amélioration à la fois.**
