provider "proxmox" {
  endpoint  = "https://192.168.1.10:8006/"
  api_token = var.proxmox_api_token # format user@realm!token=secret
  insecure  = true                  # → false une fois ACME/CA interne en place (doc 09)

  ssh {
    agent    = true
    username = "root"
  }
}