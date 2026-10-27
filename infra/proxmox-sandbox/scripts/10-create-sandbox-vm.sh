#!/bin/bash
# Run on the Proxmox host as root. Contains site placeholders: run the
# rendered copy (scripts/render.sh, then .rendered/<this path>).
#
# Creates the Docker sandbox VM (ADR-0016): VMID 111, cloned from template
# 9000, 4 vCPU, 2 GB fixed RAM, 80 GB on local-zfs with I/O caps, started on
# demand (onboot=0). Then the firewall, in this order:
#   1. host.fw `enable: 0`, so the host stays unfiltered
#   2. 111.fw: SSH in from the workstation only; out to DNS and the internet,
#      not the LAN or the tailnet; ipfilter pins the guest to its IP
#   3. datacenter firewall on (needed for any VM rule to apply)
#   4. nftables table `inet sandbox`: the host drops input from the sandbox IP
#
# Not in Terraform, so a cluster apply/destroy never touches it.
#
# Usage:  SSH_KEY_FILE=/root/sandbox.pub ./10-create-sandbox-vm.sh
#   (the workstation's public key, e.g. scp ~/.ssh/id_ed25519.pub root@pve:/root/sandbox.pub)
set -euo pipefail

VMID=111
NAME="sandbox"
TEMPLATE=9000
STORAGE="local-zfs"
CORES=4
MEMORY=2048              # fixed, no ballooning; zram inside the guest for bursts
CPUUNITS=25              # the other VMs run at the default 100
DISK_SIZE_GB=80
DISK_LIMITS="mbps_rd=200,mbps_wr=200,iops_rd=4000,iops_wr=4000"
IP="192.168.1.26"
GW="192.168.1.1"
WORKSTATION_IP='${WORKSTATION_IP}'   # rendered; literal if not
BRIDGE="vmbr0"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

die() { echo "$*" >&2; exit 1; }

[ -n "$SSH_KEY_FILE" ] && [ -s "$SSH_KEY_FILE" ] || die "Set SSH_KEY_FILE to the workstation's public key (see Usage)."
case "$WORKSTATION_IP" in 192.168.1.*) ;; *) die "WORKSTATION_IP not rendered. Run the copy from .rendered/." ;; esac
qm status "$VMID" >/dev/null 2>&1 && die "VMID $VMID already exists. Remove it first: qm destroy $VMID"
ping -c1 -W1 "$IP" >/dev/null 2>&1 && die "$IP answers ping; something else has it."

# --- VM -----------------------------------------------------------------------
qm clone "$TEMPLATE" "$VMID" --name "$NAME" --full --storage "$STORAGE"

disk="$(qm config "$VMID" | sed -n 's/^scsi0: \([^,]*\).*/\1/p')"
qm set "$VMID" \
  --cpu host --cores "$CORES" --cpuunits "$CPUUNITS" \
  --memory "$MEMORY" --balloon 0 \
  --scsi0 "${disk},discard=on,ssd=1,${DISK_LIMITS}" \
  --net0 "virtio,bridge=${BRIDGE},firewall=1" \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --ciuser sandbox --sshkeys "$SSH_KEY_FILE" \
  --ipconfig0 "ip=${IP}/24,gw=${GW}" --nameserver "$GW" \
  --onboot 0
qm disk resize "$VMID" scsi0 "${DISK_SIZE_GB}G"

# --- Proxmox firewall -----------------------------------------------------------
# Host first: with the datacenter switch on, the host would otherwise default
# to inbound DROP and block NFS, SMB and the ADR-0013 exporters.
HOST_FW=/etc/pve/nodes/$(hostname)/host.fw
if [ ! -f "$HOST_FW" ]; then
  printf '[OPTIONS]\n\nenable: 0\n' > "$HOST_FW"
elif ! grep -q '^enable: 0' "$HOST_FW"; then
  die "$HOST_FW exists without 'enable: 0'. Check it by hand before enabling the datacenter firewall."
fi

# Rules are evaluated top to bottom: DNS to the router before the LAN drop.
# ipfilter only allows the addresses in ipfilter-net0 (for VMs nothing is
# added implicitly except the IPv6 link-local address).
cat > /etc/pve/firewall/${VMID}.fw <<EOF
[OPTIONS]

enable: 1
ipfilter: 1
policy_in: DROP
policy_out: ACCEPT

[IPSET ipfilter-net0]

${IP}

[RULES]

IN SSH(ACCEPT) -source ${WORKSTATION_IP}
OUT DNS(ACCEPT) -dest ${GW}
OUT DROP -dest 192.168.1.0/24
OUT DROP -dest 100.64.0.0/10
OUT DROP -dest 224.0.0.0/4
OUT DROP -dest 255.255.255.255
EOF

CLUSTER_FW=/etc/pve/firewall/cluster.fw
if [ ! -f "$CLUSTER_FW" ]; then
  printf '[OPTIONS]\n\nenable: 1\n' > "$CLUSTER_FW"
elif ! grep -q '^enable: 1' "$CLUSTER_FW"; then
  die "$CLUSTER_FW exists without 'enable: 1'. Turn the datacenter firewall on by hand."
fi
pve-firewall compile >/dev/null
pve-firewall restart
pve-firewall status

# --- Second layer: host drops input from the sandbox ---------------------------
# Own table and unit, as ADR-0013. Never via /etc/nftables.conf (`flush
# ruleset` would wipe the Proxmox firewall too). Replies to connections the
# host opens are still allowed.
cat > /etc/nftables-sandbox.nft <<EOF
# Managed by 10-create-sandbox-vm.sh (ADR-0016)
table inet sandbox
delete table inet sandbox
table inet sandbox {
  chain input {
    type filter hook input priority filter; policy accept;
    ip saddr ${IP} ct state established,related accept
    ip saddr ${IP} drop
  }
}
EOF
nft -c -f /etc/nftables-sandbox.nft
cat > /etc/systemd/system/sandbox-firewall.service <<'EOF'
[Unit]
Description=Drop host input from the sandbox VM (ADR-0016)
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables-sandbox.nft
ExecStop=/usr/sbin/nft delete table inet sandbox

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sandbox-firewall
systemctl restart sandbox-firewall

# --- Start ----------------------------------------------------------------------
qm start "$VMID"
echo "Waiting for the guest agent (first boot runs cloud-init and package upgrades)..."
for _ in $(seq 1 60); do
  qm agent "$VMID" ping >/dev/null 2>&1 && break
  sleep 5
done
qm agent "$VMID" ping >/dev/null 2>&1 && echo "Guest agent up." || echo "No guest agent yet. Check the console: qm terminal $VMID"

qm config "$VMID"
cat <<NEXT

Next (see ../README.md), from the workstation:
  ssh sandbox@${IP} 'sudo bash -s' < infra/proxmox-sandbox/scripts/11-setup-sandbox-guest.sh
NEXT
