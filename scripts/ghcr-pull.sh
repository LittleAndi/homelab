#!/usr/bin/env bash
# Write the GHCR read token (classic PAT, read:packages only) as pull secret
# `ghcr-pull` into every namespace labelled homelab/ghcr-pull=true, and as
# `ghcr-flux` into flux-system once Flux is installed (ADR-0018 §4, Update
# 2026-11-21). Run after creating or rotating the token.
#
#   scripts/ghcr-pull.sh            # asks for the token (not echoed)
#   GHCR_TOKEN=$(bw get password …) scripts/ghcr-pull.sh
#   scripts/ghcr-pull.sh --list     # show target namespaces, change nothing
#
# Public images need no pull secret: label only namespaces of private apps.
set -euo pipefail

GHCR_USER="${GHCR_USER:-LittleAndi}"
LABEL="homelab/ghcr-pull=true"

mapfile -t namespaces < <(kubectl get ns -l "$LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
flux=""
kubectl get ns flux-system >/dev/null 2>&1 && flux=flux-system

# Context name without its domain: the full name contains the tailnet.
echo "context:   $(kubectl config current-context | cut -d. -f1)"
echo "ghcr-pull: ${namespaces[*]:-(no namespace labelled $LABEL)}"
echo "ghcr-flux: ${flux:-(flux-system not there yet)}"
[[ "${1:-}" == "--list" ]] && exit 0
if [[ ${#namespaces[@]} -eq 0 && -z "$flux" ]]; then
  echo "nothing to do" >&2; exit 1
fi

if [[ -z "${GHCR_TOKEN:-}" ]]; then
  read -rsp "GHCR token for $GHCR_USER: " GHCR_TOKEN; echo
fi

# Check the token before writing it anywhere. curl reads it from stdin, so
# it never shows up in the process list.
code=$(printf 'user = "%s:%s"\n' "$GHCR_USER" "$GHCR_TOKEN" | curl -s -K - -o /dev/null \
  -w '%{http_code}' 'https://api.github.com/user/packages?package_type=container&per_page=1')
if [[ "$code" != 200 ]]; then
  echo "token rejected by GitHub (HTTP $code): expired, revoked or missing read:packages" >&2
  exit 1
fi

read -rp "Write the secret to the namespaces above? [y/N] " ok
[[ "$ok" == [yY] ]] || exit 1

# Built here and piped to kubectl, so the token isn't a command-line argument.
auth=$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | base64 -w0)
config=$(printf '{"auths":{"ghcr.io":{"username":"%s","auth":"%s"}}}' "$GHCR_USER" "$auth" | base64 -w0)
apply_secret() { # name namespace
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $1
  namespace: $2
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $config
EOF
}
for ns in "${namespaces[@]}"; do apply_secret ghcr-pull "$ns"; done
[[ -n "$flux" ]] && apply_secret ghcr-flux "$flux"
unset GHCR_TOKEN auth config
echo "done; record the token's expiry date in the password manager"
