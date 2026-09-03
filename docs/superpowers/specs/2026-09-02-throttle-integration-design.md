# Throttle Integration — design (lot F)

Date: 2026-09-02
Statut: spec validée en brainstorming, non implémentée.
Dépend de: `2026-08-29-throttle-plan-store-design.md` (lot A, `ed73034`) et
`2026-08-30-throttle-dispatcher-design.md` (lot D, `5f220fc`).

## Périmètre

Le lot D donne à chaque tâche son worktree isolé et refuse explicitement de
merger. Le lot E rend une tâche gatée traversable par la contre-analyse. Il en
résulte un trou: une tâche finie vit dans un worktree que rien ne relit et que
rien n'intègre. Les worktrees s'accumulent, et le travail des agents n'atteint
jamais la branche de base.

Le lot F remplit ce trou et rien d'autre: relire le diff d'une tâche terminée,
vérifier que le travail tient une fois combiné à la base courante, et — sur un
geste humain — l'intégrer.

Hors périmètre, explicitement: la résolution automatique de conflit, le
best-of-N, le push, les pull requests, et toute intégration déclenchée sans
clic.

## Décisions, et ce qui les a tranchées

### 1. Le conflit est le cas normal, pas l'exception

`AgenticFlict` (arXiv 2604.03551, AIware 2026) simule la fusion de 107 000 PR
produites par des agents et mesure **27,67 % de conflits**, avec 336 000 régions
de conflit extraites. Un chemin emprunté par plus d'un quart des tâches n'est pas
une erreur à signaler en rouge: c'est un état de premier rang, avec ses fichiers
nommés et sa suite d'actions.

Conséquence de conception: `assess` rend le conflit comme une donnée structurée
(les chemins en cause), pas comme une chaîne d'erreur.

### 2. La vérification tourne après la fusion, jamais avant

Un conflit *sémantique* passe la fusion textuelle et casse le comportement: deux
branches vertes séparément, rouges ensemble. La littérature le documente et le
mesure — la détection passe par des tests joués sur le résultat combiné
(« Detecting Semantic Conflicts with Unit Tests », arXiv 2310.02395).

Une preuve de test produite par l'agent avant le rebase ne dit donc rien sur ce
qui sera mergé. Throttle relance lui-même la commande de vérification, dans le
worktree, **après** le rebase.

### 3. Le vert est estampillé, pas mis en file

Le remède industriel au problème « chaque branche est verte, leur somme est
rouge » est la merge queue: intégrer une branche à la fois, revérifier après
chaque intégration. La sémantique est la bonne; la structure de file ne l'est
pas ici — elle demanderait un état à maintenir, à afficher et à réordonner pour
un utilisateur qui intègre ses tâches une par une de toute façon.

Throttle obtient la même garantie sans file: chaque `checked` porte
`task<sha>+base<sha>`, et n'est vert que tant que les deux tiennent. Intégrer une
tâche déplace la base, donc périme mécaniquement le vert de toutes les autres.
Un vert périmé devient impossible par construction, pas par discipline.

### 4. Deux événements, parce que git sait déjà le reste

- `checked` — auteur `throttle`, porte la commande, son verdict, sa sortie
  tronquée en cas d'échec, et l'estampille des deux sha.
- `integrated` — terminal, porte le sha de fusion.

Le conflit n'est pas journalisé: git le recalcule à coût nul et sans ambiguïté.
Le log ne stocke que ce que git ne peut pas redire — un verdict de test daté et
attribuable en fait partie, un conflit non.

`checked` est un fait, pas un cache. C'est pourquoi il vit dans le log
append-only et non à côté de la projection: la question « qu'est-ce qui a été
vérifié, quand, sur quel arbre » doit rester lisible des mois plus tard, y
compris par la contre-analyse.

### 5. `done` se rouvre pour un seul événement

Le lot A a fait de `done` un état terminal; le lot E a dû rouvrir `.review` pour
la même raison qu'ici. `integrated` devient le seul événement accepté après
`done`, et il est lui-même terminal. Tout le reste continue d'être refusé avec
`RejectedEvent.Reason.terminal`, donc un agent ne peut toujours pas revenir
rapporter sur un travail qu'il a déclaré fini.

### 6. Fast-forward seulement

L'ordre rebase → vérif → merge n'est pas une commodité: après un rebase réussi,
la fusion **est** un fast-forward. Il devient structurellement impossible que le
merge fabrique un conflit que le diff affiché ne montrait pas, et un `--ff-only`
qui échoue signifie exactement une chose — la base a bougé entre l'affichage et
le clic. C'est un refus propre, jamais un commit de merge surprise.

### 7. La commande de vérification est du code hostile jusqu'à preuve du contraire

`verify` vient de `.throttle/plan.json`, c'est-à-dire d'un fichier du repo.
Cloner un dépôt inconnu et l'ouvrir dans Throttle ne doit pas exécuter ce qu'il
demande. La première exécution demande une confirmation explicite, mémorisée par
(projet, hash de la commande); la commande change → la confirmation est
redemandée.

C'est la règle « fail closed sur une identité ambiguë » appliquée à une chaîne
de shell.

## Composants

### `TaskIntegrationService` — pur, sans UI

```
assess(taskID, repo, base) -> Assessment
    baseSHA, taskSHA, behindBy, isDirty,
    files: [(path, added, removed)],
    mergeability: .clean | .conflicted([path])
```

Le conflit est calculé par `git merge-tree --write-tree`, qui produit l'arbre
fusionné dans la base d'objets **sans toucher ni au worktree ni à l'index**:
relire une tâche ne modifie jamais ce que l'agent y a laissé. Cette forme de
`merge-tree` demande git >= 2.38 (2.54 sur cette machine); en dessous, `assess`
rend `mergeability` inconnue et l'intégration exige un rebase explicite plutôt
que de deviner.

La base est la branche courante du dépôt principal au moment de l'appel — celle
sur laquelle le fast-forward se fera. Elle est relue à chaque `assess`, jamais
mémorisée à la création du worktree, puisque c'est précisément son déplacement
qui périme les verts.

Le côté tâche est lu sur la ref `task/<id>`, et `assess` **refuse** (`détaché`)
si le worktree n'est plus sur cette branche. Sinon `verify` produirait sa preuve
contre l'arbre du worktree pendant que l'estampille décrit la branche, et
`rebase` réécrirait les commits détachés en laissant la ref en arrière.

```
rebase(taskID, repo, onto) -> Result
```

Refusé si le worktree porte des modifications non committées **sur des fichiers
suivis** — comme `integrate`. La vue stricte, qui comptait aussi les fichiers non
suivis, ne faisait qu'ouvrir une impasse: un `.build/` laissé par la vérification
précédente bloquait le rebase du clic suivant, sans aucun clic capable de le
lever. git refuse le rebase de lui-même quand un fichier non suivi serait
réellement écrasé. `git rebase --abort` au premier conflit, donc un échec laisse
le worktree au sha exact où il était.

```
verify(taskID, repo, command) -> Verdict
```

Lance la commande dans le worktree, avec un timeout et une sortie tronquée,
puis écrit le `checked` correspondant.

Le processus est lancé par `posix_spawn` avec `POSIX_SPAWN_SETPGROUP`, donc il
**mène son propre groupe de processus**, et le timeout signale le groupe
(SIGTERM puis SIGKILL). `Process` ne peut pas: il donne à l'enfant le groupe de
Throttle, et seul le pid du shell pouvait être signalé — un `swift test` tué à
son deadline laissait derrière lui le compilateur et les binaires de test, qui
tenaient le pipe et la RAM. Le groupe n'est jamais supposé: `getpgid` est
interrogé, et `kill(-pid, …)` n'est employé que si le noyau confirme que ce pid
mène un groupe qui n'est pas celui de Throttle.

Le spawn porte aussi `POSIX_SPAWN_CLOEXEC_DEFAULT`, comme `Foundation.Process`:
sans lui, la commande du projet hérite de tous les descripteurs non
close-on-exec de l'application — et, deux projets pouvant s'intégrer en même
temps, l'enfant du projet B tenait le côté écriture du pipe du projet A, dont le
pipe ne signalait alors jamais l'EOF. L'entrée standard est explicitement
`/dev/null`, pas celle de l'app.

L'escalade SIGKILL n'est annulée que lorsque le **groupe est vide**, jamais à la
sortie du seul leader: un membre qui ignore SIGTERM survivait exactement au cas
que ce mécanisme existe pour fermer.

```
integrate(taskID, repo) -> String   // sha de fusion
```

Quatre refus propres, chacun avec sa raison rendue telle quelle à l'UI, plus
celui que `assess` remonte:

| Refus | Condition |
|---|---|
| worktree sale | modifications non committées **sur des fichiers suivis** |
| pas à jour | la branche de tâche n'est pas rebasée sur la base courante |
| non vérifié | aucun `checked` vert estampillé aux sha courants |
| non validé | `sotaGate` sans `verified` dans le log |
| détaché | (via `assess`) le worktree n'est plus sur `task/<id>` |

Puis `git merge --ff-only task/<id>` sur la base, et l'événement `integrated`.

### Modèle

- `Plan.verify: String?`, `PlanTask.verify: String?` (la tâche surcharge le
  projet). Décodage tolérant, comme tout le schéma.
- `TaskEventType`: `+ checked, integrated`.
- `TaskStatus`: `+ integrated`.
- `TaskEvent`: `+ ok: Bool?`, le verdict d'un `checked`.

### Surface

Une tâche `done` porte une carte dans `PlanTreeView`: fichiers touchés, +/−, le
diff en monospace scrollable, et **un seul bouton « Intégrer »**. Il enchaîne
rebase → vérif → merge en montrant l'étape courante, et s'arrête au premier
refus en nommant lequel.

Trois règles sur ce que la carte a le droit de taire — c'est-à-dire rien:

- Quand le bouton est désactivé, la ligne en dessous **dit pourquoi**. La carte
  lit la même vue « fichiers suivis seulement » que le service, donc un artefact
  de build ne désactive plus rien.
- Quand `assess` refuse (worktree détaché, par exemple), la carte affiche ce
  refus **à la place** des contrôles. L'erreur est mémorisée par tâche et purgée
  comme les caches; auparavant un `try?` la jetait et la carte se réduisait à un
  espace vide.
- L'étape en cours est **indexée par racine de projet**: une intégration dans le
  projet A ne grise plus le bouton du projet B, alors que le modèle est unique et
  suit l'onglet actif.

Un bouton plutôt que trois: chaque étape est une conséquence mécanique de la
précédente, et découper le geste ferait porter à l'utilisateur un ordre
d'opérations que le service connaît mieux que lui. Ce qui reste visible, c'est
où ça s'est arrêté.

Après une intégration réussie, le worktree est retiré: c'est ce qui ferme
l'accumulation annoncée par le périmètre. **Jamais avec `force`**, et le refus de
`TaskWorktreeService.remove` reste souverain — un worktree qui porte encore des
modifications non committées ou des commits non fusionnés est laissé debout, la
raison est rapportée, et l'intégration reste le succès qu'elle est. Un échec de
nettoyage ne transforme jamais une fusion qui a eu lieu en échec.

Le retrait n'est **pas** dans `integrate`. Le worktree d'une tâche est aussi le
répertoire de travail de son agent: le cockpit ouvre l'onglet de la tâche avec ce
chemin comme cwd, et une tâche finie et committée est précisément le cas que le
nettoyage vise. Supprimer sous un onglet vivant laisse ce shell avec un cwd
effacé et fait échouer obscurément toute commande tapée ensuite. Le service ne
voit pas les onglets, donc il ne décide pas: il expose
`removeWorktree(taskID:in:)`, qui retire et **dit pourquoi** quand il ne peut
pas, et c'est la séquence d'intégration dans `PlanModel` qui l'appelle — seulement
si aucune session du cockpit n'a ce répertoire (ou un sous-répertoire) pour cwd.
Sinon le worktree reste debout et la carte le dit sous le sha intégré.

## Tests

Sur de vrais dépôts git jetables, comme le lot D — les refus sont ce qui compte.

- **Conflit**: deux branches touchant la même ligne → `.conflicted` avec le
  chemin, et le worktree est inchangé après l'appel (sha et statut identiques).
- **Rebase avorté**: conflit pendant le rebase → sha d'origine restauré, aucun
  rebase en cours résiduel.
- **Worktree sale**: rebase et intégration refusés tous les deux.
- **Estampille**: un `checked` vert, puis un commit sur la base → le vert n'est
  plus valide et l'intégration est refusée.
- **ff-only**: la base avance entre l'affichage et le clic → refus, aucune
  écriture sur la base.
- **Gate SOTA**: tâche `sotaGate` sans `verified` → refus, même tout vert par
  ailleurs.
- **Terminal**: après `integrated`, tout événement est refusé en `terminal`;
  avant lui, `integrated` est le seul accepté sur une tâche `done`.
- **Consentement**: une commande jamais confirmée n'est pas exécutée; la même
  commande reconfirmée l'est; une commande modifiée redemande.
- **Groupe de processus**: une commande qui lance un enfant survivant à son
  parent ne laisse **aucun descendant vivant** après le timeout — assertion sur
  `kill(pid, 0)` et sur le fichier témoin que l'orphelin n'a pas écrit.
- **Artefact de build**: un `.build/` non suivi ne bloque ni le rebase ni la
  carte, alors qu'un fichier suivi modifié bloque toujours les deux.
- **Nettoyage**: le worktree d'une tâche intégrée disparaît; un worktree qui
  porte encore du travail reste debout et l'intégration reste un succès; un
  worktree dans lequel une session du cockpit travaille encore reste debout lui
  aussi, et la carte dit pourquoi.
- **Groupe non vidé**: un descendant qui **ignore** SIGTERM est tout de même
  parti après le timeout — l'escalade SIGKILL n'est relâchée que quand le groupe
  est vide, pas quand son leader est sorti.

## Ce que le lot F ne fait pas

Résoudre un conflit, merger sans clic, pousser quoi que ce soit, ouvrir une PR,
intégrer plusieurs tâches d'un geste, exécuter une commande jamais confirmée, ou
supprimer un worktree dont le travail n'est pas dans la base — le nettoyage
d'après-intégration s'arrête exactement là où `remove` refuse.
