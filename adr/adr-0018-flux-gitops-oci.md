# ADR-0018: GitOps Deploys with Flux from OCI Artifacts

**Status:** Accepted 2026-11-21 — not deployed yet
**Date:** 2026-11-21

## Context

Apps built on GitHub should reach the MicroK8s cluster (ADR-0008) without a
manual step. Today:

- `stockstalker` (private repo `stock-stalker`) builds images to GHCR on
  every push to `main` (`:main` and `:sha-<short>`), but deploying is a
  hand-run `kubectl apply -k deploy/k8s` plus `rollout restart`. Images
  track `:main` with `imagePullPolicy: Always`, so a pod restart can change
  the version unannounced. The `batch` CronJob has been in
  `ImagePullBackOff` since 2026-11-18 without anyone noticing.
- Nextcloud (ADR-0010), monitoring (ADR-0013), the Tailscale operator and
  the NFS provisioner are Helm releases installed by hand (CLAUDE.md rule 3).
- The API server is reachable only through the Tailscale operator's proxy
  (ADR-0010 update 2026-09-25); nothing in the cluster is open inbound.
- The cluster has 15 GB; on 2026-11-20 each node used 47–52%
  (1.35–1.52 GiB of ~2.9).
- This repo is public (ADR-0014); site values are `${KEY}` placeholders.

Wanted: a push to an app's `main` deploys automatically; infrastructure
stays in this repo, app-specific manifests stay with the app; the cluster
pulls OCI artifacts rather than needing access to GitHub repos.

## Decision

### 1. Flux, pull-based

- **Flux v2.10.1**, controllers **source-controller,
  kustomize-controller, notification-controller** only. No
  helm-controller (the Helm releases stay manual for now, §7) and no
  image-reflector/automation controllers (CI pins the tag, §2).
- Installed once from WSL with the pinned `flux` CLI (`flux install
  --components=…`); the same manifests are exported to
  `clusters/homelab/flux-system/` so Flux manages its own upgrades from
  then on. **Not `flux bootstrap github`**: that needs a deploy key and
  write access to the repo.
- The cluster only makes outbound requests (to GHCR). No inbound path, no
  cluster credentials in GitHub.

### 2. OCI artifacts in GHCR, no Git access from the cluster

Every Flux source is an `OCIRepository`. GitHub Actions packages the
manifests with `flux push artifact` and the cluster never clones a repo.

| Artifact | Built by | Content | Visibility |
|---|---|---|---|
| `ghcr.io/littleandi/homelab-flux` | this repo, on push to `main` touching `clusters/**` | `clusters/homelab/` | public (repo is public) |
| `ghcr.io/littleandi/<app>-deploy` | the app repo's image workflow, after the images | `deploy/k8s/` with image tags set to `sha-<short>` | same as the app repo |

- Each push is tagged `sha-<short>` (immutable) and then `main` (moving).
  `OCIRepository` follows `ref.tag: main` every 2 minutes and reconciles
  when the digest changes. **That is the auto-deploy on `main`.**
- The app workflow runs `kustomize edit set image …:sha-<short>` in its
  checkout before pushing, so the artifact pins exact images. The app repo
  is never written back to, and `imagePullPolicy: Always` / `:main` go
  away.
- **Signed and verified.** Workflows sign with cosign keyless
  (`id-token: write`). Each `OCIRepository` has `verify.provider: cosign`
  with `matchOIDCIdentity`: issuer `https://token.actions.githubusercontent.com`,
  subject that repo's workflow on `refs/heads/main`. A leaked GHCR write
  token alone can't deploy, and a branch build can't either.

### 3. Split: infrastructure here, close-to-app in the app repo

**This repo, `clusters/homelab/`:**

- `flux-system/`: Flux components, the root `OCIRepository` +
  `Kustomization` for `homelab-flux`, notifications (§5).
- `infra/`: Namespaces, and per app a `ServiceAccount` `flux` in the app
  namespace bound to the built-in `admin` ClusterRole by a RoleBinding.
- `tenants/<app>.yaml`: the app's `OCIRepository` and `Kustomization`.

**App repo, `deploy/k8s/`:** Deployments, StatefulSets, Services,
CronJobs, PVCs, ConfigMap generators, Ingress. **Not** Namespaces,
Secrets or cluster-scoped objects.

Tenant `Kustomization`:

- `serviceAccountName: flux` and `targetNamespace: <app>`. With only
  `admin` in its own namespace, an app artifact can't touch other
  namespaces or cluster-scoped objects, whatever it contains.
- `prune: true`, `wait: true`, `timeout: 5m`, `interval: 10m` (drift
  correction).
- **Objects holding data** (PVCs, the Postgres StatefulSet) are annotated
  `kustomize.toolkit.fluxcd.io/prune: disabled` in the app repo, so a bad
  or empty artifact can't delete them. (`local-path-retain` and
  `nfs-client` `archiveOnDelete` are the second layer.)

### 4. Site values and secrets

- **Homelab `Kustomization`s** use `postBuild.substituteFrom` ConfigMap
  `site-values` in `flux-system`, so files in `clusters/` keep `${KEY}`
  placeholders exactly as elsewhere (ADR-0014). The ConfigMap is created
  from the "rendered into config" keys of `site.env` by a new
  `scripts/sync-site-values.sh` (strips the quotes `kubectl
  --from-env-file` would keep). Re-run it whenever `site.env` changes.
- **Tenant `Kustomization`s get no `postBuild`.** Flux replaces undefined
  `${var}` with an empty string, which would break shell scripts in app
  manifests (e.g. stockstalker's `postgres-backup` uses `${out}`).
- **Secrets stay out of band**: `kubectl create secret` with `read -rs`,
  or the app's own script (`create-secrets.sh`). Flux never holds or
  generates a secret.
- **GHCR read access:** a classic PAT with `read:packages` (GHCR doesn't
  take fine-grained tokens), as docker-registry secret `ghcr-flux` in
  `flux-system` for the private `OCIRepository`s. Image pulls keep the
  per-namespace `ghcr-pull` secret. Expiry date in the password manager.

### 5. Failed reconciliations go to Discord

notification-controller `Provider` type `discord` (webhook URL from a
Secret created on the command line) and an `Alert` on severity `error`
for all `Kustomization`s and `OCIRepository`s. Same channel as ADR-0015,
so a failed deploy doesn't sit silent like the `batch` pull did.

### 6. Rollback and manual work

- Normal: revert in the app repo; the new artifact deploys.
- Fast: `flux tag artifact oci://…-deploy:sha-<old> --tag main`; the next
  push to `main` moves the tag forward again.
- Hands-on work: `flux suspend kustomization <app>`, then `resume`.
  Without suspending, Flux reverts `kubectl` edits to managed objects
  within `interval`.

### 7. Rollout

1. Install Flux, add `clusters/homelab/`, the homelab artifact workflow,
   `site-values`, `ghcr-flux`, Discord; apply the root sync once by hand.
2. `stockstalker` first: the Namespace moves here (out of the app's
   kustomization), the deploy job and prune annotations go into the app
   repo. Flux adopts the existing objects by server-side apply; the
   ConfigMap hash is unchanged, the switch to `sha-` tags rolls `api` and
   `host` once.
3. Further apps follow the same pattern (`tenants/<app>.yaml` + namespace).
4. Nextcloud, monitoring, the operator and the NFS provisioner **stay
   manual Helm** (CLAUDE.md rule 3). Moving them to `HelmRelease`s
   (adds helm-controller) is a later Update to this ADR.

## Alternatives considered

- **Push from GitHub Actions** (`tailscale/github-action`, `tag:ci`,
  `kubectl` through the operator proxy): quick, but puts a tailnet OAuth
  client and broad cluster access in GitHub, and corrects no drift.
- **Argo CD:** 2–3× the memory of Flux; its UI isn't needed here.
- **Flux `GitRepository`:** needs a deploy key per private app repo. The
  public homelab repo would work without credentials, but one source type
  for everything is simpler, and the artifact is the reviewed, signed
  output of CI.
- **Flux image automation:** writes tag bumps back to git and needs two
  more controllers; pinning the tag inside the artifact does the same.
- **All manifests in this repo:** every app change would need a second
  PR here.

## Consequences

- A merge to an app's `main` is live within minutes. Objects managed by
  Flux are changed through git, not `kubectl apply`.
- GitHub Actions and GHCR are in the deploy path. If either is down,
  nothing new deploys; the cluster keeps running what it last applied.
- ~150–250 MiB more on the cluster for three controllers.
- A PAT to renew, plus the Discord webhook and `site-values` to keep in
  sync with `site.env`.
- stockstalker's `docs/operations/kubernetes.md` (manual apply) needs
  updating when it moves.

## Verification (after rollout)

- `flux check`; `flux get sources oci -A` and `flux get kustomizations -A`
  all Ready, showing the signed `sha-` revision.
- A trivial change pushed to an app's `main` is running within ~5 minutes.
- An unsigned artifact pushed by hand to `:main` is rejected (verification
  failure, alert in Discord).
- The tenant's service account can't create a cluster-scoped object or
  anything in another namespace (`kubectl auth can-i --as
  system:serviceaccount:<app>:flux …`).
- A `kubectl` edit to a managed Deployment is reverted.

## Update 2026-11-21: pull secrets — public images where possible, one script for the rest

Pull secrets are per namespace, so with more apps a token rotation means
updating every copy; that is how the `batch` outage happened (below).

- **Public app repo → public GHCR images**, no pull secret in its
  namespace.
- **Private apps:** their namespace carries the label
  `homelab/ghcr-pull=true` (set in `clusters/homelab/infra/` once Flux
  runs; by hand with `kubectl label` until then). `scripts/ghcr-pull.sh`
  asks for the token once (`read -rs`, or `GHCR_TOKEN` from the password
  manager CLI), checks it against the GitHub API, then writes `ghcr-pull`
  into every labelled namespace and `ghcr-flux` into `flux-system`. One
  classic PAT (`read:packages` only) serves both. Rotation is one command;
  the token is never a command-line argument.
- **Rejected:** credentials in containerd on all nodes (token on 5 disks,
  every namespace can pull private images, unclear support in
  containerd 2.x); Reflector/Kyverno/External Secrets (another controller
  for one namespace so far); the `gh` CLI's own token (`repo` and more
  scopes, stored in the cluster). GitHub has no API to create PATs, so
  creating the token stays a manual step in the web UI.

**Incident, 2026-11-18 → 2026-11-20:** `stockstalker`'s `ghcr-pull` PAT
(created 2026-10-18, 30 days) expired 2026-11-17; GHCR answered
`403 DENIED`. The `batch` CronJob sat in `ImagePullBackOff` from the
2026-11-18 22:00 run and `concurrencyPolicy` held back the next two
nights. `api` and `host` kept running from cached images. New PAT applied
2026-11-20 23:28 UTC; the stuck run completed 23:31 UTC (31/31 tickers).
The 2026-11-19 and -20 runs were not backfilled. Expiry of the new token is
in the password manager; §5's Discord alert would have caught this.
