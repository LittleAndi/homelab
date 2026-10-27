#!/bin/bash
# Run INSIDE the sandbox VM as root, after 11-setup-sandbox-guest.sh. The
# auth key comes on stdin, sits in /run (RAM) only for `tailscale up`:
#   scp infra/proxmox-sandbox/scripts/12-join-tailnet.sh sandbox@192.168.1.26:
#   read -rs k; printf %s "$k" | ssh sandbox@192.168.1.26 'sudo bash 12-join-tailnet.sh'; unset k
#
# Joins the tailnet as tag:sandbox (ADR-0016). The key: tagged tag:sandbox,
# pre-approved, not reusable, not ephemeral (the VM is off most of the time).
# Safety rests on the policy file: tagged devices don't initiate (ADR-0016
# update 2026-10-27). Here: no routes or DNS from the tailnet, and containers
# can't open connections into tailscale0.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
. /etc/os-release

key="$(cat)"
[ -n "$key" ] || { echo "No auth key on stdin (see Usage)." >&2; exit 1; }

echo "== 1/3 Tailscale from pkgs.tailscale.com"
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.tailscale-keyring.list" \
  -o /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y tailscale

echo "== 2/3 Containers: no new connections into the tailnet"
# DOCKER-USER is recreated by dockerd, so the rule is (re)added after it.
# Replies to tailnet clients of a published port are still allowed.
cat > /etc/systemd/system/docker-tailnet-block.service <<'EOF'
[Unit]
Description=Block containers from opening connections on tailscale0 (ADR-0016)
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -C DOCKER-USER -o tailscale0 -m conntrack --ctstate NEW,INVALID -j DROP 2>/dev/null || iptables -I DOCKER-USER -o tailscale0 -m conntrack --ctstate NEW,INVALID -j DROP'
ExecStop=-/usr/sbin/iptables -D DOCKER-USER -o tailscale0 -m conntrack --ctstate NEW,INVALID -j DROP

[Install]
WantedBy=docker.service
EOF
systemctl daemon-reload
systemctl enable --now docker-tailnet-block.service

echo "== 3/3 Join as tag:sandbox"
printf %s "$key" > /run/ts-authkey && chmod 600 /run/ts-authkey
tailscale up \
  --auth-key=file:/run/ts-authkey \
  --advertise-tags=tag:sandbox \
  --hostname=sandbox \
  --accept-routes=false \
  --accept-dns=false
rm -f /run/ts-authkey
tailscale set --auto-update
tailscale status --self --peers=false
