#!/usr/bin/env bash
set -euo pipefail

WOFI_STYLE="${HOME}/.config/waybar/menu/awesome-menu.css"

notify() {
  notify-send "Audio" "$1" >/dev/null 2>&1 || true
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    notify "$1 not found"
    exit 0
  fi
}

need wpctl
need wofi

sink_vol_raw="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)"
src_vol_raw="$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null || true)"
sink_pct="N/A"
src_pct="N/A"

if [ -n "$sink_vol_raw" ]; then
  sink_pct="$(printf '%s' "$sink_vol_raw" | awk '{print int($2*100)}')%"
  if printf '%s' "$sink_vol_raw" | rg -q "MUTED"; then
    sink_pct="${sink_pct} (muted)"
  fi
fi

if [ -n "$src_vol_raw" ]; then
  src_pct="$(printf '%s' "$src_vol_raw" | awk '{print int($2*100)}')%"
  if printf '%s' "$src_vol_raw" | rg -q "MUTED"; then
    src_pct="${src_pct} (muted)"
  fi
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

add_item "  Speaker: ${sink_pct}" "noop"
add_item "  Microphone: ${src_pct}" "noop"
add_item "────────── Quick controls ──────────" "noop"
add_item "  Toggle speaker mute" "sink_mute"
add_item "  Toggle mic mute" "src_mute"
add_item "  Speaker volume +5%" "sink_up"
add_item "  Speaker volume -5%" "sink_down"
add_item "  Mic gain +5%" "src_up"
add_item "  Mic gain -5%" "src_down"
add_item "────────── Output devices ──────────" "noop"

wpctl status | awk '
  /Sinks:/ {in_sec=1; next}
  /Sources:/ {in_sec=0}
  in_sec {
    line=$0
    if (match(line, /^[[:space:][:punct:]]*[0-9]+\./)) {
      id=substr(line, RSTART, RLENGTH-1)
      gsub(/[^0-9]/, "", id)
      desc=substr(line, RSTART + RLENGTH)
      gsub(/^[[:space:]|*]+/, "", desc)
      active=(index(line, "*")>0 ? "●" : " ")
      sub(/[[:space:]]*\[.*$/, "", desc)
      sub(/[[:space:]]*<.*$/, "", desc)
      if (desc == "") desc="Audio device " id
      print active "\t" id "\t" desc
    }
  }' | while IFS=$'\t' read -r active id desc; do
  [ -n "$id" ] || continue
  add_item "${active}  ${desc}" "sink_set" "$id"
done

add_item "────────── Input devices ──────────" "noop"

wpctl status | awk '
  /Sources:/ {in_sec=1; next}
  /Source endpoints:/ {in_sec=0}
  in_sec {
    line=$0
    if (match(line, /^[[:space:][:punct:]]*[0-9]+\./)) {
      id=substr(line, RSTART, RLENGTH-1)
      gsub(/[^0-9]/, "", id)
      desc=substr(line, RSTART + RLENGTH)
      gsub(/^[[:space:]|*]+/, "", desc)
      active=(index(line, "*")>0 ? "●" : " ")
      sub(/[[:space:]]*\[.*$/, "", desc)
      sub(/[[:space:]]*<.*$/, "", desc)
      if (desc == "") desc="Input device " id
      print active "\t" id "\t" desc
    }
  }' | while IFS=$'\t' read -r active id desc; do
  [ -n "$id" ] || continue
  add_item "${active}  ${desc}" "src_set" "$id"
done

selection="$(cut -f1 "$tmp_map" | wofi --dmenu --prompt "Audio Control" --width 900 --height 640 --style "$WOFI_STYLE")"
[ -n "${selection:-}" ] || exit 0

entry="$(awk -F '\t' -v sel="$selection" '$1 == sel {print; exit}' "$tmp_map")"
[ -n "$entry" ] || exit 0

action="$(printf '%s' "$entry" | cut -f2)"
payload="$(printf '%s' "$entry" | cut -f3-)"

case "$action" in
  sink_mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
  src_mute) wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle ;;
  sink_up) wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+ ;;
  sink_down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
  src_up) wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SOURCE@ 5%+ ;;
  src_down) wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 5%- ;;
  sink_set)
    [ -n "$payload" ] || exit 0
    wpctl set-default "$payload"
    notify "Default output set"
    ;;
  src_set)
    [ -n "$payload" ] || exit 0
    wpctl set-default "$payload"
    notify "Default input set"
    ;;
  *)
    exit 0
    ;;
esac
