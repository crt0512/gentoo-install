#!/usr/bin/env bash
set -euo pipefail

if ! command -v hypridle >/dev/null 2>&1; then
  notify-send "Hypr idle" "hypridle not installed" >/dev/null 2>&1 || true
  exit 0
fi

if pgrep -x hypridle >/dev/null 2>&1; then
  exit 0
fi

hypridle >/dev/null 2>&1 &
