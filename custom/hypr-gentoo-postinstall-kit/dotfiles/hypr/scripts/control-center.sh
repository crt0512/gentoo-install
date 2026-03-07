#!/usr/bin/env bash
set -euo pipefail

WOFI_STYLE="$HOME/.config/wofi/control-center-style.css"

cc_notify() {
  notify-send "Control Center" "$1" >/dev/null 2>&1 || true
}

pick_from_map() {
  local prompt="$1"
  local width="$2"
  local height="$3"
  local map_file="$4"
  local selection entry action payload

  selection="$(cut -f1 "$map_file" | wofi --dmenu --prompt "$prompt" --width "$width" --height "$height" --style "$WOFI_STYLE")"
  [ -n "${selection:-}" ] || return 1

  entry="$(awk -F '\t' -v sel="$selection" '$1 == sel {print; exit}' "$map_file")"
  [ -n "$entry" ] || return 1
  action="$(printf '%s' "$entry" | cut -f2)"
  payload="$(printf '%s' "$entry" | cut -f3-)"
  printf '%s\t%s\n' "$action" "$payload"
}

add_item() {
  local line="$1"
  local action="$2"
  local payload="${3:-}"
  printf '%s\t%s\t%s\n' "$line" "$action" "$payload" >>"$MAP_FILE"
}

wifi_badge() {
  if ! command -v nmcli >/dev/null 2>&1; then
    printf 'N/A'
    return
  fi

  local wifi_state ssid
  wifi_state="$(nmcli radio wifi 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
  ssid="$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1=="yes" && length($2)>0 {print $2; exit}' || true)"

  if [ "$wifi_state" = "enabled" ] && [ -n "$ssid" ]; then
    printf 'ON · %s' "$ssid"
  elif [ "$wifi_state" = "enabled" ]; then
    printf 'ON'
  elif [ "$wifi_state" = "disabled" ]; then
    printf 'OFF'
  else
    printf 'UNKNOWN'
  fi
}

audio_badge() {
  if ! command -v wpctl >/dev/null 2>&1; then
    printf 'N/A'
    return
  fi

  local sink_raw sink_pct
  sink_raw="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)"
  [ -n "$sink_raw" ] || {
    printf 'N/A'
    return
  }

  sink_pct="$(printf '%s' "$sink_raw" | awk '{print int($2*100)}' 2>/dev/null || echo 0)"
  if printf '%s' "$sink_raw" | grep -q 'MUTED'; then
    printf '%s%% · MUTED' "$sink_pct"
  else
    printf '%s%%' "$sink_pct"
  fi
}

source_badge() {
  if ! command -v wpctl >/dev/null 2>&1; then
    printf 'N/A'
    return
  fi

  local src_raw src_pct
  src_raw="$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null || true)"
  [ -n "$src_raw" ] || {
    printf 'N/A'
    return
  }

  src_pct="$(printf '%s' "$src_raw" | awk '{print int($2*100)}' 2>/dev/null || echo 0)"
  if printf '%s' "$src_raw" | grep -q 'MUTED'; then
    printf '%s%% · MUTED' "$src_pct"
  else
    printf '%s%%' "$src_pct"
  fi
}

display_badge() {
  if ! command -v hyprctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'N/A'
    return
  fi

  local mode
  mode="$(hyprctl -j monitors 2>/dev/null | jq -r '.[] | select(.focused==true) | "\(.width)x\(.height)@\(.refreshRate|floor)"' | head -n1 || true)"
  [ -n "$mode" ] && [ "$mode" != "null" ] && printf '%s' "$mode" || printf 'N/A'
}

theme_badge() {
  local line theme
  line="$(tail -n 30 "$HOME/.cache/theme-selector.log" 2>/dev/null | grep 'selected=' | tail -n1 || true)"
  theme="$(printf '%s' "$line" | sed -n 's/.*selected="\([^"]*\)".*/\1/p')"
  [ -n "$theme" ] && printf '%s' "$theme" || printf 'Default'
}

network_preview() {
  if ! command -v nmcli >/dev/null 2>&1; then
    printf 'Unavailable'
    return
  fi

  local line ssid signal
  line="$(nmcli -t -f IN-USE,SSID,SIGNAL dev wifi list 2>/dev/null | awk -F: '$1=="*" && length($2)>0 {print $2 ":" $3; exit}' || true)"
  ssid="$(printf '%s' "$line" | cut -d: -f1)"
  signal="$(printf '%s' "$line" | cut -d: -f2)"

  if [ -n "$ssid" ] && [ -n "$signal" ]; then
    printf '%s (%s%%)' "$ssid" "$signal"
    return
  fi

  ssid="$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="wifi" {print $1; exit}' || true)"
  [ -n "$ssid" ] && printf '%s' "$ssid" || printf 'Not connected'
}

audio_output_name() {
  if ! command -v wpctl >/dev/null 2>&1; then
    printf 'Unavailable'
    return
  fi

  local sink
  sink="$(wpctl status 2>/dev/null | awk '
    /Sinks:/ {in_sinks=1; next}
    /Sources:/ {in_sinks=0}
    in_sinks && /\*/ {
      line=$0
      sub(/^.*\* /, "", line)
      sub(/[[:space:]]*\[.*$/, "", line)
      sub(/[[:space:]]*<.*$/, "", line)
      print line
      exit
    }' || true)"
  [ -n "$sink" ] && printf '%s' "$sink" || printf 'Default sink'
}

audio_input_name() {
  if ! command -v wpctl >/dev/null 2>&1; then
    printf 'Unavailable'
    return
  fi

  local src
  src="$(wpctl status 2>/dev/null | awk '
    /Sources:/ {in_sources=1; next}
    /Source endpoints:/ {in_sources=0}
    in_sources && /\*/ {
      line=$0
      sub(/^.*\* /, "", line)
      sub(/[[:space:]]*\[.*$/, "", line)
      sub(/[[:space:]]*<.*$/, "", line)
      print line
      exit
    }' || true)"
  [ -n "$src" ] && printf '%s' "$src" || printf 'Default source'
}

display_preview() {
  if ! command -v hyprctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'Unavailable'
    return
  fi

  local preview
  preview="$(hyprctl -j monitors 2>/dev/null | jq -r '.[] | select(.focused==true) | "\(.name) · \(.width)x\(.height)@\(.refreshRate|floor) · x\(.scale)"' | head -n1 || true)"
  [ -n "$preview" ] && [ "$preview" != "null" ] && printf '%s' "$preview" || printf 'No focused monitor'
}

brightness_badge() {
  if ! command -v brightnessctl >/dev/null 2>&1; then
    printf 'N/A'
    return
  fi

  local cur max
  cur="$(brightnessctl g 2>/dev/null || true)"
  max="$(brightnessctl m 2>/dev/null || true)"
  if [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null; then
    printf '%s%%' "$((100 * cur / max))"
  else
    printf 'N/A'
  fi
}

open_main_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_main() { rm -f "$MAP_FILE"; }
  trap cleanup_main RETURN

  local net_stat aud_stat dsp_stat thm_stat
  net_stat="$(wifi_badge)"
  aud_stat="$(audio_badge)"
  dsp_stat="$(display_badge)"
  thm_stat="$(theme_badge)"

  add_item "󰀻  Unified Control Center" "noop"
  add_item "────────────────────────────" "noop"
  add_item "󰖩  Network         · ${net_stat}" "open_network"
  add_item "󰕾  Audio Controls  · ${aud_stat}" "open_audio"
  add_item "󰍰  Audio Devices   · sink/source" "open_audio_devices"
  add_item "󰍹  Display         · ${dsp_stat}" "open_display"
  add_item "󰸉  Theme           · ${thm_stat}" "open_theme"
  add_item "  Power           · lock/exit/menu" "open_power"
  add_item "󱁤  Quick Settings  · shortcuts" "quick_settings"
  add_item "  Next wallpaper" "wall_next"
  add_item "󰉔  Wallpaper selector" "wall_selector"
  add_item "♻  Safe UI reset" "safe_reset"

  pick_from_map "Control Center" 640 560 "$MAP_FILE" || return 1
}

open_network_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_network() { rm -f "$MAP_FILE"; }
  trap cleanup_network RETURN

  wifi_state="unknown"
  if command -v nmcli >/dev/null 2>&1; then
    wifi_state="$(nmcli radio wifi 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
  fi
  [ -z "$wifi_state" ] && wifi_state="unknown"

  add_item "󰖩  Network sub-menu  · $(wifi_badge)" "noop"
  add_item "󰇚  Connected: $(network_preview)" "noop"
  add_item "────────────────────────────" "noop"
  add_item "󰈀  Open advanced network panel" "net_panel"
  if [ "$wifi_state" = "enabled" ]; then
    add_item "󰤨  Toggle Wi-Fi OFF" "wifi_off"
  else
    add_item "󰤭  Toggle Wi-Fi ON" "wifi_on"
  fi
  add_item "  Connect to Wi-Fi" "wifi_connect"
  add_item "󰲜  Toggle internet on/off" "internet_toggle"

  pick_from_map "Network" 620 460 "$MAP_FILE" || return 1
}

open_audio_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_audio() { rm -f "$MAP_FILE"; }
  trap cleanup_audio RETURN

  add_item "󰕾  Audio controls  · $(audio_badge)" "noop"
  add_item "󰓃  Output: $(audio_output_name)" "noop"
  add_item "󰍬  Input:  $(audio_input_name)" "noop"
  add_item "────────────────────────────" "noop"
  add_item "󰕾  Open advanced audio panel" "audio_panel"
  add_item "  Speaker volume +5%" "sink_up"
  add_item "  Speaker volume -5%" "sink_down"
  add_item "  Toggle speaker mute" "sink_mute"
  add_item "  Mic gain +5%" "src_up"
  add_item "  Mic gain -5%" "src_down"
  add_item "  Toggle mic mute" "src_mute"

  pick_from_map "Audio Controls" 620 560 "$MAP_FILE" || return 1
}

open_audio_devices_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_audio_dev() { rm -f "$MAP_FILE"; }
  trap cleanup_audio_dev RETURN

  add_item "󰍰  Audio devices" "noop"
  add_item "󰓃  Current output: $(audio_output_name)" "noop"
  add_item "󰍬  Current input:  $(audio_input_name)" "noop"
  add_item "────────────────────────────" "noop"
  add_item "󰓃  Select output device (sink)" "sink_select"
  add_item "󰍬  Select input device (source)" "source_select"

  pick_from_map "Audio Devices" 620 300 "$MAP_FILE" || return 1
}

open_display_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_display() { rm -f "$MAP_FILE"; }
  trap cleanup_display RETURN

  add_item "󰍹  Display controls  · $(display_badge)" "noop"
  add_item "󰍹  Focused: $(display_preview)" "noop"
  add_item "────────────────────────────" "noop"
  add_item "󰍺  Open advanced display panel" "display_panel"
  add_item "󰃞  Brightness -10%" "bright_down"
  add_item "󰃠  Brightness +10%" "bright_up"

  pick_from_map "Display" 620 360 "$MAP_FILE" || return 1
}

open_theme_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_theme() { rm -f "$MAP_FILE"; }
  trap cleanup_theme RETURN

  add_item "󰸉  Theme presets  · $(theme_badge)" "noop"
  add_item "────────────────────────────" "noop"
  add_item "󰔎  Tokyo Night" "theme" "Tokyo Night"
  add_item "  Catppuccin Mocha" "theme" "Catppuccin Mocha"
  add_item "󰋚  Gruvbox Dark" "theme" "Gruvbox Dark"
  add_item "󰔎  Aylur Space" "theme" "Aylur Space"
  add_item "󰔎  Aurora (Flicko)" "theme" "Aurora (Flicko)"
  add_item "󰮯  Pacman Rice" "theme" "Pacman Rice"

  pick_from_map "Theme" 620 520 "$MAP_FILE" || return 1
}

open_power_menu() {
  MAP_FILE="$(mktemp)"
  cleanup_power() { rm -f "$MAP_FILE"; }
  trap cleanup_power RETURN

  add_item "  Power options" "noop"
  add_item "────────────────────────────" "noop"
  add_item "  Lock screen" "lock"
  add_item "󰍃  Exit Hyprland" "exit"
  add_item "  Open power menu" "power_menu"

  pick_from_map "Power" 620 320 "$MAP_FILE" || return 1
}

picked="$(open_main_menu || true)"
[ -n "${picked:-}" ] || exit 0

action="$(printf '%s' "$picked" | cut -f1)"
payload="$(printf '%s' "$picked" | cut -f2-)"

case "$action" in
  open_network) picked="$(open_network_menu || true)" ;;
  open_audio) picked="$(open_audio_menu || true)" ;;
  open_audio_devices) picked="$(open_audio_devices_menu || true)" ;;
  open_display) picked="$(open_display_menu || true)" ;;
  open_theme) picked="$(open_theme_menu || true)" ;;
  open_power) picked="$(open_power_menu || true)" ;;
esac

[ -n "${picked:-}" ] || exit 0

action="$(printf '%s' "$picked" | cut -f1)"
payload="$(printf '%s' "$picked" | cut -f2-)"

case "$action" in
  net_panel)
    ~/.config/waybar/scripts/net-menu.sh
    cc_notify "Opened network panel"
    ;;
  wifi_on)
    command -v nmcli >/dev/null 2>&1 && nmcli radio wifi on || true
    cc_notify "Wi-Fi -> ON (${network_preview})"
    ;;
  wifi_off)
    command -v nmcli >/dev/null 2>&1 && nmcli radio wifi off || true
    cc_notify "Wi-Fi -> OFF"
    ;;
  wifi_connect)
    ~/.config/hypr/scripts/quick-settings.sh
    cc_notify "Network -> ${network_preview}"
    ;;
  internet_toggle)
    if command -v nmcli >/dev/null 2>&1; then
      state="$(nmcli networking connectivity 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
      if [ "$state" = "none" ] || [ "$state" = "unknown" ]; then
        nmcli networking on || true
        cc_notify "Internet -> ON"
      else
        nmcli networking off || true
        cc_notify "Internet -> OFF"
      fi
    fi
    ;;
  audio_panel)
    ~/.config/waybar/scripts/audio-menu.sh
    cc_notify "Opened audio panel"
    ;;
  sink_up)
    wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+
    cc_notify "Speaker -> $(audio_badge)"
    ;;
  sink_down)
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
    cc_notify "Speaker -> $(audio_badge)"
    ;;
  sink_mute)
    wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
    cc_notify "Speaker -> $(audio_badge)"
    ;;
  src_up)
    wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SOURCE@ 5%+
    cc_notify "Mic -> $(source_badge)"
    ;;
  src_down)
    wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 5%-
    cc_notify "Mic -> $(source_badge)"
    ;;
  src_mute)
    wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
    cc_notify "Mic -> $(source_badge)"
    ;;
  sink_select)
    ~/.config/waybar/scripts/audio-select.sh sink
    cc_notify "Output -> $(audio_output_name)"
    ;;
  source_select)
    ~/.config/waybar/scripts/audio-select.sh source
    cc_notify "Input -> $(audio_input_name)"
    ;;
  display_panel)
    ~/.config/waybar/scripts/monitor-menu.sh
    cc_notify "Opened display panel"
    ;;
  bright_down)
    ~/.config/hypr/scripts/brightness.sh down
    cc_notify "Brightness -> $(brightness_badge)"
    ;;
  bright_up)
    ~/.config/hypr/scripts/brightness.sh up
    cc_notify "Brightness -> $(brightness_badge)"
    ;;
  theme)
    ~/.config/hypr/scripts/theme-selector.sh "$payload"
    cc_notify "Theme -> $payload"
    ;;
  lock) hyprlock ;;
  exit) hyprctl dispatch exit ;;
  power_menu)
    ~/.config/hypr/scripts/power-menu.sh
    cc_notify "Opened power menu"
    ;;
  quick_settings)
    ~/.config/hypr/scripts/quick-settings.sh
    cc_notify "Opened quick settings"
    ;;
  wall_next)
    ~/.config/hypr/scripts/wall-next.sh
    cc_notify "Wallpaper -> switched"
    ;;
  wall_selector)
    ~/.config/hypr/scripts/wall-selector.sh
    cc_notify "Wallpaper -> selector opened"
    ;;
  safe_reset) ~/.config/hypr/scripts/safe-ui-reset.sh ;;
  *) exit 0 ;;
esac
