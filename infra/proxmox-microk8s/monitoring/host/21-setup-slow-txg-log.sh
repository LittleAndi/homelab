#!/usr/bin/env bash
# ADR-0013 Update 2026-11-26: journal line for every slow rpool txg sync, to
# line up with the dqlite "database is locked" errors. Temporary diagnostic.
#
# Run as root on the host, from the directory holding this script and
# slow-txg-log.py. Idempotent: safe to re-run. Installs nothing else.
#   THRESHOLD=0.25 bash 21-setup-slow-txg-log.sh
# Remove:
#   systemctl disable --now slow-txg-log
#   rm /etc/systemd/system/slow-txg-log.service /usr/local/bin/slow-txg-log.py
#   systemctl daemon-reload
set -euo pipefail

THRESHOLD="${THRESHOLD:-0.25}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -f "$SCRIPT_DIR/slow-txg-log.py" ]] || { echo "slow-txg-log.py missing next to this script." >&2; exit 1; }

install -m 755 "$SCRIPT_DIR/slow-txg-log.py" /usr/local/bin/slow-txg-log.py
cat > /etc/systemd/system/slow-txg-log.service <<EOF
[Unit]
Description=Log slow rpool txg syncs (ADR-0013)
After=zfs.target

[Service]
ExecStart=/usr/local/bin/slow-txg-log.py --threshold ${THRESHOLD}
Restart=on-failure
RestartSec=30
# Keeps the last txg handled across restarts; /run is cleared at boot, as is
# the kernel's txg history.
RuntimeDirectory=slow-txg-log
RuntimeDirectoryPreserve=yes
Nice=10
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable slow-txg-log
systemctl restart slow-txg-log
sleep 3
systemctl --no-pager --lines=0 status slow-txg-log
journalctl -u slow-txg-log -n 10 --no-pager -o cat
