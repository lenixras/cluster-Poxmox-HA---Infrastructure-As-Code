# Architecture cible du cluster

> Documentation complémentaire de la [roadmap](../README.md). Ce document décrit **quoi** construire et **pourquoi** ; les « comment » sont dans les docs suivantes (`03` → `13`).

---

## 1. Principe et modèle de disponibilité

Le cluster repose sur **trois mécanismes complémentaires**, dans cet ordre :

1. **Corosync** — établit l'appartenance (membres) et transporte le tuyau de communication entre nœuds
   ([Cluster Manager](https://pve.proxmox.com/pve-docs/chapter-pvecm.html)).
2. **Quorum** — transforme cette appartenance en *permission d'agir* : **majorité** (2 votes sur 3).
3. **Watchdog (fencing)** — un nœud qui perd le quorum **ne réinitialise plus le timer** → le watchdog
   expire (~60 s) et **reboote le nœud**. C'est la garantie que la VM ne tourne pas « deux fois » (split-brain).

Vient ensuite **HA Manager** (`ha-manager`, process `pve-ha-lrm`/`pve-ha-crm` qui redémarre la VM sur un nœud sain) et **la réplication ZFS** qui rend les données du VM disponibles sur le nœud de secours.

### Conséquence opérationnelle

| Événement | Comportement | Délai typique |
|---|---|---|
| Perte brutale d'un nœud | watchdog → reboot du nœud → la VM est redémarrée sur son réplica | ~1 à 2 min (pas moins, c'est un **redémarrage**, pas une migration à chaud) |
| Migration planifiée (maintenance) | online migration à froid/chaud avant coupure | selon volume RAM |

> ℹ️ *Le HA Proxmox relance le VM* — **il ne conserve pas l'état mémoire ni les connexions ouvertes**. Les applications doivent survivre à un arrêt non propre (journalisation, reconnect automatique, base récupérable). Et le HA **n'est pas une sauvegarde** (voir doc 11).

---

## 2. Réplication ZFS : le modèle de données

- Chaque nœud possède son **pool ZFS local** (`tank`).
- Les disques de VM (`scsi0…`) sont créés sur `tank/vm` (zfspool).
- Un job de réplication (`pvesr`) **copie par snapshots ZFS** les volumes du VM vers un nœud cible,
  de façon **incrémentale** (seul le delta est envoyé après la première synchro complète).
- En cas de perte du nœud source, le nœud cible dispose d'un snapshot répliqué récent → HA y redémarre le VM.

Source : [PVE — Storage Replication](https://pve.proxmox.com/pve-docs/chapter-pvesr.html).

### Caractéristiques à connaître (à documenter pour TOUTE l'équipe)

- **[RPO] = intervalle de réplication** : avec `*/5`, au plus 5 minutes de données perdues.
  Ce sont des **writes non répliqués** (arrêt non propre) — pour une base de données, prévoir une couche
  applicative de récupération (WAL, recluster…).
- **[RTO] = temps de redémarrage** du VM sur le nœud de secours (dépend du pool, réseau, RAM).
  À mesurer en doc 12 (objectif typique : < 5 min en exercice).
- Réplication **unidirectionnelle** : source → cible. Répliquer vers **deux** nœuds protège contre
  une double panne, au prix du double de place et de bande passante.

### Schéma de réplication (exemple)

```
        pve1 (source)  VM 100  ──pvesr──▶  pve2 (cible 1)
                                          pve3 (cible 2, en option)

        pve2 (source)  VM 101  ──pvesr──▶  pve1
                                          pve3

        pve3 (source)  VM 102  ──pvesr──▶  pve1
                                          pve2
```

> ⚠️ Une VM **répliquée vers un nœud ne peut pas tourner sur ce nœud** simultanément (le VM doit résider
> sur son nœud source : c'est le comportement normal de pvesr). Les règles d'affinité HA (doc 07)
> placent la VM sur son nœud source en fonctionnement normal.

---

## 3. Schéma réseau

```
                         ┌────────── Réseau Management 192.168.1.0/24 ──────────┐
                         │   GUI 8006 · SSH 22 · API · accès admin (VPN)       │
                         │                                                     │
    Corosync 10.10.0.0/24 │        Réseau VM 10.10.10.0/24 │  Backup 10.10.30.0/24
    (dédié, 1 GbE)        │        bridges vmbr2          │  (PBS 8007)
                          │                                                     │
        pve1 ── 10.10.0.1 │    192.168.1.10               │                     │
        pve2 ── 10.10.0.2 │    192.168.1.11               │   [pbs01] .10       │
        pve3 ── 10.10.0.3 │    192.168.1.12               │                     │
                          │              │                │                     │
              ZFS tank    │    VMs : dns01, vpn01, monitoring01, app01/02       │
              (OS + data) │    sur tank/vm (répliqués)    │                     │
```

Règles :
- Corosync **jamais** sur le même lien que le trafic VM/backup (jitter → auto-fencing).
- Le réseau Management expose `8006`/`22` **uniquement** depuis le subnet admin / VPN (doc 09).
- Le réseau Backup est dédié nœuds → PBS (le trafic de sauvegarde est volumineux).

---

## 4. Cartographie des services (registre)

| Service | Type | VM | Ports | Rôle disponibilité |
|---|---|---|---|---|
| GUI/API PVE | système | — | 8006 | natif cluster |
| Corosync/pvecm | système | — | 5405–5412 UDP | natif cluster |
| DNS interne | VM | dns01 | 53/5353 | répliquée + HA |
| VPN (WireGuard) | VM | vpn01 | 51820 | répliquée + HA (point d'entrée admin) |
| PBS | VM (ou petit serveur) | pbs01 | 8007 | sauvegarde des VMs |
| Supervision | VM | monitoring01 | 9090/3000/3100 | répliquée + HA |
| Reverse proxy | VM | app01 | 80/443 | répliquée + HA |
| Application | VM | app02… | — | répliquée + HA |

---

## 5. Choix et justifications (sources)

| Choix | Justification | Source |
|---|---|---|
| **3 nœuds** | Quorum fiable : 2 votes/3 ; un nœud peut tomber sans arrêt. Un 2-nœuds s'arrête à la première panne (1 vote = pas de majorité) | [HA wiki](https://pve.proxmox.com/wiki/High_Availability), [pvecm](https://pve.proxmox.com/pve-docs/chapter-pvecm.html) |
| **ZFS + réplication** plutôt que Ceph | Ceph exige ≥ 3 nœuds, 10+ GbE, 3+ disques OSD/nœud et une gestion de placement PG. En petite infra, ZFS répliqué donne le HA avec 2–4 disques et un réseau 1 GbE — au prix d'un RPO ≠ 0 | [Storage Replication](https://pve.proxmox.com/pve-docs/chapter-pvesr.html) |
| **Watchdog (fencing par reset)** plutôt que STONITH externe | Pas de BMC/IPMI à configurer pour chaque nœud ; marches arrière robuste | [HA wiki](https://pve.proxmox.com/wiki/High_Availability) |
| **Provider `bpg/proxmox`** pour Terraform | Successeur maintenu du fork Telmate, compatible PVE 8/9, schéma complet cloud-init | [registry bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest) |
| **Ansible `community.proxmox`** pour la conf cluster | Modules officiels (création/jointure de cluster, HA, RBAC) sans dépendre de l'API brute | [collections docs](https://docs.ansible.com/ansible/latest/collections/community/proxmox/index.html) |
| **PVE 9 : règles d'affinité HA** plutôt que HA groups (dépréciés) | node-affinity + resource-affinity remplacent les groupes depuis PVE 9.0 | [HA section](https://pve.proxmox.com/wiki/High_Availability) |
| **PBS séparé** | Éviter de sauvegarder sur le cluster lui-même (défaillance commune) ; dédup + chiffrement natif | [PBS wiki](https://pbs.proxmox.com/wiki/) |
| **3 réseaux + VPN** | Séparation des plans (mgmt/cluster/data), blast radius, exposition minime | [Global hardening guide](https://github.com/HomeSecExplorer/Proxmox-Hardening-Guide) |

---

## 6. Limites assumées (à connaître)

- **RPO ≠ 0** : la réplication est asynchrone (Δ suspendu entre deux jobs).
- **RTO = redémarrage** : pas de reprise-l'état-mémoire (contrairement à une failover à chaud).
- **Un nœud tombe** → toléré. **Deux nœuds simultanément** → plus de quorum (1 vote/3) → le cluster se fige (protection split-brain), aucune VM ne démarre tant que la majorité n'est pas revenue.
- **Le HA ne protège ni contre la suppression de fichiers, ni le ransomware, ni une corruption logique** → rôle de PBS (doc 11).

## 7. Vers la mise en œuvre

Enchaînez avec :
1. [`03-installation-noeuds.md`](03-installation-noeuds.md) — installer et durcir les 3 nœuds ;
2. [`04-cluster-zfs-replication.md`](04-cluster-zfs-replication.md) — cluster Corosync + pools ZFS + réplication ;
3. [`05-terraform.md`](05-terraform.md) puis [`06-ansible.md`](06-ansible.md) — IA C ;
4. [`07-ha.md`](07-ha.md) — bascule automatique.