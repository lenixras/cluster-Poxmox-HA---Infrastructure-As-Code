# RB-03 — Mise à niveau de Proxmox VE (upgrade, par nœud)

**Objectif** : passer les 3 nœuds à une nouvelle version (`pve-manager`), **en série**, sans perte de quorum
ni interruption. Règle d'or : **1 nœud → après validation → le suivant**.

---

## 0. Avant de commencer

- [ ] **Backup** : PBS récent de toutes les VMs (< SLA) — on peut régresser.
- [ ] **Snapshot/état de référence** : aucune règle HA incohérente, `pvecm status` quorate.
- [ ] **Enregistrer les versions** : `pveversion -v` sur les 3 nœuds.
- [ ] **Retirer des dépôts**

| Repère | Vérif |
|---|---|
| Versions actuelles | `pveversion -v` |
| Note de version cible | <https://pve.proxmox.com/wiki/Roadmap> |
| Backups récents | freshness < 24 h |

## 1. Suite logique (par nœud, ex. pve1 en premier)

### 1.1 Préparer le nœud

```bash
# depuis pve1 (le nœud à mettre à jour) :
apt update && apt list --upgradable
apt full-upgrade -y             # package pve-qemu-kvm, pve-kernel…
```

> Les packages de migration PVE (pve-kernel…) requièrent souvent un reboot. On ne reboot que après
> bascule éventuelle des VMs.

### 1.2 Désarmer la maintenance

```bash
# si le nœud héberge des ressources HA :
ha-manager crm-command disarm-ha freeze
# migrer l'éventuel reste :
ha-manager crm-command migrate vm:100 pve2
reboot
```

En cas de **major/minor** (ex. 8.x→9.x) : suivre particulièrement les notes de version et la doc
« Upgrading » (quorum, cohérence pmxcfs, compatibilité alerts/notifications).

### 1.3 Post-reboot & validation (pve1)

```bash
pveversion -v                       # nouvelle version affichée
pvecm status                        # quorate, pve1 de retour
ha-manager crm-command arm-ha       # ré-armer (!!)
ha-manager status ; pvesr status ; zpool status
systemctl status pve-cluster corosync
# Retest watchdog (doc 04/12) :
lsmod | grep watchdog ; cat /proc/sys/kernel/watchdog   # etc.
```

> ⚠️ Après chaque mise à jour **kernel**, tester le watchdog AVANT de passer au nœud suivant
> (un softdog perdu après reboot = chaîne HA cassée EN SILENCE).

## 2. Enchaîner sur pve2 puis pve3

Refaire 1.1→1.3 pour chaque nœud, **sans chevaucher** : le nœud suivant ne doit commencer que lorsque
le précédent est **validé** (checklist complète).

## 3. Fin d'upgrade

- [ ] `pveversion -v` : **mêmes** versions sur 3 nœuds (exigence cluster).
- [ ] `pvecm status` quorate, watchdogs armed ×3.
- [ ] Bascules de test rapides (doc 12, S2 au moins) pour prouver la chaîne post-update.
- [ ] Re-run `ansible-playbook --check` → idempotence intacte.
- [ ] Note de version + changelog archivent dans le registre (doc 13).

## 4. Cas particuliers / pannes

| Symptôme | Démarche |
|---|---|
| Quorum instable après update | un nœud périmet à partir à la panne : le RA auto-fence sera la bouée ; revenir en arrière du nœud fautif |
| paquet bloqué (`dpkg` cassé) | `dpkg --configure -a` puis re-tenter ; rechercher dans les logs d'upgrade |
| watchdog absent post-kernel | module softdog manquant → recharger/ajouter dans `/etc/modules` ; ne pas continuer la série |

> Règle capitale : **jamais 2 nœuds en maintenance simultanément** → toujours 2/3 quorate et capacités de bascule intactes.