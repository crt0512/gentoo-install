#!/usr/bin/env bash
set -euo pipefail

if ! command -v wpctl >/dev/null 2>&1; then
  echo '{"text":" N/A","tooltip":"wpctl not found"}'
  exit 0
fi

vol_line="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)"
if [ -z "$vol_line" ]; then
  echo '{"text":" N/A","tooltip":"No default sink"}'
  exit 0
fi

if echo "$vol_line" | rg -q "MUTED"; then
  echo '{"text":" mute","tooltip":"Audio muted\nLeft click: audio control\nRight click: output selector"}'
  exit 0
fi

vol="$(echo "$vol_line" | awk '{print int($2*100)}')"
if [ "$vol" -lt 35 ]; then icon=""
elif [ "$vol" -lt 70 ]; then icon=""
else icon=""
fi

echo "{\"text\":\"$icon ${vol}%\",\"tooltip\":\"Default audio sink\\nScroll: volume\\nLeft click: audio control\\nRight click: output selector\"}"
