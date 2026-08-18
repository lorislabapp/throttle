# Handoff pour reprise Claude Code (Throttle) — 18 août 2026

Date : 2026-08-18  
Destinataire : session Claude Code suivante  
Contexte : utilisateur a demandé une continuité claire sans perdre le handoff existant (2026-08-16).

## Priorité de lecture

1) Ne pas écraser/annuler le handoff du 2026-08-16.
2) Comprendre que ce document est **complémentaire** : il regroupe les questions de session switch + DeepSearsh + MCP/skills pour Claude Code.
3) Ne pas implémenter tant que les choix fonctionnels ouverts ne sont pas tranchés.

## Handoff de continuité (référence précédente)

- Handoff existant à ne pas perdre :  
  `docs/THROTTLE-WORKSPACES-HANDOFF-2026-08-16.md`

- Ce handoff doit être utilisé comme source prioritaire pour les décisions produit/architecture de base, et complété avec le présent doc pour les sujets de session et DeepSearsh.

## État actuel Throttle (vérifié au moment du handoff)

- Worktree non propre avec :
  - `Throttle/Services/MissionRuntimeService.swift` modifié.
  - `.codex/` et `.mcp.json` non suivis.
- Aucune écriture forcée de l’historique demandé ici ; pas de commit dans ce cycle.

## Réponses demandées par l’utilisateur

- Oui, il faut bien conserver un handoff unique exploitable par Claude Code.
- Oui, DeepSearsh est bien le bon mécanisme pour la base de connaissance locale, avec ingestion automatique.
- Non, il n’existe pas dans Throttle de MCP/skill **déjà actif** directement nommé “DeepSearsh”.
  - La base de connaissance est autonome dans `/Users/kevinnadjarian/GitHub/DeepSearsh`.
  - Throttle possède pour l’instant une MCP locale différente : `throttle-refinery` (qwen3.5:4b via Ollama), visible dans `.mcp.json` et `.codex/config.toml`.

## DeepSearsh : pipeline réel (et automatique)

Chemins importants :
- Répo : `/Users/kevinnadjarian/GitHub/DeepSearsh`
- Inbox : `/Users/kevinnadjarian/GitHub/DeepSearsh/inbox/`
- Script d’indexation : `/Users/kevinnadjarian/GitHub/DeepSearsh/scripts/build_library.py`
- Vérification : `/Users/kevinnadjarian/GitHub/DeepSearsh/scripts/verify_library.py`
- Watcher/service : `/Users/kevinnadjarian/GitHub/DeepSearsh/scripts/deepsearch_service.py`
- Daemon launchd : `/Users/kevinnadjarian/GitHub/DeepSearsh/com.kevinnadjarian.deepsearsh.plist`
- Index produit : `/Users/kevinnadjarian/GitHub/DeepSearsh/catalog.jsonl`
- Logs/status : `/Users/kevinnadjarian/GitHub/DeepSearsh/.service/service.log` et `.service/status.json`

Ce qui répond à ta question d’“auto ajout des nouvelles deep researches” :
- Le watcher surveille `inbox/` (poll 5 s), attend stabilité du fichier (10 s), puis lance :
  - `python3 scripts/build_library.py`
  - `python3 scripts/verify_library.py`
- Les fichiers déposés dans `inbox/` sont conservés (pas supprimés).
- Les doublons sont dédoublonnés par hash SHA-256.

## Configuration MCP/skills visible dans Throttle

- `.mcp.json` actuel :
  - `throttle-refinery` (stdio vers `experiments/local-context-refinery/mcp-server.mjs`)
  - env : THROTTLE_REFINERY_MODEL=`qwen3.5:4b`, URL Ollama local, roots.
- `.codex/config.toml` : même serveur et paramètres.
- Aucun `deepsearch`/`throttle-deepsearsh` / `notebooklm` dans la config actuelle.

## Ce qu’on demandait dans la session précédente (reste à décider côté produit)

1) Au choix d’ouverture d’une session, proposer un mode de lancement explicite :
   - Node
   - Codex
   - Claude
   - Local LLM
   - Terminal

2) Lorsqu’un projet est déjà ouvert :
   - détecter la tab existante,
   - proposer “ouvrir la tab existante” plutôt que d’en créer une nouvelle.

3) Au démarrage d’une session/deep research :
   - demander si utilisateur veut commencer avec Codex ou Claude,
   - puis créer/charger le bon contexte.

4) Deep research flow souhaité :
   - d’abord requête locale (DeepSearsh),
   - ensuite deep search web si nécessaire.

5) Possibilité d’ajouter un “prompt helper” optionnel + pré-optimisation locale avant appel modèle distant.

6) Question MCP/skills d’intégration possible :
   - NotebookLM gateway/SOTA,
   - app audit/remediation,
   - etc. à prioriser selon budget coût/risque.

## Recommandation opérationnelle pour Claude Code

- Prendre ce handoff comme seul cadre de continuité.
- Avant toute implementation :
  1) confirmer design de “switch session” et UX de tab existing,
  2) valider s’il faut intégrer DeepSearsh via MCP direct ou conserver le mode service + scripts,
  3) définir l’ordre de routage : DeepSearsh local → deep research web.

## Vérification rapide à faire en reprise

1) `cd /Users/kevinnadjarian/GitHub/Throttle && git status --short`
2) `cat /Users/kevinnadjarian/GitHub/DeepSearsh/.service/status.json`
3) `tail -50 /Users/kevinnadjarian/GitHub/DeepSearsh/.service/service.log`
4) `launchctl print gui/$(id -u)/com.kevinnadjarian.deepsearsh` (si nécessaire)

## Note de compatibilité avec la demande utilisateur

Oui, “tout est centralisé” : ce fichier est fait pour être envoyé tel quel à Claude Code, en complément du handoff du 2026-08-16, sans en perdre le contenu ni l’état.
