# Prérequis — Matériel, réseau, versions

> Cette fiche est le point d'entrée **avant toute installation**. Complétez les champs `?` de la colonne "Valeur retenue" et cochez les critères de validation.

## 1. Matériel (par nœud) — recommandations Proxmox/HA

| Composant | Recommandation | Pourquoi | Valeur retenue |
|---|---|---|---|
| Serveurs | 3 nœuds **identiques** (CPU, RAM, disques) | Caractéristiques Homogènes acceptées par Corosync ; mêmes options de migration | `?` |
| CPU | Génération identique avec **AES-NI** (VM → type `x86-64-v2-AES`) | Compatibilité *live migration* et performance chiffrement | `?` |
| RAM | ≥ 32 Go **ECC** par nœud recommandé | Le stockage ZFS + VMs en réplication consomme ; ECC protège les données | `?` |
| Comps. "server" | Alim. redondante, IPMI, carte réseau multiple | Réduire les points de panne internes | `?` |
| Disques OS | 2 × SSD ≥ 256 Go en **ZFS mirror** | Redondance du système, résilience | `?` |
| Disques data | 2 × NVMe ≥ 1 To (ou 4× SSD) en **ZFS mirror** | Pool des VMs (ce qui sera répliqué). 1 pool ZFS par nœud | `?` |
| UPS (option forte) | 1 UPS pour l'ensemble ou par nœud | Une perte totale de courant = aucun nœud ne tient quorum | `?` |

**Budget capacitaire** : la réplication duplique les données sur le nœud cible. Prévoyez sur chaque nœud : `espace_utilisable ≥ (VMs sur ce nœud + VMs répliquées depuis les pairs) × marge 1,5`.

## 2. Réseau

| Réseau | Usage | Bande recommandée | Adressage exemple |
|---|---|---|---|
| Management | API 8006, SSH, GUI | 1 GbE | `192.168.1.0/24` |
| **Corosync (cluster)** | Heartbeat/quorum/migration SSH | 1 GbE **dédié**, latence < 5 ms | `10.10.0.0/24` |
| VM / invités | Trafic applicatif | 1 GbE + | `10.10.10.0/24` |
| Backup | Nœuds ↔ PBS | 1 GbE (dédié conseillé) | `10.10.30.0/24` |

**Règles impératives** :
- **Jamais** partager le lien Corosync avec le trafic VM/backup : la saturation entraîne des *token timeouts* → auto-fencing de nœuds sains. Corosync est sensible au **jitter**, pas au débit.
- Latence inter-nœuds ≤ 5 ms (LAN) : c'est une exigence Corosync pour un fonctionnement stable.
- 2 liens Corosync conseillés (redondance knet), sur 2 réseaux physiques différents.
- Switchs : 2 switchs gérés journaliers en redondance ; éviter les liens non-GERIP sans LACP fast.

### Plan d'adressage à compléter

| Hôte | Mgmt `192.168.1.0/24` | Corosync `10.10.0.0/24` | Rôle |
|---|---|---|---|
| `pve1.cluster.local` | `192.168.1.10` | `10.10.0.1` | nœud 1 (init cluster) |
| `pve2.cluster.local` | `192.168.1.11` | `10.10.0.2` | nœud 2 |
| `pve3.cluster.local` | `192.168.1.12` | `10.10.0.3` | nœud 3 |
| `pbs.cluster.local` | `192.168.1.20` | — | Proxmox Backup Server |
| passerelle / DNS | `192.168.1.1` | — | box/pare-feu |

## 3. Versions logicielles (fixées pour la durée du projet)

| Logiciel | Version mini | Source |
|---|---|---|
| Proxmox VE | **9.x** — **identique sur les 3 nœuds** | <https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso> |
| Proxmox Backup Server | **3.x** | <https://www.proxmox.com/en/downloads/proxmox-backup-server/iso> |
| Terraform | **≥ 1.9** | <https://developer.hashicorp.com/terraform/downloads> |
| Provider `bpg/proxmox` | **~> 0.66** | <https://registry.terraform.io/providers/bpg/proxmox/latest> |
| Ansible core | **≥ 2.16** | <https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html> |
| Collection `community.proxmox` | ≥ 1.1.0 | `ansible-galaxy collection install community.proxmox` |
| Système de VM | Ubuntu 24.04 LTS / Debian 13 (cloud-init) | <https://cloud-images.ubuntu.com/> |

> ⚠️ **Mêmes versions de PVE partout** : c'est une exigence du cluster manager (migrations, pmxcfs). Toute mise à jour de version se fait **nœud par nœud** (doc 13 + RB-03).

## 4. Outillage du control node (serveur d'administration)

| Outil | Commande de référence | Notes |
|---|---|---|
| Terraform | `terraform version` | CLI sur le poste admin |
| Ansible | `ansible-core --version` | exécute les modules via API PVE (ne cible pas forcement SSH) |
| proxmoxer | `pip install proxmoxer` | dépendance Python des modules `community.proxmox` |
| Vault (secrets) | `ansible-vault` + (option) `sops` | jamais de tokens en clair |

## 5. Critères de validation avant de commencer la doc 03

- [ ] 3 serveurs identiques reçus, câblés, alimentés, dans le rack
- [ ] 2 switchs interconnectés ; liens nœuds + management câblés
- [ ] Ping inter-nœuds < 5 ms stable **sans charge** et **sous charge** (test iperf parallèle)
- [ ] NTP testé depuis un poste temporaire (les nœuds seront réglés en doc 03)
- [ ] Plan d'adressage ci-dessus rempli (pas de conflit avec le réseau existant)
- [ ] ISO PVE 9 téléchargée + vérification du **checksum** (procédure en doc 03)
- [ ] Comptes et accès admin au réseau définis (qui a accès au cluster ? 2FA prévu en doc 09)

---

**Sources officielles** : [Proxmox HA](https://pve.proxmox.com/wiki/High_Availability), [Cluster Manager](https://pve.proxmox.com/pve-docs/chapter-pvecm.html) (latence < 5 ms, lien dédié), [Storage Replication](https://pve.proxmox.com/pve-docs/chapter-pvesr.html).