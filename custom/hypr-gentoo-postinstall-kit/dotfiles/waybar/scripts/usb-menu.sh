#!/usr/bin/env bash
set -euo pipefail

WOFI_STYLE="$HOME/.config/waybar/menu/awesome-menu.css"

notify() {
  notify-send "USB Menu" "$1" >/dev/null 2>&1 || true
}

if ! command -v lsblk >/dev/null 2>&1; then
  notify "lsblk not found"
  exit 0
fi

if ! command -v udisksctl >/dev/null 2>&1; then
  notify "udisksctl not found"
  exit 0
fi

if ! command -v wofi >/dev/null 2>&1; then
  notify "wofi not found"
  exit 0
fi

open_with_file_manager() {
  local target="$1"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$target" >/dev/null 2>&1 &
  elif command -v thunar >/dev/null 2>&1; then
    thunar "$target" >/dev/null 2>&1 &
  elif command -v dolphin >/dev/null 2>&1; then
    dolphin "$target" >/dev/null 2>&1 &
  else
    notify "No file manager command found"
    return 1
  fi
}

safe_eject_disk() {
  local disk_path="$1"
  mapfile -t mounted_parts < <(lsblk -ln -o PATH,TYPE,MOUNTPOINT "$disk_path" | awk '$2=="part" && $3!="" {print $1}')

  for part in "${mounted_parts[@]:-}"; do
    [ -n "${part:-}" ] || continue
    udisksctl unmount -b "$part" >/dev/null 2>&1 || {
      notify "Failed to unmount $part"
      return 1
    }
  done

  if udisksctl power-off -b "$disk_path" >/dev/null 2>&1; then
    notify "Safe to unplug: $disk_path"
    return 0
  fi

  notify "Failed to eject $disk_path"
  return 1
}

tmp_map="$(mktemp)"
cleanup() { rm -f "$tmp_map"; }
trap cleanup EXIT

python - <<'PY' > "$tmp_map"
import json
import subprocess

raw = subprocess.check_output([
    "lsblk", "-J", "-o",
    "NAME,PATH,TYPE,RM,TRAN,SIZE,MODEL,LABEL,MOUNTPOINT"
], text=True)
data = json.loads(raw)

rows = []
for dev in data.get("blockdevices", []):
    if dev.get("type") != "disk":
        continue
    rm = int(dev.get("rm") or 0)
    tran = (dev.get("tran") or "").lower()
    if not (rm == 1 or tran == "usb"):
        continue

    path = dev.get("path") or f"/dev/{dev.get('name')}"
    model = (dev.get("model") or "External storage").strip()
    size = dev.get("size") or "?"
    label = model if model else "External storage"

    mounts = []
    for ch in dev.get("children") or []:
        mp = (ch.get("mountpoint") or "").strip()
        if mp:
            mounts.append(mp)

    rows.append((f"🧩 {label} ({size})", "noop", ""))
    if mounts:
        for mp in mounts:
            rows.append((f"📂 Open in file manager -> {mp}", "open", mp))
    else:
        rows.append(("📂 Open in file manager -> (not mounted)", "noop", ""))
    rows.append((f"⏏ Eject safely -> {path}", "eject", path))
    rows.append(("────────────────────────", "noop", ""))

for text, action, payload in rows:
    print(f"{text}\t{action}\t{payload}")
PY

if [ ! -s "$tmp_map" ]; then
  notify "No external storage device found"
  exit 0
fi

pick="$(cut -f1 "$tmp_map" | wofi --dmenu --prompt "USB devices" --width 980 --height 560 --style "$WOFI_STYLE")"
[ -n "${pick:-}" ] || exit 0

entry="$(awk -F '\t' -v sel="$pick" '$1 == sel {print; exit}' "$tmp_map")"
[ -n "${entry:-}" ] || exit 0

action="$(printf '%s' "$entry" | cut -f2)"
payload="$(printf '%s' "$entry" | cut -f3-)"

case "$action" in
  open)
    [ -n "${payload:-}" ] || {
      notify "Device is not mounted"
      exit 0
    }
    open_with_file_manager "$payload" || true
    ;;
  eject)
    [ -n "${payload:-}" ] || exit 0
    safe_eject_disk "$payload" || true
    ;;
  *)
    exit 0
    ;;
esac
