# Fiche de test — Exercice de bascule (doc 12)

> À remplir à chaque exercice. Conserver dans `docs/templates/` complétée (renommer avec la date).

## Informations

- Date / heure : `____________` — Durée : `____________`
- Scénario : ☐ S1 perte brutale nœud ☐ S2 migration planifiée ☐ S3 partition réseau ☐ Restauration PBS ☐ Reconstruiction
- VMs de test : `____________` — Nœud injecté : `____________`
- Intervenants : `____________`
- Environnement de production ? ☐ oui ☐ non (sinon préciser le lab)
- CLUSTER EN ÉTAT INITIAL SAIN ? ☐ (`pvecm status` quorate + checklist)

## Déroulé mesuré

| Temps | Lecture attendue | Lecture réelle | Commentaire |
|---|---|---|---|
| **T0** | injection effectuée | `____________` | |
| **T1** | nœud sort du quorum | `________` | |
| **T2** | watchdog reboot (S1/S3) ≤ ~60 s | `________` | |
| **T3** | `vm:__` repart `started` sur cible | `________` | |
| **T4** | cluster Quorate réédifié | `________` | |
| **T5** | réplications re-saines (≤ 5 min) | `________` | |

**Résumé** : downtime mesuré de la VM = `________` s/min — **objectif ≤ 2 min (S1)**.

## Vérifications finales

- [ ] `pvecm status` → Quorate
- [ ] `ha-manager status` → watchdogs armed, toutes ressources started
- [ ] `pvesr status` → toutes les réplications ≤ intervalle
- [ ] `zpool status` → ONLINE sur tous les pools
- [ ] backups PBS reconduits (freshness OK)
- [ ] aucun split-brain : pas de VM démarrée sur 2 nœuds (`qm list` croisé)

## Leçons apprises / actions correctives

| Constat | Action | Responsable | Fait le |
|---|---|---|---|
| | | | |

## Validation du test

`☐ conforme` — Commentaire : `________________________________` — Signature : `____________`