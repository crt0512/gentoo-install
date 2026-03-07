#!/usr/bin/env bash
set -euo pipefail
if sudo -n /usr/local/bin/tec-restart >/tmp/tec-restart.log 2>&1; then
  notify-send "TEC" "Restarted successfully"
else
  notify-send "TEC restart failed" "See /tmp/tec-restart.log"
fi
