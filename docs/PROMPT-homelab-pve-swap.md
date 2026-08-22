# Prompt à coller dans la session homelab

---

Incident sur l'hôte Proxmox `pve` (10.9.8.8 / 10.9.8.88 / 100.123.83.107) ce
matin 2026-08-22. Il est résolu de lui-même, mais la cause est toujours là et
elle se reproduira. Le rapport complet est dans
`/Users/kevinnadjarian/GitHub/Throttle/docs/INCIDENT-pve-2026-08-22.md` — lis-le
avant d'agir, il contient les mesures brutes et la liste des hypothèses déjà
réfutées.

## Ce qui s'est passé

Pendant environ 20 minutes, l'hôte a répondu en ARP mais plus rien au-dessus :
zéro ICMP et tous les ports TCP fermés, vérifié depuis le Mac **et** depuis
OPNsense qui est sur le même segment L2. Puis il est revenu seul, sans
redémarrer (`uptime` continu : `up 5 days, 23:20`).

Cause racine, trouvée dans `journalctl -k` (elle avait déjà disparu de `dmesg`) :

```
Aug 22 10:08:26 pve kernel: Write-error on swap-device (251:0:16318728)
… série continue
```

```
free -g  →  total 62   used 52   free 10
            Swap: total 7   used 7   free 0
swapon   →  /dev/zram0   8G   8G   prio 100
zram     →  6.9 GB compressés en 2.9 GB (lz4)
vm.swappiness = 10
```

Le swap est du zram, il était plein à 100 %. Quand le noyau ne peut plus écrire
dans le swap, la récupération mémoire échoue et toute allocation se bloque —
d'où l'arrêt total des services pendant que l'ARP, qui n'alloue rien, continuait
de répondre. C'est un problème de **capacité** : les conteneurs et VM occupent
réellement 52 des 62 GB.

`zpool status` : tous les pools sains, scrub du 9 août sans erreur. Le stockage
n'est pas en cause.

## Hypothèses déjà testées et FAUSSES — ne les reprends pas

- **conntrack saturé** → `count=4121` / `max=262144`, soit 1,6 %.
- **surcharge CPU** → load 23 sur **32 cœurs**, soit 72 %. Pas une saturation.
- **`404-sensor` à 475 % de CPU** → artefact de mesure. `ps -eo pcpu` donne la
  moyenne sur la durée de vie du processus, ce qui gonfle les processus courts
  (le `ps` lui-même s'affichait à 3300 %). Utilise `top -bn2`, jamais `ps pcpu`.
- **disque / ZFS** → pools sains, zéro erreur de données.

## Problème secondaire, séparé et bien réel

LXC 105 (`plex`, MAC `BC:24:11:61:22:91`, VLAN tag 20, `192.168.3.108/24` sur
vmbr2) inonde en broadcast :

```
IPv4: martian source (src=192.168.3.108, dst=192.168.3.255,
      dev=fwbr105i0 / fwbr450i0 / fwbr173i0 / fwbr161i0 / fwbr118i0 …)
net_ratelimit: jusqu'à 353 callbacks suppressed toutes les 5 s
```

Ses annonces DLNA/GDM atteignent les ponts de conteneurs d'autres VLAN. Au-delà
du softirq gaspillé sur chaque pont, ça avait rempli le buffer noyau de 1488
lignes et **effacé les traces du blackout dans `dmesg`**. Un incident qui détruit
ses propres preuves est un incident qu'on ne diagnostiquera jamais deux fois.

## Ce que j'attends de toi

D'abord un diagnostic à toi, en lecture seule — ne me crois pas sur parole,
les trois hypothèses ci-dessus étaient les miennes et elles étaient fausses.
Confirme ou casse la conclusion « swap plein », et dis-moi laquelle.

Ensuite, propose un plan pour ces trois points, en indiquant pour chacun le
risque et si ça demande un redémarrage :

1. **Rendre l'épuisement mémoire non fatal.** L'objectif n'est pas d'empêcher la
   machine de swapper, c'est qu'elle **ralentisse au lieu de se figer** quand le
   swap sature. La piste que j'ai en tête est un vrai swap sur `rpool` (zvol de
   16–32 GB, priorité inférieure à zram) pour que le noyau garde une porte de
   sortie. Dis-moi si c'est le bon choix ou s'il y a mieux — et regarde d'où
   viennent réellement les 52 GB : les conteneurs en tête sont `frigate` 6.9 GB,
   `wazuh` 4.0 GB, `throttle-agent` 1.7 GB, mais l'essentiel est côté VM et
   reste à inventorier. Agrandir zram seul ne règle rien : il se remplira encore.
2. **Arrêter la tempête de broadcast Plex** — soit en désactivant DLNA et GDM
   dans Plex, soit en cloisonnant le VLAN 20. Ne te contente pas de
   `net.ipv4.conf.all.log_martians=0` : ça masque le symptôme sans rien régler.
3. **Une alerte sur `swap used > 90 %`.** Rien n'a prévenu pendant 20 minutes de
   panne totale. C'est ce qui manque le plus.

## Contraintes

- Cet hôte porte une trentaine de services en production (Plex, Frigate,
  Wazuh, les passerelles MCP, l'agent Throttle). Rien de destructif ni de
  redémarrage sans mon accord explicite.
- Propose-moi le plan avant de l'exécuter.
- Si tu changes quelque chose au réseau, garde un chemin de secours : OPNsense
  (`10.9.8.2`, clé `~/.ssh/opnsense_ed25519`) est resté joignable pendant toute
  la panne et sert de point d'observation extérieur.

---
