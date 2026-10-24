variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://192.168.1.10:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "API token in 'user@realm!tokenid=uuid' form (Datacenter > Permissions > API Tokens)"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node (hostname) to create the VMs on"
  type        = string
  default     = "pve"
}

variable "template_vmid" {
  description = "VMID of the cloud-init Ubuntu template (created by scripts/00-create-ubuntu-template.sh)"
  type        = number
  default     = 9000
}

variable "boot_storage" {
  description = "Storage for VM OS/boot disks. Must be the SSD (local-zfs), never hdd-mirror"
  type        = string
  default     = "local-zfs"
}

variable "gateway" {
  description = "LAN gateway"
  type        = string
  default     = "192.168.1.1"
}

variable "dns_servers" {
  description = "DNS servers for the VMs (not the host's Tailscale resolver)"
  type        = list(string)
  default     = ["192.168.1.1"]
}

variable "ssh_public_key" {
  description = "Public key installed into each VM's cloud-init user"
  type        = string
}
