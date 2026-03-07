#!/usr/bin/env bash
set -euo pipefail

WALL_DIR="${WALLPAPER_DIR:-$HOME/Pictures/wallpapers}"
STATE_FILE="$HOME/.cache/hypr-wall-index"

# PNG, JPG, JPEG supported by swaybg
mapfile -t WALLS < <(find "$WALL_DIR" -maxdepth 4 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | sort)
[ "${#WALLS[@]}" -gt 0 ] || exit 0

idx=0
if [ -f "$STATE_FILE" ]; then
  idx="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
fi

idx=$(( (idx + 1) % ${#WALLS[@]} ))
echo "$idx" > "$STATE_FILE"
next="${WALLS[$idx]}"

# Apply via swaybg (stable on Hypr/NVIDIA)
pkill -x hyprpaper 2>/dev/null || true
pkill -x swaybg 2>/dev/null || true
swaybg -i "$next" -m fill >/dev/null 2>&1 &

# Keep record for wallstart
printf '%s\n' "$next" > "$HOME/.cache/hypr-last-wall"

command -v notify-send >/dev/null 2>&1 && notify-send "Wallpaper" "$(basename "$next")"
