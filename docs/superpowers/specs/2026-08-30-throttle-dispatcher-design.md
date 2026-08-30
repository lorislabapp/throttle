# Throttle Dispatcher — design (lot D)

Date: 2026-08-30
Statut: spec validée en brainstorming, non implémentée.
Dépend de: `2026-08-29-throttle-plan-store-design.md` (lot A, committé en `ed73034`).

## Périmètre

Le lot A a produit le plan: un arbre de tâches, un log append-only par tâche, et
trois tools MCP par lesquels un agent prend une tâche et rend compte. Personne ne
décide encore *qui* fait *quoi*.

Le lot D remplit ce trou, et rien de plus: pour une tâche débloquée, recommander
un runtime, montrer pourquoi, et — sur un geste de l'utilisateur — préparer un
worktree isolé et ouvrir la session dedans.

Hors périmètre, explicitement: le merge, la boucle « jusqu'au SOTA », la
contre-analyse par le modèle opposé, le best-of-N. Tout cela est le lot E.

## Décisions, et ce qui les a tranchées

### 1. Advisory, jamais automatique

Throttle calcule la recommandation et l'affiche sur la tâche. L'utilisateur
lance. Aucune session n'est ouverte sans un geste humain.

La recherche de Kevin du 2026-08-18 conclut « adopter le router advisory +
abstention, rejeter l'auto-routing ». L'idée de départ décrivait un dispatcher
qui assigne seul; la doctrine a gagné. Le coût d'une mauvaise recommandation
reste ainsi nul.

### 2. Règles et contraintes live, pas d'apprentissage

Au jour 1 il n'existe aucun historique. Les logs du lot A en accumuleront, et un
lot ultérieur pourra calibrer dessus. En attendant, la recommandation se fonde
sur des signaux vérifiables, pas sur une intuition statistique tirée de rien.

`RouterAdvisorService` existe déjà mais répond à un autre axe — local vs
frontier. Le lot D ajoute l'axe Claude Code vs Codex, en reprenant sa forme
(`Advice` = recommandation + raisons + historique) sans le modifier.

### 3. Parallélisme entre tâches, pas dans une tâche

Le lot A garantit un propriétaire par tâche. Plutôt que de casser cet invariant,
le parallélisme vient du DAG: toutes les feuilles débloquées peuvent tourner en
même temps. Une tâche qui mériterait plusieurs agents doit être **découpée en
enfants** — le plan sait déjà faire des enfants.

Ce n'est pas un compromis. La recherche (2026-08-30) désigne la décomposition
spec-driven avec frontières de fichiers et d'interfaces explicites comme *le*
mécanisme qui fait marcher le parallèle sur du code. Ce qui dégrade, c'est
plusieurs agents sans frontières: collisions, conflits de merge, et sur les
tâches petites à moyennes un coût de coordination supérieur au séquentiel.

Une exception mesurée: sur les feuilles `kind: research`, le fan-out
orchestrateur-workers est réellement supérieur (exploration en largeur, contextes
isolés). Il y est autorisé, plafonné, et jamais silencieux.

### 4. Un worktree par tâche, merge jamais automatique

`Lancer` crée `.claude/worktrees/<taskId>`, ouvre un onglet Cockpit sur le
runtime recommandé avec ce worktree pour cwd, et écrit l'événement `claimed`.

À `completed`, Throttle **ne merge pas**: il montre le diff. Le merge est une
écriture irréversible; la déclencher depuis un agent est précisément le piège
documenté (deux worktrees mergent chacun avec succès et fabriquent un conflit
qu'aucun ne détecte). Le lot E pourra proposer le merge, jamais l'exécuter seul.

Nettoyage: Throttle supprime automatiquement un worktree dont la tâche est `done`
**et** dont le diff est vide ou déjà mergé. Tout le reste attend un geste. Jamais
de suppression d'un worktree contenant du travail non intégré.

## Composants

```
Services/DispatchAdvisor.swift       pur — (tâche, capacités, budgets, RAM) -> DispatchAdvice
Services/DispatchBudget.swift        lecture live des contraintes
Services/TaskWorktreeService.swift   création / inventaire / nettoyage gardé
Services/TaskLauncher.swift          worktree + onglet + prompt d'amorce + claimed
UI/Cockpit/PlanTreeView.swift        bloc recommandation, [Lancer] [Changer…]
```

Modifié: `PlanTreeView` seulement. `MissionRuntimeService`, `CodexUsageService`,
`SystemMemoryService` et `PlanStore` sont lus, jamais changés.

## L'avis

```swift
struct DispatchAdvice {
    enum Verdict { case runtime(AgentRuntime), abstain }
    let verdict: Verdict
    let confidence: Confidence      // high, medium, low
    let reasons: [String]           // une ligne par signal ayant pesé
    let fanOut: Int                 // 1 sauf feuille research autorisée
    let tokenMultiplier: Double?    // affiché avant tout fan-out
    let waitEstimate: TimeInterval? // quand les deux runtimes sont épuisés
}
```

`DispatchAdvisor.advise(...)` est une fonction pure: pas d'I/O, pas d'horloge,
pas de processus. Les budgets et la mémoire lui sont injectés par
`DispatchBudget`, ce qui rend chaque règle testable isolément.

### Ordre des signaux

Le premier qui tranche gagne. Aucun ne tranche → abstention.

1. **Capacités (dur).** `MissionRuntimeService.capabilityInventory` sait déjà
   quels skills et serveurs MCP chaque runtime possède *dans ce repo*. Une tâche
   qui nomme un skill que seul un runtime a → ce runtime, confiance haute. C'est
   un fait de système de fichiers, pas une devinette.
2. **Kind.** `research` autorise le fan-out; `build`, `audit` et `decision`
   restent à un agent.
3. **Budget.** Un runtime au bout de sa fenêtre sort de la course. Les deux
   épuisés → abstention accompagnée d'une estimation d'attente.
4. **Mémoire.** Sous le plafond de concurrence *mesuré* (voir ci-dessous), le
   fan-out retombe à 1 et l'avis propose d'attendre plutôt que de faire swapper
   la machine.
5. **Rien de dominant** → `abstain`, avec les faits affichés. Une recommandation
   faible déguisée en certitude est pire que pas de recommandation.

### Le plafond de concurrence est mesuré, pas réglé

Throttle est vendu. Un seuil calibré sur la machine du développeur est
exactement ce qu'il ne faut pas livrer: il serait trop bas sur un Mac de 64 Go et
trop haut sur un portable de 8 Go.

`SystemMemoryService` sait déjà tout ce qu'il faut:

- `subtreeRSS(rootPids:)` — la mémoire réellement occupée par chaque session
  claude/codex **de cet utilisateur, sur cette machine**;
- `pressureLevel()` — le signal de macOS lui-même, qui est l'autorité, et non une
  arithmétique sur les octets libres;
- `underPressure` / `critical` — des seuils que l'app définit déjà.

La règle: mesurer l'empreinte médiane d'une session ici, la comparer à la marge
disponible, et cesser d'ajouter des agents dès que la pression monte ou que le
swap grossit. Aucun réglage, aucune constante en gigaoctets dans le code. Un
utilisateur dont les sessions sont plus lourdes obtient un plafond plus bas de
lui-même.

### Le fan-out est une question de coût, pas de mémoire

Une fois la mémoire dérivée, il reste une vraie décision d'utilisateur: combien
il accepte de dépenser. Elle s'exprime en argent, pas en nombre d'agents —
« 4 agents » ne veut rien dire pour quelqu'un qui n'a pas la table des prix en
tête, alors que Throttle, lui, connaît le prix des tokens.

**Un seul réglage visible**: le plafond de dépense par tâche. Throttle le traduit
en nombre d'agents, sous le plafond de concurrence mesuré. Le défaut est
conservateur (un agent) — le fan-out est un choix, jamais une surprise sur la
facture.

Six curseurs seraient le signe qu'on n'a pas su décider à la place de
l'utilisateur.

### Honnêteté sur les tokens

Un fan-out multiplie la consommation — la littérature mesure les systèmes
multi-agents à 4–220× les tokens d'un agent seul. Throttle affiche le
multiplicateur estimé avant de lancer. Cacher ce chiffre dans une app dont le
métier est de compter les tokens serait absurde.

Le fan-out `research` est borné par deux choses seulement: le plafond de dépense
choisi par l'utilisateur, et le plafond de concurrence mesuré. Aucune constante
arbitraire — le « 4 » d'une version antérieure de cette spec était mon chiffre,
pas un résultat.

Best-of-N (plafond utile mesuré autour de N=8, avec vérificateur plutôt que vote
majoritaire) appartient au lot E.

## Tests

- **Advisor**, un cas par signal: capacité décisive, kind, runtime épuisé, les
  deux épuisés, RAM basse, aucun signal → abstention.
- **Précédence**: la capacité l'emporte sur le kind; le budget retire un runtime
  que la capacité désignait; le plafond de concurrence écrase le fan-out.
- **Plafond mesuré**: à empreinte de session égale, une machine avec plus de
  marge autorise plus d'agents — le même test passe sur 16 Go et sur 64 Go sans
  changer de valeur attendue, seulement l'entrée mesurée.
- **Plafond de dépense**: un budget qui n'autorise qu'un agent donne `fanOut == 1`
  même sur une feuille `research` avec de la marge mémoire.
- **Multiplicateur de tokens**: présent dès que `fanOut > 1`, absent sinon.
- **Worktree**: création idempotente, refus de nettoyer un worktree au diff non
  vide, nettoyage d'un worktree `done` et vide.
- **Launcher**: écrit exactement un `claimed`, avec le `missionID` de l'onglet.

## Ce que le lot D ne fait pas

Merger, décider seul, lancer sans geste humain, apprendre de l'historique,
supprimer du travail non intégré, cacher le coût d'un fan-out, ou coder en dur un
seuil calibré sur la machine du développeur.
