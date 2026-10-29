#!/bin/bash
# Run on the Proxmox host as root. Contains site placeholders: run the
# rendered copy (scripts/render.sh, then .rendered/<this path>).
#
# Creates (or updates) the rclone remote for the second old storage account
# (ADR-0017 §7): plain azureblob, not encrypted, several containers, most
# blobs Cool (some Cold). Reading Cool/Cold costs a retrieval fee per GB on
# top of egress, so plan downloads with ADR-0017 §7.
#   - Paste the portal's "Blob service SAS URL" from an *account* SAS
#     (Storage account -> Shared access signature: service Blob, resource
#     types Service + Container + Object -- Service is needed to list the
#     containers --, Read + List (+ Delete when pruning), HTTPS only, short
#     expiry). It isn't echoed or written to shell history.
#   - The test lists the containers only (no data download).
set -euo pipefail

R="${DOCS_AZURE_REMOTE}"

read -rsp 'Blob service SAS URL: ' u; echo
case "$u" in https://*'?'*sig=*) ;; *) echo "That doesn't look like a SAS URL." >&2; exit 1;; esac
if rclone listremotes | grep -qx "$R:"; then
  rclone config update "$R" sas_url "$u" >/dev/null
else
  rclone config create "$R" azureblob sas_url "$u" >/dev/null
fi
unset u
echo "Remote $R: ready. Containers:"
rclone lsd "$R:"
