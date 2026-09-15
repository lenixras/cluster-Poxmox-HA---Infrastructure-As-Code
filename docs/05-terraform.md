# Provisioning des VMs avec Terraform

> Fournisseur : **`bpg/proxmox`** (successeur maintenu du fork Telmate, compatible PVE 8/9).
> Pré-requis : cluster en place (doc 04), templates cloud-init créés (section 3 ici).
> Références : [registry bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest) ·
> [backends/state](https://developer.hashicorp.com/terraform/language/state/backends)

---

## 1. Compte API dédié (jamais `root@pam` dans Terraform)

```bash
pveum user add terraform@pve --comment "Terraform automation"
pveum role add TerraformRole --privs \
  "VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.GuestAgent.Audit VM.PowerMgmt VM.Migrate Datastore.Audit Datastore.AllocateSpace Pool.Audit Pool.Allocate Sys.Audit"
pveum aclmod / -user terraform@pve -role TerraformRole
# Token (bull PrivSep à 0 hérite des privs du rôle ci-dessus ; affiché UNE SEULE fois)
pveum user token add terraform@pve terraform-token --privsep=0
```

Stockez le token dans votre gestionnaire de secrets / Vault, **jamais** dans le repo.

## 2. Arborescence `terraform/`

```
terraform/
├── versions.tf        # provider + backend distant
├── provider.tf
├── variables.tf
├── terraform.tfvars   # gitignoré (IPs, token…)
├── 99-vms.tf          # ressources VMs (for_each)
└── outputs.tf
```

### versions.tf + backend (state distant avec locking)

Le state contient des secrets en clair ⇒ **jamais en git, jamais en local seul**.

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }

  backend "s3" {
    bucket         = "terraform-state-cluster"     # ou MinIO local
    key            = "cluster_proxmox/terraform.tfstate"
    endpoint       = "https://minio.cluster.local:9000"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true                          # locking natif S3 (TF ≥ 1.11) ;
    # dynamodb_table = "terraform-lock"            # variante plus ancienne
    skip_credentials_validation = true
    skip_region_validation      = true
  }
}
```

> Mini-liste des bonnes pratiques (source HashiCorp) : **versioning** activé sur le bucket, droits
> `Get/List/Put` restreints. Option locale de secours : `backend "http"` (Consul) ou état local pour dépannage.

### provider.tf

```hcl
provider "proxmox" {
  endpoint  = "https://192.168.1.10:8006/"
  api_token = var.proxmox_api_token          # format user@realm!token=secret
  insecure  = true                            # → false une fois ACME/CA interne en place (doc 09)

  ssh {
    agent    = true
    username = "root"
  }
}
```

## 3. Template cloud-init (à créer une fois, manuel ou via Ansible)

Terraform **clone** un template existant ; il ne le crée pas. Sur un nœud (p. ex. `pve1`) :

```bash
# 1. Télécharger l'image cloud officielle
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img

# 2. Créer le VM template (9000)
qm create 9000 --name ubuntu-2404-template \
  --memory 2048 --cores 2 --cpu cputype=host \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr2 \
  --ide2 local:cloudinit \
  --boot order=scsi0 \
  --ostype l26 \
  --serial0 socket --vga serial0 \
  --agent enabled=1

# 3. Importer le disque dans le pool ZFS répliqué + cloud-init
qm importdisk 9000 ubuntu-24.04-server-cloudimg-amd64.img tank
qm set 9000 --scsi0 tank:9000/vm-9000-disk-0.raw \
  --scsihw virtio-scsi-single --boot order=scsi0 \
  --ide2 local:cloudinit
qm template 9000
```

> Piège fréquent : le disque cloud-init doit rester en **ide2** (CD-ROM) sinon cloud-init est ignoré
> silencieusement ([source DEV](https://dev.to/widely/automating-proxmox-virtual-machine-deployment-using-terraform-and-cloud-init-templates-2p19)).

## 4. Variables et exécution

```hcl
# variables.tf
variable "proxmox_api_token" { type = string; sensitive = true }
variable "ssh_public_key"    { type = string; description = "Clé publique SSH injectée via cloud-init" }
variable "vm_gateway"        { type = string; default = "10.10.10.1" }
variable "dns_servers"       { type = list(string); default = ["10.10.10.20", "1.1.1.1"] }
variable "storage_pool"      { type = string; default = "tank" }
variable "node"              { type = string; default = "pve1" }
variable "template_id"       { type = number; default = 9000 }
variable "cluster_domain"    { type = string; default = "cluster.local" }

variable "vms" {
  type = map(object({
    vm_id  = number
    ip     = string
    cores  = number
    memory = number
    disk   = number
  }))
  default = {
    dns01  = { vm_id = 101, ip = "10.10.10.20", cores = 2, memory = 2048, disk = 20 }
    vpn01  = { vm_id = 102, ip = "10.10.10.21", cores = 2, memory = 2048, disk = 20 }
    mon01  = { vm_id = 103, ip = "10.10.10.30", cores = 4, memory = 4096, disk = 40 }
    app01  = { vm_id = 104, ip = "10.10.10.40", cores = 4, memory = 8192, disk = 50 }
    app02  = { vm_id = 105, ip = "10.10.10.41", cores = 4, memory = 8192, disk = 50 }
  }
}
```

```hcl
# 99-vms.tf
resource "proxmox_virtual_environment_vm" "servers" {
  for_each  = var.vms
  name      = "${each.key}.${var.cluster_domain}"
  node_name = var.node
  vm_id     = each.value.vm_id

  clone {
    vm_id = var.template_id
    full  = true          # copie indépendante (pas de lien au template)
  }

  cpu    { cores = each.value.cores; sockets = 1; type = "x86-64-v2-AES" }
  memory { dedicated = each.value.memory }
  disk   { datastore_id = var.storage_pool; interface = "scsi0"; size = each.value.disk; discard = "on" }
  network_device { bridge = "vmbr2"; model = "virtio" }
  agent { enabled = true }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.vm_gateway
      }
    }
    user_account { username = "ubuntu"; keys = [var.ssh_public_key] }
    dns { servers = var.dns_servers; domain = var.cluster_domain }
  }

  operating_system { type = "l26" }
  tags   = ["managed-by-terraform"]
  started = true
}
```

**Exécution (depuis `terraform/`)**

```bash
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

> `terraform.tfvars` (gitignoré) : `proxmox_api_token = "terraform@pve!terraform-token=xxx"` + clé publique SSH.
> Éviter la dépendance aux `provisioner` ; la configuration applicative est déléguée à Ansible (doc 06).

## 5. Qualité / pièges connus

| Problème | Correction |
|---|---|
| `Disk image size not adjust` / clone impossible | La taille de disque ne se **réduit jamais** : augmenter seulement (`size up only`) |
| `node_name` invalide | reprendre la valeur exacte de `pvesh get /nodes` (casse : `pve1` ≠ `PVE1`) |
| VM ID déjà utilisé | réserver 100–299 pour Terraform, exclure des créations manuelles |
| le provider attend l'agent guest | `agent { enabled = true }` + qemu-guest-agent dans le template |
| la clé SSH non injectée au premier apply | attente ~20–30 s post-boot de cloud-init (ou `remote-exec` avec retry) |
| API 401 sur liste des ressources | ajouter `Sys.Audit` au rôle / chemin de ACL |

## 6. Validation

- [ ] `terraform plan` → aucun changement inattendu après un premier `apply`
- [ ] `terraform import` d'une VM existante réussit (migration d'existant sous IA C)
- [ ] Les VMs créées ont leur disque sur `tank` → réplication vers le nœud de secours automatique dans `*/5`
- [ ] `.terraform.lock.hcl` versionné (reproductibilité des providers)