#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export GENTOO_INSTALL_REPO_DIR="$REPO_DIR"
export GENTOO_INSTALL_REPO_SCRIPT_ACTIVE=true
export GENTOO_INSTALL_REPO_SCRIPT_PID=$$

# shellcheck source=../scripts/utils.sh
source "$REPO_DIR/scripts/utils.sh"
# shellcheck source=../scripts/functions.sh
source "$REPO_DIR/scripts/functions.sh"

fail() {
	echo "Test failure: $*" >&2
	exit 1
}

expect_failure_containing() {
	local expected="$1"
	shift
	local output
	if output="$("$@" 2>&1)"; then
		fail "command unexpectedly succeeded: $*"
	fi
	[[ $output == *"$expected"* ]] \
		|| fail "failure did not contain '$expected': $output"
}

invalid_bootloader() {
	IS_EFI=true
	BOOTLOADER=direct
	validate_bootloader
}

systemd_boot_on_bios() {
	IS_EFI=false
	BOOTLOADER=systemd-boot
	validate_bootloader
}

grub_on_bios() {
	IS_EFI=false
	BOOTLOADER=grub
	validate_bootloader
}

(
	IS_EFI=true
	unset BOOTLOADER
	validate_bootloader
	[[ $BOOTLOADER == grub ]] \
		|| fail "EFI default bootloader should be grub"
)

(
	IS_EFI=false
	unset BOOTLOADER
	validate_bootloader
	[[ $BOOTLOADER == limine ]] \
		|| fail "BIOS default bootloader should be limine"
)

(
	IS_EFI=true
	BOOTLOADER=grub
	validate_bootloader
)

(
	IS_EFI=true
	BOOTLOADER=limine
	validate_bootloader
)

(
	IS_EFI=true
	BOOTLOADER=systemd-boot
	validate_bootloader
)

expect_failure_containing "BOOTLOADER must be one of" \
	invalid_bootloader

expect_failure_containing "BOOTLOADER=systemd-boot requires EFI boot" \
	systemd_boot_on_bios

expect_failure_containing "BOOTLOADER=grub is currently supported only with EFI boot" \
	grub_on_bios

echo 'bootloader validation tests passed'
