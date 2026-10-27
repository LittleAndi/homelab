#!/bin/bash
# Run INSIDE the sandbox VM as root, once after 10-create-sandbox-vm.sh:
#   ssh sandbox@192.168.1.26 'sudo bash -s' < infra/proxmox-sandbox/scripts/11-setup-sandbox-guest.sh
#
# Sets up the guest (ADR-0016): IPv6 off, zram, Docker Sandboxes (`sbx`,
# microVMs on nested KVM; no Docker Engine), key-only SSH, unattended
# upgrades. Ends with the isolation checks and a reboot (for ipv6.disable=1).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
. /etc/os-release

echo "== 1/6 IPv6 off (kernel parameter, so no interface can bring it back)"
cat > /etc/default/grub.d/99-sandbox.cfg <<'EOF'
# ADR-0016: IPv6 off, so the IPv4-only firewall rules can't be bypassed.
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT ipv6.disable=1"
EOF
update-grub

echo "== 2/6 Trim memory: drop snapd and unused services"
apt-get purge -y --autoremove snapd 2>/dev/null || true
for s in multipathd ModemManager; do
  systemctl disable --now "$s" 2>/dev/null || true
done

echo "== 3/6 zram (zstd, half of RAM); no other swap"
apt-get update
apt-get install -y systemd-zram-generator unattended-upgrades ca-certificates curl
cat > /etc/systemd/zram-generator.conf <<'EOF'
# ADR-0016: burst headroom for the 2 GB guest. RAM-backed, not a zvol.
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service

echo "== 4/6 Docker Sandboxes (sbx) from Docker's apt repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update || { echo "Docker's repository has no '${VERSION_CODENAME}' suite yet?" >&2; exit 1; }
# No Docker Engine: each sandbox is a microVM with its own daemon.
apt-get install -y docker-sbx
usermod -aG kvm sandbox

echo "== 5/6 SSH key-only, unattended upgrades on"
cat > /etc/ssh/sshd_config.d/90-sandbox.conf <<'EOF'
# ADR-0016
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sshd -t && systemctl reload ssh
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "== 6/6 Checks"
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }
blocked() {   # host port: must NOT connect
  if timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; then bad "$1:$2 reachable"; else ok "$1:$2 blocked"; fi
}
curl -fsS -m 5 -o /dev/null https://example.com && ok "internet (https)" || bad "internet (https)"
getent hosts example.com >/dev/null && ok "DNS" || bad "DNS"
for p in 8006 22 2049 445; do blocked 192.168.1.10 "$p"; done
blocked 192.168.1.20 16443
ping -c1 -W2 192.168.1.25 >/dev/null 2>&1 && bad "ping .25 answered" || ok "ping .25 blocked"
sudo -u sandbox -g kvm test -w /dev/kvm && ok "/dev/kvm usable by sandbox" || bad "/dev/kvm"
command -v sbx >/dev/null && ok "sbx $(sbx version 2>/dev/null | head -1)" || bad "sbx missing"
zramctl | grep -q zram0 && ok "zram0" || bad "zram0"

if [ "$fail" -ne 0 ]; then
  echo "Some checks failed; not rebooting. Fix the firewall before running anything in here." >&2
  exit 1
fi
echo "All checks passed. Rebooting for ipv6.disable=1."
systemctl reboot
