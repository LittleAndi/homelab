# Monitoring (ADR-0013)

kube-prometheus-stack in the cluster (namespace `monitoring`), Grafana at
`https://grafana.{tailnet}.ts.net`, and three exporters on the Proxmox host.
30 days of retention, no alerts.

| File | What |
|---|---|
| `values.yaml` | kube-prometheus-stack values (contains `${TAILNET}`: render before use) |
| `host/20-setup-host-exporters.sh` | node_exporter, smartctl_exporter, pve-exporter, ZFS textfile timer, nftables limit; run on the host |
| `host/zfs-metrics.py` | ZFS pool/dataset/snapshot metrics for the textfile collector |
| `dashboards/` | Exported Grafana dashboards as ConfigMaps (empty until the "Server overview" dashboard is built) |

**Chart version:** `92.13.1` (app v0.94.1), picked 2026-10-26. Always pass `--version`.

## 1. Host exporters

From WSL, in the repo root:

```bash
scp -r infra/proxmox-microk8s/monitoring/host root@pve:/root/monitoring-host
ssh root@pve 'bash /root/monitoring-host/20-setup-host-exporters.sh'
```

The script ends with local checks; every line should show a non-zero count.
Then check the firewall from both sides:

```bash
ssh ubuntu@192.168.1.20 'curl -s --max-time 5 192.168.1.10:9100/metrics | grep -m3 zfs_pool'   # works
curl -s --max-time 5 192.168.1.10:9100/metrics                                                  # times out
```

If the Proxmox firewall is enabled at node level, it also has to allow TCP
9100, 9221 and 9633 from `192.168.1.20–.24`.

The PVE token is created once and lives only in `/etc/prometheus/pve.yml` on
the host. To rotate: delete that file and re-run the script.

pve-exporter is pip-installed and not updated by `apt upgrade`:

```bash
ssh root@pve '/opt/pve-exporter/bin/pip install -U prometheus-pve-exporter && systemctl restart pve-exporter'
```

## 2. Cluster (from WSL)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm search repo prometheus-community/kube-prometheus-stack     # note the version above

kubectl create namespace monitoring
read -rsp 'Grafana admin password: ' GF_PW; echo
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$GF_PW"
unset GF_PW

scripts/render.sh      # writes .rendered/… with the real tailnet from site.env
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f .rendered/infra/proxmox-microk8s/monitoring/values.yaml \
  --version 92.13.1
```

## 3. Verify

```bash
kubectl -n monitoring get pods -o wide        # prometheus on wk2, all Running
kubectl -n monitoring get pvc                 # prometheus 20Gi + grafana 1Gi, Bound
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
# http://localhost:9090/targets: every job up, including pve-node, pve-smartctl, pve
```

Then open `https://grafana.{tailnet}.ts.net`. The *Homelab* folder holds
Node Exporter Full and Proxmox via Prometheus; the chart's Kubernetes
dashboards sit under *General*.

Useful queries for the overview dashboard:

```promql
zfs_pool_capacity_percent
zfs_dataset_used_bytes{dataset=~"hdd-mirror/k8s|hgst/bulk|hgst/backup/.*"}
time() - zfs_dataset_newest_snapshot_timestamp_seconds     # snapshot / syncoid age
node_systemd_unit_state{state="failed"} == 1
smartctl_device_temperature
pve_up
```

## Upgrade

```bash
scripts/render.sh
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f .rendered/infra/proxmox-microk8s/monitoring/values.yaml \
  --version <NEW_VERSION>
```

Read the chart's upgrade notes first: major versions sometimes need CRDs
applied by hand.

## Removal

`helm uninstall kube-prometheus-stack -n monitoring` keeps the CRDs and the
PVs (`local-path-retain`). Delete those by hand if wanted. On the host:
`systemctl disable --now pve-exporter smartctl_exporter prometheus-node-exporter zfs-metrics.timer exporters-firewall`.
