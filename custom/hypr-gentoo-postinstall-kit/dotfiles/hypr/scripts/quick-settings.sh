#!/usr/bin/env bash
set -euo pipefail

menu() {
  printf "  Wi-Fi toggle\n  Wi-Fi connect\n  Audio sink\n  TEC restart\n  Next wallpaper\n󰉔  Wallpaper selector\n"
}

pick="$(menu | wofi --dmenu --prompt "Quick Settings" --width 460 --height 360)"
[ -n "${pick:-}" ] || exit 0

case "$pick" in
  "  Wi-Fi toggle")
    if command -v nmcli >/dev/null 2>&1; then
      state="$(nmcli radio wifi)"
      if [ "$state" = "enabled" ]; then
        nmcli radio wifi off && notify-send "Wi-Fi" "Disabled"
      else
        nmcli radio wifi on && notify-send "Wi-Fi" "Enabled"
      fi
    else
      notify-send "Quick Settings" "nmcli not found"
    fi
    ;;

  "  Wi-Fi connect")
    if ! command -v nmcli >/dev/null 2>&1; then
      notify-send "Quick Settings" "nmcli not found"
      exit 0
    fi

    # Show ssid + signal, deduplicated by SSID
    net="$(nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list | awk -F: '
      length($1)>0 { if (!seen[$1] || $2 > best[$1]) { best[$1]=$2; sec[$1]=$3; seen[$1]=1 } }
      END { for (s in seen) printf "%s  (%s%%)  [%s]\n", s, best[s], sec[s] }
    ' | sort | wofi --dmenu --prompt "Select Wi-Fi" --width 640 --height 420)"
    [ -n "${net:-}" ] || exit 0

    ssid="$(printf '%s' "$net" | sed -E 's/  \(.+$//')"
    [ -n "$ssid" ] || exit 0

    # If secured, ask password via wofi dmenu
    sec="$(nmcli -t -f SSID,SECURITY dev wifi list | awk -F: -v s="$ssid" '$1==s {print $2; exit}')"
    if [ -n "$sec" ] && [ "$sec" != "--" ]; then
      pass="$(printf "" | wofi --dmenu --password --prompt "Password for $ssid" --width 480 --height 120)"
      [ -n "${pass:-}" ] || exit 0
      if nmcli dev wifi connect "$ssid" password "$pass" >/tmp/qs-wifi.log 2>&1; then
        notify-send "Wi-Fi" "Connected to $ssid"
      else
        notify-send "Wi-Fi" "Failed to connect $ssid"
      fi
    else
      if nmcli dev wifi connect "$ssid" >/tmp/qs-wifi.log 2>&1; then
        notify-send "Wi-Fi" "Connected to $ssid"
      else
        notify-send "Wi-Fi" "Failed to connect $ssid"
      fi
    fi
    ;;

  "  Audio sink")
    if ! command -v wpctl >/dev/null 2>&1; then
      notify-send "Quick Settings" "wpctl not found"
      exit 0
    fi

    # Build sink list: "ID  Name"
    sinks="$(wpctl status | awk '
      /Sinks:/ {in_sinks=1; next}
      /Sources:/ {in_sinks=0}
      in_sinks && $1 ~ /^[0-9]+\./ {
        id=$1; gsub(/\./, "", id)
        $1=""
        sub(/^ +/, "", $0)
        print id "  " $0
      }'
    )"

    pick_sink="$(printf '%s\n' "$sinks" | wofi --dmenu --prompt "Audio sink" --width 760 --height 420)"
    [ -n "${pick_sink:-}" ] || exit 0
    sink_id="$(printf '%s' "$pick_sink" | awk '{print $1}')"
    [ -n "$sink_id" ] || exit 0

    wpctl set-default "$sink_id"
    notify-send "Audio" "Default sink set to ID $sink_id"
    ;;

  "  TEC restart")
    /usr/local/bin/tec-restart >/tmp/qs-tec.log 2>&1 || true
    notify-send "TEC" "Restart command sent"
    ;;

  "  Next wallpaper")
    ~/.config/hypr/scripts/wall-next.sh >/tmp/qs-wall.log 2>&1 || true
    ;;

  "󰉔  Wallpaper selector")
    ~/.config/hypr/scripts/wall-selector.sh >/tmp/qs-wall-selector.log 2>&1 || true
    ;;
esac
