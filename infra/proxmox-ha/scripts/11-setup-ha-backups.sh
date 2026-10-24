#!/bin/bash
# Run on the Proxmox host as root, after 10-create-haos-vm.sh. Safe to re-run.
#
# Backup target for Home Assistant (ADR-0012), following "one dataset + one
# NFS export per consumer" (ADR-0008, scripts in ../proxmox-microk8s/):
#   - hdd-mirror/ha-backups, NFS-exported to the HA VM's IP only, root_squash
#   - Sanoid snapshots (template_data) and an hourly syncoid copy to
#     hgst/backup/ha-backups, the same protection as hdd-mirror/k8s (ADR-0011)
set -euo pipefail

POOL="hdd-mirror"
DATASET="${POOL}/ha-backups"
QUOTA="50G"
HA_IP="192.168.1.25"
EXPORT_OPTS="rw,sync,no_subtree_check,root_squash"
EXPORT_FILE="/etc/exports.d/ha-backups.exports"
BACKUP_PARENT="hgst/backup"
TARGET="${BACKUP_PARENT}/ha-backups"
SANOID_CONF="/etc/sanoid/sanoid.conf"

die() { echo "$*" >&2; exit 1; }

zpool list -H "$POOL" >/dev/null 2>&1 || die "Pool '$POOL' not found."
zfs list -H "$BACKUP_PARENT" >/dev/null 2>&1 || die "$BACKUP_PARENT not found (ADR-0011)."
[ -f "$SANOID_CONF" ] || die "$SANOID_CONF not found (ADR-0011)."
command -v syncoid >/dev/null || die "syncoid not installed (apt install sanoid)."

# --- Dataset + export ---------------------------------------------------------
zfs list -H "$DATASET" >/dev/null 2>&1 || zfs create "$DATASET"
zfs set quota="$QUOTA" "$DATASET"
MOUNTPOINT="$(zfs get -H -o value mountpoint "$DATASET")"

# HA's Supervisor writes as root; root_squash maps that to nobody:nogroup,
# so the directory belongs to 65534 rather than exporting with no_root_squash.
chown 65534:65534 "$MOUNTPOINT"
chmod 0770 "$MOUNTPOINT"

mkdir -p /etc/exports.d
{
  echo "# Managed by proxmox-ha/scripts/11-setup-ha-backups.sh: Home Assistant backups (ADR-0012)"
  echo "${MOUNTPOINT} ${HA_IP}(${EXPORT_OPTS})"
} > "$EXPORT_FILE"
exportfs -ra

# --- Sanoid -------------------------------------------------------------------
# template_data and template_backup already exist (ADR-0011).
if ! grep -q "^\[${DATASET}\]" "$SANOID_CONF"; then
  cat >> "$SANOID_CONF" <<CONF

[${DATASET}]
  use_template = data

[${TARGET}]
  use_template = backup
CONF
  echo "Added $DATASET and $TARGET to $SANOID_CONF."
fi

# --- Initial replication ------------------------------------------------------
if ! zfs list -H "$TARGET" >/dev/null 2>&1; then
  # syncoid --no-sync-snap needs at least one Sanoid snapshot on the source.
  if [ -z "$(zfs list -H -t snapshot -o name "$DATASET")" ]; then
    TZ=UTC sanoid --take-snapshots   # UTC names, like sanoid.service
  fi
  # The read-only parent blocks creating the new mountpoint directory on the
  # first receive (ADR-0011 update), so lift it for this one run.
  zfs set readonly=off "$BACKUP_PARENT"
  if ! HOME=/root syncoid --no-sync-snap "$DATASET" "$TARGET"; then
    zfs set readonly=on "$BACKUP_PARENT"
    die "Initial syncoid failed."
  fi
  zfs mount "$TARGET" 2>/dev/null || true
  zfs set readonly=on "$BACKUP_PARENT"
fi

# --- Hourly replication ---------------------------------------------------------
# :20 so it doesn't overlap syncoid-k8s (:10) on the same HGST spindle.
cat > /etc/systemd/system/syncoid-ha-backups.service <<UNIT
[Unit]
Description=Replicate ${DATASET} to ${TARGET} (ADR-0012)
After=zfs.target

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/usr/sbin/syncoid --no-sync-snap ${DATASET} ${TARGET}
UNIT

cat > /etc/systemd/system/syncoid-ha-backups.timer <<UNIT
[Unit]
Description=Hourly syncoid ${DATASET} -> ${TARGET}

[Timer]
OnCalendar=*-*-* *:20:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now syncoid-ha-backups.timer

zfs list -o name,used,avail,quota,readonly,mountpoint "$DATASET" "$TARGET"
exportfs -v | grep -A1 ha-backups || true
systemctl list-timers 'syncoid-*' --no-pager

cat <<NEXT

In Home Assistant: Settings > System > Storage > Add network storage
  Name:    nas-backups
  Usage:   Backup
  Server:  192.168.1.10
  Protocol: NFS
  Path:    ${MOUNTPOINT}
Then Settings > System > Backups: make nas-backups the backup location and
turn on automatic daily backups.
NEXT
