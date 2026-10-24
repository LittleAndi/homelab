# Shared helpers for the site.env scripts (ADR-0014). Sourced, not run.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keys defined in site.env.example, in order.
site_keys() {
  grep -oE '^[A-Z][A-Z0-9_]*=' "$REPO_ROOT/site.env.example" | tr -d '='
}

# Load site.env into the environment; fail if it's missing or a key is empty.
load_site_env() {
  local f="$REPO_ROOT/site.env" k missing=0
  [[ -f "$f" ]] || { echo "site.env not found: cp site.env.example site.env and fill it in." >&2; return 1; }
  set -a; # shellcheck disable=SC1090
  . "$f"; set +a
  for k in $(site_keys); do
    [[ -n "${!k:-}" ]] || { echo "site.env: $k is empty" >&2; missing=1; }
  done
  return $missing
}
