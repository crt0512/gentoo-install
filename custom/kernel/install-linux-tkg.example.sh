#!/usr/bin/env bash
set -euo pipefail

# Example custom kernel pipeline hook for oddlama/gentoo-install.
# This script is executed in the target system (inside chroot) from gentoo.conf: after_install().
#
# Usage from gentoo.conf:
#   CUSTOM_KERNEL_PIPELINE_ENABLE=true
#   CUSTOM_KERNEL_SCRIPT_RELATIVE_PATH="custom/kernel/install-linux-tkg.sh"
#   CUSTOM_KERNEL_SCRIPT_ARGS=("--some-arg")
#
# Recommended flow:
# 1) Keep default kernel installed as fallback.
# 2) Build/install linux-tkg.
# 3) Update boot entry to point to linux-tkg kernel+initramfs.
# 4) Reboot and test.
# 5) Remove fallback only after validation.

cat <<'EOF'
This is an example template, not an active linux-tkg installer.

Steps you likely want to implement here:
- Ensure build dependencies are installed.
- Clone/update https://github.com/Frogging-Family/linux-tkg
- Build linux-tkg for Gentoo according to your chosen method.
- Install resulting kernel artifacts.
- Regenerate initramfs and update boot entry.

Tip: Keep the gentoo-kernel/gentoo-kernel-bin fallback until linux-tkg is verified bootable.
EOF
