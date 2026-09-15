# RB-04 — Reconstruction complète du cluster (disaster recovery)

**Objectif** : reconstruire un cluster **de zéro** (nœud(s) perdu(s), réinstallation complète) à partir
de ce dépôt Git + du PBS — **sans données perdues**.

> Pré-requis forts : le dépôt Git est à jour (doc 06/13), les backups PBS existent, la clé d'encryption
> PBS est disponible (RB-05), et au moins 1 nœud survivant ou du matériel neuf.

---

## 1. Inventaire des ressources

- [ ] Dis faire **tout ce qui vit sur le cluster** : VMs + templates cloud-init + config (`/etc/pve`) +
  règles HA + pool zfspool + réplications.
- [ ] Confirmer l'état PBS : `proxmox-backup-server` accessible, datastores listés, **backups récents** :

```bash
# depuis PBS :
proxmox-backup-manager datastore list
proxmox-backup-manager task list datastore1 | head      # derniers jobs
```

## 2. Reconstruction des nœuds (0 → cluster)

1. Réinstaller PVE 9 (doc 03) — **même** adressage, mêmes hostnames, clés SSH en place.
2. Créer les pools ZFS data : `zpool create tank mirror <disks>` + `zfs create tank/vm`.
3. Créer le cluster : `pvecm create ha-cluster --link0 … ` puis joindre (doc 04).
4. Réenregistrer le datastore `tank` (`pvesm add zfspool tank --pool tank/vm --content images,rootdir`).
5. Réappliquer toute la config via Ansible :

```bash
cd ansible
ansible-playbook -i inventory.yml playbooks/site.yml    # cluster, base, firewall, etc.
```

## 3. Restauration des VMs depuis PBS

```bash
# depuis l'UI PBS ou CLI, lister les backups de chaque VM :
pvesm list datastore1
# restauration complète (nouveau VMID ou même VMID si détruit) :
qmrestore /mnt/datastore1/datastore1/dump/vzdump-qemu-100-*.vma.zst 100 --storage tank
```

- [ ] Check **chiffrement** : les VMs chiffrées ne se restaurent que **avec** la bonne clé (RB-05).
- [ ] Remettre les **réplications** `pvesr` en place (doc 04) — elles ne survivent pas à la destruction.
- [ ] Re-déclarer les ressources **HA** : `ha-manager add vm:100 --state started` … (doc 07).

## 4. Réactivation HA complète

```bash
pvecm status ; ha-manager status        # quorate + watchdogs armed
# règles d'affinité (doc 07) re-créées
```

## 5. Validation finale (disaster-recovery)

Execute: [`docs/templates/checklist-verif-cluster.md`](../templates/checklist-verif-cluster.md) complète.

- [ ] `pvecm status` quorate ;
- [ ] Toutes les VMs critiques restaurées et démarrées (cas de test : script `for vmid …; do qm status…` ) ;
- [ ] Réplications `pvesr status` ≤ intervalle, pour toutes les VMs ;
- [ ] Backup de ce nouvel état `vzdump` → PBS OK (la boucle est refermée) ;
- [ ] Le dépôt Git reflète la réalité finale (diff 0 sur le playbook).