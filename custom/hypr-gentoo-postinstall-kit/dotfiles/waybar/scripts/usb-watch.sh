#!/usr/bin/env bash
set -euo pipefail

STATE="$HOME/.cache/usb-last.txt"
mkdir -p "$HOME/.cache"

friendly_name() {
  local line="${1:-}"
  local raw
  raw="$(printf '%s' "$line" | sed -E 's/^Bus [0-9]{3} Device [0-9]{3}: ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4} //')"
  local lower
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == *root\ hub* || "$lower" == *usb\ hub* || "$lower" == *\ hub* || "$lower" == *bluetooth* || "$lower" == *aura\ led* || "$lower" == *led\ controller* || "$lower" == *ax211* ]]; then
    return 1
  fi

  local model
  model="$(printf '%s' "$raw" | sed -E 's/\b(Corp\.?|Inc\.?|Ltd\.?|Co\.?|Company|Technology|Computer)\b//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
  [ -z "$model" ] && model="$raw"

  if [[ "$lower" == *printer* || "$lower" == *deskjet* || "$lower" == *laserjet* || "$lower" == *epson* || "$lower" == *canon* || "$lower" == *brother* ]]; then
    printf 'Printer · %s' "$model"
  elif [[ "$lower" == *webcam* || "$lower" == *camera* || "$lower" == *video* || "$lower" == *capture* ]]; then
    printf 'Webcam/Camera · %s' "$model"
  elif [[ "$lower" == *gamepad* || "$lower" == *controller* || "$lower" == *joystick* || "$lower" == *xbox* || "$lower" == *dualsense* || "$lower" == *dualshock* ]]; then
    printf 'Gamepad/Controller · %s' "$model"
  elif [[ "$lower" == *keyboard* || "$lower" == *keychron* || "$lower" == *kbd* ]]; then
    printf 'Keyboard · %s' "$model"
  elif [[ "$lower" == *receiver* || "$lower" == *mouse* || "$lower" == *viper* || "$lower" == *logitech* || "$lower" == *mx* ]]; then
    printf 'Mouse · %s' "$model"
  elif [[ "$lower" == *storage* || "$lower" == *mass\ storage* || "$lower" == *flash* || "$lower" == *disk* || "$lower" == *ssd* || "$lower" == *hdd* || "$lower" == *card\ reader* || "$lower" == *sandisk* || "$lower" == *kingston* ]]; then
    printf 'Storage · %s' "$model"
  elif [[ "$lower" == *android* || "$lower" == *iphone* || "$lower" == *phone* || "$lower" == *pixel* || "$lower" == *samsung* ]]; then
    printf 'Phone · %s' "$model"
  else
    return 1
  fi
}

friendly_list() {
  sed -n '1,5p' | while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="$(friendly_name "$line" || true)"
    [ -n "$name" ] || continue
    printf '• %s\n' "$name"
  done
}

current="$(lsusb | sort)"
printf '%s\n' "$current" > "$STATE"

while true; do
  sleep 2
  new="$(lsusb | sort)"
  old="$(cat "$STATE" 2>/dev/null || true)"

  if [ "$new" != "$old" ]; then
    added="$(comm -13 <(printf '%s\n' "$old") <(printf '%s\n' "$new") || true)"
    removed="$(comm -23 <(printf '%s\n' "$old") <(printf '%s\n' "$new") || true)"

    if [ -n "$added" ]; then
      added_friendly="$(printf '%s\n' "$added" | friendly_list)"
      [ -n "$added_friendly" ] && notify-send "USB connected" "$added_friendly"
    fi
    if [ -n "$removed" ]; then
      removed_friendly="$(printf '%s\n' "$removed" | friendly_list)"
      [ -n "$removed_friendly" ] && notify-send "USB removed" "$removed_friendly"
    fi

    printf '%s\n' "$new" > "$STATE"
  fi
done
