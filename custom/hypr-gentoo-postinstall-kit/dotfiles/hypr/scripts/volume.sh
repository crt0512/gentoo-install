#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"

notify() {
  command -v notify-send >/dev/null 2>&1 || return 0
  level="$1"
  notify-send -a "volume" -h int:value:"$level" "Volume" "${level}%"
}

if command -v wpctl >/dev/null 2>&1; then
  case "$action" in
    up)   wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+ ;;
    down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
    mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
    *) exit 1 ;;
  esac

  # Extract integer percent from wpctl output
  level="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}')"
  notify "$level"
  exit 0
fi

if command -v pamixer >/dev/null 2>&1; then
  case "$action" in
    up)   pamixer -i 5 ;;
    down) pamixer -d 5 ;;
    mute) pamixer -t ;;
    *) exit 1 ;;
  esac
  level="$(pamixer --get-volume 2>/dev/null || echo 0)"
  notify "$level"
  exit 0
fi

exit 0
