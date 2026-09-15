output "vm_info" {
  description = "Descriptif synthétique des VMs provisionnées"
  value = {
    for k, vm in proxmox_virtual_environment_vm.servers : k => {
      name      = vm.name
      vm_id     = vm.vm_id
      ip        = var.vms[k].ip
      node_name = vm.node_name
    }
  }
}