# Throttle — preuves SOTA et décisions, 7 septembre 2026

Périmètre : macOS et services, amélioration du travail réel jusqu'à publication. Recherche primaire consultée le 2026-09-07, distincte de la qualification runtime. Aucun upload de corpus. NotebookLM N/A.

## Corpus local et lacunes

Pistes DeepSearsh : carte `projects/throttle.md`, documents déjà présents dans ce dépôt, notamment `2026-09-04-retrieval-audit-deepsearsh-research-vault.md`, `2026-08-27-throttle-research-vault-cheatcode-full-sota.md`, `sota-companions-2026-07-14.md` et `2026-09-04-plan-orientation-ai-routing-sota.md`. Les cartes et benchmarks historiques sont des pistes, pas des preuves actuelles. L'ancien benchmark sur titres est insuffisant ; le jeu réel avec questions sans réponse est plus pertinent. Aucun gain de retrieval annoncé avant reproduction sur corpus autorisé.

## Recherche actuelle

| Source primaire | Fait utilisable et limite | Conséquence Throttle |
|---|---|---|
| [OpenAI, Git worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees) | Isolation de chats et transfert Local/Worktree ; état courant de documentation, pas mesure d'usage | Préserver identité et mutations par session ; les worktrees seuls ne différencient plus |
| [VS Code, Manage agent sessions](https://code.visualstudio.com/docs/agents/run/sessions/manage-sessions) | Sessions persistantes, état, changements et types d'agent ; chats d'un dossier vs sessions isolées | Orientation utilisateur et récupération visibles, coût relié à la vraie conversation |
| [Zed, External agents](https://zed.dev/docs/ai/external-agents) | Intégrations ACP et permissions/authentification propres aux fournisseurs | Ne pas interpréter du texte PTY comme autorisation structurée |
| [Conductor](https://www.conductor.build/) | Offre actuelle d'équipes d'agents cloud et environnements isolés ; déclaration fournisseur | L'ancienne description mac-only est périmée ; ne pas copier une simple grille de terminaux |
| [Anthropic, Contextual Retrieval](https://www.anthropic.com/engineering/contextual-retrieval) | Méthode de contexte par chunk et recherche lexicale/vectorielle ; publication 2024, résultats fournisseur | Comparer sur questions réelles avec abstention, coût et provenance ; aucun pourcentage transférable |
| [MCP, Security Best Practices](https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices) | Consentement sur commande exacte, vérification des requêtes, minimisation des scopes ; la version 2025-06-18 redirige ici | Les reçus et sorties d'agent ne peuvent accorder leurs propres droits ; droits distincts owner/query |
| [Apple WWDC23, Observation](https://developer.apple.com/videos/play/wwdc2023/10149/) | Dépendances de vue fondées sur les propriétés effectivement lues | Isoler les lectures haute fréquence dans les sous-vues ; mesurer ensuite le runtime |
| [Sparkle, Security and reliability](https://sparkle-project.org/documentation/security-and-reliability/) | 2.9.6 inclut correctifs de timeout et de sécurité pour daemons/CLI root | Lock local 2.9.1 confirmé ; analyser exposition de l'app non-root et mettre à jour le candidat avant qualification |

## Priorités retenues

1. **Continuité fiable des missions.** Identité native stable ; création distincte de reprise ; arrêt confirmé avant changement d'agent ; diagnostic actionnable si identité ou terminaison inconnue. Critères : A/B/C même cwd jamais confondus, récupération après hibernation/app restart, aucun second écrivain avant arrêt. F-001/F-002 sont des prérequis, pas une preuve de fonction terminée.
2. **Bibliothèque locale multi-projets utilisable.** Le propriétaire enregistre explicitement un projet sélectionné, importe puis recherche les reçus de ce projet ; les autres clients gardent leurs scopes. Critères : projet arbitraire et label accentué/collision, erreurs précises, import partiel fidèle, résultats avec provenance ; OCR reproductible. Pas de wildcard global.
3. **Vérification de travail lisible et bornée.** Plan conserve un verdict fiable même si une commande produit beaucoup de sortie ; troncature indiquée, résultat final et preuves conservés. Critères : dizaines de Mo drainés avec mémoire bornée ; deadline/exit code inchangés ; UI montre le verdict et la limite sans masquer l'échec.

Ces trois axes ferment le périmètre majeur de cette boucle. Les améliorations de sécurité, accessibilité, localisation, packaging et performance nécessaires à leurs gates restent incluses. Cette priorité est une inférence à partir du workflow demandé et des défauts confirmés, pas une étude de revenus.

## Opportunités différées et raisons

- ACP/transport structuré des permissions : intégration utile mais pas de réactivation d'auto-approbation fondée sur une approximation de prompt. Réétudier sur un contrat fournisseur authentifié.
- Nouveau reranker/embedding : comparer après correction import/scope et reproduction d'un benchmark réel, pas avant.
- Orchestration cloud et collaboration multi-utilisateur : élargiraient l'hébergement et les flux de données ; hors périmètre approuvé.
- Pricing/acquisition : absence de mesures de rétention et de demande vérifiées ; pas de changement spéculatif du prix.

## Questions encore ouvertes

Version Sparkle de production retenue et compatibilité, cause OCR, preuve d'identité au lancement de chaque fournisseur, UX des états d'arrêt incomplet et temps d'indexation : résoudre par source/tests/runtime dans le journal. Les comparaisons marketing ne ferment aucune gate technique.


### Précision Darwin validée pendant la remédiation

Le wrapper `proc_listchildpids` renvoie un nombre de PID, même si son paramètre buffersize est en octets. Le code Throttle de capture ajouté dans ce cycle a été corrigé après qu'une fixture réelle d'orphelin a exposé la confusion ; cinq tests passent après correction. Source primaire : [Apple XNU libproc.c, fonction proc_listchildpids](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c#L81). Les identités/groupes capturés ne constituent pas une sandbox ; une dérive observée bloque la reprise automatique, et un daemon entièrement détaché entre deux observations reste une limite explicite.


### Complément OCR et recherche mixte — 7 septembre

- Apple documente le choix explicite du compute device par étape : https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:) ; SDK installé VNRequest.h119–144 impose de consulter les devices supportés de la requête. Le binding Swift disponible macOS14/iOS17 expose `supportedComputeStageDevices` (getter throws). Le flag usesCPUOnly est déprécié : https://developer.apple.com/documentation/vision/vnrequest/usescpuonly . Le banc synthétique confirme une défaillance e5rt13 en calcul automatique et une reconnaissance exacte par CPU supporté ; ne prouve pas que tous les scans seront lisibles ou rapides.
- SQLite documente BM25 et ses statistiques de corpus : https://www.sqlite.org/fts5.html#the_bm25_function . Inférence d'architecture : les scores bruts de deux index distincts ne sont pas directement comparables. La fusion actuelle alterne leurs rangs de façon déterministe ; son efficacité doit être mesurée sur le golden set, pas déduite de cette référence.


### Remote continuity refinement — 2026-09-07 21:27 UTC

The selected implementation uses a fixed per-transfer systemd unit. Its helper,
repository preparation, isolated tmux server and native writer all belong to the
same cgroup. A separately persisted stop tombstone forbids later helper launches.
This avoids relying on the termination of an external, delayed `systemd-run`
launcher. This is an engineering inference, not a completed Linux qualification.

`Type=oneshot` requires an explicit startup timeout; `RemainAfterExit=yes` keeps
successful units active after the setup process exits. A tombstoned helper must
fail rather than produce an apparently successful active unit. `KillMode=control-group`
and `SendSIGKILL=yes` cover remaining processes on stop. Primary semantics:
[systemd service manual source](https://github.com/systemd/systemd/blob/main/man/systemd.service.xml),
[systemd kill manual source](https://github.com/systemd/systemd/blob/main/man/systemd.kill.xml).
A privileged process can escape its group; this is an ownership and continuity
contract, not a security sandbox. The independent architecture memo and the
remaining kernel/runtime gates are retained with lot 8.


## Server prerequisite refresh — 2026-09-08

Read-only observations through the existing Proxmox connection identify CT134
as the configured Throttle server. The public health endpoint still reports1.0.0,
zero sessions at observation, and systemd-v1 resource isolation. Linux cgroup v2,
systemd252, tmux3.3a, Git2.39.5 and5.5 GiB free are present; login-shell PATH
finds both native CLIs. This establishes available prerequisites, not a v2
qualification. No remote files, units, accounts or trust settings were changed.
Evidence: `audit-output/sota-20260907/lot9/linux-readiness-readonly.json`.

The server reports Node18.20.4. The [official Node.js release table](https://nodejs.org/en/about/previous-releases)
marks Node18 EOL and Node24/22 LTS, and recommends supported LTS versions for
production. Upstream support is therefore absent for the observed major version;
distribution backports have not yet been checked. Prepare and qualify a supported
runtime with the exact edge candidate before updating the running service. This
is a service-maintenance prerequisite within the existing scope, not a new feature.


### Qualification Linux préparée, 8 septembre 2026 (non exécutée)

Le serveur de travail observé utilise Node18.20.4. La [table officielle Node](https://nodejs.org/en/about/previous-releases) classe Node18 et20 EOL,24 et22 LTS ; statut Debian backports non évalué. Pour qualifier un runtime maintenu sans changer celui du service existant, l’archive officielle [Node24.20.0 Linux x64](https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz) a été téléchargée localement, sans installation. Son SHA-256 intégral `2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2` correspond au [fichier officiel des empreintes](https://nodejs.org/dist/v24.20.0/SHASUMS256.txt). Cela établit l’égalité des octets à la source HTTPS, pas une qualification d’exécution Linux ni une vérification GPG.

Le banc ajoute un timer systemd distinct des scopes SIGSTOP. Le [manuel systemd v252](https://github.com/systemd/systemd/blob/v252/man/systemd.timer.xml) précise que OnActiveSec démarre son délai à l’activation du timer et que celui-ci active l’unité indiquée par Unit ; AccuracySec borne la fenêtre de précision. Notre usage à180s/1s est une conception de banc à qualifier, sans promesse contre une panne du noyau ou du gestionnaire systemd. Le premier prototype de timer JavaScript dans le writer n’était pas suffisant sous SIGSTOP ; la contre-revue l’a rejeté avant tout essai distant.


## Native CLI qualification preparation — 8 September

Installed help read locally: Claude Code2.1.263, Codex CLI0.147.0. Only --version/--help ran; no conversation or native process lifecycle was exercised. Help snapshots are in /private/tmp/throttle-sota-native-{claude,codex,codex-exec}-help.txt. CLI release and documentation can drift; the installed flags are the immediate contract.

Primary sources refreshed: [Claude sessions](https://code.claude.com/docs/en/sessions) distinguishes exact-ID resume from picker and documents separate config/session roots; [Claude headless](https://code.claude.com/docs/en/headless) documents bare mode and bounded print runs; [environment variables](https://code.claude.com/docs/en/env-vars) describes endpoint and traffic controls. [Codex advanced configuration](https://developers.openai.com/codex/config-advanced/) and [configuration reference](https://developers.openai.com/codex/config-reference/) document custom providers and Responses transport. A local protocol fixture could exercise native transcript creation/resume without model credentials, but would not prove interactive Cockpit/PTY behavior or provider-authenticated continuity. No such fixture run is claimed yet.


### Codex 0.147.0 — sous-agents dans le même processus

Lecture locale du 8 septembre : un même PID natif conserve ouverts en écriture le rollout utilisateur `source: cli` et celui du sous-agent `source.subagent.thread_spawn`, même cwd. La simple exclusion des processus descendants ne suffit donc pas à sélectionner la conversation principale. Observation sans lecture des messages ni action sur les sessions, preuve réduite lot14/native-descriptor-observation.json.

Le [protocole Codex au tag rust-v0.147.0](https://github.com/openai/codex/blob/rust-v0.147.0/codex-rs/protocol/src/protocol.rs) définit `SessionSource`, sa sérialisation lowercase, les origines internal/subagent et thread_source. Inférence appliquée : rejeter les origines non utilisateur avant le test d’unicité des descripteurs ; conserver le refus de plusieurs sessions principales. Les anciens rollouts sans source conservent la compatibilité du décodeur natif et exigent toujours FD writable, cwd exact et UUID.
