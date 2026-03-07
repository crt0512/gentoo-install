#!/usr/bin/env bash
set -euo pipefail

if ! command -v wpctl >/dev/null 2>&1; then
  echo '{"text":" N/A","tooltip":"wpctl not found"}'
  exit 0
fi

vol_line="$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null || true)"
if [ -z "$vol_line" ]; then
  echo '{"text":" N/A","tooltip":"No default source (mic)"}'
  exit 0
fi

if echo "$vol_line" | rg -q "MUTED"; then
  echo '{"text":" mute","tooltip":"Microphone muted\nClick: unmute\nRight-click: input source"}'
  exit 0
fi

vol="$(echo "$vol_line" | awk '{print int($2*100)}')"
echo "{\"text\":\" ${vol}%\",\"tooltip\":\"Default microphone\\nScroll: mic volume\\nClick: mute\\nRight-click: select input\"}"
