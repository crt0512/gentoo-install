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

fail() {
	echo "Test failure: $*" >&2
	exit 1
}

expect_failure() {
	local description="$1"
	shift
	if ("$@") >/dev/null 2>&1; then
		fail "$description unexpectedly succeeded"
	fi
}

# A destructive confirmation must match exactly. In particular, pressing Enter
# must never retain the permissive default of the generic ask() helper.
flush_stdin() { :; }
if printf '\n' | confirm_destructive_action WIPE 'test prompt'; then
	fail 'empty destructive confirmation was accepted'
fi
if printf 'wipe\n' | confirm_destructive_action WIPE 'test prompt'; then
	fail 'case-mismatched destructive confirmation was accepted'
fi
printf 'WIPE\n' | confirm_destructive_action WIPE 'test prompt' \
	|| fail 'exact destructive confirmation was rejected'

# Exercise the layout-level guard before any action can be queued.
canonicalize_whole_block_device() {
	echo -n /dev/mock-disk
}
# Called indirectly by the sourced validation helpers.
# shellcheck disable=SC2317,SC2329
block_device_is_in_use() {
	return 1
}
expect_failure \
	'one-device RAID1 layout' \
	create_raid1_luks_layout swap=false /dev/mock-a
expect_failure \
	'duplicate canonical RAID1 devices' \
	create_raid1_luks_layout swap=false /dev/mock-a /dev/disk/by-id/mock-a

# Busy devices must also be rejected by the common destructive-device guard.
# shellcheck disable=SC2317,SC2329
block_device_is_in_use() {
	return 0
}
expect_failure \
	'busy destructive device' \
	validate_destructive_whole_block_devices 1 'test layout' /dev/mock-a

# The nested installer replays disk_configuration after the outer installer has
# mounted the target. It must rebuild IDs without rejecting those expected busy
# devices or registering another destructive host operation.
RUNNING_IN_INSTALLER_CHROOT=true
DESTRUCTIVE_DEVICES=()
DESTRUCTIVE_DEVICE_SET=()
# A later mock intentionally replaces this sourced function for a separate test.
# shellcheck disable=SC2218
validate_destructive_whole_block_devices 1 'inner replay' /dev/mock-a \
	|| fail 'inner configuration replay rejected an expected busy device'
register_destructive_device /dev/mock-a
[[ ${#DESTRUCTIVE_DEVICES[@]} -eq 0 ]] \
	|| fail 'inner configuration replay registered a destructive device'
unset RUNNING_IN_INSTALLER_CHROOT

# A custom config must not smuggle a registered-existing device into a format
# action without adding its physical disk to the exact wipe confirmation.
DISK_ID_TO_UUID[existing]=00000000-0000-4000-8000-000000000002
DISK_ID_REGISTERED_EXISTING[existing]=true
expect_failure \
	'format of unconfirmed registered-existing device' \
	format id=existing type=ext4

# Mock the physical layout operations, but retain format_zfs itself. This checks
# that create_zfs_centric_layout passes its compression value into DISK_ACTIONS.
validate_destructive_whole_block_devices() { :; }
create_gpt() { :; }
create_partition() {
	local argument
	for argument in "$@"; do
		if [[ $argument == new_id=part_root_dev0 ]]; then
			DISK_ID_TO_UUID[part_root_dev0]=00000000-0000-4000-8000-000000000001
		fi
	done
}
format() { :; }

DISK_ACTIONS=()
create_zfs_centric_layout \
	swap=false \
	type=efi \
	encrypt=false \
	compress=zstd-fast \
	pool_type=standard \
	/dev/mock-a

compression_recorded=false
for action_field in "${DISK_ACTIONS[@]}"; do
	if [[ $action_field == compress=zstd-fast ]]; then
		compression_recorded=true
		break
	fi
done
[[ $compression_recorded == true ]] \
	|| fail 'ZFS compression was not recorded in DISK_ACTIONS'

echo 'disk configuration validation tests passed'
