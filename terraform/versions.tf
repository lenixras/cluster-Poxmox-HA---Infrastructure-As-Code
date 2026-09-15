terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }

  backend "s3" {
    bucket       = "terraform-state-cluster" # ou MinIO local
    key          = "cluster_proxmox/terraform.tfstate"
    endpoint     = "https://minio.cluster.local:9000"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # locking natif S3 (TF ≥ 1.11) ;
    # dynamodb_table = "terraform-lock"            # variante plus ancienne
    skip_credentials_validation = true
    skip_region_validation      = true
  }
}