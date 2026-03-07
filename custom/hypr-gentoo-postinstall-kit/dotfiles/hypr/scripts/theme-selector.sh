#!/usr/bin/env bash
set -euo pipefail

logfile="${XDG_CACHE_HOME:-$HOME/.cache}/theme-selector.log"

if [ "${1:-}" != "" ]; then
  theme="$1"
else
  theme="$(printf "Tokyo Night\nCatppuccin Mocha\nGruvbox Dark\nAylur Space\nAurora (Flicko)\nPacman Rice\n" | wofi --dmenu --prompt "Theme" --width 360 --height 340)"
fi
theme="$(printf "%s" "${theme:-}" | sed 's/[[:space:]]*$//')"
[ -n "${theme:-}" ] || exit 0

case "$theme" in
  "Tokyo Night"|*"Tokyo"*)
    BG="rgba(26, 27, 38, 0.88)"; FG="#c0caf5"; ACC="#7aa2f7"; SUB="#9aa5ce"
    ;;
  "Catppuccin Mocha"|*"Catppuccin"*)
    BG="rgba(30, 30, 46, 0.88)"; FG="#cdd6f4"; ACC="#89b4fa"; SUB="#a6adc8"
    ;;
  "Gruvbox Dark"|*"Gruvbox"*)
    BG="rgba(40, 40, 40, 0.90)"; FG="#ebdbb2"; ACC="#83a598"; SUB="#a89984"
    ;;
  "Aylur Space"|*"Aylur"*|*"Space"*)
    # Inspired by Aylur's "Space" theme (ags-pre-ts branch).
    BG="rgba(23, 23, 23, 0.88)"; FG="#e6e6e6"; ACC="#9077e7"; SUB="#b9afea"
    ;;
  "Aurora (Flicko)"|*"Aurora"*|*"Flicko"*)
    # Inspired by flickowoa aurora palette.
    BG="rgba(17, 17, 27, 0.90)"; FG="#cdd6f4"; ACC="#89b4fa"; SUB="#b4befe"
    ;;
  "Pacman Rice"|*"Pacman"*|*"Rice"*)
    # Retro colorful preset inspired by pacman-themed bars.
    BG="rgba(26, 27, 38, 0.90)"; FG="#c0caf5"; ACC="#e0af68"; SUB="#7aa2f7"
    ;;
  *) exit 0 ;;
esac

THEME_CSS="$HOME/.config/waybar/theme.css"
TMP="$THEME_CSS.new"
BAK="$THEME_CSS.bak"
WB_CFG="$HOME/.config/waybar/config"
WB_STYLE="$HOME/.config/waybar/style.css"
WB_CFG_BAK="$HOME/.config/waybar/config.bak.theme-switch"
WB_STYLE_BAK="$HOME/.config/waybar/style.css.bak.theme-switch"
PRESET_CFG="$HOME/.config/waybar/config.default"
PRESET_STYLE="$HOME/.config/waybar/style.default.css"

case "$theme" in
  "Aylur Space"|*"Aylur"*|*"Space"*)
    PRESET_CFG="$HOME/.config/waybar/config.aylur-space"
    PRESET_STYLE="$HOME/.config/waybar/style.aylur-space.css"
    ;;
  "Aurora (Flicko)"|*"Aurora"*|*"Flicko"*)
    PRESET_CFG="$HOME/.config/waybar/config.aurora"
    PRESET_STYLE="$HOME/.config/waybar/style.aurora.css"
    ;;
  "Pacman Rice"|*"Pacman"*|*"Rice"*)
    PRESET_CFG="$HOME/.config/waybar/config.pacman"
    PRESET_STYLE="$HOME/.config/waybar/style.pacman.css"
    ;;
esac

printf '[%s] selected="%s" preset_cfg="%s" preset_style="%s"\n' \
  "$(date '+%F %T')" "$theme" "$PRESET_CFG" "$PRESET_STYLE" >>"$logfile"

cp -f "$THEME_CSS" "$BAK" 2>/dev/null || true
cp -f "$WB_CFG" "$WB_CFG_BAK" 2>/dev/null || true
cp -f "$WB_STYLE" "$WB_STYLE_BAK" 2>/dev/null || true

cat > "$TMP" <<CSS
#workspaces, #window, #custom-gentoo, #custom-tec, #custom-usb, #custom-network, #custom-audio, #custom-monitor, #clock {
  background: ${BG};
  color: ${FG};
  border: 1px solid ${ACC};
}
#workspaces button { color: ${SUB}; }
#workspaces button.active { color: ${ACC}; background: transparent; }
tooltip { background: ${BG}; color: ${FG}; border: 1px solid ${ACC}; }
CSS

mv "$TMP" "$THEME_CSS"

if [ -f "$PRESET_CFG" ]; then
  cp -f "$PRESET_CFG" "$WB_CFG"
fi
if [ -f "$PRESET_STYLE" ]; then
  cp -f "$PRESET_STYLE" "$WB_STYLE"
fi

# Light matching for wofi+mako
cat > "$HOME/.config/wofi/style.css" <<CSS
* { font-family: "JetBrainsMono Nerd Font", "Noto Sans"; font-size: 14px; }
window { background-color: ${BG}; border: 2px solid ${ACC}; border-radius: 12px; }
#input { margin: 10px; padding: 10px; border: none; border-radius: 8px; background: #11111b; color: ${FG}; }
#inner-box { margin: 0 10px 10px 10px; background: transparent; }
#entry { padding: 8px; border-radius: 8px; color: ${FG}; }
#entry:selected { background: ${ACC}33; }
CSS

cat > "$HOME/.config/mako/config" <<CFG
font=JetBrainsMono Nerd Font 10
background-color=${BG}
text-color=${FG}ff
border-color=${ACC}ff
border-size=2
border-radius=10
padding=12
default-timeout=5000
anchor=top-right
margin=12
width=380
max-visible=5
CFG

# Apply new files by restarting only waybar.
pkill -x waybar 2>/dev/null || true

# If launcher loop is missing, start it once.
if ! pgrep -f "/home/edo/.config/hypr/scripts/waybar-launch.sh" >/dev/null 2>&1; then
  "$HOME/.config/hypr/scripts/waybar-launch.sh" >/dev/null 2>&1 &
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if pgrep -x waybar >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if ! pgrep -x waybar >/dev/null 2>&1; then
  printf '[%s] WARN no waybar after restart; keeping selected files\n' "$(date '+%F %T')" >>"$logfile"
  notify-send "Theme applied (partial)" "Files switched, but Waybar restart needs manual reset" || true
fi

pkill -x mako 2>/dev/null || true
mako >/dev/null 2>&1 &
notify-send "Theme applied" "$theme" || true
