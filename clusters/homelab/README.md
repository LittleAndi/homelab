# clusters/homelab — Flux (ADR-0018)

Flux **v2.10.1** (source, kustomize, notification controllers) applies this
tree from the signed OCI artifact `ghcr.io/littleandi/homelab-flux:main`,
pushed by `.github/workflows/flux-artifact.yml` on every merge to `main`
that touches `clusters/`.

| Path | Flux Kustomization | Contents |
|---|---|---|
| `flux-system/` | `flux-system` | Flux components (generated) + root sync |
| `infra/` | `infra` (`${KEY}` from `site-values`) | Namespaces, tenant service accounts, Discord alerts |
| `tenants/` (later) | `tenants` | per app: `OCIRepository` + `Kustomization` of its own artifact |

Objects managed here are changed through git. For hands-on work:
`flux suspend kustomization <name>`, then `flux resume kustomization <name>`.

## Install (once)

1. Flux CLI v2.10.1 from the GitHub release, checksum checked against
   `flux_2.10.1_checksums.txt`. `flux check --pre`.
2. Merge to `main`; the workflow pushes `homelab-flux:sha-<short>`, signs it
   and tags `main`. Check the run's summary.
3. Components and CRDs:
   `kubectl apply -f clusters/homelab/flux-system/gotk-components.yaml`,
   then `flux check`.
4. Secrets and values (never in files):
   - `scripts/ghcr-pull.sh` → `ghcr-flux` in `flux-system` (and `ghcr-pull`
     in labelled namespaces);
   - `scripts/sync-site-values.sh` → ConfigMap `site-values`;
   - Discord webhook, key `address`:
     ```bash
     read -rs URL; kubectl -n flux-system create secret generic discord-webhook \
       --from-file=address=<(printf %s "$URL"); unset URL
     ```
5. Root sync: `kubectl apply -f clusters/homelab/flux-system/gotk-sync.yaml`.
   From here on Flux manages itself.
6. Verify (ADR-0018): `flux get sources oci -A` and `flux get
   kustomizations -A` Ready on the `sha-` revision with a verified signature;
   `kubectl get ns stockstalker --show-labels`.

## Upgrade Flux

Regenerate with the new pinned CLI (command in
`flux-system/kustomization.yaml`), bump `version:` in the workflow, add an
ADR-0018 Update, merge.
