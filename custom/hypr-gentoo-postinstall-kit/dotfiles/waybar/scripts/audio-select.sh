#!/usr/bin/env bash
set -euo pipefail

mode="${1:-sink}" # sink | source

if ! command -v wpctl >/dev/null 2>&1; then
  notify-send "Audio" "wpctl not found"
  exit 0
fi

if ! command -v wofi >/dev/null 2>&1; then
  notify-send "Audio" "wofi not found"
  exit 0
fi

case "$mode" in
  sink)
    title="Audio output"
    target="sink"
    list="$(wpctl status | awk '
      /Sinks:/ {in_sec=1; next}
      /Sources:/ {in_sec=0}
      in_sec {
        line=$0
        if (match(line, /^[[:space:][:punct:]]*[0-9]+\./)) {
          id=substr(line, RSTART, RLENGTH-1)
          gsub(/[^0-9]/, "", id)
          desc=substr(line, RSTART + RLENGTH)
          gsub(/^[[:space:]|*]+/, "", desc)
          sub(/[[:space:]]*\[.*$/, "", desc)
          sub(/[[:space:]]*<.*$/, "", desc)
          if (desc == "") desc="Audio device " id
          print id "  " desc
        }
      }')"
    ;;
  source)
    title="Audio input"
    target="source"
    list="$(wpctl status | awk '
      /Sources:/ {in_sec=1; next}
      /Source endpoints:/ {in_sec=0}
      in_sec {
        line=$0
        if (match(line, /^[[:space:][:punct:]]*[0-9]+\./)) {
          id=substr(line, RSTART, RLENGTH-1)
          gsub(/[^0-9]/, "", id)
          desc=substr(line, RSTART + RLENGTH)
          gsub(/^[[:space:]|*]+/, "", desc)
          sub(/[[:space:]]*\[.*$/, "", desc)
          sub(/[[:space:]]*<.*$/, "", desc)
          if (desc == "") desc="Audio device " id
          print id "  " desc
        }
      }')"
    ;;
  *)
    notify-send "Audio" "Usage: audio-select.sh sink|source"
    exit 1
    ;;
esac

[ -n "${list:-}" ] || {
  notify-send "Audio" "No ${target} devices found"
  exit 0
}

pick="$(printf '%s\n' "$list" | wofi --dmenu --prompt "$title" --width 760 --height 420)"
[ -n "${pick:-}" ] || exit 0

id="$(printf '%s' "$pick" | awk '{print $1}')"
[ -n "$id" ] || exit 0

wpctl set-default "$id"
notify-send "Audio" "Default ${target} set to ID $id"
