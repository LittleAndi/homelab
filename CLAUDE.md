# CLAUDE.md — working in this repo

Home server: Proxmox VE host (`pve`, 192.168.1.10) with ZFS, a 5-VM MicroK8s
cluster (Nextcloud, monitoring) and a Home Assistant VM. Decisions are ADRs in
`adr/`; the README indexes them and lists open items. Read the README and the
relevant ADR before changing anything.

## Rules

1. **Decisions become ADRs.** A decision made in a session is written up in
   the same session: new `adr/adr-NNNN-short-name.md` (next number), or a dated
   `## Update YYYY-MM-DD: …` on the existing ADR, plus the README row and its
   open items. Don't rewrite history; update Status and add Update sections.
   Keep the Status line, README row and open items in sync with what's live.
2. **The repo is public.** Never put a real site value in a tracked file.
   - Docs use `{placeholders}`, config uses `${KEY}`; both map to keys in
     `site.env` (gitignored; keys documented in `site.env.example`).
   - Never print, echo or quote `site.env` values in output, commits or
     files. A new identifying value goes into `site.env` *and* a new key in
     `site.env.example` before it's used.
   - Secrets never go in files: Kubernetes Secrets are created from the
     command line (`read -rs`), tokens live on the host or in the password
     manager. `terraform.tfvars`, `*.tfstate*`, `infra/proxmox-ha/backup/`
     are local-only.
3. **Render before Helm.** Run `scripts/render.sh`, then
   `helm upgrade … -f .rendered/<path>/values.yaml`. Always pass `--version`
   (pinned versions are in the ADR or the folder's README).
4. **Commits go through pre-commit** (gitleaks + `scripts/check-site-values.sh`).
   Never bypass it (`--no-verify`). If it blocks, fix the content.
5. **Ask before anything destructive or hard to undo** on the host or cluster:
   `zfs destroy`, `zpool` changes, `helm uninstall`, deleting PVCs/PVs,
   `terraform destroy`/`apply` that replaces VMs, rebooting the host.
   Read-only checks (`kubectl get`, `zfs list`, `systemctl status`) are fine.
6. **Use `/dev/disk/by-id/…`, never `sdX`** (letters shift; ADR-0009).
7. After `terraform apply`, a `site.env` change or a new Z-Stick backup, run
   `scripts/backup-local.sh`.

## Access from this machine (WSL)

- Cluster: `kubectl` / `helm` via the Tailscale operator's API proxy (context
  from `tailscale configure kubeconfig tailscale-operator`). Break-glass:
  `ssh ubuntu@192.168.1.20` then `sudo microk8s kubectl`.
- Proxmox host: `ssh root@pve`.
- Home Assistant: `http://192.168.1.25` (port 80) on the LAN.

## Layout

- `infra/proxmox-microk8s/` — host scripts `00–03`, Terraform, Ansible (ADR-0008)
- `infra/proxmox-microk8s/nextcloud/` — Helm values, MariaDB, runbook (ADR-0010)
- `infra/proxmox-microk8s/monitoring/` — kube-prometheus-stack, host exporters (ADR-0013)
- `infra/proxmox-ha/` — HAOS VM and backup scripts (ADR-0012)
- `scripts/` — `render.sh`, `check-site-values.sh`, `backup-local.sh` (ADR-0014)
