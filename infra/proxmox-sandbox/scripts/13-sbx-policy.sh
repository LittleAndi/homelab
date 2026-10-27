#!/bin/bash
# Run INSIDE the sandbox VM as the `sandbox` user (not root), after
# `sbx login`. Safe to re-run:
#   ssh sandbox@192.168.1.26 'bash -s' < infra/proxmox-sandbox/scripts/13-sbx-policy.sh
#
# Network policy for Docker Sandboxes (ADR-0016): the Balanced default
# (deny by default, common dev sites allowed) minus
#   - storage anyone can upload to (an exfiltration channel), and
#   - other vendors' agent and SaaS endpoints (only Claude is used).
# If a tool breaks, `sbx policy log` shows the blocked host; allow that one
# host (`sbx policy allow network <host>:443`), not the wildcard.
set -uo pipefail

[ "$(id -un)" = sandbox ] || { echo "Run as the sandbox user, not root." >&2; exit 1; }

REMOVE=(
  # open object storage
  '**.amazonaws.com' '**.googleapis.com' '**.blob.core.windows.net'
  '**.public.blob.vercel-storage.com' '**.googleusercontent.com'
  # other agents
  '**.openai.com' chatgpt.com '**.chatgpt.com' '**.oaistatic.com'
  '**.oaiusercontent.com' cdn.openaimerge.com cursor.com '**.cursor.sh'
  gemini.google.com generativelanguage.googleapis.com play.googleapis.com
  api.perplexity.ai models.dev factory.ai '**.factory.ai' api.workos.com
  # unused SaaS
  supabase.com clerk.com figma.com app.daytona.io vercel.com
)

sbx policy ls --json 2>/dev/null | grep -q '"default-ai-services"' || sbx policy init balanced

for h in "${REMOVE[@]}"; do
  sbx policy rm network -f --resource "${h}:443" >/dev/null 2>&1 && echo "removed  $h" || echo "absent   $h"
done

mkdir -p ~/work
sbx policy ls
