# ADR-0015: Host Notifications to Discord through the Proxmox Notification System

**Status:** Accepted 2026-10-26 — deployed 2026-10-26
**Date:** 2026-10-26

## Context

Checked the live host on 2026-10-26 (Proxmox VE 9.2.20):

- smartd runs with `DEVICESCAN … -m root -M exec smartd-runner`, and zed has
  `ZED_EMAIL_ADDR="root"`. Both send mail to `root`.
- `/root/.forward` pipes root's mail into `proxmox-mail-forward`, which turns
  it into Proxmox notifications. The only matcher was the built-in
  `default-matcher` → `mail-to-root`, which mails root@pam's address.
- **None of that mail ever arrived.** `/etc/aliases.db` didn't exist, so
  Postfix deferred all local mail to root ("alias database unavailable").
  Past that, `mail-to-root` sends straight to the recipient's MX on port 25
  (no `relayhost`), and the ISP blocks outbound port 25.
- The new Azure sync (ADR-0011 §3) and the syncoid/sanoid units had no
  failure notification at all.

ADR-0013 (monitoring) chose "no alerts for now". That is about Prometheus
metrics and dashboards; this ADR covers events the host already reports
(disk failures, pool faults, failed backup units).

## Decision

### 1. One channel: a Discord webhook as a Proxmox notification target

- Webhook target `discord` (`pvesh … /endpoints/webhook`), method POST,
  URL `https://discord.com/api/webhooks/{{ secrets.hook }}`. The
  `<id>/<token>` part is a target secret, stored in `/etc/pve/priv/`; the
  `url` field must start with `https://`, so the whole URL can't be a
  secret. The URL isn't in the repo, in shell history or in chat.
- Body: a Discord embed, `[{{ severity }}] {{ escape title }}` as title and
  `{{ escape message }}` as description (embed limit 4096 characters,
  versus 2000 for plain content).
- Matcher `to-discord`, mode `all`, no filter: every notification goes to
  Discord (backup jobs, package updates, fencing, forwarded mail).
- Forwarded mail has no severity and shows as `[unknown]`.

### 2. Everything else feeds in as mail to root

- smartd and zed keep mailing root; `proxmox-mail-forward` passes it on.
- `notify-failure@.service` (`/usr/local/sbin/notify-failure`) mails root
  the `systemctl status` of a failed unit. `OnFailure=` drop-ins hook it to
  `azure-sync-k8s`, `syncoid-k8s`, `syncoid-ha-backups` and `sanoid`.
- `/etc/aliases.db` created with `newaliases` (plus `postfix reload`), so
  local mail to root is delivered again.

Script: `infra/proxmox-microk8s/scripts/05-setup-notifications.sh` (run with
`ssh -t`; it asks for the webhook URL on the first run, `--reset-url` to
replace it). It ends by sending a test notification.

## Alternatives considered

- **SMTP target (e.g. Gmail app password):** works, but needs a mail
  account credential on the host, and email is easy to miss. Can be added
  as a second target later.
- **ntfy / Gotify:** push to the phone, but needs a server (self-hosted on
  this host defeats the purpose when the host is the problem) or a public
  ntfy topic.
- **Alertmanager (ADR-0013):** runs in the cluster, so it can't report on
  the host underneath it, and it isn't deployed.

## Consequences

- Discord is a single, external dependency: if it's down or the webhook is
  deleted, notifications are lost (Proxmox logs the failed delivery).
- Very long messages (over 4096 characters) are rejected by Discord. The
  failure mail is trimmed to 25 status lines of 200 characters; a long
  smartd report could still exceed it.
- Everything goes to the channel unfiltered. If it gets noisy, add
  `match-severity` to the matcher rather than more targets.
- Verified 2026-10-26: the target's test notification, and a test failure
  (`notify-failure@pipeline-test`) through Postfix → `proxmox-mail-forward`
  → Discord.

## Open items

- Decide on `default-matcher` → `mail-to-root`: it can't deliver (port 25
  blocked), so each notification leaves a deferred mail for 5 days.
  Disable it, or give it an SMTP target.
