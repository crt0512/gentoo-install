#!/usr/bin/env bash
set -euo pipefail

# Start one available polkit agent so GUI auth prompts keep working.
if [ -x /usr/libexec/polkit-kde-authentication-agent-1 ]; then
  /usr/libexec/polkit-kde-authentication-agent-1 >/dev/null 2>&1 &
elif [ -x /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 ]; then
  /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 >/dev/null 2>&1 &
elif command -v lxqt-policykit-agent >/dev/null 2>&1; then
  lxqt-policykit-agent >/dev/null 2>&1 &
elif command -v mate-polkit >/dev/null 2>&1; then
  mate-polkit >/dev/null 2>&1 &
fi
