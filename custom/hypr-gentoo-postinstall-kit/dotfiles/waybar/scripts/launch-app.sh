#!/usr/bin/env bash
set -euo pipefail

app="${1:-}"

run_first() {
  for cmd in "$@"; do
    bin="${cmd%% *}"
    if command -v "$bin" >/dev/null 2>&1; then
      # Launch detached so Waybar does not block.
      nohup sh -lc "$cmd" >/dev/null 2>&1 &
      exit 0
    fi
  done
  notify-send "Launcher" "No command found for: $app"
  exit 1
}

case "$app" in
  firefox)
    run_first "firefox"
    ;;
  thunar)
    run_first "thunar"
    ;;
  dolphin)
    run_first "dolphin"
    ;;
  kitty)
    run_first "kitty"
    ;;
  code)
    run_first "cursor" "code" "code-oss" "codium"
    ;;
  steam)
    run_first "steam"
    ;;
  scanner)
    run_first "simple-scan" "xsane" "hp-toolbox"
    ;;
  obs)
    run_first "obs" "obs-studio"
    ;;
  zoom)
    run_first "zoom" "zoom-us"
    ;;
  *)
    notify-send "Launcher" "Unknown launcher: $app"
    exit 1
    ;;
esac
