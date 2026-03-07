#!/usr/bin/env bash
set -euo pipefail

WOFI_STYLE_CAL="${HOME}/.config/waybar/menu/calendar-menu.css"
WOFI_STYLE_FALLBACK="${HOME}/.config/waybar/menu/awesome-menu.css"

if [ -f "$WOFI_STYLE_CAL" ]; then
  WOFI_STYLE="$WOFI_STYLE_CAL"
else
  WOFI_STYLE="$WOFI_STYLE_FALLBACK"
fi

if ! command -v wofi >/dev/null 2>&1; then
  notify-send "Calendar" "wofi not found" >/dev/null 2>&1 || true
  exit 0
fi

if ! command -v cal >/dev/null 2>&1; then
  notify-send "Calendar" "cal not found" >/dev/null 2>&1 || true
  exit 0
fi

month_ref="$(date +%Y-%m-01)"

render_calendar_rows() {
  local year="$1"
  local month="$2"
  local today_iso="$3"

  python - "$year" "$month" "$today_iso" <<'PY'
import calendar
import datetime
import sys

year = int(sys.argv[1])
month = int(sys.argv[2])
today = datetime.date.fromisoformat(sys.argv[3])

cal = calendar.Calendar(firstweekday=0)
print("Mo   Tu   We   Th   Fr   Sa   Su")

for week in cal.monthdayscalendar(year, month):
    cols = []
    for day in week:
        if day == 0:
            cols.append(" ·  ")
        elif year == today.year and month == today.month and day == today.day:
            cols.append(f"[{day:02d}]")
        else:
            cols.append(f" {day:02d} ")
    print(" ".join(cols))
PY
}

while :; do
  month_num="$(date -d "$month_ref" +%m)"
  year_num="$(date -d "$month_ref" +%Y)"
  title="$(date -d "$month_ref" +'%B %Y')"
  today_iso="$(date +%F)"
  today_line="$(date +'%A, %d %B %Y  •  %H:%M')"

  tmp_map="$(mktemp)"
  cleanup() { rm -f "$tmp_map"; }
  trap cleanup EXIT

  add_item() {
    local label="$1"
    local action="$2"
    printf '%s\t%s\n' "$label" "$action" >>"$tmp_map"
  }

  add_item "󰃭  ${title}" "noop"
  add_item "󰃰  ${today_line}" "noop"
  add_item "────────────────────────────────────" "noop"

  while IFS= read -r line; do
    add_item "$line" "noop"
  done < <(render_calendar_rows "$year_num" "$month_num" "$today_iso")

  add_item "────────────────────────────────────" "noop"
  add_item "󰒭  Prev month" "prev"
  add_item "󰒮  Next month" "next"
  add_item "󰁔  Jump to today" "today"
  add_item "  Close" "close"

  selection="$(cut -f1 "$tmp_map" | wofi --dmenu --prompt "  Calendar" --width 700 --height 620 --style "$WOFI_STYLE")"
  [ -n "${selection:-}" ] || exit 0

  action="$(awk -F '\t' -v sel="$selection" '$1==sel {print $2; exit}' "$tmp_map")"
  [ -n "$action" ] || exit 0

  case "$action" in
    prev) month_ref="$(date -d "$month_ref -1 month" +%Y-%m-01)" ;;
    next) month_ref="$(date -d "$month_ref +1 month" +%Y-%m-01)" ;;
    today) month_ref="$(date +%Y-%m-01)" ;;
    close) exit 0 ;;
    noop) continue ;;
    *) exit 0 ;;
  esac
done
