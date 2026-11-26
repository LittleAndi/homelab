# ADR-0013: Monitoring — kube-prometheus-stack in the Cluster, Exporters on the Host

**Status:** Accepted 2026-10-24 — deployed 2026-10-26 (chart 92.13.1); Entra ID sign-in added 2026-10-31; custom dashboard not built yet
**Date:** 2026-10-24

## Context

The Proxmox UI shows host, VM and storage graphs, but opening it to check
things is cumbersome. It also misses most of what matters here:

- the cluster's workloads (nodes, pods, PVCs);
- dataset-level ZFS usage, such as the `hdd-mirror/k8s` reservation and the
  `hgst/bulk` quota;
- snapshot freshness and syncoid lag (ADR-0011);
- disk health, including the drives behind the HBA (ADR-0009).

The goal is one dashboard that covers:

- the Proxmox host and its VMs (cluster nodes and `haos`);
- ZFS: `rpool`, `hdd-mirror` and `hgst`, with their datasets and snapshots;
- the MicroK8s cluster;
- SMART data for all six drives.

ADR-0010 deferred observability until real load showed how much of the
17 GB cluster RAM was free. The cluster runs only Nextcloud and is mostly
idle.

Constraints set in this session:

- everything stays on the server;
- no new VMs;
- no alerts for now;
- 30 days of retention.

Access stays tailnet-only (ADR-0007, ADR-0010).

## Decision

### 1. kube-prometheus-stack in the cluster

- **Chart and release:** Helm chart `prometheus-community/kube-prometheus-stack`,
  namespace `monitoring`, release `kube-prometheus-stack`. The chart version
  is picked at install, recorded in the runbook, and always passed with
  `--version` (lesson from ADR-0010).
- **Prometheus:**
  - retention `30d`, plus `retentionSize: 18GB` as a hard cap;
  - TSDB on a 20 Gi `local-path-retain` PVC, not NFS, because Prometheus
    doesn't support NFS for its TSDB;
  - preferred on **wk2**, since wk1 carries MariaDB;
  - requests 768Mi, limit 2Gi.
- **Grafana:**
  - exposed through the Tailscale operator: Ingress `className: tailscale`,
    `grafana.{tailnet}.ts.net`, with Tailscale-issued TLS (same pattern as
    Nextcloud);
  - admin credentials come from a Secret `grafana-admin` created on the
    command line, not from any file;
  - a 1 Gi `local-path-retain` PVC, so dashboards made in the UI survive
    pod restarts.
- **Bundled and kept:**
  - node-exporter as a DaemonSet on the 5 VMs;
  - kube-state-metrics;
  - kubelet/cAdvisor scraping;
  - the chart's Kubernetes dashboards and the recording rules they depend on.
- **Switched off:**
  - Alertmanager, since there are no alerts yet;
  - the scrape targets and rule groups for etcd, kube-scheduler,
    kube-controller-manager and kube-proxy. MicroK8s runs those inside
    `kubelite` and uses dqlite, so the default targets would always show
    as down.
- **Dashboards:**
  - Grafana.com dashboards: *Node Exporter Full* (1860) for the host and
    *Proxmox via Prometheus* (10347).
  - A custom "Server overview" dashboard (pools, datasets, snapshot age,
    disk health, cluster summary) is built once metrics flow. It is then
    exported to `infra/` as a ConfigMap, picked up by the chart's dashboard
    sidecar.

### 2. Exporters on the Proxmox host

These are installed by `infra/proxmox-microk8s/monitoring/host/20-setup-host-exporters.sh`.

| Exporter | Port | Installed from | Covers |
|---|---|---|---|
| `prometheus-node-exporter` | 9100 | Debian (no recommends) | Host CPU, RAM, network and disk I/O; ZFS ARC; systemd unit state for sanoid, syncoid-\*, zfs-metrics, smbd, nfs-server, zfs-zed, smartmontools and the PVE daemons |
| `zfs-metrics.py` (textfile collector, every minute) | via 9100 | Own script | Pool size, allocated, free, fragmentation and health; dataset used, available, referenced, snapshot usage, quota and reservation; newest snapshot time and snapshot count per dataset |
| `prometheus-smartctl-exporter` | 9633 | Debian trixie-backports | SMART on all disks, including through the HBA |
| `prometheus-pve-exporter` | 9221 | PyPI, venv in `/opt/pve-exporter` | Node and guest status and usage, Proxmox storages |

- **PVE access:** pve-exporter authenticates as `prometheus@pve` with role
  `PVEAuditor` (read-only) on `/`, using API token `exporter`.
  - The token lives only in `/etc/prometheus/pve.yml` on the host
    (`root:pve-exporter`, mode 640), never in the synced folder.
- **Scraping:** Prometheus reaches the exporters at `192.168.1.10` through
  `additionalScrapeConfigs`, labelled `instance="pve"`.
- **Firewall:** an nftables table `inet exporters` allows the exporter ports
  only from 127.0.0.1 and the node IPs `.20–.24`, the same rule as the NFS
  export.
  - It is loaded by its own systemd unit, and never through
    `nftables.conf`, whose `flush ruleset` would wipe other rules.
  - Calico SNATs pod traffic to the host to the node IP, so the node IPs are
    the sources the host sees.
- **Snapshot freshness:** snapshot age is computed in PromQL as
  `time() - zfs_dataset_newest_snapshot_timestamp_seconds`.
  - A received snapshot keeps its source creation time, so on
    `hgst/backup/*` the same expression shows how far syncoid is behind.

## Alternatives considered

- **A monitoring VM or LXC outside the cluster**, running
  Prometheus/VictoriaMetrics and Grafana.
  - It would keep working while the cluster is down, and survive cluster
    rebuilds.
  - Rejected for now: no new guests, and the cluster has unused capacity.
- **Proxmox External Metric Server → InfluxDB + Grafana.** No agents on the
  host, but no Kubernetes, dataset-level ZFS, snapshot or SMART data.
- **Netdata / Beszel.** Quick to set up. Netdata is heavier per node; Beszel
  lacks Kubernetes and ZFS dataset detail.
- **Homepage / Glance**, a start page that queries the APIs live. It keeps
  no history, but it can be added on top later.
- **VictoriaMetrics in the cluster** instead of Prometheus. Lighter, but
  kube-prometheus-stack's dashboards and rules come ready-made with
  Prometheus.
- **`zfs_exporter`.** Not packaged in Debian. A short textfile script covers
  what's needed, including snapshot age.
- **The full ADR-0007 stack, including Loki/Alloy for logs.** Deferred. Logs
  stay in `kubectl logs` and the journal for now.

## Consequences

- **Blind spot:** when the cluster is down, so is the dashboard. The
  Proxmox UI remains the fallback. Accepted.
- **Cluster resources:** roughly 1.2–1.6 GB of cluster RAM, mostly
  Prometheus, and about 20 Gi on wk2's boot disk.
  - Prometheus and Grafana stay on the node where their PVCs are first bound
    (local-path, as accepted in ADR-0008).
- **New on the host:**
  - three exporters and a textfile timer;
  - a read-only PVE user and token;
  - the trixie-backports repo, used only for `prometheus-smartctl-exporter`
    (backports never install without `-t`);
  - an nftables table.
- **Updates:** pve-exporter comes from pip, so `apt upgrade` doesn't update
  it. Update it with pip in the venv.
- **Metrics aren't backed up.** VM disks aren't snapshotted (ADR-0011), so
  losing them only loses history.
- **Other ADRs:**
  - ADR-0010's "follow-up ADR for observability" is this ADR. Its optional
    Redis/Valkey item stays open there.
  - ADR-0009's HBA temperature check isn't covered: smartctl reports disk
    temperatures, not the SAS3008's. A disk dropping off the HBA does show
    up as a missing `smartctl` device.
- **Alerts** can be added later, through Alertmanager or Grafana alerting,
  without changing the collection side.

## Update 2026-10-26: host exporters deployed

- Script 20 run on the host. Installed: `prometheus-node-exporter` (Debian),
  `prometheus-smartctl-exporter` 0.14.0 (trixie-backports),
  `prometheus-pve-exporter` 3.10.1 (PyPI venv). Local checks: ZFS ARC,
  3 pools, systemd unit states, SMART for **all 6 drives** (including the
  HBA), `pve_up`.
- The backports package names its unit **`smartctl_exporter.service`**,
  not `prometheus-smartctl-exporter.service`; the script and the
  node-exporter unit list were fixed.
- `azure-sync-k8s` (ADR-0011 §3) added to node-exporter's systemd unit
  list.
- Firewall verified: all three ports answer `200` from cp1; from a
  non-node LAN machine (WSL) and over Tailscale they time out.
- Backports stays at priority 100: none of the host's upgradable packages
  come from it.

## Update 2026-10-26: chart installed

- `kube-prometheus-stack` **92.13.1** (app v0.94.1), the newest at
  install. Before installing, every key in `values.yaml` was checked
  against the chart's own values, and `helm template` was reviewed (no
  Alertmanager, no chart-generated Grafana admin Secret).
- **Fixed before install:** the Prometheus affinity said `wk2`, but the
  node is `microk8s-wk2` (`kubernetes.io/hostname`). Prometheus now runs
  on wk2 as intended. Grafana landed on cp2 (`local-path` pins it there).
- **All 32 targets up**, including `pve`, `pve-node` and `pve-smartctl`,
  which confirms the SNAT-to-node-IP path through the host firewall.
  Data checked: pool capacity for all 3 pools, current temperature for all
  6 drives, snapshot age, guest status, systemd units (incl.
  `azure-sync-k8s`).
- Grafana answers at `https://grafana.{tailnet}.ts.net` (first request
  ~10 s while Tailscale issued the certificate). The Grafana.com dashboards
  downloaded and provisioned.
- The Prometheus image has no shell tools; query it through the API server
  proxy:
  `kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/targets'`.

## Update 2026-10-31: Entra ID sign-in

Grafana sign-in now goes through Entra ID, using Grafana's built-in
`auth.azuread` provider (helm revision 3, same chart version). Access stays
tailnet-only: the redirects run in the browser, so Entra never connects to
Grafana.

- **App registration:** *Grafana homelab* in the personal tenant that holds
  the Azure subscriptions; single tenant, with `allowed_organizations` also
  set to that tenant. IDs are in `site.env`.
- **Who gets in:** assignment is required on the enterprise application. One
  user so far, the owner, as `Admin`. Grafana also refuses a login with no
  role (`role_attribute_strict`).
- **Roles:** app roles `Admin`, `Editor` and `Viewer`, synced at each login, so
  Entra is the source of truth rather than the Grafana UI. No `GrafanaAdmin`
  role: the local admin covers server-level administration.
- **Break-glass:** the local admin and login form stay, so Grafana is still
  reachable if Entra or the secret fails.
- **Client secret:** only in the Secret `grafana-entra`, piped straight from
  `az`. It expires **2028-10-31**. The Grafana pod won't start without this
  Secret, so a rebuild has to create it first (runbook).
- **Alternatives:** Tailscale identity through `auth.proxy` would avoid a
  second login and a secret, but it was not what was asked for here and adds
  a proxy in front of Grafana. Generic OAuth has no advantage over the
  dedicated provider.

**Dependency:** new logins now depend on Microsoft being reachable; the local
admin doesn't.

## Update 2026-11-25: telemetry for dqlite lock errors

**Problem.** The Flux Discord alert fires 1–2 times a day with
`database is locked` on a status write, close to `:00`. Investigation: k8s-dqlite
logs about 80 such errors a day per control-plane node, on all three nodes;
minute `:00` has about 5× the average (22 vs ~4 over 3 days on cp1). Most are
retried by kine; Flux's alert is the few that surface. Existing metrics
(apiserver/etcd latency, disk time, PSI) show nothing at `:00` at 1-minute
resolution, so a stall of a second or two is averaged away.

**Hypothesis (not proven).** Sanoid's snapshot and prune on the host at `:00`
forces txg syncs on `rpool`, where the VM disks live, and briefly stalls
dqlite's fsyncs. The additions below test it.

**Added** (no alerts, per this ADR):
- Flux `PodMonitor` (`clusters/homelab/infra/flux-monitoring.yaml`, deployed by
  Flux) for `gotk_*` metrics, e.g. `gotk_reconcile_condition`.
- `zfs_pool_txg_{sync,wait}_seconds_max`, `zfs_pool_txg_dirty_bytes_max` and
  `zfs_pool_txg_closed_count` in `zfs-metrics.py`: the max over the txgs closed
  in the last 70 s, so short stalls survive the scrape interval.
- `dqlite_database_locked_total` on the control-plane nodes: a systemd timer
  (`monitoring/nodes/`, Ansible) counts the dqlite journal lines into the
  node_exporter textfile directory, which the DaemonSet now mounts
  (`prometheus-node-exporter` in `values.yaml`). Resolution is 1 minute.

**Reading it.** Compare `increase(dqlite_database_locked_total[5m])` by node
with `zfs_pool_txg_sync_seconds_max{pool="rpool"}` and the Sanoid run times.
If locks follow txg stalls, move or thin the Sanoid/syncoid timers (hourly
snapshots on `rpool` look unneeded: `template_os` is daily-only). If not, look
at dqlite itself (leader churn, snapshots).

**Not changed:** the Flux Discord `Alert` still fires on every error; nothing
is excluded until the cause is known.

## Update 2026-11-26: first results from the lock telemetry

The 2026-11-25 telemetry is live: `gotk_*`, `dqlite_database_locked_total` and
`zfs_pool_txg_*` are all in Prometheus. Data covers about 35 h from
2026-11-25 08:22 UTC.

**One alert traced** (`infra` status write, 12:58:54 UTC):
- cp1 and cp2 logged lock errors within the same second or so, on node,
  API server and Flux leader leases besides the `infra` status. cp3 logged no
  match. Flux recovered by itself; `kustomize-controller` didn't restart.
- `rpool` had a 1.22 s txg sync in a txg born between about 12:58:37 and
  12:59:14, a span that includes the error. Earlier samples from 12:50 showed
  at most 0.29 s, but they had gaps (below). Peak dirty data in the same span
  was about 37 MB, which is ordinary.
- NVMe averages over 2 minutes were slightly high: flush 4.7 ms (35 h median
  3.6, p95 4.2), write 3.5 ms (median 2.6, p95 3.0).
- Not Sanoid: it started at 13:00:06 UTC, after the error.

**All 35 h:** 321 lock lines in the k8s-dqlite journals (cp1 169, cp2 53,
cp3 99), matching the counter.
- Minutes near an `rpool` txg sync of 0.25 s or more (highest value within a
  minute either side) were 24 % of all minutes and had about 51 % of the lock
  errors. **Not reliable:** the metric missed many txgs (below), so some of
  the other errors may have had a slow sync that wasn't seen.
- Only 6 minutes were near a sync of 1 s or more, and 17 % of them had a
  lock error: too few to conclude anything.
- By journal timestamp, `:00` isn't among the 10 busiest minutes of the hour
  (busiest: `:50` with 16 and `:58` with 14; mean 5.3). The earlier 3-day cp1
  finding of about 5× at `:00` didn't repeat in this window.

**Decision:** leave the Sanoid/syncoid timers as they are. The data doesn't
show them as the main cause. Slow `rpool` syncs look like one contributor,
not a proven or complete explanation. The Flux alert stays unchanged.

**Bug in the txg metrics, fixed 2026-11-26.** The kstat's `birth` is
`CLOCK_MONOTONIC_RAW`, but `zfs-metrics.py` compared it with
`CLOCK_MONOTONIC`. The two were 33.9 s apart after 13.9 days of uptime
(about 2.4 s/day), so the "last 70 s" window really covered about the last
36–40 s of runs 60–70 s apart. Many txgs were never counted, and after about
four weeks of uptime the metric would have shown nothing. It now uses the raw
clock and an 80 s window. On the host, the window went from 6–7 `rpool` txgs
to 16, as expected at one per 5 s. `zfs_pool_txg_*` data from before the fix
(2026-11-26 about 18:20 UTC) has these gaps.

**Other gaps.** Even fixed, the metric is a maximum over a window, so it can't
place a slow sync at the same second as an error. The kernel keeps only the
last 100 txgs per pool (about 8 minutes here), so per-txg times for older
events are gone. NVMe rates average over 2 minutes.

**Added: slow-txg log** (temporary). `host/slow-txg-log.py` runs as
`slow-txg-log.service` on the host (installed by
`host/21-setup-slow-txg-log.sh`, running since 2026-11-26 18:21 UTC). It
writes one journal line per `rpool` txg whose sync took 0.25 s or more, with
sync start and end in UTC, and a `gap` line if txgs were missed. Remove it
once the cause is known.

**Reading it.** After 2–3 days, line up the `slow` lines with the lock lines
in the k8s-dqlite journals. Compare the share of errors that fall during or
just after a slow sync with the share of all time those spans cover. Overlap
well above that share points to a link, though not to which causes which (a
slow disk could delay both). No more overlap than that points at dqlite.

## Open items

- ~~Apply the 2026-11-25 telemetry~~ Done; confirmed 2026-11-26.
- Find the cause of the lock errors:
  - after 2–3 days (from about 2026-11-29), compare the `slow-txg-log` lines
    with the dqlite journal timestamps, and add NVMe latency and per-VM write
    load; then remove the logger;
  - check dqlite itself (leader changes, snapshots), including errors that
    come without a slow sync.
- Rotate the Entra client secret by 2028-10-31 (runbook §4). Nothing alerts
  on its expiry.
- ~~Run script 20 on the host. Verify the three ports from cp1, and that
  another LAN machine is refused.~~ Done 2026-10-26.
- ~~Pick the chart version, record it in the runbook, and run `helm install`.~~
  Done 2026-10-26 (92.13.1).
- ~~Check that all targets are up in Prometheus (`/targets`), especially the
  `pve-*` jobs.~~ Done 2026-10-26: 32/32 up.
- Build the "Server overview" dashboard and export it to
  `infra/proxmox-microk8s/monitoring/dashboards/` as a ConfigMap.
- ~~Pin the Grafana.com dashboard revisions in `values.yaml` (currently
  `latest`).~~ Done 2026-10-26: 1860 rev 45, 10347 rev 5 (the revisions
  already installed; helm revision 2).
