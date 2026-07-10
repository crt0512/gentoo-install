#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GENTOO_INSTALL_REPO_DIR="$REPO_DIR"
export GENTOO_INSTALL_REPO_SCRIPT_ACTIVE=true
export GENTOO_INSTALL_REPO_SCRIPT_PID=$$

# shellcheck source=../scripts/utils.sh
source "$REPO_DIR/scripts/utils.sh"
# shellcheck source=../scripts/config.sh
source "$REPO_DIR/scripts/config.sh"
# shellcheck source=../scripts/functions.sh
source "$REPO_DIR/scripts/functions.sh"
# shellcheck source=../scripts/main.sh
source "$REPO_DIR/scripts/main.sh"

fail() {
	echo "Test failure: $*" >&2
	exit 1
}

actions=()
declare -A active_mounts=(
	["/mock/target"]=true
	["/mock/target/proc"]=true
	["/mock/repo-bind"]=true
)
declare -A active_luks=([new-root]=true [old-root]=true)
declare -A active_md=([/dev/md/new-array]=true [/dev/md/old-array]=true)
active_rpool=true

# Non-destructive command mocks used by the cleanup functions.
mountpoint() {
	local path="${*: -1}"
	[[ ${active_mounts[$path]:-false} == true ]]
}
umount() {
	local path="${*: -1}"
	actions+=("umount:$path")
	active_mounts[$path]=false
	[[ $path != /mock/target ]] || active_mounts[/mock/target/proc]=false
}
cryptsetup() {
	case "$1" in
		status) [[ ${active_luks[$2]:-false} == true ]] ;;
		close) actions+=("luks:$2"); active_luks[$2]=false ;;
		*) return 1 ;;
	esac
}
mdadm() {
	case "$1" in
		--detail) [[ ${active_md[$2]:-false} == true ]] ;;
		--stop) actions+=("md:$2"); active_md[$2]=false ;;
		*) return 1 ;;
	esac
}
zpool() {
	case "$1" in
		list) [[ $active_rpool == true ]] && echo rpool ;;
		export) actions+=("zpool:$2"); active_rpool=false ;;
		*) return 1 ;;
	esac
}

ROOT_MOUNTPOINT=/mock/target
GENTOO_INSTALL_REPO_BIND=/mock/repo-bind
INSTALLER_OWNS_TARGET_MOUNTS=true
INSTALLER_CREATED_MOUNTS=(/mock/repo-bind /mock/target/proc)
INSTALLER_CREATED_MOUNT_SET=(
	[/mock/repo-bind]=true
	[/mock/target/proc]=true
)
INSTALLER_RESOURCE_BASELINES_CAPTURED=true
USED_ZFS=true
INSTALLER_CREATED_RPOOL=true
INSTALLER_PLANNED_LUKS_MAPPINGS=(old-root new-root)
INSTALLER_CREATED_LUKS_MAPPINGS=(new-root)
INSTALLER_PLANNED_MD_ARRAYS=(/dev/md/old-array /dev/md/new-array)
INSTALLER_CREATED_MD_ARRAYS=(/dev/md/new-array)

cleanup_installer_failure_resources

[[ ${active_luks[new-root]} == false ]] || fail 'created LUKS mapping was not closed'
[[ ${active_luks[old-root]} == true ]] || fail 'pre-existing/uncreated LUKS mapping was closed'
[[ ${active_md[/dev/md/new-array]} == false ]] || fail 'created RAID array was not stopped'
[[ ${active_md[/dev/md/old-array]} == true ]] || fail 'pre-existing/uncreated RAID array was stopped'
[[ $active_rpool == false ]] || fail 'created rpool was not exported'

first_action_count=${#actions[@]}
cleanup_installer_failure_resources
[[ ${#actions[@]} -eq $first_action_count ]] \
	|| fail 'failure cleanup was not idempotent'

# The nested installer must leave host resources to its outer parent.
RUNNING_IN_INSTALLER_CHROOT=true
active_luks[new-root]=true
cleanup_installer_failure_resources
[[ ${#actions[@]} -eq $first_action_count ]] \
	|| fail 'cleanup ran from inside the chroot'
RUNNING_IN_INSTALLER_CHROOT=false

# gentoo_chroot must return the child's status (and therefore cannot exec over
# the parent). Also verify that command arguments survive intact.
bound_repo_chroot=""
bind_repo_dir() {
	bound_repo_chroot="$1"
	active_mounts[/mock/target/tmp/gentoo-install/bind]=true
	record_installer_created_mount /mock/target/tmp/gentoo-install/bind
}
prepared_tmp_chroot=""
prepare_chroot_installer_tmp_dir() { prepared_tmp_chroot="$1"; }
bound_uuid_chroot=""
bind_installer_uuid_storage() {
	bound_uuid_chroot="$1"
	active_mounts[/mock/target/tmp/gentoo-install/uuids]=true
	record_installer_created_mount /mock/target/tmp/gentoo-install/uuids
}
install() { :; }
mountpoint() { return 0; }
cache_lsblk_output() { CACHED_LSBLK_OUTPUT=mock; }
chroot_args=()
chroot() {
	chroot_args=("$@")
	return 42
}
set +e
gentoo_chroot /mock/target /bin/test --flag
chroot_status=$?
set -e
[[ $chroot_status -eq 42 ]] \
	|| fail "gentoo_chroot lost child status 42 (got $chroot_status)"
[[ " ${chroot_args[*]} " == *" /bin/test --flag "* ]] \
	|| fail 'gentoo_chroot lost command arguments'
[[ $bound_repo_chroot == /mock/target ]] \
	|| fail 'gentoo_chroot did not request a direct repository bind below the target'
[[ $prepared_tmp_chroot == /mock/target && $bound_uuid_chroot == /mock/target ]] \
	|| fail 'gentoo_chroot did not share UUID state independently of the target /tmp mount'
[[ ${active_mounts[/mock/target/tmp/gentoo-install/bind]} == false \
	&& ${active_mounts[/mock/target/tmp/gentoo-install/uuids]} == false ]] \
	|| fail 'gentoo_chroot left transient repository or UUID mounts behind'

# Optional disk-action fields must retain their documented defaults under
# `set -u`, including custom configurations which omit labels and pool/profile
# options.
test_optional_disk_action_defaults() {
	local disk_action_summarize_only=true
	local -A summary_tree=()
	local -A summary_name=()
	local -A summary_hint=()
	local -A summary_ptr=()
	local -A summary_desc=()

	local -A arguments=([id]=root [type]=ext4)
	disk_format
	arguments=([ids]='root;')
	disk_format_zfs
	arguments=([ids]='root;')
	disk_format_btrfs
}
test_optional_disk_action_defaults \
	|| fail 'optional disk-action defaults triggered an unbound variable'

removed_kernel_type='unsupported-removed-kernel'
if (KERNEL_TYPE="$removed_kernel_type"; validate_kernel_type) >/dev/null 2>&1; then
	fail 'removed custom kernel type was silently accepted'
fi

# Failures inside command substitutions must propagate instead of producing an
# apparently valid boot command line with an empty UUID.
if (
	KEYMAP_INITRAMFS=us
	USED_ZFS=false
	DISK_DRACUT_CMDLINE=()
	DISK_ID_ROOT=root
	get_blkid_uuid_for_id() { return 1; }
	get_cmdline
) >/dev/null 2>&1; then
	fail 'kernel command line accepted a failed root UUID lookup'
fi

if (
	DISK_ID_TO_RESOLVABLE[missing]='partuuid:missing'
	get_device_by_partuuid() { return 1; }
	resolve_device_by_id missing
) >/dev/null 2>&1; then
	fail 'device resolver swallowed a failed backend lookup'
fi

# Required export is fail-closed; optional export may be unavailable.
USED_LUKS=true
LUKS_HEADER_EXPORT_DIR=/definitely/not/a/real/export/directory
REQUIRE_LUKS_HEADER_EXPORT=true
if (validate_luks_header_export_destination) >/dev/null 2>&1; then
	fail 'required missing LUKS header export destination was accepted'
fi
REQUIRE_LUKS_HEADER_EXPORT=false
validate_luks_header_export_destination >/dev/null 2>&1
[[ $LUKS_HEADER_EXPORT_READY == false ]] \
	|| fail 'missing optional export destination was marked ready'

echo 'recovery cleanup tests passed'
