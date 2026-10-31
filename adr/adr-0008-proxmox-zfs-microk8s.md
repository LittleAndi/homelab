# ADR-0008: Proxmox VE + ZFS + 5-VM MicroK8s Cluster

**Status:** Accepted — deployed and verified 2026-09-21; workers cut to 3 GB 2026-10-27; host updated to kernel 7.0.14-26 2026-10-31; Entra ID sign-in realm added 2026-10-31. Supersedes ADR-0004 and ADR-0006.

> The Decision section below is the original proposal. The dated Update
> sections record what changed on the way to the deployed state; where they
> differ, the Updates win.
**Date:** 2026-09-21

## Context

The server's role grew beyond a single-purpose Nextcloud box: running
Nextcloud alongside VMs for experimentation, and practising multi-node
Kubernetes. ADR-0004 and ADR-0006 both named this kind of growth ("VMs,
databases", "multi-node cluster") as the reason to revisit ZFS and Kubernetes.
The Azure/rclone backup (ADR-0003) is still the disaster-recovery anchor.

An earlier iteration planned 3 VMs (one Nextcloud VM with a reserved disk,
plus two thin-provisioned playground VMs) and a separate 6TB ZFS pool exposed
to them as ZVOLs. The design below replaces it.

## Decision

- **Hypervisor:** Proxmox VE on bare metal (API at `192.168.1.5:8006`, node `pve`).
- **SSD pool:** 1TB SSD as a single-disk ZFS pool (`local-zfs`) that holds
  Proxmox and all VM boot disks. Keep usage under ~80% to avoid ZFS
  allocator slowdown.
- **HDD pool:** the two 2TB WD HDDs as a ZFS **mirror** (`hddmirror`),
  chosen over striping so one drive failure doesn't lose the pool. Dataset
  `hddmirror/nextcloud-data` is NFS-exported to the LAN.
- **Cluster:** 5 Ubuntu 26.04 VMs cloned from a cloud-init template (VMID 9000):

  | Node | VMID | IP | vCPU | RAM | Disk |
  |---|---|---|---|---|---|
  | cp1–cp3 (control plane / dqlite) | 101–103 | 192.168.1.10–.12 | 2 | 5 GB | 40 GB |
  | wk1–wk2 (workers) | 104–105 | 192.168.1.13–.14 | 4 | 6 GB | 60 GB |

  Static IPs sit outside the router's DHCP pool (192.168.1.64–.243).
- **Control-plane disks** get a hard ZFS `refreservation` (40G each). That
  way thin-provisioned worker disks filling the pool can't starve dqlite's
  writes.
- **Tooling:** Terraform (`bpg/proxmox` provider) provisions the VMs.
  Ansible with the community `istvano.microk8s` role forms the cluster, which
  avoids hand-rolled join-token logic.
- **Storage for workloads:** `nfs-subdir-external-provisioner` as the default
  StorageClass `nfs-client`, backed by the ZFS mirror. The `hostpath-storage`
  addon is disabled so PVCs don't land on boot disks.
- **Backups:** snapshot each ZFS dataset and point the existing Azure/rclone
  pipeline at `.zfs/snapshot/…` instead of the live directory, for
  crash-consistent backups.

## Alternatives considered

- **Keep bare-metal Linux + Podman + mergerfs (ADR-0004/0006)**: simpler and
  lighter, but no VM isolation for experiments and no Kubernetes practice.
- **3-VM layout with a Nextcloud VM + ZVOL-backed disks** (earlier plan):
  replaced by the cluster + NFS StorageClass design.
- **k3s**: not chosen; MicroK8s with an existing Ansible role was preferred.

## Consequences

- Supersedes ADR-0004 (mergerfs) and ADR-0006 (Podman) once accepted.
  ADR-0005's tiering principle carries over (SSD pool vs HDD mirror).
  ADR-0007's stack has to be re-platformed onto Kubernetes.
- 3 control-plane nodes on one physical host give quorum practice, not
  hardware HA. The host is still a single point of failure.
- VM RAM adds up to 27 GB before Proxmox/ZFS ARC overhead, so it has to fit
  the server's installed RAM.
- NFS with `no_root_squash` exported to the whole /24 is broad. Consider
  narrowing it to the 5 node IPs. *(Done, see storage-layout update.)*

## Update 2026-09-21: validated against the live host

Checked the running Proxmox host (PVE 9.2.20, Ryzen 7 7700, 32 GB RAM) via
its API. Nothing deployed yet: no VMs, no template 9000, no API token.
Changes to the decision above, applied in `infra/proxmox-microk8s/`:

- **Addressing.** The Proxmox host is at **192.168.1.10**, not `.5`. Servers
  (VMs) use **192.168.1.20–.63**. Cluster nodes move to
  cp1–cp3 = `.20–.22`, wk1–wk2 = `.23–.24`. `NFS_SERVER` = `.10`.
- **HDD pool name** is **`hdd-mirror`** (already created, ONLINE, both WD
  disks by-id, also registered as Proxmox storage). Dataset path is
  `hdd-mirror/nextcloud-data`, exported at `/hdd-mirror/nextcloud-data`.
  `01-setup-zfs-nfs.sh` no longer creates the pool.
- **VM DNS** is set explicitly (`dns_servers`, default `192.168.1.1`). The
  host's resolvers are Tailscale-only, which the VMs can't reach.
- `local-zfs` = `rpool/data` on the 1 TB NVMe (confirmed).

Host prerequisites found missing (README step 0):

- No `vmbr0`. The host runs on Wi-Fi (`wlp5s0`); wired `nic0` is
  unconfigured. Wi-Fi can't be bridged, so a wired `vmbr0` on `nic0` is
  required before the template or VMs can have networking.
- Host DNS has no LAN fallback if tailscaled is down.
- Only `root@pam` exists; a `terraform@pve` API token is needed.
- RAM was tight: 27 GB VMs + ~3 GB ARC on 32 GB with no swap (resolved
  below).

## Update 2026-09-21: VM RAM reduced

- **Control plane 3 GB each, workers 4 GB each: 17 GB total** (was 27 GB).
  That leaves ~15 GB for Proxmox, ZFS ARC and headroom on the 32 GB host.
- **Fixed allocation, no ballooning.** Kubernetes schedules against a node's
  maximum memory, so ballooning would let it over-commit what the host can
  actually give back.
- **Grow later as needed:** raise `memory` in `terraform/main.tf`, apply, then
  drain → reboot → uncordon one node at a time. 3 control-plane nodes keep
  quorum during the rolling reboot.
- MicroK8s control-plane nodes also run workloads by default, so all
  5 nodes add to usable capacity.

## Update 2026-09-21: storage layout

Discussed NFS vs. block volumes (ZVOL virtual disks) for Nextcloud, which is
currently the only workload needing storage. Decision:

- **VM OS disks always on the SSD** (`local-zfs`). `hdd-mirror` holds bulk
  data only (ADR-0005's tiering carries over).
- **NFS for Nextcloud user files.** Chosen over a ZVOL data disk mainly so
  the data stays as plain files in a host-side ZFS dataset: the existing
  snapshot → rclone → Azure backup runs on the host unchanged, and the data
  survives a cluster rebuild. It also allows several Nextcloud pods later
  (RWX). Accepted costs: NFS service on the host, sync writes to HDD are
  slower for many small files. Raw throughput is HDD-bound either way.
- **Not NFS for the database.** InnoDB on NFS is discouraged (locking/fsync
  semantics), and the NFS tier is HDD anyway. MariaDB and the Nextcloud
  app/config volume use `local-path-provisioner` (StorageClass `local-path`,
  non-default) on a node's SSD boot disk. The pod is pinned to that node,
  which costs little on a single physical host. Proxmox CSI plugin is the
  upgrade path if more stateful apps arrive.
- **DB backup:** nightly `mariadb-dump` CronJob writing to the NFS share, so
  everything worth keeping ends up as files on `hdd-mirror` and in the Azure
  pipeline. (Designed with the Nextcloud migration.)
- **One dataset + one NFS export per consumer.** Cluster storage is
  `hdd-mirror/k8s` (replaces `hdd-mirror/nextcloud-data`), 500G reservation,
  exported via `/etc/exports.d/k8s.exports` to the 5 node IPs only
  (`no_root_squash` makes a /24 export unsafe). A future playground VM gets
  either a plain data disk on `hdd-mirror` or its own dataset/export with a
  quota, never access to `k8s`.

## Update 2026-09-21: own Ansible playbook instead of istvano.microk8s

The first run with the `istvano.microk8s` role left five standalone
single-node clusters on MicroK8s 1.27 with hostpath-storage, registry and
dashboard enabled. The role (last change March 2024) defaults to
`1.27/stable`, only clusters with `microk8s_enable_HA` + a `microk8s_HA`
group, and ships add-on defaults that contradict this ADR.

- Replaced with a short playbook using only `ansible.builtin`
  (`infra/proxmox-microk8s/ansible/`): pinned channel **1.35/stable**
  (`vars.yml`), snap auto-refresh held, joins via one-time tokens
  (cp2/cp3 control plane, wk1/wk2 `--worker`, serially), `/etc/hosts`
  entries for all nodes.
- Add-ons: dns (upstream 192.168.1.1), rbac, metrics-server, helm3.
  hostpath-storage, registry, dashboard kept disabled.
- Channel mismatch stops the run unless `-e microk8s_reset=true` (purge +
  reinstall). Upgrades are manual, one node at a time.
- Tooling bullet in the Decision section ("community `istvano.microk8s`
  role") is superseded by this.

## Update 2026-09-21: deployed and verified

Everything in `infra/proxmox-microk8s/` has been run against the host.

- **Cluster:** 5 nodes Ready on MicroK8s **v1.35.6** (containerd 2.1.6,
  Ubuntu 26.04.1, guest kernel 7.0). `high-availability: yes`, dqlite voters
  `.20`, `.21`, `.22`. Add-ons: dns, rbac, metrics-server, helm3 (plus
  MicroK8s' own ha-cluster and helm).
- **Storage:** StorageClasses `nfs-client` (default, `hdd-mirror/k8s` via
  NFS) and `local-path` (local-path-provisioner **v0.0.37**, node SSD).
  Smoke test passed: RWX claim on NFS and RWO claim on local-path both
  bound; the file written over NFS appeared in `/hdd-mirror/k8s/` on the
  host. Test resources removed.
- **Host:** 120 GiB refreservation on the 3 control-plane disks; `local-zfs`
  ~14% used.

Fixes found during deployment (all in the scripts/playbook now):

- Template image gets `qemu-guest-agent` via `virt-customize` (script 00);
  without it Terraform waits for the agent timeout.
- VMs use CPU type `host`, `discard=on` + agent `trim` (thin-provisioned
  ZFS), cloud-init drive on `local-zfs`.
- Every node needs `nfs-common`; without it the kubelet can't mount NFS
  volumes (`bad option … mount.<type> helper`). Installed by the playbook.
- Playbook waits for a joined node to register before `kubectl wait`, and
  writes the `/etc/hosts` block into the cloud-init template too
  (`manage_etc_hosts: true` rewrites `/etc/hosts` on boot).
- API token is passed as `TF_VAR_proxmox_api_token`, not stored in
  `terraform.tfvars` (the folder syncs to Nextcloud).
- Proxmox shows the VMs at ~100% memory because ballooning is off, so it
  only sees allocated RAM. Real usage: `free -h` in the guest or
  `kubectl top nodes`.

## Update 2026-10-25: API token out of `terraform.tfvars`

The 2026-09-21 note above says the token came from
`TF_VAR_proxmox_api_token`, but `terraform.tfvars` still held it (found
2026-10-22). The line was removed from the local file on 2026-10-25, the
`.example` and the setup README now point to the environment variable. The
old token has been in a file that syncs to Nextcloud (and in
`LOCAL_BACKUP_DIR` copies), so it is rotated rather than just moved.

Rotated the same day: new token `tf2` (`privsep 0`, so it inherits the
user's `TerraformProv` role), `terraform plan` showed no changes, then `tf`
was removed. The secret is in the password manager and is read into
`TF_VAR_proxmox_api_token` per shell. Note for bash: the `!` in
`terraform@pve!tf2=…` must be in single quotes, or history expansion
rejects the line.

## Update 2026-10-27: workers cut to 3 GB (cluster 17 → 15 GB)

Measured over the 42 h of Prometheus history (since ADR-0013):

| Node | Allocated | Peak used | Lowest available | Main pods |
|---|---|---|---|---|
| cp1–cp3 | 3 GB | 1.45–1.98 GiB | 0.91 GiB (cp2) | Grafana, Nextcloud app, stockstalker |
| wk1 | 4 GB | 1.59 GiB | 2.09 GiB | MariaDB (peak 793 Mi) |
| wk2 | 4 GB | 1.73 GiB | 2.01 GiB | Prometheus (peak 933 Mi) |

Host: 24.9 of 31 GiB used, 5.7 GiB lowest available, no swap.

- **Workers 4 → 3 GB.** Workers don't run the API server or dqlite, so
  their base is ~0.6 GiB; at 3 GB the worst-case limit on each (MariaDB
  1.5 Gi, Prometheus 2 Gi) still fits. Memory requests add up to ~4.2 GiB
  across the cluster.
- **Control plane stays at 3 GB.** Base ~1.2 GiB per node (kubelite +
  dqlite) and cp2 already dipped to 0.9 GiB available; 2.5 GB would leave
  ~400 MiB.
- **Grow, don't pre-provision.** Watch node memory in Grafana and raise a
  node again if it gets tight, rather than keeping headroom unused.
- **Result:** host available memory 6.2 → 8.0 GiB; all 32 scrape targets up.

Done without Terraform (token not in the shell): one worker at a time,
`kubectl drain`, `qm set <vmid> --memory 3072`, `qm reboot <vmid>`
(applies the pending change), uncordon. `terraform/main.tf` has the same
value, so the next `terraform plan` should show no changes. This also
avoids the provider rebooting both workers at once on apply.

Learned during the drain:

- **`local-path` volumes pin pods to their node.** Draining wk1 left
  `nextcloud-db-0` Pending (PV node affinity), so Nextcloud was down until
  wk1 was back (~2 min). Same on wk2 for Prometheus and stockstalker's
  postgres; on cp2 for Grafana, on cp3 for the Nextcloud app volume. A
  node reboot is a short outage of whatever has its volume there.
- **The Tailscale operator is the `kubectl` path.** Draining its node
  (wk1) reset the connection mid-drain; it was rescheduled on cp3 and a
  second `drain` finished the job.
- **Swap:** none in the guests (kubelet default, and an OOM kill is easier
  to see than a node thrashing). On the host, never on ZFS (zvol swap can
  deadlock under memory pressure); zram is the option if the host ever
  needs a buffer. Not decided.

## Update 2026-10-31: host updated; graceful reboot script runs from the workstation

The host got its pending packages and kernel 7.0.14-26 (fix for
CVE-2026-98432, per Proxmox staff in forum thread 187339; 7.0.14-25 and later).

- **`/usr/local/sbin/graceful-shutdown.sh` on the host was removed.** It could
  only power off, left Nextcloud and its database at 0 replicas, and root on
  the host has no SSH key for the nodes. The failed pod count read as "no pods
  left", so it would have powered off at once with Nextcloud still running.
- **`scripts/graceful-shutdown.sh` replaces it,** run from the workstation:
  `check`, `reboot`, `poweroff`, `start`. It stops on any cluster failure.
  The reboot and power-off paths have only run against a stubbed `ssh` so far.

Learned during the reboot:

- **Pod deletions can be missed.** After scaling to 0, the Nextcloud pod (cp3)
  and database pod (wk1) stayed `Terminating` past their 30 s grace period. The
  kubelets still listed them as running with no deletion set. Cause not
  established; the host reboot cleared it.
- **Don't restart kubelite on a control-plane node to clear this.** On cp3 it
  restarted 3 times, couldn't find its own node, `microk8s status` hung there
  and `k8s-dqlite` logged range errors, while cp1 and cp2 stayed healthy.
- **Rebooting anyway worked.** The VM shutdown stopped the database, which
  started without crash recovery. The scale to 0 was kept in the datastore.
- **A reboot during a Tailscale control-plane incident can leave a machine off
  the tailnet** until the incident clears (seen on the HA add-on, which rejoined
  by itself). LAN access keeps working; `check` warns about open incidents.

## Update 2026-10-31: Entra ID sign-in realm

The Proxmox UI can now be signed in to through Entra ID, with a built-in OpenID
Connect realm `entra` (no extra software, no restart). It is an addition:
`root@pam` and the `pve` realm's accounts are unchanged, and `pam` stays the
fallback for when Microsoft or the internet connection is down.

- **App registration:** *Proxmox homelab*, separate from Grafana's, in the same
  single tenant (ADR-0013). The client ID is in `site.env`.
- **Address:** the only redirect URI is `https://pve.{tailnet}.ts.net`, the
  Tailscale Serve address with a valid certificate. Entra sign-in therefore
  works only from there; on `https://192.168.1.10:8006`, use `pam`.
- **Who gets in:** three gates: assignment is required on the enterprise
  application, `autocreate` is off, and a Proxmox user needs an explicit ACL.
  Roles live in Proxmox, because the realm doesn't read Entra roles.
- **Username:** `{object-id}@entra`, from the `oid` claim (`--username-claim`
  can't be changed later). `oid` is immutable and known in advance, so a user
  can be created before the first login, whereas an email can change.
- **Claims:** read from the ID token (`--query-userinfo 0`); the v2 token has
  `oid` with the `profile` scope.
- **First user:** the owner, as `Administrator` on `/`. Some operations remain
  limited to `root@pam`.
- **Client secret:** on the host in `/etc/pve/domains.cfg`, piped from `az` over
  SSH. It expires **2028-10-31**.

To add a user, assign them to *Proxmox homelab* in Entra, then on the host:

```bash
pveum user add '{object-id}@entra' --comment '{who}'
pveum acl modify / --users '{object-id}@entra' --roles {role}
```

To rotate the secret, load `site.env`, then from WSL:

```bash
az ad app credential reset --id "$ENTRA_PVE_CLIENT_ID" --display-name proxmox \
  --years 2 --query password -o tsv \
  | ssh root@pve 'read -r K; pveum realm modify entra --client-key "$K"'
```

## Open items

- Confirm a full Entra login at `https://pve.{tailnet}.ts.net`. So far Entra
  has only been seen to accept the authorize request (2026-10-31).
- Rotate the Proxmox Entra client secret by 2028-10-31. Nothing alerts on its
  expiry.
- ~~Run `terraform plan` (with `TF_VAR_proxmox_api_token`) to confirm no
  drift after the 2026-10-27 worker resize, then `scripts/backup-local.sh`.~~
  Done 2026-10-27: no changes; backup run.

- ~~Rotate the `terraform@pve` token: new token into the password manager,
  delete the old one, `terraform plan` shows no changes.~~ Done 2026-10-25
  (`tf` → `tf2`).
- ~~Confirm this ADR (Proposed → Accepted) and mark ADR-0004/0006 Superseded.~~
  Done 2026-09-21.
- ~~`scripts/03-setup-nfs-provisioner.sh` has `NFS_SERVER="192.168.1.1"`~~
  Fixed 2026-09-21 (now `.10`, see Update).
- ~~Host prerequisites: wired `vmbr0`, DNS fallback, Terraform API token.~~
  Done 2026-09-21: `vmbr0` on `nic0` (.10), Wi-Fi and wpa_supplicant disabled;
  `tailscale set --accept-dns=false`, host DNS `192.168.1.1`; `terraform@pve`
  with token `tf` and role `TerraformProv` on `/`; kernel 7.0.14-19.
  Terraform now also places the cloud-init drive on `local-zfs`
  (provider default `local-lvm` doesn't exist here).
- Design the Nextcloud/MariaDB/Redis deployment into the cluster (new ADR,
  replaces ADR-0007's Compose stack). Include a `local-path` StorageClass
  with `reclaimPolicy: Retain` for MariaDB (the default `local-path` deletes
  data with the PVC).
- ~~Point the Azure/rclone backup at snapshots of `hdd-mirror/k8s`
  (`.zfs/snapshot/…`); not set up yet.~~ Done 2026-10-26: nightly sync of
  the newest daily snapshot to its own storage account (ADR-0011 §3).
- ~~Host updates (found 2026-10-26): 39 packages pending, 27 of them from
  `stable-security`. Plan a maintenance window: `apt full-upgrade` on the
  host, reboot if the kernel or `pve-*` changed (needs an OK; the VMs and
  the cluster go down with it), then check the cluster, HA and the timers.~~
  Done 2026-10-31 (see Update).
- Node kernels: rolling update to Ubuntu 7.0.0-43 once it's released, one node
  at a time. Watch for pods stuck in `Terminating` while draining (see Update).
- Find out why the kubelets missed the pod deletions on 2026-10-31.
- Role of the 1TB HDD(s) and the planned 6TB drive(s) under this design (see ADR-0009).
  Live host shows one 1 TB HGST (`sdc`, blank) and a 512 GB Samsung SSD with NTFS (`sdd`).
