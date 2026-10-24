# ADR-0009: Storage Expansion — LSI SAS 9211-8i HBA; Disk Inventory

**Status:** Accepted — implemented 2026-10-20 with an **LSI SAS 9300-8i** instead of the 9211-8i (see Update). Disk roles partly open: HGST decided in ADR-0011 (2026-09-26); Seagate and Samsung SSD still without a role.
**Date:** 2026-09-21

## Context

The Asrock B650M-HDV/M.2 has 4 onboard SATA ports (ADR-0001), while the
Jonsbo N6 has 9 hot-swap bays. More drives have been collected than the board
can attach directly.

## Decision

Add an **LSI SAS 9211-8i HBA flashed to IT mode** for SATA expansion before
filling the N6's remaining bays. IT mode passes disks straight through to
the OS, which ZFS needs.

## Disk inventory

| Disk | Size | Role |
|---|---|---|
| 1TB SSD | 1 TB | Proxmox + VM boot disks (`local-zfs`), per ADR-0008 |
| WDC WD2002FAEX-007BA0 ({wd-serial-1}) | 2 TB | ZFS mirror `hddmirror` (ADR-0008) |
| WDC WD2002FAEX-007BA0 ({wd-serial-2}) | 2 TB | ZFS mirror `hddmirror` (ADR-0008) |
| HGST HTS721010A9E630 | 1 TB (HDD) | **Undecided** → pool `hgst` (ADR-0011, see Update) |
| Seagate ST1000LM035-1RK172 | 1 TB (HDD) | **Undecided** |
| 6 TB HDD (×1, later ×2 as mirror) | 6 TB | Planned, not purchased |

Candidate uses for the two 1TB HDDs: a local Proxmox Backup Server target,
a VM storage pool (the role the 6TB drive was planned for), or scratch space
for playground VMs.

## Consequences

- Uses one PCIe slot. That affects the still-open option of adding a
  discrete GPU.
- The HBA must be confirmed in IT mode (not IR/RAID) before any disks go into a ZFS pool.

## Update 2026-09-26: live disk inventory

Checked on the host (`lsblk`, `/dev/disk/by-id`, `lspci`):

| Device | Disk | Role |
|---|---|---|
| `nvme0n1` | Samsung MZVLB1T0HBLR 1 TB NVMe | `rpool` (Proxmox + VM disks) |
| `sda` | WD2002FAEX ({wd-serial-1}) | `hdd-mirror` |
| `sdb` | WD2002FAEX ({wd-serial-2}) | `hdd-mirror` |
| `sdc` | HGST HTS721010A9E630 ({hgst-serial}) | **Pool `hgst`: local backup + bulk data (ADR-0011)** |
| `sdd` | Samsung MZ7TD512 512 GB SATA SSD | Unused. Old Windows install (EFI + NTFS); not in the original inventory |
| — | Seagate ST1000LM035 1 TB | **Not installed.** SMR drive; no role |
| — | LSI SAS 9211-8i | **Not installed** (`lspci` shows no SAS controller) |

- All 4 onboard SATA ports are in use. Adding the Seagate needs the HBA or
  removing the Samsung.
- The HGST role is decided in ADR-0011. The Seagate and Samsung stay open.

## Update 2026-10-20: LSI SAS 9300-8i installed

**Card changed from the Decision.** A used **LSI SAS 9300-8i** (Broadcom
SAS3008, PCIe 3.0 x8, 2× SFF-8643) was bought on 2026-10-14 instead of the
9211-8i, and instead of the 6-port PCIe x4 SATA cards looked at on 2026-10-07.
It came with full-height and low-profile brackets and two SFF-8643 → 4× SATA
forward-breakout cables. The seller's `sas3flash` showed IT firmware. Installed
and booted 2026-10-20. The intent of the Decision (IT-mode HBA for SATA
expansion) is unchanged; only the model differs.

Verified on the host:

- **Detection:** `01:00.0 … SAS3008 PCI-Express Fusion-MPT SAS-3 [1000:0097]
  (rev 02)`, driver `mpt3sas` 54.100.00.00, `port enable: SUCCESS`.
- **Firmware / mode:** `FWVersion(16.00.10.00)` (Phase 16).
  `Protocol=(Initiator,Target)` with no `Raid` capability, so **IT mode is
  confirmed**, which clears the IT-mode precondition in Consequences. No
  option ROM loaded (no BIOS version in `dmesg`), so it doesn't affect boot
  time or boot order. 16.00.12.00 is a later point release; no need to flash
  unless a problem shows up.
- **PCIe link:** `LnkCap` 8GT/s x8, `LnkSta` 8GT/s **x4**. PCIe 3.0 x4
  (~3.9 GB/s) is far above what HDDs need (8 × ~200 MB/s ≈ 1.6 GB/s); it
  would only limit 7–8 SATA SSDs. Expected if the card sits in the lower
  slot, which was the plan to keep PCIE1 free for the GPU (slot not
  confirmed in this session).
- **Attached disk:** the Seagate ST1000LM035 ({seagate-serial}) on phy 6, SATA link
  at 6.0 Gb/s through the HBA. `smartctl` works through the card with no
  `-d` option. SMART PASSED; 0 reallocated / pending / uncorrectable,
  **0 CRC errors** (the breakout cable is fine), 8,562 power-on hours,
  Load_Cycle_Count 22,189, 24 °C. **Extended self-test: "Completed without
  error"** (finished at 8,565 h, 2026-10-20 evening). The drive is healthy;
  it still has no role (SMR).

Side effects of the new controller:

- **Disk letters shifted.** Drives didn't move; the kernel assigned names in
  a new order. The order is not guaranteed between boots, so use
  `/dev/disk/by-id/…` in commands and notes, never `sdX`.

  | Device | Disk | Path | Role |
  |---|---|---|---|
  | `nvme0n1` | Samsung MZVLB1T0HBLR 1 TB NVMe | NVMe | `rpool` |
  | `sda` | Seagate ST1000LM035 ({seagate-serial}) | HBA phy 6 | **No role** (SMR) |
  | `sdb` | WD2002FAEX ({wd-serial-1}) | onboard SATA 1 | `hdd-mirror` |
  | `sdc` | WD2002FAEX ({wd-serial-2}) | onboard SATA 2 | `hdd-mirror` |
  | `sdd` | HGST HTS721010A9E630 ({hgst-serial}) | onboard SATA 3 | `hgst` (ADR-0011) |
  | `sde` | Samsung MZ7TD512 512 GB SATA SSD | onboard SATA 4 | Unused |

- Nothing broke: the pools import by-id (all ONLINE, no errors), the HGST's
  APM udev rule matches by serial (`APM_level = 254` after the reboot), and
  smartd's `DEVICESCAN` finds disks by scanning.
- PCI bus numbers shifted: the Wi-Fi interface is now `wlp6s0` (was
  `wlp5s0`). Harmless, since Wi-Fi is disabled. `nic0` is pinned by MAC and
  came up at 1000 Mb/s. A leftover `wlp5s0` stanza in
  `/etc/network/interfaces`, if any, now points at nothing.
- After boot: `vmbr0` up on .10, VMs 101–105 running, `sanoid.timer` and
  `syncoid-k8s.timer` caught up and scheduled, NFS export limited to the
  5 node IPs.

Capacity: 4 onboard + 8 HBA ports = 12, more than the N6's 9 bays. SATA
ports are no longer the limit.

Open items:

- ~~Record the Seagate's extended self-test result.~~ Done: completed
  without error.
- Check the HBA heatsink temperature under sustained use. The SAS3008 is
  built for server airflow; overheating shows up as `mpt3sas` resets and
  dropped disks in `dmesg`.
- Roles for the Seagate (SMR) and the Samsung 512 GB SSD.
- 6 TB purchase; GPU use.
