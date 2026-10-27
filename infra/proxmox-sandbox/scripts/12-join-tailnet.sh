#!/bin/bash
# Run INSIDE the sandbox VM as root, after 11-setup-sandbox-guest.sh. The
# auth key comes on stdin, sits in /run (RAM) only for `tailscale up`:
#   scp infra/proxmox-sandbox/scripts/12-join-tailnet.sh sandbox@192.168.1.26:
#   read -rs k; printf %s "$k" | ssh sandbox@192.168.1.26 'sudo bash 12-join-tailnet.sh'; unset k
#
# Joins the tailnet as tag:sandbox (ADR-0016). The key: tagged tag:sandbox,
# pre-approved, not reusable, not ephemeral (the VM is off most of the time).
# Safety rests on the policy file: tagged devices don't initiate (ADR-0016
# update 2026-10-27). Here: no routes or DNS from the tailnet. Sandboxes reach
# out only through sbx's deny-by-default proxy.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
. /etc/os-release

key="$(cat)"
[ -n "$key" ] || { echo "No auth key on stdin (see Usage)." >&2; exit 1; }

echo "== 1/2 Tailscale from pkgs.tailscale.com"
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.tailscale-keyring.list" \
  -o /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y tailscale

echo "== 2/2 Join as tag:sandbox"
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
