#!/usr/bin/env bash
set -euo pipefail

style="$HOME/.config/wofi/launcher-style.css"
apps_conf="$HOME/.config/wofi/launcher.conf"
menu_conf="$HOME/.config/wofi/launcher-menu.conf"

has() {
  command -v "$1" >/dev/null 2>&1
}

open_browser() {
  if has librewolf; then
    exec librewolf
  elif has firefox; then
    exec firefox
  elif has chromium; then
    exec chromium
  fi
  notify-send "Launcher" "No supported browser found."
}

show_apps() {
  exec wofi --show drun --conf "$apps_conf" --style "$style"
}

show_hub() {
  local choice
  choice="$(printf '%s\n' \
    '󰀻  Apps' \
    '  Terminal' \
    '  Files (yazi)' \
    '󰈹  Browser' \
    '󰓅  Quick Settings' \
    '  Theme Selector' \
    '󰉁  Next Wallpaper' \
    '󰉔  Wallpaper Selector' \
    '󰐑  Power Menu' \
    '󰹑  Screenshot (Region)' \
    '󱣴  Screenshot (Full)' \
    '󰑓  Reload Hyprland' \
    | wofi --dmenu --prompt 'Launch…' --conf "$menu_conf" --style "$style")"

  case "$choice" in
    *"Apps"*) show_apps ;;
    *"Terminal"*) exec kitty ;;
    *"Files (yazi)"*) exec kitty -e yazi ;;
    *"Browser"*) open_browser ;;
    *"Quick Settings"*) exec "$HOME/.config/hypr/scripts/quick-settings.sh" ;;
    *"Theme Selector"*) exec "$HOME/.config/hypr/scripts/theme-selector.sh" ;;
    *"Next Wallpaper"*) exec "$HOME/.config/hypr/scripts/wall-next.sh" ;;
    *"Wallpaper Selector"*) exec "$HOME/.config/hypr/scripts/wall-selector.sh" ;;
    *"Power Menu"*) exec "$HOME/.config/hypr/scripts/power-menu.sh" ;;
    *"Screenshot (Region)"*) exec "$HOME/.config/hypr/scripts/screenshot.sh" region ;;
    *"Screenshot (Full)"*) exec "$HOME/.config/hypr/scripts/screenshot.sh" full ;;
    *"Reload Hyprland"*) exec hyprctl reload ;;
    *) exit 0 ;;
  esac
}

case "${1:-}" in
  --apps) show_apps ;;
  --hub|"") show_hub ;;
  *) show_apps ;;
esac
