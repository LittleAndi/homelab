#!/usr/bin/env bash
# Write the "rendered into config" keys of site.env into ConfigMap
# flux-system/site-values, which fills ${KEY} placeholders in clusters/homelab/
# (ADR-0018 §4). Run at Flux install and after every site.env change.
# Values are never printed, and never passed as command-line arguments.
#
#   scripts/sync-site-values.sh          # keys only, then asks before writing
set -euo pipefail
. "$(dirname "$0")/lib-site.sh"
load_site_env

# Keys between "--- rendered into config" and the next "# ---" header.
mapfile -t keys < <(awk '/^# --- rendered into config/{on=1; next} /^# ---/{on=0} on' \
  "$REPO_ROOT/site.env.example" | grep -oE '^[A-Z][A-Z0-9_]*=' | tr -d '=')
[[ ${#keys[@]} -gt 0 ]] || { echo "no keys found in site.env.example" >&2; exit 1; }

kubectl get ns flux-system >/dev/null 2>&1 || { echo "namespace flux-system not found (install Flux first)" >&2; exit 1; }
echo "context: $(kubectl config current-context | cut -d. -f1)"
echo "keys:    ${keys[*]}"
read -rp "Write these to flux-system/site-values? [y/N] " ok
[[ "$ok" == [yY] ]] || exit 1

# KEY=value lines (unquoted; site.env quoting is shell syntax) via a pipe.
kubectl -n flux-system create configmap site-values \
  --from-env-file=<(for k in "${keys[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done) \
  --dry-run=client -o yaml | kubectl apply -f -
