#!/usr/bin/env bash
set -euo pipefail

KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOTFILES_DIR="${KIT_DIR}/dotfiles"
STAMP="$(date +%Y%m%d-%H%M%S)"
WITH_TEC=0
MACHINE_PROFILE="auto"
LAUNCHER_COUNT=5
LAUNCHER_APPS="firefox,steam,scanner,obs,zoom"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-tec)
      WITH_TEC=1
      shift
      ;;
    --machine)
      MACHINE_PROFILE="${2:-auto}"
      shift 2
      ;;
    --launchers)
      LAUNCHER_COUNT="${2:-5}"
      shift 2
      ;;
    --launcher-apps)
      LAUNCHER_APPS="${2:-firefox,steam,scanner,obs,zoom}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: ./scripts/02-user-setup.sh [--with-tec] [--machine auto|desktop|laptop] [--launchers 3|5] [--launcher-apps app1,app2,...]"
      exit 1
      ;;
  esac
done

if [[ "${MACHINE_PROFILE}" != "auto" && "${MACHINE_PROFILE}" != "desktop" && "${MACHINE_PROFILE}" != "laptop" ]]; then
  echo "Invalid --machine value: ${MACHINE_PROFILE}"
  echo "Use one of: auto, desktop, laptop"
  exit 1
fi

if [[ "${LAUNCHER_COUNT}" != "3" && "${LAUNCHER_COUNT}" != "5" ]]; then
  echo "Invalid --launchers value: ${LAUNCHER_COUNT}"
  echo "Use one of: 3, 5"
  exit 1
fi

detect_machine_profile() {
  if compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1; then
    echo "laptop"
    return
  fi
  if [[ -r /sys/devices/virtual/dmi/id/chassis_type ]]; then
    case "$(tr -d '\n' < /sys/devices/virtual/dmi/id/chassis_type)" in
      8|9|10|14) echo "laptop"; return ;;
    esac
  fi
  echo "desktop"
}

if [[ "${MACHINE_PROFILE}" == "auto" ]]; then
  MACHINE_PROFILE="$(detect_machine_profile)"
fi

backup_path() {
  local target="$1"
  if [[ -e "${target}" ]]; then
    mv "${target}" "${target}.bak.${STAMP}"
    echo "  backed up ${target} -> ${target}.bak.${STAMP}"
  fi
}

copy_tree() {
  local src="$1"
  local dst="$2"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${src}/" "${dst}/"
  else
    rm -rf "${dst}"
    mkdir -p "${dst}"
    cp -a "${src}/." "${dst}/"
  fi
}

echo "==> Creating base config folders"
mkdir -p "${HOME}/.config" "${HOME}/.cache"

if [[ -d "${DOTFILES_DIR}/hypr" ]]; then
  echo "==> Installing hypr config"
  backup_path "${HOME}/.config/hypr"
  mkdir -p "${HOME}/.config/hypr"
  copy_tree "${DOTFILES_DIR}/hypr" "${HOME}/.config/hypr"
fi

for app in waybar wofi mako kitty; do
  if [[ -d "${DOTFILES_DIR}/${app}" ]]; then
    echo "==> Installing ${app} config"
    backup_path "${HOME}/.config/${app}"
    mkdir -p "${HOME}/.config/${app}"
    copy_tree "${DOTFILES_DIR}/${app}" "${HOME}/.config/${app}"
  fi
done

if [[ -d "${HOME}/.config/waybar/scripts" ]]; then
  chmod +x "${HOME}/.config/waybar/scripts/"*.sh 2>/dev/null || true
fi
if [[ -d "${HOME}/.config/hypr/scripts" ]]; then
  chmod +x "${HOME}/.config/hypr/scripts/"*.sh 2>/dev/null || true
fi

echo "==> Applying hardware-aware waybar profile"
WAYBAR_CFG="${HOME}/.config/waybar/config"
if [[ -f "${WAYBAR_CFG}" ]] && command -v jq >/dev/null 2>&1; then
  # Build launcher app list (user choices + defaults, deduplicated, capped to 3 or 5).
  declare -a ORDERED_DEFAULT_APPS=(firefox steam scanner obs zoom thunar kitty dolphin code)
  declare -A APP_ICON=(
    [firefox]="󰈹"
    [steam]=""
    [scanner]="󰚫"
    [obs]="󰐾"
    [zoom]="󰬇"
    [thunar]="󰝰"
    [kitty]=""
    [dolphin]="󰉋"
    [code]=""
  )
  declare -A APP_TOOLTIP=(
    [firefox]="Firefox"
    [steam]="Steam"
    [scanner]="HP Scanner"
    [obs]="OBS Studio"
    [zoom]="Zoom"
    [thunar]="Thunar"
    [kitty]="Kitty"
    [dolphin]="Dolphin"
    [code]="Code"
  )

  declare -A seen_apps=()
  declare -a chosen_apps=()
  IFS=',' read -r -a requested_apps <<<"${LAUNCHER_APPS}"
  for raw in "${requested_apps[@]}"; do
    app="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | xargs)"
    [ -z "${app:-}" ] && continue
    [ -n "${APP_ICON[$app]+x}" ] || continue
    [ -n "${seen_apps[$app]+x}" ] && continue
    chosen_apps+=("$app")
    seen_apps[$app]=1
  done
  for app in "${ORDERED_DEFAULT_APPS[@]}"; do
    [ "${#chosen_apps[@]}" -ge "${LAUNCHER_COUNT}" ] && break
    [ -n "${seen_apps[$app]+x}" ] && continue
    chosen_apps+=("$app")
    seen_apps[$app]=1
  done
  if [ "${#chosen_apps[@]}" -lt "${LAUNCHER_COUNT}" ]; then
    echo "Unable to resolve ${LAUNCHER_COUNT} launcher apps. Check --launcher-apps values."
    exit 1
  fi

  LAUNCH_JSON="$(mktemp)"
  {
    printf '{\n  "modules_left_prefix": ['
    for i in "${!chosen_apps[@]}"; do
      app="${chosen_apps[$i]}"
      [ "$i" -gt 0 ] && printf ', '
      printf '"custom/launch-%s"' "$app"
    done
    printf '],\n  "launcher_defs": {\n'
    for i in "${!chosen_apps[@]}"; do
      app="${chosen_apps[$i]}"
      [ "$i" -gt 0 ] && printf ',\n'
      printf '    "custom/launch-%s": {"format":"%s","tooltip":"%s","on-click":"~/.config/waybar/scripts/launch-app.sh %s"}' \
        "$app" "${APP_ICON[$app]}" "${APP_TOOLTIP[$app]}" "$app"
    done
    printf '\n  }\n}\n'
  } > "${LAUNCH_JSON}"

  TMP_CFG="$(mktemp)"
  jq --arg machine "${MACHINE_PROFILE}" --argjson with_tec "${WITH_TEC}" --slurpfile launch "${LAUNCH_JSON}" '
    def norm_separators:
      reduce .[] as $i
        ([];
          if ($i == "custom/separator" and ((length == 0) or (.[-1] == "custom/separator")))
          then .
          else . + [$i]
          end
        )
      | if (length > 0 and .[-1] == "custom/separator") then .[0:length-1] else . end;
    def trim_leading_separators:
      reduce .[] as $i ([]; if ($i=="custom/separator" and length==0) then . else . + [$i] end);
    def insert_after(arr; needle; item):
      if (arr | index(item)) != null then arr
      elif (arr | index(needle)) == null then arr + [item]
      else
        (arr | index(needle)) as $idx
        | (arr[0:$idx+1] + [item] + arr[$idx+1:])
      end;
    def without_launchers:
      map(select((startswith("custom/launch-") | not)));

    with_entries(select(.key | startswith("custom/launch-") | not))
    | . + ($launch[0].launcher_defs)
    | .["modules-left"] = (
        ($launch[0].modules_left_prefix + ["custom/separator"] + ((.["modules-left"] // []) | without_launchers | trim_leading_separators))
        | norm_separators
      )
    | if $with_tec == 0 then
      .["modules-right"] = ((.["modules-right"] // []) | map(select(. != "custom/tec")) | norm_separators)
      | del(.["custom/tec"])
    else
      .
    end
    | .["custom/bluetooth"] = (.["custom/bluetooth"] // {
        "exec": "~/.config/waybar/scripts/bluetooth-status.sh",
        "interval": 5,
        "return-type": "json",
        "on-click": "~/.config/waybar/scripts/bluetooth-menu.sh"
      })
    | if $machine == "laptop" then
        .["battery"] = (.["battery"] // {
          "states": {"warning": 30, "critical": 15},
          "format": "{capacity}% {icon}",
          "format-charging": "{capacity}% 󰂄",
          "format-plugged": "{capacity}% ",
          "format-icons": ["󰁺","󰁻","󰁼","󰁽","󰁾","󰁿","󰂀","󰂁","󰂂","󰁹"]
        })
        | .["modules-right"] = ((.["modules-right"] // [])
            | map(select(. != "battery" and . != "custom/bluetooth"))
            | insert_after(.; "custom/network"; "custom/bluetooth")
            | (["battery","custom/separator"] + .)
            | norm_separators)
      else
        .
      end
  ' "${WAYBAR_CFG}" > "${TMP_CFG}" && mv "${TMP_CFG}" "${WAYBAR_CFG}"
  rm -f "${LAUNCH_JSON}"
  echo "  machine profile: ${MACHINE_PROFILE}, TEC enabled: ${WITH_TEC}, launchers: ${LAUNCHER_COUNT} (${chosen_apps[*]})"
fi

echo "==> Ensuring fallback polkit launcher exists"
mkdir -p "${HOME}/.config/hypr/scripts"
cat > "${HOME}/.config/hypr/scripts/start-polkit-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -x /usr/libexec/polkit-kde-authentication-agent-1 ]; then
  /usr/libexec/polkit-kde-authentication-agent-1 >/dev/null 2>&1 &
elif [ -x /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 ]; then
  /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 >/dev/null 2>&1 &
elif command -v lxqt-policykit-agent >/dev/null 2>&1; then
  lxqt-policykit-agent >/dev/null 2>&1 &
elif command -v mate-polkit >/dev/null 2>&1; then
  mate-polkit >/dev/null 2>&1 &
fi
EOF
chmod +x "${HOME}/.config/hypr/scripts/start-polkit-agent.sh"

echo "==> Ensuring key exec-once lines exist"
mkdir -p "${HOME}/.config/hypr/conf"
EXEC_CONF="${HOME}/.config/hypr/conf/exec.conf"
touch "${EXEC_CONF}"

ensure_line() {
  local line="$1"
  if ! rg -Fxq "${line}" "${EXEC_CONF}"; then
    printf '%s\n' "${line}" >> "${EXEC_CONF}"
  fi
}

ensure_line "exec-once = ~/.config/hypr/scripts/start-polkit-agent.sh"
ensure_line "exec-once = ~/.config/hypr/scripts/waybar-launch.sh"
ensure_line "exec-once = mako"
ensure_line "exec-once = thunar --daemon"

echo "==> Setting Thunar as default file manager"
mkdir -p "${HOME}/.config"
MIMEAPPS="${HOME}/.config/mimeapps.list"
if [[ ! -f "${MIMEAPPS}" ]]; then
  cat > "${MIMEAPPS}" <<'EOF'
[Default Applications]
inode/directory=thunar.desktop
x-scheme-handler/trash=thunar.desktop
EOF
else
  if rg -q '^\[Default Applications\]' "${MIMEAPPS}"; then
    if rg -q '^inode/directory=' "${MIMEAPPS}"; then
      sed -i 's|^inode/directory=.*|inode/directory=thunar.desktop|' "${MIMEAPPS}"
    else
      sed -i '/^\[Default Applications\]/a inode/directory=thunar.desktop' "${MIMEAPPS}"
    fi
    if rg -q '^x-scheme-handler/trash=' "${MIMEAPPS}"; then
      sed -i 's|^x-scheme-handler/trash=.*|x-scheme-handler/trash=thunar.desktop|' "${MIMEAPPS}"
    else
      sed -i '/^\[Default Applications\]/a x-scheme-handler/trash=thunar.desktop' "${MIMEAPPS}"
    fi
  else
    cat >> "${MIMEAPPS}" <<'EOF'

[Default Applications]
inode/directory=thunar.desktop
x-scheme-handler/trash=thunar.desktop
EOF
  fi
fi

if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default thunar.desktop inode/directory >/dev/null 2>&1 || true
fi

echo
echo "User setup completed."
echo "Next: run scripts/03-verify.sh"
