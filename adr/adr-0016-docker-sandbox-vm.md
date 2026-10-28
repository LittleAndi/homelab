# ADR-0016: Docker Sandbox VM

**Status:** Accepted — deployed 2026-10-27
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
- Minimal guest: snapd purged, multipathd and ModemManager off.
- `docker system prune` on boot (a timer won't fire reliably on a VM that
  is mostly off). Unattended security upgrades on; rebuild, don't repair.

### 3. Network isolation

Proxmox firewall on the VM's NIC (`firewall=1`), in this order:

- **In:** TCP 22 from `{workstation-ip}` only; key-only SSH.
- **Out:** allow DNS to 192.168.1.1; drop 192.168.1.0/24, 100.64.0.0/10
  and multicast/broadcast; allow the rest (internet).
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

## Update 2026-10-27: deployed

Scripts 10 and 11 run as written. All checks passed:

- From the VM: internet and DNS work; `.10` on 8006/22/2049/445,
  `.20:16443` and ping to .25 are blocked. A second address (.27) added in
  the guest can't get out (`ipfilter`). SSH from cp1 to .26 is refused.
- Host after enabling the datacenter firewall: NFS and SMB answer,
  exporters reachable from the nodes, all 32 scrape targets up.
- Memory: guest 399 MiB used at idle with Docker; zram 980 MiB. Host
  available 7.8 → 6.3 GiB while the VM runs.

## Update 2026-10-27: tailnet policy narrowed (precondition for Tailscale)

The policy file still had the default allow-all, so a tagged sandbox would
have reached every device. Changed in the admin console:

- Allow-all source `*` → `autogroup:member`: tagged devices (`tag:k8s`,
  `tag:k8s-operator`, later `tag:sandbox`) answer but never initiate.
- `tag:sandbox` added to `tagOwners` (`autogroup:admin`).
- `tests` block: members reach `tag:k8s`, `tag:k8s-operator`,
  `tag:sandbox:22`; `tag:sandbox` and `tag:k8s` are denied the members'
  devices. A save fails if a test does.

Verified: Nextcloud, Grafana, stockstalker, HA, `kubectl` via the operator
and `ssh root@pve` work as before; pve's packet filter admits 0 of 4 tagged
devices and all user-owned ones; no proxy errors.

Not done yet: the sandbox itself on the tailnet (`--accept-routes=false`,
non-ephemeral tagged key, `DOCKER-USER` drop to `tailscale0`), after the
change has held for a day.

## Update 2026-10-28: sandbox on the tailnet

Replaces "No Tailscale on the VM" in §3. Script 12 (guest) installs
Tailscale, joins as `tag:sandbox` (`--accept-routes=false`,
`--accept-dns=false`, auto-update on) with a pre-approved, single-use,
non-ephemeral key passed on stdin, and adds a `DOCKER-USER` drop for new
connections out `tailscale0`.

Verified: `ssh sandbox@sandbox.{tailnet}.ts.net` works from the
workstation. From the VM and from a container, pve (22, 8006), the
Nextcloud and Grafana proxies and the workstation are unreachable over the
tailnet; internet works. The policy change held a day: all tailnet
services up, no denial errors in the operator or proxy logs.

The LAN SSH rule (`{workstation-ip}` only) stays as a fallback for now.

## Update 2026-10-28: workload is Docker Sandboxes; trial at 2 GB

The workload is [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)
(`sbx`): AI coding agents (Claude Code and others) in microVMs on nested
KVM, each with its own kernel and Docker daemon, egress through a
deny-by-default proxy (UDP and ICMP blocked). Replaces §2 (Docker Engine)
and the `DOCKER-USER` rule from the update above.

- **Docker Engine removed**, `docker-sbx` (0.50.0) installed from Docker's
  apt repository; `sandbox` in the `kvm` group. Host has `nested=1`, CPU
  type `host`. Guest idle 399 → 350 MiB.
- **Stays at 2 GB for a trial.** A sandbox gets 50% of the VM by default
  (~1 GiB), at most 75% (`--memory`, ~1.4 GiB). Expect it to be tight for
  builds; 3 GB VM with `--memory 2g` is the next step if it is.
- **Layers:** microVM (inner) → `sbx` proxy policy → VM firewall → tailnet
  policy. The VM is now the trusted side of the sandbox.
- **Credentials in the VM** (reverses §4 "no credentials"): the Docker
  account login and the agent's credential, stored by `sbx` under
  `~/.config/com.docker.sandboxes` (0700, no keyring on a headless VM). The
  proxy injects them, so they never enter the microVM. A git credential, if
  any, is scoped to the repo being worked on.
- Isolation checks rerun after the change: all pass.

## Update 2026-10-28: sbx network policy and workspace layout

**Policy:** Balanced (deny by default, common dev sites allowed; 195
rules), minus 26 (→ 169), by script 13:

- **Open object storage**, where anyone can create a bucket and so an agent
  could upload code: `**.amazonaws.com`, `**.googleapis.com`,
  `**.blob.core.windows.net`, `**.public.blob.vercel-storage.com`,
  `**.googleusercontent.com`.
- **Other agents' and SaaS endpoints** (only Claude is used): OpenAI,
  Cursor, Gemini, Perplexity, Factory, models.dev, WorkOS, Supabase, Clerk,
  Figma, Daytona, Vercel.
- Kept: Anthropic, package managers, OS packages, certificate checks,
  GitHub/GitLab, container registries, read-only CDNs, Playwright.
- A tool that breaks gets its one host allowed (`sbx policy log` shows
  it), not the wildcard back.

**Workspaces:** one folder and one sandbox per project,
`~/work/<repo>`, always `sbx run claude --clone` from that folder. The
agent works on a private clone and its commits come back through the
`sandbox-<name>` remote, reviewed before pushing. Never start a sandbox from
`~`: it holds `sbx`'s credentials and `~/.ssh`. One folder for all projects
would put every repo in one sandbox's reach. The CLI can't narrow the
filesystem rules (`**`), so this is a convention.

**Pushing:** from `~/work/<repo>` in the VM, outside the sandbox, with a
per-repo GitHub deploy key (write); no account-wide token in the VM.

## Update 2026-10-28: pushing via branches and PRs

`main` is now protected by a ruleset (no deletion, no force-push, PR
required, 0 approvals, no bypass). This replaces the per-repo deploy key
and "reviewed before pushing" in the update above: the agent now pushes
before review.

- **Token:** per sandbox, fine-grained, one repo, Contents read/write only,
  30 days; `sbx secret set github --sandbox <name>`, injected by the `sbx`
  proxy. In `--clone` mode the agent's `origin` is GitHub, so it pushes a
  branch itself. Without Pull requests permission it can't open or merge a
  PR.
- **Accepted for now (option A):** the token acts as the owner, so the
  agent can also push to, delete or force-push any branch except `main`,
  and create tags. A branch is public as soon as it is pushed, before any
  check. Low risk here: the sandbox has no `site.env` and can't reach the
  LAN or the tailnet. Option B, if autonomy grows: a bot account with
  1 approval required on `main` and rulesets limiting it to `agent/**`,
  plus gitleaks and the site-value check as required CI checks.
- **Review on the workstation** before opening the PR: check the branch
  out (pre-commit hooks read the working tree), then
  `pre-commit run --from-ref origin/main --to-ref HEAD` and
  `pre-commit run --hook-stage manual gitleaks-range` (the normal gitleaks
  hook only scans staged changes).
- `sbx` forwards the SSH agent by default; the VM has none, and it is never
  reached with `ssh -A`.

## Update 2026-10-28: first `sbx run claude --clone` trial

First session: `sbx run claude --clone` on this repo (sandbox
`claude-homelab`, clone mode), doing docs and git work.

- **Memory:** the microVM sees **935 MiB** (the 50% default), ~330 MiB
  used and ~600 MiB available with Claude Code idle between tool calls. Docs
  and git work fit; builds and `terraform init` haven't been tried.
- **Isolation from inside the microVM:** a raw TCP connect to `.10:8006`,
  `.10:22`, `192.168.1.20:16443` and `.25:80` *succeeds*, because the `sbx`
  proxy accepts it. Over HTTP, Proxmox and HA get the proxy's 403 (policy
  block). SSH to `.10` gets no banner. Check with a real protocol, not a
  port probe.
- **Consequence:** a session in the sandbox can't reach `pve`, the cluster
  or HA (no `kubectl` either). Host and cluster checks run from the
  workstation; the sandbox is for repo work.
- **Pushing:** with the token from the update above, the agent pushed this
  branch itself; the PR is opened from the workstation.
- **pre-commit's gitleaks hook** compiles from Go source, so in the
  sandbox it needs extra hosts. Through the Go proxy that needs `storage.googleapis.com`
  (removed on purpose); with `GOPROXY=direct` it needs
  `go.googlesource.com`, `go4.org`, `gopkg.in` and `dario.cat`, allowed
  for this sandbox 2026-10-28 (never the `**.googleapis.com` wildcard). The
  site-values check skips without `site.env`, which a clone doesn't have.
- **Stays at 2 GB.** Grow to 3 GB with `--memory 2g` when a real workload
  hits the ceiling. VM-level usage (`free -m` in VM 111 during a session)
  not measured yet.

## Open items

- ~~Decide the workload.~~ Docker Sandboxes, 2026-10-28.
- Renew each sandbox's GitHub token before it expires: `claude-homelab`
  by 2026-11-27.
- ~~Try `sbx run claude --clone` on a first repo.~~ Done 2026-10-28:
  ~600 MiB free in the microVM for docs/git work; stays at 2 GB.
- Measure VM-level memory during a session; move to 3 GB (`--memory 2g`)
  if a build hits the ceiling.
- ~~Add `{workstation-ip}` to `site.env` and `site.env.example`.~~ Done
  2026-10-27 (`WORKSTATION_IP`). It's a DHCP address: reserve it on the
  router.
- ~~Write `infra/proxmox-sandbox/`.~~ Done 2026-10-27: script 10 (host:
  VM, firewall, nftables) and 11 (guest: Docker, zram, checks).
- ~~Create the VM and verify.~~ Done 2026-10-27.
- DHCP reservation for `{workstation-ip}` on the router.
- ~~Recheck operator/proxy logs, then put the sandbox on the tailnet.~~
  Done 2026-10-28 (script 12).
- Phone apps (Nextcloud, HA) away from home after the policy change.
- Decide whether the LAN SSH rule can go (then no DHCP reservation needed).
