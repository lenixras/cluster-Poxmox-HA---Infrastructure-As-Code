# Réseaux, DNS interne et VLANs

> Objectifs : écrire le plan de segmentation, router proprement les 4 plans, publier un service
> DNS interne `cluster.local` et (option) une IP flottante pour les services.
> Références : [PVE — network](https://pve.proxmox.com/pve-docs/chapter-sysadmin.html), [wiki /etc/network](https://pve.proxmox.com/wiki/Network_Configuration)

---

## 1. Plan réseau final (à figer dans l'inventaire)

| Réseau | Subnet | Passerelle (VM) | Vlan (si taggé) | Rôle |
|---|---|---|---|---|
| Management | `192.168.1.0/24` | physique | 1 | GUI 8006, SSH |
| Corosync | `10.10.0.0/24` | — (nœuds seulement) | 10 | heartbeat knet |
| VM | `10.10.10.0/24` | `10.10.10.1` | 20 | invités |
| Backup | `10.10.30.0/24` | `10.10.30.1` | 30 | nœuds ↔ PBS |

**Règles** : Corosync isolé loin du trafic volumineux ; VM et backup séparés pour ne pas saturer le lien
de migration ; management trop exposé → doc 09.

## 2. Interfaces avec VLAN tagging (exemple nœud, un seul NIC physique)

Si vous ne disposiez que d'un seul uplink, on segmente en VLANs (nettement moins bon pour Corosync
que la voie physique dédiée — réserver au minimum une NIC physique à Corosync) :

```
auto vmbr2
iface vmbr2 inet static
    bridge-ports eno3.20
    ...
```

Ou bien un **bond LACP** avec VLANs par bridge :

```
auto bond0
iface bond0 inet manual
    bond-slaves eno3 eno4
    bond-mode 802.3ad
    bond-miimon 100
    bond-lacp-rate fast

auto vmbr2                    # subnet VM taggé VLAN 20
iface vmbr2 inet static
    address 10.10.10.1/24
    bridge-ports bond0.20
    bridge-stp off
    bridge-fd 0
```

> ⚠️ **bond-lacp-rate fast** impératif si un lien Corosync utilise le LACP (défaut slow → ~90 s de
> failover > 60 s du watchdog → fencing accidentels). Voir [document Corosync](https://pve.proxmox.com/pve-docs/chapter-pvecm.html).

## 3. Convergence réseau inter-nœuds

Test de robustesse à refaire régulièrement (trame de doc 12) :

```bash
# latence / jitter corosync :
ping -f -c 1000 10.10.0.2
# bande passante simulée (parallèle) sur le lien management :
iperf3 -s &    # sur pve2
iperf3 -c pve2 # sur pve1
```

La **latence** (pas le débit) doit rester < 5 ms même sous charge de migration/sauvegarde.
Si l'uplink VM et Corosync partagent un lien et se congestionnent → fencing intempestif : séparer.

## 4. DNS interne — serveur `dns01` (VM Ubuntu), zone `cluster.local`

### 4.1. Sur la VM `dns01` (déployée via Terraform, doc 05)

```bash
apt install -y bind9 dnsutils
```

### 4.2. Zones (fichier `/etc/bind/named.conf.local`)

```bind
zone "cluster.local" {
    type master;
    file "/etc/bind/db.cluster.local";
};

zone "10.10.10.in-addr.arpa" {
    type master;
    file "/etc/bind/db.10.10.10";
};
```

### 4.3. Zone directe `/etc/bind/db.cluster.local`

```bind
$TTL 300
@       IN SOA  dns01.cluster.local. admin.cluster.local. (
                2026010101 ; serial
                3600       ; refresh
                900        ; retry
                604800     ; expire
                300 )      ; negative TTL

                NS      dns01.cluster.local.

dns01           A       10.10.10.20
pve1            A       192.168.1.10
pve2            A       192.168.1.11
pve3            A       192.168.1.12
pbs             A       10.10.30.10
monitoring      A       10.10.10.30
app             A       10.10.10.40
```

> Générez cette zone depuis l'inventaire Ansible (template Jinja) plutôt qu'à la main : une seule source de vérité.

### 4.4. Propagation

- Tous les nœuds PVE : `/etc/resolv.conf` → `nameserver 10.10.10.20` (`nameserver dns01` si la VM n'est pas encore là) + `search cluster.local`.
- Box/DHCP : option `domain-name-servers 10.10.10.20`, `domain-search cluster.local`.
- Configurer le **forwarder** vers les root/public (1.1.1.1) pour Internet.
- Vérifier : `dig app.cluster.local @dns01` ; `nslookup 10.10.10.30` (réverse).

## 5. IP flottante applicative (option VRRP)

Pour les services qui ne suivent pas les VMs (reverse proxy, pass…) sur 2 VMs :

```bash
# sur app01 et app02 (Ubuntu) :
apt install -y keepalived
# /etc/keepalived/keepalived.conf (IDENTIQUE sur les 2, seul state/priority diffère)
vrrp_instance VI_1 {
    state MASTER            # app02 : BACKUP
    interface ens18         # dans le réseau VM
    virtual_router_id 55
    priority 100            # app02 : 90
    advert_int 1
    virtual_ipaddress { 10.10.10.200/24 }
}
systemctl enable --now keepalived
```

L'IP virtuelle `10.10.10.200` suit le nœud actif → le HA du VM + VRRP donnent une **IP stable** en bascule.

## 6. Validation réseau/DNS

- [ ] `dig` (direct + réverse) OK depuis nœuds et VM
- [ ] latence corosync < 5 ms sous charge (test iperf en parallèle)
- [ ] bascule câble : perte < 5 s (bond LACP fast)
- [ ] `ip addr` → les 4 plans affichés sur chaque nœud, aucune IP en trop
- [ ] VRRP (si actif) : `ip a` montre 10.10.10.200 sur un seul VRRP à la fois