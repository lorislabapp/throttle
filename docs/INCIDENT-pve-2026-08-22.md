# Incident — hôte Proxmox injoignable, 2026-08-22

Briefing pour la session qui gère le homelab. Rédigé par la session Throttle.
**Lecture seule côté constat : tout ce qui suit a été mesuré, pas supposé.**
Les hypothèses sont marquées comme telles.

## Symptôme

L'hôte Proxmox (`10.9.8.8`, `10.9.8.88`, `100.123.83.107`) ne répond plus :

| test | résultat |
| --- | --- |
| ARP depuis OPNsense | **répond**, MAC `98:b7:85:1e:bb:b6`, bail rafraîchi plusieurs fois |
| ICMP depuis le Mac (3 adresses) | 100 % de perte |
| ICMP depuis OPNsense (même segment L2) | 100 % de perte |
| TCP 22 / 8006 / 3128 depuis OPNsense | fermés |
| TCP 8105 depuis le Mac | fermé |
| TCP 8103 depuis le Mac | `SYN_SENT` sans réponse |

**L'entrée ARP a été rafraîchie pendant la panne** (expiration remontée de 174 s à
1157 s puis 733 s). Le noyau répond donc encore au niveau 2. Ce n'est ni un arrêt
machine ni une coupure réseau : `10.9.8.2` (OPNsense) répond normalement et
l'accès Internet du Mac est intact.

## Dernier état connu, capturé à 09:33 UTC+2

```
uptime : up 5 days, 22:47,  load average: 16.01, 16.10, 16.78
%CPU    RSS      COMMAND
3300    5772     ps
 475    3796     404-sensor
 104   35212     dockerd
99.7  216128     ffmpeg
98.9    6312     tar
```

L'hôte est devenu muet dans les minutes qui ont suivi.

## RÉSOLU — l'hôte est revenu seul après 1174 s, sans redémarrage

`uptime` après retour : `up 5 days, 23:20` — continuité confirmée, il n'a pas
rebooté.

### Cause racine : le swap est plein à 100 %

```
Aug 22 10:08:26 pve kernel: Write-error on swap-device (251:0:16318728)
… série continue
```

```
free -g   →  total 62   used 52   free 10
             Swap: total 7   used 7   free 0
swapon    →  /dev/zram0   8G   8G   prio 100
zram      →  6.9 GB compressés en 2.9 GB (lz4)
vm.swappiness = 10
```

Le swap est **zram**, pas un disque : 100 % occupé. Quand le noyau ne peut plus
écrire dans le swap, la récupération mémoire échoue et **toute allocation se
bloque** — d'où l'arrêt total des services pendant que l'ARP, qui n'alloue rien,
continuait de répondre. C'est un **problème de capacité**, pas une panne : les
conteneurs et VM occupent réellement 52 des 62 GB.

`zpool status` : **tous les pools sains**, scrub du 9 août sans erreur, aucune
erreur de données. Le disque n'est pas en cause.

### Cause secondaire : tempête de broadcast depuis Plex (LXC 105)

```
IPv4: martian source (src=192.168.3.108, dst=192.168.3.255,
      dev=fwbr105i0 / fwbr450i0 / fwbr173i0 / fwbr161i0 / fwbr118i0 …)
net_ratelimit: jusqu'à 353 callbacks suppressed toutes les 5 s
```

LXC 105 (`plex`, `BC:24:11:61:22:91`, VLAN tag 20, `192.168.3.108/24` sur vmbr2)
diffuse en broadcast pour la découverte DLNA/GDM, et ces paquets atteignent les
ponts de conteneurs d'autres VLAN. Coût : du softirq sur chaque pont, et surtout
**1488 lignes qui chassent le reste du buffer noyau** — le flood efface les
traces des incidents, y compris celles de ce blackout dans `dmesg` (seul
`journalctl -k` les avait encore).

### Hypothèses testées et RÉFUTÉES

Écrites ici pour que personne ne les reprenne :

- **conntrack saturé** → `count=4121` / `max=262144`, soit **1,6 %**. Faux.
- **surcharge CPU** → load 23 sur **32 cœurs** = 72 %. Pas une saturation.
- **`404-sensor` à 475 % de CPU** → artefact : `ps -eo pcpu` donne la moyenne sur
  la durée de vie du processus, ce qui gonfle les processus courts (le `ps`
  lui-même s'affichait à 3300 %). Mesurer avec `top -bn2`, jamais `ps pcpu`.
- **disque / ZFS** → pools sains, zéro erreur.

## Ce que cette session a fait sur l'hôte avant l'incident

À évaluer comme cause possible, sans complaisance :

1. `iptables -t nat -A PREROUTING … --dport 8105 -j DNAT --to 10.9.8.131:8105`
   (+ 4 règles INPUT dans LXC 131 pour le port 8105). Sauvegardes :
   `/root/rules.v4.bak.*`, `/root/lxc131.rules.bak.*`
2. Création de l'utilisateur `git` (`git-shell`, sans mot de passe) et de
   `/datapool/git/repos` — dépôts nus.
3. Déploiement de `mcp-codemagic.service` dans LXC 131 (port 8105, `MemoryMax=384M`).
4. **Un push git de 464 MB** (dépôt Éclair) vers `/datapool/git/repos`, alors que
   la charge était déjà à 16. Le premier essai a coupé en plein transfert.
5. Kevin a lancé : ajout de `git@100.64.0.0/10 git@10.9.8.0/24` à `AllowUsers`
   dans `/etc/ssh/sshd_config.d/99-hardening.conf` (validé par `sshd -t`,
   sauvegarde `.bak.*`), puis `systemctl reload ssh` et un `chown -R git:git`.

Le point 4 est le plus lourd et le plus proche dans le temps. **Après analyse il
n'est pas la cause** : la cause est l'épuisement du swap sur une machine déjà à
52/62 GB. Le push a pu contribuer à la pression mémoire au moment du basculement,
sans en être l'origine.

## Ce qui N'EST PAS en cause

- Le réseau : OPNsense répond, la route du Mac est saine.
- Le travail Éclair de Kevin : la session active tourne **sur le Mac**
  (`codex` pid 87401, cwd `/Users/kevinnadjarian/GitHub/Éclair`), pas sur le box.
  La session marquée REMOTE dans le cockpit est `idle`.

## Correctifs proposés — AUCUN appliqué, décision de Kevin

Rien de ce qui suit n'a été exécuté. Ce sont des opérations sur un hyperviseur
en production qui porte une trentaine de services.

### 1. Rendre l'épuisement mémoire non fatal (priorité)

Le problème n'est pas que la machine swappe, c'est qu'**une fois le swap plein
elle se fige** au lieu de dégrader. Options, de la moins à la plus intrusive :

- **Ajouter un vrai swap sur `rpool`** (zvol de 16–32 GB, priorité inférieure à
  zram). Le noyau garde une porte de sortie quand zram sature. Fait à chaud.
- **Réduire la consommation** : `frigate` 6.9 GB, `wazuh` 4.0 GB,
  `throttle-agent` 1.7 GB en tête des conteneurs — mais l'essentiel des 52 GB est
  côté VM, à inventorier.
- Ne PAS se contenter d'agrandir zram : il se remplit à nouveau, et la panne
  revient identique.

### 2. Arrêter la tempête de broadcast

Dans Plex : *Paramètres → Réseau* → désactiver **DLNA** et **GDM** si tu ne t'en
sers pas. Sinon, cloisonner le VLAN 20 pour que la diffusion n'atteigne plus les
ponts des autres conteneurs. **Ne pas** se contenter de
`net.ipv4.conf.all.log_martians=0` : ça masque le symptôme, la tempête continue
et le softirq reste consommé.

### 3. Surveillance

Rien n'a alerté pendant 20 minutes de panne totale. Une alerte sur
`swap used > 90 %` aurait donné le signal avant le blocage.

### Vérifications de reprise

- `mcp-codemagic` et les 4 autres gateways de LXC 131 sont-ils remontés ?
- Depuis le Mac : `~/GitHub/Throttle/scripts/throttle-sync.sh status`

## Ce qui reste à faire ensuite (hors incident)

- Pousser le travail de la session Éclair distante (`~/offload/Éclair` sur
  LXC 134) sur le miroir — il n'y est pas encore.
- Deux bugs Throttle relevés pendant l'incident : une session distante morte
  garde l'air vivante, et une session affichée « offloadée » tournait en fait
  en local.

---

## Résolution — appliquée le 2026-08-22 (session homelab)

**Diagnostic indépendant : conclusion « swap plein » CONFIRMÉE.** Mesuré à nouveau
en direct : `SwapFree` = 68–196 kB (zram 8 GB à 100 %), `Write-error on
swap-device (251:0:…)` **encore actifs** (10:20), load 18–23, MemAvailable
descendu jusqu'à **13 %** pendant l'intervention. Le mécanisme est exactement
celui décrit : zram plein → le noyau ne peut plus swapper → allocations bloquées
→ services muets pendant que l'ARP répond.

**Hypothèse ajoutée puis écartée :** l'ARC ZFS n'est **pas** le voleur de RAM
caché — `size` = 3,4 GB, `c_max` = 6,3 GB (déjà plafonné). Les deux plus gros
postes sont les **VM `mailcow` (180)** et **`ha` (450)**, 8 GB chacune, sans
ballooning. **Aucun OOM-killer userspace** n'était présent (`earlyoom` absent,
`systemd-oomd` inactif) → rien ne tuait un process avant le deadlock noyau.

### ⚠️ Correctif #1 (swap zvol) écarté — ne pas l'appliquer
Un swap sur zvol ZFS **deadlocke** sous pression : pour écrire la page de swap
censée libérer de la RAM, ZFS doit en **allouer**, alors qu'il n'y en a plus.
C'est vraisemblablement pourquoi un zvol swap avait déjà été retiré après un
freeze (mémoire homelab : « freeze fixed, zvol swap removed »). Le rajouter
reproduirait la panne. Choix retenu à la place : **earlyoom** (dégrader au lieu
de figer).

### Ce qui a été appliqué (tout à chaud, aucun reboot)

| # | Action | Détail |
| --- | --- | --- |
| 1a | **earlyoom installé + actif** | `/etc/default/earlyoom` : SIGTERM à mem≤8 %, SIGKILL à 4 %. `--avoid (kvm\|qemu\|systemd\|sshd\|pmxcfs\|pve\|corosync\|watchdog\|zed\|lxcfs\|init)` (protège VM + démons PVE), `--prefer (ffmpeg\|frigate\|python\|java\|Suricata\|motis)`. Tue un process de conteneur (redémarré seul) au lieu de figer l'hôte. |
| 3 | **Alerte mémoire → Slack** | `/root/pve-mem-alert.sh` + `pve-mem-alert.timer` (2 min). Seuil **MemAvailable ≤ 15 %** (précurseur réel — « swap>90 % » seul déclencherait en permanence, le zram étant chroniquement plein). Canal Slack *LorisLabs Comms*, cooldown 30 min, message de rétablissement à ≥20 %. **Testé (`ok=true`), a déjà déclenché à 15 %.** |
| 1b | **Ballooning VM** | `qm set 180 --balloon 6144` + `qm set 450 --balloon 6144` (min 6 / max 8 GB) → pvestatd récupère jusqu'à ~4 GB sous pression. |
| — | **Délestage** | Jellyfin (CT173) arrêté + `--onboot 0` (redondant avec Plex, **+1,9 GB**) ; Plex éteint la nuit `/etc/cron.d/plex-night` (`pct stop 105` @00h, `start` @08h). |
| — | **KSM** | `ksmtuned` déjà actif (dédup pages inter-VM). |
| 2 | **Tempête broadcast Plex coupée** | DLNA + GDM désactivés à chaud via l'API Plex (`PUT /:/prefs?DlnaEnabled=0&GdmEnabled=0`). Martians **~4200 → ~120 /min** (–97 %). Un restart Plex finirait le résiduel. |

### Vérifications de reprise
- earlyoom `active`, `pve-mem-alert.timer` `active`.
- MemAvailable remonté à ~10–11 GB après l'arrêt de Jellyfin.
- Post Slack de test : `ok=true`.

### Ce qui reste — durable
**Plus de RAM.** 62 GB reste trop juste pour la flotte (2 VM = 16 GB + Frigate
3,2 GB + conteneurs). earlyoom empêche le crash mais ne crée pas de RAM → cible :
**barrettes 32 GB DDR4-3200 RDIMM ECC** (voir discussion d'achat en cours). Le
restart de Plex (résiduel martian) et l'arbitrage sur ce qui doit vraiment
tourner (2e serveur média, VM à 8 GB fixes) restent à trancher.

_Détail complet + commandes rejouables : mémoire homelab `pve-memory-freeze-earlyoom`._
