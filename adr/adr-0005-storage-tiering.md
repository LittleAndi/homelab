# ADR-0005: Storage Tiering — SSD for System/Database, HDD Pool for Bulk Data

**Status:** Accepted — implemented via ADR-0008
**Date:** 2026-08-18

## Context

The boot drive will be an M.2 SSD. Nextcloud's perceived performance is
largely database-bound rather than file-storage-bound, so where the database
lives matters more than where the bulk files live.

## Decision

- OS, container runtime/images, MariaDB data, Redis/cache data, and
  app code/config live on the **SSD**.
- Nextcloud's `data` directory (the actual user files) lives on the
  **mergerfs HDD pool** (ADR-0004).

## Alternatives considered

- **Single storage location for everything** — rejected; would tie database
  latency to HDD pool performance and prevent scaling file storage capacity
  independently of system storage.

## Consequences / open action item

The compose stack currently in use (ADR-0007) maps the entire
`/var/www/html` (app code **and** the `data/` subfolder together) to a
single `${DATA_ROOT}` path:

```yaml
nextcloud-app:
  volumes:
    - ${DATA_ROOT}/data:/var/www/html:Z
```

This does **not** yet implement the split described above. To realize this
ADR, the app/html path and the user-data path need to be separated, e.g.:

```yaml
nextcloud-app:
  volumes:
    - ${DATA_ROOT}/html:/var/www/html:Z                      # SSD
    - ${STORAGE_ROOT}/nextcloud-data:/var/www/html/data:Z     # mergerfs pool
```

Tracked as a pending follow-up — not yet applied to the live compose file.

## Update 2026-09-21

The tiering principle still holds (SSD for system/DB, HDD for bulk data). Under ADR-0008 the SSD tier becomes the Proxmox `local-zfs` pool (VM disks) and the HDD tier becomes the `hddmirror` ZFS pool, served via NFS as the `nfs-client` StorageClass. The compose bind-mount fix below only applies if the Podman stack is kept.

## Update 2026-09-21: implemented

Implemented as part of ADR-0008 (deployed today). Correction to the note
above: the pool is named `hdd-mirror`, not `hddmirror`.

- **SSD tier:** Proxmox `local-zfs` (`rpool/data`, 1 TB NVMe) holds all VM
  OS disks. In the cluster, StorageClass `local-path` puts volumes on a
  node's SSD boot disk, for MariaDB and the Nextcloud app/config.
- **HDD tier:** dataset `hdd-mirror/k8s` on the WD mirror, served over NFS as
  the default StorageClass `nfs-client`, for Nextcloud user files and DB
  dumps.
- The Compose bind-mount fix above is obsolete; the Podman stack is not used.
