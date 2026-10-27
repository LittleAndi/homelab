# ADR-0016: Docker Sandbox VM

**Status:** Proposed
**Date:** 2026-10-27

## Context

A place is wanted to run experimental or untrusted Docker containers
(sandboxes) without putting the Proxmox host, the cluster or Nextcloud at
risk. The workload is not specified yet; this ADR assumes throwaway or
agent-run code.

Host on 2026-10-27, after the worker resize (ADR-0008): 7.8 GiB available,
no swap, VMs 18 GB fixed (cluster 15, `haos` 3), KSM sharing ~1.2 GiB.

## Decision

### 1. A dedicated VM, started on demand

- VM **111 `sandbox`**, cloned from template 9000 (Ubuntu 26.04,
  cloud-init). **4 vCPU** (`host`), **2 GB fixed RAM** (no ballooning),
  **80 GB** thin disk on `local-zfs` (`discard`, `ssd`), guest agent.
- **`cpuunits: 25`** (others default 100), so the cluster and `haos` win
  under contention.
- **Disk I/O caps:** `mbps_rd/wr=200`, `iops_rd/wr=4000`. The NVMe is
  shared with MariaDB, Prometheus and the `local-path` volumes; loosen if a
  real workload needs it.
- **`onboot=0`.** Started with `qm start 111` when needed, shut down with
  `qm shutdown 111` afterwards. Costs no RAM while off.
- **zram in the guest** (zstd, 50% of RAM) for bursts. RAM-backed, so the
  zvol-swap deadlock (ADR-0008) doesn't apply. No other swap.
- Static IP **192.168.1.26**, gateway and DNS 192.168.1.1.
- Created by `infra/proxmox-sandbox/scripts/10-create-sandbox-vm.sh`
  (`qm clone` + cloud-init, as ADR-0012), outside the cluster's Terraform
  state.

Not on the host (ZFS, NFS, Samba, backups) and not in the cluster (shared
kernel with Nextcloud, sandboxes want privileged mode or the Docker socket).
A VM is the isolation boundary.

### 2. Docker in the VM

- Docker Engine + Compose plugin from Docker's apt repository.
- `daemon.json`: `json-file` logs, `max-size: 10m`, `max-file: 3`.
- User `sandbox` in the `docker` group (root-equivalent inside the VM only).
- Every container gets `--memory`, `--cpus` and `--pids-limit`.
- `docker system prune` on boot (a timer won't fire reliably on a VM that
  is mostly off). Unattended security upgrades on; rebuild, don't repair.

### 3. Network isolation

Proxmox firewall on the VM's NIC (`firewall=1`), in this order:

- **In:** TCP 22 from `{workstation-ip}` only; key-only SSH.
- **Out:** allow DNS to 192.168.1.1; drop 192.168.1.0/24 and
  100.64.0.0/10; allow the rest (internet).
- **IPv6 off in the guest** (`ipv6.disable=1`), so the IPv4 rules can't be
  bypassed.
- **`ipfilter: 1`** in the VM's firewall options, so the guest can only
  send from its configured IP (root in the guest could change it otherwise).
- **Second layer on the host:** an nftables rule dropping all input from
  192.168.1.26, next to ADR-0013's `inet exporters` table. Independent of
  the VM rules, and can't lock anyone out.
- No Tailscale on the VM.
- **Host firewall stays off.** Set `[OPTIONS] enable: 0` in
  `/etc/pve/nodes/pve/host.fw` *before* enabling the datacenter firewall;
  otherwise the host defaults to inbound DROP and blocks NFS, SMB and the
  ADR-0013 exporters.

### 4. Storage and monitoring

- No host directories, NFS or SMB access; no credentials beyond what a job
  needs. Disk not snapshotted or backed up (ADR-0011): everything in it is
  disposable.
- No extra exporter; the PVE exporter (ADR-0013) covers the VM.

## Alternatives considered

- **WSL on the workstation:** no server cost; the fallback, and the better
  fit if sandboxes only run against local repos.
- **Docker on the host / pods in MicroK8s / LXC with nested Docker:**
  weaker isolation.
- **Host firewall restricting SSH/8006 to the workstation and NFS/SMB to
  their clients:** general host hardening, not needed for the sandbox (the
  `.26` drop covers it), with real lock-out risk. A separate ADR if wanted.
- **`cpulimit`:** adds nothing on a 16-thread host with `cpuunits` set.
- **4 GB, always on:** ~2 GiB more host RAM permanently for an undefined
  workload. Grow when a workload needs it.
- **Ballooning:** Proxmox only reclaims above ~80% host use, so it saves
  nothing at idle.
- **Docker Sandboxes (microVM):** possible later; nested virtualization is
  already on (`kvm_amd nested=1`).

## Consequences

- Host available memory ~5.8 GiB while the sandbox runs, unchanged while
  off.
- Containers past 2 GB (plus zram) are OOM-killed inside the VM.
- The sandbox can't reach LAN services, by design.
- New value `{workstation-ip}` goes into `site.env` and `site.env.example`
  first (ADR-0014).

## Verification (after creation)

- From the VM, after every firewall change: `curl -m 5
  https://example.com` works; `.10` on 8006, 22, 2049 and 445,
  `192.168.1.20:16443` and ping to .25 all fail. With a changed guest IP,
  nothing leaves the VM.
- SSH works from the workstation, is refused from other LAN machines.
- Host NFS, SMB and exporter targets still up after the firewall change.
- `zramctl` shows the device; `docker run --rm --memory 256m alpine true`
  works.

## Open items

- Decide the workload (and whether Docker Sandboxes is wanted).
- Add `{workstation-ip}` to `site.env` and `site.env.example`.
- Write `infra/proxmox-sandbox/` (README + script 10), create the VM, verify.
