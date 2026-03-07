#!/usr/bin/env bash
set -euo pipefail

if ! command -v nmcli >/dev/null 2>&1; then
  echo '{"text":"󰖪 net N/A","tooltip":"nmcli not found"}'
  exit 0
fi

wifi_radio="$(nmcli radio wifi 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
net_enabled="$(nmcli networking 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
all_radios="$(nmcli radio all 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"

if { [ "$all_radios" = "disabled" ] || { [ "$net_enabled" = "disabled" ] && [ "$wifi_radio" = "disabled" ]; }; }; then
  echo '{"text":"󰀝 airplane","tooltip":"Airplane mode is enabled\nLeft click: open network control"}'
  exit 0
fi

line="$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status | rg ':connected:' | head -n1 || true)"
if [ -z "$line" ]; then
  echo '{"text":"󰖪 offline","tooltip":"No active network"}'
  exit 0
fi

dev="$(echo "$line" | cut -d: -f1)"
typ="$(echo "$line" | cut -d: -f2)"
con="$(echo "$line" | cut -d: -f4-)"

if [ "$typ" = "wifi" ]; then
  sig="$(nmcli -t -f IN-USE,SIGNAL dev wifi list 2>/dev/null | rg '^\*' | head -n1 | cut -d: -f2 || true)"
  [ -z "$sig" ] && sig="?"
  wifi_count="$(nmcli -t -f SSID dev wifi list 2>/dev/null | rg -v '^$' | wc -l || true)"
  echo "{\"text\":\" ${con}\",\"tooltip\":\"Mode: Wi-Fi\\nNetwork: ${con}\\nDevice: ${dev}\\nSignal: ${sig}%\\nNearby Wi-Fi: ${wifi_count}\\nLeft click: open network control\"}"
elif [ "$typ" = "ethernet" ]; then
  wifi_count="$(nmcli -t -f SSID dev wifi list 2>/dev/null | rg -v '^$' | wc -l || true)"
  echo "{\"text\":\"󰈀 ${dev}\",\"tooltip\":\"Mode: Ethernet (LAN)\\nDevice: ${dev}\\nProfile: ${con}\\nNearby Wi-Fi: ${wifi_count}\\nLeft click: open network control\"}"
else
  echo "{\"text\":\"󰈀 ${dev}\",\"tooltip\":\"Connected: ${typ}\\nDevice: ${dev}\\nProfile: ${con}\\nLeft click: open network control\"}"
fi
