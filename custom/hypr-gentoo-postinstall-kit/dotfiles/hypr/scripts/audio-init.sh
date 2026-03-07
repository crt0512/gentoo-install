#!/usr/bin/env bash
set -euo pipefail

if command -v gentoo-pipewire-launcher >/dev/null 2>&1; then
  pgrep -x pipewire >/dev/null 2>&1 || gentoo-pipewire-launcher >/dev/null 2>&1 &
else
  pgrep -x pipewire >/dev/null 2>&1 || pipewire >/dev/null 2>&1 &
  pgrep -x wireplumber >/dev/null 2>&1 || wireplumber >/dev/null 2>&1 &
  pgrep -x pipewire-pulse >/dev/null 2>&1 || pipewire-pulse >/dev/null 2>&1 &
fi

sleep 1

# If no default sink, set first available sink as default
if command -v wpctl >/dev/null 2>&1; then
  if ! wpctl get-volume @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1; then
    first_sink="$(wpctl status | awk '
      /Sinks:/ {in_sinks=1; next}
      /Sources:/ {in_sinks=0}
      in_sinks && $1 ~ /^[0-9]+\./ {gsub(/\./, "", $1); print $1; exit}
    ')"
    [ -n "${first_sink:-}" ] && wpctl set-default "$first_sink" >/dev/null 2>&1 || true
  fi
fi
