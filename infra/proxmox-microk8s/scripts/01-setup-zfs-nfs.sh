#!/bin/bash
# Run ONCE on the Proxmox host as root. Safe to re-run.
#
# Storage layout (ADR-0008, update 2026-09-21):
#   - VM OS disks always live on the SSD (local-zfs = rpool/data).
#   - hdd-mirror (2x 2TB WD, ZFS mirror, already created) holds bulk data only.
#   - One ZFS dataset + one NFS export per consumer. The cluster gets
#     hdd-mirror/k8s, exported ONLY to the 5 node IPs. A future playground
#     VM gets its own dataset/export (see bottom of this file), never k8s.
set -euo pipefail

POOL="hdd-mirror"
DATASET="${POOL}/k8s"
# Guaranteed space for the cluster so other datasets/VM data disks on the
# pool can never starve Nextcloud. Adjust as the pool grows.
K8S_RESERVATION="500G"
CLUSTER_NODES="192.168.1.20 192.168.1.21 192.168.1.22 192.168.1.23 192.168.1.24"
EXPORT_OPTS="rw,sync,no_subtree_check,no_root_squash"
EXPORT_FILE="/etc/exports.d/k8s.exports"

if ! zpool list -H "$POOL" >/dev/null 2>&1; then
  echo "Pool '$POOL' not found. Expected the existing WD mirror (WMAY04636950 + WMAY05102700)." >&2
  exit 1
fi

zfs list -H "$DATASET" >/dev/null 2>&1 || zfs create "$DATASET"
zfs set reservation="$K8S_RESERVATION" "$DATASET"
MOUNTPOINT="$(zfs get -H -o value mountpoint "$DATASET")"

# nfs-server logs "can't open /etc/exports" if the file is missing, even
# though our export lives in /etc/exports.d. An empty file keeps it quiet.
touch /etc/exports

apt update
apt install -y nfs-kernel-server

# One export file per dataset; rewritten each run, so it's always in sync
# with CLUSTER_NODES.
mkdir -p /etc/exports.d
{
  echo "# Managed by 01-setup-zfs-nfs.sh — cluster storage (nfs-subdir-external-provisioner)"
  printf '%s' "$MOUNTPOINT"
  for ip in $CLUSTER_NODES; do printf ' %s(%s)' "$ip" "$EXPORT_OPTS"; done
  echo
} > "$EXPORT_FILE"

exportfs -ra
systemctl enable --now nfs-kernel-server

echo "Dataset '$DATASET' (reservation $K8S_RESERVATION) exported at $MOUNTPOINT to: $CLUSTER_NODES"
zpool status "$POOL"
zfs list -o name,used,avail,reservation,mountpoint -r "$POOL"
exportfs -v

# ---------------------------------------------------------------------------
# Adding a playground VM later (don't run now). Its OS disk goes on local-zfs
# (SSD). For bulk data, either:
#   a) plain data disk: add a second disk on storage "hdd-mirror" to the VM
#      (enable discard; consider `pvesm set hdd-mirror --sparse 1` first), or
#   b) shared files: own dataset + export limited to its IP, e.g.
#        zfs create -o quota=200G hdd-mirror/play1
#        echo "/hdd-mirror/play1 192.168.1.30(rw,sync,no_subtree_check,root_squash)" \
#          > /etc/exports.d/play1.exports && exportfs -ra
# Never add a playground VM to k8s.exports.
# ---------------------------------------------------------------------------
