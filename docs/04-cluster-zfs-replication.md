# Cluster Corosync + pools ZFS + réplication

> Pré-requis : nœuds installés et durcis (doc 03), 3 versions PVE identiques, NTP synchronisé.
> Objectifs : (1) créer le cluster 3 nœuds, (2) configurer le fencing (watchdog), (3) créer les pools ZFS data, (4) mettre en place la réplication `pvesr`.

---

## Partie A — Création du cluster (Corosync)

### A.1. Initialiser depuis `pve1`

```bash
# Lien 0 = corosync dédié (10.10.0.x) ; Lien 1 = redondance sur le réseau management (priorité basse)
pvecm create ha-cluster --link0 10.10.0.1 --link1 192.168.1.10
```

> `pvecm` configure knet (Kronosnet) : 2 liens, bascule automatique. Sur PVE ≥ 9.2, le
> `token_coefficient` par défaut est abaissé (125 ms) pour une reprise de membre plus rapide.
> Ne pas modifier sans comprendre les implications (fenêtres de timeouts vs. watchdog).

### A.2. Joindre `pve2` et `pve3`

Depuis l'UI Web (Datacenter → Cluster → **Join Information**), récupérer le *fingerprint* et le *token* de jointure.
Sur chaque nœud à joindre :

```bash
pvecm add ha-cluster --token <TOKEN> --fingerprint <FINGERPRINT> --link0 10.10.0.2 --link1 192.168.1.11
# (sur pve3 : --link0 10.10.0.3 --link1 192.168.1.12)
```

### A.3. Vérifier l'état du cluster

```bash
pvecm status
#  Membership information
#      Vote quorum: 2
#      Expected votes: 3
#    Quorate: Yes
#      Nodeid  Name  Quorum Votes  ...   Status
#        1     pve1   1        1           Online, quorate
#        2     pve2   2        1           Online, quorate
#        3     pve3   3        1           Online, quorate

corosync-cfgtool -s        # 2 liens up sur chaque nœud (knet)
systemctl status pve-cluster
```

**Critère de validation** : `Quorate: Yes`, 3 nœuds en ligne. Un nœud peut tomber → 2 votes restent ≥ quorum 2 → le cluster survit.

## Partie B — Fencing / watchdog

Le fencing garantit qu'un nœud en panne **s'arrête vraiment** avant qu'une VM soit relancée ailleurs.

```bash
# Par défaut : softdog (kernel). Vérifier qu'il est bien armé :
lsmod | grep watchdog            # → softdog
cat /etc/default/pve-ha-manager  # → WATCHDOGE_DEVICE= / WATCHDOG_MODULE=softdog

# Option matériel (IPMI) : décommenter et définir le module
#   WATCHDOG_MODULE=ipmi_watchdog
#   (charger au boot : echo ipmi_watchdog >> /etc/modules ; reboot requis)
```

Après reconfig, redémarrer `watchdog-mux` et confirmer qu'il maintient `/dev/watchdog` ouvert :

```bash
systemctl restart watchdog-mux
ls -l /dev/watchdog*             # doit exister
systemctl status watchdog-mux    # active, markers présents sous /run/watchdog-mux.active/
```

Le **test réel** de fencing (perte de quorum → reboot sous ~60 s) est réalisé en doc 12. À ce stade, vérifier seulement que le chemin watchdog est en place.

## Partie C — Pools ZFS et stockage partagé logique

> Le HA Proxmox exige que les disques du VM soient **accessibles depuis le nœud de secours**.
> Avec ZFS local, cela passe par la **réplication** (pvesr) : le nœud cible possède une copie par snapshot.

### C.1. Créer un pool data par nœud

Sur **chaque nœud**, avec les disques data (ex. 2× NVMe) :

```bash
# Identifier les disques (depuis /dev/disk/by-id/)
ls -l /dev/disk/by-id/ | grep -i nvme

zpool create \
  -o ashift=12 -o autoexpand=on \
  -O compression=lz4 -O atime=off \
  tank mirror /dev/disk/by-id/nvme-<A> /dev/disk/by-id/nvme-<B>

zfs create tank/vm                # dataset accueillant les disques de VM
zfs list                          # tank / tank/vm
```

### C.2. Enregistrer le datastore `zfspool` dans Proxmox

Sur un nœud du cluster (se propage à tous via pmxcfs) :

```bash
pvesm add zfspool tank \
  --pool tank/vm \
  --content images,rootdir \
  --nodes pve1,pve2,pve3
pvesm status                      # tank : Active, actif sur les 3 nœuds
```

> Le datastore `tank` est déclaré **sur les 3 nœuds** pour que les migrations/réplications fonctionnent quelle que soit la cible. (Le plugin zfspool partagé est le composant normal pour réplication.)

### C.3. Créer les datastores complémentaires

```bash
# Images /ISO + snippets restent sur le stockage local de chaque nœud (créés par défaut)
pvesm status   # vérifier local & local-lvm (système)
```

## Partie D — Réplication (pvesr)

Créer **un job de réplication par VM critique**, pointant vers le nœud de secours.

### Via l'interface Web (recommandé)

1. Sélectionner la VM → onglet **Réplication** → **Ajouter**.
2. Nœud cible : `pve2` (si VM sur `pve1`) ; **planification** : `*/5` (toutes les 5 min).
3. Décocher « Répliquer uniquement les disques… » selon le besoin (par défaut : disques + cloud-init).
4. Enregistrer.

### Via CLI (équivalent)

```bash
# VM 100 vit sur pve1 → réplique vers pve2, toutes les 5 min, limite 100 MB/s
pvesr create-local-job 100-0 pve2 --schedule "*/5" --rate 100

# Répliquer aussi vers un second nœud (double protection)
pvesr create-local-job 100-1 pve3 --schedule "*/5" --rate 100
```

Exemple officiel : `pvesr create-local-job 100-0 pve1 --schedule "*/5" --rate 10`
([doc pvesr](https://pve.proxmox.com/pve-docs/chapter-pvesr.html)).

### Vérification

```bash
pvesr list                       # liste des jobs
pvesr status 100                 # dernière synchro, volume répliqué
# sur le nœud cible :
zfs list -t snapshot -r tank/vm  # devrait montrer snapshots de réplication (source@...)
```

**Noyau du fonctionnement** : la première exécution copie tout, les suivantes n'envoient que le **delta**
(snapshots ZFS). `RPO = intervalle programmé`.

> ⚠️ Après redémarrage du source, la réplication relance un full initial. Pendant un *live migration*,
> les jobs de réplication sont suspendus (le VM bascule de nœud, à re-créer ensuite selon le schéma).

## Partie E — Critères de validation finale

- [ ] `pvecm status` → Quorate, 3 nœuds, latence corosync OK
- [ ] `corosync-cfgtool -s` → 2 liens actifs knet
- [ ] `lsmod | grep watchdog` + `ha-manager status` (watchdog visible ; il passera `armed` en doc 07 quand HA sera activé)
- [ ] `pvesm status` → `tank` actif sur 3 nœuds
- [ ] Une VM de test : créée sur `tank/vm`, répliquée (`pvesr status` = `running`, dernier synchro récent)
- [ ] Timeline : un snapshot de réplication récent existe sur les nœuds cibles

---

Résultat : un cluster qualifié pour la haute disponibilité. Enchaîner avec :
- [`05-terraform.md`](05-terraform.md) — provisioning des VMs (les disques sur `tank/vm`) ;
- [`06-ansible.md`](06-ansible.md) — automatisation de la configuration ;
- [`07-ha.md`](07-ha.md) — activation du HA Manager.