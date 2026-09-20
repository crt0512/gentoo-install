# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Script internal configuration

# The temporary directory for this script. It must reside in /tmp to allow the
# chrooted system to access the files. The entrypoint validates this as a
# root-owned, non-symlink directory with mode 0700 before using it.
TMP_DIR="/tmp/gentoo-install"
# Mountpoint for the new system
ROOT_MOUNTPOINT="$TMP_DIR/root"
# Mountpoint for the script files for access from chroot
GENTOO_INSTALL_REPO_BIND="$TMP_DIR/bind"
# Mountpoint for the script files for access from chroot
UUID_STORAGE_DIR="$TMP_DIR/uuids"
# Backup dir for luks headers
LUKS_HEADER_BACKUP_DIR="$TMP_DIR/luks-headers"
# Permanent copy inside the installed system. This is useful for inspection,
# but is not an independent recovery copy: it is stored behind the same LUKS
# container whose header it backs up.
LUKS_HEADER_TARGET_DIR="/root/luks-header-backups"
# Optional directory on the live host (for example, a mounted removable disk).
# Configuration files may override these two values.
LUKS_HEADER_EXPORT_DIR=""
REQUIRE_LUKS_HEADER_EXPORT=false
# Reject replayed stage3 builds older than this many days. Set to 0 only for an
# explicit offline/archive workflow; signatures and checksums are still checked.
MAX_STAGE3_AGE_DAYS=45

# Flag to track usage of raid (needed to check for mdadm existence)
USED_RAID=false
# Flag to track usage of luks (needed to check for cryptsetup existence)
USED_LUKS=false
# Flag to track usage of zfs
USED_ZFS=false
# Flag to track usage of btrfs
USED_BTRFS=false
# Flag to track usage of encryption
USED_ENCRYPTION=false
# Flag to track whether partitioning or formatting is forbidden
NO_PARTITIONING_OR_FORMATTING=false
# Check whether the disks are already partitioned as configured and offer to keep that layout
DETECT_EXISTING_PARTITIONS=true
# Set at runtime once the existing partitions were confirmed for reuse
REUSE_EXISTING_PARTITIONS=false
# Set at runtime when the reused partitions must keep their current filesystems
KEEP_EXISTING_FILESYSTEMS=false
# Maps disk ids to the uuids that were found on disk while detecting an existing layout
declare -gA DISK_DETECTED_UUIDS=()
# Accepted uuid format for installer state files and for adopted on-disk identifiers
INSTALLER_UUID_REGEX='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[1-5][[:xdigit:]]{3}-[89abAB][[:xdigit:]]{3}-[[:xdigit:]]{12}$'

# Restrict mirrorselect to a single country instead of probing the whole mirror list
SELECT_MIRRORS_COUNTRY=""

# Defaults for optional settings, so a configuration which does not mention them still works
SYSTEMD_NETWORKD=true
SYSTEMD_NETWORKD_INTERFACE_NAME="en*"
SYSTEMD_NETWORKD_DHCP=true
SYSTEMD_NETWORKD_ADDRESSES=()
SYSTEMD_NETWORKD_GATEWAY=""
SYSTEMD_INITRAMFS_SSHD=false
PORTAGE_SYNC_TYPE="git"
PORTAGE_GIT_FULL_HISTORY=false
PORTAGE_GIT_MIRROR="https://anongit.gentoo.org/git/repo/sync/gentoo.git"
USE_PORTAGE_TESTING=false
SELECT_MIRRORS=false
SELECT_MIRRORS_LARGE_FILE=false
ADDITIONAL_PACKAGES=()
ENABLE_SSHD=false
ENABLE_BINPKG=false
KERNEL_TYPE=bin
BOOTLOADER=""
ROOT_SSH_AUTHORIZED_KEYS=""

# Name of an unprivileged user to create, or empty to create none
CREATE_USER=""
# Comma separated supplementary groups for the created user
CREATE_USER_GROUPS="wheel,audio,video,usb,portage"
# Login shell for the created user
CREATE_USER_SHELL="/bin/bash"
# Install sudo and allow the wheel group to use it
CREATE_USER_SUDO=true
# Authorized ssh keys for the created user, one per line
CREATE_USER_SSH_AUTHORIZED_KEYS=""

# An array of disk related actions to perform
DISK_ACTIONS=()
# Resource names declared by DISK_ACTIONS. Before destructive work begins the
# installer records whether any of these already exist, so failure cleanup can
# only tear down resources created by this run.
INSTALLER_PLANNED_MD_ARRAYS=()
INSTALLER_PLANNED_LUKS_MAPPINGS=()
INSTALLER_CREATED_MD_ARRAYS=()
INSTALLER_CREATED_LUKS_MAPPINGS=()
INSTALLER_CREATED_LUKS_HEADERS=()
declare -gA INSTALLER_PLANNED_MD_ARRAY_SET=()
declare -gA INSTALLER_PLANNED_LUKS_MAPPING_SET=()
declare -gA INSTALLER_MD_ARRAY_PREEXISTED=()
declare -gA INSTALLER_LUKS_MAPPING_PREEXISTED=()
INSTALLER_RPOOL_PREEXISTED=false
INSTALLER_CREATED_RPOOL=false
INSTALLER_RESOURCE_BASELINES_CAPTURED=false

# Mounts created by this process are recorded individually. This is also used
# by --chroot so pre-existing mounts supplied by the operator are never removed.
INSTALLER_CREATED_MOUNTS=()
declare -gA INSTALLER_CREATED_MOUNT_SET=()
INSTALLER_OWNS_TARGET_MOUNTS=false
INSTALLER_FAILURE_CLEANUP_RUNNING=false
# Canonical whole-device paths which will be modified. This is consumed by the
# destructive confirmation shown immediately before applying disk actions.
DESTRUCTIVE_DEVICES=()
declare -gA DESTRUCTIVE_DEVICE_SET=()
# An array of dracut parameters needed to boot the selected configuration
DISK_DRACUT_CMDLINE=()
# An associative array from disk id to a resolvable string
declare -gA DISK_ID_TO_RESOLVABLE
# An associative array from disk id to parent gpt disk id (only for partitions)
declare -gA DISK_ID_PART_TO_GPT_ID
# An associative array to check for existing ids (maps to uuids)
declare -gA DISK_ID_TO_UUID
# IDs registered as pre-existing are read-only inputs. Allowing a later format,
# RAID, LUKS, or partition action on them could modify a device which was never
# included in DESTRUCTIVE_DEVICES or the exact wipe confirmation.
declare -gA DISK_ID_REGISTERED_EXISTING=()
# An associative set to check for correct usage of size=remaining in gpt tables
declare -gA DISK_GPT_HAD_SIZE_REMAINING

function register_destructive_device() {
	# See validate_destructive_whole_block_devices: the inner installer only
	# rebuilds configuration state and must never register/apply host disk work.
	[[ ${RUNNING_IN_INSTALLER_CHROOT:-false} != true ]] || return 0

	local device="$1"
	local canonical

	canonical="$(canonicalize_whole_block_device "$device")" \
		|| die "Invalid destructive whole-device path '$device'"
	if block_device_is_in_use "$canonical"; then
		die "Refusing to modify '$device' ('$canonical'): the device or one of its children is mounted or otherwise in use"
	fi

	if [[ ! -v "DESTRUCTIVE_DEVICE_SET[$canonical]" ]]; then
		DESTRUCTIVE_DEVICE_SET[$canonical]=true
		DESTRUCTIVE_DEVICES+=("$canonical")
	fi
}

function only_one_of() {
	local previous=""
	local a
	for a in "$@"; do
		if [[ -v arguments[$a] ]]; then
			if [[ -z $previous ]]; then
				previous="$a"
			else
				die_trace 2 "Only one of the arguments ($*) can be given"
			fi
		fi
	done
}

function create_new_id() {
	local id="${arguments[$1]}"
	[[ $id == *';'* ]] \
		&& die_trace 2 "Identifier contains invalid character ';'"
	[[ ! -v DISK_ID_TO_UUID[$id] ]] \
		|| die_trace 2 "Identifier '$id' already exists"
	local storage_key
	storage_key="$(uuid_storage_key "$id")" \
		|| die_trace 2 "Could not encode identifier '$id' for UUID storage"
	local generated_uuid
	generated_uuid="$(load_or_generate_uuid "$storage_key")" \
		|| die_trace 2 "Could not load or generate UUID for identifier '$id'"
	DISK_ID_TO_UUID[$id]="$generated_uuid"
}

function verify_existing_id() {
	local id="${arguments[$1]}"
	[[ -v DISK_ID_TO_UUID[$id] ]] \
		|| die_trace 2 "Identifier $1='$id' not found"
}

function verify_existing_unique_ids() {
	local arg="$1"
	local ids="${arguments[$arg]}"
	local count_orig
	local count_uniq

	count_orig="$(tr ';' '\n' <<< "$ids" | grep -c '\S')"
	count_uniq="$(tr ';' '\n' <<< "$ids" | grep '\S' | sort -u | wc -l)"
	[[ $count_orig -gt 0 ]] \
		|| die_trace 2 "$arg=... must contain at least one entry"
	[[ $count_orig -eq $count_uniq ]] \
		|| die_trace 2 "$arg=... contains duplicate identifiers"

	local id
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		[[ -v DISK_ID_TO_UUID[$id] ]] \
			|| die_trace 2 "$arg=... contains unknown identifier '$id'"
	done
}

function reject_registered_existing_ids_for_destructive_action() {
	local action="$1"
	local ids="$2"
	local id

	# Splitting is intentional here.
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		[[ ! -v "DISK_ID_REGISTERED_EXISTING[$id]" ]] \
			|| die_trace 2 "Refusing to $action registered-existing id '$id': it is not part of the confirmed destructive-device set"
	done
}

function verify_option() {
	local opt="$1"
	shift

	local arg="${arguments[$opt]}"
	local i
	for i in "$@"; do
		[[ $i == "$arg" ]] \
			&& return 0
	done

	die_trace 2 "Invalid option $opt='$arg', must be one of ($*)"
}

# Named arguments:
# new_id:  Id for the existing device
# device:  The block device
function register_existing() {
	local known_arguments=('+new_id' '+device')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	create_new_id new_id
	local new_id="${arguments[new_id]}"
	local device="${arguments[device]}"
	DISK_ID_REGISTERED_EXISTING[$new_id]=true
	create_resolve_entry_device "$new_id" "$device"
	DISK_ACTIONS+=("action=existing" "$@" ";")
}

# Named arguments:
# new_id:     Id for the new gpt table
# device|id:  The operand block device or previously allocated id
function create_gpt() {
	local known_arguments=('+new_id' '+device|id')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	only_one_of device id
	[[ -v arguments[device] ]] \
		&& register_destructive_device "${arguments[device]}"
	create_new_id new_id
	[[ -v arguments[id] ]] \
		&& { verify_existing_id id; reject_registered_existing_ids_for_destructive_action "create a GPT on" "${arguments[id]}"; }

	local new_id="${arguments[new_id]}"
	create_resolve_entry "$new_id" ptuuid "${DISK_ID_TO_UUID[$new_id]}"
	DISK_ACTIONS+=("action=create_gpt" "$@" ";")
}

# Named arguments:
# new_id:  Id for the new partition
# size:    Size for the new partition, or 'remaining' to allocate the rest
# type:    The parition type, either (bios, efi, swap, raid, luks, linux) (or a 4 digit hex-code for gdisk).
# id:      The operand device id
function create_partition() {
	local known_arguments=('+new_id' '+id' '+size' '+type')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	create_new_id new_id
	verify_existing_id id
	reject_registered_existing_ids_for_destructive_action "create a partition on" "${arguments[id]}"
	verify_option type bios efi swap raid luks linux

	[[ -v "DISK_GPT_HAD_SIZE_REMAINING[${arguments[id]}]" ]] \
		&& die_trace 1 "Cannot add another partition to table (${arguments[id]}) after size=remaining was used"

	# shellcheck disable=SC2034
	[[ ${arguments[size]} == "remaining" ]] \
		&& DISK_GPT_HAD_SIZE_REMAINING[${arguments[id]}]=true

	local new_id="${arguments[new_id]}"
	DISK_ID_PART_TO_GPT_ID[$new_id]="${arguments[id]}"
	create_resolve_entry "$new_id" partuuid "${DISK_ID_TO_UUID[$new_id]}"
	DISK_ACTIONS+=("action=create_partition" "$@" ";")
}

# Named arguments:
# new_id:  Id for the new raid
# level:   Raid level
# name:    Raid name (/dev/md/<name>)
# ids:     Comma separated list of all member ids
function create_raid() {
	USED_RAID=true

	local known_arguments=('+new_id' '+level' '+name' '+ids')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	verify_option level 0 1 5 6
	verify_existing_unique_ids ids
	reject_registered_existing_ids_for_destructive_action "create RAID from" "${arguments[ids]}"
	local member_count
	local minimum_members
	member_count="$(tr ';' '\n' <<< "${arguments[ids]}" | grep -c '\S')"
	case "${arguments[level]}" in
		0|1) minimum_members=2 ;;
		5)   minimum_members=3 ;;
		6)   minimum_members=4 ;;
	esac
	[[ "$member_count" -ge "$minimum_members" ]] \
		|| die_trace 1 "RAID level ${arguments[level]} requires at least $minimum_members distinct members"
	create_new_id new_id

	local new_id="${arguments[new_id]}"
	local uuid="${DISK_ID_TO_UUID[$new_id]}"
	local mddevice="/dev/md/${arguments[name]}"
	[[ ! -v "INSTALLER_PLANNED_MD_ARRAY_SET[$mddevice]" ]] \
		|| die_trace 1 "RAID device name '${arguments[name]}' is used more than once"
	INSTALLER_PLANNED_MD_ARRAY_SET[$mddevice]=true
	INSTALLER_PLANNED_MD_ARRAYS+=("$mddevice")
	create_resolve_entry "$new_id" mdadm "$uuid"
	DISK_DRACUT_CMDLINE+=("rd.md.uuid=$(uuid_to_mduuid "$uuid")")
	DISK_ACTIONS+=("action=create_raid" "$@" ";")
}

# Named arguments:
# new_id:  Id for the new luks
# id:      The operand device id (use this form for a partition)
# device:  A direct whole-device operand
function create_luks() {
	USED_LUKS=true
	USED_ENCRYPTION=true

	local known_arguments=('+new_id' '+name' '+device|id')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	only_one_of device id
	[[ -v arguments[device] ]] \
		&& register_destructive_device "${arguments[device]}"
	create_new_id new_id
	[[ -v arguments[id] ]] \
		&& { verify_existing_id id; reject_registered_existing_ids_for_destructive_action "create LUKS on" "${arguments[id]}"; }

	local new_id="${arguments[new_id]}"
	local name="${arguments[name]}"
	local uuid="${DISK_ID_TO_UUID[$new_id]}"
	[[ ! -v "INSTALLER_PLANNED_LUKS_MAPPING_SET[$name]" ]] \
		|| die_trace 1 "LUKS mapping name '$name' is used more than once"
	INSTALLER_PLANNED_LUKS_MAPPING_SET[$name]=true
	INSTALLER_PLANNED_LUKS_MAPPINGS+=("$name")
	create_resolve_entry "$new_id" luks "$name"
	DISK_DRACUT_CMDLINE+=("rd.luks.uuid=$uuid")
	DISK_ACTIONS+=("action=create_luks" "$@" ";")
}

# Named arguments:
# new_id:  Id for the new luks
# device:  The whole device
function create_dummy() {
	local known_arguments=('+new_id' '+device')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	register_destructive_device "${arguments[device]}"
	create_new_id new_id

	local new_id="${arguments[new_id]}"
	local device="${arguments[device]}"
	local uuid="${DISK_ID_TO_UUID[$new_id]}"
	create_resolve_entry_device "$new_id" "$device"
	DISK_ACTIONS+=("action=create_dummy" "$@" ";")
}

# Named arguments:
# id:     Id of the device / partition created earlier
# type:   One of (bios, efi, swap, ext4)
# label:  The label for the formatted disk
function format() {
	local known_arguments=('+id' '+type' '?label')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	verify_existing_id id
	reject_registered_existing_ids_for_destructive_action "format" "${arguments[id]}"
	verify_option type bios efi swap ext4 btrfs

	local type="${arguments[type]}"
	if [[ "$type" == "btrfs" ]]; then
		USED_BTRFS=true
	fi

	DISK_ACTIONS+=("action=format" "$@" ";")
}

# Named arguments:
# ids:       List of ids for devices / partitions created earlier. Must contain at least 1 element.
# pool_type: The zfs pool type
# encrypt:   Whether or not to encrypt the pool
function format_zfs() {
	USED_ZFS=true

	local known_arguments=('+ids' '?pool_type' '?encrypt' '?compress')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	verify_existing_unique_ids ids
	reject_registered_existing_ids_for_destructive_action "format ZFS on" "${arguments[ids]}"

	USED_ENCRYPTION=${arguments[encrypt]:-false}
	DISK_ACTIONS+=("action=format_zfs" "$@" ";")
}

# Named arguments:
# ids:     List of ids for devices / partitions created earlier. Must contain at least 1 element.
# label:   The label for the formatted disk
function format_btrfs() {
	USED_BTRFS=true

	local known_arguments=('+ids' '?raid_type' '?label')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	verify_existing_unique_ids ids
	reject_registered_existing_ids_for_destructive_action "format Btrfs on" "${arguments[ids]}"

	DISK_ACTIONS+=("action=format_btrfs" "$@" ";")
}

# Returns a comma separated list of all registered ids matching the given regex.
function expand_ids() {
	local regex="$1"
	for id in "${!DISK_ID_TO_UUID[@]}"; do
		[[ $id =~ $regex ]] \
			&& echo -n "$id;"
	done
}

# Single disk, 3 partitions (efi, swap, root)
# Parameters:
#   swap=<size>           Create a swap partition with given size, or no swap at all if set to false.
#   type=[efi|bios]       Selects the boot type. Defaults to efi if not given.
#   luks=[true|false]     Encrypt root partition. Defaults to false if not given.
#   root_fs=[ext4|btrfs]  Root filesystem. Defaults to ext4 if not given.
function create_classic_single_disk_layout() {
	local known_arguments=('+swap' '?type' '?luks' '?root_fs')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	[[ ${#extra_arguments[@]} -eq 1 ]] \
		|| die_trace 1 "Expected exactly one positional argument (the device)"
	local device="${extra_arguments[0]}"
	local size_swap="${arguments[swap]}"
	local type="${arguments[type]:-efi}"
	local use_luks="${arguments[luks]:-false}"
	local root_fs="${arguments[root_fs]:-ext4}"
	validate_destructive_whole_block_devices 1 "classic single-disk layout" "$device"

	create_gpt new_id=gpt device="$device"
	create_partition new_id="part_$type" id=gpt size=1GiB       type="$type"
	[[ $size_swap != "false" ]] \
		&& create_partition new_id=part_swap    id=gpt size="$size_swap" type=swap
	create_partition new_id=part_root    id=gpt size=remaining    type=linux

	local root_id="part_root"
	if [[ "$use_luks" == "true" ]]; then
		create_luks new_id=part_luks_root name="root" id=part_root
		root_id="part_luks_root"
	fi

	format id="part_$type" type="$type" label="$type"
	[[ $size_swap != "false" ]] \
		&& format id=part_swap type=swap label=swap
	format id="$root_id" type="$root_fs" label=root

	if [[ $type == "efi" ]]; then
		DISK_ID_EFI="part_$type"
	else
		DISK_ID_BIOS="part_$type"
	fi
	[[ $size_swap != "false" ]] \
		&& DISK_ID_SWAP=part_swap
	DISK_ID_ROOT="$root_id"

	if [[ $root_fs == "btrfs" ]]; then
		DISK_ID_ROOT_TYPE="btrfs"
		DISK_ID_ROOT_MOUNT_OPTS="defaults,noatime,compress-force=zstd,subvol=/root"
	elif [[ $root_fs == "ext4" ]]; then
		DISK_ID_ROOT_TYPE="ext4"
		DISK_ID_ROOT_MOUNT_OPTS="defaults,noatime,errors=remount-ro,discard"
	else
		die "Unsupported root filesystem type"
	fi
}

function create_single_disk_layout() {
	die "'create_single_disk_layout' is deprecated, please use 'create_classic_single_disk_layout' instead. It is fully option-compatible to the old version."
}

# Skip partitioning, and use existing pre-formatted partitions. These must be trivially mountable.
# Parameters:
#   swap=<device|false>   Use the given device as swap, or no swap at all if set to false.
#   boot=<device>         Use the given device as the bios/efi partition.
#   type=[efi|bios]       Selects the boot type. Defaults to efi if not given.
function create_existing_partitions_layout() {
	NO_PARTITIONING_OR_FORMATTING=true

	local known_arguments=('+swap' '+boot' '?type')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	[[ ${#extra_arguments[@]} -eq 1 ]] \
		|| die_trace 1 "Expected exactly one positional argument (the device)"
	local device="${extra_arguments[0]}"
	local swap_device="${arguments[swap]}"
	local boot_device="${arguments[boot]}"
	local type="${arguments[type]:-efi}"

	register_existing new_id="part_$type" device="$boot_device"
	[[ $swap_device != "false" ]] \
		&& register_existing new_id="part_swap" device="$swap_device"
	register_existing new_id="part_root" device="$device"

	if [[ $type == "efi" ]]; then
		DISK_ID_EFI="part_$type"
	else
		DISK_ID_BIOS="part_$type"
	fi
	[[ $swap_device != "false" ]] \
		&& DISK_ID_SWAP=part_swap
	DISK_ID_ROOT="part_root"
	DISK_ID_ROOT_TYPE="" # unknown, could be anything. Left empty to skip generating an fstab entry.
}

# Multiple disks, up to 3 partitions on first disk (efi, optional swap, root with zfs).
# Additional devices will be added to the zfs pool.
# Parameters:
#   swap=<size>                     Create a swap partition with given size, or no swap at all if set to false.
#   type=[efi|bios]                 Selects the boot type. Defaults to efi if not given.
#   encrypt=[true|false]            Encrypt the zfs datasets. Defaults to false if not given.
#   compress=[false|<compression>]  Compress the zfs datasets. For valid values visit man zfsprops. Defaults to false if not given.
#   pool_type=[standard|custom]     Select zfs pool type. Custom pools allow you to do the pool creation yourself. Defaults to standard.
function create_zfs_centric_layout() {
	local known_arguments=('+swap' '?type' '?encrypt' '?compress' '?pool_type')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	[[ ${#extra_arguments[@]} -gt 0 ]] \
		|| die_trace 1 "Expected at least one positional argument (the devices)"
	local device="${extra_arguments[0]}"
	local size_swap="${arguments[swap]}"
	local type="${arguments[type]:-efi}"
	local encrypt="${arguments[encrypt]:-false}"
	local compress="${arguments[compress]:-false}"
	local pool_type="${arguments[pool_type]:-standard}"
	validate_destructive_whole_block_devices 1 "ZFS-centric layout" "${extra_arguments[@]}"

	# Create layout on first disk
	create_gpt new_id="gpt_dev0" device="${extra_arguments[0]}"
	create_partition new_id="part_${type}_dev0" id="gpt_dev0" size=1GiB       type="$type"
	[[ $size_swap != "false" ]] \
		&& create_partition new_id="part_swap_dev0"    id="gpt_dev0" size="$size_swap" type=swap
	create_partition new_id="part_root_dev0"    id="gpt_dev0" size=remaining    type=linux

	local root_id="part_root_dev0"
	local root_ids="part_root_dev0;"
	local dev_id
	for i in "${!extra_arguments[@]}"; do
		[[ $i != 0 ]] || continue
		dev_id="root_dev$i"
		create_dummy new_id="$dev_id" device="${extra_arguments[$i]}"
		root_ids="${root_ids}$dev_id;"
	done

	format id="part_${type}_dev0" type="$type" label="$type"
	[[ $size_swap != "false" ]] \
		&& format id="part_swap_dev0" type=swap label=swap
	format_zfs ids="$root_ids" encrypt="$encrypt" compress="$compress" pool_type="$pool_type"

	if [[ $type == "efi" ]]; then
		DISK_ID_EFI="part_${type}_dev0"
	else
		DISK_ID_BIOS="part_${type}_dev0"
	fi
	[[ $size_swap != "false" ]] \
		&& DISK_ID_SWAP=part_swap_dev0
	DISK_ID_ROOT="$root_id"
	DISK_ID_ROOT_TYPE="zfs"
}

# Multiple disks, with raid 0 and luks
# - efi:  partition on all disks, but only first disk used
# - swap: raid 0 → fs
# - root: raid 0 → luks → fs
# Parameters:
#   swap=<size>           Create a swap partition with given size for each disk, or no swap at all if set to false.
#   type=[efi|bios]       Selects the boot type. Defaults to efi if not given.
#   luks=[true|false]     Encrypt root partition. Defaults to true if not given.
#   root_fs=[ext4|btrfs]  Root filesystem. Defaults to ext4 if not given.
function create_raid0_luks_layout() {
	local known_arguments=('+swap' '?type' '?luks' '?root_fs')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	[[ ${#extra_arguments[@]} -ge 2 ]] \
		|| die_trace 1 "RAID0 requires at least two positional device arguments"
	local size_swap="${arguments[swap]}"
	local type="${arguments[type]:-efi}"
	local use_luks="${arguments[luks]:-true}"
	local root_fs="${arguments[root_fs]:-ext4}"
	validate_destructive_whole_block_devices 2 "RAID0 layout" "${extra_arguments[@]}"

	for i in "${!extra_arguments[@]}"; do
		create_gpt new_id="gpt_dev${i}" device="${extra_arguments[$i]}"
		create_partition new_id="part_${type}_dev${i}" id="gpt_dev${i}" size=1GiB       type="$type"
		[[ $size_swap != "false" ]] \
			&& create_partition new_id="part_swap_dev${i}"    id="gpt_dev${i}" size="$size_swap" type=raid
		create_partition new_id="part_root_dev${i}"    id="gpt_dev${i}" size=remaining    type=raid
	done

	[[ $size_swap != "false" ]] \
		&& create_raid new_id=part_raid_swap name="swap" level=0 ids="$(expand_ids '^part_swap_dev[[:digit:]]$')"
	create_raid new_id=part_raid_root name="root" level=0 ids="$(expand_ids '^part_root_dev[[:digit:]]$')"

	local root_id="part_raid_root"
	if [[ "$use_luks" == "true" ]]; then
		create_luks new_id=part_luks_root name="root" id=part_raid_root
		root_id="part_luks_root"
	fi

	format id="part_${type}_dev0" type="$type" label="$type"
	[[ $size_swap != "false" ]] \
		&& format id=part_raid_swap type=swap label=swap
	format id="$root_id" type="$root_fs" label=root

	if [[ $type == "efi" ]]; then
		DISK_ID_EFI="part_${type}_dev0"
	else
		DISK_ID_BIOS="part_${type}_dev0"
	fi
	[[ $size_swap != "false" ]] \
		&& DISK_ID_SWAP=part_raid_swap
	DISK_ID_ROOT="$root_id"

	if [[ $root_fs == "btrfs" ]]; then
		DISK_ID_ROOT_TYPE="btrfs"
		DISK_ID_ROOT_MOUNT_OPTS="defaults,noatime,compress=zstd,subvol=/root"
	elif [[ $root_fs == "ext4" ]]; then
		DISK_ID_ROOT_TYPE="ext4"
		DISK_ID_ROOT_MOUNT_OPTS="defaults,noatime,errors=remount-ro,discard"
	else
		die "Unsupported root filesystem type"
	fi
}

# Multiple disks, with raid 1 and luks
# - efi:  raid 1 → fs
# - swap: raid 1 → fs
# - root: raid 1 → luks → fs
# Parameters:
#   swap=<size>           Create a swap partition with given size for each disk, or no swap at all if set to false.
#   type=[efi|bios]       Selects the boot type. Defaults to efi if not given.
#   luks=[true|false]     Encrypt root partition. Defaults to true if not given.
#   root_fs=[ext4|btrfs]  Root filesystem. Defaults to ext4 if not given.
function create_raid1_luks_layout() {
	local known_arguments=('+swap' '?type' '?luks' '?root_fs')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	[[ ${#extra_arguments[@]} -ge 2 ]] \
		|| die_trace 1 "RAID1 requires at least two positional device arguments"
	local size_swap="${arguments[swap]}"
	local type="${arguments[type]:-efi}"
	local use_luks="${arguments[luks]:-true}"
	local root_fs="${arguments[root_fs]:-ext4}"
	validate_destructive_whole_block_devices 2 "RAID1 layout" "${extra_arguments[@]}"

	for i in "${!extra_arguments[@]}"; do
		create_gpt new_id="gpt_dev${i}" device="${extra_arguments[$i]}"
		create_partition new_id="part_${type}_dev${i}" id="gpt_dev${i}" size=1GiB       type="$type"
		[[ $size_swap != "false" ]] \
			&& create_partition new_id="part_swap_dev${i}"    id="gpt_dev${i}" size="$size_swap" type=raid
		create_partition new_id="part_root_dev${i}"    id="gpt_dev${i}" size=remaining    type=raid
	done

	create_raid new_id="part_raid_${type}" name="$type" level=1 ids="$(expand_ids "^part_${type}_dev[[:digit:]]$")"
	[[ $size_swap != "false" ]] \
		&& create_raid new_id=part_raid_swap name="swap" level=1 ids="$(expand_ids '^part_swap_dev[[:digit:]]$')"
	create_raid new_id=part_raid_root name="root" level=1 ids="$(expand_ids '^part_root_dev[[:digit:]]$')"

	local root_id="part_raid_root"
	if [[ "$use_luks" == "true" ]]; then
		create_luks new_id=part_luks_root name="root" id=part_raid_root
		root_id="part_luks_root"
	fi

	format id="part_raid_${type}" type="$type" label="$type"
	[[ $size_swap != "false" ]] \
		&& format id=part_raid_swap type=swap label=swap
	format id="$root_id" type="$root_fs" label=root

	if [[ $type == "efi" ]]; then
		DISK_ID_EFI="part_raid_${type}"
	else
		DISK_ID_BIOS="part_raid_${type}"
	fi
	[[ $size_swap != "false" ]] \
		&& DISK_ID_SWAP=part_raid_swap
	DISK_ID_ROOT="$root_id"

	if [[ $root_fs == "btrfs" ]]; then
		DISK_ID_ROOT_TYPE="btrfs"
		DISK_ID_ROOT_MOUNT_OPTS="defaults,noatime,compress=zstd,subvol=/root"
	elif [[ $root_fs == "ext4" ]]; then
		DISK_ID_ROOT_TYPE="ext4"
		DISK_ID_ROOT_MOUNT_OPTS="defaults,noatime,errors=remount-ro,discard"
	else
		die "Unsupported root filesystem type"
	fi
}

# Multiple disks, up to 3 partitions on first disk (efi, optional swap, root with btrfs).
# Additional devices will be first encrypted and then put directly into btrfs array.
# Parameters:
#   swap=<size>                Create a swap partition with given size, or no swap at all if set to false.
#   type=[efi|bios]            Selects the boot type. Defaults to efi if not given.
#   luks=[true|false]          Encrypt root partition and btrfs devices. Defaults to false if not given.
#   raid_type=[raid0|raid1]    Select raid type. Defaults to raid0.
function create_btrfs_centric_layout() {
	local known_arguments=('+swap' '?type' '?luks' '?raid_type')
	local extra_arguments=()
	declare -A arguments; parse_arguments "$@"

	[[ ${#extra_arguments[@]} -gt 0 ]] \
		|| die_trace 1 "Expected at least one positional argument (the devices)"
	local device="${extra_arguments[0]}"
	local size_swap="${arguments[swap]}"
	local type="${arguments[type]:-efi}"
	local use_luks="${arguments[luks]:-false}"
	local raid_type="${arguments[raid_type]:-raid0}"
	validate_destructive_whole_block_devices 1 "Btrfs-centric layout" "${extra_arguments[@]}"

	# Create layout on first disk
	create_gpt new_id="gpt_dev0" device="${extra_arguments[0]}"
	create_partition new_id="part_${type}_dev0" id="gpt_dev0" size=1GiB       type="$type"
	[[ $size_swap != "false" ]] \
		&& create_partition new_id="part_swap_dev0"    id="gpt_dev0" size="$size_swap" type=swap
	create_partition new_id="part_root_dev0"    id="gpt_dev0" size=remaining    type=linux

	local root_id
	local root_ids=""
	if [[ "$use_luks" == "true" ]]; then
		create_luks new_id=luks_dev0 name="luks_root_0" id=part_root_dev0
		root_id="luks_dev0"
		root_ids="${root_ids}luks_dev0;"
		for i in "${!extra_arguments[@]}"; do
			[[ $i != 0 ]] || continue
			create_luks new_id="luks_dev$i" name="luks_root_$i" device="${extra_arguments[$i]}"
			root_ids="${root_ids}luks_dev$i;"
		done
	else
		local dev_id=""
		root_id="part_root_dev0"
		root_ids="${root_ids}part_root_dev0;"
		for i in "${!extra_arguments[@]}"; do
			[[ $i != 0 ]] || continue
			dev_id="root_dev$i"
			create_dummy new_id="$dev_id" device="${extra_arguments[$i]}"
			root_ids="${root_ids}$dev_id;"
		done
	fi

	format id="part_${type}_dev0" type="$type" label="$type"
	[[ $size_swap != "false" ]] \
		&& format id="part_swap_dev0" type=swap label=swap
	format_btrfs ids="$root_ids" label=root raid_type="$raid_type"

	if [[ $type == "efi" ]]; then
		DISK_ID_EFI="part_${type}_dev0"
	else
		DISK_ID_BIOS="part_${type}_dev0"
	fi
	[[ $size_swap != "false" ]] \
		&& DISK_ID_SWAP=part_swap_dev0
	DISK_ID_ROOT="$root_id"
	DISK_ID_ROOT_TYPE="btrfs"
	DISK_ID_ROOT_MOUNT_OPTS="defaults,noatime,compress=zstd,subvol=/root"
}

function create_btrfs_raid_layout() {
	die "'create_btrfs_raid_layout' is deprecated, please use 'create_btrfs_centric_layout' instead. It is fully option-compatible to the old version."
}
