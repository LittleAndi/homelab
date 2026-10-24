# ADR-0012: Home Assistant OS VM with Z-Wave and Zigbee Sticks

**Status:** Accepted 2026-10-22 — VM deployed 2026-10-24 (HA 2026.10.3); radios not set up yet
**Date:** 2026-10-22

## Context

Two radio sticks are to be used for home automation on the server:

- **Aeotec Z-Stick Gen5** (Z-Wave, 500 series): `0658:0200`, `cdc_acm`,
  `/dev/ttyACM0`. The original Gen5 (not the Gen5+) is known to misbehave on
  USB 3 ports, and 500-series sticks can re-enumerate on USB when reset,
  which breaks VM passthrough unless handled.
- **Aeotec Zi-Stick** (Zigbee 3.0, Silicon Labs EFR32MG21): appears as a
  generic CH340 bridge `1a86:7523` (`ch341`, "USB Serial", no serial number),
  `/dev/ttyUSB0`. Works with ZHA and with Zigbee2MQTT (`ember` adapter).

Checked on the host 2026-10-22: both are plugged into the motherboard's rear
I/O USB ports and sit behind an onboard Genesys USB 2.0 hub (`05e3:0610`,
bus 7, ports 7-1.2 and 7-1.3), so the Gen5 runs on USB 2.

The cluster (ADR-0008) is built with host scripts, Terraform (`bpg/proxmox`,
`terraform@pve`) cloning a cloud-init template, and Ansible. Host RAM: 32 GB,
of which the cluster VMs use 17 GB fixed.

## Decision

### 1. Home Assistant OS in its own VM, outside the cluster

- VM **110 `haos`**, Home Assistant OS from the official qcow2 image.
- Sized as small as possible with some headroom: **2 vCPU** (`host`),
  **3 GB fixed RAM** (no ballooning, as for the cluster), **32 GB** disk on
  `local-zfs` (thin, `discard`, `ssd`). The HAOS VM guide's minimum is
  2 vCPU / 2 GB; the extra GB covers Z-Wave JS plus Zigbee2MQTT/Mosquitto.
  VMs total 20 GB, leaving ~12 GB for Proxmox, ARC and headroom.
- q35 + OVMF (HAOS needs UEFI), Secure Boot off, guest agent with trim,
  `onboot=1`.
- Static IP **192.168.1.25** (next free in the `.20–.63` server range), set
  inside HA after first boot; gateway and DNS 192.168.1.1.
- Both sticks passed through by **vendor:product ID** (`usb0: host=0658:0200`,
  `usb1: host=1a86:7523`), as USB 2 (no `usb3=1`). Because the CH340 ID is
  generic, the script refuses to run if more than one CH340 device is
  present; the fallback is passing the Zi-Stick by port (`host=7-1.3`).

### 2. Host scripts, not Terraform

`infra/proxmox-ha/scripts/10-create-haos-vm.sh` creates the VM, in the style
of the cluster's host scripts (`00`–`02`). Reasons: raw USB passthrough on a
VM can only be set by `root@pam` (the `terraform@pve` token would need a
Resource Mapping and extra privileges); keeping HA out of the cluster's
Terraform state means a cluster `apply`/`destroy` never touches it; and HAOS
manages itself after creation (OS updates, config from HA backups), so
Terraform would only ever create it once. Template 9000, cloud-init and
Ansible don't apply to HAOS.

### 3. Radio software

- Z-Wave: the Z-Wave JS add-on. Take an NVM backup of the stick before
  pairing devices; firmware 1.2 is recommended; disable "soft reset" if the
  stick drops after restarts.
- Zigbee: ZHA or Zigbee2MQTT + Mosquitto. **Not decided yet**; 3 GB RAM
  covers either.

### 4. Access

Tailscale add-on in HAOS (`homeassistant.{tailnet}.ts.net`, HTTPS from
Tailscale), matching ADR-0007/0010's tailnet-only principle. On the LAN,
`192.168.1.25:8123`. The Tailscale Kubernetes operator only serves cluster
services and doesn't apply.

### 5. Backups

`infra/proxmox-ha/scripts/11-setup-ha-backups.sh`, following ADR-0008's
"one dataset + one NFS export per consumer":

- Dataset `hdd-mirror/ha-backups`, quota 50G, NFS-exported only to
  192.168.1.25 with **`root_squash`** (directory owned by 65534).
- HA's own backups go there as a network storage location (daily automatic).
- Sanoid `template_data` on the dataset; hourly syncoid at :20 to
  `hgst/backup/ha-backups` (`template_backup` pruning), same as
  `hdd-mirror/k8s` (ADR-0011). It joins the Azure upload once §3 of
  ADR-0011 exists.
- The VM disk itself is not snapshotted (ADR-0011 policy). Restore = new VM
  from script 10 + restore an HA backup.

## Alternatives considered

- **Pods in MicroK8s** (Z-Wave JS UI, Zigbee2MQTT, HA container). Sticks
  would be passed into one worker, pods pinned and privileged, and the
  cluster's scheduling gains nothing for single-consumer hardware. Cluster
  rebuilds/upgrades would also take home automation down.
- **HA Container in an LXC**: lighter, but no Supervisor/add-ons, so Z-Wave
  JS, Zigbee2MQTT and MQTT would be run and updated by hand.
- **Terraform for the VM**: see §2.
- **Separate Raspberry Pi**: extra hardware for something the server has
  room for.

## Consequences

- One more VM on the host; the host is still a single point of failure for
  automations (devices keep their local controls).
- 3 GB of host RAM allocated permanently.
- New NFS export and a second syncoid timer on the HGST.
- The Zi-Stick's generic USB ID must stay unique on the host, or it moves to
  port-based passthrough.

## Update 2026-10-24: deployed

- **VM:** script 10 created and started VM 110; Home Assistant **2026.10.3**.
  Static IP 192.168.1.25 set in Settings → System → Network.
- **Web UI port is 80, not 8123.** Since HA 2026.8, HAOS serves the UI on
  port 80 by default. LAN URL: `http://192.168.1.25`. The `:8123` in §4,
  the proxmox-ha README and script 10's output is outdated.
- **Tailscale:** Tailscale app (formerly add-on) logged in to the tailnet,
  key expiry disabled, "Share Home Assistant" set to **Serve** (not Funnel).
  Serve only came up once HA trusted the proxy: since 2026.8 that is set in
  the UI (Settings → System → Network → HTTP server: Trust
  X-Forwarded-For on, trusted proxy `127.0.0.1`), not in
  `configuration.yaml`. Saving restarts HA and must be confirmed within
  5 minutes or it rolls back. HTTPS works at
  `https://homeassistant.{tailnet}.ts.net`.
- **Backups:** script 11 ran cleanly: `hdd-mirror/ha-backups` (quota 50G)
  exported to .25 only with `root_squash`, added to Sanoid, first syncoid
  to `hgst/backup/ha-backups` done (target read-only),
  `syncoid-ha-backups.timer` hourly at :20. HA's network storage added as
  the backup location; a test backup landed as a `.tar` owned by
  `nobody:nogroup`, so writes through `root_squash` work.
- HA backups are encrypted: the encryption key (emergency kit) must be kept
  in the password manager, or the backups can't be restored.

## Open items

- ~~Run scripts 10 and 11; set the static IP; add the NFS backup location.~~
  Done 2026-10-24.
- Store the HA backup encryption key in the password manager.
- Fix `:8123` → port 80 in `infra/proxmox-ha/README.md` and in script 10's
  final output.
- Choose ZHA or Zigbee2MQTT. With ZHA, 2 GB RAM would do.
- Z-Stick: NVM backup, firmware 1.2 check.
- Short USB extension cables for both sticks.
