#!/usr/bin/env bash
set -euo pipefail

WOFI_STYLE="${HOME}/.config/waybar/menu/awesome-menu.css"

notify() {
  notify-send "Display" "$1" >/dev/null 2>&1 || true
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    notify "$1 not found"
    exit 0
  fi
}

need hyprctl
need wofi
need jq

mon_json="$(hyprctl -j monitors 2>/dev/null || true)"
[ -n "$mon_json" ] || {
  notify "Could not read monitor info"
  exit 0
}

focused_name="$(printf '%s' "$mon_json" | jq -r '.[] | select(.focused==true) | .name' | head -n1)"
[ -n "$focused_name" ] || focused_name="$(printf '%s' "$mon_json" | jq -r '.[0].name // empty')"
[ -n "$focused_name" ] || {
  notify "No monitor detected"
  exit 0
}

current_mode="$(printf '%s' "$mon_json" | jq -r --arg name "$focused_name" '.[] | select(.name==$name) | "\(.width)x\(.height)@\(.refreshRate|tostring)Hz"' | sed -n '1p')"
normalized_current="$(printf '%s' "$current_mode" | sed 's/Hz$//')"
display_desc="$(printf '%s' "$mon_json" | jq -r --arg name "$focused_name" '.[] | select(.name==$name) | .description // .name' | head -n1)"

brightness_pct="N/A"
if command -v brightnessctl >/dev/null 2>&1; then
  b_now="$(brightnessctl g 2>/dev/null || true)"
  b_max="$(brightnessctl m 2>/dev/null || true)"
  if [ -n "$b_now" ] && [ -n "$b_max" ] && [ "$b_max" -gt 0 ] 2>/dev/null; then
    brightness_pct="$((100 * b_now / b_max))%"
  fi
fi

gpu_vendor="GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_vendor="NVIDIA"
elif [ -r /sys/class/drm/card0/device/vendor ]; then
  vendor_hex="$(tr -d '\n' < /sys/class/drm/card0/device/vendor 2>/dev/null || true)"
  case "${vendor_hex,,}" in
    0x10de) gpu_vendor="NVIDIA" ;;
    0x1002|0x1022) gpu_vendor="AMD" ;;
    0x8086) gpu_vendor="Intel" ;;
  esac
fi

menu_pick() {
  local prompt="$1"
  local width="$2"
  local height="$3"
  local map_file="$4"
  local selection entry action payload

  selection="$(cut -f1 "$map_file" | wofi --dmenu --prompt "$prompt" --width "$width" --height "$height" --style "$WOFI_STYLE")"
  [ -n "${selection:-}" ] || return 1

  entry="$(awk -F '\t' -v sel="$selection" '$1 == sel {print; exit}' "$map_file")"
  [ -n "$entry" ] || return 1
  action="$(printf '%s' "$entry" | cut -f2)"
  payload="$(printf '%s' "$entry" | cut -f3-)"
  printf '%s\t%s\n' "$action" "$payload"
}

add_item() {
  local line="$1"
  local action="$2"
  local payload="${3:-}"
  printf '%s\t%s\t%s\n' "$line" "$action" "$payload" >>"$MAP_FILE"
}

open_main_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_main() { rm -f "$MAP_FILE"; }
  trap cleanup_main RETURN

  add_item "󰍹  ${focused_name}  •  ${display_desc}" "noop"
  add_item "󰘨  ${current_mode}  •  ${gpu_vendor}" "noop"
  add_item "──────────────────────────────────────────" "noop"
  add_item "󰃠  Brightness      (${brightness_pct})" "open_brightness"
  add_item "󰍺  Resolution / Refresh" "open_modes"
  add_item "󰑓  Scale (100% / 125% / 150%)" "open_scale"

  menu_pick "Display Control" 940 520 "$MAP_FILE" || return 1
}

open_brightness_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_brightness() { rm -f "$MAP_FILE"; }
  trap cleanup_brightness RETURN

  if ! command -v brightnessctl >/dev/null 2>&1; then
    add_item "󰃟  Brightness not available on this device" "noop"
  else
    add_item "󰃞  -10%" "brightness_down"
    add_item "󰃠  +10%" "brightness_up"
    add_item "────────────────────────" "noop"
    for p in 20 30 40 50 60 70 80 90 100; do
      mark="○"
      [ "${brightness_pct%\%}" = "$p" ] && mark="◉"
      add_item "${mark}  Set ${p}%" "brightness_set" "$p"
    done
  fi

  menu_pick "Brightness" 520 560 "$MAP_FILE" || return 1
}

open_modes_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_modes() { rm -f "$MAP_FILE"; }
  trap cleanup_modes RETURN

  printf '%s' "$mon_json" | jq -r --arg name "$focused_name" '.[] | select(.name==$name) | .availableModes[]?' | while IFS= read -r mode; do
    [ -n "$mode" ] || continue
    mark="○"
    [ "$mode" = "$normalized_current" ] && mark="◉"
    pretty_mode="$(printf '%s' "$mode" | sed 's/@/ @ /')"
    add_item "${mark}  ${pretty_mode}" "mode_set" "$mode"
  done

  menu_pick "Resolution / Refresh" 760 640 "$MAP_FILE" || return 1
}

open_scale_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_scale() { rm -f "$MAP_FILE"; }
  trap cleanup_scale RETURN

  current_scale="$(printf '%s' "$mon_json" | jq -r --arg name "$focused_name" '.[] | select(.name==$name) | (.scale // 1)' | sed -n '1p')"
  for s in 1 1.25 1.5; do
    label_pct="$(awk -v v="$s" 'BEGIN{printf "%.0f", v*100}')"
    mark="○"
    [ "$current_scale" = "$s" ] && mark="◉"
    add_item "${mark}  ${label_pct}% (scale ${s})" "scale_set" "$s"
  done

  menu_pick "Scale" 520 380 "$MAP_FILE" || return 1
}

picked="$(open_main_menu || true)"
[ -n "${picked:-}" ] || exit 0
action="$(printf '%s' "$picked" | cut -f1)"
payload="$(printf '%s' "$picked" | cut -f2-)"

if [ "$action" = "open_brightness" ]; then
  picked="$(open_brightness_menu || true)"
  [ -n "${picked:-}" ] || exit 0
  action="$(printf '%s' "$picked" | cut -f1)"
  payload="$(printf '%s' "$picked" | cut -f2-)"
elif [ "$action" = "open_modes" ]; then
  picked="$(open_modes_menu || true)"
  [ -n "${picked:-}" ] || exit 0
  action="$(printf '%s' "$picked" | cut -f1)"
  payload="$(printf '%s' "$picked" | cut -f2-)"
elif [ "$action" = "open_scale" ]; then
  picked="$(open_scale_menu || true)"
  [ -n "${picked:-}" ] || exit 0
  action="$(printf '%s' "$picked" | cut -f1)"
  payload="$(printf '%s' "$picked" | cut -f2-)"
fi

case "$action" in
  brightness_down)
    brightnessctl set 10%- >/dev/null && notify "Brightness decreased"
    ;;
  brightness_up)
    brightnessctl set +10% >/dev/null && notify "Brightness increased"
    ;;
  brightness_set)
    [ -n "$payload" ] || exit 0
    brightnessctl set "${payload}%" >/dev/null && notify "Brightness set to ${payload}%"
    ;;
  mode_set)
    [ -n "$payload" ] || exit 0
    scale="$(printf '%s' "$mon_json" | jq -r --arg name "$focused_name" '.[] | select(.name==$name) | .scale' | head -n1)"
    [ -z "$scale" ] && scale="1"
    hyprctl keyword monitor "${focused_name},${payload},auto,${scale}" >/dev/null
    notify "Applied ${payload} on ${focused_name}"
    ;;
  scale_set)
    [ -n "$payload" ] || exit 0
    cur_mode_no_hz="$(printf '%s' "$current_mode" | sed 's/Hz$//')"
    hyprctl keyword monitor "${focused_name},${cur_mode_no_hz},auto,${payload}" >/dev/null
    notify "Scale ${payload} applied on ${focused_name}"
    ;;
  *)
    exit 0
    ;;
esac
