#!/usr/bin/env bash
set -euo pipefail

if ! command -v bluetoothctl >/dev/null 2>&1; then
  echo '{"text":"󰂲 bt N/A","tooltip":"bluetoothctl not found"}'
  exit 0
fi

power="$(bluetoothctl show 2>/dev/null | awk -F': ' '/Powered:/ {print tolower($2); exit}' || true)"
[ -z "${power:-}" ] && power="no"

if [ "$power" != "yes" ]; then
  echo '{"text":"󰂲 bt off","tooltip":"Bluetooth is powered off\nLeft click: open bluetooth control"}'
  exit 0
fi

connected_lines="$(bluetoothctl devices Connected 2>/dev/null || true)"
connected_count="$(printf '%s\n' "$connected_lines" | rg '^Device ' | wc -l || true)"
[ -z "${connected_count:-}" ] && connected_count=0

if [ "$connected_count" -gt 0 ] 2>/dev/null; then
  first_name="$(printf '%s\n' "$connected_lines" | sed -n '1p' | cut -d' ' -f3- || true)"
  [ -z "${first_name:-}" ] && first_name="connected device"
  echo "{\"text\":\"󰂱 ${connected_count}\",\"tooltip\":\"Bluetooth ON\\nConnected: ${connected_count}\\nPrimary: ${first_name}\\nLeft click: open bluetooth control\"}"
else
  echo '{"text":"󰂯 bt on","tooltip":"Bluetooth ON\nNo connected device\nLeft click: open bluetooth control"}'
fi
