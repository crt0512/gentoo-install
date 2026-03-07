#!/usr/bin/env bash
set -euo pipefail

WALL_DIR="${WALLPAPER_DIR:-$HOME/Pictures/wallpapers}"
LAST_FILE="$HOME/.cache/hypr-last-wall"
STYLE_FILE="$HOME/.config/wofi/wallpaper-style.css"

if ! command -v wofi >/dev/null 2>&1; then
  notify-send "Wallpaper" "wofi not found" >/dev/null 2>&1 || true
  exit 0
fi

mapfile -t WALLS < <(find "$WALL_DIR" -maxdepth 4 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | sort)
[ "${#WALLS[@]}" -gt 0 ] || {
  notify-send "Wallpaper" "No images found in $WALL_DIR" >/dev/null 2>&1 || true
  exit 0
}

current=""
if [ -s "$LAST_FILE" ]; then
  current="$(cat "$LAST_FILE" 2>/dev/null || true)"
fi

apply_wallpaper() {
  local img="$1"
  pkill -x hyprpaper 2>/dev/null || true
  pkill -x swaybg 2>/dev/null || true
  swaybg -i "$img" -m fill >/dev/null 2>&1 &
  printf '%s\n' "$img" >"$LAST_FILE"

  local idx=0 i
  for i in "${!WALLS[@]}"; do
    if [ "${WALLS[$i]}" = "$img" ]; then
      idx="$i"
      break
    fi
  done
  printf '%s\n' "$idx" >"$HOME/.cache/hypr-wall-index"

  notify-send "Wallpaper" "Applied: $(basename "$img")" >/dev/null 2>&1 || true
}

preview_wallpaper() {
  local img="$1"

  if command -v swayimg >/dev/null 2>&1; then
    swayimg "$img" >/dev/null 2>&1 &
  elif command -v imv >/dev/null 2>&1; then
    imv "$img" >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$img" >/dev/null 2>&1 &
  else
    notify-send "Wallpaper" "No preview app found (install swayimg/imv)" >/dev/null 2>&1 || true
  fi
}

while :; do
  tmp_map="$(mktemp)"
  cleanup() { rm -f "$tmp_map"; }
  trap cleanup EXIT

  for wall in "${WALLS[@]}"; do
    name="$(basename "$wall")"
    if [ "$wall" = "$current" ]; then
      label="  $name"
    else
      label="  $name"
    fi
    printf '%s\t%s\n' "$label" "$wall" >>"$tmp_map"
  done

  printf '%s\t%s\n' "󰑐  Random wallpaper" "__random__" >>"$tmp_map"
  printf '%s\t%s\n' "  Close" "__close__" >>"$tmp_map"

  choice="$(cut -f1 "$tmp_map" | wofi --dmenu --prompt "Wallpaper" --width 980 --height 640 --columns 2 --style "$STYLE_FILE")"
  [ -n "${choice:-}" ] || exit 0

  picked="$(awk -F '\t' -v sel="$choice" '$1 == sel {print $2; exit}' "$tmp_map")"
  [ -n "$picked" ] || exit 0

  case "$picked" in
    __close__)
      exit 0
      ;;
    __random__)
      random_wall="${WALLS[$((RANDOM % ${#WALLS[@]}))]}"
      apply_wallpaper "$random_wall"
      exit 0
      ;;
    *)
      action="$(printf '%s\n' '󰉍  Preview image' '  Apply wallpaper' '  Back' | wofi --dmenu --prompt "$(basename "$picked")" --width 520 --height 260 --style "$STYLE_FILE")"
      case "$action" in
        *"Preview image"*)
          preview_wallpaper "$picked"
          ;;
        *"Apply wallpaper"*)
          apply_wallpaper "$picked"
          exit 0
          ;;
        *)
          ;;
      esac
      ;;
  esac
done
