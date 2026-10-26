# ADR-0013: Monitoring — kube-prometheus-stack in the Cluster, Exporters on the Host

**Status:** Accepted 2026-10-24 — deployed 2026-10-26 (chart 92.13.1); custom dashboard not built yet
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

## Open items

- ~~Run script 20 on the host. Verify the three ports from cp1, and that
  another LAN machine is refused.~~ Done 2026-10-26.
- ~~Pick the chart version, record it in the runbook, and run `helm install`.~~
  Done 2026-10-26 (92.13.1).
- ~~Check that all targets are up in Prometheus (`/targets`), especially the
  `pve-*` jobs.~~ Done 2026-10-26: 32/32 up.
- Build the "Server overview" dashboard and export it to
  `infra/proxmox-microk8s/monitoring/dashboards/` as a ConfigMap.
- Pin the Grafana.com dashboard revisions in `values.yaml` (currently
  `latest`).
