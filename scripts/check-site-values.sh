#!/usr/bin/env bash
# pre-commit hook (ADR-0014): refuse to commit any file containing a real
# value from site.env. Prints file and key, never the value.
#   scripts/check-site-values.sh FILE...    (pre-commit passes staged files)
#   scripts/check-site-values.sh --all      (scan the whole working tree)
set -uo pipefail
. "$(dirname "$0")/lib-site.sh"
if ! load_site_env 2>/dev/null; then
  echo "check-site-values: site.env missing or incomplete; skipping (fill it in to enable this check)." >&2
  exit 0
fi
cd "$REPO_ROOT"

if [[ "${1:-}" == "--all" ]]; then
  mapfile -t files < <(git ls-files --cached --others --exclude-standard 2>/dev/null \
    || find . -type f -not -path './.git/*' | sed 's#^\./##')
else
  files=("$@")
fi

fail=0
for f in "${files[@]}"; do
  [[ -f "$f" && "$f" != "site.env" ]] || continue
  for k in $(site_keys); do
    v="${!k}"
    [[ ${#v} -ge 4 ]] || continue
    if grep -Fqwi -- "$v" "$f"; then
      echo "BLOCKED: $f contains the value of $k (use its placeholder; see site.env.example)"
      fail=1
    fi
  done
done
exit $fail
