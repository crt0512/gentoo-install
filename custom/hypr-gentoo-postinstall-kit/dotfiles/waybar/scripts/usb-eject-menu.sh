#!/usr/bin/env bash
set -euo pipefail

WOFI_STYLE="$HOME/.config/waybar/menu/awesome-menu.css"

notify() {
  notify-send "USB Eject" "$1" >/dev/null 2>&1 || true
}

if ! command -v udisksctl >/dev/null 2>&1; then
  notify "udisksctl not found"
  exit 0
fi

if ! command -v lsblk >/dev/null 2>&1; then
  notify "lsblk not found"
  exit 0
fi

if ! command -v wofi >/dev/null 2>&1; then
  notify "wofi not found"
  exit 0
fi

tmp_map="$(mktemp)"
cleanup() { rm -f "$tmp_map"; }
trap cleanup EXIT

# Build list of external-like disks (USB transport or removable media flag)
python - <<'PY' > "$tmp_map"
import json, subprocess

raw = subprocess.check_output([
    "lsblk", "-J", "-o",
    "NAME,PATH,TYPE,RM,TRAN,SIZE,MODEL,LABEL,MOUNTPOINT"
], text=True)
data = json.loads(raw)

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

    mounts = []
    for ch in dev.get("children") or []:
        mp = (ch.get("mountpoint") or "").strip()
        if mp:
            mounts.append(mp)
    mount_info = ", ".join(mounts) if mounts else "not mounted"

    display = f"⏏  {model} ({size}) · {mount_info}"
    print(f"{display}\t{path}")
PY

if [ ! -s "$tmp_map" ]; then
  notify "No external storage device found"
  exit 0
fi

pick="$(cut -f1 "$tmp_map" | wofi --dmenu --prompt "Safely eject" --width 900 --height 420 --style "$WOFI_STYLE")"
[ -n "${pick:-}" ] || exit 0

disk_path="$(awk -F '\t' -v sel="$pick" '$1 == sel {print $2; exit}' "$tmp_map")"
[ -n "${disk_path:-}" ] || exit 0

# Unmount any mounted partitions first
mapfile -t mounted_parts < <(lsblk -ln -o PATH,TYPE,MOUNTPOINT "$disk_path" | awk '$2=="part" && $3!="" {print $1}')

for part in "${mounted_parts[@]:-}"; do
  [ -n "${part:-}" ] || continue
  udisksctl unmount -b "$part" >/dev/null 2>&1 || {
    notify "Failed to unmount $part"
    exit 0
  }
done

# Power off / safely remove device
if udisksctl power-off -b "$disk_path" >/dev/null 2>&1; then
  notify "Safe to unplug: $disk_path"
else
  notify "Failed to eject $disk_path"
fi
