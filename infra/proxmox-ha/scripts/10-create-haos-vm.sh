#!/bin/bash
# Run ONCE on the Proxmox host as root.
# Creates the Home Assistant OS VM (ADR-0012): VMID 110, 2 vCPU, 3 GB fixed
# RAM, 32 GB disk on local-zfs, UEFI, with the Z-Wave and Zigbee sticks
# passed through by USB ID.
#
# Not in Terraform on purpose: raw USB passthrough (usbN: host=...) can only
# be set by root@pam, and HAOS manages itself after creation (OS updates,
# config restored from HA backups).
#
# Usage:  ./10-create-haos-vm.sh                 # latest HAOS release
#         HAOS_VERSION=17.0 ./10-create-haos-vm.sh
set -euo pipefail

VMID=110
NAME="haos"
STORAGE="local-zfs"      # SSD. OS disks never go on hdd-mirror (ADR-0008)
CORES=2
MEMORY=3072              # fixed, no ballooning, same as the cluster VMs
DISK_SIZE_GB=32          # HAOS keeps two OS slots; don't go smaller
BRIDGE="vmbr0"
ZWAVE_USB="0658:0200"    # Aeotec Z-Stick Gen5, rear USB 2.0 (port 7-1.2)
ZIGBEE_USB="1a86:7523"   # Aeotec Zi-Stick, generic CH340 bridge (port 7-1.3)
IMG_DIR="/var/lib/vz/template/iso"
HAOS_VERSION="${HAOS_VERSION:-}"   # empty = latest release on GitHub

die() { echo "$*" >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 || die "$BRIDGE does not exist."
if qm status "$VMID" >/dev/null 2>&1; then
  die "VMID $VMID already exists. Remove it first: qm destroy $VMID"
fi

# Both sticks must be present. The Zi-Stick's CH340 ID is generic: if a
# second CH340 device (e.g. an ESP32 board) is plugged in, passing by ID is
# ambiguous, so stop and pass it by port instead.
lsusb -d "$ZWAVE_USB" >/dev/null || die "Z-Stick ($ZWAVE_USB) not found in lsusb."
n_ch340="$(lsusb -d "$ZIGBEE_USB" | wc -l || true)"
case "$n_ch340" in
  1) ;;
  0) die "Zi-Stick ($ZIGBEE_USB) not found in lsusb." ;;
  *) die "Found $n_ch340 devices with ID $ZIGBEE_USB (CH340). Unplug the others, or edit this script to use usb1: host=7-1.3 (pass by port)." ;;
esac

# --- Image ------------------------------------------------------------------
if [ -z "$HAOS_VERSION" ]; then
  HAOS_VERSION="$(curl -fsSL https://api.github.com/repos/home-assistant/operating-system/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$HAOS_VERSION" ] || die "Could not determine the latest HAOS version. Set HAOS_VERSION=xx.y and re-run."
fi
echo "HAOS version: $HAOS_VERSION"

IMG="$IMG_DIR/haos_ova-${HAOS_VERSION}.qcow2"
URL="https://github.com/home-assistant/operating-system/releases/download/${HAOS_VERSION}/haos_ova-${HAOS_VERSION}.qcow2.xz"

command -v unxz >/dev/null || { apt update && apt install -y xz-utils; }
if [ -f "$IMG" ]; then
  echo "Image already downloaded, skipping fetch."
else
  wget -O "$IMG.xz" "$URL"
  unxz "$IMG.xz"
fi

# --- VM -----------------------------------------------------------------------
# q35 + OVMF: HAOS requires UEFI. pre-enrolled-keys=0: Secure Boot off.
# CPU host: single host, never migrated (same as the cluster).
# discard + ssd + agent trim: thin-provisioned ZFS gets freed space back.
# USB ports are passed as USB 2 (usb3 option not set), which the Gen5 needs.
qm create "$VMID" \
  --name "$NAME" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" \
  --cpu host \
  --cores "$CORES" \
  --memory "$MEMORY" --balloon 0 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-pci \
  --scsi0 "${STORAGE}:0,import-from=${IMG},discard=on,ssd=1" \
  --boot order=scsi0 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --usb0 "host=${ZWAVE_USB}" \
  --usb1 "host=${ZIGBEE_USB}" \
  --onboot 1

# The HAOS image is 32 GB virtual already; only grow if a release ships smaller.
img_bytes="$(qemu-img info --output=json "$IMG" | sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -n1)"
if [ "$(( img_bytes / 1024**3 ))" -lt "$DISK_SIZE_GB" ]; then
  qm disk resize "$VMID" scsi0 "${DISK_SIZE_GB}G"
fi

qm start "$VMID"

# HAOS ships qemu-guest-agent; use it to find the DHCP address of the first boot.
echo "Waiting for the guest agent (first boot takes a minute or two)..."
IP=""
for _ in $(seq 1 60); do
  IP="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
    | grep -o '"ip-address" *: *"192\.168\.1\.[0-9]*"' | grep -o '192\.168\.1\.[0-9]*' | head -n1 || true)"
  [ -n "$IP" ] && break
  sleep 5
done

qm config "$VMID"
echo
if [ -n "$IP" ]; then
  echo "HAOS is up at http://${IP}:8123 (DHCP). Onboarding can take a few minutes."
else
  echo "No IP from the guest agent yet. Check the VM console in the Proxmox UI."
fi
cat <<'NEXT'

Next steps (see ../README.md):
  1. Finish onboarding in the browser.
  2. Set the static IP: Settings > System > Network > IPv4 static,
     192.168.1.25/24, gateway 192.168.1.1, DNS 192.168.1.1. Reconnect on .25.
  3. Run scripts/11-setup-ha-backups.sh on the host, then add the NFS
     backup location in HA.
NEXT
