#!/usr/bin/env bash
# Counts "database is locked" lines from k8s-dqlite since boot and writes them
# for node_exporter's textfile collector (ADR-0013 Update 2026-11-25).
# Run every minute by dqlite-locks.timer on the control-plane nodes.
set -euo pipefail
DIR=/var/lib/node_exporter/textfile
UNIT=snap.microk8s.daemon-k8s-dqlite
n=$(journalctl -u "$UNIT" -b --no-pager -o cat 2>/dev/null | grep -c 'database is locked' || true)
tmp=$(mktemp "$DIR/.dqlite.prom.XXXXXX")
cat > "$tmp" <<PROM
# HELP dqlite_database_locked_total "database is locked" errors logged by k8s-dqlite since boot.
# TYPE dqlite_database_locked_total counter
dqlite_database_locked_total ${n}
PROM
chmod 644 "$tmp"
mv "$tmp" "$DIR/dqlite.prom"
