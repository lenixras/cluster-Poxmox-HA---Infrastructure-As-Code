# Sauvegarde et restauration — Proxmox Backup Server

> **Principe** : le HA protège contre une panne matérielle ; **la sauvegarde protège contre tout le reste**
> (suppression, corruption logique, ransomware, erreur humaine). Le PBS est **hors du cluster**.
> Référence : [PBS docs](https://pbs.proxmox.com/wiki/), [PVE backup](https://pve.proxmox.com/wiki/Backup_and_Restore)

---

## 1. Déploiement du PBS

- **ISO officielle** : <https://www.proxmox.com/en/downloads/proxmox-backup-server/iso> (vérifier le checksum comme en doc 03).
- Installer sur une machine séparée (ou une VM du cluster **dont le disque vit sur un autre pool que ses homologues**) — idéalement un petit serveur ou une VM non volontaire.
- Réseau : `10.10.30.10` (réseau backup dédié).

```bash
# sur le PBS : créer le datastore
proxmox-backup-manager datastore create datastore1 --path /mnt/datastore1/datastore1
# (monter d'abord l'espace de stockage dédié — NAS ou disque local — dans /mnt/datastore1)
```

**Depuis PVE** : Datacenter → Storage → Ajouter → Proxmox Backup Server :
host `10.10.30.10`, user `root@pam`, datastore `datastore1`, fingerprint (coller celui du PBS).

## 2. Chiffrement (pré-requis à ne pas différer)

```bash
# côté PBS : créer une clé de chiffrement (à conserver hors-ligne !)
proxmox-backup-manager key generate --out /root/datastore1-encryption-key.pem
# stocker UNE copie chiffrée dans un coffre + une copie physique hors-ligne (RB-05)
```

- Cocher « Encrypted backup » dans Datastore → Backup sur PVE (la clé est optionnelle au niveau datastore PBS).
- **Test** : une restauration sans la bonne clé doit échouer (gain de confiance).

## 3. Stratégie des jobs (vzdump)

| Fréquence | Type | Rétention | Contenu |
|---|---|---|---|
| Quotidien | Incrémental | 7 jours (7 dernières générations) | toutes les VMs |
| Hebdomadaire | Full | 7 (≈ 2 mois) | VMs critiques |

Créer dans PVE : Datacenter → Backup → **Ajouter** (par datastore `datastore1`) ou via API :

```bash
pvesh create /cluster/backup \
  --storage datastore1 --mode snapshot --compress zstd \
  --schedule "21:00" --vmid 100,101,102,103,104,105 \
  --retention 7 --pool cluster_pool
```

> `mode snapshot` = snapshot live (léger), `compress zstd`. Le **pool** de VMs est la cible habituelle.
> Notification : configurer via le système de notifications (doc 10) — PAS le mode sendmail legacy.

## 4. Vérification (ce qu'on ne vérifie pas ne compte pas)

- **Vérification des chunks** : PBS vérifie l'intégrité des blocs (datastore → Verification Jobs) — lancer régulièrement, alerte si erreur.
- **Freshness** : alerte si aucun backup depuis 48 h (métrique exporter PBS, doc 10).
- **Test de restauration** au moins mensuel, planifié (doc 12 / RB-04).

## 5. Restauration — guide rapide

```bash
# Lister les backups d'une VM
pvesm list datastore1 | grep vm/100

# Restauration complète vers un autre nœud/datastore (simule une catastrophe)
qmrestore /mnt/datastore1/datastore1/dump/vzdump-qemu-100-*.vma.zst 110 \
  --storage tank --unique 1

# Cuisine de fichier (urgence) : PBS UI → Datastore → Backup → Restaurer → Restaurer fichier
```

## 6. RPO / RTO documents

| Repère | Valeur cible | Mesure |
|---|---|---|
| **RPO réplication** (HA) | ≤ 5 min | `pvesr status` (vérifier au quotidien) |
| **RPO backups PBS** | = intervalle job | dernier `vzdump` OK |
| **RTO incident nœud** | < 5 min | exercice doc 12 |
| **RTO catastrophe totale** | < 1 jour | exercice RB-04 |

## 7. Sauvegarde de la configuration cluster (souvent oubliée)

`/etc/pve` (pmxcfs) contient toute la config (ACL, tokens, firewall, pools). Une perte complète du cluster = perte de tout.

```bash
# dump périodique (root sur un nœud) dans le datastore PBS :
proxmox-backup-client backup root.pxar:/etc/pve \
  --repository root@pam@10.10.30.10:datastore1 --ns config
```

## 8. Validation

- [ ] job quotidien exécuté **sans erreur** depuis 7 nuits ; rétention effective
- [ ] chiffrement actif : restore échoue sans clé, réussit avec
- [ ] restauration complète d'une VM sur un **autre nœud** réussie (doc 12)
- [ ] freshness > 48 h → alerte critical (testée)
- [ ] dump `/etc/pve` présent et récent dans le PBS