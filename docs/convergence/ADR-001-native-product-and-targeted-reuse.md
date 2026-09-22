# ADR-001 — Un produit natif, réemploi ciblé

Date : 2026-09-20. Statut : décision produit approuvée dans le plan, implémentation progressive. Autorisation : « Implement the plan ». Pas d'autorisation de publier ou de migrer des données.

## Décision et faits sources

Throttle possède le workflow, les permissions, les budgets, les preuves et la décision de completion. L'UI reste Swift/AppKit/SwiftUI. Ni une UI Tauri parallèle ni un second orchestrateur ne sont importés. Le socle reste utilisable sans Node, Valkey, SpiceDB ou serveur distant. SuperGateway sera un transport optionnel qualifié par version et protocole, pas une autorité de politique supplémentaire.

Base : cockpit `1ac0a32f02f2cce9707779e41118ea39e7eb97d7` et patch préexistant identifié dans [baseline.json](baseline.json). Le worktree d'origine n'est pas modifié. Les résultats de recherche précédents sont conservés dans [la revue](../research/THROTTLE_RESEARCH_ARCHITECTURE_REVIEW.md), sans convertir ses propositions en capacités existantes.

## Registre du réemploi

| Source observée | Décision | Application / preuve nécessaire |
|---|---|---|
| Throttle `ProjectKnowledgeExplorer`, receipts et `OutboundPolicy` | ADAPT | Une seule frontière read/list/search, commune au MCP et aux assistants ; tests sur fixtures, bornes, liens et changements de racine. |
| Throttle `PlanStore`, `PlanProjection`, `PlanMCPAuthority`, `BudgetAdmissionStore`, `WorkflowWorkContract` | KEEP / ADAPT | Ne pas ajouter de journal concurrent. Étendre les invariants aux frontières d'effet, avec récupération vérifiable. |
| Throttle `TaskSpend`, `ClaudeAgentInventory`, `StatsDataService` | KEEP | Le travail cockpit hérité reste intact ; pas de deuxième calcul de dépenses/inventaire. |
| Kalystr `crates/so-orchestrator/src/local_executor.rs`, `local_gateway.rs` | ADAPT des invariants et scénarios | Root-capability, budgets, refus sans confinement. Le lot 1 implémente nativement les ouvertures relatives POSIX et reprend les catégories de tests, sans copier ce code. |
| Kalystr `so-memory/mission_journal.rs` | ADAPT des concepts | Intent, lease/fencing, réconciliation ; aucune importation SQLite ni deuxième source d'autorité. |
| Kalystr `agent_sandbox.rs`, `pty_broker.rs` | EXPERIMENT | Qualification de confinement CLI et supervision des descendants avant autonomie d'écriture. Les limites de processus ne sont pas une sandbox. |
| Kalystr `builder_authority.rs`, SuperGateway `goliathBuilderAuthority.ts` / `goliathExecutionPlane.ts` | MODIFY avant réemploi | Les contrats actuels font de SuperGateway l'autorité. Ne pas réétiqueter leurs anciens reçus comme des preuves émises par Throttle. |
| SuperGateway `tools/build-goliath-authority-sea.mjs`, transport MCP | WRAP optionnel | Vérifier Node 24/arm64, artefact exact, licence et compatibilité. Aucune installation, compilation SEA, signature ou mise en service ici. |
| `wp6Runtime`, UI React/Tauri, historiques et secrets des deux produits | DEFER / REJECT migration | Complexité non nécessaire au noyau local. Pas de transfert de sessions, données, comptes ou clés. |

Révisions inspectées : Kalystr `7d1a6444ad44666ff4f86306c81fa6f3ede21895` (arbre sale) ; SuperGateway `f61e761fe3307a083f365f2cf355f988718b5004` (arbre sale). Ces dépôts restent intacts. Une extraction ultérieure doit capturer aussi les empreintes des fichiers réellement copiés, leur état local et leurs notices. Cargo annonce MIT pour Kalystr mais l'absence de licence racine inspectée ne suffit pas pour redistribuer : vérifier fichier/composant avant copie substantielle. SuperGateway porte une licence MIT à préserver.

## Migration et portes de sortie

1. Lectures seules : fermer le shell générique et unifier les outils sur l'explorer. Les anciens appels bash sont explicitement refusés, sans processus.
2. Écritures/exécution : persister l'intention avant l'effet ; expiration/révocation au dernier point contrôlé, état inconnu après perte d'ACK, sans retry aveugle. Une absence de confinement qualifié reste une indisponibilité explicite.
3. Preuves et Git : identifier contenu, exigences, outils et état vérifié ; ne jamais fusionner un nom de branche qui a bougé depuis la vérification ; réconcilier un succès Git non journalisé.
4. Gateway : compatibilité/auth/runtime optionnels ; supprimer les générateurs d'installation flottante avant proposition de déploiement.
5. Cockpit/review et cycle produit : afficher l'identité des évaluateurs et la portée des preuves. Terminé, intégrable, publiable et publication autorisée restent distincts.
6. Optimisation : baseline incluant échecs/annulations puis observations limitées. Aucun appel payant sans budget.

Chaque lot est vérifié avant d'élargir son autorité. Revenir au comportement de shell générique n'est pas un rollback acceptable ; un défaut du lot 1 doit désactiver les lectures ou restaurer une version contrôlée de l'explorer. Les autres migrations doivent préserver les anciens journaux en lecture et invalider les preuves insuffisantes, pas les réinterpréter comme fiables.

## Sources primaires complémentaires déjà examinées pendant le plan

- [MCP transports 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports) et [authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization) : qualifier explicitement les protocoles ; ne pas supposer que l'ancien handshake valide la version courante.
- [cap-std 4.0.2 Dir](https://docs.rs/cap-std/4.0.2/cap_std/fs/struct.Dir.html) : modèle de répertoire-capability ; pas une preuve de confinement de tout le processus.
- [Apple XPC](https://developer.apple.com/documentation/xpc) et [launch/library constraints](https://developer.apple.com/documentation/security/applying-launch-environment-and-library-constraints) : séparation de processus et contraintes d'identité à qualifier sur la cible réelle.

Les garanties du code seront mesurées par les tests du lot, pas déduites de ces documentations ni du succès historique d'une autre application.
