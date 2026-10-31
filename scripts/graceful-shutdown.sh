#!/usr/bin/env bash
# Stop Nextcloud cleanly, then reboot or power off the Proxmox host. Run from
# the workstation (WSL), which has SSH access to both the host and the nodes;
# root on the host has none to the nodes. Replaces the old copy on the host.
#
#   scripts/graceful-shutdown.sh check     read-only: can everything be reached?
#   scripts/graceful-shutdown.sh reboot    stop, reboot, wait, start Nextcloud
#   scripts/graceful-shutdown.sh poweroff  stop, power off (run `start` after power on)
#   scripts/graceful-shutdown.sh start     start timers and Nextcloud (also recovers a failed run)
#
# Options: --yes skips the prompt. --force continues if pods won't stop in time
# (the VM shutdown stops them instead).
set -euo pipefail

HOST=root@192.168.1.10
CP1=ubuntu@192.168.1.20
NS=nextcloud
# Both run with one replica (mariadb.yaml, nextcloud/values.yaml).
REPLICAS=1
TIMERS="syncoid-k8s.timer syncoid-ha-backups.timer"
SERVICES="syncoid-k8s.service syncoid-ha-backups.service"

SSH_OPTS=(-n -o ConnectTimeout=10 -o BatchMode=yes)
H() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }
K() { ssh "${SSH_OPTS[@]}" "$CP1" timeout 30 sudo microk8s kubectl "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# wait_for <description> <seconds> <command...>: poll until the command succeeds.
wait_for() {
  local what=$1 limit=$2 waited=0
  shift 2
  echo "waiting: $what (up to ${limit}s)"
  until "$@" >/dev/null 2>&1; do
    (( waited < limit )) || return 1
    sleep 5
    waited=$((waited + 5))
  done
}

# A failed kubectl must not read as "no pods left", so this fails unless kubectl worked.
pods_gone() {
  local pods
  pods=$(K -n "$NS" get pods --no-headers -o name \
    --field-selector='status.phase!=Succeeded,status.phase!=Failed') || return 1
  [[ -z "$pods" ]]
}
nodes_ready() {
  local nodes
  nodes=$(K get nodes --no-headers) || return 1
  [[ -n "$nodes" ]] && ! awk '{print $2}' <<<"$nodes" | grep -qvx Ready
}
services_idle() { ! H systemctl is-active --quiet $SERVICES; }
boot_changed() {
  local now
  now=$(H cat /proc/sys/kernel/random/boot_id) || return 1
  [[ "$now" != "$1" ]]
}
nextcloud_status() { K -n "$NS" exec deploy/nextcloud -c nextcloud -- curl -s -m 10 http://localhost/status.php; }

check() {
  H true || die "can't reach the host over SSH ($HOST)"
  echo "ok: host reachable, kernel $(H uname -r)"
  K -n "$NS" get deploy,sts --no-headers >/dev/null || die "can't reach the cluster through $CP1"
  echo "ok: cluster reachable through $CP1"
  nodes_ready || die "not all nodes are Ready"
  echo "ok: all nodes Ready"
  [[ "$(H zpool status -x)" == "all pools are healthy" ]] || die "ZFS pools aren't healthy"
  echo "ok: ZFS pools healthy"
  if H systemctl is-active --quiet azure-sync-k8s.service; then
    die "the Azure sync is running; wait for it to finish"
  fi
  echo "ok: Azure sync not running"
  # A machine that reboots during a Tailscale incident can't rejoin the tailnet.
  if curl -s -m 10 https://status.tailscale.com/api/v2/summary.json | grep -q '"incidents":\[{'; then
    echo "WARNING: Tailscale has an open incident; rebooted machines may not rejoin the tailnet"
  fi
}

stop_nextcloud() {
  # Runtime only: the timers start again on boot.
  # shellcheck disable=SC2086
  H systemctl stop $TIMERS
  echo "stopped: $TIMERS"
  wait_for "running replication to finish" 1800 services_idle \
    || die "replication still running; run '$0 start' to restore the timers"

  K -n "$NS" scale deploy/nextcloud --replicas=0 \
    && K -n "$NS" scale sts/nextcloud-db --replicas=0 \
    || die "scale-down failed, nothing was rebooted; run '$0 start' to bring Nextcloud back"
  if ! wait_for "Nextcloud and its database to stop" 300 pods_gone; then
    if [[ "$FORCE" == 1 ]]; then
      echo "WARNING: pods still there; continuing because of --force"
    else
      die "pods haven't stopped, or the cluster stopped answering. Nothing was rebooted. Don't restart kubelite on a
control-plane node. Re-run with --force, or run '$0 start' to bring Nextcloud back."
    fi
  fi
}

start_nextcloud() {
  # shellcheck disable=SC2086
  H systemctl start $TIMERS
  echo "started: $TIMERS"
  wait_for "all nodes Ready" 600 nodes_ready || die "nodes aren't Ready; Nextcloud is still down"
  wait_for "old pods to clear" 300 pods_gone || die "old pods are stuck; Nextcloud is still down"

  # The database first: Nextcloud needs it to start.
  K -n "$NS" scale sts/nextcloud-db --replicas="$REPLICAS"
  wait_for "the database" 300 K -n "$NS" rollout status sts/nextcloud-db --timeout=25s \
    || die "the database didn't start; Nextcloud is still down"
  K -n "$NS" scale deploy/nextcloud --replicas="$REPLICAS"
  wait_for "Nextcloud" 300 K -n "$NS" rollout status deploy/nextcloud --timeout=25s \
    || die "Nextcloud didn't start"

  local status
  status=$(nextcloud_status) || die "Nextcloud is running, but status.php didn't answer"
  grep -q '"maintenance":false' <<<"$status" || die "Nextcloud is up, but in maintenance mode"
  echo "ok: Nextcloud is up"
}

confirm() {
  [[ "$YES" == 1 ]] && return 0
  echo "This stops Nextcloud and will $1 the host; every VM goes down with it."
  local answer
  read -r -p "Type '$1' to continue: " answer
  [[ "$answer" == "$1" ]] || die "cancelled, nothing changed"
}

# Delayed, so the SSH session ends cleanly before the host goes down.
trigger() { H systemd-run --quiet --on-active=3s systemctl "$1"; }

ACTION=${1:-}
[[ $# -gt 0 ]] && shift
FORCE=0
YES=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --yes) YES=1 ;;
    *) die "unknown option: $arg" ;;
  esac
done

case "$ACTION" in
  check)
    check
    ;;
  start)
    start_nextcloud
    ;;
  reboot)
    check
    confirm reboot
    BOOT_ID=$(H cat /proc/sys/kernel/random/boot_id)
    stop_nextcloud
    trigger reboot
    echo "rebooting the host"
    wait_for "the host to come back" 900 boot_changed "$BOOT_ID" \
      || die "host not back after 15 minutes: check its console. Then run '$0 start'"
    start_nextcloud
    echo "done: host on kernel $(H uname -r)"
    ;;
  poweroff)
    check
    confirm poweroff
    stop_nextcloud
    trigger poweroff
    echo "powering off. It stays off until someone presses the power button."
    echo "After power on, run: $0 start"
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
