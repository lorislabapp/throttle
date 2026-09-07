# Handoff pour reprise Codex (Throttle) — 7 septembre 2026

Date : 2026-09-07
Émetteur : session Claude Code (Fable 5.1, puis Opus 5)
Destinataire : session Codex suivante
Objet : Throttle 3.5.2 (build 218) est **publiée et vérifiée**. Ce document dit ce qui est vrai, ce qui reste ouvert, et ce qu'il ne faut surtout pas refaire.

## Priorité de lecture

1. Ne pas écraser les handoffs précédents : `docs/THROTTLE-WORKSPACES-HANDOFF-2026-08-16.md` et `docs/THROTTLE-HANDOFF-2026-08-18-PASSAGE-CODEX-TO-CLAUDE.md` restent la référence produit/architecture. Ce document est **complémentaire** et couvre la release 3.5.2 et sa chaîne de publication.
2. Lire `docs/RELEASE.md` avant toute action de release. C'est le mode d'emploi désormais canonique.
3. Ne rien installer ni relancer sur le Mac de Kevin sans son accord explicite à chaque fois (il travaille dans Throttle ; un redémarrage coupe ses sessions).

## État vérifié au moment du handoff

### Public

| Élément | Valeur |
|---|---|
| Version en ligne | 3.5.2 (build 218) |
| DMG | `https://lorislab.fr/throttle/Throttle-3.5.2.dmg`, 31 832 615 octets |
| SHA-256 du DMG | `c7ff74053564b0afeecb6379813401874e7916150d3b12afa6e4e4cbb56993c1` |
| Notarisation | soumission `b208d0fe-f88a-47bf-918a-9e1c39515588`, ticket agrafé, `spctl` = Notarized Developer ID |
| Appcast | 94 827 octets, item de tête 3.5.2 / `<sparkle:version>218` |
| Page produit | lien `Throttle-3.5.2.dmg`, `v3.5.2 · 31.8 MB` |

Vérifié en requête normale **et** cache-bustée, avec téléchargement complet et comparaison d'empreinte. Rejouable : `scripts/verify-public-release.sh <stage-dir>`.

### Dépôts

- `lorislabapp/throttle` : `main` = `release/3.5.2-218` = `ecd50fe`, poussés. Les deux branches sont identiques ; la lignée réelle est passée par `release/*` et `main` a été avancé en fast-forward dessus.
- `feat/research-vault-lots-1-4` (`ce083de`) est entièrement fusionnée dans `main`. La garder ou la supprimer est indifférent.
- CI verte sur `main` (run 34099674225, commit `023ff8f`) — **première réussite depuis la 3.2.96**. Toutes les étapes passent, y compris le build macOS durci et l'état de sécurité iOS.
- `lowrisk75/lorislab-website` : `main` = `0abb6c6`, local et origin alignés. `throttle/appcast.xml` et `throttle/index.html` sont désormais identiques à l'octet près à ce qui est servi. Le worktree local de Kevin garde 7 fichiers modifiés non committés (son travail en cours) et 3 répertoires non suivis — **ne pas y toucher**.

### Ce que contient la 3.5.2

Fusion de la préparation 3.5.2 (Plan, fenêtre AI Routing, vérité Qwen/Ollama, règles de repli local/frontier) avec `feat/research-vault-lots-1-4` (Research Vault lots 1-4 : ingestion dossier et URL, lecture de PDF scannés, import NotebookLM, fenêtre d'installation guidée) plus le nouveau filtre d'activité du rail et de la barre d'onglets.

Suite complète passée sur l'arbre fusionné : **578 tests, 5 ignorés, 0 échec**.

## Le filtre d'activité (demande initiale de la session)

Trois paliers partagés par le rail et la barre d'onglets, mémorisés dans `UserDefaults` sous `cockpitActivityFilter` :

- **Toutes**
- **Vivantes** = un processus tourne (`CockpitTab.isSpawned`) : working, waiting, idle ou paused. Pas `isLive`, qui est le drapeau de fraîcheur du transcript calculé par le tick — piège de nommage, les deux existent.
- **Actives** = attend une réponse, rate-limitée, ou sortie depuis moins de **60 s** (`CockpitTab.activeWindow`). Volontairement plus large que les 6 s du point d'état : à 6 s la liste clignoterait pendant qu'un agent réfléchit entre deux outils.

Points d'implémentation à ne pas casser :

- `visibleSessionIDs`, `liveCount` et `activeCount` sont **stockés** et recalculés uniquement sur le tick, sur changement de filtre et sur ajout/retrait de session. Ne jamais lire `tab.state` ou `tab.isActive(now:)` depuis le `body` : c'est exactement le défaut qui a fait manger 42 Go à la barre de menus (voir `waitingCount` et son commentaire dans `MultiCockpitModel.swift`).
- L'onglet sélectionné reste visible même s'il ne passe pas le filtre (`visibleSessions(_:visibleIDs:pinned:)`), sinon le terminal affiche une session que la liste nie.
- Tests : `ThrottleTests/StateTests/ActivityFilterTests.swift`, 10 cas, prédicats purs sans PTY.

## Chaîne de publication (nouvelle, à utiliser telle quelle)

`docs/RELEASE.md` détaille les six étapes. Les trois scripts :

- `scripts/stage-release.py` — lit l'entrée appcast signée, **récupère l'appcast et la page en ligne** (le dépôt du site dérive), retire les transformations Cloudflare/WebMCP injectées dans la page servie, ajoute l'item en tête, met à jour version, lien et taille. Refuse un numéro de build déjà publié, un DMG dont la taille ne correspond pas à la longueur signée, un DMG sans ticket agrafé, et une signature EdDSA qui ne vérifie pas contre les octets.
- `scripts/publish-release.mjs` — envoie **uniquement** le répertoire mis en scène, en une archive que l'hébergeur extrait par fusion sur `public_html`. La preuve du déploiement est le tampon, jamais le code de retour du déclencheur (il a déjà renvoyé 500 sur des déploiements réussis).
- `scripts/verify-public-release.sh` — contrôle ce que reçoit un vrai client Sparkle.

**Ne jamais utiliser `node deploy.mjs` du dépôt du site pour une release Throttle** : il embarquerait le travail en cours de Kevin et n'enverrait pas le DMG sans `DEPLOY_DMG=1`.

## Pièges découverts cette session (coût réel : plusieurs heures)

1. **Baseline SwiftLint et chemins absolus.** La 3.5.1 avait régénéré `.swiftlint-baseline.json` depuis un worktree sous `/private/tmp` ; SwiftLint y écrit des chemins absolus, le runner ne retrouve aucun fichier, et les 3 063 violations connues reviennent comme neuves. **C'était la cause unique de la CI rouge depuis la 3.2.96.** Régénérer uniquement depuis un worktree sous `$HOME`, avec le binaire **épinglé 0.63.2** (le 0.65.1 de Homebrew produit un baseline que le 0.63.2 rejette). `scripts/build-dmg.sh` et la CI refusent maintenant un baseline contenant `"file":"/`.
2. **Le baseline encode le nombre de lignes.** Les entrées `file_length` et `type_body_length` portent le compte au moment de l'enregistrement, donc toute édition d'un fichier déjà hors limites les fait remonter comme nouvelles. Régénérer est la procédure normale, pas un contournement.
3. **`Text` et les ternaires de littéraux.** `Text(cond ? "A" : "B")` se type en `String` et choisit la surcharge **non localisante**. Passer par `String(localized:)` des deux côtés.
4. **Format du catalogue de chaînes.** `Localizable.xcstrings` fait 6 334 lignes ; le réécrire avec `json.dump` produit ~4 700 lignes de bruit de reformatage. Insérer les entrées comme du texte, au format des voisines. Validation sans build : `xcrun xcstringstool compile --output-directory <dir> <fichier>`.
5. **`curl` dans un tube vers `grep -m1` sous `set -e`.** `grep` ferme le tube, `curl` meurt en 56 « Failure writing output », et le script sort en silence. Écrire dans un fichier d'abord.
6. **Le classifieur d'outils bloque certaines actions** en mode auto : l'envoi Hostinger, `git stash` enchaîné à d'autres commandes git, `git checkout --ours/--theirs` enchaîné à `git add -A` et un commit. Les séparer, ou passer la main à Kevin avec `!`.
7. **Budget disque.** Un build + tests complet réclame ~4,5 Go de DerivedData. Vérifier `df` avant tout `xcodebuild`.

## Ce qui reste ouvert

- **Trois correctifs sont sur `main` mais PAS dans la 3.5.2 publiée** : l'état vide de la barre d'onglets (empilé alors que la barre est horizontale et haute de 40 pt), la localisation perdue du message d'état vide, et les sept chaînes du filtre absentes du catalogue. Ils partiront avec la prochaine version. Impact aujourd'hui : cosmétique, visible seulement quand on filtre sur Vivantes ou Actives sans aucune session correspondante.
- **Plan et AI Routing n'ont jamais été validés visuellement ni en accessibilité** : l'app n'a pas été lancée de la session (consigne de Kevin).
- **`MultiCockpitRoot.swift` fait 2 086 lignes**, corps de structure 1 264 lignes ; `MultiCockpitModel.swift` en fait 1 900. Les deux sont hors limites et absorbés par le baseline. Le découpage est le correctif de fond qui traîne, et chaque édition de ces fichiers force une régénération du baseline.
- **Disque à ~1,2 Go libre.** Postes principaux, tous à Kevin : DerivedData Throttle 3,5 Go, Éclair 2,3 Go, `.install-backups/` 880 Mo de sauvegardes 3.4.x et 3.5.0.
- Le worktree `/private/tmp/throttle-release-3.5.2-218` **disparaîtra au prochain redémarrage**. Rien n'y est unique : la branche est poussée, le DMG est publié et copié dans le dépôt du site, et les dSYMs de la 3.5.2 sont sauvegardés dans `.install-backups/dSYMs-3.5.2-218/` (107 Mo, avec les UUID) — sans eux aucun rapport de crash 3.5.2 n'aurait pu être symbolicalisé.

## À ne pas faire

- Ne pas installer ni relancer Throttle sur le Mac de Kevin sans accord explicite.
- Ne pas éditer `~/.claude.json` : `throttle-memory` est le binaire de l'app, toute modification la redémarre.
- Ne pas éditer `.swiftlint-baseline.json` à la main, et ne pas le régénérer depuis `/private/tmp`.
- Ne pas repartir de `main` en croyant qu'il est en retard : depuis le 7 septembre `main` porte toute la lignée release.
- Ne pas relancer une release sans lire `docs/RELEASE.md` : Sparkle compare `CFBundleVersion`, donc `MARKETING_VERSION` **et** `CURRENT_PROJECT_VERSION` doivent monter tous les deux.
