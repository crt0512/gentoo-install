#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
command -v playerctl >/dev/null 2>&1 || exit 0

case "$action" in
  play-pause) playerctl play-pause ;;
  next)       playerctl next ;;
  prev)       playerctl previous ;;
  stop)       playerctl stop ;;
  *) exit 1 ;;
esac
