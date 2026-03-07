#!/usr/bin/env bash
set -euo pipefail

pass() { printf 'PASS: %s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; }

check_bin() {
  local bin="$1"
  if command -v "${bin}" >/dev/null 2>&1; then
    pass "binary present: ${bin}"
  else
    warn "binary missing: ${bin}"
  fi
}

echo "==> Binary checks"
for b in Hyprland waybar wofi mako kitty hyprctl wpctl; do
  check_bin "${b}"
done

echo
echo "==> Config checks"
for f in \
  "${HOME}/.config/hypr/hyprland.conf" \
  "${HOME}/.config/hypr/conf/exec.conf" \
  "${HOME}/.config/waybar/config" \
  "${HOME}/.config/waybar/style.css"; do
  if [[ -f "${f}" ]]; then
    pass "exists: ${f}"
  else
    warn "missing: ${f}"
  fi
done

machine="desktop"
if compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1; then
  machine="laptop"
fi

if [[ -f "${HOME}/.config/hypr/conf/exec.conf" ]]; then
  if rg -Fq "start-polkit-agent.sh" "${HOME}/.config/hypr/conf/exec.conf"; then
    pass "polkit agent autostart line found"
  else
    warn "polkit agent autostart line missing"
  fi
fi

if [[ "${machine}" == "laptop" && -f "${HOME}/.config/waybar/config" ]]; then
  if rg -q '"battery"' "${HOME}/.config/waybar/config"; then
    pass "laptop battery module present in waybar config"
  else
    warn "laptop detected but battery module not found in waybar config"
  fi
  if rg -q '"custom/bluetooth"' "${HOME}/.config/waybar/config"; then
    pass "laptop bluetooth module present in waybar config"
  else
    warn "laptop detected but bluetooth module not found in waybar config"
  fi
  if command -v bluetoothctl >/dev/null 2>&1; then
    pass "bluetoothctl available"
  else
    warn "bluetoothctl missing (install net-wireless/bluez)"
  fi
fi

echo
echo "==> Runtime process checks (best effort)"
if pgrep -x Hyprland >/dev/null 2>&1; then
  pass "Hyprland process running"
else
  warn "Hyprland process not running (expected if not in session)"
fi

if pgrep -x waybar >/dev/null 2>&1; then
  pass "waybar process running"
else
  warn "waybar process not running"
fi

echo
echo "Verification complete."
