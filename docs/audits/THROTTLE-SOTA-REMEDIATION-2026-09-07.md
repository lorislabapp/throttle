# APPLE AUDIT REMEDIATION LOG

## OUTCOME

PARTIAL — PRODUCT BLOCKED

Boucle active, non publiée. Checkpoint lot 17 : 2026-09-08, après 12:03 UTC. Trois constats initiaux corrigés localement, cinq constats initiaux et trois constats complémentaires encore ouverts ; G0–G9 restent à fermer.

## 1. DRIFT RECONCILIATION

Audit source : `THROTTLE-INITIAL-AUDIT-2026-09-07.md`, END 17:58:41 UTC, HEAD cc40cfb, diff e8420694939ae36e4d8ada0b12a4ff27fa677b4c0d6671e445c4bd2d6462102e. Branche de travail `fix/cockpit-state-observation` dans `build/cockpit-maintenance`. Ancienne branche de l'entrée principale, sauvegardes et worktree release préservés. Les changements de point d'état/baseline sont préexistants à ce nouvel audit ; aucun commit ou push dans cette phase.

## 2. RESEARCH AND NOTEBOOKLM RECONCILIATION

Recherche : `../research/2026-09-07-throttle-sota-evidence.md`. DeepSearsh consulté comme pistes historiques, sources primaires revalidées. Trois axes fixés : continuité native, Vault multi-projets, vérification bornée. NotebookLM : N/A, aucun paquet autorisé à l'upload. Sparkle 2.9.6 est maintenant épinglé, résolu et compilé en Debug. La qualification Release et la mise à jour isolée restent ouvertes ; l’attaque root décrite par le fournisseur n’est pas extrapolée à l’app ordinaire.

## 3. SOTA GATE PLAN

| Gate | Statut | Preuve / fermeture |
|---|---|---|
| G0 | PARTIAL | Sources et reprise réconciliées ; disque fluctuant de 0 à 14 Gio avec autres builds actifs, capacité release à sécuriser |
| G1 | PARTIAL | Audit frais et paquet de recherche écrits ; recherche et arbitrages fixés, mesures produit encore ouvertes |
| G2 | FAIL | F-001, F-002, F-004, F-009, F-010 et F-011 ouverts |
| G3 | PARTIAL | Critères fixés ; noyau du transfert/reprise qualifié avec fixtures Linux, parcours natifs complets et mesures des trois axes encore ouverts |
| G4 | PARTIAL | F-005 corrigé localement ; lint strict PASS après découpage, F-007 fermé après contre-revue ; mesures d’invalidation encore ouvertes |
| G5 | PARTIAL | Deux previews Vault FR/AX corrigées ; troncatures levées en recapture Release END11:13:42 ; clavier/VoiceOver et parcours fonctionnels ouverts |
| G6 | PARTIAL | Lot15 : 608 tests app PASS/5 ignorés, lint0.63.2 PASS ; Vault Debug/Release144 PASS, Shared52 PASS, Node32 PASS. Lot17 : archive universelle Developer ID et DMG signé PASS, exit0 ; CI fraîche ouverte |
| G7 | PARTIAL | Candidat3bb05c8d :32NodePASS/Linux et3scénarios synthétiquesPASS, quatre scopes nettoyés, revue END09:44:58 ; CLI natives/HTTP/Mac réel ouverts |
| G8 | NOT RUN | Candidat exact à préparer ; accords externes puis vérification publique |
| G9 | NOT RUN | Contre-audit FINAL indépendant uniquement après G0–G8 PASS |

## 4. REMEDIATION MATRIX

| ID | État | Lot / acceptation |
|---|---|---|
| F-001 | OPEN | Correctif implémenté, réserves statiques levées ; 29 tests ciblés PASS après reconstruction ; parcours CLI réel ouvert |
| F-002 | OPEN | Backend 5 tests PASS ; intégration et récupération 13 tests PASS, réserves statiques locales levées ; dernières gardes et UI runtime à requalifier |
| F-003 | FIXED | Auto-réponse et préférence retirées, UI manuelle FR/EN ; handlePrompt testé ; qualification visuelle G5 ouverte |
| F-004 | OPEN | Admission owner persistée, tiers fixes ; 18 tests admission/recherche/backup PASS et réserve backup v6 levée ; XPC installé et benchmark ouverts |
| F-005 | FIXED | Buffer 64 KiB pendant drainage ; troncature aussi à 4 000 caractères ; 64 MiB injectés, UTF-8 et queue finale testés |
| F-006 | OPEN | Vision e5rt code13 sur image nette ; retry CPU compatible par document, 3 tests extraction PASS ; performance et erreurs UI à qualifier |
| F-007 | FIXED | Découpage et lint0 sans exemption nouvelle ; contre-revue lot9 END08:10:38 UTC |
| F-008 | OPEN | Vérificateur octets normal/cache-bust corrigé, 3 tests HTTP PASS ; public/Sparkle/T+15 ouverts |
| F-009 | OPEN | Aller/retour v2 API/UX raccordés ; conflit local conservé, capture serveur scellée, aliases et publication transcript corrigés. Qualification Linux/CLI/UI, récupération sans metadata et sessions legacy fraîches restent ouvertes |
| F-011 | OPEN | Recherche receipts/documents raccordée, provenance/ordinal exacts ; tests PASS. P2 contre-revue taille IPC corrigé, fixture grosses sources PASS ; benchmark et IPC réel ouverts |
| F-010 | OPEN | Sparkle2.9.6 résolu et Debug compilé ; seul pin modifié, Release/signature/update isolée restent à qualifier |

## 5. CHANGE LOG BY BATCH

- Préexistant : point d'état isolé de la racine, deux tests d'observation, baseline SwiftLint 0.63.2 régénérée (3063 → 3061), handover de reprise.
- Lot 0 : audit initial read-only, revue indépendante initiale, recherche, tests et checkpoints. Cache Vault supprimé après conservation des logs ; cache intermédiaire Éclair inactif supprimé après autorisation système explicite. Aucune source de cet autre projet modifiée.
- Lot 1 : suppression de l'autorité des prompts PTY et du service de policy désormais inutile ; demandes toujours manuelles. Collector Plan borné à 64 KiB et texte final à 4 000 caractères, marqueur explicite de troncature. La contre-revue initiale du lot a fait corriger le cas intermédiaire 4 000–64 KiB et supprimer des tests redondants. Sept tests ciblés passent après reconstruction et ajustements (`throttle-sota-lot1-final-tests.log`, exit 0). Lint global encore FAIL sur tailles des fichiers touchés/baseline décalée : G4 ouvert. Une exemption locale documentée autorise uniquement la réparation UTF-8 du flux subprocess, couverte par test ; aucune nouvelle entrée baseline.
- Lot 2 en cours : `CockpitTab` et son lancement extraits du modèle ; plus de sélection newest-cwd pour lancement, hibernation, statistiques, handoff ou offload. Claude reçoit un UUID neuf via `--session-id` (aide CLI installée vérifiée). Découverte Codex/picker par FD writable du runtime de premier plan, identité kernel racine gardée depuis spawn, outils/subagents exclus, ambiguïté refusée. Réserves indépendantes levées statiquement dans `throttle-independent-lot2-delta-20260907.md`. Première passe 18 tests/1 échec, seconde 29/1 échec ; diagnostic prouve une comparaison de chemins `/var` et `/private/var`, pas un échec kernel ni de flags. Normalisation symétrique ajoutée : 29 tests/0 échec dans `throttle-sota-lot2-recovery-tests.log`, exit 0. Le rerun précédent avait échoué INFRA en résolution de packages (disque 298 Mio), avant les tests. Aucun PASS runtime natif encore revendiqué.
- Lot 3 F-002 : capture bornée PID/UID/start et PGID avant signaux, TERM/CONT puis KILL des groupes ancrés et identités conservées ; attend membres et groupes disparus. Dérive PGID observée sticky => refus de reprise. Le banc a détecté un vrai défaut de conversion : `proc_listchildpids` renvoie un compte, pas des octets (source Apple XNU vérifiée). Fix et assertion >=2 membres : 5 XCTest PASS dans `throttle-process-scope-corrected-tests.log`. La fixture avait retenu le pipe de SwiftPM après son échec ; son seul groupe synthétique a été identifié puis nettoyé par action autorisée, stdio et descripteurs désormais isolés.
- Lot 3 intégration locale : hibernate/restart/continueMission/close/quit/autoHibernate attendent le résultat ; shells principal et latéral inclus, identité enregistrée après spawn ; terminaux conservés et saisie suspendue en attente, échec visible et remplacement refusé. Quit utilise terminateLater/reply. Transfert sortant arrête localement avant réseau et bloque wake pendant transfert. Première compilation FAIL sur consolidateDuplicates encore synchrone, adapté ; reconstruction 13 tests PASS. Les courses Quit et détection périmée ont été corrigées après contre-revue, puis reconstruction 13 tests PASS (`throttle-sota-lot3-recovery-tests.log`). Réserves récupération fond/texte/identité latérale levées statiquement dans `throttle-independent-lot3-recovery-final-20260907.md`. Dernières gardes persist/remote et sélection erreur post-tests : validation runtime ouverte. Aucun PASS UI revendiqué. Ancien killSubtree supprimé. Le cas PGID simulé exige désormais le motif de dérive, pas n'importe quel échec ; test réel de dérive durant grace encore ouvert.
- F-009 découvert en lecture du transfert retour : `RemoteSessionsService.bringBack` télécharge avant stop et écrit toujours côté Claude ; l'edge utilise newest-cwd pour usage/transcript, et un `kill-session` best-effort sans reçu de fin de processus. Les transferts réseau indéterminés doivent aussi bloquer un wake local jusqu'à réconciliation. À corriger dans l'axe continuité, pas une quatrième évolution majeure.

- Lot 4 en cours F-004 : admission explicite via endpoint owner signé, registre de projets dans SQLCipher (migration additive v7), grant Throttle étendu uniquement par cette opération. CheatCode et tout gateway de query ordinaire restent fixes ; les métadonnées de receipts ne donnent aucun droit. Le formulaire/import de fichiers et les dossiers approuvés déclenchent l'admission du projet choisi ; les receipts importés ne peuvent pas élargir seuls leur grant. Risques : migration/reprise et atomicité d'admission concurrente ; validation sur bases temporaires, rejet hors-grant, isolement tiers et redémarrage. Rollback source avant publication ; aucune base utilisateur ne sera migrée par ces tests.

- Lot 8 F-001 : `drainThenPause` consulte le transcript exact du runtime et de l’identité liés à l’onglet. Capture de génération et revalidation après suspension ; suppression de `newestSession`. Le calme de mtime reste décrit comme une heuristique, sans preuve de quiescence réseau. Aucun changement de la fenêtre d’activité de 60 secondes.
- Lot 8 F-009, socle local : journal par transfert, hash intégral en mémoire bornée, phases monotones, sauvegarde atomique et fsync des fichiers/répertoires ; erreur de lecture propagée. Sauvegarde de l’identifiant distant dans les onglets et garde sur toutes les entrées de lancement. Cinq tests du journal passent. À ce checkpoint historique du 7 septembre, ce journal n’était pas encore écrit par le parcours offload ; raccordement réalisé au delta du 8 septembre ci-dessous.
- Lot 8 F-009, socle serveur : module `edge-agent/transfer-runtime.mjs`, identités native/transfert/serveur, réservation exclusive, uploads vérifiés sans écrasement, tombstone indépendant du statut mutable. Unité systemd par transfert, helper et tmux dédiés dans son cgroup ; refus du helper tombstoné ou hors cgroup. Démarrage borné à 120 secondes et arrêt à 5 secondes ; vérification d’état et cgroup avant reçu. À ce checkpoint historique, aucun handler HTTP ne l’appelait encore. Le raccordement du 8 septembre reste local, sans déploiement.
- Contre-revue lot 8 END 21:22 UTC : erreurs corrigées de journal incohérent, faux reçu, tombstone seul et `cd` échoué ; huit tests produit + trois probes indépendants et une démonstration de grammaire historique passent. Deux réserves restaient à ce snapshot : copie native directe et Git préparatoire hors unité. Le delta suivant publie le transcript par staging/hash/fsync/link exclusif et déplace clone/checkout dans le helper de l’unité. Ce delta a 14 tests Node PASS, dont quatre courses déterministes d’arrêt ; aucune assimilation à une preuve de noyau Linux.
- Validation lot 8 : 19 tests Mac PASS (native 7, terminaison 5, journal 5, observation 2), après réparation de trois références de test altérées par un renommage au lot 7. Importeur manuel Vault : 4 tests SwiftTesting, dont 3 cas paramétrés, PASS après extraction du mapping d’erreur OCR. Le premier essai de chaque outil Swift était INFRA BLOCKED par les caches sandbox ; relance hors sandbox PASS. Lint frais : 54 diagnostics non couverts, G4 FAIL ; baseline non élargi. Disque 7,9 Gio au dernier sondage.

- Lot 8, 8 septembre : aller v2 raccordé au Cockpit et à la sheet. Réservation MainActor avant le premier await, journal fsync avant prepare, endpoint/identité serveur/UUID/input vérifiés ; hibernate avant capture. Git utilise un index privé et une référence par UUID, conserve branche/index/staged/unstaged/untracked/suppressions et fichiers explicitement inclus. Sous-dossier Git refusé avant artefacts. Version SOURCE edge 2.0.0, module ESM inclus dans le bundle via import data URL ; déploiement en stdin, sans limite argv induite par sa taille. Aucune installation ni version macOS changée.
- Contre-revue départ END 06:28 UTC : réservation pré-journal, stop-before-prepare et cwd racine levés ; P1 picker natif identifié. Correctif : commande throwing préparée avant PTY/envoi ; refus picker tant qu’un transfert du runtime reste pending ou que le journal est illisible, refus d’un picker déjà ouvert au départ. 24 tests app +4 Shared PASS ; contre-revue picker END 06:40 UTC sans nouveau P0/P1. Anciens tests natifs ensuite isolés du journal utilisateur par injection d’un journal temporaire.
- Retour v2 : arrêt original confirmé avant capture. Unité séparée throttle-return/UUID contenant Git, index privé, bundle/ref de retour et transcript exact ; draft fsync, sceau monotone empêchant une capture retardée, arrêt du worker avant validation des fichiers et phase frozen. Téléchargements limités à 128 MiB chacun, buffer client 64 KiB, longueur et SHA-256 complets. Copie figée réutilisée après retry ; nouvelle revendication native refusée jusqu’à un accusé de réception lié aux deux hashes, validé dans le schéma du journal serveur.
- Retour Mac : import sous refs/throttle/transfers/UUID/return ; arbre/transcript locaux doivent être le baseline du départ ou le résultat déjà installé. Divergence préexistante conserve les deux copies et interdit wake. Application du delta Git en conservant HEAD et l’index utilisateur ; sauvegarde du baseline et copies téléchargées conservées. Le transcript est publié par échange atomique RENAME_SWAP, son inode réellement déplacé est conservé et référencé par une intention persistée ; divergence pendant publication restaure l’inode local et conserve aussi la copie déplacée. Réservation portée jusqu’à libération+wake synchrones, gardes communes empêchant les aliases de reprendre un writer local actif. Le picker natif est également refusé lorsqu’un autre onglet du runtime est actif.
- Contre-revue retour END 07:01 UTC : quatre réserves levées statiquement (inode transcript, réservation jusque wake, sceau capture, schéma returned/ack). P2 restant : manifeste local écrit directement pouvant laisser un JSON partiel. Delta post-END : staging fsync + lien exclusif + fsync parent pour manifeste et intentions de déplacement ; test de staging interrompu et refus d’écrasement ajouté, validation ciblée5 tests retour PASS ; contre-contrôle metadata END07:14 UTC, P2 levé.
- Validation retour : 16 puis18 tests Node PASS (Git réel, backend systemd simulé), 27 puis29 tests app PASS (dont FD concurrent et réservation après journal returned), 6 tests Shared PASS (download complet, tronqué, trop grand et corruption de même longueur). Le delta metadata postérieur aux29 tests a son propre run ciblé5 tests PASS, TEST SUCCEEDED. Aucun résultat Node simulé n’est une preuve Linux. Lint frais avant le dernier helper :116 diagnostics non couverts, baseline non élargie, G4 FAIL. Disque9,5 Gio au dernier sondage.
- Limite concrète : les processus pilotés par Cockpit sont arrêtés et réservés. Un éditeur/Git/CLI externe écrivant simultanément dans le dépôt n’est pas exclu par Throttle ; arrêter ces writers avant transfert/retour. La conservation atomique du transcript protège l’inode déplacé, mais git apply ne constitue pas une transaction multi-fichiers contre des éditeurs externes. Legacy repos/start refusent les espaces de transfert réservés, y compris via alias symbolique. Les actions MCP v2 sont dirigées vers le même stop/signal contrôlé.

- Lot 9 : MultiCockpitModel (117 membres), SQLCipherReceiptStore (30 membres), CockpitTab, EdgeAgentService et AppDelegate répartis par responsabilités ; DTO IPC/XPC/Notebook déplacés entiers. Propriétés stockées et ordre conservés, helpers transversaux internes au module. La première compilation SQL a révélé un helper Collection resté privé au fichier : défaut corrigé, première preuve FAIL conservée. Contre-revue indépendante des extractions modèle/SQL END07:34:35 sans défaut restant dans ce périmètre ; deltas suivants soumis à nouvelle revue.
- Lot 9 : statistiques Cockpit fondées sur des snapshots typés incluant identité native et génération du processus. Un résultat périmé ne peut plus écraser l’onglet courant ; test de changement d’identité/génération ajouté et PASS. Observation et modèles de coût Claude/Codex conservés. Corps du transfert, retour, insertion SQL et startup Vault découpés en étapes explicites, sans élargir les droits clients. Chaînes UI/SQL/MCP repliées avec continuations ; preuves de contenu et correspondances conservées.
- Lot 9 validation locale : lint strict 0.63.2 sans cache PASS, zéro diagnostic, baseline 2983→2950 (deux file_length retirées par extractions, puis 31 exemptions retirées ; uniquement déplacements bijectifs des exemptions restantes). `git diff --check` PASS. App Debug complet : 603 XCTest dont 5 ignorés et zéro échec, plus 3 Swift Testing PASS, `TEST SUCCEEDED`, exit0, fin08:01 UTC. Vault Debug complet :42 XCTest +102 Swift Testing PASS, exit0 ; Shared complet48 XCTest PASS, exit0. Les premières tentatives sandbox échouaient sur les caches Swift ; les relances hors sandbox sont celles qui portent ces résultats. Les avertissements de priorité Xcode ne sont pas une mesure runtime produit. Un dernier repli de ligne/commentaires de railHoverActions est postérieur à la compilation complète ; aucun changement de logique. Release Vault144 PASS (42 XCTest +102 Swift Testing), exit0 ; OCR de la suite Release a duré68,8s sur le SDK beta, sans qualification de performance. Qualification réelle et publication ouvertes.

- Lot 9 serveur, lecture seule : endpoint configuré en1.0.0, CT134 identifié via connexion Proxmox existante ; systemd252/cgroupv2/tmux3.3a et5,5 Gio disponibles. Node18.20.4 upstream EOL selon tableau officiel ; backports Debian encore non vérifiés. Runtime maintenu à qualifier avec le candidat edge. Aucun déploiement, installation ou changement SSH. Détail et source dans le paquet de recherche.

## 6. FINAL VALIDATION LEDGER

Les résultats suivants sont initiaux et ne valent pas validation finale des prochains changements : macOS test-without-building 580/5 skipped/0 failure ; ThrottleShared 42 PASS ; edge-agent PASS ; frontière dépendance Vault PASS ; pipeline Vault PARTIAL avec OCR FAIL. Gitleaks quatre faux positifs triés. Fresh Release, UI, signatures et publication NOT RUN. Contre-revue initiale indépendante NO-GO ; aucun GO final.

## 7. CLAIM, PRIVACY AND RELEASE RECONCILIATION

Ne pas promettre reprise fiable, écriture unique ou auto-approbation sûre avant correction et qualification. Pas d'upload de corpus, pas de changement de prix/canal/privacy. Site via chaîne ciblée canonique uniquement, sept fichiers Kevin préservés. DMG normal et cache-bust téléchargés intégralement et comparés au manifeste ; contrôle T+15 min et mise à jour Sparkle isolée nécessaires.

## 8. OPEN GATES AND APPROVALS

Installation/redémarrage de l'app de travail non autorisés implicitement. Préparer candidat, notes, signatures et manifeste avant accords exacts de notarisation/publication. Le journal reste PARTIAL tant qu'un contrôle runtime, build ou accord requis manque. Aucun statut d'attente ne clôt la boucle. Les autorisations du plan couvrent corrections locales réversibles et leurs tests.

## 9. EVIDENCE INDEX

- Plan : `../THROTTLE-SOTA-LOOP-2026-09-07.md`.
- Audit : `THROTTLE-INITIAL-AUDIT-2026-09-07.md`.
- Recherche : `../research/2026-09-07-throttle-sota-evidence.md`.
- Preuves initiales et contre-revue : `../../audit-output/sota-20260907/initial/`.
- Résultat ciblé antérieur : `../../audit-output/cockpit-maintenance-20260907/FocusedTests.xcresult`.

- Lot 4 : 18 tests ciblés admission/recherche/provenance/backup PASS (`lot4/throttle-sota-vault-lot4-qualified-tests.log`). L'échec de comparaison de Date haute précision était dans la fixture ; timestamp milliseconde exact retenu. Migration v6 sur copie : original byte-identique, approved/quarantined conservés. Réserve indépendante backup levée. Classement alterné déterministe, aucune amélioration de Recall annoncée sans benchmark. Contre-revue trouve un P2 IPC : sources longues dupliquées dans origins/provenance, hors budget caractères. Encodeur wire commun + omission d'items entiers avec truncated, provenance retenue intacte ; fixture corrigée à <16KiB par locator, test PASS dans lot6.
- Lot 5 : vérificateur public télécharge DMG normal et cache-bust, vérifie chaque taille/SHA256 ; appcasts byte-identiques et liens des deux pages. Trois tests HTTP synthétiques PASS après autorisation bind loopback : succès, DMG cache-bust corrompu de même taille, appcast normal divergent. Ajout CI. Aucun nouveau fetch public ni publication.
- Lot 6 F-006 : reproduction réelle Vision échoue `TextRecognition.CRImageReaderError.e5rtError(..., 13)` ; PNG synthétique inspecté, texte net et droit. Le même moteur révision3 sur CPU déclaré compatible reconnaît toute la phrase. Correctif : une tentative CPU après erreur automatique, politique conservée seulement pour les pages du même document ; absence de texte n'entraîne pas de retry. Échec moteur propagé et distinct d'un PDF illisible, imports refusent alors un document partiellement lu. Sept tests extraction/recherche/budget IPC PASS en60,3s, exit0 ; lenteur OCR beta à mesurer G4/G7. Propagation importeurs et texte FR/EN ajoutés après ce run, full-suite suivante nécessaire.
- Preuves lots4–6 et contre-revues copiées sous `../../audit-output/sota-20260907/`. Aucun changement de base utilisateur, installation, version, upload ni publication.

- Lot 6 qualification complète : premier full Debug102SwiftTesting PASS mais42XCTest/1FAIL. La fixture de downgradev3 laissait les objets de v7, donc elle ne représentait pas une basev3. DROP des deux objets nouveaux ajouté au banc ; rerun42XCTest+102SwiftTesting PASS, exit0 (`lot6/throttle-sota-vault-lot6-full-debug-final-tests.log`). OCR chaud1,03s, premier essai froid60,3s : timings distincts, pas un benchmark de performance.
- Lot 7 dépendance : Sparkle pin exact2.9.1→2.9.6, révisionac2def288cbff5cfc7df3ffef6abdf45b72bcb0a. Résolution puis comparaison JSON : aucune autre dépendance modifiée. Xcodegen et reconstruction macOS réussissent,19tests ciblés PASS ; bundleDebug inclut nouveau framework, aucune signature/publication Release encore validée.
- Lot 7 fichiers : Root cockpit9fichiers≤246lignes ; Workbench16fichiers≤274lignes, exemptionsfile_length/type_body_length retirées. Dropdown3340lignes réparti entre meter/navigation/composants et panes ; General.body conserve exactement l'ordre des rangées via5builders. Première compilation échoue sur helperdescribe privé devenu inter-fichiers ; formateur nommé partagé corrigé et buildPASS. Contre-revue trouve2chaînes ayant perdu le motprivate par regex trop large : toutes deux restaurées byte-identiques hors indentation depuis snapshot. Comparaison des329blocs en cours, UI visuelle NOTRUN.
- Lot 7 lint : baseline3061→2983 par remappage un-à-un des diagnostics historiques seulement ; preuvesavant/après et mapping conservés.27chaînes inchangées ont une indentation diminuée de4colonnes ; aucun diagnosticnouveau n'est ajouté. Cas d'une ligne passant du seuil200 au seuil120 en raccourcissant202→198 explicitement conservé comme dette historique.60diagnostics nouveaux/non couverts restent FAIL à ce checkpoint ; certains noms/alignment/longueslignes déjà corrigés après ce scan, prochainlint nécessaire. Ce résultat ne clôt pasG4.
- Lot 7 SQL : migration409lignes séparée en7étapes atomiques,48instructionsDDL/DML inchangées,versioncommitée avec chaque étape ; versionnégative rejetée.25XCTest SQLCipher+9SwiftTesting admission/recherche/backup PASS. Décomposition restante du stockage, modèlecockpit et IPC/lint ouverte.
- F009 contrat indépendant : UUID/transfertpersisté avant requête, startidempotent, tombstonedurable doit neutraliser aussi toutlauncher retardé ; unité/cgroups vides après arrêt, nativeUUIDexact et fichiersfigés aprèsstop, retouridempotent qui conserve les conflits. État historique avant lot8 : source v2 non implémentée. Le delta du8septembre ci-dessus remplace cet état de développement, pas le contrat du mémo. Mémo dans `lot7/throttle-independent-remote-contract-20260907.md`.
- Deltas post-build : Question.at→askedAt, noms de variables explicites, messages de récupération reformatés sans changement de texte, alignements ; requalification app encore à faire. Disque10Gio au dernierpoint, aucune suppression de cache tiers supplémentaire, installation ou mutation de service distant.

- Preuves lot 8 : `../../audit-output/sota-20260907/lot8/`, journaux app/importer/Node/lint et contre-revues avec snapshots. Rapports indépendants départ/picker/retour et logs du8septembre ajoutés. API et freeze sont raccordés localement ; qualification Linux et récupération complète restent ouvertes.


### Lot10 — reprise durable des créations et métadonnées (8 septembre, en cours)

- Lot9 contre-revue finale archivée : END08:10:38.787748Z, aucun nouveauP0/P1/P2 ; 200 déclarations,70 propriétés stockées,27 chaînes et handshakeMCP conservés,2950 exemptions historiquement justifiées. F007 fermé localement, G4/G5/G7 restent ouverts.
- Binding immuable publié avant le journal mutable ; perte du mutable récupérable uniquement après reçu d’arrêt, corruption n’empêche plus la tentative d’arrêt du cgroup.23 testsNodePASS dont Git réel ; contre-revue END08:20:14.311669Z sans nouveauP0/P1/P2. Perte totale/corruption des deux métadonnées reste récupération manuelle, aucun reçu inventé.
- Créations distantes fresh : journal et namespace propres, unité throttle-session/UUID et tmux privé, arrêts tombstonés ; aucune assimilation aux transferts d’une conversation locale. Premier lot28Node/48Shared/38AppPASS ; revue END08:35:40.671165Z a trouvé deuxP2 : requestID client perdu après réponse incertaine, commandes de banc ignorées par helper.
- Correctifs locaux de cesP2 : demande partagée Mac/iOS conservée sur disque avant réseau, requestID/serveur/endpoint/cwd/runtime/projet vérifiés au replay ; réponse bornée32KiB ; nouvelle demande refusée tant que l’ancienne reste incertaine. Retry observe l’unité originale sans StartUnit supplémentaire ; arrêt d’une demande exige reçu cgroup vide avant libération. UI de récupération Mac/iOS ajoutée. Commande trusted et cheminOAuth capturés dans journal privé ; helper lit ce descriptor, commandes personnalisées sans flags natifs ni identité Claude inventée. Descriptor exclu des réponses d’arrêt.
- Node31PASS et Shared50PASS, dont réponse perdue après acceptation puis client recréé, bindings modifiés refusés, mauvais serveur/reçu peuplé refusés, JSON partiel conservé. La fixture inerte exécute un script temporaire et vérifie argv sans aucune CLI native. Premier test de fixture FAIL car cwd absent, fixture corrigée ; échec retenu. Lint sandbox INFRA BLOCKED sur cache ; relance a trouvé trois diagnostics de forme en cours de correction. App ciblée et contre-revue indépendantes en cours : ne pas les déclarer PASS à ce checkpoint.
- Serveur vérifié en lecture seule via pve/CT134 : systemd252.39, cgroupv2, tmux3.3a, Node18.20.4, agent1.0.0 actif. Node18 upstream EOL, statut backportsDebian non évalué. Aucun accès direct SSH après refus de host-key, aucune confiance modifiée. Aucun déploiement/testLinux/CLI réel ; candidat et banc inerte à préparer. Disque local2.9Gi libres au dernier sondage, pas de suppression.


### Lot10 — validations locales suivantes et préparation Linux

- Contre-revue fresh delta END08:51:52.458278Z : les deuxP2 sont levés sur sources stables. Node31PASS, Shared50PASS ; app rebuild durable38PASS, TEST SUCCEEDED/exit0. Aucun nouveauP0/P1/P2 sur le périmètre revu.
- Récupération des journaux sans onglets : restore() lit aussi le journal quand la liste sauvegardée est absente/vide. Les transferts non rendus retrouvent un onglet dormant avec identité/cwd exacts, même si le dossier local est absent ; aucun processus/réseau/fichier produit lancé ou remplacé. Les conflits et journaux illisibles sont visibles. Deux nouveaux tests exercent le manque d’onglets et JSON partiel. Premier build FAIL après compilation, CodeSign dylib «internal error in Code Signing subsystem» ; relance unique identique TEST SUCCEEDED,29PASS/exit0. Aucun changement du trousseau.
- Contre-revue orphan/iOS END09:03:05.354939Z : aucun nouveau problème sur la restauration du journal. P2 iOS identifié car l’état fresh ne rapporte pas paused et cachait Resume ; correction donnant accès explicite à Pause et Resume pour remote/unverified, sans inventer un état observé. Addendum indépendant END09:11:27.165529Z : P2 levé. Compagnon iOS compile Debug simulateurarm64, BUILD SUCCEEDED/exit0, sans signature/install ; aucune validation physique/UI déduite. Lint final0, baseline2950 inchangé.
- BancLinux local `edge-agent/qualify-linux.mjs`, pas encore exécuté : fresh par vrai helper + commandes inertes Claude/Codex ; cgroup descendants, retry même invocation, stop sousSIGSTOP ; transfert synthétique, perte du mutable, arrêt puis freeze/retourGit. QualificationCLI native/HTTP complète reste hors de ce banc. Node24.20.0 officiel préparé en archive privée, aucune mise à niveau du service1.0.0/Node18.
- Première contre-revue du banc END09:11:27 a rejeté trois réserves avant exécution : cleanup sans tombstone/sceau, timerJS inopérant sousSIGSTOP, Git héritant du HOME/config hôte. Correctif du banc : markersdurables avant arrêt, timer systemd externe180s + registre/cancelled durable, Gitisolé dansdriver/helpers, étatT kernel requis, fetch explicite du refretour, rapport préservé malgré erreur d’observation/nettoyage. Contre-contrôle en cours ; syntaxe Node et shell/--plan seulement PASS. Ne pas déclarer LinuxPASS ni autoriser implicitement le redémarrage du service de travail.


### Premier banc Linux exécuté — 09:25 UTC

Archive f768c4a06e8690f718098f6fafeeb83cf3c5d8d1583490e159b0f4c9248d42a6 autorisée par tool escalation puis transférée sur CT134, hash distant confirmé. Node31testsPASS sur runtime privé24.20.0. Premier scénario fresh échoue avant writer : journalctl montre `File name too long` pour socket tmux sous le long répertoire de journal du banc. Scénarios réussis0 ; verdictFAIL. Root `/opt/throttle-qualification/run-5a7caf78-900b-4607-b571-b574086283cd`, cgroup du seul scope créé confirmé vide après cleanup, unités/timer de banc retirés par le script, `productionServiceUnchanged=true`. Le service de travail1.0.0/Node18 n’a pas été redémarré ou mis à niveau.

Correctif produit local : socket bornée `/run/throttle-{transfer|session}-UUID/terminal.sock`, RuntimeDirectory/Mode0700 gérés parsystemd, shared backend utilisé par helpers et attach. Journal/tombstones restent durables hors de ce répertoire. Test racine longue supérieur108octets et cheminfinalcourt ;32NodePASS. [Manuel systemd v252](https://github.com/systemd/systemd/blob/v252/man/systemd.exec.xml) consulté pour durée de vie/permissions. Contre-revue delta en cours ; la réussite du prochain essai n’est pas présumée.

L’archive initiale avait échoué par ENOSPC local avant tout transfert. Suppression explicitement autorisée du seul cache VaultRelease432MiB terminé, lsof sans fichierouvert ;144testsReleasePASS/logs conservés. Reconstruction et hash intégral de l’archive avant autorisation distante. Aucun autre cache/worktree/app supprimé. Hashs anciens exécutables avant suppression : XPC `59a88aac9bbea324fed5f6481aba20a918e9de5b029b61a4de3539b034fd654f`, MCP `564f63319595aeb459864852b2f1910a4bf4ac4988eb2d7ed5b28ad87401715c`.


### Requalification Linux PASS — 09:38:54 à09:39:16UTC

Archive exacte `3bb05c8d77e3e5bc183aaf4aec3936bc64c54481107fd67688bdff437057a99e` autorisée puis exécutée,32NodetestsPASS/LinuxNode24.20.0. Trois scénarios synthétiquesPASS, exit0 : freshClaude+Codex même invocation après retry, deux writers de chaque scope vus en étatT/t puis disparus après arrêt ; transfert synthétique perte mutable/stop/freeze/Gitretour/ack. Quatre reçuscleanup populated0, workingServiceUnchanged=true. Lecture finale indépendante du run : fichiers des4scopes,4RuntimeDirectory et2unitéswatchdog absents ; serviceactif/runningPID130723 et invocation870b3803b59e4f74b5ad1cad98d36f87 ; hashes3modules distants égaux aux sources locales.

Contre-revue des preuves END09:44:58UTC : archiveSHA/taille,11entréesdu manifeste,7fichierssource et JSON/rapportstdout concordent ; aucun nouveauP0/P1/P2 dans le périmètre. Champmetadata de début corrigé pour utiliser la vraie borne du rapport, ancienneheure de collecte renommée statusRecordedAt. PremierFAIL conservé. Run22,566s : timer180s armé puis désarmé, son déclenchement après crash n’a pas été exercé. Ces preuves qualifient uniquement les3scénarios synthétiques de ce candidat ; ni CLIauth/native, niHTTP complet, UI, performanceMac ouG9. G7PARTIAL.

Lot11 local démarré : scripts de déploiement installaient Node20 ou conservaient Node18. Préparation d’un binaire privé officielNode24.20.0, archivesx64/arm64 vérifiées parSHA, remplacementatomique avant serviceExecStart privé ; aucune modification duNode système ni déploiement de ce changement. TestsShared en cours. L’agent production reste1.0.0/Node18, cette dette de runtime n’est pas déclarée résolue en production.


### Lot11 — runtime privé, validation locale

Shared52testsPASS puis2tests ciblésPASS après extraction du helper SSH, exit0 ; syntaxe des scripts générés et refus d’une archive corrompue avant remplacement du binaire existant vérifiés. Premier échec de compilation du test (argument httpPort absent) conservé puis corrigé. Lint0, baseline2950 inchangé. Contre-revue END10:06:43.430309Z sans nouveauP0/P1/P2. Preuves dans lot11. Aucune installation réussie du script, exécution arm64Linux ou mise à niveau du service de travail encore qualifiée.

Préparation qualification Mac : lecture de démarrage révèle que XCTest ordinaire ouvre encore la DB réelle, le singleton updater démarre Sparkle précocement et Retention/CapabilityHost sont appelés avant la garde test. Correction de cette frontière et contre-audit borné en cours ; les anciens tests réussis ne constituent pas une preuve d’isolation complète.


### Lot12 — hôtes Mac isolés et première preview réelle

Sept frontières de démarrage corrigées : DB mémoire migrée sans licence pour tous les hosts, flags autonomes reconnus, rétention/capabilities après garde, updater lazy et non démarré en host, scène menu absente, reopen/terminate/deep-links gardés. Workbench et onboarding en previews inertes : aucun client Vault, store chargé, monitor ou probe worker. Contre-revue END10:25:03UTC sans nouveauP0/P1/P2. Quatre exemptions historiques déplacées/réduites, trois retirées ; baseline2950→2947, aucune ajoutée, lint0.

Validation14tests ciblésPASS. Full suite :607XCTest dont5skip et0failurePASS, puis SwiftTesting FAIL et crash de fixture reasoningSelectors (espaces de projet vides). RésultatglobalFAIL/exit65 conservé. Fixture corrigée avec espaces par défaut construits en mémoire et assertion #require(first) ; revalidation2XCTest+3SwiftTestingPASS, TESTSUCCEEDED/exit0. Addendum indépendant END10:32:53UTC sans défaut. Aucun fullsuitePASS post-correctif encore revendiqué.

Copie ad hoc distincte com.lorislab.throttle.qualification.lot12 préparée avec manifeste, pas installation de travail. Spawn direct via node_repl avorte dans Carbon avant AppDelegate ; open sous sandbox échoue -10827. Ouverture exacte hors sandbox autorisée par outil, exit0/PID51479, capture réelle940×652 en français. Appde travail conserve singletonPID57439. La capture ne montre pas de chevauchement ; plusieurs textes anglais et explications absentes de l’arbreAX. Contre-revue END10:36:35UTC identifie aussi une condition impossible pour l’étapeLoginItems (enabled et requiresApproval simultanés). Ces constats ouvrent lot13 ; G5PARTIAL, pas de preuve fonctionnelleVault/VoiceOverphysique. Preuves et événements sous lot12.

Lot13 en cours : étape d’accord macOS active quand requiresApproval, activation demandée distincte d’activée, groupingAX contain pour conserver texte et bouton ; preview synthétique de cet état sans SMAppService réel.41entrées françaises ajoutées sans modifier les traductions existantes, placeholders vérifiés. Reconstruction et captures à faire.


### Lot13 — état d’accord, FR et AX, puis troncatures

42 traductions FR ajoutées (895 clés effectives), placeholders conservés. La reprise d’activité de l’app rafraîchit l’état SMService puis la santé lors du passage à enabled ; les hôtes isolés sortent avant toute lecture du service. Six tests ciblés PASS/exit0 et lint0 ; contre-revue END10:47:12UTC sans nouveauP0/P1/P2.

Copie ad hoc lot13 unique, manifeste/exécution/captures sous audit-output/sota-20260907/lot13. Les deux états français disabled et requiresApproval sont observés à940×652 ; étapes et descriptions présentes dans AX, bouton d’accord visible. Fermeture de la copie confirmée, singleton de travail57439 conservé. Le bleu du bouton après Tab ne suffit pas à prouver le focus : clavier/VoiceOver restent non qualifiés. Aucun accord macOS réel ni connexion XPC effectué.

Revue des rendus END10:55:50UTC clôt les trois défauts initiaux dans ce périmètre, mais identifie UI-P2-05 : nom de projet coupé dans le bouton latéral et consigne Réglages tronquée. Correctif local de disposition : bouton multilignes, statut sur une ligne propre extensible. Reconstruction et recapture encore ouvertes.

Build Release app arm64 en cours, non signé, après premier essai sandbox exit74 (permissions des caches Swift), sans installation ni publication. Un delta de deux fichiers UI survient pendant la compilation des dépendances ; une passe incrémentale au snapshot stable suivra avant de qualifier les octets finaux.


### Lot13 clôture du défaut de disposition

Nouvelle copie ad hoc issue du Releasearm64,940×652, état requiresApproval : nomthrottle entier sur deux lignes et consigneRéglages entière sur une ligne propre. AX conserve les textes complets. Contre-revue END11:13:42UTC clôt UI-P2-05, aucun nouveauP0/P1/P2. Copie arrêtée et absence vérifiée ; aucun accord système réel/XPC/VoiceOver.

### Lot14 — origines natives Codex dans un même PID

Observation read-only réelle : parentCLI et sous-agent ont chacun un rollout ouvert writable dans le PID55582, mêmecwd. La découverte par seul processus les confondait en ambiguïté. Filtre source/thread_source avantunicité, refus des origines internal/subagent/inconnues ; legacy sanssource conservé conformément au décodeur Codex0.147.0. UUID/cwd/FD requis et refus de plusieurs racines inchangés. Protocole officiel tagrust-v0.147.0 vérifié et cité au paquet de recherche. Neuf testsnative avecwritersréels dans le mêmePID passent ; totalité ciblée27XCTest+3SwiftTestingPASS/exit0. Contre-revue END11:04:07 sans nouveauP0/P1/P2. Pas de qualification hibernation/native interactive déduite de cette lecture.

BuildReleasearm64 non signé PASS puis passe incrémentale stable PASS, exit0 ; vérification structurebundlePASS/signed0. Ces octets précèdentlot15, aucune signaturedistribution/install/publication.

### Lot15 — validation SwiftLint vraiment épinglée

Les anciennes commandes nues des lots9,12fixture,13activation résolvaient Homebrew0.65.1. Cette version ignore par défaut les URL(string:littéral)! ;0.63.2pinCI ne les ignore pas. Contre-revue END11:09:29 reproduit29diagnostics/exit2 en0.63.2 et0/exit0 en0.65.1 sur mêmesdixfichiers/baseline. Les anciens lint0 ne prouvent donc pas le gateépinglé ; les autres tests/builds ne sont pas invalidés. Échecs et commandes réduites conservéslot14.

Correction locale29unwrapsURL : garde des endpoints, cartesmodèlesoptionnelles rendues parModelCardLink, fixturesXCTUnwrap, constructionrequête/payload/navigationextraites pour ne pas élargir les seuils. ClélicenseJSONmachineId, entêtes/body/timeouts conservés. Baseline2947→2886, quatre dimensions historiques réduites et61entréesstales/résoluesretirées, aucune exemption nouvelle ; comparaisonprogrammatique lot15/baseline-delta.json. Lint0.63.2strict/no-cachePASSexit0. Nouveau scripts/verify-swiftlint.sh appeléparCI/build-dmg : mauvaisbinaire0.65.1rejetéexit78, binairepinexplicitePASS.

Première fullsuite lot15 FAILcompile : testmétadonnéesmodèle non adapté àURLoptionnelle. TestcorrigéXCTUnwrap ; nouvellefullsuite en cours, résultatnonprésumé. Contre-revue lot15source/ratchet en cours.


Lot15 revalidation finale : fullsuite610XCTest dont5ignorés et0échec, plus3SwiftTestingPASS, soit608réussis/613total, exit0 observé. Scriptlint0.63.2PASSexit0, mauvaisbinaire0.65.1rejeté78. Contre-revue END11:25:05UTC,23fichiersstables, aucune nouvelleP0/P1/P2 ; ratchet reproduit depuis/private/tmp. Pas de gainmémoireWebKit revendiqué pourloadHTMLString ; parcoursruntime toujours ouverts. Preuveslot15/final-validation.json.


### Lot16 — mesures réelles du contexte de recherche

MCPDebug recompilé cacheprivé, exit0. Processusstdioréel avec cléDebugéphémère, DB/inboxneufs danslot16, corpusDeepSearshread-only ; aucune connexionXPCinstallée/keychain.65documentsThrottle et738chunks chargés, schéma7, SQLCipher4.18.0, intégritéscipher/foreignKeys/quickCheckPASS. TroisRPCsmokePASS/exit0, citationsdocumentv2.

Sur13questionsThrottle du jeu humainhistorique golden-v2,11ont des références dans le grantThrottle ;2n’en ont quehorsgrant. À5extraits (IDsdocumentsdédupliqués), Recallmoyen0,7273, MRR0,5606, nDCG0,5799. Hashsextraits/plaintext, schémacit et confinementaugrantPASS. Batchimport+13requêtes0,947s ; pas de latenceparrequête/P95 mesurée. Les labels ne sont pas réadjudiqués sur le corpusactuel ; cette mesure n’est ni un nouveau seuilG9, ni une comparaisonauxanciensscorescrossproject, ni une preuveXPC/receipt. Rapportlot16/real-questions-6202957a-d77a-473e-bb04-a74a6b573bb4/report.json. Améliorationfutureduclassement à arbitrerau backlog, sans ajouterun quatrièmeaxemajeur.

### Lot17 — candidate signée et checkpoint source

Source 3.6.0/219, notes FR préparées. Archive universelle, export Developer ID,
contrôles stricts app/widget/Vault/Sparkle et DMG monté PASS ; prepare-only exit0
observé le8septembre après12:01UTC. ExécutableSHA256
9bdc4cb4da9ed7bbb89bd59e044397a498c9a8f1a56df9351f8fdf84b0638fd7 ;
DMG32284439octets SHA256e30c2ef0366d0de9c1ded3e50dcbf3bcb84382b49e8b589e5c83b99b4b727c5f.
Manifeste106entrées, dSYMsIntel/arm64 et log conservés. Aucun ticket notaire,
installation, redémarrage, upload ou nouvelle version publique revendiqué.
Gitleaks sur214fichiers texte actuels : une alerte generic-api-key, clé PUBLIQUE
Sparkle identique àHEAD et àl'app installée ;0secret confirmé, aucune exemption
ajoutée. Preuves dans audit-output/sota-20260907/release-3.6.0-219.
La candidate précède uniquement les mises à jour documentaires du checkpoint.
Qualification et rollback préparés ; accord frais d'arrêt/remplacement demandé,
non reçu àce checkpoint. Revue indépendante du lot17 en cours.
