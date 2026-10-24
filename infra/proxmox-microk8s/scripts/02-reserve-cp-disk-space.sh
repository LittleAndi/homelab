#!/bin/bash
# Run ONCE on the Proxmox host, AFTER `terraform apply` has created the
# VMs, as root.
# Sets a hard ZFS refreservation on the 3 control-plane VM disks so their
# space is guaranteed even if the worker VMs' thin-provisioned disks fill
# the pool — see ADR-0008's dqlite/resource-pressure note for why this
# matters specifically for these three.
set -euo pipefail

BOOT_POOL="rpool/data"   # verified: storage local-zfs = rpool/data

for vmid in 101 102 103; do   # <-- match these to the VMIDs Terraform assigns cp1/cp2/cp3
  zvol="${BOOT_POOL}/vm-${vmid}-disk-0"
  echo "Reserving 40G on $zvol"
  zfs set refreservation=40G "$zvol"
done

echo "Done. Verify with: zfs get refreservation ${BOOT_POOL}"
