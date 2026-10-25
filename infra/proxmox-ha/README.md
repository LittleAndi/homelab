# Home Assistant OS VM — setup order

Creates the Home Assistant VM designed in
[ADR-0012](../../adr/adr-0012-home-assistant-vm.md): HAOS on Proxmox, separate
from the MicroK8s cluster, with the Aeotec Z-Stick Gen5 (Z-Wave) and Zi-Stick
(Zigbee) passed through. Plain host scripts, no Terraform (USB passthrough
needs `root@pam`; HAOS manages itself after creation).

| | |
|---|---|
| VM | 110 `haos`, 2 vCPU (`host`), 3 GB fixed (no balloon), 32 GB on `local-zfs`, q35 + OVMF, Secure Boot off |
| IP | 192.168.1.25 (static, set inside HA), gateway/DNS 192.168.1.1 |
| USB | `0658:0200` Z-Stick Gen5 → Z-Wave JS; `1a86:7523` Zi-Stick (CH340) → ZHA or Zigbee2MQTT |
| Backups | HA backups → NFS `hdd-mirror/ha-backups` (only to .25, `root_squash`) → Sanoid + hourly syncoid to `hgst/backup/ha-backups` |

## Run order

1. **On the Proxmox host** — create and start the VM:
   ```
   scripts/10-create-haos-vm.sh                  # latest HAOS
   HAOS_VERSION=xx.y scripts/10-create-haos-vm.sh   # or pin a version
   ```
   Stops if VMID 110 exists, if a stick is missing, or if more than one
   CH340 device is plugged in (then pass the Zi-Stick by port,
   `usb1: host=7-1.3`). Prints the first-boot DHCP address.

2. **In the browser** — onboarding at `http://<dhcp-ip>` (port 80; HA 2026.8+ no longer uses `:8123`), then
   *Settings > System > Network*: IPv4 static `192.168.1.25/24`, gateway and
   DNS `192.168.1.1`. Reconnect on `.25`.

3. **On the Proxmox host** — backup dataset, export, snapshots, replication:
   ```
   scripts/11-setup-ha-backups.sh
   ```
   Then in HA: *Settings > System > Storage > Add network storage* (NFS,
   server `192.168.1.10`, path `/hdd-mirror/ha-backups`, usage Backup), and
   make it the default backup location with automatic daily backups.

4. **In HA** — radios and access:
   - Z-Wave JS add-on on `/dev/serial/by-id/usb-0658_0200-if00`. Before
     pairing anything, take an NVM backup of the stick (Z-Wave JS UI or the
     integration's backup option). Consider updating the stick to firmware
     1.2 first (helps with USB re-enumeration in VMs, adds SmartStart). If
     the stick drops after restarts, disable "soft reset" in Z-Wave JS.
   - Zigbee on `/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0`: ZHA, or
     Zigbee2MQTT + Mosquitto with adapter `ember`. Pick a Zigbee channel
     clear of the Wi-Fi (e.g. 25).
   - Tailscale add-on for `homeassistant.{tailnet}.ts.net`.

## Notes

- The sticks sit on the board's rear USB 2.0 ports (onboard Genesys hub).
  Put them on short USB extension cables away from the case for range;
  keep them in the same ports.
- The VM disk is not snapshotted (ADR-0011 policy). Restore = new VM from
  script 10 + restore an HA backup from the NFS share.
- Growing the VM: `qm set 110 --memory 4096` or `qm disk resize 110 scsi0 +16G`,
  then reboot it. Shrinking the disk isn't possible.
