#!/usr/bin/env bash
set -euo pipefail

KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${KIT_DIR}/dotfiles"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "${OUT_DIR}"

backup_path() {
  local target="$1"
  if [[ -e "${target}" ]]; then
    mv "${target}" "${target}.bak.${STAMP}"
    echo "  backed up ${target} -> ${target}.bak.${STAMP}"
  fi
}

copy_cfg() {
  local src="$1"
  local name="$2"
  if [[ -d "${src}" ]]; then
    backup_path "${OUT_DIR}/${name}"
    mkdir -p "${OUT_DIR}/${name}"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "${src}/" "${OUT_DIR}/${name}/"
    else
      rm -rf "${OUT_DIR:?}/${name}"
      mkdir -p "${OUT_DIR}/${name}"
      cp -a "${src}/." "${OUT_DIR}/${name}/"
    fi
    echo "  exported ${src} -> ${OUT_DIR}/${name}"
  else
    echo "  skipped (not found): ${src}"
  fi
}

echo "==> Exporting current user configs to kit"
copy_cfg "${HOME}/.config/hypr" "hypr"
copy_cfg "${HOME}/.config/waybar" "waybar"
copy_cfg "${HOME}/.config/wofi" "wofi"
copy_cfg "${HOME}/.config/mako" "mako"
copy_cfg "${HOME}/.config/kitty" "kitty"

echo
echo "Export completed. Review ${OUT_DIR} before committing/sharing."
