#!/usr/bin/env bash
set -euo pipefail

gpu="N/A"
gpu_temp="N/A"
label="GPU"

if command -v nvidia-smi >/dev/null 2>&1; then
  util="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | sed -n '1p' | tr -d ' ' || true)"
  if [ -n "$util" ] && [ "$util" -eq "$util" ] 2>/dev/null; then
    gpu="${util}%"
  fi
  t="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | sed -n '1p' | tr -d ' ' || true)"
  if [ -n "$t" ] && [ "$t" -eq "$t" ] 2>/dev/null; then
    gpu_temp="${t}°C"
  fi
  label="NVIDIA"
elif [ -r /sys/class/drm/card0/device/gpu_busy_percent ]; then
  util="$(tr -d '\n' < /sys/class/drm/card0/device/gpu_busy_percent || true)"
  if [ -n "$util" ] && [ "$util" -eq "$util" ] 2>/dev/null; then
    gpu="${util}%"
  fi
  if command -v sensors >/dev/null 2>&1; then
    t="$(sensors 2>/dev/null | awk '
      /amdgpu|nouveau|nvidia/i {in_gpu=1}
      in_gpu && /edge:|temp1:/ {
        for (i=1; i<=NF; i++) {
          if ($i ~ /\+?[0-9]+(\.[0-9]+)?°C/) {
            gsub(/\+/, "", $i);
            print $i;
            exit
          }
        }
      }')"
    [ -n "${t:-}" ] && gpu_temp="$t"
  fi
  label="GPU"
fi

tooltip="${label} usage: ${gpu}\\n${label} temp: ${gpu_temp}"
printf '{"text":"󰢮 %s","tooltip":"%s"}\n' "$gpu" "$tooltip"
