#!/usr/bin/env bash
# ADR-0013: Prometheus exporters on the Proxmox host (pve, 192.168.1.10).
#
#   node_exporter  :9100  Debian package; ZFS ARC, systemd units, textfile dir
#   zfs-metrics    via :9100 (textfile)  pools, datasets, snapshot age
#   smartctl       :9633  Debian trixie-backports
#   pve-exporter   :9221  PyPI in a venv, read-only PVE token
#   nftables table `inet exporters`: ports only from 127.0.0.1 + node IPs
#
# Run as root on the host, from the directory holding this script and
# zfs-metrics.py. Idempotent: safe to re-run.
#   PVE_EXPORTER_VERSION=3.x.y bash 20-setup-host-exporters.sh   # optional pin
set -euo pipefail

NODE_IPS="192.168.1.20-192.168.1.24"
EXPORTER_PORTS="9100, 9221, 9633"
PVE_EXPORTER_VERSION="${PVE_EXPORTER_VERSION:-}"   # empty = latest from PyPI
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -f "$SCRIPT_DIR/zfs-metrics.py" ]] || { echo "zfs-metrics.py missing next to this script." >&2; exit 1; }

echo "== 1/5 node_exporter"
apt-get update -q
# No recommends: prometheus-node-exporter-collectors brings its own smartmon/apt
# timers, which would overlap with smartctl_exporter.
apt-get install -y -q --no-install-recommends prometheus-node-exporter python3-venv

UNITS='(sanoid|syncoid-.+|azure-sync-k8s|zfs-metrics|smbd|nfs-server|zfs-zed|smartmontools|pveproxy|pvedaemon|pvestatd|pve-cluster|tailscaled|pve-exporter|smartctl_exporter)\.(service|timer)'
cat > /etc/default/prometheus-node-exporter <<EOF
# Managed by 20-setup-host-exporters.sh (ADR-0013)
ARGS="--collector.textfile.directory=${TEXTFILE_DIR} --collector.systemd --collector.systemd.unit-include=${UNITS}"
EOF
install -d -m 755 "$TEXTFILE_DIR"
systemctl enable prometheus-node-exporter
systemctl restart prometheus-node-exporter

echo "== 2/5 zfs-metrics textfile timer"
install -m 755 "$SCRIPT_DIR/zfs-metrics.py" /usr/local/bin/zfs-metrics.py
cat > /etc/systemd/system/zfs-metrics.service <<'EOF'
[Unit]
Description=Write ZFS metrics for node_exporter (ADR-0013)
After=zfs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zfs-metrics.py
Nice=10
EOF
cat > /etc/systemd/system/zfs-metrics.timer <<'EOF'
[Unit]
Description=ZFS metrics every minute (ADR-0013)

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now zfs-metrics.timer
systemctl start zfs-metrics.service

echo "== 3/5 smartctl_exporter (trixie-backports)"
if [[ ! -f /etc/apt/sources.list.d/debian-backports.sources ]]; then
  cat > /etc/apt/sources.list.d/debian-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  apt-get update -q
fi
# Backports never install without -t, so this pulls in only this package.
apt-get install -y -q -t trixie-backports prometheus-smartctl-exporter
systemctl enable --now smartctl_exporter   # the package names its unit smartctl_exporter

echo "== 4/5 pve-exporter"
id pve-exporter &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin pve-exporter
[[ -x /opt/pve-exporter/bin/pip ]] || python3 -m venv /opt/pve-exporter
/opt/pve-exporter/bin/pip install -q --upgrade "prometheus-pve-exporter${PVE_EXPORTER_VERSION:+==$PVE_EXPORTER_VERSION}"
echo "   installed: $(/opt/pve-exporter/bin/pip show prometheus-pve-exporter | awk '/^Version/{print $2}')"

# Read-only PVE user + token. The token value lives only in /etc/prometheus/pve.yml.
pveum user list --output-format json | grep -q '"prometheus@pve"' \
  || pveum user add prometheus@pve --comment "Prometheus exporter (ADR-0013)"
pveum acl modify / --users prometheus@pve --roles PVEAuditor
if [[ ! -s /etc/prometheus/pve.yml ]]; then
  pveum user token remove prometheus@pve exporter &>/dev/null || true
  TOKEN_VALUE="$(pveum user token add prometheus@pve exporter --privsep 0 --output-format json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
  install -d -m 755 /etc/prometheus
  ( umask 027
    cat > /etc/prometheus/pve.yml <<EOF
default:
  user: prometheus@pve
  token_name: exporter
  token_value: ${TOKEN_VALUE}
  verify_ssl: false
EOF
  )
  unset TOKEN_VALUE
  chown root:pve-exporter /etc/prometheus/pve.yml
  chmod 640 /etc/prometheus/pve.yml
fi

cat > /etc/systemd/system/pve-exporter.service <<'EOF'
[Unit]
Description=Prometheus Proxmox VE exporter (ADR-0013)
After=network-online.target pveproxy.service
Wants=network-online.target

[Service]
User=pve-exporter
Group=pve-exporter
# 3.x flags; 2.x took positional args (check with --help if the unit fails).
ExecStart=/opt/pve-exporter/bin/pve_exporter --config.file=/etc/prometheus/pve.yml --web.listen-address=0.0.0.0:9221
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pve-exporter
systemctl restart pve-exporter

echo "== 5/5 nftables: exporter ports only from localhost + node IPs"
# Own table and unit. Never via /etc/nftables.conf: its `flush ruleset` would
# also wipe the Proxmox firewall's rules.
cat > /etc/nftables-exporters.nft <<EOF
# Managed by 20-setup-host-exporters.sh (ADR-0013)
table inet exporters
delete table inet exporters
table inet exporters {
  chain input {
    type filter hook input priority filter; policy accept;
    tcp dport { ${EXPORTER_PORTS} } ip saddr { 127.0.0.1, ${NODE_IPS} } accept
    tcp dport { ${EXPORTER_PORTS} } ip6 saddr ::1 accept
    tcp dport { ${EXPORTER_PORTS} } drop
  }
}
EOF
nft -c -f /etc/nftables-exporters.nft
cat > /etc/systemd/system/exporters-firewall.service <<'EOF'
[Unit]
Description=Restrict Prometheus exporter ports (ADR-0013)
Before=prometheus-node-exporter.service smartctl_exporter.service pve-exporter.service
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables-exporters.nft
ExecStop=/usr/sbin/nft delete table inet exporters

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable exporters-firewall
systemctl restart exporters-firewall

echo
echo "== Checks (localhost)"
sleep 3
check() {
  local n
  n="$(curl -fsS --max-time 10 "$1" 2>/dev/null | grep -c "$2" || true)"
  printf "   %-28s %s samples\n" "$2" "${n:-0}"
}
check http://127.0.0.1:9100/metrics '^node_zfs_arc'
check http://127.0.0.1:9100/metrics '^zfs_pool_size_bytes'
check http://127.0.0.1:9100/metrics '^node_systemd_unit_state'
check http://127.0.0.1:9633/metrics '^smartctl_device{'
check 'http://127.0.0.1:9221/pve?module=default&cluster=1&node=1' '^pve_up'
echo
echo "Next: from cp1, curl -s 192.168.1.10:9100/metrics | head; from any other LAN machine it must time out."
