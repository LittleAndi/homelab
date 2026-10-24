#!/usr/bin/env bash
# Copy the local-only files (ADR-0014) to LOCAL_BACKUP_DIR from site.env,
# keeping their repo-relative paths. Run after changing site.env, running
# terraform, or taking a new Z-Stick backup.
set -euo pipefail
. "$(dirname "$0")/lib-site.sh"
load_site_env
cd "$REPO_ROOT"

LOCAL_ONLY=(
  site.env
  infra/proxmox-microk8s/terraform/terraform.tfvars
  infra/proxmox-microk8s/terraform/terraform.tfstate
  infra/proxmox-microk8s/terraform/terraform.tfstate.backup
)
shopt -s nullglob
LOCAL_ONLY+=(infra/proxmox-ha/backup/* infra/proxmox-microk8s/*/*.local.yaml)

mkdir -p "$LOCAL_BACKUP_DIR"
for f in "${LOCAL_ONLY[@]}"; do
  [[ -f "$f" ]] || { echo "skip (missing)  $f"; continue; }
  mkdir -p "$LOCAL_BACKUP_DIR/$(dirname "$f")"
  cp -p "$f" "$LOCAL_BACKUP_DIR/$f"
  echo "backed up       $f"
done
echo "-> $LOCAL_BACKUP_DIR"
