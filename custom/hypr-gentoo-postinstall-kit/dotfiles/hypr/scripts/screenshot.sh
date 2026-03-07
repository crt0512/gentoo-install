#!/usr/bin/env bash
set -euo pipefail

dir="${HOME}/Pictures/Screenshots"
mkdir -p "$dir"
file="$dir/Screenshot-$(date +%F_%H-%M-%S).png"

case "${1:-}" in
  region)
    if area="$(slurp)"; then
      grim -g "$area" "$file"
      wl-copy --type image/png < "$file"
      notify-send "Screenshot" "Region saved: $(basename "$file")"
    fi
    ;;
  full)
    grim "$file"
    wl-copy --type image/png < "$file"
    notify-send "Screenshot" "Full screen saved: $(basename "$file")"
    ;;
  *)
    echo "Usage: $0 {region|full}"
    exit 1
    ;;
esac
