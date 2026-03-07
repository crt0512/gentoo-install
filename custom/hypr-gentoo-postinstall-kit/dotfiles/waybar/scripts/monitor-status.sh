#!/usr/bin/env bash
set -euo pipefail

display="N/A"
monitor_name=""
gpu_vendor="Unknown"
gpu_icon="󰢮"

detect_gpu_vendor() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu_vendor="NVIDIA"
    gpu_icon="󰢮"
    return
  fi

  local vendor_hex=""
  if [ -r /sys/class/drm/card0/device/vendor ]; then
    vendor_hex="$(tr -d '\n' < /sys/class/drm/card0/device/vendor 2>/dev/null || true)"
  elif command -v lspci >/dev/null 2>&1; then
    vendor_hex="$(lspci -nn | awk '/VGA|3D|Display/ { if (match($0, /\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]/)) { print substr($0, RSTART + 1, 4); exit } }' || true)"
    [ -n "${vendor_hex:-}" ] && vendor_hex="0x${vendor_hex}"
  fi

  case "${vendor_hex,,}" in
    0x10de) gpu_vendor="NVIDIA"; gpu_icon="󰢮" ;;
    0x1002|0x1022) gpu_vendor="AMD"; gpu_icon="" ;;
    0x8086) gpu_vendor="Intel"; gpu_icon="󰘚" ;;
    *) gpu_vendor="GPU"; gpu_icon="󰍛" ;;
  esac
}

if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  mon_json="$(hyprctl -j monitors 2>/dev/null || true)"
  if [ -n "${mon_json:-}" ]; then
    mon_line="$(printf '%s\n' "$mon_json" | jq -r '
      (.[] | select(.focused == true) | [.name, .width, .height, .refreshRate] | @tsv),
      (.[] | [.name, .width, .height, .refreshRate] | @tsv)
      ' | sed -n '1p' || true)"

    if [ -n "${mon_line:-}" ] && [ "$mon_line" != "null" ]; then
      monitor_name="$(printf '%s' "$mon_line" | awk -F '\t' '{print $1}')"
      mon_w="$(printf '%s' "$mon_line" | awk -F '\t' '{print $2}')"
      mon_h="$(printf '%s' "$mon_line" | awk -F '\t' '{print $3}')"
      mon_r="$(printf '%s' "$mon_line" | awk -F '\t' '{print $4}')"
      mon_r="$(printf '%s' "$mon_r" | awk '{printf "%.2f", $1}')"
      if [ -n "${monitor_name:-}" ] && [ -n "${mon_w:-}" ] && [ -n "${mon_h:-}" ] && [ -n "${mon_r:-}" ]; then
        display="${mon_w}x${mon_h}@${mon_r}Hz ${monitor_name}"
      fi
    fi
  fi
elif command -v hyprctl >/dev/null 2>&1; then
  mode="$(hyprctl monitors 2>/dev/null | rg -m1 '^[[:space:]]*[0-9]+x[0-9]+@' | sed 's/^[[:space:]]*//' || true)"
  monitor_name="$(hyprctl monitors 2>/dev/null | rg -m1 '^Monitor ' | awk '{print $2}' || true)"
  if [ -n "$mode" ]; then
    display="$(echo "$mode" | sed -E 's/([0-9]+x[0-9]+)@([0-9.]+).*/\1@\2Hz/')"
    if [ -n "${monitor_name:-}" ]; then
      display="${display} ${monitor_name}"
    fi
  fi
fi

detect_gpu_vendor

text="󰍹 ${gpu_icon} ${display}"
tooltip="Display mode: ${display}\\nGPU: ${gpu_vendor}"

if command -v brightnessctl >/dev/null 2>&1; then
  b_now="$(brightnessctl g 2>/dev/null || true)"
  b_max="$(brightnessctl m 2>/dev/null || true)"
  if [ -n "$b_now" ] && [ -n "$b_max" ] && [ "$b_max" -gt 0 ] 2>/dev/null; then
    b_pct="$((100 * b_now / b_max))"
    tooltip="${tooltip}\\nBrightness: ${b_pct}%"
  fi
fi

tooltip="${tooltip}\\nLeft click: display control"

printf '{"text":"%s","tooltip":"%s"}\n' "$text" "$tooltip"
