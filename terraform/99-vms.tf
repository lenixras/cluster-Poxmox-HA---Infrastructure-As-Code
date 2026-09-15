resource "proxmox_virtual_environment_vm" "servers" {
  for_each  = var.vms
  name      = "${each.key}.${var.cluster_domain}"
  node_name = var.node
  vm_id     = each.value.vm_id

  clone {
    vm_id = var.template_id
    full  = true # copie indépendante (pas de lien au template)
  }

  cpu {
    cores   = each.value.cores
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
  }

  network_device {
    bridge = "vmbr2"
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.vm_gateway
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
    dns {
      servers = var.dns_servers
      domain  = var.cluster_domain
    }
  }

  operating_system {
    type = "l26"
  }

  tags    = ["managed-by-terraform"]
  started = true
}