#!/usr/bin/env bash
set -euo pipefail

pkill -f waybar-launch.sh 2>/dev/null || true
pkill -x waybar 2>/dev/null || true
pkill -x mako 2>/dev/null || true

rm -rf "/tmp/waybar-launch-$UID.lock.d" "${XDG_RUNTIME_DIR:-/tmp}/waybar-launch.lock.d"

~/.config/hypr/scripts/waybar-launch.sh >/dev/null 2>&1 &
mako >/dev/null 2>&1 &
hyprctl reload >/dev/null 2>&1 || true

notify-send "Hypr UI" "Safe reset complete"
