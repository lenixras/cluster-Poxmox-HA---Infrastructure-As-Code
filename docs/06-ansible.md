# Configuration et orchestration avec Ansible

> Outil : **ansible-core ≥ 2.16** + collection **`community.proxmox`** (modules API, ex. `proxmox_cluster`)
> + roles maison. Références : [collections docs](https://docs.ansible.com/ansible/latest/collections/community/proxmox/index.html).
> Objectifs : faire du cluster un **état de code idempotent** (ré-exécution = 0 changement).

---

## 1. Arborescence `ansible/`

```
ansible/
├── ansible.cfg
├── requirements.yml           # collections à installer
├── inventory.yml              # ← copie de inventory.example.yml (racine) adaptée
├── group_vars/
│   ├── all/vars.yml           # variables communes (réseaux, domaine)
│   └── all/vault.yml          # secrets chiffrés (ansible-vault)
├── playbooks/
│   ├── 00-cluster.yml         # jointure/santé du cluster (API)
│   ├── 01-base.yml            # durcissement SSH/NTP/UFW/PVE-firewall
│   ├── 02-storage.yml         # pools ZFS + datastores + jobs de réplication
│   ├── 03-monitoring.yml      # exporters + prometheus + grafana (VM monitoring)
│   ├── 04-services.yml        # services applicatifs (docker compose…)
│   └── site.yml               # orchestre tout (avec --tags)
└── roles/
    ├── base/  cluster/  storage/  monitoring/  services/
```

### ansible.cfg

```ini
[defaults]
inventory      = inventory.yml
remote_user    = root
host_key_checking = False
roles_path     = roles
collections_path = collections
ansible_python_interpreter = /usr/bin/python3
ask_vault_pass = True
```

### requirements.yml

```yaml
collections:
  - name: community.proxmox      # modules proxmox_kvm, proxmox_cluster, proxmox_cluster_ha_*
    version: ">=1.1.0"
  - name: community.general
  - name: community.docker      # pour les services applicatifs
```

```bash
ansible-galaxy collection install -r requirements.yml
# dépendance Python des modules API :
pip install proxmoxer
```

## 2. Inventaire et secrets (Vault)

Inventaire : voir [`../inventory.example.yml`](../inventory.example.yml) (racine). Points clés :

- groupes `pve` (nœuds) et `vms` (guests) ;
- variables non secrètes dans `group_vars/all/vars.yml` ;
- secrets (token API, passwords) dans `group_vars/all/vault.yml`.

```bash
ansible-vault create group_vars/all/vault.yml
#   vault_proxmox_api_token_secret: "xxxxxxxx"
#   vault_pbs_password: "secret-pbs"
ansible-vault view group_vars/all/vault.yml
```

## 3. Sensibiliser l'API : créer le compte Ansible

```bash
pveum user add ansible@pve --comment "Ansible cluster API"
pveum role add AnsibleRole --privs \
  "Datastore.Allocate Datastore.AllocateSpace Datastore.Audit Pool.Allocate Sys.Audit Sys.Modify VM.Allocate VM.Audit VM.Backup VM.Clone VM.Config.* VM.Monitor VM.PowerMgmt SDN.Use Permissions.Modify"
pveum aclmod / -user ansible@pve -role AnsibleRole
pveum user token add ansible@pve ansible-token --privsep=1
```

## 4. Playbook : s'assurer que le cluster est créé (API, sans SSH)

Modules documentés : `proxmox_cluster` (création), `proxmox_cluster_join_info`, `proxmox_cluster_status_info`.

```yaml
# playbooks/00-cluster.yml
- name: Assurer l'état du cluster Proxmox
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - ../group_vars/all/vault.yml
  tasks:
    - name: Créer le cluster (si absent) — exécuté contre pve1
      community.proxmox.proxmox_cluster:
        api_host: "{{ proxmox_api_host }}"
        api_user: "{{ proxmox_api_user }}"
        api_token_id: ansible-token
        api_token_secret: "{{ vault_proxmox_api_token_secret }}"
        validate_certs: false
        state: present
        cluster_name: ha-cluster
        link0: "{{ hostvars.pve1.pve_corosync_ip }}"
        link1: "{{ hostvars.pve1.ansible_host }}"

    - name: Joindre pve2 et pve3 au cluster
      community.proxmox.proxmox_cluster:
        api_host: "{{ item }}"
        api_user: "{{ proxmox_api_user }}"
        api_token_id: ansible-token
        api_token_secret: "{{ vault_proxmox_api_token_secret }}"
        validate_certs: false
        state: present
        master_ip: "{{ proxmox_api_host }}"
        # fingerprint : récupérer via proxmox_cluster_join_info sur pve1
    loop: [pve2, pve3]
```

> `proxmox_cluster_join_info` retourne `fingerprint` : l'enregistrer dans une variable, ne pas le hard-coder.

## 5. Playbook base (durcissement nœuds, over SSH)

```yaml
# playbooks/01-base.yml
- name: Durcir les nœuds Proxmox
  hosts: pve
  become: true
  roles:
    - role: base
      vars:
        ntp_servers: ["ntp.local", "0.debian.pool.ntp.org", "1.debian.pool.ntp.org"]
        ssh_password_auth: false
        fail2ban_enabled: true
        pve_firewall_policy_in: DROP
```

Le rôle `base` doit réaliser (voir doc 09 pour le détail) :
- SSH : clés seulement, `PermitRootLogin prohibit-password`, `AllowUsers root` restreint aux réseaux admin ;
- `unattended-upgrades` (pas de reboot auto) ;
- `fail2ban` sur `/var/log/pveproxy/access.log` (protection du portail 8006) ;
- règles PVE firewall (datacenter + nœud) via les modules `proxmox_cluster_firewall` / `proxmox_node_firewall`.

## 6. Exécution

```bash
cd ansible
ansible-playbook -i inventory.yml playbooks/site.yml --tags cluster,base,storage
ansible-playbook -i inventory.yml playbooks/site.yml --check   # idempotence
```

**Règle d'équipe** (issue de la [pratique « cluster as code »](https://ilia.ae/en/blog/digital/proxmox-cluster-infrastructure-as-code/)) :
*chaque correction manuelle est reinjectée en code avant validation de la tâche*.

## 7. Validation

- [ ] `ansible-playbook --check` → `changed` = 0 sur un cluster à l'état stable
- [ ] `ansible-lint` passe sans erreur bloquante
- [ ] le re-jeu d'un playbook après un incident ne « répare » rien par accident (toute la vérité vient du code)
- [ ] `proxmox_cluster_status_info` confirme 3 nœuds + quorum

---

Résultat : configuration exprimée en code. Enchaîner avec [`07-ha.md`](07-ha.md) pour la bascule automatique.