# ADR-0017: IronWolf 8 TB ZFS Mirror for Bulk Media and Backups; Selective Off-Site

**Status:** Accepted — pool not created yet (waits for the self-tests, ADR-0009 update 2026-10-28)
**Date:** 2026-10-28

## Context

- Two used IronWolf 8 TB drives (ST8000VN004, CMR) are installed and
  verified empty (ADR-0009, update 2026-10-28). They replace the planned
  6 TB drives that ADR-0011 named as "the long-term answer" for bulk data.
- The migration upload in the old Azure account was ~1.43 TiB. About
  400 GiB of it (the `tmp` folder) was pulled to `hgst/bulk` on 2026-09-27
  and counted as replaceable (no backup). The other ~1 TiB is still there,
  waiting for room. Its SAS expired 2026-09-28, so the contents can't be
  listed right now.
- `hgst` (one old 1 TB laptop disk) is at 67%: `hgst/bulk` 400G of a 450G
  quota, `hgst/backup` 223G. It has no room for the rest of the migration
  data and no redundancy.
- Off-site (Azure, ADR-0011 §3) is paid per GiB-month. Today it holds only
  `hdd-mirror/k8s` (207 GiB). Off-site copies for all of the bulk data
  cost more than it's worth, so only what can't be replaced should go off-site.

## Decision

### 1. Pool `tank`: a ZFS mirror of the two IronWolfs

```bash
zpool create -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa \
  tank mirror \
  /dev/disk/by-id/ata-ST8000VN004-3CP101_{ironwolf-serial-1} \
  /dev/disk/by-id/ata-ST8000VN004-2M2101_{ironwolf-serial-2}
```

~7.2 TiB usable. The pool is named for what it holds, not the hardware.
Created only after both extended self-tests show "Completed without error"
(and after the burn-in, if one is run).

### 2. Datasets are the off-site boundary

Whether data goes off-site is set per **dataset**, never per folder. It
must be clear from where a file sits whether it has an off-site copy.

| Dataset | Holds | Snapshots | Off-site |
|---|---|---|---|
| `tank/media` | Bulk media that can be re-ripped, re-downloaded or lived without: the migration data by default | Sanoid `media`: daily 7, monthly 3 (covers accidental deletes; cheap, since media rarely changes) | **No** |
| `tank/archive` | Irreplaceable bulk: own photos/video, documents, anything without another source | Sanoid `data` (24/30/6, as `hdd-mirror/k8s`) | **Yes**, own Azure prefix |
| `tank/backup` | Backups of other things (see §4) | Per source | Only if the source has none |

```bash
zfs create -o recordsize=1M tank/media
zfs create -o recordsize=1M tank/archive
zfs create tank/backup
```

`recordsize=1M` suits large sequential media files. Quotas aren't needed
on a 7 TiB pool yet; add them if one dataset starts crowding the others.

**Rule for the migration data:** everything lands in `tank/media`.
Something moves to `tank/archive` only when it's judged irreplaceable.
The default is no off-site copy, and `tank/archive` stays small.

### 3. Moving the data in

1. `hgst/bulk` → `tank/media`: `zfs send` a snapshot, receive into
   `tank/media/…` (or `rsync`; it's 400 GiB of large files). Point the Samba
   `[bulk]` share at `/tank/media`. After checking the copy, destroy
   `hgst/bulk` (ask first, CLAUDE.md rule 5). That frees ~400G on `hgst`.
2. The remaining ~1 TiB from the old migration container: a new short-lived
   **Read + List** SAS, `rclone copy` into `/tank/media/` on the host (as in
   ADR-0011's update 2026-09-27, as a `systemd-run` unit), **in batches
   within the egress budget of §7**, not in one go. Network time is not the
   limit (~272 Mbit/s → ~100 GB in about an hour).
3. Sort: move the irreplaceable parts to `tank/archive` (`mv` across datasets
   is a copy plus a delete).
4. Once everything is home and checked, delete the old container or account
   (ask first). The data then exists only at home, plus whatever
   `tank/archive` has off-site. Parts already home and on the mirror (the
   400 GiB `tmp`, then each batch) can be deleted from Azure as they land,
   so the storage bill shrinks along the way.

### 4. `tank/backup`

The place for backups that have no home yet. Candidates, each to be decided
when it's set up:

- PC backups from `{workstation}` over SMB (its own share and dataset,
  not `[bulk]`).
- `vzdump` / PBS of the VMs (ADR-0011 §1 left VM-level backups for later).
- Optionally the second local copy of `hdd-mirror/k8s` (today
  `hgst/backup/k8s`). A mirror is a better target than one old laptop disk,
  but the HGST copy works and is a separate pool. Not moved by this ADR.

### 5. Off-site for `tank/archive`

Same mechanism as ADR-0011 §3 (a newest-daily snapshot, `rclone sync` with
`--backup-dir`), in the existing storage account and crypt remote
(`{offsite-crypt-remote}:archive/`). The tier is decided once the size is
known. Cold or Archive are cheaper than Cool for data that's written once
and rarely read, but they have longer minimum retention and read/early-delete
fees, and Archive blobs can't be read or server-side copied without
rehydration (that breaks `--backup-dir`). Not set up until `tank/archive`
has content.

### 6. Monitoring

- Monthly `zpool scrub`: Debian's `zfsutils-linux` cron scrubs all pools
  on the second Sunday at 00:24 (`/etc/cron.d/zfsutils-linux`,
  checked 2026-10-28), so `tank` is included once it exists. zed reports to
  Discord (ADR-0015).
- smartd already covers the disks (`DEVICESCAN`). Scheduled self-tests and
  temperature limits are an open item (ADR-0009).

### 7. Egress budget: Azure downloads cost money

Downloading from Azure is billed; uploading isn't. List prices, Sweden
Central, USD, checked 2026-10-28 via the Azure Retail Prices API
(`prices.azure.com`). The old migration account's region and tier are
**not confirmed yet**:

| | Hot | Cool | Cold | Archive |
|---|---|---|---|---|
| Storage, per GB-month | 0.0184 | 0.010 | 0.0036 | 0.00099 |
| Retrieval, per GB | 0 | 0.01 | 0.03 | 0.024 + rehydration |
| Minimum retention | — | 30 d | 90 d | 180 d |

Internet egress: **first 100 GB per month free** (for the whole billing
account, all regions and services), then 0.087/GB.

Rules:

- **Default: stay inside the free 100 GB per month.** Each batch is
  `rclone copy … --max-transfer 95G --cutoff-mode soft` (the 5 GB margin
  covers restore tests and other small downloads in the same month).
  `rclone copy` skips files that are already home, so the same command
  resumes the next month.
- **Waiting isn't free either:** whatever's still in Azure keeps paying for
  storage. A GB is worth holding for a free month only while
  `months waited × storage price < 0.087`: about 4–5 months on Hot, 8–9
  on Cool. Data that would wait longer is cheaper to pull now and pay for.
  The plan is recalculated once the old account's tier and the file list
  are known.
- **Cheapest of all: don't download it.** List the container first
  (listing costs fractions of a cent) and delete what isn't wanted straight
  in Azure.
- Other downloads count against the same 100 GB: off-site restore tests
  (ADR-0011 §3), `rclone check`/`cryptcheck` (they read the data). Uploads and
  the nightly off-site sync are free in transfer terms (they pay only for
  operations).
- The Azure 400 GiB from 2026-09-27 (ADR-0011) went far past the free
  allowance (~330 GB billed, roughly $29 at today's list price).

**Tracking:** every batch gets a row in the log below (date, GB
downloaded that month from all sources, cumulative, what's left). Before a
batch, check the month's earlier rows and the Azure cost view. Rows are
added in this ADR, no new Update section per batch.

| Month | Batch | GB from Azure this month | Migration data home (cumulative) | Not home yet |
|---|---|---|---|---|
| 2026-09 | `tmp` (ADR-0011) | ~430 | ~430 GB (400 GiB) | ~1.1 TB |

## Alternatives considered

- **mdadm or btrfs mirror.** Rejected: everything else on the host is ZFS
  (sanoid/syncoid, zed, scrub, `zfs send`), and ZFS checksums detect bit
  rot on media that's read rarely.
- **Off-site for all bulk data.** Rejected on cost: ~1.4 TiB plus growth,
  for data that's mostly replaceable.
- **Per-folder include/exclude lists for the off-site sync.** Rejected:
  easy to get wrong silently. A dataset boundary is visible in the path and
  in `zfs list`.
- **Keep `bulk` on `hgst` and use `tank` only for new data.** Rejected:
  `hgst` is full and has no redundancy; the migration data belongs on the
  mirror.

## Consequences

- `tank/media` has no off-site copy. Losing the server (fire, theft) loses
  it. Accepted: it's replaceable by definition. `tank/archive` is what's
  protected, so the sorting in §3.3 matters.
- After the migration data is home and the old container is deleted,
  anything that wasn't moved to `tank/archive` has a single copy (the
  mirror plus snapshots).
- Two used, out-of-warranty drives with different ages (2021, 2023) in one
  mirror. Different batches lower the risk of both failing together. A
  failed drive is replaced at own cost.
- `hgst` keeps only `hgst/backup` after `bulk` moves (~223G of 928G). Its
  free space has no role yet.
- Off-site cost grows only with `tank/archive`.

## Open items

- Create `tank` and the datasets after the self-tests (and optional burn-in).
- Move `hgst/bulk` → `tank/media`, repoint Samba, then destroy `hgst/bulk`
  (ask first).
- Confirm the old migration account's region and tier (`az storage account
  show`) and this month's egress (Azure cost view); then fix the batch plan
  (§7).
- New Read + List SAS for the old container; list it, delete what isn't
  wanted in Azure, then pull the rest into `tank/media` in batches (§7),
  logging each one.
- Delete `tmp` (400 GiB, already home) from the old container once it's on
  `tank` (ask first): it's paying storage for a copy that's no longer needed.
- Sort irreplaceable data into `tank/archive`; then choose the Azure tier and
  extend the off-site sync to `archive/`.
- Delete the old migration container or account once everything is home
  (ask first).
- Decide which backups go to `tank/backup` (PC, vzdump/PBS, k8s replica).
