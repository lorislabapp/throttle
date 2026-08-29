# Throttle Plan Store — design (lot A)

Date: 2026-08-29
Statut: spec validée en brainstorming, non implémentée.

## Contexte

Objectif long terme: Throttle pilote un projet de bout en bout — analyse du
répertoire, brainstorming de l'idée si vide, dossier de viabilité (faisabilité,
concurrence, missed opportunities, rentabilité), planification, délégation des
tâches à des sessions Claude Code / Codex selon leurs forces et les crédits
disponibles, boucle « jusqu'au SOTA », puis contre-analyse par le modèle opposé
avant de valider une tâche.

Ce périmètre est trop large pour une seule spec. Il est découpé en cinq lots:

| Lot | Contenu |
|---|---|
| **A** | Task store + graphe + UI roadmap ← **cette spec** |
| B | Intake & brainstorming d'un projet vide |
| C | Dossier de viabilité (deep research, concurrence, scoring) |
| D | Dispatcher task→runtime (forces, crédits, RAM) |
| E | Boucle SOTA + contre-analyse par le modèle opposé |

A est le socle: B/C/D/E n'ont nulle part où écrire sans lui. Cette spec ne
couvre que A.

## Existant réutilisé

- `MissionRuntimeService` — routing Claude/Codex/Local/Terminal, handoff,
  compatibilité de capacités. Le lot D s'y branchera.
- `MultiCockpitModel.ViewMode.mission` — regroupe déjà les sessions d'un
  handoff via `missionID`. Une *tâche* et une *mission* sont le même objet vu à
  deux moments; on les relie, on ne les duplique pas.
- `ThrottleMCPServer` — hôte des tools `throttle_*`. Les nouveaux tools s'y
  ajoutent selon le pattern existant (`tools/list` + `tools/call`).
- `ResearchVaultKit` — précédent interne de preuves chaînées (receipts).

Non réutilisé: `LiveFileWatcher` est câblé en dur sur les `.jsonl` de Claude
Code et sert le chemin chaud du metering. On copie son pattern `DispatchSource`
dans un watcher dédié plutôt que de le généraliser.

## Décisions

1. **Le plan vit dans le repo du projet**, sous `.throttle/`. Les agents
   délégués le lisent, git fournit l'historique, `throttle-sync` le transporte
   entre machines.
2. **Arbre + dépendances.** Hiérarchie parent/enfant pour la lecture, champ
   `dependsOn` pour les blocages transverses.
3. **Event-sourcing.** Le log append-only est la vérité; l'état est une
   projection dérivée, jetable et régénérable.
4. **Un seul process appende: Throttle.** Les agents passent par
   `ThrottleMCPServer`, qui est le binaire de l'app; l'écriture est sérialisée
   par un actor.
5. **Lot A = socle seul.** Pas de génération automatique de plan, pas d'édition
   à la souris, pas de dispatch. Le plan est écrit à la main ou par une session
   à qui on donne le schéma.

## Modèle de données

Un seul type de nœud. Une « phase » est une tâche qui a des enfants.

### `.throttle/plan.json` — structure, Throttle seul écrivain

```json
{ "schema": 1, "projectId": "uuid", "title": "Throttle",
  "tasks": [
    { "id": "T2.1", "parent": "P2", "order": 10,
      "title": "Analyse concurrence",
      "kind": "research|build|audit|decision",
      "dependsOn": ["T1.2"],
      "runtimeHint": "codex",
      "sotaGate": true }
  ] }
```

`runtimeHint` et `sotaGate` sont inertes en lot A: ils sont lus et affichés,
jamais interprétés. Les lots D et E les consommeront.

### `.throttle/log/<taskId>.ndjson` — la vérité, append-only

Une ligne = un événement JSON.

```
{"seq":1,"at":"…","by":"codex:sess_ab","type":"claimed","prev":null}
{"seq":2,"at":"…","by":"codex:sess_ab","type":"progress","pct":40}
{"seq":3,"at":"…","by":"codex:sess_ab","type":"evidence","kind":"commit","ref":"a3f19c2"}
{"seq":4,"at":"…","by":"codex:sess_ab","type":"completed","summary":"…"}
```

Types d'événements: `claimed`, `progress`, `evidence`, `blocked`, `unblocked`,
`completed`, `failed`, `released`.

`prev` = sha256 de la ligne précédente. Une chaîne cassée signifie qu'un writer
a contourné Throttle: c'est un signal exposé dans l'UI, pas une corruption.

Ce que le chaînage vaut exactement, mesuré par les tests: il détecte l'édition
de toute ligne qui a un successeur. Il ne détecte **pas** l'édition de la
dernière ligne, que rien ne cautionne, et il ne résiste pas à un writer qui
recalcule toute la chaîne. C'est de la tamper-evidence contre les éditions
négligentes, **pas** une preuve d'authorship. Obtenir une vraie preuve demande
une signature et une clé — décision à prendre au lot E, avec le problème de
distribution de clé entre machines que ça implique.

### `.throttle/state/<taskId>.json` — projection jetable

```
{ status, pct, owner, runtime, missionID, startedAt, lastSeq, evidence[], chainValid }
```

Statuts: `pending → blocked → claimed → running → review → done | failed`.

`missionID` vit dans l'état, jamais dans le plan: une tâche non démarrée n'est
pas une mission. C'est le point d'accroche du lot D.

Invariant vérifiable: `rm -rf .throttle/state` puis replay reproduit un état
identique. C'est le test qui prouve que l'event-sourcing est réel.

## Résolution des courses

Plusieurs agents peuvent tenter de prendre la même tâche. Le premier `claimed`
(par `seq`) gagne; les `claimed` suivants sont ignorés par la projection et
signalés. Déterministe, sans verrou.

Un agent peut relâcher une tâche (`released`), après quoi un autre peut la
prendre. Un `claimed` émis par un tiers alors qu'un owner est actif est rejeté
à la projection.

## Fichiers

```
Throttle/Models/PlanModels.swift        Plan, PlanTask, TaskEvent, TaskState — Codable+Sendable
Throttle/Services/PlanProjection.swift  [TaskEvent] -> TaskState, fonction pure
Throttle/Services/PlanStore.swift       load / append / replay / rebuild — actor
Throttle/Services/PlanWatcher.swift     DispatchSource sur .throttle/, debounce 250ms
Throttle/State/PlanModel.swift          @Observable pour l'UI
Throttle/UI/Cockpit/PlanTreeView.swift  arbre + inspecteur
```

Modifiés: `ThrottleMCPServer.swift` (3 tools), `MultiCockpitModel` +
`MultiCockpitRoot` (un case de plus dans `ViewMode` et son icône).

## Projection

`PlanProjection` est une fonction pure `[TaskEvent] -> TaskState`. Tout le cœur
métier est testable sans I/O, sans UI, sans agent.

Rollup: le `pct` d'une phase est la moyenne pondérée de ses feuilles. Une phase
n'a pas de `pct` propre.

Performance: le replay est mis en cache par `(taille, mtime)` du log, pour ne
pas relire chaque fichier à chaque événement FSEvent.

Non fait: la compaction du log. Une tâche produit 10–100 événements. On la fera
si un log dépasse réellement un seuil, pas avant.

## UI

Nouveau segment `.plan` dans le view switcher du Cockpit.

- Gauche: l'arbre indenté — titre, barre de %, pastille de statut, runtime
  propriétaire, marqueur « bloqué par ».
- Droite: inspecteur de la tâche sélectionnée — liste des événements du log,
  preuves, chaîne valide ou non.
- Lecture seule en lot A.

## Tools MCP

Ajoutés à `ThrottleMCPServer`:

- `throttle_plan_read` — l'arbre plus la liste de ce qui est débloquable
  (dépendances satisfaites, pas d'owner actif).
- `throttle_task_claim` — prend une tâche; échoue si déjà détenue.
- `throttle_task_event` — émet `progress` / `evidence` / `blocked` /
  `completed` / `failed` / `released` sur une tâche détenue.

Refus explicites: écrire un événement sur une tâche qu'on ne détient pas,
chemin hors du repo, tâche inconnue.

## Tests

- Projection pure: chaque transition de statut, course au claim, `claimed`
  d'un tiers rejeté, chaîne cassée détectée, `released` puis re-claim.
- Replay: `rm -rf state/` reproduit un état identique.
- Rollup de % sur un arbre à trois niveaux.
- Store: append concurrent depuis deux appelants MCP, chaîne restée valide.
- Watcher: une écriture déclenche un rafraîchissement, une rafale est débouncée.

## Hors périmètre

Génération automatique de plan, édition dans l'UI, dispatch vers des runtimes,
boucle SOTA, contre-analyse, arbitrage par crédits ou RAM, compaction, CRDT.
