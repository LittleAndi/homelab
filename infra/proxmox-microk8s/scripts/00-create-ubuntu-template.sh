#!/bin/bash
# Run ONCE on the Proxmox host as root.
# Creates a reusable cloud-init-enabled Ubuntu 26.04 template that
# Terraform clones to create each of the 5 VMs.
set -euo pipefail

if ! ip link show vmbr0 >/dev/null 2>&1; then
  echo "vmbr0 does not exist. Create it on the wired NIC (nic0) first, see README step 0." >&2
  exit 1
fi

VMID=9000
STORAGE="local-zfs"   # verified: rpool/data on the NVMe
IMG_URL="https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
IMG_FILE="/var/lib/vz/template/iso/ubuntu-26.04-cloudimg-amd64.img"

if [ -f "$IMG_FILE" ]; then
  echo "Image already downloaded, skipping fetch."
else
  wget -O "$IMG_FILE" "$IMG_URL"
fi

# Ubuntu cloud images don't ship qemu-guest-agent; Terraform's agent block
# waits for it. Bake it into the image (idempotent).
if ! command -v virt-customize >/dev/null; then
  apt update && apt install -y libguestfs-tools
fi
virt-customize -a "$IMG_FILE" --install qemu-guest-agent

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists. Remove it first: qm destroy $VMID" >&2
  exit 1
fi

qm create "$VMID" \
  --name ubuntu-26.04-cloudinit-template \
  --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --ostype l26 \
  --agent enabled=1

qm importdisk "$VMID" "$IMG_FILE" "$STORAGE"
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0

qm template "$VMID"

echo "Template VMID $VMID ready — terraform/main.tf clones this."
