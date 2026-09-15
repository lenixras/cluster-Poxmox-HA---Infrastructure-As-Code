# Sécurité, firewall et gestion des secrets

> Objectif : passer d'un PVE « fonctionnel » (défauts) à un environnement durci et auditable.
> Sources : [documentation firewall PVE](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html),
> [security & identity PVE](https://pve.proxmox.com/pve-docs/), guides de durcissement communautaires 2026.

---

## 1. Modèle de confiance

- Le cluster n'est **jamais exposé à Internet** (8006/22 derrière VPN ou subnet admin).
- Source unique de vérité des rôles : groupes de personnes ≠ groupes de VMs, rôles étroits.
- Automatisation = tokens API (jamais de comptes humains ni de mots de passe dans le code).

## 2. Firewall Proxmox (datacenter puis nœuds)

Activer le firewall **cluster-wide** et passer en défaut **drop** :

```bash
pvesh set /cluster/firewall/options -enable 1 -policy_in DROP -policy_out ACCEPT
# (penser à activer aussi au niveau nœud : Node → Firewall → Options → nftables / enable)
```

Règles d'ouverture (depuis un IPset `mgmt_net` vers le datacenter) :

```bash
pvesh create /cluster/firewall/ipset mgmt_net
pvesh create /cluster/firewall/ipset/mgmt_net/cidr --cidr 192.168.1.0/24
pvesh create /cluster/firewall/ipset/mgmt_net/cidr --cidr 10.10.200.0/24  # pool VPN

# GUI + SSH seulement depuis l'IPset admin
pvesh create /cluster/firewall/rules --action ACCEPT --source mgmt_net --dport 8006 --proto tcp --type in
pvesh create /cluster/firewall/rules --action ACCEPT --source mgmt_net --dport 22   --proto tcp --type in

# Corosync entre nœuds (UDP 5405-5412) — auto-créée par PVE si le firewall est actif ;
# sinon l'ouvrir explicitement entre les IP corosync :
pvesh create /cluster/firewall/rules --action ACCEPT --source 10.10.0.0/24 --proto udp --dport 5405:5412 --type in
```

Défenses supplémentaires (doc firewall PVE) :

- Activer `protection_synflood`, `tcpflags` (filtre flags TCP), `nosmurfs`, `log_level_in info` (audit des drops).
- Au niveau VM : activer le firewall sur l'interface + règles par VM (segmentation **est-ouest** : empêcher
  qu'une VM compromise sonde les autres). Aussi `policy_forward DROP` au datacenter.
- **Ordre des règles** : allow explicites d'abord, log avant drop, catch-all à la fin.

### Fichiers concernés (via pmxcfs, se propagent partout)

```
/etc/pve/firewall/cluster.fw                # options + règles datacenter
/etc/pve/nodes/<node>/host.fw               # règles par nœud
/etc/pve/firewall/ipset/…  / etc/pve/firewall/groups/…
```

## 3. Authentification

### 3.1. 2FA (TOTP) pour les humains

```bash
pveum user modify root@pam --otp-type totp    # affiche un QR code + clé
# puis configurer un 2e facteur (WebAuthn/Yubikey) pour les comptes admin
```

> Le TOTP seul ne suffit pas pour WebAuthn : il faut un certificat **de confiance** (point 5). Prévoir aussi un code de secours conservé hors-ligne (procédure RB-05).

### 3.2. Utilisateurs et rôles — principe du moindre privilège

| Sujet | Rôle / chemin | Note |
|---|---|---|
| Humains « opérateur VMs » | `PVEVMAdmin` sur `/vms` ou pools | pas d'accès `/` |
| Humains « cluster admin » | `Administrator` (petit groupe) | groupe séparé, audit régulier |
| `terraform@pve` | rôle étroit (doc 05) | token bearer, rotation |
| `ansible@pve` | rôle étroit (doc 06) | token bearer, rotation |

Audit trimestriel : `pveum acl list`, `pveum user list`, `pveum user token list` — révoquer tout ce qui est inutile.

## 4. Durcissement des nœuds (SSH, fail2ban, updates)

```bash
# /etc/ssh/sshd_config (sur chaque nœud)
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 3
AllowUsers root       # restreindre ~ root admin ; pas de comptes partagés
```

> Ne pas définir `PermitRootLogin no` ni `AllowTcpForwarding no` globalement : PVE utilise le SSH
> root pour les réplications/migrations internes. On contourne en restreignant par `Match Address`.
> Source : [guide durcissement PVE 9](https://github.com/HomeSecExplorer/Proxmox-Hardening-Guide).

fail2ban (bruteforce du portail 8006) — jail configurée dans Ansible :

```ini
[pveproxy]
enabled = true
port    = 8006,https
filter  = pveproxy
logpath = /var/log/pveproxy/access.log
maxretry = 5
bantime  = 3600
findtime = 600
```

Mises à jour automatiques de sécurité (`unattended-upgrades`), **sans** reboot automatique — les reboots
se font en maintenance planifiée (RB-03). Dépêche liée : obturer les paquets Proxmox (`pve-no-subscription`).

## 5. Certificats (remplacer le self-signed)

- **Option 1 — ACME (Let's Encrypt)**, intégré : Datacenter → ACME → compte + plugin (dns-challenge si pas de port 80 publique) → par nœud : « Order Certificates ». Renouvellement auto (~60 j). Requis pour WebAuthn.
- **Option 2 — CA interne** (environnement air-gap) : générer via votre PKI + importer
  (`Node → Certificates → Upload`). Aussi utilisé pour le provider Terraform (`insecure=false`).

## 6. Secrets : où, comment, jamais

| Secret | Stockage | Rotation |
|---|---|---|
| Token `terraform@pve` | Vault / gestionnaire de secrets ; `terraform.tfvars` gitignoré | planifiée + immédiate si suspicion |
| Token `ansible@pve` | `group_vars/all/vault.yml` (Ansible Vault) | idem |
| Mots de passe PBS | Vault | régulière |
| Clés SSH | fichiers protégés (`700`) | selon politique |
| Clés d'encryption PBS | hors-ligne / coffre | documentée (RB-05) |

- `ansible-vault`: secrets chiffrés dans le repo ; jamais en clair.
- SOPS (« secrets as code ») : `.sops.yaml` pour Terraform (`sops -e terraform.tfvars`).
- Utilisation optionnelle de **HashiCorp Vault** en VM (`community.hashi_vault` dans Ansible, lookup runtime).
- Ne **jamais** : committer un token, logguer un mot de passe, stocker un `.tfstate` en clair.

Audit : `grep -rEi "(token|password|secret)" . --include="*.tf" --include="*.yml"` → aucune valeur réelle.

## 7. Checklist de validation sécurité

- [ ] depuis un réseau hors admin : `8006` et `22` **injoignables**
- [ ] `nft list ruleset` : drops entre VM ; `pve-firewall status` actif sur les 3 nœuds
- [ ] TOTP exigé pour tout utilisateur humain ; tokens API purs pour l'automatisation
- [ ] `ss -lntp` : 8006 en écoute (pas exposé), SSH en clés seules
- [ ] `certbot` / ACME : certificat de confiance sur `https://pve1:8006`
- [ ] `unattended-upgrades` actif, reboot **jamais** automatique
- [ ] aucun secret en clair dans le repo (`grep` ci-dessus propre) ; `.gitignore` exclut `*.tfvars`, `.tfstate`, `*.sops.*`