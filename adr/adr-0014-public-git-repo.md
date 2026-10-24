# ADR-0014: Public Git Repo `homelab`; Site Values and Secrets Kept Local

**Status:** Accepted 2026-10-24 — public at `github.com/LittleAndi/homelab` since 2026-10-24 (MIT)
**Date:** 2026-10-24

## Context

The ADRs, IaC and scripts live in a Nextcloud-synced `NAS/` folder, with the
ADRs and README mirrored to the Claude Project. Nextcloud gives sync, but no
history, diffs or rollback. The plan is to move everything into a **public**
GitHub repo.

A scan of the folder on 2026-10-24 found:

- **Secrets:**
  - `terraform/terraform.tfvars` holds the real `terraform@pve` token. This
    was already an ADR-0008 open item: remove it and rotate the token.
  - `terraform.tfstate` and `.tfstate.backup` contain `password` and `keys`
    attributes.
  - `infra/proxmox-ha/backup/` holds a Z-Stick NVM backup, which includes
    the Z-Wave network keys.
- **Not secret, but identifying:** the tailnet name, the Nextcloud instance
  id and account names, the workstation's hostname and paths, Azure and
  rclone names, and disk serial numbers.
- **Everything else is clean:**
  - manifests, Helm values, the playbook and the scripts contain no secret
    values, because secrets have always come from the command line or stay
    on the host;
  - the "password" hits in the ADRs are prose, not values.
- **Not ours to publish:** `reference/` holds vendor PDFs.
- **Not worth publishing:** `_archive/`.

## Decision

### 1. One public repo, outside Nextcloud

- **Location:** GitHub repository **`homelab`**, cloned in WSL at
  `~/src/homelab`.
- **Not inside Nextcloud:** syncing a `.git` directory through Nextcloud
  risks lock-file conflicts and half-synced objects.
- **Fresh history:** the first commit is the cleaned tree. Nothing from
  before the clean-up is ever committed, because deleting a secret later
  doesn't remove it from git history.
- **Contents:** `README.md`, `adr/`, `infra/`, `scripts/`, plus the repo
  configuration (`.gitignore`, `.gitattributes`, `site.env.example`,
  `.pre-commit-config.yaml`).

### 2. Local-only files (gitignored)

| File | Why |
|---|---|
| `site.env` | Real site values (§3) |
| `infra/proxmox-microk8s/terraform/terraform.tfvars` | API token, SSH key comment |
| `*.tfstate`, `*.tfstate.*` | Passwords and keys in state |
| `.terraform/` | Provider cache |
| `infra/proxmox-ha/backup/` | Z-Wave network keys |
| `*.local.yaml`, `*.local.env`, `.rendered/` | Local overlays and rendered output |

- **Backup:** `scripts/backup-local.sh` copies these files to
  `LOCAL_BACKUP_DIR` (in Nextcloud), keeping their repo-relative paths.
  Git never has them, so this backup and the password manager are the only
  copies.
- **What stays in Nextcloud:** `reference/` and `_archive/` stay in the
  Nextcloud folder and are not in the repo.

### 3. Identifying values: placeholders in git, real values in `site.env`

- **`site.env`** (gitignored) holds every identifying value.
  **`site.env.example`** (tracked) has the same keys with dummy values,
  plus a comment mapping each key to its placeholder in the docs.
- **Docs** use readable placeholders in braces, for example
  `nextcloud.{tailnet}.ts.net`, `{nc-instanceid}`, `{hgst-serial}` and
  `{workstation}`. Braces are used rather than `<…>`, which GitHub's
  Markdown renderer would hide as an HTML tag.
- **Config that must run with the real value** uses `${KEY}`. Today that is
  only `${TAILNET}`, in the two Helm `values.yaml` files.
  - `scripts/render.sh` writes copies with real values to `.rendered/`, and
    `helm` reads from there.
  - Only keys listed in `site.env.example` are substituted; any other `$VAR`
    in a file is left alone.
- **Redacting existing ADRs:** replacing these values in ADR-0009 to
  ADR-0013 is a redaction, not a rewrite of what was decided. No other
  wording changed.
- **Rejected: git clean/smudge filters**, which would show real values in
  the working copy automatically. The filter configuration lives outside the
  repo, so a fresh clone or a misconfigured machine would commit real values
  silently.

### 4. Guard rails

- **pre-commit** (`.pre-commit-config.yaml`), installed per clone with
  `pre-commit install`:
  - **gitleaks** for secret patterns;
  - **`scripts/check-site-values.sh`**, which blocks any staged file that
    contains a value from `site.env`. It reports the file and key, never
    the value.
- **GitHub:** secret scanning and push protection switched on.
- **Before the first commit:** run `scripts/check-site-values.sh --all` and
  `gitleaks dir .`, and read the tree once. Because history starts clean, a
  private first push adds only a review window: something found while the
  repo is private can still be fixed by recreating it. After that review,
  the repo is made public.
- **Token rotation:** the `terraform@pve` token is rotated regardless,
  since it has been in the Nextcloud sync (ADR-0008 open item).

### 5. Where each kind of information lives (replaces the README's old rules)

| What | Master | Mirror |
|---|---|---|
| ADRs, README, `infra/`, `scripts/` | **Git repo** | ADRs and README in the Claude Project docs, identical text |
| Site values, tfvars, tfstate, device backups | `site.env` and local files in the clone | `LOCAL_BACKUP_DIR` in Nextcloud; tokens in the password manager |
| Manuals, archive | Nextcloud `NAS/reference/`, `NAS/_archive/` | — |
| Current status, loose ends | Project memory | — |

- A decision made in chat is written as an ADR in the repo, and the same
  text goes to the Project docs.
- The Project copies carry the same placeholders as the repo. The real
  values are in `site.env`.
- The Nextcloud `NAS/adr/`, `NAS/infra/` and `NAS/README.md` are retired
  once the repo is pushed.

## Alternatives considered

- **Private repo only.** No redaction needed, but nothing to share, and a
  private repo tends to collect secrets "because it's private".
- **Keep the Nextcloud folder as the only copy.** No history or diffs.
- **Repo inside the Nextcloud folder.** Sync and `.git` don't mix well
  (see §1).
- **Encrypted secrets in the repo (SOPS/age).** Workable, but it puts
  ciphertext of real credentials in a public repo, adds a key to manage,
  and isn't needed: secrets already live outside files.
- **Clean/smudge filters for site values.** See §3.

## Consequences

- **Helm commands change:** run `scripts/render.sh` first, then point
  `-f` at `.rendered/…`.
- **Local-only files have no history.** After `terraform apply`, changing
  `site.env`, or taking a new Z-Stick backup, run `scripts/backup-local.sh`.
- **Placeholders in the docs** read slightly less directly than real names;
  `site.env` is the lookup table.
- **Mirroring changes direction:** the Project docs mirror the repo, where
  the Project used to be the master.
- **The repo is public,** so new identifying values must go into
  `site.env` first. The pre-commit hook only knows values that are listed
  there.

## Update 2026-10-24: pushed and public

- **Repo:** `github.com/LittleAndi/homelab`, cloned in WSL at
  `~/src/homelab`. The first commit is the cleaned tree from §1.
- **Checks before going public:**
  - `git ls-files` shows none of the local-only files from §2;
  - `scripts/check-site-values.sh --all` passes;
  - gitleaks found no leaks.
- **Order of operations:**
  - pushed as private, then switched to public with
    `gh api -X PATCH repos/LittleAndi/homelab -f visibility=public`;
  - secret scanning and push protection were switched on right after.
    GitHub refuses both on a private repo on a free account (HTTP 422).
- **Licence:** MIT, covering both the code and the docs (`LICENSE`).
- **Project docs:** ADR-0009 to ADR-0013 in the Project now carry the same
  redacted text as the repo.
- **`gh` upgraded** from Ubuntu's 2.45.0 to GitHub's own apt repository
  (2.103.2). The old version lacked
  `gh repo edit --accept-visibility-change-consequences`.

## Update 2026-10-24: working model

This replaces the "Mirror" column of §5 for ADRs and the README.

- **Changes:** made with Claude Code in WSL (`~/src/homelab`).
  - From there it can reach the cluster (`kubectl`/`helm` through the
    Tailscale operator), the host (`ssh root@pve`) and the local
    `site.env`, so it can edit, apply, verify and commit in one session.
  - `CLAUDE.md` holds the rules: ADRs for decisions, placeholders only,
    render before Helm, pre-commit never bypassed, ask before destructive
    operations.
- **Design discussions:** stay in the claude.ai Project.
  - Instead of copying ADRs into the Project by hand, the repo is connected
    as Project knowledge through the GitHub integration, with only `adr/`
    and `README.md` selected.
  - The sync is manual: press Sync after pushing.
  - The hand-uploaded Project docs are removed once the integration is
    connected, so there's one copy.
- **Hand-offs:** a decision reached in a Project chat is handed to Claude
  Code to write up and commit. The Project never holds a version the repo
  doesn't have.

## Open items

- Connect the repo to the Project (GitHub integration, `adr/` + `README.md`),
  then delete the hand-uploaded Project docs.
- Rotate the `terraform@pve` token and update `terraform.tfvars`, or switch
  to `TF_VAR_proxmox_api_token` only (ADR-0008).
- ~~Create the GitHub repo, switch on secret scanning and push protection,
  first push, then make it public.~~ Done 2026-10-24.
- ~~Choose a licence.~~ MIT, 2026-10-24.
- Copy the local-only files into the clone, run `scripts/backup-local.sh`
  once, then retire `NAS/adr`, `NAS/infra` and `NAS/README.md` in Nextcloud.
- ~~Mirror the redacted ADRs and README to the Project docs.~~ Done 2026-10-24.
