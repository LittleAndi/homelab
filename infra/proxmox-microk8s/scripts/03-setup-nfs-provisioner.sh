#!/bin/bash
# Run ON one of the control-plane nodes (e.g. cp1) after the Ansible
# playbook has clustered all 5 nodes.
#
# Two StorageClasses (ADR-0008, update 2026-09-21):
#   nfs-client  (default) — bulk data on the HDD mirror via NFS
#                           (Nextcloud user files, DB dump target).
#   local-path            — node-local volume on the VM's SSD boot disk
#                           (MariaDB, Nextcloud app/config). Pins the pod
#                           to one node. Must be requested explicitly.
# The hostpath-storage addon stays disabled.
set -euo pipefail

NFS_SERVER="192.168.1.10"          # the Proxmox host (vmbr0)
NFS_PATH="/hdd-mirror/k8s"
# Check https://github.com/rancher/local-path-provisioner/releases for the
# current release before running.
LOCAL_PATH_VERSION="v0.0.37"

microk8s enable helm3
microk8s disable hostpath-storage || true   # ignore if it wasn't enabled

# --- HDD tier: NFS ----------------------------------------------------------
microk8s helm3 repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
microk8s helm3 repo update

microk8s helm3 upgrade --install nfs-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server="${NFS_SERVER}" \
  --set nfs.path="${NFS_PATH}" \
  --set storageClass.name=nfs-client \
  --set storageClass.defaultClass=true

echo "Waiting for NFS provisioner pod..."
microk8s kubectl -n default rollout status deploy/nfs-provisioner-nfs-subdir-external-provisioner

# --- SSD tier: local-path ---------------------------------------------------
# Volumes land under /opt/local-path-provisioner on the node's boot disk,
# which is on local-zfs (NVMe).
microk8s kubectl apply -f \
  "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
microk8s kubectl -n local-path-storage rollout status deploy/local-path-provisioner
# Make sure it is NOT the default class — nfs-client is.
microk8s kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

microk8s kubectl get storageclass
