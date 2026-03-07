#!/usr/bin/env bash
set -euo pipefail

choice="$(printf "  Lock\n  Logout\n  Reboot\n  Shutdown\n" | wofi --dmenu --prompt "Power" --width 320 --height 260)"

case "$choice" in
  "  Lock")
    hyprlock
    ;;
  "  Logout")
    hyprctl dispatch exit
    ;;
  "  Reboot")
    loginctl reboot 2>/dev/null || systemctl reboot 2>/dev/null || sudo reboot
    ;;
  "  Shutdown")
    loginctl poweroff 2>/dev/null || systemctl poweroff 2>/dev/null || sudo poweroff
    ;;
  *)
    exit 0
    ;;
esac
