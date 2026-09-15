# RB-01 — Incident : perte brutale d'un nœud

**Objectif** : rétablir l'exploitation après la perte (alimentation, disque, kernel-panic) d'un nœud,
sans perte de données et en vérifiant la ré-intégration.

---

## 1. Entrée du runbook

| Déclencheur | Exemple |
|---|---|
| Alerte monitoring (doc 10) : node down, perte quorum, guest down | `pve_node_status == 0` |
| Constat : `ha-manager status` montre ressource en `pve1` absente, etc. | |

**Règle** : ne jamais « forcer » une VM à redémarrer sur deux nœuds à la fois.
Le HA redémarre la VM sur le nœud réplica automatiquement — on **observe et vérifie**, on n'accélère pas.

## 2. Chronologie d'intervention

### T+0 — Confirmer et protéger

```bash
# depuis un nœud survivant (pve2 ou pve3) :
pvecm status                 # quorum ? pve1 présent ou pas ?
ha-manager status            # ressources : started ? sur quels nœuds ? watchdogs armed ?
pvesr status                 # réplication récente ?
zpool status                 # pools sains sur les nœuds survivants ?
```

- [ ] Notification au responsable + équipe (quand on coupe, on prévient).
- [ ] Ouvrir la console physique/KVM du nœud tombé (état réel ?).

### T+5 — Laisser le HA finir son travail

Faute de nœud, après le timeout watchdog (≤ ~60 s), les ressources migrent sur la cible de réplication.
**Ne pas interférer** — juste vérifier :

```bash
watch -n5 ha-manager status    # vm:100 doit passer started sur pve2/pve3
pvecm status                   # quorum restored après ré-intégration automatique
```

⚠️ Si `ha-manager status` montre `error` ou une ressource restée `stopped` au-delà de ~5 min :
voir section 5 (intervention manuelle).

### T+15 — Diagnostic de la cause (nœud éteint)

```bash
# depuis la console du nœud tombé (une fois l'alimentation OK) :
journalctl -b -u pve-ha-lrm -u pve-ha-crm      # pourquoi a-t-il cessé de parler à corosync ?
journalctl -b --no-hostname | grep -i -E "panic|bug|oops"
```

- [ ] Décider : réparation simple (périphérique reseat), remplacement de disque, carte, alim…

### T+30 — Réintégration du nœud

Le nœud rebotote :
1. il rejoint Corosync **automatiquement** si le réseau est intact → `pvecm status` Quorate ;
2. si HA : les ressources qui avaient basculé restent où elles sont (pas de failback automatique sauf règle) ;
3. vérifier la **réplication inverse** (le nœud réintégré doit redevenir cible de pvesr pour les VMs qu'il doit accueillir) :

```bash
pvesr status            # jobs actifs
pvesr list
```

### T+60 — Vérifications post-incident

```bash
pvecm status ; ha-manager status ; pvesr status ; zpool status ; pveversion -v
```
Menu de validation complet : [`docs/templates/checklist-verif-cluster.md`](../templates/checklist-verif-cluster.md).

## 3. Si le nœud n'est PAS récupérable (défaillance matérielle)

- [ ] Conserver ses disques pour extraction (ne jamais rebooter en vain).
- [ ] Les VMs restent sur les survivants : vérifier capacité (CPU/RAM/disque) — ajuster règlementairement.
- [ ] Commande de remplacement ; exercer RB-04 (reconstruction from scratch) pour le remplacer immédiatement.
- [ ] Tant qu'il n'y a qu'**un** survivant : cluster **non quorate** → plus aucune bascule possible → **urgence maximale**.

## 4. En fin d'incident

1. Re-injecter les constats dans le code/runbooks (doc 13 — « toute correction manuelle devient du code »).
2. Programmer un **exercice S1** (doc 12) pour prouver que la chaîne reproduite est bonne.
3. Clôturer la fiche (modèle [`fiche-test-failover.md`](../templates/fiche-test-failover.md)) et l'alerte.

## 5. Intervention manuelle de récupération (si HA bloqué)

Réservé aux cas où des ressources restent `stopped`/`error` sans redémarrage :

```bash
# 1. identifier la ressource bloquée
ha-manager status
# 2. la démarrer explicitement sur le nœud voulu (bascule forcée)
ha-manager crm-command start-remote resource vm:100 pve2
# 3. ou migrate si elle est en état started mais au mauvais endroit
ha-manager crm-command migrate vm:100 pve3
# 4. suivre : 
ha-manager status
```

> Toujours via `ha-manager crm-command` (coordonné) plutôt que `qm start` brut (risque de double exécution).