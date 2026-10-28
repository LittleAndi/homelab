# homelab — Home Server Decision Records and Infrastructure

Architecture Decision Records (ADRs) for the home server build. Each ADR
captures context, decision, alternatives and consequences *at the time*.
When a decision changes, update its **Status** and add a dated
`## Update` note, or write a new ADR. Don't rewrite history.

| # | Decision | Status |
|---|---|---|
| [0001](adr/adr-0001-hardware-platform.md) | Hardware platform (board, CPU, Jonsbo N6) | Accepted |
| [0002](adr/adr-0002-operating-system.md) | Linux over Windows | Accepted — distro settled by 0008 |
| [0003](adr/adr-0003-retire-firmware-raid.md) | Retire firmware RAID; rely on Azure backup | Accepted |
| [0004](adr/adr-0004-storage-pooling.md) | mergerfs pooling, SnapRAID deferred | Superseded by 0008 |
| [0005](adr/adr-0005-storage-tiering.md) | SSD for system/DB, HDD for bulk data | Accepted — implemented via 0008 |
| [0006](adr/adr-0006-container-platform.md) | Podman | Superseded by 0008 |
| [0007](adr/adr-0007-application-stack.md) | Compose stack, Tailscale+Caddy, observability | Superseded by 0010 |
| [0008](adr/adr-0008-proxmox-zfs-microk8s.md) | Proxmox VE + ZFS + 5-VM MicroK8s | Accepted — deployed 2026-09-21; workers 4 → 3 GB 2026-10-27 (cluster 15 GB) |
| [0009](adr/adr-0009-storage-expansion-hba.md) | IT-mode HBA for SATA expansion; disk inventory | Accepted — **LSI 9300-8i** (instead of 9211-8i) installed 2026-10-20 |
| [0010](adr/adr-0010-nextcloud-microk8s-deployment.md) | Nextcloud on MicroK8s: like-for-like move, Helm chart + own MariaDB, Tailscale operator | **Accepted — migrated 2026-09-26; on 35.0.2 (PHP 8.5.12) since 2026-10-23** |
| [0011](adr/adr-0011-snapshots-backup-hgst.md) | Sanoid snapshots, HGST pool for local backup + bulk data (SMB), Azure from snapshot | Accepted — implemented 2026-09-26; Azure sync since 2026-10-26 |
| [0012](adr/adr-0012-home-assistant-vm.md) | Home Assistant OS VM (110) with Z-Wave + Zigbee sticks; host scripts, NFS backups | Accepted — **VM deployed 2026-10-24** (HA 2026.10.3, Tailscale Serve, NFS backups); radios not set up yet |
| [0013](adr/adr-0013-monitoring.md) | Monitoring: kube-prometheus-stack in the cluster (Grafana via Tailscale), exporters on the host; 30 d, no alerts | Accepted — **deployed 2026-10-26** (chart 92.13.1) |
| [0014](adr/adr-0014-public-git-repo.md) | Public git repo `homelab`; site values in gitignored `site.env`, placeholders in git; pre-commit guard rails | Accepted — **public since 2026-10-24** (MIT) |
| [0015](adr/adr-0015-host-notifications-discord.md) | Host notifications: Proxmox notification system → Discord webhook; smartd/zed/failed backup units via mail to root | Accepted — deployed 2026-10-26; Discord only |
| [0016](adr/adr-0016-docker-sandbox-vm.md) | Sandbox VM (111) for Docker Sandboxes (`sbx`, microVMs): 2 GB, on demand, firewalled off the LAN and tailnet | Accepted — deployed 2026-10-27 |

## Open items

- **ADR-0016**: sandbox VM 111 deployed 2026-10-27, all isolation checks
  passed; tailnet allow-all narrowed to members; on the tailnet as
  `tag:sandbox` since 2026-10-28; workload is Docker Sandboxes (`sbx`,
  Docker Engine removed); agent pushes branches with a per-sandbox token,
  PRs from the workstation (`main` protected). Left: renew the
  `claude-homelab` token by 2026-11-27; trial `sbx run claude` at 2 GB,
  then keep or grow to 3 GB; phone apps away from home; keep or drop the LAN SSH rule
  (DHCP reservation for `{workstation-ip}` if kept).
- **ADR-0015**: Discord notifications live 2026-10-26 (smartd, zed, failed
  backup units, Proxmox jobs); `default-matcher` (mail) disabled. Nothing
  left.
- **ADR-0014**: public since 2026-10-24 with secret scanning + push
  protection (MIT). Left: connect the repo to the Project (GitHub
  integration) and remove the hand-uploaded docs; retire `NAS/adr`,
  `NAS/infra`, `NAS/README.md` in Nextcloud. (Token rotated and first
  `backup-local.sh` run 2026-10-25.)
- **ADR-0013**: deployed 2026-10-26 (chart 92.13.1, all 32 targets up,
  Grafana on the tailnet). Left: build the "Server overview" dashboard and
  export it as a ConfigMap. (Dashboard revisions pinned 2026-10-26.)
- **ADR-0012**: VM, static IP (.25), Tailscale Serve and NFS backups done
  2026-10-24. Left: store the HA backup encryption key; choose ZHA or
  Zigbee2MQTT; Z-Wave JS + Z-Stick NVM backup before pairing; USB extension
  cables. (`:8123` → port 80 in the docs fixed 2026-10-25.)
- **ADR-0011**: snapshots, HGST backup copy, SMB share and the nightly
  Azure sync are live (first upload 2026-10-26: 207 GiB, verified, restore
  tested). Left: confirm the 2026-10-27 03:00 UTC run is incremental;
  check the daily snapshot is back at 01:30 UTC (the DST night's ran at
  02:00).
- **ADR-0010**: on 35.0.2 since 2026-10-23; MariaDB tuned (512M buffer
  pool, 256M redo log). Left: recheck the buffer pool hit rate after a few
  days; pin the chart version
  (always `helm upgrade … --version 9.3.0` until then); back up `config/`
  before major upgrades (the app volume isn't snapshotted); decommission
  the Podman stack on `{workstation}` (unblocked: Azure sync runs since 2026-10-26);
  optional Redis/Valkey. (Observability follow-up: ADR-0013.)
- **ADR-0008 (VM RAM, 2026-10-27)**: workers cut to 3 GB via `qm set`
  (host available 6.2 → 8.0 GiB); `terraform plan` clean, backup run.
  Left: grow a node again if Grafana shows it tight. Host zram: optional,
  not decided.
- **ADR-0008 (host updates, found 2026-10-26)**: 39 packages pending on
  the host, 27 security. Maintenance window: `apt full-upgrade`, reboot if
  needed (ask first), check cluster/HA/timers afterwards.
- **ADR-0009**: HBA (9300-8i, IT mode) installed 2026-10-20; the Seagate on it
  passed an extended self-test. Left: check HBA heatsink temperature; roles
  for the Seagate 1TB and Samsung 512GB SSD; 6TB purchase; GPU use. Disk
  letters shifted with the HBA: use `/dev/disk/by-id/…`, not `sdX`.

## Using this repo

Site-specific values (tailnet name, account names, disk serials, …) are not in
git. Docs show them as `{placeholders}`; config that needs the real value uses
`${KEY}`. Both map to keys in `site.env` (ADR-0014).

```bash
cp site.env.example site.env          # fill in real values (gitignored)
pipx install pre-commit && pre-commit install
scripts/render.sh                     # .rendered/… = config with real values
helm upgrade … -f .rendered/infra/proxmox-microk8s/<app>/values.yaml
scripts/backup-local.sh               # copy local-only files to LOCAL_BACKUP_DIR
```

Local-only, gitignored: `site.env`, `terraform.tfvars`, `*.tfstate*`,
`.terraform/`, `infra/proxmox-ha/backup/`, `*.local.yaml`, `.rendered/`.
Secrets are never in files at all: they go into Kubernetes Secrets from the
command line or stay on the host.

## Way of working

Where each kind of information lives (ADR-0014):

| What | Master | Mirror |
|---|---|---|
| ADRs, README, `infra/`, `scripts/` | **This git repo** (changes via Claude Code in WSL, see `CLAUDE.md`) | `adr/` + README synced into the Claude Project via its GitHub integration (press Sync after a push) |
| Site values, tfvars, tfstate, device backups | `site.env` and local files in the clone | `LOCAL_BACKUP_DIR` in Nextcloud; tokens in the password manager |
| Manuals, superseded copies | Nextcloud `NAS/reference/`, `NAS/_archive/` | — |
| Current status, loose ends | Project memory | Short notes only. Decisions go in an ADR |

Rules:

1. **A decision made in chat gets written up as an ADR in the same session**
   and committed here. A decision reached in a Project chat is handed to
   Claude Code to write up; the Project only ever syncs from the repo.
2. **The repo is the master copy.** If the Project differs, the repo wins.
3. Memory never holds a decision on its own. If it matters later, it goes in an ADR.
4. New ADRs: next number, `adr/adr-NNNN-short-name.md`, add a row above.
5. A new identifying value goes into `site.env` (and its key into
   `site.env.example`) **before** it's used anywhere; the pre-commit hook only
   blocks values it knows.

### Layout

```
homelab/
├── README.md
├── adr/
├── infra/
│   ├── proxmox-microk8s/             ← ADR-0008: scripts, Terraform, Ansible
│   ├── proxmox-microk8s/nextcloud/   ← ADR-0010: runbook, values.yaml, mariadb.yaml,
│   │                                    pvcs.yaml, loader-pod.yaml, storageclass, dump cronjob
│   ├── proxmox-microk8s/monitoring/  ← ADR-0013: runbook, values.yaml, host exporters
│   ├── proxmox-ha/                   ← ADR-0012: HAOS VM + backup scripts, README
│   └── proxmox-sandbox/              ← ADR-0016: sandbox VM + guest setup scripts, README
├── CLAUDE.md                         ← rules for Claude Code in this repo
├── scripts/                          ← ADR-0014: render.sh, check-site-values.sh, backup-local.sh
├── site.env.example                  ← keys + placeholder map (site.env itself is gitignored)
└── .pre-commit-config.yaml           ← gitleaks + site-value check
```

## Licence

[MIT](LICENSE), for both the code and the docs.
