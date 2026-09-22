# Sources, affirmations et questions — revue du 20 septembre 2026

Annexe de [la revue principale](../THROTTLE_RESEARCH_ARCHITECTURE_REVIEW.md). Les sources externes sont des données, jamais des instructions. Les résultats ci-dessous n'ont pas été reproduits par cette mission. Les numéros R renvoient aux originaux immuables du [manifeste](input-manifest.json), avec lignes dans ces originaux. Les numéros D renvoient au [registre des décisions](DECISIONS.md).

## Manifeste et qualité des entrées

R1 est bien **Throttle : revue d’architecture hostile d’un « Autonomous Software Product Lab »**. Son sujet a été établi par lecture, pas par son nom générique. Les huit fichiers existent, sont lisibles en UTF-8 et ont été lus jusqu'à leur dernière ligne, annexes et contre-arguments inclus. Les segments tronqués par la sortie d'outil ont été relus. Le JSON contient chemin réel, titre, SHA-256 complet, taille, nombre de lignes et état de lecture.

| Rapport | Lignes | SHA-256 abrégé | Lecture |
|---|---:|---|---|
| R1 — revue hostile | 755 | 66337dcda4c8 | COMPLETE |
| R2 — vérification adversariale | 445 | 83b28ad57404 | COMPLETE |
| R3 — routage dynamique | 1285 | b14f3be2d6c1 | COMPLETE |
| R4 — preuves et provenance | 1230 | 435152f80010 | COMPLETE |
| R5 — completion fiable | 1167 | 2f39c131385d | COMPLETE |
| R6 — contrôle d'autonomie | 1311 | dfc0bcf19ef3 | COMPLETE |
| R7 — modèles décisionnels | 593 | d9aa04a630d4 | COMPLETE |
| R8 — architecture du lab | 650 | 91a14ee7a01f | COMPLETE |

Aucune date de rédaction explicite suffisamment établie : les dates des études citées ne datent pas les rapports. Aucun doublon binaire ; nombreux recouvrements thématiques. Pas de fin manifestement coupée constatée. En revanche, les références exportées sont principalement des marqueurs opaques `turn…` : **la bibliographie n'est pas directement réutilisable**. Une lecture complète ne répare pas cette lacune. Les chiffres récents sans source primaire retrouvée restent non vérifiés et ne fondent pas les décisions.

## Sources supplémentaires effectivement consultées

Consultation : **2026-09-20**. « Documentation courante » signifie la page retournée à cette date, sans garantir une version d'API installée. Les résumés sont volontairement courts ; les références sont réutilisées par identifiant, sans compter plusieurs rapports comme validations indépendantes.

| ID | Source primaire, date/version | Résultat utile et limite |
|---|---|---|
| S01 | [TypeSafe, lancement Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev), 15 septembre 2026 | Early access. Benchmark fournisseur : quatre workflows, référence moyenne de modèles et graphe supposé correct. Prix/latence annoncés, géographie et biais reconnus. « Pas d'hallucination » y désigne surtout conformité de schéma, pas vérité métier. |
| S02 | [Choice](https://docs.typesafe.ai/primitives/choice), doc courante | Sélection par probabilité maximale, distribution normalisée, confidence dérivée ; jusqu'à 255 options ; OTHER doit être fourni si nécessaire. |
| S03 | [Score](https://docs.typesafe.ai/primitives/score), doc courante | 2–10 niveaux ordonnés ; résultat = espérance de leurs indices, pas quantité physique ni fraction de bugs résolus. |
| S04 | [Noul](https://docs.typesafe.ai/primitives/noul), doc courante | Probabilité prédite du « oui », sans champ confidence séparé. Ne représente pas le degré d'une propriété. |
| S05 | [Confidence](https://docs.typesafe.ai/confidence), doc courante | Statistique de concentration de la distribution Choice/Score. Seuils d'exemple, pas seuils validés pour Throttle. |
| S06 | [System One](https://docs.typesafe.ai/concepts/system-one) et [State](https://docs.typesafe.ai/concepts/state) | Texte/JSON, aucune vision native. Calibration collective distincte de la correction d'un cas. Les questions partagent un state : leur évaluation parallèle ne prouve pas l'indépendance statistique des erreurs. |
| S07 | [Construire avec TypeSafe](https://docs.typesafe.ai/concepts/how-to-build-with-system-one) | Code propriétaire du contrôle et des effets ; jugements étroits. URL d'abord inaccessible puis accessible via lien officiel : erreur de récupération, pas preuve d'obsolescence. |
| S08 | [Modèles](https://docs.typesafe.ai/models), Jev 1.13.0 | Alias/version, limites de contexte et de débit documentés. Prix affiché 0,042 USD/Mtokens en entrée ; ce n'est ni une offre contractuelle ni le coût d'une tâche Throttle. Aucun compte interrogé. |
| S09 | [Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13), revue fournisseur 17 septembre 2026 | Limites explicites : calcul, dates, contexte inutile, indirection, contenu adversarial, invariants entre questions. Contredit toute lecture de « type-safe » comme absence d'erreur sémantique. |
| S10 | [Eigent, What is Jev?](https://www.eigent.ai/blog/typesafe-ai-jev-system-one-models), 18 septembre 2026, secondaire | Version anglaise retrouvée ; URL française fournie inaccessible. Reprend TypeSafe et propose sa propre intégration : aucune validation indépendante du fournisseur ni nécessité d'adopter Eigent. |
| S11 | [Lindfors, essai early access](https://lindfors.no/blog/a-first-look-at-typesafes-jev/), septembre 2026 | Étude originale exploratoire : 24 documents norvégiens, 192 jugements d'arguments ; référence en partie issue d'un modèle. Signaux utiles, taille et oracle insuffisants pour calibration logicielle. |
| S12 | [Kim et al., Correlated Errors](https://proceedings.mlr.press/v267/kim25e.html), ICML 2025 | Plus de 350 modèles, deux leaderboards et sélection de CV. Corrélation y compris entre fournisseurs ; ne mesure pas directement un challenger de patches Swift. |
| S13 | [Yu et al., UTBoost](https://arxiv.org/abs/2506.09289), juin 2025, ACL 2025 | Augmentation de tests Python : 36 instances insuffisantes, 345 patches erronés auparavant acceptés. Les 40,9/24,4 % concernent des entrées de leaderboard affectées, pas le taux universel d'erreurs de patches. |
| S14 | [Guo et al., calibration](https://proceedings.mlr.press/v70/guo17a.html), ICML 2017 | Études image/classification de documents, calibration post-hoc. Justifie la distinction confiance/correction ; pas un certificat de calibration Jev ni un protocole de sûreté autonome. |
| S15 | [Anthropic, système de recherche multi-agent](https://www.anthropic.com/engineering/multi-agent-research-system), 13 juin 2025 | Retour fournisseur sur recherche parallélisable. Les ~15× tokens comparent au chat, pas au worker unique. Transfert au développement couplé non démontré. |
| S16 | [Anthropic, long-running harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), retour d'ingénierie | Contrats, progression et vérification externe contribuent à la continuité. Ce retour ne prouve pas une autonomie complète de release. |
| S17 | [Anthropic, sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing), retour d'ingénierie | Isolation système/fichiers/réseau et séparation des credentials. Les permissions de prompt seules ne constituent pas cette frontière. |
| S18 | [Temporal, Activity Definition](https://docs.temporal.io/activity-definition), doc courante | Une activité dont le résultat n'est pas enregistré peut être rejouée ; idempotence à construire avec le système destinataire. Temporal ne rend pas chaque effet externe exactly-once. |
| S19 | [LangGraph, persistence](https://docs.langchain.com/oss/python/langgraph/persistence), doc courante | Checkpointer de thread distinct du store ; mémoire RAM perdue au redémarrage. URL durable-execution redirigée. Vérifier séparément les effets avant checkpoint. |
| S20 | [MCP security best practices](https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices), version retournée 2025-11-25 | Confused deputy, audience des tokens, SSRF et sessions. L'URL 2025-06-18 redirige ; ne prouve pas l'implémentation du transport Throttle. |
| S21 | [Atomic commit SQLite](https://sqlite.org/atomiccommit.html) | Transactions locales et hypothèses de stockage. Une transaction SQLite n'englobe pas Git, un processus et un fournisseur externe. |
| S22 | [W3C PROV overview](https://www.w3.org/TR/prov-overview/), 2013 | Vocabulaire de provenance utile sans imposer RDF ni base graphe. |
| S23 | [SLSA v1.2](https://slsa.dev/spec/v1.2/) | Provenance de production et intégrité supply chain ; ne certifie ni besoins utilisateur ni correction fonctionnelle. |
| S24 | [Apple, Xcode system requirements](https://developer.apple.com/xcode/system-requirements), doc courante | Xcode 27 et SDK 27 documentés ; compilation possible pour des versions minimales antérieures. URL /support/xcode redirigée. |
| S25 | [Apple, WWDC26 Foundation Models](https://developer.apple.com/videos/play/wwdc2026/241/) ; [PCC](https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute/) | API PCC et disponibilités à distinguer du modèle sur appareil. Page DocC peu extractible ; déclarations recoupées avec le swiftinterface du SDK installé. Aucun quota ni accès runtime vérifié. |
| S26 | [Apple, audits d'accessibilité](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app?changes=_6) | Audit d'un écran : contrastes, descriptions, clipping. Ne remplace ni parcours clavier/VoiceOver ni test d'utilisabilité. HIG consultée mais extraction pauvre. |
| S27 | [Ollama FAQ](https://docs.ollama.com/faq) | Mémoire dépend des modèles chargés, du contexte et de la concurrence. Pas de capacité gratuite déduite du seul nombre de GPU. |
| S28 | [Codex SDK](https://learn.chatgpt.com/docs/codex-sdk) ; [sécurité](https://learn.chatgpt.com/docs/security), doc courante | Threads et intégration locale ; SDK/app-server sont des options d'adaptation, pas le registre produit. URLs developers.openai.com/codex redirigées. Ne pas supposer le comportement d'une CLI installée d'après la doc courante. |
| S29 | [OpenAI, guardrails et revue](https://developers.openai.com/api/docs/guides/agents/guardrails-approvals), doc courante | Le mode parallèle peut commencer du travail avant le verdict. Une barrière d'autorisation doit précéder l'effet ; compléter les contrôles selon chaque type d'outil. |
| S30 | [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview), doc courante | Outils, hooks, sous-agents, permissions et usage déjà fournis. Adapter un worker ; ne pas refaire un SDK. URL platform.claude.com redirigée. |
| S31 | [OpenHands SDK](https://docs.openhands.dev/sdk) ; [SWE-agent](https://swe-agent.com/latest/) | Harnesses logiciels spécialisés à comparer sur une tâche. Pas de preuve acquise concernant UI native Apple ou distribution complète. |
| S32 | [DSPy, source officielle](https://github.com/stanfordnlp/dspy) | Programmation/optimisation de systèmes LM contre métrique ; intérêt seulement avec oracle et dataset. Page overview dspy.ai non exploitable, dépôt de référence utilisé. |
| S33 | [Letta stateful agents](https://docs.letta.com/v1-sdk/concepts/stateful-agents) | Mémoire et messages persistés, blocs modifiables par agents. Chemin fourni redirige vers documentation V1 legacy : ne pas en déduire les garanties d'un nouveau déploiement. |
| S34 | [AutoGen AgentChat](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/index.html) ; [CrewAI Flows 1.15.22](https://docs.crewai.com/v1.15.22/en/concepts/flows) | Collaboration et flows. Alternatives évaluées par responsabilité ; aucune migration justifiée par leur seul catalogue. |
| S35 | [Git worktree](https://git-scm.com/docs/git-worktree) ; [hooks](https://git-scm.com/docs/githooks) | Worktrees partagent des métadonnées/refs. Isolation d'édition n'est pas confinement hostile ni transaction d'intégration. |
| S36 | [Sparkle documentation](https://sparkle-project.org/documentation/) | Mise à jour macOS existante à conserver ; artefact/appcast et état public restent des preuves distinctes. |
| S37 | [RouteLLM, code et évaluation](https://github.com/lm-sys/RouteLLM) | Routage appris réutilisable pour expérience ; préférences/benchmarks fournis ne sont pas les labels d'acceptation Throttle. |

Sources locales supplémentaires : `docs/testing/workflow.md` (protocole, pilote **0/10**), `docs/adr/0002-research-vault-authenticated-xpc-boundary.md` (décision du 27 août, limites runtime), `docs/design-circuit-breaker.md` (warn livré, auto-pause différée), `C:docs/testing/2026-09-15-workflow-contract-increment.md` (preuves historiques), et le paquet DeepSearsh `library/evidence-and-decisions/throttle/research-vault-symbolic-reasoning-local-go--356d2740a6.md` (30 août). Ce dernier décide de conserver la reconstruction complète du raisonnement et un plafond opérationnel de 10 000 faits ; ses timings historiques ne sont pas des mesures actuelles. Le Global RAG a été consulté une fois avec limit=6 comme orientation, puis les fichiers ont été vérifiés. Aucun corpus n'a été importé ou modifié.

### Recherches infructueuses et limites

- Vidéo `https://www.youtube.com/watch?v=cJ0EOzey--o` : récupération échouée ; recherches sur l'identifiant puis l'identifiant + transcript sans transcription exploitable. **OUTIL/SOURCE INDISPONIBLE**. Aucun propos ni titre de la vidéo ne lui est attribué dans la revue. Prompt résiduel : « Obtenir légalement la transcription de cette URL, titre/auteur/date et timestamps ; distinguer propos verbatim, inférences et liens cités ; extraire uniquement les assertions pouvant changer D09/D10/D20. Ne fournir aucun résultat si inaccessible. » Cela empêche l'analyse spécifique de la vidéo, pas les décisions appuyées par code et documents TypeSafe.
- TypeSafe `/limitations`, `/concepts/limitations`, `/llms.txt` non récupérables. La page officielle S09 a été trouvée par le lien Models ; ne pas inventer une redirection depuis ces chemins.
- Recherche Jev indépendant : S11 retrouvé ; piste de monitor de backdoors sur LessWrong inaccessible directement (miroir et annuaire trouvés mais **non retenus comme preuve technique primaire**). Pas de benchmark Throttle ni de calibration logicielle suffisamment établie trouvé dans cette recherche bornée. Cela ne signifie pas qu'aucun essai n'existe.
- Références numériques de R1/R3/R5 sur SWE-EVO, ProjDevBench, SecureVibeBench, IssueTrojanBench, DeepSWE, SpecBench, Skills et routage 2026 : bibliographie opaque, vérification exhaustive non menée. Leurs chiffres sont exclus des promesses et du classement des priorités.
- Aucun inventaire de vulnérabilités exhaustif des dépendances, statut des comptes, licence juridique applicable à chaque fichier, fournisseur live ou appareil physique n'est établi.

## Registre Claim → Evidence → Decision

Typologie : **ER** empirique robuste dans son périmètre ; **EL** empirique limité ; **TH** raisonnement théorique/normatif ; **REX** retour opérationnel ; **VF** affirmation fournisseur ; **H** hypothèse non vérifiée ; **CONT** affirmation contredite dans sa forme forte. Robustesse dans un benchmark n'implique jamais validité end-to-end.

Les propositions négatives/fortes ci-dessous sont les **hypothèses mises à l'épreuve**, pas des citations attribuées automatiquement aux rapports. La référence R indique le passage qui les discute, souvent pour les réfuter lui-même : notamment R2 sur l'indépendance, R4 sur hash/vérité et graphe/stockage, R5 sur tests verts/completion, R6 sur permissions. Seules les prescriptions explicitement identifiées comme recommandations (cinq reviewers, étages appris, Decision Engine, Temporal) sont traitées comme telles. Aucune contradiction avec un rapport ne se déduit de la simple formulation provocatrice d'une ligne.

| Claim | Proposition et origine précise | Domaine / méthode / population / résultat | Favorable, contre-preuve et hypothèse de transfert | Conséquence |
|---|---|---|---|---|
| CL01 | Une architecture à nombreux services/agents n'est pas nécessaire. R1:238–274,355–638 ; R8:418–443 | TH, aucune ablation Throttle | Code C possède les responsabilités. Contre : spécialisations utiles si vraie séparation/outillage. Transfert : tâches souvent couplées. | D01,D20 |
| CL02 | Changer de fournisseur rend le juge indépendant. R2:5–40,171–199 | CONT sous forme de garantie ; S12, ICML2025, >350 modèles | Erreurs corrélées entre fournisseurs ; contexte/oracles communs persistent. Aucune mesure directe du couple de workers local. | D06 |
| CL03 | Recherche multi-agent améliore le travail autonome. R1:124–138 ; R8:15,410–416 | REX/VF, S15, évaluation interne de recherche | Gain spécifique ; coût 15× vs chat, pas worker. Aucune preuve d'un gain uniforme en coding ou produit. | D09,D20 |
| CL04 | Tests verts suffisent à terminer. R1:63–83 ; R5:53–153 | CONT ; S13, génération de tests Python et audit patches | 345 faux positifs identifiés ; les tests ajoutés restent eux-mêmes imparfaits. Transfert : protéger les obligations, vérifier besoin et résultat. | D05,D07 |
| CL05 | Confiance verbalisée = probabilité correcte. R1:85–106 ; R5:513–694 ; R6:80–290 | CONT ; S14 sur classification, pas code | Calibration est évaluée sur cohortes. Aucune calibration locale. | D07,D10,D17 |
| CL06 | Déployer cinq agents de vérification permanents. R2:171–199 | H normative sans comparaison locale | Objectifs séparés utiles ; contre coût, corrélation, transfert de contexte. Même processus/profil distinct peut suffire pour petits risques. | D06,D20 |
| CL07 | Challenger doit produire une réfutation testable. R2:201–388 | TH + REX ; oracle requis | Repro/invariant/fichiers/gravité. Certaines failles statiques justifient blocage sans exploitation. Jamais prime au nombre de constats. | D06 |
| CL08 | Le routeur doit apprendre immédiatement. R3:3–51,1183–1285 | H ; S37 ne valide pas ce domaine | Admission/coût/fallback existent ; dataset local absent. L'observation de l'arm choisi est biaisée. | D09,D17,D20 |
| CL09 | Confidentialité et permissions sont des contraintes dures. R3:353–389,985 ; R6:698–803 | TH + S17/S20/S29 | Le modèle peut signaler du risque, pas déclassifier ni autoriser. Contre : un simple booléen ne couvre pas la frontière OS. | D02,D03,D04 |
| CL10 | Coût par tâche acceptée compte plus que tokens par appel. R3:1030–1181 | TH, métrique proposée sans gain mesuré | Inclure préparation, retries, annulations, vérification, ressources et inconnus. TaskSpend n'est pas la facture totale. | D12,D17 |
| CL11 | PostgreSQL ou une base graphe est nécessaire. R4:3–57,1095–1230 | CONT comme nécessité | S21/S22 + GRDB/SQLCipher/journal déjà présents. Relation logique n'impose pas backend distribué. | D01,D11,D20 |
| CL12 | Hash prouve vérité et authenticité. R4:103–148,719–954 | CONT ; S22/S23 | Digest identifie les octets ; producteur, acquisition, oracle et intégrité de stockage restent nécessaires. PlanStore documente sa limite. | D04,D05,D11 |
| CL13 | Toute décision doit être liée au sujet/version. R4:719–954 ; R6:671–694 | TH, corroborée par code C | Deux SHA ne couvrent pas entrées ignorées/non suivies ; mtime peut être trompeuse. Revalidation requise après changements. | D05,D08 |
| CL14 | Provenance = copie intégrale de tous prompts/logs. R4:103–148,174–298 | TH ; nécessité rejetée pour Throttle | Audit utile ; contre secrets/PII/rétention/coût. Conserver dossier minimal et références accessibles selon scope. | D11 |
| CL15 | Une DoD vectorielle est préférable à une moyenne. R5:362–511 | TH, implémentation C partielle | Critère obligatoire FAIL/UNKNOWN bloque ; NA justifié selon obligation, pas échappatoire du worker. | D07 |
| CL16 | Une probabilité globale permet de certifier terminé. R5:694–978 | H non exploitable actuellement | Proposition et population mal définies ; corrélation, rareté, changement de politique. Aucune multiplication de probabilités non indépendantes. | D07,D10 |
| CL17 | Un build propre est obligatoire pour tout travail. R5:984–1000 | CONT comme règle universelle | Protocole local autorise inspection documentaire/visuelle ciblée. Choisir la preuve selon frontière touchée. | D07,D17 |
| CL18 | Contrôleur externe au worker, contrôle à chaque effet. R6:3–76,698–803 | TH ; S17/S20/S29 | Référence monitor logique nécessaire ; six plans n'imposent pas six services. Grant MCP ne confine pas le shell utilisateur. | D02,D04 |
| CL19 | Timeout/503 permet retry. R6:349–482 ; R8:590 | CONT sans sémantique d'effet ; S18 | Timeout peut suivre succès distant. Ledger release sait distinguer started/observed mais pas tous les runners. | D03,D08,D14 |
| CL20 | Retour arrière = annulation de tous effets. R6:527–667 | CONT | Git revert n'annule pas message, signature, déploiement ou paiement. Compensation spécifique + réconciliation. | D08,D14 |
| CL21 | Choice/Score/Noul donnent des jugements typés. R7:43–67 | VF documentaire vérifiée S02–S06, Jev1.13 | Sémantique précise confirmée ; nul besoin de nouveau moteur générique. | D10 |
| CL22 | Jev ne peut pas halluciner donc peut garder les permissions. R7:43–67 ; phrase forte S01 | CONT pour vérité/sécurité ; S09 | Fournisseur reconnaît sensibilité adversariale et erreurs arithmétiques. Sortie légale syntaxiquement peut être mauvaise. | D04,D10,D20 |
| CL23 | Gains vitesse/prix Jev transférables au lab. R7:43–67 | VF, quatre workflows enseignants S01 | Coût d'entrée et réseau, préparation d'état, oracle non terrain, infrastructure West Coast. Pas de gain de productivité Throttle établi. | D10,D17 |
| CL24 | Il faut construire Decision Engine multi-backend. R7:221–310,543–593 | H architecturale | Typed decisions utiles mais routeurs/gates/admission existent. Une fonction de jugement en observation suffit au premier essai. | D09,D10,D20 |
| CL25 | Temporal doit être adopté comme colonne vertébrale. R8:445–459,545 | H ; S18 décrit mécanismes, pas besoin local | Crash/retry requis ; PlanStore déjà durable. Serveur/langage/ops supplémentaires et double autorité possibles. | D01,D08,D20 |
| CL26 | Workflow et mémoire conversationnelle ne sont pas interchangeables. R8:328–394 | TH + S19/S28/S33 | Garder historique natif worker + contrat/journal Throttle ; changement de modèle devient événement, pas faux replay déterministe. | D01,D08,D11 |
| CL27 | La vérification doit inclure besoin produit et UX. R5:362–511 ; R8:617–633 | TH ; S26 + contrats C | Tests AX ne prouvent pas utilisabilité, capture ne prouve pas parcours. Acceptation utilisateur pour ambiguïté réelle. | D07,D13,D14 |
| CL28 | Risque R0 lecture / R1 test sont toujours faibles. R8:578–588 | CONT comme classification automatique | Lecture sensible peut exfiltrer ; build exécute Package.swift/scripts. Évaluer données/effets, pas nom d'outil. | D02,D03,D04 |
| CL29 | Ajouter de nouvelles couches mémoire améliore forcément le contexte. R3/R4/R8 | H | Vault/FTS/raisonnement existent ; corpus local avait déjà différé l'incrémental. Mesurer requête/rappel/coût avant embeddings ou graphes. | D11,D17 |
| CL30 | Auto-modifier évaluateurs/politiques peut s'auto-valider. R5:1003–1026 ; R6:859–1157 ; R8:90 | CONT | Toute proposition de changement d'oracle doit être validée sous ancien contrôleur, corpus tenu à part, auteur non autorité finale. | D18 |
| CL31 | Les cibles de produits imposent la plateforme hôte. R8:architecture distribuée | CONT | Host macOS14 déclaré ; SDK27 installé ; iOS17 et visionOS26 compagnons. Android est une destination de contrat, pas hôte requis. | D16 |
| CL32 | Les scores pondérés de dépendances constituent des preuves. R1/R8, transposition | H/CONT | C a déjà gates + scores. Poids et seuil75 sont politiques heuristiques, pas probabilités ni compatibilité démontrée. | D15 |

### Contradictions explicites à conserver

R1 réduit à six primitives ; R2 recommande cinq vérificateurs ; R3 ajoute plusieurs étages d'apprentissage ; R7 recommande un Decision Engine ; R8 privilégie Temporal. **Aucune de ces décompositions n'est approuvée par consensus.** Le code C et l'alternative minimale décident du besoin. R1 avertit sur la corrélation mais sa formule d'utilité aux lignes 674–684 multiplie des probabilités sans loi jointe définie : elle n'est pas retenue. R3:670–690 classe universellement tests/build au-dessus de l'humain : cela ne vaut pas pour valider le besoin. R8:588 suggère de baisser une classe de risque avec l'expérience : le rayon d'impact intrinsèque ne baisse pas parce que le modèle progresse ; seule une politique d'automatisation explicitement approuvée peut évoluer.

Les idées précédemment évoquées dans la conversation — Decision Engine, Autonomy Controller, DoD probabiliste — restent des hypothèses. L'automatisation d'archive évoquée auparavant ne démontre aucune durabilité produit. Le nouveau mandat interdit de la relancer. L'approbation UI antérieure ne constitue pas une autorisation d'exécution dans cette revue.

## Registre des questions complémentaires A–M

| ID / priorité | Décision bloquée, risque | Connaissance / preuve manquante | Méthode menée et résultat | Résiduel |
|---|---|---|---|---|
| Q-A P0 durable | D08, doublon après crash | PlanStore + release ledger présents ; runner général incomplet | Inspection code, S18/S19/S21 : conserver local, réconcilier effet inconnu | Expérience crash/kill/disque plein sur fixtures requise |
| Q-B P0 sécurité | D02–04, droits hors scope | Grammaire bash permissive, lecture HOME, grants coopératifs | Call sites + tests + S17/S20/S29 : fail-closed avant extensions | Containment OS effectif et clients hostiles NON EXÉCUTÉS |
| Q-C P1 vérité | D05/06/17, faux succès | Pilote0/10, tests inventaire existants | S12–14, inspection invariants : benchmark interne indépendant | Labels humains et défauts échappés manquent |
| Q-D P1 mémoire | D11, donnée périmée/exfiltrée | Vault scoping, receipts, FTS, génération | ADR0002 + paquet DeepSearsh + code ; pas de base graphe | Matrice rétention/suppression et runtime signé incomplets |
| Q-E P1 long terme | D08/14, mauvais besoin et boucles | WorkContract/retry/PlanProjection | Inspection montre états candidats et budgets ; jalons résultat requis | Échantillon besoins et reprise multi-jours à exécuter |
| Q-F P1 UX | D13, preuve comprise et contrôle effectif | DesignContract ; enum shipped mais libellés Integrated/Intégré corrects | Suivi PlanFlow→FlowWording→catalogue réfute le défaut de libellé initial ; S26 sépare fidélité/AX/usabilité | Parcours réel, VoiceOver, rendu EN/FR non exécutés |
| Q-G P1 Apple | D16, SDK imaginaire/GPU saturé | Targets14/17/26, SDK27, MLX/Ollama | Plists/swiftinterface + S24–27 : disponibilité par backend | Quotas PCC, modèle installé utilisable, mémoire/GPU runtime inconnus |
| Q-H P0 Git | D05/08, mauvaise révision intégrée | FF-only et stamp existent, refs partagées | Inspection integrate + S35 : fermer fenêtre entre check et merge | Test writer non coopératif et crash après merge requis |
| Q-I P1 IP/réemploi | D15, mauvais composant/licence | Modèles évaluateurs déjà là ; notices hétérogènes | Source/README/CONTRIBUTING + S23 ; pas de changement de licence | Arbitrage propriétaire par périmètre, inventaire CVE/SBOM complet absent |
| Q-J P1 release | D14, faux « livré » ou effet répété | Manifest/gates/journal sans connecteurs effecteurs | Inspection + S36 : brancher un canal borné ultérieurement | Éligibilité et autorisation live non vérifiées |
| Q-K P1 économie | D12, réserve fictive ou coûts invisibles | Budget admission/protected reserves et TaskSpend | Inspection prouve séparation measured/upper-bound ; S27 | Comptabilité tous providers et contrôle des processus externes incomplets |
| Q-L P2 réutiliser | D01/09/20, nouveau framework inutile | Swift natif + workers CLI | S18/19/28–34/37 comparés par responsabilité | Benchmark nécessaire avant changer worker ou runtime |
| Q-M P0 auto-modif | D18, oracle affaibli | Hashes/contrats ne confinent pas même UID | Inspection des accès + S17/23/29 : protéger contrôleur et corpus | Test version N contre proposition N+1 requis |

Arrêt de recherche : les questions prioritaires ont une décision justifiable par inspection et sources. Les incertitudes restantes nécessitent une expérience ou une autorité produit, pas une nouvelle recherche générale.
