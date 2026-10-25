#!/bin/bash
# Run on the Proxmox host as root. Safe to re-run. Contains site placeholders:
# run the rendered copy (scripts/render.sh, then .rendered/<this path>).
#
# Off-site copy of hdd-mirror/k8s to Azure (ADR-0011 §3, update 2026-10-25):
#   - Uploads from the newest Sanoid daily snapshot (01:30 UTC, after the
#     01:00 UTC mariadb-dump), not from a separate @azure snapshot: syncoid
#     2.2.0 can't skip snapshots, and a recreated @azure would collide on
#     hgst/backup/k8s and break the hourly replication.
#   - rclone sync into the off-site crypt remote under k8s/ (own storage
#     account and container, ADR-0011 update 2026-10-25). Files deleted or changed
#     at home move to k8s-deleted/<date>/ instead of disappearing; folders
#     older than KEEP_DAYS are purged.
#   - Nextcloud's preview cache (regenerable) is skipped.
#   - Daily at 03:00 UTC. A run that takes longer than a day (the first
#     upload) just delays the next one; systemd won't start it twice.
#
# Check first with:  DRY_RUN=1 /usr/local/sbin/azure-sync-k8s
#
# Needs rclone and /root/.config/rclone/rclone.conf with a SAS that allows
# read, add, create, write, delete and list (see ADR-0011 for renewing it).
set -euo pipefail

DATASET="hdd-mirror/k8s"
REMOTE="${CRYPT_OFFSITE_REMOTE}:"
DEST="${REMOTE}k8s"
DELETED="${REMOTE}k8s-deleted"
KEEP_DAYS=30
BIN="/usr/local/sbin/azure-sync-k8s"

die() { echo "$*" >&2; exit 1; }

zfs list -H "$DATASET" >/dev/null 2>&1 || die "$DATASET not found."
command -v rclone >/dev/null || die "rclone not installed (ADR-0011: rclone.org/install.sh)."
rclone listremotes | grep -qx "$REMOTE" || die "rclone remote $REMOTE not configured."
rclone lsf --max-depth 1 "$REMOTE" >/dev/null 2>&1 \
  || die "Can't list $REMOTE: SAS expired or missing permissions? Renew it first (ADR-0011)."

# --- Sync script ----------------------------------------------------------------
cat > "$BIN" <<SCRIPT
#!/bin/bash
# Managed by proxmox-microk8s/scripts/04-setup-azure-sync.sh (ADR-0011 §3).
set -euo pipefail

DATASET="$DATASET"
DEST="$DEST"
DELETED="$DELETED"
KEEP_DAYS=$KEEP_DAYS
HOLD="azure-sync"
SCRIPT
cat >> "$BIN" <<'SCRIPT'

SNAP="$(zfs list -H -t snapshot -o name -s creation "$DATASET" | grep '_daily$' | tail -n1)"
[ -n "$SNAP" ] || { echo "No daily snapshot of $DATASET." >&2; exit 1; }
AGE=$(( $(date +%s) - $(zfs get -H -p -o value creation "$SNAP") ))
[ "$AGE" -lt $((26 * 3600)) ] || { echo "Newest daily $SNAP is $((AGE / 3600)) h old: is Sanoid running?" >&2; exit 1; }

# Keep Sanoid from pruning the snapshot while rclone reads it.
zfs hold "$HOLD" "$SNAP" 2>/dev/null || true
trap 'zfs release "$HOLD" "$SNAP" 2>/dev/null || true' EXIT

SRC="$(zfs get -H -o value mountpoint "$DATASET")/.zfs/snapshot/${SNAP#*@}"
TODAY="$(date -u +%F)"
DRY=${DRY_RUN:+--dry-run}   # DRY_RUN=1 azure-sync-k8s: show what would change
echo "Syncing $SNAP -> $DEST ${DRY}"

rclone sync $DRY "$SRC/" "$DEST" \
  --backup-dir "$DELETED/$TODAY" \
  --exclude '/*/data/appdata_*/preview/**' \
  --transfers 8 --checkers 16 --fast-list \
  --stats 15m --stats-one-line --log-level NOTICE

# Purge deleted/changed-file folders older than KEEP_DAYS.
CUTOFF="$(date -u -d "-$KEEP_DAYS days" +%F)"
{ rclone lsf --dirs-only "$DELETED" 2>/dev/null || true; } | tr -d / | while read -r d; do
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  if [[ "$d" < "$CUTOFF" ]]; then
    echo "Purging $DELETED/$d"
    [ -n "$DRY" ] || rclone purge "$DELETED/$d"
  fi
done
echo "Done: $SNAP"
SCRIPT
chmod 0750 "$BIN"

# --- systemd --------------------------------------------------------------------
cat > /etc/systemd/system/azure-sync-k8s.service <<UNIT
[Unit]
Description=Sync newest daily snapshot of ${DATASET} to Azure (ADR-0011)
After=zfs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Nice=10
ExecStart=${BIN}
UNIT

cat > /etc/systemd/system/azure-sync-k8s.timer <<UNIT
[Unit]
Description=Daily Azure sync of ${DATASET}

[Timer]
OnCalendar=*-*-* 03:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now azure-sync-k8s.timer
systemctl list-timers azure-sync-k8s.timer --no-pager

cat <<NEXT

Timer enabled (03:00 UTC). For the first (long) upload, start it now and follow it:
  systemctl start --no-block azure-sync-k8s.service
  journalctl -fu azure-sync-k8s.service
NEXT
