# ADR-0011: ZFS Snapshots, Local Backup Pool on the HGST, and Bulk Data

**Status:** Accepted 2026-09-26 — §1, §2 and §4 implemented 2026-09-26; bulk data moved in 2026-09-27; §3 (Azure) pending
**Date:** 2026-09-26

> The Decision section is the plan as accepted. The dated Update below records
> what changed during implementation; where they differ, the Update wins.

## Context

Checked the live Proxmox host on 2026-09-26:

- **No snapshots exist** apart from Proxmox's own `rpool/data/base-9000-disk-0@__base__`.
  No Sanoid, no snapshot timers. Nextcloud's data on `hdd-mirror/k8s` (197G,
  1.11x compression) has only the mirror, Nextcloud's trash/versions and the
  stale `{old-stack-dir}` copy (2026-09-25) behind it. The Azure/rclone backup
  (ADR-0008 open item) isn't pointed at it yet.
- `hdd-mirror` 1.81T, 10% allocated. `hdd-mirror/k8s` has a **500G
  `reservation`** (not `refreservation`), so snapshot space counts inside it.
- `rpool` 944G, 2% allocated. Control-plane zvols carry `refreservation=40G`,
  so a snapshot of one reserves roughly what it references (3–6G).
- Compression and `snapdir` are inherited defaults (lz4, hidden).
- `hdd-mirror/k8s` holds a single PVC directory
  (`nextcloud-nextcloud-data-pvc-…`, mode 777 from the NFS provisioner) with
  `data/` and `db-dumps/`. MariaDB and the app volume live on a node's boot
  zvol (`local-path-retain`), most likely cp3 / `vm-103-disk-0` (6.4G vs 3.3G
  on cp1/cp2; unverified).
- Unused drives: **HGST HTS721010A9E630** 1 TB (`sdc`, blank) and the Samsung
  MZ7TD512 512G SATA SSD (`sdd`, old Windows install). See ADR-0009 update.
- ~400 GiB of the ~1.43 TiB in Azure Blob storage is to be moved home. That
  data is replaceable and **needs no backup at all** — not locally, not in Azure.

## Decision

### 1. Snapshots with Sanoid on the host

`apt install sanoid`, config `/etc/sanoid/sanoid.conf`:

```ini
[hdd-mirror/k8s]
  use_template = data

[rpool/ROOT/pve-1]
  use_template = os

[template_data]
  hourly = 24
  daily = 30
  monthly = 6
  daily_hour = 3      # host local time (Europe/Stockholm) -> changed to 1 (UTC), see Update
  daily_min = 30      # 01:30 UTC in summer, 02:30 UTC in winter
  autosnap = yes
  autoprune = yes

[template_os]
  daily = 7
  autosnap = yes
  autoprune = yes
```

- Retention 24 hourly / 30 daily / 6 monthly (confirmed 2026-09-26).
- The daily snapshot is timed after the nightly `mariadb-dump` (01:00 UTC,
  not yet verified against the CronJob), so each daily snapshot holds a DB
  dump that matches its files (crash-consistent files + a complete dump).
  Sanoid uses the host's local time, so 03:30 local is 30 min after the dump
  in summer and 90 min in winter; the dump takes a few minutes. Sanoid's
  timer runs every 15 min, so the snapshot can land up to 15 min later. No
  maintenance-mode orchestration.
- **VM disks are not snapshotted.** The DB is covered by the dump on NFS; the
  cluster is rebuildable with Terraform/Ansible; snapshots of the three
  control-plane zvols taken at different moments can give an inconsistent
  dqlite state. VM-level backups, if wanted, go via `vzdump`/PBS in a later ADR.

### 2. HGST as a single-disk pool `hgst`

```bash
zpool create -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa \
  hgst /dev/disk/by-id/ata-HGST_HTS721010A9E630_{hgst-serial}
zfs create -o readonly=on hgst/backup    # syncoid target
zfs create -o quota=450G  hgst/bulk      # the ~400 GiB from Azure
```

- **`hgst/backup`**: `syncoid` (ships with Sanoid) replicates
  `hdd-mirror/k8s` into `hgst/backup/k8s` nightly, non-recursive. A second
  local copy on a separate disk and pool, which covers pool loss or a bad
  `zfs destroy` that the mirror doesn't.
- **`hgst/bulk`**: the data moved out of Azure. Not in `sanoid.conf`, not
  replicated, not synced to Azure. If the disk dies it is re-downloaded.
  The quota keeps it from crowding out the backups.
- Sizing: ~400G bulk + ~200G backup ≈ 600 of ~900 GiB usable (≈67%).
  Headroom before 80% is only ~120 GiB of Nextcloud growth/snapshot history;
  the 6 TB drives (ADR-0009) are the long-term answer, and `bulk` moves there
  with `zfs send` when they arrive.
- The mirror stays for data that matters; the HGST holds only copies or
  replaceable data.

**Drive health (2026-09-26):** SMART PASSED; 0 reallocated / pending /
uncorrectable, 0 CRC errors, 23,161 power-on hours, 26 °C.
Load_Cycle_Count **301,169** (drives of this class are usually rated around
600k), caused by aggressive head parking. Disable it and persist the setting:

```bash
hdparm -B 254 /dev/sdc
echo 'ACTION=="add", KERNEL=="sd*", ENV{ID_SERIAL_SHORT}=="{hgst-serial}", RUN+="/usr/sbin/hdparm -B 254 /dev/%k"' \
  > /etc/udev/rules.d/69-hgst-apm.rules
```

Head parking disabled 2026-09-26. Pool creation waits for the extended self-test started 2026-09-26 15:18
(ETA 18:10): `smartctl -l selftest /dev/sdc` must show
"Completed without error".

### 3. Off-site: Azure/rclone from a fixed-name snapshot

Before each rclone run, recreate `hdd-mirror/k8s@azure` and sync from
`/hdd-mirror/k8s/.zfs/snapshot/azure/<pvc-dir>/`. A fixed path, and the
upload is crash-consistent. Implements ADR-0008's open backup item. Script
to be written under `infra/`.

### 4. `bulk` over SMB from Samba on the host

The goal is a plain `net use` from the Windows PC. Samba runs directly on the
Proxmox host and shares `/hgst/bulk`. The simplest option: no VM, container
or cluster involved.

```bash
apt install samba
useradd -M -s /usr/sbin/nologin {user}     # Samba-only user, no shell
smbpasswd -a {user}
chown {user}:{user} /hgst/bulk
cp /etc/samba/smb.conf /etc/samba/smb.conf.orig
```

`/etc/samba/smb.conf` (replaces the default; no `[homes]`/`[printers]`):

```ini
[global]
   server string = pve
   server min protocol = SMB3
   map to guest = never
   hosts allow = 192.168.1. 100.64.0.0/10 127.
   hosts deny = 0.0.0.0/0
   load printers = no
   disable spoolss = yes

[bulk]
   path = /hgst/bulk
   valid users = {user}
   read only = no
   create mask = 0664
   directory mask = 0775
```

```bash
testparm -s && systemctl restart smbd && systemctl disable --now nmbd
```

From Windows: `net use Z: \\192.168.1.10\bulk /user:{user} /persistent:yes`
at home, or `\\pve\bulk` (Tailscale MagicDNS) from anywhere else. Reachable
from the LAN and the tailnet only; SMB3 only; no guest access. If the
Proxmox firewall is enabled, allow TCP 445 from those ranges.

**Tailscale:** the share accepts both. The LAN IP is preferred at home: it
has no WireGuard overhead, which matters when copying hundreds of GiB. The
tailnet path gives encrypted access away from home, and Tailscale grants can
narrow port 445 to specific devices. Binding Samba to `tailscale0` only
(`bind interfaces only`) was not chosen: `smbd` can start before
`tailscale0` exists at boot, and LAN clients would then have to go through
Tailscale too.

## Alternatives considered

- **Swap the Samsung SSD for the Seagate ST1000LM035 and stripe it with the
  HGST (~1.8 TB)** for backups + the 400 GiB. Rejected: a stripe fails
  completely if either old laptop drive fails, and the Seagate is SMR (slow
  sustained writes, bad resilvers).
- **The 400 GiB as `hdd-mirror/bulk`** (excluded from backups). Workable with
  no hardware change and disk-failure protection, but spends mirror capacity
  on replaceable data. The user preferred keeping the mirror for data that
  matters.
- **The Seagate as its own pool for `bulk`.** Needs the Samsung's SATA port
  (or the HBA), and it's SMR. The HGST (CMR, 7200 rpm) is already attached.
- **Bringing all 1.43 TiB home now.** Doesn't fit: it would push `hdd-mirror`
  past ~90%. Waits for the 6 TB drives.
- **Snapshotting VM zvols.** See §1.
- **Samba in an LXC container** (bind-mount `/hgst/bulk`). Keeps the host
  leaner and is the usual Proxmox pattern, but adds a container to maintain.
  The host option was chosen for simplicity; moving to an LXC later is easy.
- **NFS, Nextcloud external storage, or a pod in the cluster.** NFS is
  awkward on Windows; the other two add layers for data that only needs a
  drive letter.

## Consequences

- The HGST is a single point of failure for `bulk` (accepted: replaceable)
  and for the local backup copy (the original stays on the mirror).
- Nightly syncoid and heavy `bulk` use share one spindle for a short window.
- Samsung SSD and Seagate stay without a role (ADR-0009).
- Samba is a new service on the hypervisor itself, limited to LAN + tailnet.
- Until §1 and §3 run, Nextcloud data has no snapshot or off-site copy:
  keep the Podman stack's `{old-stack-dir}` and the migration dump until then
  (ADR-0010).

## Update 2026-09-26: implemented (§1, §2, §4)

- **Drive:** HGST extended self-test "Completed without error" (23,163 h).
  APM 254 set; the udev rule was verified by setting 128 and re-triggering
  udev, which restored 254.
- **Pool:** `hgst` created as in §2: `hgst/backup` (readonly),
  `hgst/bulk` (quota 450G). 679G free after the first copy.
- **Sanoid:** the Debian package doesn't create `/etc/sanoid/`
  (`mkdir -p /etc/sanoid` first). First snapshots taken by hand at 21:50
  local; `sanoid.timer` runs every 15 min.
- **Sanoid runs in UTC.** The packaged `sanoid.service` sets `TZ=UTC`, so
  timer-made snapshot names and `daily_hour` are UTC, not local time (the
  hand-run 21:50 snapshots are named in local time; harmless, they age out).
  `daily_hour` changed from 3 to **1**: the daily snapshot is at 01:30 UTC,
  30 min after the 01:00 UTC dump all year, with no DST drift.
- **Initial syncoid** `hdd-mirror/k8s` → `hgst/backup/k8s`: ~243 GiB
  estimate, 45 min at ~92 MiB/s; 218G referenced on the source, 220G on the
  target. The receive couldn't mount the new dataset because the read-only
  parent blocked creating its mountpoint directory. Fixed once with
  `zfs set readonly=off hgst/backup; zfs mount hgst/backup/k8s;
  zfs set readonly=on hgst/backup`. The directory persists, and the target
  inherits `readonly=on`, which also keeps incrementals from being refused
  over a modified target.
- **Target pruning:** in `sanoid.conf`:

  ```ini
  [hgst/backup/k8s]
    use_template = backup

  [template_backup]
    hourly = 24
    daily = 30
    monthly = 6
    autosnap = no
    autoprune = yes
  ```

- **Nightly replication:** `syncoid-k8s.service` (oneshot,
  `/usr/sbin/syncoid --no-sync-snap hdd-mirror/k8s hgst/backup/k8s`) and
  `syncoid-k8s.timer` (`OnCalendar=*-*-* 04:00` local, `Persistent=true`),
  i.e. after the 01:30 UTC daily snapshot. `--no-sync-snap` replicates
  Sanoid's snapshots only, with no syncoid snapshots of its own.
- **Samba:** set up as in §4; `net use` from the Windows PC works.
- `hdd-mirror/k8s` grew from 197G to 218G referenced over the day.

## Update 2026-09-27: syncoid hourly

- `syncoid-k8s.timer` changed from nightly 04:00 to **hourly at :10**
  (`OnCalendar=*-*-* *:10:00`), 10 min after Sanoid's hourly snapshot, so
  each run sends only one hour of changes. The HGST copy is now at most
  about an hour behind instead of up to ~24 h: after losing `hdd-mirror`,
  at most ~1 h of changes is lost.
- `Environment=HOME=/root` added to `syncoid-k8s.service` to silence
  mbuffer's warning.
- Restoring after total loss of `hdd-mirror/k8s`: stop Nextcloud, recreate
  the pool if needed, `zfs send -R hgst/backup/k8s@<newest> | zfs receive -u
  hdd-mirror/k8s`, then `zfs set reservation=500G`, `zfs inherit readonly`,
  mount, `exportfs -ra`, start Nextcloud. Syncoid doesn't send properties,
  hence the reservation step. Snapshots on `hdd-mirror` itself don't help
  if the pool is lost; the HGST copy does. Losing the whole server still
  needs §3 (Azure).

## Update 2026-09-27: bulk data moved from Azure to `hgst/bulk`

- **Where it ran:** on the Proxmox host, writing straight to `/hgst/bulk`
  (no Samba or PC in the path). rclone installed with the official
  installer (`curl -fsSL https://rclone.org/install.sh | bash`); Debian's
  package lags upstream.
- **Config:** `rclone.conf` copied from {workstation} to
  `/root/.config/rclone/rclone.conf` (mode 600). The crypt remote
  `{crypt-remote}:` wraps `{azure-remote}:{azure-container}` (the whole container). The
  crypt `password`/`password2` are only obscured, so they work unchanged on
  another machine. Azure access is a **time-limited container SAS**; the old
  one had expired, so a new Read + List SAS was set with
  `rclone config update {azure-remote} sas_url '…'`.
- **Copy:** `rclone copy {crypt-remote}:tmp /hgst/bulk/tmp --transfers 8
  --checkers 16` run as a `systemd-run` unit so it survives SSH drops.
  Result: 2 files (2 × 200 GiB), **400 GiB in 4 h 28 min**, no errors.
- **Verification:** rclone crypt authenticates every 64 KiB block on
  download, so an error-free finish means the data decrypted intact.
  `rclone cryptcheck` (about 1 h of HGST reads) was skipped; the files were
  checked another way.
- **NIC downshift found:** `nic0` (onboard Realtek 2.5 GbE) had negotiated
  **100 Mb/s** although both it and the switch advertise 1000baseT/Full,
  which capped the download at ~95 Mbit/s. After renegotiation the link came
  up at 1000 Mb/s (~02:42; visible as a step from ~12 to ~35 MB/s in the
  node's Network Traffic graph). From then on the internet line was the
  limit, ~272 Mbit/s (~32.5 MiB/s). A downshift with 1000 on both ends
  usually means a marginal cable (gigabit needs all four pairs).
- **Throughput reference:** the HGST (~90 MiB/s sequential) only becomes the
  bottleneck above ~750 Mbit/s, so on this line future large pulls are
  network-bound.

## Update 2026-10-25: §3 design for the Azure sync

Script: `infra/proxmox-microk8s/scripts/04-setup-azure-sync.sh` (run the
rendered copy on the host). It installs `/usr/local/sbin/azure-sync-k8s`
and `azure-sync-k8s.timer`, daily at **03:00 UTC**.

- **Source: the newest Sanoid daily snapshot, not `@azure`.** syncoid 2.2.0
  replicates every snapshot and can't exclude one. A daily-recreated
  `@azure` would land on `hgst/backup/k8s`, and the next day's would clash
  with it there and break the hourly replication. The 01:30 UTC daily is
  just as crash-consistent and already holds the 01:00 UTC dump. The script
  `zfs hold`s it while rclone reads it and refuses a daily older than 26 h.
- **Scope:** all of `hdd-mirror/k8s` (every PVC directory, including the
  DB dumps and `stockstalker-postgres-backups`), minus Nextcloud's preview
  cache (`appdata_*/preview`, ~36G, regenerable).
- **Target: a new storage account**, `{offsite-azure-account}` in resource
  group `pve` (Standard LRS, Cool tier, no public access, TLS 1.2), with one
  private container `{offsite-azure-container}`. The old account was set up
  for the migration and still holds the old data; keeping the backup apart
  means its own SAS, its own crypt passwords and a clean bill. LRS because
  the copy is already off-site; Cool because it's written nightly and
  rarely read (its 30-day minimum matches the 30 days below).
- **rclone:** `{offsite-azure-remote}:` (azureblob, container SAS) and
  `{offsite-crypt-remote}:` (crypt over `{offsite-azure-remote}:{offsite-azure-container}`,
  new generated passwords). The old `{azure-remote}:`/`{crypt-remote}:` stay
  for the old container. Data goes to `{offsite-crypt-remote}:k8s/`.
  `rclone sync` with `--backup-dir {offsite-crypt-remote}:k8s-deleted/<date>`:
  files deleted or changed at home move there instead of vanishing, so a
  local mistake or ransomware doesn't wipe the off-site copy the same night.
  Folders older than **30 days** are purged by the script.
- **Credentials:** a container SAS tied to a **stored access policy**
  (read, add, create, write, delete, list; 1-year expiry). Revoking it means
  deleting the policy, without rotating account keys. The old ad-hoc SAS
  expired 2026-09-28. Renew before the policy expires: edit the policy's
  expiry (`az storage container policy update … --expiry`; the SAS URL
  keeps working) or create a new policy and run
  `rclone config update {offsite-azure-remote} sas_url '…'` on the host.
- **Restore** (from any machine with `rclone.conf`):
  `rclone copy {offsite-crypt-remote}:k8s/<pvc-dir>/ <target>/`; an older
  version of a file is in `{offsite-crypt-remote}:k8s-deleted/<date>/`. Without the crypt
  passwords the copy is unreadable, so `rclone.conf` must also be stored
  outside this house (password manager).
- **Not covered:** MariaDB's own volume and Nextcloud's app volume
  (`local-path` on a node, ADR-0010); the DB is covered through the dumps.

## Open items

- Confirm `daily_hour = 1` is in `/etc/sanoid/sanoid.conf`.
- Do a test restore into `hdd-mirror/restore-test`.
- Check that old snapshots get pruned on `hgst/backup/k8s` after a day or two.
  (The manual `systemctl start syncoid-k8s.service` at 23:17 worked: the
  incremental carried the 20:00/21:00 UTC hourlies over. mbuffer's
  "HOME environment variable not set" warning is harmless; optionally add
  `Environment=HOME=/root` to the service.)
- ~~Verify the `mariadb-dump` schedule is 01:00 UTC
  (`kubectl -n nextcloud get cronjob`).~~ Done 2026-10-25 (it was 02:30;
  moved to `0 1 * * *`, see ADR-0010).
- The 2026-10-25 daily snapshot was taken at 02:00 UTC instead of 01:30
  (the night DST ended). Check that 2026-10-26 is back at 01:30 UTC.
- After a day, confirm Load_Cycle_Count barely moves (was 301,169).
- Make sure `smartd` is running with notifications for all disks. (Running
  2026-10-25, but `-m root` mails go nowhere: pick a notification channel.
  The Azure sync has no failure notification either.)
- Store `rclone.conf` (crypt `password`/`password2`) in the password
  manager, so an Azure restore doesn't depend on this house.
- §3: create the storage account, container, policy and SAS; create the
  two rclone remotes; run `04-setup-azure-sync.sh`,
  a `DRY_RUN=1` check, then the first upload; confirm the 03:00 UTC run the
  next night. Until it runs,
  keep `{old-stack-dir}` and the migration dump (ADR-0010).
- Optional: tighten the 777 PVC directory on the host.
- Bulk: `chown -R {user}:{user} /hgst/bulk` so the Samba user owns the copied
  files (rclone wrote them as root).
- Bulk: delete `tmp` from Azure with a short-lived SAS that has Delete
  permission, once satisfied with the local copy.
- Remove `/root/.config/rclone/rclone.conf` from the host, unless it's kept
  for §3.
- Swap the `nic0` cable (Cat5e or better) and confirm
  `ethtool nic0 | grep Speed` shows 1000Mb/s after a reboot.
