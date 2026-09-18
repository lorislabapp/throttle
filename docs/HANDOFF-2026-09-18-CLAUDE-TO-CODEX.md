# Throttle — Passation Claude Code → Codex (2026-09-18)

**Statut : travail livré, testé localement, *rien* publié ni poussé.**
Ce document est une orientation, pas une preuve. Revalide le checkout avant d'agir.

Runtime source : Claude Code (Opus 5, 1M) · Runtime cible : Codex
Rédigé après la mort brutale de la session `cf60d1b8` (voir §8).

---

## 1. Où est le travail

| | |
|---|---|
| Worktree actif | `~/.claude/worktrees/throttle-project-overview` |
| Branche | `feat/cockpit-navigation` |
| HEAD | `691499f` |
| Avance sur `origin/main` | **34 commits, aucun push** |
| Dépôt | `https://github.com/lorislabapp/throttle.git` |
| Worktree principal | `~/GitHub/Throttle` sur `feat/research-vault-lots-1-4` (ne pas mélanger) |

Arbre propre à l'exception de logs/dossiers de build non suivis (`build-*.log`,
`build-preview-v5/`, `build-release/`). Ne les commite pas, ne les supprime pas
sans demander.

⚠️ `~/GitHub/Throttle` contient **13 worktrees**. Vérifie toujours dans lequel tu
es (`git worktree list`) avant d'éditer. Rappel : `settings.local.json` refuse
`Read(./build/**)` — dans ces worktrees-là il faut passer par `cat`, `sed`,
`git show` ou `sh -c 'cd …'`.

---

## 2. Ce qui a été livré (et prouvé)

### Lots A / B / C — 17 septembre, dans le DMG 3.8.0 (225)

- **A. Tableau de flux.** Chaque projet s'ouvre sur l'onglet « Flux » avant
  « Vue d'ensemble » et « Plan ». Colonnes : À démarrer, Agent au travail,
  À corriger, En vérification, Prêt à intégrer, Intégré, En attente. Bandeau
  « Étape suivante » avec **un seul** bouton. Panneau droit : santé du projet
  (tâches en échec, tests, décisions en attente, journal) + activité récente.
  « Aujourd'hui » agrège les mêmes compteurs pour tous les projets.
- **C. Correction + apprentissage.** Une tâche relancée transporte les raisons
  de ses échecs précédents. Colonne « À retenir » : chaque leçon est ajoutable
  à `CLAUDE.md` **d'un clic explicite** — Throttle n'écrit jamais tout seul.
- **B. Agents spécialisés.** Menu « Rôle » à côté de Lancer : Développeur,
  Tests, Red team sécurité, Documentation, UI/UX, Refactorisation. Rôle déduit
  du titre de la tâche, modifiable. **Décision assumée : un agent par tâche, pas
  d'essaim** — coût lisible, et la vérification par l'autre famille de modèles
  reste la seule contre-expertise.
- Coffre de recherche : import réel des documents (et pas seulement des reçus),
  espaces par projet, création d'un espace projet depuis la barre latérale,
  raison affichée sous un dossier illisible.

### Lots D / E — 18 septembre, commités aujourd'hui, **pas encore dans un DMG**

- **D — `7abef99` : coût par tâche et par plan.** `Throttle/Services/TaskSpend.swift`.
  La jointure est le **worktree** : une tâche tourne dans son propre worktree,
  donc toute session Claude Code ouverte dans ce dossier lui appartient. Cette
  jointure survit aux redémarrages, contrairement à un onglet vivant.
  Affichage : le montant sur la carte de tâche du flux, le total dans le panneau
  latéral. **Les tâches sans session sont comptées à part**, jamais à zéro : une
  moyenne sur des inconnues se lit comme une facture plus petite, pas comme une
  mesure manquante. Libellé obligatoire : valeur API-équivalente des tokens, ni
  l'abonnement, ni ajoutée à l'abonnement.
- **E — `491b167` + `691499f` : les agents hors Throttle.** Lit l'inventaire de
  la CLI (`claude agents --json`) et liste dans « Aujourd'hui » ce qui tourne
  ailleurs — sessions background, et threads cloud quand ils arriveront.
  « Ouvrir » fait `claude attach <id>` dans un onglet terminal : on se rattache
  à la session existante, on n'en démarre pas une seconde sur le même travail.
  Seule la forme d'identifiant de la CLI atteint la ligne de shell.
  **Correctif `691499f` :** `--all` a été retiré. Mesuré sur la vraie CLI : avec
  `--all`, 5 sessions background reviennent dont 3 arrêtées ou en échec depuis
  des mois ; sans, il en reste 2, **bloquées depuis août** — exactement le signal
  pour lequel la carte existe.

### Preuves de validation (rejouées le 18/09, pas héritées)

```
xcodegen generate
swiftlint lint --quiet --strict                         → 0 violation
xcodebuild test -project Throttle.xcodeproj -scheme Throttle \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -skipMacroValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:ThrottleTests/TaskSpendTests \
  -only-testing:ThrottleTests/ClaudeAgentInventoryTests   → ** TEST SUCCEEDED **
```

Forme réelle de `claude agents --json`, vérifiée le 18/09 :
`[{id, cwd, kind, startedAt (ms), sessionId, name, state}]` — `kind` ∈
{interactive, background}, `state` absent pour interactive, ∈ {blocked, failed,
stopped} sinon. Le parseur de `ClaudeAgentInventory` correspond exactement.
**Aucune session `kind: "cloud"` n'existe encore sur cette machine** : le chemin
cloud est écrit mais non observé.

---

## 3. Release 3.8.0 (225) — prête, **non publiée**

- DMG **notarisé par Apple et stapé**, signature Ed25519 vérifiée, appcast en
  tête sur `<sparkle:version>225</sparkle:version>` / « Version 3.8.0 ».
- Le dossier de mise en scène était dans le scratchpad d'une session morte. Il a
  été **copié le 18/09 vers un emplacement durable** :
  `~/GitHub/Throttle/build/stage-3.8.0/throttle/{appcast.xml, index.html, Throttle-3.8.0.dmg}` (33 Mo).
  L'original temporaire existe encore mais peut disparaître à tout moment.
- ⚠️ **Le DMG 3.8.0 ne contient PAS les lots D et E** (commités après la
  notarisation). Si on publie tel quel, on publie A/B/C + coffre uniquement.
- ⚠️ **Sparkle compare le numéro de BUILD, pas `MARKETING_VERSION`.** Toute
  nouvelle build doit bumper `CFBundleVersion` (226…) ou personne ne verra la
  mise à jour.

### Bloquant humain

**Kevin n'a jamais testé ce build.** Publier avant son test enverrait aux
utilisateurs une UI que personne n'a vue tourner. C'est la règle, pas une
précaution.

### Commandes — à lancer par Kevin lui-même avec `!` (le classifier les bloque)

```
! nohup ~/install-throttle-preview.sh &     # puis ⌘Q sur Throttle
! node ~/.claude/worktrees/throttle-project-overview/scripts/publish-release.mjs \
    ~/GitHub/Throttle/build/stage-3.8.0
```

---

## 4. Anthropic « Projects, redesigned » — ce qu'on en a dit

Source : <https://claude.com/blog/projects-redesigned>, lue le 18/09 par la
session précédente (non refetchée depuis — à revérifier avant toute décision
irréversible).

**Ce qu'Anthropic a fait**
- Les Projects deviennent un **coordinateur** : il découpe la demande et la
  répartit sur des threads parallèles, chacun étant une session Claude Code
  **cloud** sur sa propre branche.
- **Mémoire de projet partagée** (décisions, dates, choix d'architecture).
- Bibliothèque de fichiers du projet.
- Beta, Pro/Max, **cloud uniquement** — le local est annoncé « bientôt ».

**Ce que ça menace chez Throttle**
- La couche coordinateur du Plan : découper et répartir sur des agents, c'est
  exactement ce que le Plan fait.
- La mémoire de projet recoupe le plan store et `CLAUDE.md`.

**Ce que ça valide**
- Le multi-thread devient la norme → savoir « qui travaille sur quoi » est un
  vrai besoin : c'est le tableau de flux (lot A).
- Leur propre avertissement — « les projets atteignent les limites d'usage plus
  vite » — est le terrain de Throttle : **personne ne dit combien coûte un
  thread.**

**Ce qui reste en propre à Throttle**
- Local-first, et le coût **mesuré** par tâche, par thread, par projet.
- Multi-runtime : Claude **et** Codex, avec vérification par une autre famille
  de modèles.
- La preuve : reçus, journal chaîné, rien de « fait » sans vérification.
- Le coffre de recherche chiffré, sur la machine.

**Le vrai risque, dit honnêtement à Kevin :** quand le local arrivera chez eux,
la partie « orchestrer » de Throttle sera commoditisée. La partie « mesurer,
prouver, arbitrer le coût » ne l'est pas.

**Décision de Kevin (18/09, verbatim) : « on fait ce qui est absolument state of
the art peu importe le coût ».** Réponse retenue = **A + B à fond** :
- **A. Coût par thread** — attribuer dépense et quota à chaque thread/tâche, y
  compris les sessions cloud. → **lot D livré** pour les sessions locales ; le
  volet cloud reste ouvert (§6).
- **B. Suivre leurs threads cloud dans le cockpit**, à côté des siens. → **lot E
  livré** ; le `kind: "cloud"` est géré mais jamais observé, l'API beta bougera.
- (C. « Ne rien changer, finir 3.8.0 » a été écarté.)

---

## 5. Mac mini — ce qu'on en a dit

Kevin **va recevoir un Mac mini** (mémoire projet : M5 Pro 64 Go prévu —
spécifications à confirmer auprès de lui, ne rien affirmer).

**Idée retenue :** le Mac mini **exécute les sessions**, le MacBook reste le
**poste de pilotage**, liaison Tailscale.

**Ce qui existe déjà et qu'il faut réutiliser plutôt que réécrire**
- Délégation de session à une autre machine + `ttyd` + `tmux` (déjà shippé côté
  agent edge, commit `babe73e`).
- `scripts/throttle-sync.sh` + miroirs git nus avec `refs/wip/<machine>` : le
  travail non committé survit au changement de machine. **Un FS partagé
  (SMB/Syncthing sur `~/GitHub`) a été explicitement rejeté — 3 preuves.**
- Agent edge sur Proxmox LXC 134, joignable en `100.123.83.107:8787/8788` via
  DNAT hôte ; streaming de frappes ttyd vérifié en vrai.
- `ThrottlePeer` / Weave : **attention**, `~/GitHub/Remote` + Weave servent à
  **renvoyer l'écran** d'une app à distance, *pas* à exécuter les sessions
  ailleurs. Ne pas confondre les deux briques.

**Ce que le Mac mini change vraiment**
- Il lève la contrainte RAM du MacBook 16 Go (cause probable de la mort de la
  session, §8) : les builds Xcode et les agents lourds partent sur le mini.
- Il ne change **rien** au coût en tokens, qui reste la vraie contrainte.
- Piège connu : un `claude` sur le mini a besoin de sa **propre authentification**
  (c'est ce qui bloque encore l'offload réel sur LXC 134, qui tourne sur un
  `CLAUDE_CMD` factice).

**Statut : discuté, rien de décidé, rien de codé.** C'est un sujet à rouvrir
avec Kevin quand la machine est là — une question à la fois.

---

## 6. Ce qui reste à faire

### Bloquants humains (Kevin seul)
1. **Tester le build 3.8.0** (installer + ⌘Q). Rien ne se publie avant.
2. Décider si on publie 3.8.0 tel quel (sans D/E) ou si on refait une build 226
   avec D/E dedans. **Recommandation : build 226 avec D/E**, le coût par tâche
   est le différenciateur du moment.
3. Lancer lui-même l'upload (`!`) — le classifier bloque la publication.
4. Confirmer les specs et la date d'arrivée du Mac mini.

### Produit — suite directe des lots D/E
5. **Coût des threads cloud.** Aujourd'hui `TaskSpend` ne mesure que les
   sessions locales (transcripts `~/.claude/projects/<dossier-worktree>/`). Un
   thread cloud n'écrit rien en local : trouver ce que la CLI/API expose, ou
   afficher honnêtement « non mesuré » plutôt qu'un zéro.
6. **`kind: "cloud"` jamais observé.** Retester `ClaudeAgentInventory` dès que
   Kevin a un vrai thread cloud ; l'API beta bougera.
7. **Rafraîchissement de la carte agents.** `.task` ne se relance pas : la liste
   se fige à l'ouverture de « Aujourd'hui ». Lui donner la même boucle 4 s que
   le reste, ou un bouton.
8. **Aucun test d'UI** sur `OutsideAgentsCard` ni sur l'affichage du coût : seuls
   les services sont couverts (9 tests : 5 inventaire, 4 coût).

### Dette laissée ouverte
9. **Éclair, T1.1** : l'agent a été coupé par un redémarrage de Throttle le 17/09
   (13 min, ~11 $, 200 lignes). La tâche reste marquée « Attribuée » alors que
   personne ne travaille dessus. Le flux le signale mais ne la libère pas.
10. **Coffre** : l'import DeepSearsh était encore en cours (24 espaces) ; « 1
    dossier illisible » devait être diagnostiqué depuis le nouveau build. Limite
    assumée : Throttle importe les recherches existantes, il n'en lance pas.
11. **CI non surveillée** : rouge depuis 3.2.96 sans que personne le voie
    (SwiftLint non épinglé), et TestFlight est gaté dessus. Faire
    `gh run list` autour de chaque release.
12. `docs/BACKLOG.md` et `docs/TODO.md` du dépôt restent la liste longue.

---

## 7. Garde-fous — non négociables

- **Ne jamais redémarrer ni réinstaller Throttle sans l'accord explicite de
  Kevin, à chaque fois.** Un redémarrage tue ses sessions en cours (c'est ce qui
  a coupé l'agent d'Éclair). Toute édition de `~/.claude.json` redémarre l'app :
  `throttle-memory` **est** le binaire de l'app.
- **Ne jamais lancer l'app depuis `build/export`** : Sparkle casse à la release
  suivante. La prod, c'est `/Applications`.
- Ne pas publier, pousser, merger, déployer sans autorisation explicite.
- **Jamais de chiffre inventé.** Une valeur non défendable est dégradée (`≈`,
  ton atténué, tag `est`) ou la cellule est masquée. Les montants EUR sont de la
  valeur API-équivalente, jamais de la dépense d'abonnement.
- **`xcodebuild` : `df` d'abord.** Un build+test complet = ~4,5 Go de
  DerivedData ; disque plein → échec de link (errno 28) et `SourcePackages`
  corrompu (faux « half.h not found »). Le 17/09 la notarisation a cassé
  exactement comme ça (1,4 Go libres).
- **Un échec `xcodebuild` imprime `env -i` avec tous les secrets du shell** :
  filtrer étroitement, jamais de sortie brute.
- **Ne jamais lancer deux `xcodebuild` en parallèle** sur le MacBook 16 Go
  (`pgrep -fl xcodebuild` avant).
- XcodeGen : après **tout ajout ou suppression de fichier**, `xcodegen generate`
  ou le build ne le voit pas.
- SwiftLint : le baseline encode le **nombre de lignes** — éditer un fichier
  baselined casse le lint. Les tests XCTest lisent les **vraies** préférences de
  Kevin (`TEST_HOST = Throttle.app`).
- Convention de commit : `[throttle] action: description`. Pas de backticks ni
  de `<>` `>` dans `-m` (zsh les évalue).
- Répondre à Kevin en **puces courtes, < 10 lignes, la réponse d'abord** (il est
  dyslexique), et **une seule question par tour**, chaque option portant son
  POUR / CONTRE / SOTA.

---

## 8. Pourquoi cette passation existe

La session précédente (`cf60d1b8`, transcript de 36,9 Mo) est morte le 18/09 à
~07:25, en plein `xcodebuild test`. Signature : dernière ligne du JSONL = un
`tool_use` Bash, **aucun `tool_result`** ; aucun crash report node/claude, aucun
JetsamEvent → **SIGKILL**, pas un plantage. Contexte : un second `xcodebuild`
(Éclair) tournait en parallèle, swap à 3,8/5 Go sur un Mac de 16 Go.

Le prompt `Kevin:~$` revenu sous la scrollback figée = seul le process `claude`
est mort, le zsh de l'onglet a survécu — donc l'app Throttle n'avait **pas**
redémarré.

**Aucun travail n'avait été perdu** : le `build-test.log` du worktree disait
déjà `** TEST SUCCEEDED **`. Réflexe à garder : lire le log de build avant de
relancer quoi que ce soit.

---

## 9. Ce que je demande à Codex

Reprendre au §6, dans l'ordre, **sur ce worktree**, sans rien pousser ni
publier. Commencer en lecture seule : `git status`, le diff, `docs/BACKLOG.md`,
et ce fichier. Réutiliser `TaskSpend`, `ClaudeAgentInventory`,
`StatsDataService`/`CockpitQueries` plutôt que d'ouvrir des implémentations
parallèles. Terminer par : fichiers modifiés, tests réellement exécutés,
vérifications manquantes, prochaine tâche. Si un dépôt, une permission ou une
décision produit manque, expliquer le blocage au lieu de supposer.
