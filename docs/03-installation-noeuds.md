# Installation des nœuds Proxmox — de A à Z

> Étapes à répéter **sur chacun des 3 nœuds** (les valeurs exactes diffèrent selon nœud : IP, hostname).
> Durée estimée : ~2 h par nœud. Reproduire ensuite [`04-cluster-zfs-replication.md`](04-cluster-zfs-replication.md).

## 0. Téléchargement officiel et vérification

**Sources officielles :**
- Proxmox VE ISO : <https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso>
- Miroir ISO direct (versions actuelles) : <https://iso.proxmox.com/iso/>

```bash
# Télécharger la dernière ISO stable PVE 9.x (liste et checksum sur la page de téléchargement)
wget https://iso.proxmox.com/iso/proxmox-ve_9.x-1.iso     # adapter le nom de fichier

# Vérifier l'intégrité avec le hash affiché sur le site officiel :
echo "<HASH_OFFICIEL>  proxmox-ve_9.x-1.iso" | sha256sum --check -
```

**Graver la clé USB** (outils recommandés) : Balena Etcher, Ventoy, ou `dd`.

## 1. Installation (écran d'installation)

- **Disques** : sélectionner les **2 disques OS** → option de partitionnement **`ZFS (RAID-1)`**
  (mirror ZFS). C'est le boot système redondant, requis pour un nœud fiable.
- **Options ZFS** : activer `checksum`, `compression lz4`, `ashift` = secteur natif du disque (12 pour 4K).
- **Hostname** : `pve1.cluster.local` (puis `pve2…`, `pve3…`)
- **IP statique** : `192.168.1.10/24`, passerelle `192.168.1.1`
- **Pays/lieu + fuseau horaire** : Europe/Paris (ou votre TZ) — utilisé aussi par NTP.
- **Mot de passe root** fort, non partagé.

## 2. Vérification post-installation

```bash
pveversion -v              # doit afficher pve-manager/9.x ...
ip a                       # interface d'administration OK
df -h / && zpool list      # rpool (système) en ligne, MIRROR
cat /etc/hostname          # pve1
```

Accéder à l'interface : `https://192.168.1.10:8006` (certificat auto-signé pour l'instant → doc 09).

## 3. Réseau : interfaces + 4 réseaux

Sur chaque nœud, adapter `/etc/network/interfaces`. Exemple **pve1** (hostname identique sur les 3, seules les IP changent) :

```
auto lo
iface lo inet loopback

# ---- Réseau 1 : Management (VM-gestion, API, SSH) ----
auto eno1
iface eno1 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0

# ---- Réseau 2 : Corosync (DÉDIÉ, basse latence) ----
auto eno2
iface eno2 inet static
    address 10.10.0.1/24

# ---- Réseau 3 : VM / invités ----
auto eno3
iface eno3 inet manual

auto vmbr2
iface vmbr2 inet static
    address 10.10.10.1/24
    bridge-ports eno3
    bridge-stp off
    bridge-fd 0

# ---- Réseau 4 : Backup (nœuds ↔ PBS) ----
auto eno4
iface eno4 inet manual

auto vmbr3
iface vmbr3 inet static
    address 10.10.30.1/24
    bridge-ports eno4
    bridge-stp off
    bridge-fd 0
```

Adaptations selon matériel : remplacer `enoX` par vos noms (`ip link`). Pour la redondance de lien,
utiliser un **bond LACP** (`bond-mode 802.3ad`, `bond-lacp-rate fast` — important pour Corosync) en
`bridge-ports bond0`. Voir [`08-reseau-dns-vlan.md`](08-reseau-dns-vlan.md).

> ⚠️ Modifier le réseau = **risque de coupure**. Gardez une console physique/KVM ouverte.
> Après application, reconnecter via la nouvelle IP avant de rebooter.

```bash
ifreload -a          # recharge la configuration réseau
hostnamectl set-hostname pve1 && hostnamectl set-hostname --transient pve1
ping -c3 10.10.0.2    # (sur pve2 : 10.10.0.1) → latence ≤ quelques ms
```

## 4. NTP — synchronisation (pré-requis Corosync)

La date/heure **doit** être synchro avant la création du cluster.

```bash
timedatectl set-ntp true
# Éditer /etc/systemd/timesyncd.conf et renseigner une pool locale fiable :
#   [Time]
#   NTP=ntp.local 0.debian.pool.ntp.org 1.debian.pool.ntp.org
systemctl restart systemd-timesyncd
timedatectl   # vérifier "System clock synchronized: yes"
chronyc sources -v   # si chrony est installé à la place
```

## 5. Dépôts et mise à jour

Proxmox VE 9 est basé sur Debian 13 (Trixie). Activer le dépôt communautaire :

```bash
# Désactiver le dépôt entreprise (réservé aux abonnés) pour éviter les erreurs apt :
rm /etc/apt/sources.list.d/pve-enterprise.list

# Dépôt no-subscription (le codename est celui de la base Debian = "trixie" pour PVE 9)
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve $(lsb_release -c -s) pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list

apt update && apt full-upgrade -y
```

**Contrôle des versions AVANT clustering** : les 3 nœuds doivent afficher le **même** `pve-manager`
après `pveversion -v`. Ne pas créer le cluster avec des versions différentes.

## 6. Durcissement minimal avant cluster

- `pve-firewall` (datacenter + nœud) : voir doc 09 — au minimum, fermer `8006`/`22` aux réseaux non-admin dès maintenant.
- SSH : clés seulement (`PasswordAuthentication no`), root autorisé en **clés seules** pour le clustering
  (`PermitRootLogin prohibit-password`) — ne PAS couper root complet, Proxmox s'en sert pour les migrations.
- `apt install -y unattended-upgrades` puis config (doc 09, pas de reboot automatique).

## 7. Validation « nœud prêt »

- [ ] `pveversion -v` identique sur les 3 nœuds
- [ ] `timedatectl` synchronisé ; `ping` corosync < 5 ms stable
- [ ] UI accessible `https://<ip-mgmt>:8006`
- [ ] `zpool list` → `rpool` en `MIRROR`, `zdatalist` des disques data encore libres
- [ ] Réseau des 4 plans fonctionnel après reboot (`systemctl reboot` + reconnexion)

---

Résultat : 3 nœuds PVE autonomes. Enchaîner avec la doc suivante.