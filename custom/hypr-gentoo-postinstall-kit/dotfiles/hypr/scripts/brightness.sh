#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
command -v brightnessctl >/dev/null 2>&1 || exit 0

# If no backlight device exists (common on desktops), do nothing.
brightnessctl -l >/dev/null 2>&1 || exit 0

case "$action" in
  up) brightnessctl set +10% >/dev/null ;;
  down) brightnessctl set 10%- >/dev/null ;;
  *) exit 1 ;;
esac

command -v notify-send >/dev/null 2>&1 || exit 0
level="$(brightnessctl g)"
max="$(brightnessctl m)"
pct=$(( level * 100 / max ))
notify-send -a "brightness" -h int:value:"$pct" "Brightness" "${pct}%"
