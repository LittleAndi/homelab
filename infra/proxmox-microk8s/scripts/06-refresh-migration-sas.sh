#!/bin/bash
# Run on the Proxmox host as root. Contains site placeholders: run the
# rendered copy (scripts/render.sh, then .rendered/<this path>).
#
# Sets a new SAS on the old migration container's rclone remote (ADR-0017 §3,
# §7) and lists the top level through the crypt remote as a test.
#   - Paste the portal's "Blob SAS URL" (Read + Delete + List, HTTPS only,
#     short expiry). It isn't echoed or written to shell history, and
#     rclone's output is suppressed so it doesn't print the URL back.
#   - Listing only reads blob names: no data download beyond the list
#     responses (ADR-0017 §7 egress budget).
set -euo pipefail

AZ="${AZURE_REMOTE}"
CRYPT="${CRYPT_REMOTE}"

rclone listremotes | grep -qx "$AZ:" || { echo "rclone remote $AZ: not configured." >&2; exit 1; }

read -rsp 'Blob SAS URL: ' u; echo
case "$u" in https://*'?'*sig=*) ;; *) echo "That doesn't look like a SAS URL." >&2; exit 1;; esac
rclone config update "$AZ" sas_url "$u" >/dev/null
unset u
echo "SAS updated. Top-level folders:"
rclone lsd "$CRYPT:" --max-depth 1
