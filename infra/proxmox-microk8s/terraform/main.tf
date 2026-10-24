terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"   # check the Terraform Registry for the current version
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true   # set false once the Proxmox web UI has a real cert
}

# ---------------------------------------------------------------------------
# Node definitions. VMIDs are assigned sequentially starting at 101 so that
# cp1/cp2/cp3 = 101/102/103 — matches scripts/02-reserve-cp-disk-space.sh.
# Static IPs: .20-.22 control-plane, .23-.24 workers. Servers use
# .20-.63; the Proxmox host itself is .10. All outside DHCP (.64-.243).
# ---------------------------------------------------------------------------
# RAM: 3 GB control plane, 4 GB workers (17 GB total on a 32 GB host).
# Fixed allocation, no ballooning (k8s schedules against the max). To grow a
# node: raise memory here, apply, then drain/reboot/uncordon one node at a time.
locals {
  nodes = {
    cp1 = { vmid = 101, ip = "192.168.1.20", cores = 2, memory = 3072, disk_gb = 40 }
    cp2 = { vmid = 102, ip = "192.168.1.21", cores = 2, memory = 3072, disk_gb = 40 }
    cp3 = { vmid = 103, ip = "192.168.1.22", cores = 2, memory = 3072, disk_gb = 40 }
    wk1 = { vmid = 104, ip = "192.168.1.23", cores = 4, memory = 4096, disk_gb = 60 }
    wk2 = { vmid = 105, ip = "192.168.1.24", cores = 4, memory = 4096, disk_gb = 60 }
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name      = "microk8s-${each.key}"
  node_name = var.proxmox_node
  vm_id     = each.value.vmid

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  cpu {
    cores = each.value.cores
    # Single host, never migrated: expose the Ryzen's full instruction set
    # (provider default qemu64 lacks AVX etc.).
    type = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.boot_storage
    interface    = "scsi0"
    size         = each.value.disk_gb
    ssd          = true
    # Thin-provisioned on ZFS: pass TRIM through so freed space returns to
    # the pool (keeps local-zfs under the ~80% target).
    discard      = "on"
    # Control-plane disks get a hard ZFS reservation via
    # scripts/02-reserve-cp-disk-space.sh after apply — the provider
    # doesn't expose ZFS refreservation directly, since that's a
    # storage-backend property, not a VM property.
  }

  initialization {
    # Cloud-init drive; the provider defaults to "local-lvm", which
    # doesn't exist on this host (ZFS install).
    datastore_id = var.boot_storage

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }
    # Set explicitly so VMs never inherit the host's resolvers (which were
    # Tailscale-only until accept-dns was turned off on the host).
    dns {
      servers = var.dns_servers
    }
    user_account {
      keys = [var.ssh_public_key]
    }
  }

  agent {
    # Requires qemu-guest-agent in the template image (script 00 installs it
    # with virt-customize). Without it, apply waits for the agent timeout.
    enabled = true
    trim    = true
  }

  operating_system {
    type = "l26"
  }
}

output "node_ips" {
  value = { for k, v in local.nodes : k => v.ip }
}

output "node_vmids" {
  value = { for k, v in local.nodes : k => v.vmid }
}
