#!/usr/bin/env bash
set -uo pipefail

# Use a stable lock path so launch source/env differences cannot spawn duplicates.
lockdir="/tmp/waybar-launch-${UID}.lock.d"
legacy_lockdir="${XDG_RUNTIME_DIR:-/tmp}/waybar-launch.lock.d"
logdir="${XDG_CACHE_HOME:-$HOME/.cache}"
logfile="${logdir}/waybar.log"

mkdir -p "$logdir"

# Avoid multiple launcher loops without relying on flock.
if ! mkdir "$lockdir" 2>/dev/null; then
  exit 0
fi
rmdir "$legacy_lockdir" 2>/dev/null || true

cleanup() {
  rmdir "$lockdir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Keep Waybar alive if it exits unexpectedly and log crashes.
while true; do
  waybar >>"$logfile" 2>&1 || true
  printf '[%s] waybar exited, restarting in 1s\n' "$(date '+%F %T')" >>"$logfile"
  sleep 1
done
