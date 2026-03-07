#!/usr/bin/env bash
set -euo pipefail

WOFI_STYLE="${HOME}/.config/waybar/menu/awesome-menu.css"

notify() {
  notify-send "Network" "$1" >/dev/null 2>&1 || true
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    notify "$1 not found"
    exit 0
  fi
}

require nmcli
require wofi

wifi_radio="$(nmcli radio wifi 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
net_state="$(nmcli networking connectivity 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
net_enabled="$(nmcli networking 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
[ -z "$wifi_radio" ] && wifi_radio="unknown"
[ -z "$net_state" ] && net_state="unknown"
[ -z "$net_enabled" ] && net_enabled="unknown"

bt_power="unknown"
if command -v bluetoothctl >/dev/null 2>&1; then
  bt_power="$(bluetoothctl show 2>/dev/null | awk -F': ' '/Powered:/ {print tolower($2); exit}' || true)"
  [ -z "$bt_power" ] && bt_power="unknown"
fi

airplane="off"
if [ "$net_enabled" = "disabled" ] && [ "$wifi_radio" = "disabled" ]; then
  if [ "$bt_power" = "yes" ]; then
    airplane="off"
  else
    airplane="on"
  fi
fi

active_line="$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status | rg ':connected:' | rg -v '^lo:' | head -n1 || true)"
active_desc="Offline"
if [ -n "$active_line" ]; then
  active_dev="$(printf '%s' "$active_line" | cut -d: -f1)"
  active_type="$(printf '%s' "$active_line" | cut -d: -f2)"
  active_con="$(printf '%s' "$active_line" | cut -d: -f4-)"
  case "$active_type" in
    wifi) active_desc="Wi-Fi (${active_con:-$active_dev})" ;;
    ethernet) active_desc="Ethernet (${active_dev})" ;;
    *) active_desc="${active_type} (${active_dev})" ;;
  esac
fi

tmp_map="$(mktemp)"
cleanup() { rm -f "$tmp_map"; }
trap cleanup EXIT

add_item() {
  local line="$1"
  local action="$2"
  local payload="${3:-}"
  printf '%s\t%s\t%s\n' "$line" "$action" "$payload" >>"$tmp_map"
}

if [ "$wifi_radio" = "enabled" ]; then
  add_item "󰤨  Wi-Fi: ON  (toggle)" "wifi_off"
else
  add_item "󰤭  Wi-Fi: OFF (toggle)" "wifi_on"
fi

if [ "$net_state" = "none" ] || [ "$net_state" = "unknown" ]; then
  add_item "󰲜  Internet: OFF (toggle)" "net_on"
else
  add_item "󰛳  Internet: ON  (toggle)" "net_off"
fi

if [ "$airplane" = "on" ]; then
  add_item "󰀝  Airplane mode: ON  (toggle)" "airplane_off"
else
  add_item "󰀞  Airplane mode: OFF (toggle)" "airplane_on"
fi

add_item "󰈀  Active mode: ${active_desc}" "noop"
add_item "────────── Available Wi-Fi ──────────" "noop"

if [ "$wifi_radio" = "enabled" ]; then
  wifi_lines="$(nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan auto 2>/dev/null || true)"
  if [ -n "$wifi_lines" ]; then
    while IFS=: read -r in_use ssid signal security; do
      [ -z "${ssid// }" ] && continue
      sec_icon=""
      [ -n "$security" ] && [ "$security" != "--" ] && sec_icon=""
      current=" "
      [ "$in_use" = "*" ] && current="●"
      label="${current}  ${sec_icon}  ${ssid}  (${signal}%)"
      add_item "$label" "wifi_connect" "$ssid"
    done <<<"$wifi_lines"
  fi
fi

selection="$(cut -f1 "$tmp_map" | wofi --dmenu --prompt "Network Control" --width 860 --height 520 --style "$WOFI_STYLE")"
[ -n "${selection:-}" ] || exit 0

entry="$(awk -F '\t' -v sel="$selection" '$1 == sel {print; exit}' "$tmp_map")"
[ -n "$entry" ] || exit 0

action="$(printf '%s' "$entry" | cut -f2)"
payload="$(printf '%s' "$entry" | cut -f3-)"

case "$action" in
  wifi_on)
    nmcli radio wifi on && notify "Wi-Fi enabled"
    ;;
  wifi_off)
    nmcli radio wifi off && notify "Wi-Fi disabled"
    ;;
  net_on)
    nmcli networking on && notify "Networking enabled"
    ;;
  net_off)
    nmcli networking off && notify "Networking disabled"
    ;;
  airplane_on)
    nmcli radio all off >/dev/null 2>&1 || true
    nmcli networking off >/dev/null 2>&1 || true
    if command -v bluetoothctl >/dev/null 2>&1; then
      bluetoothctl power off >/dev/null 2>&1 || true
    fi
    notify "Airplane mode enabled"
    ;;
  airplane_off)
    nmcli networking on >/dev/null 2>&1 || true
    nmcli radio wifi on >/dev/null 2>&1 || true
    if command -v bluetoothctl >/dev/null 2>&1; then
      bluetoothctl power on >/dev/null 2>&1 || true
    fi
    notify "Airplane mode disabled"
    ;;
  wifi_connect)
    [ -n "$payload" ] || exit 0
    if nmcli -g NAME connection show | rg -Fxq "$payload"; then
      nmcli connection up id "$payload" >/dev/null && notify "Connected to ${payload}"
      exit 0
    fi

    sec="$(nmcli -t -f SSID,SECURITY device wifi list | rg "^${payload}:" | head -n1 | cut -d: -f2- || true)"
    pass=""
    if [ -n "$sec" ] && [ "$sec" != "--" ]; then
      pass="$(wofi --dmenu --prompt "Password for ${payload}" --password --width 600 --height 120 --style "$WOFI_STYLE")"
      [ -n "${pass:-}" ] || exit 0
      nmcli device wifi connect "$payload" password "$pass" >/dev/null && notify "Connected to ${payload}"
    else
      nmcli device wifi connect "$payload" >/dev/null && notify "Connected to ${payload}"
    fi
    ;;
  *)
    exit 0
    ;;
esac
