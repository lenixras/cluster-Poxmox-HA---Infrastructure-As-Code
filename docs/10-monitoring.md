# Supervision, logs et alertes

> Objectif : une visibilité **cluster-wide** (nœuds, VMs, ZFS, quorum, jobs de réplication et backups)
> + alerte précoce. La supervision s'exécute **hors du cluster** (VM `monitoring01` répliquée et HA,
> mais les données de supervision peuvent être re-créées — ne pas y mettre la pérennité).
> Sources : [Monitoring/observability PVE](https://pve.proxmox.com/pve-docs/), [prometheus-pve-exporter](https://github.com/prometheus-pve/prometheus-pve-exporter).

---

## 1. Architecture de collecte

```
Nœud PVE (pve1..3)  API 8006  ──┬──> prometheus-pve-exporter :9221 ──> Prometheus :9090 ──> Grafana :3000
    ZFS /disques  ──────────────┴──> node_exporter (textfile + zfs collector)
    journald ───syslog──> rsyslog (nœud) ──> Loki :3100 ──> Grafana
PBS      API 8007 ──> exporter PBS ──> Prometheus
                    PVE Notifications (SMTP/webhook) : fencing, backups  →  chat/mail
```

## 2. Exposant Proxmox (`prometheus-pve-exporter`)

Un seul exporteur couvre le **cluster entier** (l'API renvoie tout). Config `/etc/prometheus/pve-exporter/pve.yml` :

```yaml
default:
  user: prometheus@pve
  token_name: exporter
  token_value: "XXXX-…-XXXX"     # secret → injecté par Ansible/Vault
  verify_ssl: false              # true avec cert ACME (doc 09)
```

Utilisateur API **lecture seule** (`PVEAuditor` + token) — jamais d'écriture :

```bash
pveum user add prometheus@pve
pveum role add AuditRead --privs "Sys.Audit VM.Audit Datastore.Audit Pool.Audit"
pveum aclmod / -user prometheus@pve -role AuditRead
pveum user token add prometheus@pve exporter --privsep=1
```

Scrape Prometheus (mode multi-target : le **cible** est le nœud, pas l'exporteur) :

```yaml
scrape_configs:
  - job_name: proxmox
    metrics_path: /pve
    params:
      module: [default]
      cluster: ["1"]
      node: ["1"]
    static_configs:
      - targets: ["10.10.10.30:9221"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
        replacement: pve1
      - target_label: __address__
        replacement: 10.10.10.30:9221
```

Métriques clés : `pve_node_status`, `pve_cpu_usage_ratio`, `pve_memory_usage_bytes`,
`pve_guest_info`, `pve_guest_status`, `pve_disk_usage_bytes`, et depuis v3.5+ `pve_ha_*`, `pve_lock_state`.

## 3. ZFS + disques (node_exporter)

```bash
# sur chaque nœud : node_exporter avec collecteurs ZFS et disque
node_exporter --collector.zfs --collector.diskstats --collector.textfile.directory=/var/lib/node_exporter

# santé ZFS en texte (JSON à la volée) → alertes scrub/health
zpool status -x > /var/lib/node_exporter/zpool_status.prom   # via cron/systemd-timer
```

Alertes type : `HEALTH_WARN`, pool > 80 %, disk SMART pending.

## 4. Loki (logs centralisés)

- journald des nœuds → rsyslog → Loki. Activer dans `/etc/systemd/journald.conf` :
  `ForwardToSyslog=yes` puis `systemctl restart systemd-journald`.
- Rétention ≥ 30 jours (les post-mortems s'appuient sur ces journaux).

## 5. Alertes (Alertmanager → notifications)

Règles minimales exploitables (Prometheus) :

| Alerte | Expression (ex.) | Sévérité |
|---|---|---|
| Nœud down | `pve_node_status{id=~"node/.*"} == 0` | critical |
| VM/CT down inattendu | `pve_guest_status ... == 0` | warning→critical |
| Perte de quorum | `corosync_quorum_votes_total < expected` | critical |
| HA ressource en panne | `pve_ha_state != "started"` | critical |
| Réplication en retard | `time() - last pvesr sync > 15 min` | warning |
| ZFS dégradé | test textfile `zpool` ≠ ONLINE | critical |
| Pool > 85 % | `pve_disk_usage_bytes / size > 0.85` | warning |
| Backup stale (> 48 h) | depuis exporter PBS | critical |

Tableau de bord de départ : **Grafana dashboard PVE 10347** (nœuds) et **15356** (cluster).

## 6. Notifications natives Proxmox

Datacenter → Notifications → cibles SMTP + Webhook (Gotify) puis **matchers** pour router :
- Fencing/Ceph-AER → canal on-call ;
- backup/replication → canal backups.

> Depuis PVE 9.x, préférer le **système de notifications** au « sendmail legacy » (déprécié) des jobs de backup.

## 7. Validation

- [ ] `/pve` scrape → séries `pve_node_status{node=…}` actives pour pve1..3
- [ ] dashboards Grafana 10347 + 15356 peuplés (cluster, nœuds, VMs, stockage)
- [ ] alerte de test : arrêt volontaire d'une VM non critique → notification reçue < 1 min
- [ ] un journal de `pvecm status` hors-quorum déclenche l'alerte
- [ ] rétention Loki ≥ 30 j et dashboards d'audit (login 8006, modifications ACL…)

---

Résultat : le cluster surveille et prévient. Vient ensuite la **sauvegarde** : [`11-backup-restore.md`](11-backup-restore.md).