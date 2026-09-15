variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "ssh_public_key" {
  type        = string
  description = "Clé publique SSH injectée via cloud-init"
}

variable "vm_gateway" {
  type    = string
  default = "10.10.10.1"
}

variable "dns_servers" {
  type    = list(string)
  default = ["10.10.10.20", "1.1.1.1"]
}

variable "storage_pool" {
  type    = string
  default = "tank"
}

variable "node" {
  type    = string
  default = "pve1"
}

variable "template_id" {
  type    = number
  default = 9000
}

variable "cluster_domain" {
  type    = string
  default = "cluster.local"
}

variable "vms" {
  type = map(object({
    vm_id  = number
    ip     = string
    cores  = number
    memory = number
    disk   = number
  }))
  default = {
    dns01 = {
      vm_id  = 101
      ip     = "10.10.10.20"
      cores  = 2
      memory = 2048
      disk   = 20
    }
    vpn01 = {
      vm_id  = 102
      ip     = "10.10.10.21"
      cores  = 2
      memory = 2048
      disk   = 20
    }
    mon01 = {
      vm_id  = 103
      ip     = "10.10.10.30"
      cores  = 4
      memory = 4096
      disk   = 40
    }
    app01 = {
      vm_id  = 104
      ip     = "10.10.10.40"
      cores  = 4
      memory = 8192
      disk   = 50
    }
    app02 = {
      vm_id  = 105
      ip     = "10.10.10.41"
      cores  = 4
      memory = 8192
      disk   = 50
    }
  }
}