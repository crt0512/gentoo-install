#!/usr/bin/env bash
set -euo pipefail

WOFI_STYLE="${HOME}/.config/waybar/menu/awesome-menu.css"

notify() {
  notify-send "Bluetooth" "$1" >/dev/null 2>&1 || true
}

if ! command -v bluetoothctl >/dev/null 2>&1; then
  notify "bluetoothctl not found"
  exit 0
fi

if ! command -v wofi >/dev/null 2>&1; then
  notify "wofi not found"
  exit 0
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

power="$(bluetoothctl show 2>/dev/null | awk -F': ' '/Powered:/ {print tolower($2); exit}' || true)"
[ -z "${power:-}" ] && power="no"

if [ "$power" = "yes" ]; then
  add_item "󰂯  Bluetooth: ON  (toggle)" "bt_off"
else
  add_item "󰂲  Bluetooth: OFF (toggle)" "bt_on"
fi

add_item "────────── Devices ──────────" "noop"

paired="$(bluetoothctl devices Paired 2>/dev/null || true)"
if [ -z "${paired:-}" ]; then
  add_item "No paired devices found" "noop"
else
  while IFS= read -r line; do
    [ -n "${line:-}" ] || continue
    mac="$(printf '%s' "$line" | awk '{print $2}')"
    name="$(printf '%s' "$line" | cut -d' ' -f3-)"
    is_connected="no"
    if bluetoothctl info "$mac" 2>/dev/null | rg -q 'Connected:\s+yes'; then
      is_connected="yes"
    fi

    if [ "$is_connected" = "yes" ]; then
      add_item "●  ${name}" "bt_disconnect" "$mac"
    else
      add_item "○  ${name}" "bt_connect" "$mac"
    fi
  done <<<"$paired"
fi

selection="$(cut -f1 "$tmp_map" | wofi --dmenu --prompt "Bluetooth Control" --width 640 --height 520 --style "$WOFI_STYLE")"
[ -n "${selection:-}" ] || exit 0

entry="$(awk -F '\t' -v sel="$selection" '$1 == sel {print; exit}' "$tmp_map")"
[ -n "$entry" ] || exit 0

action="$(printf '%s' "$entry" | cut -f2)"
payload="$(printf '%s' "$entry" | cut -f3-)"

case "$action" in
  bt_on)
    bluetoothctl power on >/dev/null 2>&1 && notify "Bluetooth enabled"
    ;;
  bt_off)
    bluetoothctl power off >/dev/null 2>&1 && notify "Bluetooth disabled"
    ;;
  bt_connect)
    [ -n "$payload" ] || exit 0
    bluetoothctl connect "$payload" >/dev/null 2>&1 && notify "Device connected"
    ;;
  bt_disconnect)
    [ -n "$payload" ] || exit 0
    bluetoothctl disconnect "$payload" >/dev/null 2>&1 && notify "Device disconnected"
    ;;
  *)
    exit 0
    ;;
esac
