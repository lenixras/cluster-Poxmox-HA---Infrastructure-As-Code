# Tests de bascule et de reprise après incident

> **Un HA non testé est une croyance, pas une capacité.** (ℹ️) La conformité se prouve en
> simulant les 3 modes de défaillance sur un cluster **non critique** — jamais en production sans
> prévenir, et idéalement en premier lieu sur des VMs jetables.
> Modèles à remplir : [`docs/templates/fiche-test-failover.md`](../templates/fiche-test-failover.md) et
> [`docs/templates/checklist-verif-cluster.md`](../templates/checklist-verif-cluster.md).

---

## Préparation de l'environnement de test

- 1–2 VMs jetables (`vm:100`, `vm:101`) : répliquées `*/5`, HA activées, **sans données sensibles**.
- Fenêtre calendrier + augmentation de la surveillance (doc 10) + notification à l'équipe.
- Prendre note des « avant » : `pvecm status`, `ha-manager status`, `pvesr status`.

## Scénario 1 — Perte brutale d'un nœud (le plus important)

> Exercice le plus « code-path » différent : power loss réelle (pas `reboot` propre).

```bash
# depuis pve1 connecté en console physique/KVM (ou via IPMI) :
poweroff -f            # (ou couper l'alimentation)
# PUIS depuis pve2, chronométrer :
time while ! pvecm status | grep -q Quorate; do sleep 2; done
# surveiller jusqu'à ce que vm:100 repasse started sur la cible :
watch -n2 ha-manager status
```

**Ce qu'on attend** :
1. `pve1` perd le quorum → le **watchdog ne reçoit plus de poke** → reboot automatique (~60 s) — vérifiable en console.
2. pve2 + pve3 restent quorate (majorité 2/3) ;
3. le HA relance `vm:100` sur `pve2` (ou pve3), **depuis le snapshot de réplication** ;
4. downtime mesuré (objectif : **1 à 2 min**, pas 45).

**Après coupure test** : remettre le nœud en service, vérifier `pvecm status` → Quorate, ressources répliquées,
et la **réplication inverse à recréer si le schéma l'exige**.

## Scénario 2 — Migration planifiée (maintenance)

```bash
# déplacer proprement une ressource HA avant coupure de maintenance :
ha-manager crm-command migrate vm:100 pve2
#   → migration *live* (ZFS possible) ou relocation selon le pool ; QEMU live-migrate en temps réel
#   mieux : ha-manager migrate (cmd de maintenance), ne l'utiliser qu'en fenêtre prévue
```

Ce scénario valide : le **live migration** (latence perçue ~0), la capacité des nœuds adjacents à absorber
la charge, et la réplication qui rend le mouvement possible sans perte.

## Scénario 3 — Partition réseau (défaillance la plus sournoise)

```bash
# SUR le nœud pve3 : couper LE lien corosync uniquement (isoler du réseau 10.10.0.0/24) :
ip link set eno2 down
# attendre :
watch pvecm status          # sur pve1 : pve3 sort du quorum
journalctl -u pve-ha-lrm -u pve-ha-crm   # pve3 : nettoyage watchdog / auto-fencing
```

Ce test révèle si Corosync partage un lien **pour son trafic**, et si les timeouts mènent à un
auto-fencing propre (le nœud isolé reboot, la majorité relance ses VMs).

## Chronométrage + fiche de test

Pour chaque scénario, noter sur la fiche :

| Étape | Lecture attendue | Lecture réelle |
|---|---|---|
| T0 (injection) | — | |
| T1 (nœud hors quorum) | < tokentimeout (CM) | |
| T2 (watchdog reboot si isolé) | ~60 s | |
| T3 (VM started sur cible) | ≤ 2 min | |
| T4 (cluster re-quorate) | < 5 min | |
| Données perdues | ≤ RPO (5 min) | |
| Bilan / actions | — | |

**Après chaque exercice** (trame de post-mortem) :
`journalctl -u pve-ha-crm`, `-u pve-ha-lrm`, `pvecm status`, `zpool status` sur tous les nœuds → corriger → ré-injecter l'action corrective dans le code/runbook.

## Calendrier recommandé

| Occasion | Test |
|---|---|
| Après install / activation HA | S1 + S2 complets |
| Après chaque upgrade kernel / HA / PVE | S1 (avec VMs jetables) |
| Mensuel | Rotation S2 / restauration PBS |
| Trimestriel | S1 sur une VM réelle non critique |
| Annuel | RB-04 reconstruction complète + test de restauration catastrophe |

## Échecs fréquents à provisionner dans les fiches

- Quorum mal configuré → récupération en 45 min au lieu de 2 (cause n°1) — toujours `pvecm status` en post-tests ;
- Watchdog absent (`lsmod | grep watchdog`) : un noyau à jour peut perdre softdog ;
- VM sur local-lvm → non répliquée → pas de bascule possible (leçon : répliquer tout, vérifier `pvesr status`) ;
- `max_relocate` illimité → un VM cassé fait du tourisme sur les 3 nœuds (bornes, doc 07) ;
- Corosync partagé avec un lien chargé → auto-fencing intempestif (S3 révèle directement).