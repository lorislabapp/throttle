# Qualification Linux Throttle — paquet exact

Exécuté le 8 septembre 2026 après autorisations exactes : premier candidat FAIL, second candidat PASS pour les trois scénarios synthétiques décrits ci-dessous. Contre-revue des preuves END09:44:58UTC ; aucune conclusion CLI native, HTTP complet, UI ou G9.

- Destination : CT134 throttle-agent, via la connexion SSH existante pve.
- Archive : `audit-output/sota-20260907/lot10/throttle-linux-qualification-20260908.tar.gz` (31,898,353 octets).
- SHA-256 : `f768c4a06e8690f718098f6fafeeb83cf3c5d8d1583490e159b0f4c9248d42a6`.
- Dossier distant neuf : `/opt/throttle-qualification/candidate-f768c4a06e8690f7`.
- Runtime privé : Node24.20.0 Linuxx64, SHA officiel `2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2`.

## Opération préparée

Le script `audit-output/sota-20260907/lot10/run-ct134-qualification.sh` transfère l’archive, vérifie son empreinte, l’extrait dans son dossier neuf, puis lance les self-tests et trois scénarios. Une destination déjà présente est refusée.

- Créations fresh Claude/Codex par vrais helpers, commandes synthétiques : retry même requête et invocation, arrêt après SIGSTOP observé sur writer et descendant détaché résistant à TERM.
- Transfert avec writer synthétique remplaçant le helper CLI natif : perte du journal mutable, arrêt confirmé, freeze transcript/Git, vérification du fichier produit et accusé des hashes.
- Nettoyage après tombstone/sceau et reçu de cgroup vide. Timer systemd indépendant à180s si le pilote disparaît, registre/annulation durables ; retrait des unités après réussite, preuves conservées en cas d’erreur.

Chaque passage crée `/opt/throttle-qualification/run-UUID`, quatre unités de scope UUID et deux unités de secours sous `/run/systemd/system`, et appelle `systemctl daemon-reload`. Les données du banc restent disponibles. Git utilise HOME/config privés ; les variablesGit héritées sont purgées dans les helpers. Le service existant est observé avant/après, sans ordre de redémarrage. Node18 du service reste en place. Aucun serveurHTTP du banc, aucune CLI Claude/Codex ni aucun dépôt utilisateur ne sont visés.

## Preuves et limites

Le banc est revu statiquement, syntaxes Node/shell et --plan PASS. Son hash est `2413cc9ffb059a6b37641e73feaa7372905c4ac4702d62f082bc2e2de9a89baf`. Le manifeste interne vérifie chaque fichier et l’archive officielle Node. La première tentative d’archivage a échoué par ENOSPC ; l’archive actuelle a été reconstruite après suppression autorisée de notre seul cache VaultRelease432MiB (tests144PASS et logs conservés, aucun fichier ouvert selon lsof).

Le banc ne qualifie ni les vrais CLI/auth/transcripts de production, ni tout le protocoleHTTP, ni UI/VoiceOver/mémoire macOS, ni publication. Il apporte la prochaine preuve noyau/systemd/Git de G7. La boucle SOTA reste active.


## Deuxième candidat — correction de la socket

Le premier passage réel a échoué au démarrage tmux : socket trop longue sous le dossier de journal. Node31testsPASS, aucun scénario système réussi, nettoyagecgroup0 et service existant inchangé. Le correctif fournit un RuntimeDirectory systemd0700 distinct pour chaque unité, sous `/run/throttle-{session|transfer|return}-UUID` ; journal et marqueurs durables préservés. Chemins sockets bornés71–73octets,32NodePASS local. Revue indépendante END09:29:42UTC sans nouveauP0/P1/P2, GO statique pour requalification uniquement.

Archive : `throttle-linux-qualification-20260908-socket.tar.gz` (31898750octets). SHA-256 `3bb05c8d77e3e5bc183aaf4aec3936bc64c54481107fd67688bdff437057a99e`. Destination neuve `/opt/throttle-qualification/candidate-3bb05c8d77e3e5bc`. Script `audit-output/sota-20260907/lot10/run-ct134-socket-qualification.sh`. Scénarios, runtime privé, cleanup/watchdog et frontières identiques. Les dossiers RuntimeDirectory sous `/run` sont créés/retirés parsystemd avec les scopes. Ce second passage a réussi, exit0, de09:38:54.224 à09:39:16.790UTC :32testsNode et3scénarios synthétiquesPASS,4reçus de nettoyage populated0. Le service de travail conserve son PID130723 et invocation870b3803b59e4f74b5ad1cad98d36f87. La lecture finale confirme absence des4unités,4RuntimeDirectories et2unités de secours ; données et runtime privés conservés. Le déclenchement du watchdog après crash n’a pas été exercé. Rapport et relevé final sous lot10/linux-socket-qualification-report.json et linux-final-readonly-state.json.
