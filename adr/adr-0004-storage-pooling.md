# ADR-0004: Storage Pooling Strategy — mergerfs, SnapRAID Deferred

**Status:** **Superseded by ADR-0008** (2026-09-21)
**Date:** 2026-08-18

## Context

The server will run Nextcloud, and its file storage needs to be easily
expandable over time — adding drives of mismatched sizes without rebuilds.
Options considered: ZFS, Btrfs, LVM, and mergerfs+SnapRAID. Protection
against drive failure was explicitly rated "nice to have, not critical,"
since the existing Azure backup (ADR-0003) already serves as disaster
recovery.

## Decision

- Use **mergerfs** to pool individual data disks (starting with disk1 1TB +
  disk2 2TB) into a single unified mount point, using the `mfs` (most free
  space) policy for new file placement.
- **Do not deploy SnapRAID at initial launch.** It remains an optional future
  addition — a dedicated parity disk sized ≥ the largest data disk — if
  scheduled protection against a single drive failure becomes desirable
  later.

## Alternatives considered

- **ZFS** — stronger integrity guarantees (checksumming, self-healing,
  real-time protection) but historically less flexible for adding single
  mismatched-size drives to an existing RAIDZ vdev, and a heavier RAM
  footprint. Worth revisiting if the server's role expands (VMs, databases)
  or if scheduled-only parity protection stops being acceptable.
- **Btrfs** — flexible native multi-device pooling and live rebalancing, but
  its parity modes (RAID5/6) are not considered production-safe.
- **LVM** — simplest volume growth across disks, but no built-in redundancy.

## Consequences

- Files are not striped — a single file's read/write speed is capped by
  whichever physical disk it lives on.
- Growing the pool later is simple: format the new drive, mount it, add it
  to the mergerfs config — no rebuild required.
- If SnapRAID is added later, the parity disk must be ≥ the size of the
  largest data disk at all times, and coverage only reflects the last sync
  (not real-time).

## Update 2026-09-21

ADR-0008 (proposed) replaces mergerfs with ZFS: the two 2TB HDDs as a mirror vdev, NFS-exported to the cluster. This is the "server's role expands (VMs, databases)" case this ADR anticipated for revisiting ZFS.

## Update 2026-09-21: superseded

ADR-0008 is accepted and deployed. mergerfs is not used: the two 2TB WD HDDs
are a ZFS mirror (`hdd-mirror`), and bulk data lives in the dataset
`hdd-mirror/k8s`, NFS-exported to the cluster. SnapRAID is no longer
relevant; the mirror gives real-time redundancy. The Azure backup
(ADR-0003) remains the disaster-recovery anchor.
