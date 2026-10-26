# ADR-0010: Nextcloud Deployment on MicroK8s

**Status:** Accepted — migrated and verified 2026-09-26; on 35.0.2 since 2026-10-23
**Date:** 2026-09-22 (revised 2026-09-24 after checking against chart 9.3.0; updates 2026-09-25, 2026-09-26 ×2, 2026-10-23)

## Context

ADR-0008 deployed the 5-node MicroK8s cluster with StorageClasses `nfs-client`
(default, `hdd-mirror/k8s` via NFS, RWX-capable) and `local-path` (node SSD
boot disk). The Compose stack from ADR-0007 still runs on `{workstation}` under
Podman/WSL, reachable at `nextcloud.{tailnet}.ts.net`.

Inventory of the live stack (`{old-stack-dir}\config\compose.yaml`, `.env`, and
the webroot):

- `nextcloud:34-apache`, installed **34.0.1**; `mariadb:11.4`; DB and user
  `nextcloud`, `dbhost` `nextcloud-db`. **No Redis** (despite ADR-0007's title).
- `${DATA_ROOT}/data` (`{old-stack-dir}\data`) is bind-mounted onto
  `/var/www/html`, so code and user data share one mount (the ADR-0005 gap).
  User files are in `data/data`; `datadirectory` is `/var/www/html/data`.
- 209 GB, 237,761 files, 88,133 folders. Accounts `{user}` and
  `{nc-admin}`; no third-party apps; `instanceid` `{nc-instanceid}`.
  `data/data/nextcloud.log` is a 594 MB log, not user data.

Settled in this session: Helm for Nextcloud, the Tailscale Kubernetes
operator instead of Caddy, minimal observability for now, and extended
downtime is acceptable during the migration.

## Decision

### 1. Like-for-like move of the existing instance

Carry the old install over whole (webroot including `config.php`, user
data, database dump) instead of installing fresh and patching values back
in. Nextcloud then starts on the cluster as the same instance: same
`instanceid`/`secret`/`passwordsalt`, same `datadirectory`, same `dbhost`,
same version, same hostname. Sync clients don't need to re-authenticate.
Upgrade to a newer 34.x only after the move is verified.

Rejected: fresh Helm install, restore DB on top, then re-apply
`secret`/`instanceid`/`passwordsalt` with occ (this session's first
draft). The installer writes a new admin account and a new
`appdata_<id>` into the data directory, and any other hand-set
`config.php` entries would be lost silently.

### 2. Nextcloud via the official Helm chart; MariaDB via our own manifest

- Nextcloud: `nextcloud/nextcloud` chart (checked against 9.3.0), image
  pinned to `34.0.1-apache`.
- **MariaDB: not the chart's bundled subchart.** The chart pulls
  `bitnamilegacy/mariadb` and `bitnamilegacy/redis`, which Bitnami no longer
  updates (the chart itself sets `global.security.allowInsecureImages: true`
  to allow them). `mariadb.yaml` runs the official `mariadb:11.4` image
  instead, with the same server flags as today, as a one-replica
  StatefulSet behind a Service named `nextcloud-db`. The chart reaches it
  via `externalDatabase`, and the migrated `config.php`'s `dbhost` works
  unchanged.
- **No Redis**, matching the running stack (APCu + DB file locking). Add an
  official-image Redis/Valkey later if file-locking contention shows up.
- No secrets in any file that syncs to Nextcloud. DB and admin credentials
  live in Kubernetes Secrets (`nextcloud-db`, `nextcloud-admin`) created
  from the command line. The DB Secret reuses the current
  `MYSQL_PASSWORD`, so `config.php` needs no edit; rotate it later.

### 3. Storage: implements ADR-0005's split

- New StorageClass `local-path-retain` (same `rancher.io/local-path`
  provisioner, `reclaimPolicy: Retain`).
- `nextcloud-app` PVC (10 Gi, `local-path-retain`): code, `config/`,
  `themes/`. The chart mounts its subdirectories (`html/`, `config/`,
  `custom_apps/`, `themes/`, `tmp/`, `root/`).
- `nextcloud-data` PVC (300 Gi, `nfs-client`, RWX): user data via the
  chart's native `persistence.nextcloudData`, mounted at the unchanged
  `/var/www/html/data`. Keeping the path means no `oc_storages` rewrite in
  the DB. This replaces the draft's `NEXTCLOUD_DATA_DIR=/mnt/ncdata`
  approach, which would have required that rewrite.
- MariaDB volume (20 Gi, `local-path-retain`) via the StatefulSet.
- Both PVCs are created before the Helm release (`existingClaim`), so they
  can be pre-seeded and aren't owned by the release.

### 4. Tailscale access via the operator

The chart's Ingress uses `className: tailscale` with
`tls.hosts: [nextcloud.{tailnet}.ts.net]`. From the operator source
(`cmd/k8s-operator/ingress.go`): the device name is the first label of
`tls.hosts[0]` (`nextcloud`), and a rule whose host equals `tls.hosts[0]` is
accepted. Tailscale issues the certificate. The old Caddy device is removed
from the tailnet first, as a normal step in the runbook, so the same name
is free. `OVERWRITEHOST`, `OVERWRITEPROTOCOL=https` and
`TRUSTED_PROXIES=10.0.0.0/8` carry over from `compose.yaml` (the pod CIDR is
10.1.0.0/16).

### 5. Background jobs and DB backup

- The chart's cron sidecar, switched on with `occ background:cron`. The old
  stack had no cron container.
- Nightly `mariadb-dump` CronJob writing to `db-dumps/` at the root of the
  `nextcloud-data` PVC (next to `data/`), so the dumps land on
  `hdd-mirror/k8s` for the Azure pipeline.

### 6. Observability

Minimal for now: `metrics-server` and `kubectl top`. The Prometheus/Loki/
Grafana stack from ADR-0007 is deferred to a follow-up ADR, once real load
shows how much of the 17 GB cluster RAM is free.

## Migration (summary)

Full steps in `infra/proxmox-microk8s/nextcloud/migration-runbook.md`.

- **Part A** (old Nextcloud keeps running): operator, namespace, Secrets,
  MariaDB, PVCs, SSH/rsync access. Optionally pre-copy the data.
- **Part B** (downtime):
  1. Stop the Podman stack.
  2. Dump the DB.
  3. `rsync` `data/data` over SSH to the Proxmox host, into the PVC's
     directory under `/hdd-mirror/k8s`, setting ownership to uid 33 and mode
     0770. The NFS export only allows the node IPs, so `{workstation}` can't mount it.
  4. Stream the webroot (without `data/`) into the app PVC through a
     temporary loader pod.
  5. Restore the dump.
  6. Remove the old Tailscale device.
  7. `helm install`.
  8. Verify.
- **Rollback** until decommissioning: `helm uninstall`, new Tailscale auth
  key, `podman compose up -d`. `{old-stack-dir}` is only read throughout.

## Alternatives considered

- **Raw manifests for Nextcloud too.** More control, but the chart covers
  the Deployment, probes, cron sidecar and config files well. MariaDB is
  the one piece where the chart's option (Bitnami legacy) was worse than a
  short manifest.
- **Bundled Bitnami MariaDB/Redis subcharts.** The first draft of this ADR
  used them. Rejected because the images are frozen (see §2).
- **Keep `caddy-tailscale` in-cluster.** Workable, but the operator gives
  the same outcome (tailnet-only access, Tailscale-issued TLS) as a
  cluster-level component with nothing extra in the Nextcloud pod.
- **Temporary hostname, then cut over.** Dropped: downtime is accepted, so
  it only adds steps.
- **Full observability stack now.** Deferred, not rejected (§6).

## Consequences

- ADR-0005 finally holds: code and config on SSD (Retain), user data on the
  HDD mirror, DB on SSD (Retain).
- The app PVC and MariaDB are pinned to the node where they were first
  bound (local-path). This was already accepted in ADR-0008.
- New dependency: the Tailscale operator and its OAuth client. Caddy goes
  away.
- MariaDB is now ours to update: bump the `mariadb.yaml` image tag within 11.4.
- Nextcloud is down from B1 through B9. Accepted.

## Update 2026-09-25: operator installed, kubectl access via the tailnet

The operator step from Part A is done, and the operator also serves as the
way to reach the Kubernetes API from workstations.

- **Operator:** Helm release `tailscale-operator` (chart
  `tailscale/tailscale-operator`) in namespace `tailscale`, installed from cp1
  with `apiServerProxyConfig.mode=true`. Its tailnet device is
  `tailscale-operator.{tailnet}.ts.net`.
- **OAuth client** (admin console → Settings → Trust credentials → OAuth):
  scopes Devices Core (write), Auth Keys (write), Services (write), tag
  `tag:k8s-operator`. The ID and secret are kept in a password manager and
  were passed to Helm via `read`. They are not stored in any file.
- **Tailnet policy file:** `tagOwners` for `tag:k8s-operator` (owned by
  admins) and `tag:k8s` (owned by `tag:k8s-operator`). A grant from
  `autogroup:admin` to `tag:k8s-operator` with app capability
  `tailscale.com/cap/kubernetes` impersonates group `system:masters`.
  Tailnet admins are cluster-admin through the proxy.
- **Workstation (WSL on `{workstation}`):** WSL is its own tailnet device,
  `{workstation}-wsl`, separate from Windows' Tailscale. kubectl comes from the
  `pkgs.k8s.io` v1.35 apt repo, pinned to the cluster's minor version.
  `tailscale configure kubeconfig tailscale-operator` writes the context. No
  cluster-admin certificate is kept on the workstation. Helm isn't needed
  there until charts are installed from WSL.
- **Node-side access** stays as the break-glass path: `ssh ubuntu@192.168.1.20`,
  then `sudo microk8s kubectl` / `sudo microk8s helm3`. The `ubuntu` user on
  cp1 also has `~/.kube/config` from `microk8s config` (admin certificate), so
  plain `helm` works there. The operator was installed that way.
- The first `kubectl` calls through the proxy hit a TLS handshake timeout.
  Retrying later worked.

Alternatives considered for workstation access:

- **Copy `microk8s config` (admin certificate) to WSL.** Works on the LAN only
  and puts a static, non-revocable admin credential on the workstation.
- **Subnet router on the Proxmox host** advertising `192.168.1.0/24`. Quick,
  and the existing kubeconfig would work off-LAN. Rejected because it exposes
  the whole LAN to the tailnet and still authenticates with the admin
  certificate.
- **Tailscale on the control-plane VMs.** Needs Tailscale IP SANs on every
  API server certificate and three more devices to maintain.

## Update 2026-09-26: migrated and verified

Part B was run on 2026-09-25/26. Nextcloud now runs on the cluster as the
same instance: sync clients on the PC and phone reconnected without logging
in again. The Podman stack on `{workstation}` is stopped (`podman compose down`,
named volumes kept) and `{old-stack-dir}` is untouched, so rollback remains
possible until decommissioning.

Results:

- **Data:** one `rsync` pass with the stack stopped. 224.5 GB, 237,806
  files, about 5 h 50 min at ~10 MB/s; reading from the Windows drive
  through WSL was the bottleneck. 210 GB apparent size on the host, stored
  as 191 GB because of ZFS compression (1.11x).
- **DB:** 262,294 file-index rows and both accounts restored. `installedat`
  kept the original July 2026 value.
- **Start-up:** the container logged no "Initializing", "New instance" or
  "Upgrading". It found 34.0.1 on the volume, matched it to the image and
  went straight to Apache. `occ status` showed `installed: true`, 34.0.1 and
  `needsDbUpgrade: false`.
- **Tailscale:** the old `nextcloud` device was removed first, and the
  Ingress claimed `nextcloud.{tailnet}.ts.net` directly.
- **Cron:** switched to cron with `occ background:cron`. The sidecar is
  running jobs every 5 minutes.
- **Backup:** the `mariadb-dump` CronJob works. The test dump was 349 MB,
  74 MB on disk, complete ("Dump completed"), in `db-dumps/` next to `data/`.
- **Security:** `/data/.ncdata` returns 404 through the ingress.

Changes from the plan, all reflected in the runbook:

- Podman runs from the Windows side, so B1–B2 are PowerShell. The dump is
  written inside the container (`--result-file`) and copied out with
  `podman cp`, because a PowerShell 5.1 `>` redirect would produce UTF-16.
- The Proxmox host is reached as `root@pve` for SSH.
- Because `kubectl` works in WSL through the operator (see the 2026-09-25
  update), B4/B5 ran locally instead of over SSH to cp1. B4 and B5 were done
  while rsync was still running.
- The webroot arrived as mode 777 (the Windows drive reports everything
  that way), so the app volume was tightened to 750/640 after B4.
- `setupchecks` showed a failed code-integrity result for the `text` app.
  It was a stale stored result that came over with the database:
  `integrity:check-core` and `integrity:check-app text` were clean. It was
  cleared with `occ config:app:delete core oc.integritycheck.checker`.
- The self-connect checks in `setupchecks` (WebDAV, `.well-known`, fonts
  and so on) can't run, because the pod can't reach its own tailnet
  hostname. Verified manually instead through working sync and the
  `.ncdata` 404.

## Update 2026-09-26: upgraded to 34.0.4

`image.tag` in `values.yaml` changed to `34.0.4-apache`, followed by a
`helm upgrade`. The entrypoint upgraded 34.0.1.2 → 34.0.4.1: DB schema, and
the apps dav, files_lock, files_downloadlimit and files_pdfviewer. Code
integrity was OK and maintenance mode turned off again. `occ status` shows
34.0.4 with `needsDbUpgrade: false`. A DB dump was taken beforehand with the
`mariadb-dump` CronJob.

The log warns that `config/s3.config.php` differs from the image's copy. This
is harmless: `config/` is on the persistent volume and isn't overwritten,
and the file does nothing without S3 environment variables.

Nextcloud 35.0.0 was released 2026-09-16. Wait for a few point releases
and chart support, then upgrade to 35 as a separate step.

## Update 2026-10-23: 34.0.5 (PHP2Shell fix), then 35.0.2

**Why.** PHP disclosed two critical remote-code-execution flaws
(CVE-2026-109618, CVE-2026-109619, "PHP2Shell"). Details leaked before the
patch and exploitation was reported. They are fixed in PHP 8.5.12, 8.4.27,
8.3.36 and 8.2.35, released 2026-10-21. In the official `nextcloud` image the
PHP fix arrives through a rebuild of the base image, not a Nextcloud
release, and only the tags Docker Hub still lists get rebuilt.
`34.0.4-apache` was no longer one of them, so the running pod stayed on
vulnerable PHP. Tailnet-only access reduced the exposure but didn't remove it.

**How** (both steps from WSL on `{workstation}`, in
`infra/proxmox-microk8s/nextcloud/`; Helm now runs there):

1. `image.tag` → `34.0.5-apache`. Dump with `kubectl -n nextcloud create job
   --from=cronjob/mariadb-dump pre-34-0-5-dump`, then
   `helm upgrade nextcloud nextcloud/nextcloud -n nextcloud -f values.yaml
   --version 9.3.0` (revision 3). Entrypoint: 34.0.4.1 → 34.0.5.1.
   `php -v` 8.5.12 (built 2026-10-21).
2. Right after, `image.tag` → `35.0.2-apache`, new dump `pre-35-dump`, same
   `helm upgrade`. Entrypoint: 34.0.5.1 → 35.0.2.2, no errors, no apps
   disabled. `occ status`: 35.0.2, `maintenance: false`,
   `needsDbUpgrade: false`. `php -v` 8.5.12. `occ db:add-missing-indices`
   added `taskp_tasks_scheduled` and `oc_notifications_object_ts`.

The chart stays at **9.3.0**, still the newest official release and built
for 34. It only runs the image, and 35 worked with it. `--version 9.3.0` is
passed so that only the image changes; `values.yaml` doesn't pin it.

Nextcloud 35's new requirements don't touch this setup: PHP comes with the
image (8.5), MariaDB is 11.4 (35 needs at least 10.11), and there are no
third-party apps.

**`setupchecks` after 35:** code integrity OK, PHP 8.5.12, cron OK, no
missing indices, columns or primary keys. New warnings: "Database
configuration: 2 checks failing" (details not looked at yet), mimetype
migrations available, `.js.map` files not served, and 2 log warnings from
the upgrade window. The disabled apps (admin_audit, encryption,
files_external, suspicious_login, twofactor_nextcloud_notification,
user_ldap) are bundled apps that ship disabled. The self-connect checks
still can't run (known, see the 2026-09-26 update).

**Lessons:**

- A PHP-only fix arrives as a re-push of an existing tag. With the default
  `IfNotPresent` pull policy a node keeps its cached image. For the next
  PHP-only fix: move to a newer tag, pin the digest, or remove the cached
  image on the node. Check `php -v` in the pod afterwards.
- Always pass `--version` to `helm upgrade` until the chart version is
  pinned in the repo.
- There's no in-place downgrade from 35. The DB is covered by `pre-35-dump`,
  but the app volume (code and `config/`, on `local-path-retain` on a node's
  boot zvol) is **not** snapshotted: ADR-0011 excludes VM disks. A copy of
  `config/` belongs in the pre-upgrade routine before the next major upgrade.

## Update 2026-10-23: follow-ups after 35

- **Mimetype repair:** `occ maintenance:repair --include-expensive` ran
  cleanly (4 birthday calendars fixed, nothing else to do).
- **Log warnings:** one is cron skipping the web updater's backup clean-up
  (`updater-<instanceid>/backups` doesn't exist because upgrades go through
  the image entrypoint, not the web updater). Harmless and expected.
- **MariaDB tuning** (the two failing "Database configuration" checks, shown
  on Administration → System → Database): buffer pool was the 192M default
  (hit rate 96.97%, measured right after the upgrades), redo log 96M.
  `mariadb.yaml` now passes `--innodb-buffer-pool-size=512M` and
  `--innodb-log-file-size=256M`, with memory request 768Mi / limit 1536Mi
  (was 512Mi / 1Gi) so the pool fits with headroom. Applied with
  `kubectl apply`; the pod restarted in about a minute and Nextcloud
  reconnected. Verified 512 / 256 MB with `SELECT @@innodb_…`. Not 60% of
  RAM as the check suggests: the DB shares its node.
- **Placement:** `nextcloud-db-0` runs on **wk1** (4 GB worker), not cp3 as
  ADR-0011's context guessed. wk1 had 512Mi requested and ~1.3 Gi in use
  before the change.

## Open items

- Decommission the Podman stack on `{workstation}` after a few stable days. Keep
  `{old-stack-dir}` and the migration dump until the Azure backup covers
  `hdd-mirror/k8s`. (Unblocked 2026-10-26: the Azure backup covers it,
  ADR-0011 §3.)
- ~~ADR-0008: point the Azure/rclone backup at `hdd-mirror/k8s` snapshots.
  Until then, the new data and the nightly DB dumps have no off-site copy.~~
  Done 2026-10-26.
- Recheck the InnoDB buffer pool hit rate after a few days of normal use
  (it restarts cold); raise the pool only if it stays below ~99%.
- Move to an official chart release for 35 when one appears.
- Back up `config/` from the app volume before major upgrades (not covered
  by snapshots).
- Pin the chart version (e.g. a comment in `values.yaml` and the runbook's
  upgrade note), and add the pull-policy lesson to the runbook.
- ~~`mariadb-dump-cronjob.yaml` runs at `30 2 * * *` (02:30 UTC), after
  Sanoid's 01:30 UTC daily snapshot, so each daily snapshot holds the
  previous night's dump. Move the CronJob to `0 1 * * *` (ADR-0011 assumes
  01:00 UTC).~~ Done 2026-10-25: `0 1 * * *` applied; the cluster runs in
  UTC (last run fired at 02:30Z), so no DST drift.
- ~~Follow-up ADR for observability~~ Done: ADR-0013 (2026-10-24).
- Optional Redis/Valkey.
- `migration-runbook.md` Part A: make any operator re-install keep
  `--set-string apiServerProxyConfig.mode="true"`. Without it, kubectl
  access through the tailnet stops.
- Optional: `infra/proxmox-microk8s/scripts/workstation-setup.sh` (kubectl
  1.35, Tailscale, optionally Helm) so WSL can be rebuilt.
