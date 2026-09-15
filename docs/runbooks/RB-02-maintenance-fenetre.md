# RB-02 — Fenêtre de maintenance planifiée d'un nœud

**Objectif** : couper/suspendre proprement **un** nœud (matériel, réseau, migration) sans interruption
de service des VMs critiques et sans bascule brutale.

---

## 0. Pré-requis (étape AVANT)

- [ ] Fenêtre annoncée (maintenance planifiée, pas d'urgence en cours).
- [ ] Cluster en bonne santé : `pvecm status` (Quorate), `ha-manager status` (tout `started`).
- [ ] Réplications à jour : `pvesr status` ≤ 5 min pour toutes les VMs critiques.
- [ ] Backup PBS récent (< SLA) — juste au cas où.
- [ ] Checklist d'état enregistrée [`checklist-verif-cluster.md`](../templates/checklist-verif-cluster.md).

## 1. Mettre le HA en maintenance (désarmer proprement)

```bash
# depuis un nœud du cluster (souvent le nœud cible lui-même) :
ha-manager crm-command disarm-ha freeze
#  → met en pause les requêtes HA ; les ressources actuelles restent en place, watchdogs libérés
ha-manager status          # watchdogs : disarmed / standby
```

> ⚠️ Pendant cette période, **plus de bascule automatique**. Garder la fenêtre courte et couverte par du monde.

## 2. Migrer les VMs hors du nœud (bascule propre)

```bash
# Migrer chaque ressource vers un autre nœud (migration LIVE si possible) :
ha-manager crm-command migrate vm:100 pve2
ha-manager crm-command migrate vm:101 pve3
ha-manager status          # toutes les ressources started sur des nœuds ≠ nœud de maintenance

# VMs non-HA éventuelles :
qm migrate <vmid> pve2 --online
```

## 3. Coupure du nœud

```bash
systemctl reboot                    # reboot propre (si maintenance OS)
# ou arrêt physique (matériel) : shutdown -h now puis couper l'alimentation à la console
```

**Attendre** que le nœud soit réellement off avant de toucher au matériel.

## 4. Opérations de maintenance

Selon le besoin : nettoyage, changement de disque, ajout/NIC, câblage, firmware…

- Toute action réseau : s'orienter réseau de secours actif (`reboot` du nœud revient désarmé).

## 5. Redémarrage et ré-intégration

```bash
# depuis un nœud survivant :
pvecm status                # le nœud rejoint Corosync automatiquement (réseau intact)
ha-manager crm-command arm-ha        # RE-ARMER LA PILE HA (étape critique sinon oubliée)
ha-manager status           # watchdogs armed, ressources à leur place/failback selon règles
pvesr status                # vérifier la réplication (le nœud réintégré redevient cible)
zpool status                # pools importés proprement
```

## 6. Restauration de l'équilibre

- S'il y avait des **failbacks** attendus et qu'ils n'ont pas eu lieu (règles désactivées), les relancer
  manuellement si souhaité :
  ```bash
  ha-manager crm-command migrate vm:100 pve1   # retour sur le nœud favori
  ```
- Re-vérifier `==== checklist-verif-cluster.md` complète (quorum/watchdog/backups).

## 7. Clôture / leçons

- [ ] Fenêtre documentée (début/fin), écart au plan signalé.
- [ ] Tests post-maintenance rapides : démarrage d'une VM jetable, migration courte.
- [ ] Re-injection de toute correction manuelle dans le code (doc 13).

> Rappel critique : un `arm-ha` oublié laisse le cluster « dénudé » — la prochaine panne sera une bascule
> manuelle non prévue. Faire du ré-armé une étape du checklist. (Voir aussi `disarm-ha` dans le wiki HA.)