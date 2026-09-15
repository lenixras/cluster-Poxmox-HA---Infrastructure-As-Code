# Checklist de vérification du cluster

> Utiliser **avant et après** chaque intervention (doc 13). Date : `____/____/____` —
> Intervenant(s) : `____________` — Type d'intervention : `____________`

## 1. Santé du cluster

| # | Contrôle | Commande | OK |
|---|---|---|---|
| 1 | Quorum | `pvecm status` → `Quorate: Yes`, 3 nœuds, votes 3 | ☐ |
| 2 | Liens Corosync | `corosync-cfgtool -s` → liens up | ☐ |
| 3 | Latence | `ping -f -c 1000 10.10.0.X` < 5 ms | ☐ |
| 4 | NTP | `timedatectl` → synchronized ; écart nœuds < 100 ms | ☐ |
| 5 | PVE versions identiques | `pveversion -v` sur les 3 nœuds | ☐ |

## 2. HA / watchdog

| # | Contrôle | Commande | OK |
|---|---|---|---|
| 6 | HA actif | `ha-manager status` → watchdogs `armed`, ressources `started` | ☐ |
| 7 | Ressources attendues | toutes les VMs critiques `started` sur leur nœud nominal | ☐ |
| 8 | Watchdogs nœuds | `lsmod \| grep watchdog` présent sur les 3 | ☐ |
| 9 | Pas de ressource `error`/`stopped` inattendue | `ha-manager status` | ☐ |

## 3. Stockage / réplication / backups

| # | Contrôle | Commande | OK |
|---|---|---|---|
| 10 | Datastores actifs | `pvesm status` → `tank`, `local` actifs | ☐ |
| 11 | Réplications à jour | `pvesr status` → dernière synchro ≤ intervalle (5 min) | ☐ |
| 12 | ZFS sain | `zpool status` → `ONLINE` sur les 3 pools | ☐ |
| 13 | Scrub ZFS récent | `zpool status` → dernier `scrub` < 7 j | ☐ |
| 14 | Dernier backup PBS | `pvesm list datastore1` / UI PBS → freshness < 24 h | ☐ |

## 4. Réseau / DNS

| # | Contrôle | Commande | OK |
|---|---|---|---|
| 15 | DNS interne | `dig app.cluster.local @10.10.10.20` → réponse | ☐ |
| 16 | Reverse | `nslookup 10.10.10.30` → nom | ☐ |
| 17 | 4 plans affichés | `ip addr` sur chaque nœud | ☐ |

## 5. Sécurité

| # | Contrôle | Commande | OK |
|---|---|---|---|
| 18 | Firewall actif | `pve-firewall status` ; `pvesh get /cluster/firewall/options` → enable 1 | ☐ |
| 19 | GUI/SSH non exposés | depuis un réseau outsider : `8006`/`22` injoignables | ☐ |
| 20 | 2FA + tokens | `pveum user list` ; user tokens à jour ; aucun compte partagé | ☐ |
| 21 | Aucun secret en clair | `grep -rEi "(token\\|password\\|secret)" ansible/ terraform/` | ☐ |

## 6. Supervision

| # | Contrôle | Commande | OK |
|---|---|---|---|
| 22 | Exporteur PVE up | `curl http://<mon>:9221/metrics` → séries `pve_node_*` | ☐ |
| 23 | Grafana | dashboard cluster 15356 peuplé | ☐ |
| 24 | Alerte de test reçue | (doc 10) | ☐ |

## 7. Bilan

Écarts constatés / actions : `________________________________________________________________`

Signature : `____________` — Recheck (si écart) : `____________`