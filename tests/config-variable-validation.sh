#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export GENTOO_INSTALL_REPO_DIR="$REPO_DIR"
export GENTOO_INSTALL_REPO_SCRIPT_ACTIVE=true
export GENTOO_INSTALL_REPO_SCRIPT_PID=$$

# shellcheck source=../scripts/utils.sh
source "$REPO_DIR/scripts/utils.sh"
# shellcheck source=../scripts/config.sh
source "$REPO_DIR/scripts/config.sh"
# shellcheck source=../scripts/functions.sh
source "$REPO_DIR/scripts/functions.sh"

fail() {
	echo "Test failure: $*" >&2
	exit 1
}

# The settings are read by the sourced installer functions, not by this file
# shellcheck disable=SC2034
set_required_variables() {
	HOSTNAME=gentoo
	TIMEZONE=Europe/Berlin
	KEYMAP=us
	KEYMAP_INITRAMFS=us
	LOCALES="en_US.UTF-8 UTF-8"
	LOCALE=C.utf8
	GENTOO_MIRROR="https://distfiles.gentoo.org"
	GENTOO_ARCH=amd64
	GENTOO_SUBARCH=""
	STAGE3_VARIANT=systemd
	STAGE3_BASENAME=stage3-amd64-systemd
	SYSTEMD=true
	MUSL=false
}

# Every optional setting must have a default, so a configuration may omit it
for optional in \
	SYSTEMD_NETWORKD SYSTEMD_NETWORKD_INTERFACE_NAME SYSTEMD_NETWORKD_DHCP \
	SYSTEMD_NETWORKD_ADDRESSES SYSTEMD_NETWORKD_GATEWAY SYSTEMD_INITRAMFS_SSHD \
	PORTAGE_SYNC_TYPE PORTAGE_GIT_FULL_HISTORY PORTAGE_GIT_MIRROR USE_PORTAGE_TESTING \
	SELECT_MIRRORS SELECT_MIRRORS_LARGE_FILE SELECT_MIRRORS_COUNTRY ADDITIONAL_PACKAGES \
	ENABLE_SSHD ENABLE_BINPKG KERNEL_TYPE BOOTLOADER ROOT_SSH_AUTHORIZED_KEYS \
	DETECT_EXISTING_PARTITIONS CREATE_USER CREATE_USER_GROUPS CREATE_USER_SHELL \
	CREATE_USER_SUDO CREATE_USER_SSH_AUTHORIZED_KEYS
do
	# declare -p also reports empty arrays, which '-v' would not
	declare -p "$optional" >/dev/null 2>&1 \
		|| fail "optional setting '$optional' has no default in scripts/config.sh"
done

set_required_variables
check_required_config_variables \
	|| fail 'a complete configuration was rejected'

# A missing setting must be reported by name instead of failing later as an unbound variable
# Each case runs in its own subshell on purpose, so the unset cannot leak
# shellcheck disable=SC2030,SC2031
for missing in HOSTNAME TIMEZONE KEYMAP LOCALE GENTOO_ARCH STAGE3_BASENAME SYSTEMD MUSL; do
	output="$( (set_required_variables; unset "$missing"; check_required_config_variables) 2>&1 )" \
		&& fail "a configuration without $missing was accepted"
	[[ $output == *"$missing"* ]] \
		|| fail "the error for a missing $missing did not name it: $output"
done

output="$( (set_required_variables; unset HOSTNAME TIMEZONE; check_required_config_variables) 2>&1 )" \
	&& fail 'a configuration without HOSTNAME and TIMEZONE was accepted'
[[ $output == *HOSTNAME* && $output == *TIMEZONE* ]] \
	|| fail "all missing settings must be reported at once: $output"

echo 'config variable validation tests passed'
