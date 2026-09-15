# RB-05 — Perte de secrets / comptes / clés — procédures de secours

**Objectif** : retrouver l'accès au cluster quand un secret critique est perdu ou un compte compromis —
sans perdre de données, et en **fermant la perte** (rotation intelligente).

---

## 1. Matrice des secrets & emplacements

| Secret | Emplacement(s) | Perte ⇒ |
|---|---|---|
| Mot de passe `root@pam` (nœud) | foi physique / terminal | reset via console : RB-05 sect. 2 |
| Clé d'encryption PBS | coffre + copie hors-ligne (physique) | **AUCUNE restauration possible sans elle** |
| Tokens `terraform@pve` / `ansible@pve` | Vault / `group_vars/all/vault.yml` | rotation token (pas de coupure) |
| Clés SSH du cluster (migrations) | `/etc/pve/nodes/*/ssh_known_hosts` | régénération via `pvecm updatecerts` |
| Code de secours TOTP | coffre hors-ligne | secteur 3 |
| Mots de passe apps / Git | gestionnaire (Vault) | sect. 4 |

## 2. Mot de passe `root` PVE perdu

Consoler un nœud (KVM/IPMI) → mode rescue (boot du noyau PVE, `init=/bin/bash`) ou chroot :

```bash
# (mode rescue) remonter rw et reset :
mount -o remount,rw /
passwd root
```

> Il n'y a pas de mot de passe « secret service » : le `root@pam` est le contrôle absolu des nœuds.
> Après recovery : contrôler les ACLs (`pveum user list`) et penser à la 2FA (doc 09).

## 3. Perte du 2e facteur (TOTP / WebAuthn) d'un admin

- **have ac back** : connexion console/IPMI root (sect. 2) puis :

```bash
# régénérer un QR/code pour l'utilisateur (nouveau facteur) :
pveum user modify <user>@pam --otp-type totp
# ou retirer l'exigence 2FA ponctuellement (ré-enforcer ensuite) :
pveum user modify <user>@pam --delete otp
```

- **preventive** : prévoir un **2e facteur secondaire** (YubiKey/WebAuthn) et un **break-glass** scellé.

## 4. Token d'automatisation compromis

```bash
# DEPUIS un nœud (admin) — révoquer immédiatement :
pveum user token delete terraform@pve terraform-token
pveum user token add    terraform@pve terraform-token --privsep=0   # nouvel identifiant/secret
# mettre à jour vault / Vault, puis :
ansible-playbook -i inventory.yml playbooks/site.yml   # re-test complet
```

Règle : toute suspicion ⇒ rotation immédiate, journalisation de la raison, revue de `pveproxy`/SSH logs.

## 5. Clé SSH du cluster perdue / mise à jour

```bash
# sur le nœud : régénérer les clés internes (migrations, pmxcfs)
pvecm updatecerts --force
# puis rejoindre/re-joint les nœuds si problème de confiance host Key (doc 04)
```

## 6. Perte de la clé d'encryption PBS — **alerte maximum**

Les données **chiffrées ne sont récupérables nulle part** sans cette clé :

1. Vérifier la sauvegarde coffre (copie physique !) ;
2. En l'absence de copie, les données chiffrées sont **définitivement perdues** : il est impossible
   de rattraper la restauration depuis une réplique (tout est chiffré) → donc : **empêcher la perte**
   (2 copies physiques + 1 coffre), jamais 1 seule ;
3. Au minimum : après avoir réétabli une clé, relancer un job de sauvegarde complet et vérifier la
   restauration d'une VM de test avant de re-basculer en production.

> **Standing order** : une clé d'encryption n'existe jamais en un seul endroit. Export clé +
> génération de copie de secours hors-ligne annuelle (doc 11).

## 7. Prévention continue

- [ ] Coffre/3 copies des clés (dont hors-ligne) recensées dans ce runbook, revérifiées trimestriellement ;
- [ ] Rotations planifiées (tokens ≥ semi-annuel) ;
- [ ] Comptes humains : groupes de rôles, `pveum acl list` audité trimestriellement (doc 13) ;
- [ ] Régénérer la clé du coffre immédiatement après toute utilisation (aucune « copie en clair » traînante).