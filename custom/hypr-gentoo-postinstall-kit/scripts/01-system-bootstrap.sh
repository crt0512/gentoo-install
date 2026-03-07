#!/usr/bin/env bash
set -euo pipefail

KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_FILE="${KIT_DIR}/packages/base.txt"
USE_SNIPPET="${KIT_DIR}/portage/package.use/hypr-postinstall"
KEYWORD_SNIPPET="${KIT_DIR}/portage/package.accept_keywords/hyproverlay"

WITH_HYPROVERLAY=0
GPU_PROFILE="auto"
MACHINE_PROFILE="auto"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-hyproverlay)
      WITH_HYPROVERLAY=1
      shift
      ;;
    --gpu)
      GPU_PROFILE="${2:-auto}"
      shift 2
      ;;
    --machine)
      MACHINE_PROFILE="${2:-auto}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: sudo ./scripts/01-system-bootstrap.sh [--with-hyproverlay] [--gpu auto|nvidia|amd|intel] [--machine auto|desktop|laptop] [--dry-run]"
      exit 1
      ;;
  esac
done

if [[ "${GPU_PROFILE}" != "auto" && "${GPU_PROFILE}" != "nvidia" && "${GPU_PROFILE}" != "amd" && "${GPU_PROFILE}" != "intel" ]]; then
  echo "Invalid --gpu value: ${GPU_PROFILE}"
  echo "Use one of: auto, nvidia, amd, intel"
  exit 1
fi

if [[ "${MACHINE_PROFILE}" != "auto" && "${MACHINE_PROFILE}" != "desktop" && "${MACHINE_PROFILE}" != "laptop" ]]; then
  echo "Invalid --machine value: ${MACHINE_PROFILE}"
  echo "Use one of: auto, desktop, laptop"
  exit 1
fi

if [[ "${EUID}" -ne 0 && "${DRY_RUN}" -ne 1 ]]; then
  echo "Run as root: sudo ./scripts/01-system-bootstrap.sh [--with-hyproverlay] [--gpu auto|nvidia|amd|intel] [--machine auto|desktop|laptop] [--dry-run]"
  exit 1
fi

if [[ ! -f "${PKG_FILE}" ]]; then
  echo "Missing package file: ${PKG_FILE}"
  exit 1
fi

run_or_print() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

set_makeconf_var() {
  local key="$1"
  local value="$2"
  local file="/etc/portage/make.conf"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN: set ${key}=\"${value}\" in ${file}"
    return
  fi

  install -d /etc/portage
  touch "$file"

  if rg -q "^[[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=\"${value}\"|" "$file"
  else
    printf '%s\n' "${key}=\"${value}\"" >> "$file"
  fi
}

video_cards_for_gpu() {
  local gpu="$1"

  case "$gpu" in
    nvidia) echo "nvidia" ;;
    amd) echo "amdgpu radeonsi" ;;
    intel) echo "intel i965 iris" ;;
    *) echo "" ;;
  esac
}

detect_init_system() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || -d /etc/systemd/system ]]; then
    echo "systemd"
    return
  fi

  if command -v rc-update >/dev/null 2>&1; then
    echo "openrc"
    return
  fi

  echo "unknown"
}

service_enabled_openrc() {
  local svc="$1"
  rc-update show 2>/dev/null | rg -q "^\\s*${svc}\\s+\\|\\s+default"
}

enable_services() {
  local init_system="$1"
  shift
  local services=("$@")

  case "$init_system" in
    systemd)
      echo "==> Enabling systemd services"
      for svc in "${services[@]}"; do
        if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | rg -qx "${svc}\.service"; then
          if systemctl is-enabled "$svc" >/dev/null 2>&1; then
            echo "  - ${svc} already enabled"
          else
            run_or_print "systemctl enable \"${svc}\""
          fi
        else
          echo "  - Skipping ${svc}: service unit not found"
        fi
      done
      ;;
    openrc)
      echo "==> Enabling OpenRC services"
      for svc in "${services[@]}"; do
        if service_enabled_openrc "$svc"; then
          echo "  - ${svc} already in default runlevel"
        else
          run_or_print "rc-update add \"${svc}\" default"
        fi
      done
      ;;
    *)
      echo "==> Could not detect init system (systemd/OpenRC). Skipping service enablement."
      ;;
  esac
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> DRY-RUN MODE (no system changes will be made)"
fi

echo "==> Writing Portage package.use snippet"
run_or_print "install -d /etc/portage/package.use"
run_or_print "install -m 0644 \"${USE_SNIPPET}\" /etc/portage/package.use/hypr-postinstall"

if [[ "${WITH_HYPROVERLAY}" -eq 1 ]]; then
  echo "==> Enabling hyproverlay keyword snippet"
  run_or_print "install -d /etc/portage/package.accept_keywords"
  run_or_print "install -m 0644 \"${KEYWORD_SNIPPET}\" /etc/portage/package.accept_keywords/hyproverlay"
fi

detect_gpu_profile() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "nvidia"
    return
  fi

  local vendor_hex=""
  if [[ -r /sys/class/drm/card0/device/vendor ]]; then
    vendor_hex="$(tr -d '\n' < /sys/class/drm/card0/device/vendor || true)"
  elif command -v lspci >/dev/null 2>&1; then
    vendor_hex="$(lspci -nn | awk '/VGA|3D|Display/ { if (match($0, /\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]/)) { print substr($0, RSTART + 1, 4); exit } }' || true)"
    [[ -n "${vendor_hex:-}" ]] && vendor_hex="0x${vendor_hex}"
  fi

  case "${vendor_hex,,}" in
    0x10de) echo "nvidia" ;;
    0x1002|0x1022) echo "amd" ;;
    0x8086) echo "intel" ;;
    *) echo "intel" ;;
  esac
}

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

if [[ "${GPU_PROFILE}" == "auto" ]]; then
  GPU_PROFILE="$(detect_gpu_profile)"
fi

if [[ "${MACHINE_PROFILE}" == "auto" ]]; then
  MACHINE_PROFILE="$(detect_machine_profile)"
fi

echo "==> Ensuring GPU defaults in /etc/portage/make.conf"
VIDEO_CARDS_VALUE="$(video_cards_for_gpu "${GPU_PROFILE}")"
if [[ -n "${VIDEO_CARDS_VALUE}" ]]; then
  set_makeconf_var "VIDEO_CARDS" "${VIDEO_CARDS_VALUE}"
  echo "  - VIDEO_CARDS set for ${GPU_PROFILE}: ${VIDEO_CARDS_VALUE}"
else
  echo "  - Skipping VIDEO_CARDS update (unknown GPU profile: ${GPU_PROFILE})"
fi

GPU_PKG_FILE="${KIT_DIR}/packages/profile-${GPU_PROFILE}.txt"
GPU_USE_SNIPPET="${KIT_DIR}/portage/package.use/gpu-${GPU_PROFILE}"
MACHINE_PKG_FILE="${KIT_DIR}/packages/profile-${MACHINE_PROFILE}.txt"

if [[ -f "${GPU_USE_SNIPPET}" ]]; then
  echo "==> Writing GPU-specific package.use snippet (${GPU_PROFILE})"
  run_or_print "install -m 0644 \"${GPU_USE_SNIPPET}\" \"/etc/portage/package.use/gpu-${GPU_PROFILE}\""
fi

echo "==> Installing package set"
mapfile -t PKGS < <(rg -v '^\s*(#|$)' "${PKG_FILE}")

if [[ -f "${GPU_PKG_FILE}" ]]; then
  echo "==> Applying GPU package profile: ${GPU_PROFILE}"
  mapfile -t GPU_PKGS < <(rg -v '^\s*(#|$)' "${GPU_PKG_FILE}")
  PKGS+=("${GPU_PKGS[@]}")
else
  echo "==> No extra package profile for GPU: ${GPU_PROFILE}"
fi

if [[ -f "${MACHINE_PKG_FILE}" ]]; then
  echo "==> Applying machine package profile: ${MACHINE_PROFILE}"
  mapfile -t MACHINE_PKGS < <(rg -v '^\s*(#|$)' "${MACHINE_PKG_FILE}")
  PKGS+=("${MACHINE_PKGS[@]}")
else
  echo "==> No extra package profile for machine: ${MACHINE_PROFILE}"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "DRY-RUN: emerge -av ${PKGS[*]}"
else
  emerge -av "${PKGS[@]}"
fi

INIT_SYSTEM="$(detect_init_system)"
echo "==> Detected init system: ${INIT_SYSTEM}"

if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
  enable_services "${INIT_SYSTEM}" NetworkManager
else
  enable_services "${INIT_SYSTEM}" dbus elogind NetworkManager
fi

echo
echo "System bootstrap completed."
echo "Next: run scripts/02-user-setup.sh as normal user."
