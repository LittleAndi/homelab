#!/usr/bin/env bash
# Render tracked files that contain ${KEY} placeholders (keys from
# site.env.example) into .rendered/<same path>, with values from site.env.
# Only those keys are substituted; any other $VAR in a file is left alone.
#
#   scripts/render.sh                 # render everything that has placeholders
#   helm upgrade ... -f .rendered/infra/proxmox-microk8s/monitoring/values.yaml
set -euo pipefail
. "$(dirname "$0")/lib-site.sh"
load_site_env
cd "$REPO_ROOT"

keys=$(site_keys)
pattern="\\\$\\{($(echo $keys | tr ' ' '|'))\\}"

if git rev-parse --is-inside-work-tree &>/dev/null; then
  files=$(git ls-files --cached --others --exclude-standard | grep -v '^site\.env\.example$' || true)
else
  files=$(find . -type f -not -path './.git/*' -not -path './.rendered/*' -not -name site.env.example | sed 's#^\./##')
fi

rm -rf .rendered
count=0
for f in $files; do
  grep -qE "$pattern" "$f" 2>/dev/null || continue
  mkdir -p ".rendered/$(dirname "$f")"
  # Substitute only the site keys (no envsubst dependency).
  KEYS="$keys" python3 -c '
import os, re, sys
keys = os.environ["KEYS"].split()
pat = re.compile(r"\$\{(" + "|".join(map(re.escape, keys)) + r")\}")
sys.stdout.write(pat.sub(lambda m: os.environ[m.group(1)], sys.stdin.read()))
' < "$f" > ".rendered/$f"
  echo "rendered  .rendered/$f"
  count=$((count + 1))
done
echo "$count file(s) rendered."
