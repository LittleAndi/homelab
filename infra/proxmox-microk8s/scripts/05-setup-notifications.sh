#!/bin/bash
# Run on the Proxmox host as root, interactively (ssh -t). Safe to re-run.
#
# Host notifications to Discord (ADR-0015):
#   - Proxmox notification webhook target "discord". The webhook's
#     <id>/<token> part is stored as a target secret (/etc/pve/priv/), asked
#     for on the first run and never echoed; the url field has to start with
#     https://, so it can't be a secret by itself. To replace it: --reset-url.
#   - Matcher "to-discord": every notification goes there, including mail to
#     root that proxmox-mail-forward turns into notifications (smartd, zed).
#   - notify-failure@.service: mails root when a backup unit fails, so those
#     reach Discord the same way (OnFailure= drop-ins below).
#   - notify-success@.service: the same for a successful run, only for the
#     daily Azure sync (OnSuccess=; the hourly units would flood the channel).
#     A missing morning message means the sync didn't run.
set -euo pipefail

TARGET="discord"
MATCHER="to-discord"
UNITS="azure-sync-k8s syncoid-k8s syncoid-ha-backups sanoid"
SUCCESS_UNITS="azure-sync-k8s"

die() { echo "$*" >&2; exit 1; }
b64() { printf '%s' "$1" | base64 -w0; }

[ "$(id -u)" = 0 ] || die "Run as root on the Proxmox host."
grep -q proxmox-mail-forward /root/.forward 2>/dev/null \
  || die "/root/.forward doesn't pipe to proxmox-mail-forward: root mail won't become notifications."

# Discord embed: description holds up to 4096 characters (plain content: 2000).
URL_BASE='https://discord.com/api/webhooks/'
BODY='{"username":"pve","embeds":[{"title":"[{{ severity }}] {{ escape title }}","description":"{{ escape message }}"}]}'

# --- Webhook target -------------------------------------------------------------
if pvesh get "/cluster/notifications/endpoints/webhook/$TARGET" >/dev/null 2>&1 && [ "${1:-}" != "--reset-url" ]; then
  pvesh set "/cluster/notifications/endpoints/webhook/$TARGET" \
    --method post --url "${URL_BASE}{{ secrets.hook }}" \
    --header "name=Content-Type,value=$(b64 application/json)" \
    --body "$(b64 "$BODY")"
  echo "Target $TARGET updated (URL secret left as it was)."
else
  [ -t 0 ] || die "Needs a terminal for the webhook URL: ssh -t root@pve …"
  read -rs -p "Discord webhook URL: " URL; echo
  [[ "$URL" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/([0-9]+/[A-Za-z0-9_-]+)/?$ ]] \
    || die "That doesn't look like a Discord webhook URL."
  HOOK="${BASH_REMATCH[2]}"; unset URL
  pvesh delete "/cluster/notifications/endpoints/webhook/$TARGET" >/dev/null 2>&1 || true
  pvesh create /cluster/notifications/endpoints/webhook --name "$TARGET" \
    --comment "Discord channel (ADR-0015)" \
    --method post --url "${URL_BASE}{{ secrets.hook }}" \
    --header "name=Content-Type,value=$(b64 application/json)" \
    --body "$(b64 "$BODY")" \
    --secret "name=hook,value=$(b64 "$HOOK")"
  unset HOOK
  echo "Target $TARGET created."
fi

# --- Matcher --------------------------------------------------------------------
if pvesh get "/cluster/notifications/matchers/$MATCHER" >/dev/null 2>&1; then
  pvesh set "/cluster/notifications/matchers/$MATCHER" --target "$TARGET" --mode all
else
  pvesh create /cluster/notifications/matchers --name "$MATCHER" --target "$TARGET" \
    --mode all --comment "All notifications to Discord (ADR-0015)"
fi

# --- Failure / success notifications for backup units ---------------------------
cat > /usr/local/sbin/notify-unit <<'SCRIPT'
#!/bin/bash
# Managed by proxmox-microk8s/scripts/05-setup-notifications.sh (ADR-0015).
# notify-unit <unit> failed|succeeded: mails root about a finished unit;
# proxmox-mail-forward passes it on to Discord.
unit="$1" result="${2:-failed}"
inv="$(systemctl show -p InvocationID --value "$unit")"
start="$(systemctl show -p ExecMainStartTimestampMonotonic --value "$unit")"
stop="$(systemctl show -p ExecMainExitTimestampMonotonic --value "$unit")"
took=""
if [ "${start:-0}" -gt 0 ] && [ "${stop:-0}" -gt "$start" ]; then
  s=$(( (stop - start) / 1000000 ))
  took=" after $((s / 3600))h$(( s % 3600 / 60 ))m$((s % 60))s"
fi
{
  echo "Subject: ${unit%.service} ${result} on $(hostname)${took}"
  echo
  if [ "$result" = succeeded ] && [ -n "$inv" ]; then
    # This run's own output only, without systemd's start/stop lines.
    journalctl -q --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$inv" _TRANSPORT=stdout \
      | tail -n 8 | cut -c1-200
  else
    systemctl status --no-pager --lines=25 "$unit" 2>&1 | cut -c1-200
  fi
} | /usr/sbin/sendmail root
SCRIPT
chmod 0755 /usr/local/sbin/notify-unit
rm -f /usr/local/sbin/notify-failure   # replaced by notify-unit

for r in failure success; do
  [ "$r" = failure ] && word=failed || word=succeeded
  cat > "/etc/systemd/system/notify-$r@.service" <<UNIT
[Unit]
Description=Notify that %i ${word} (ADR-0015)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/notify-unit %i ${word}
UNIT
done

for u in $UNITS; do
  systemctl cat "$u.service" >/dev/null 2>&1 || { echo "skip $u.service (not installed)"; continue; }
  mkdir -p "/etc/systemd/system/$u.service.d"
  {
    echo "# Managed by 05-setup-notifications.sh (ADR-0015)"
    echo "[Unit]"
    echo "OnFailure=notify-failure@%n.service"
    if [[ " $SUCCESS_UNITS " == *" $u "* ]]; then echo "OnSuccess=notify-success@%n.service"; fi
  } > "/etc/systemd/system/$u.service.d/notify-failure.conf"
  echo "Notifications set for $u.service$([[ " $SUCCESS_UNITS " == *" $u "* ]] && echo " (failure + success)")"
done
systemctl daemon-reload

# --- Test -------------------------------------------------------------------------
pvesh create "/cluster/notifications/targets/$TARGET/test" && echo "Test notification sent: check Discord."
