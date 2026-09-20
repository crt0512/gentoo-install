# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Functions

# True if the live system runs systemd and provides systemd-timesyncd. Several live images (for example the Arch ISO) ship no other NTP client.
function has_systemd_timesyncd() {
	command -v timedatectl >/dev/null 2>&1 \
		&& [[ -d /run/systemd/system ]] \
		&& systemctl cat systemd-timesyncd.service >/dev/null 2>&1
}

# timesyncd synchronizes in the background, so enable it and wait until the clock is actually reported as synchronized.
function sync_time_with_timesyncd() {
	timedatectl set-ntp true \
		|| return 1

	local waited=0
	while [[ $waited -lt 60 ]]; do
		[[ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)" == "yes" ]] \
			&& return 0
		sleep 1
		waited=$((waited + 1))
	done

	return 1
}

function sync_time() {
	einfo "Synchronizing time"
	if command -v ntpd >/dev/null 2>&1; then
		ntpd -g -q \
			|| die "Could not synchronize time with ntpd"
	elif command -v chronyd >/dev/null 2>&1; then
		chronyd -q 'pool pool.ntp.org iburst' \
			|| die "Could not synchronize time with chronyd"
	elif has_systemd_timesyncd; then
		sync_time_with_timesyncd \
			|| die "Could not synchronize time with systemd-timesyncd"
	else
		die "No supported NTP client found (tried ntpd, chronyd and systemd-timesyncd); refusing unauthenticated HTTP time synchronization. Install one first, for example 'pacman -Sy chrony'."
	fi

	einfo "Current date: $(LANG=C date)"
	einfo "Writing time to hardware clock"
	hwclock --systohc --utc \
		|| ewarn "Could not write synchronized time to the hardware clock"
}

# Settings without a safe default, reported together instead of failing later as an unbound variable
function check_required_config_variables() {
	local -a required=(
		HOSTNAME
		TIMEZONE
		KEYMAP
		KEYMAP_INITRAMFS
		LOCALES
		LOCALE
		GENTOO_MIRROR
		GENTOO_ARCH
		GENTOO_SUBARCH
		STAGE3_VARIANT
		STAGE3_BASENAME
		SYSTEMD
		MUSL
	)

	local -a missing=()
	local name
	for name in "${required[@]}"; do
		[[ -v "$name" ]] \
			|| missing+=("$name")
	done

	[[ ${#missing[@]} -eq 0 ]] \
		|| die "Your configuration does not define: ${missing[*]}. Compare it against gentoo.conf.example or regenerate it with ./configure."
}

# True when this cpu supports every feature of the x86-64-v3 microarchitecture level
function cpu_supports_x86_64_v3() {
	local loader output
	for loader in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
		[[ -x $loader ]] \
			|| continue
		output="$("$loader" --help 2>/dev/null)" \
			|| continue
		# Only trust the loader when it really reports the hwcaps levels
		[[ $output == *x86-64-v2* ]] \
			|| continue
		[[ $output == *"x86-64-v3 (supported"* ]]
		return
	done

	# Older loaders do not report hwcaps, so check the cpu flags themselves
	local flags
	flags="$(sed -n 's/^flags[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -n1)"
	[[ -n $flags ]] \
		|| return 1
	cpu_flags_support_x86_64_v3 "$flags"
}

# True when a /proc/cpuinfo flags line contains everything x86-64-v2 and v3 require
function cpu_flags_support_x86_64_v3() {
	local flags=" $1 "
	local feature
	for feature in cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do
		[[ $flags == *" $feature "* ]] \
			|| return 1
	done
	return 0
}

# Prints the microarchitecture level to build and fetch binary packages for
function resolve_cpu_microarch() {
	case "${CPU_MICROARCH:-auto}" in
		'x86-64'|'x86-64-v3')
			echo -n "$CPU_MICROARCH"
			;;
		'auto')
			if [[ $GENTOO_ARCH == "amd64" ]] && cpu_supports_x86_64_v3; then
				echo -n "x86-64-v3"
			else
				echo -n "x86-64"
			fi
			;;
		*) die "CPU_MICROARCH must be one of 'auto', 'x86-64' or 'x86-64-v3'" ;;
	esac
}

function check_config() {
	check_required_config_variables

	[[ $KEYMAP =~ ^[0-9A-Za-z-]*$ ]] \
		|| die "KEYMAP contains invalid characters"

	if [[ "$SYSTEMD" == "true" ]]; then
		[[ "$STAGE3_BASENAME" == *systemd* ]] \
			|| die "Using systemd requires a systemd stage3 archive!"
	else
		[[ "$STAGE3_BASENAME" != *systemd* ]] \
			|| die "Using OpenRC requires a non-systemd stage3 archive!"
	fi

	# Check hostname per RFC1123
	local hostname_regex='^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$'
	[[ $HOSTNAME =~ $hostname_regex ]] \
		|| die "'$HOSTNAME' is not a valid hostname"

	[[ -v "DISK_ID_ROOT" && -n $DISK_ID_ROOT ]] \
		|| die "You must assign DISK_ID_ROOT"
	[[ -v "DISK_ID_EFI" && -n $DISK_ID_EFI ]] || [[ -v "DISK_ID_BIOS" && -n $DISK_ID_BIOS ]] \
		|| die "You must assign DISK_ID_EFI or DISK_ID_BIOS"

	[[ -v "DISK_ID_BIOS" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_BIOS]" ]] \
		&& die "Missing uuid for DISK_ID_BIOS, have you made sure it is used?"
	[[ -v "DISK_ID_EFI" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_EFI]" ]] \
		&& die "Missing uuid for DISK_ID_EFI, have you made sure it is used?"
	[[ -v "DISK_ID_SWAP" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_SWAP]" ]] \
		&& die "Missing uuid for DISK_ID_SWAP, have you made sure it is used?"
	[[ -v "DISK_ID_ROOT" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_ROOT]" ]] \
		&& die "Missing uuid for DISK_ID_ROOT, have you made sure it is used?"

	if [[ -v "DISK_ID_EFI" ]]; then
		IS_EFI=true
	else
		IS_EFI=false
	fi

	validate_kernel_type
	validate_bootloader
	[[ ${MAX_STAGE3_AGE_DAYS:-45} =~ ^[0-9]+$ ]] \
		|| die "MAX_STAGE3_AGE_DAYS must be a non-negative integer"

	case "${REQUIRE_LUKS_HEADER_EXPORT:-false}" in
		true|false) ;;
		*) die "REQUIRE_LUKS_HEADER_EXPORT must be either true or false" ;;
	esac
	[[ $LUKS_HEADER_TARGET_DIR == /root/* && $LUKS_HEADER_TARGET_DIR != *'/../'* && $LUKS_HEADER_TARGET_DIR != */.. ]] \
		|| die "LUKS_HEADER_TARGET_DIR must be a path below /root without '..' components"

	case "${DETECT_EXISTING_PARTITIONS:-true}" in
		true|false) ;;
		*) die "DETECT_EXISTING_PARTITIONS must be either true or false" ;;
	esac

	case "${CPU_MICROARCH:-auto}" in
		auto|x86-64) ;;
		x86-64-v3)
			[[ $GENTOO_ARCH == "amd64" ]] \
				|| die "CPU_MICROARCH=x86-64-v3 requires GENTOO_ARCH=amd64" ;;
		*) die "CPU_MICROARCH must be one of 'auto', 'x86-64' or 'x86-64-v3'" ;;
	esac

	# Without these the generated .network file would leave the system without networking
	if [[ $SYSTEMD == "true" && $SYSTEMD_NETWORKD == "true" && $SYSTEMD_NETWORKD_DHCP != "true" ]]; then
		[[ ${#SYSTEMD_NETWORKD_ADDRESSES[@]} -gt 0 ]] \
			|| die "SYSTEMD_NETWORKD_DHCP=false requires at least one entry in SYSTEMD_NETWORKD_ADDRESSES"
		[[ -n $SYSTEMD_NETWORKD_GATEWAY ]] \
			|| die "SYSTEMD_NETWORKD_DHCP=false requires SYSTEMD_NETWORKD_GATEWAY"
	fi
	# The value is passed to mirrorselect as a single argument, so only reject obvious mistakes
	local country_regex="^[A-Za-z][A-Za-z .'-]*$"
	[[ -z ${SELECT_MIRRORS_COUNTRY:-} || ${SELECT_MIRRORS_COUNTRY} =~ $country_regex ]] \
		|| die "SELECT_MIRRORS_COUNTRY must be a country name as used by the gentoo mirror list"

	check_user_config
}

function check_user_config() {
	[[ -n ${CREATE_USER:-} ]] \
		|| return 0

	# Same restriction as useradd's default NAME_REGEX
	[[ $CREATE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
		|| die "CREATE_USER='$CREATE_USER' is not a valid user name"
	[[ $CREATE_USER != "root" ]] \
		|| die "CREATE_USER must not be root, use the root password prompt instead"
	[[ ${CREATE_USER_GROUPS:-} =~ ^([a-z_][a-z0-9_-]*(,[a-z_][a-z0-9_-]*)*)?$ ]] \
		|| die "CREATE_USER_GROUPS must be a comma separated list of group names"
	[[ ${CREATE_USER_SHELL:-/bin/bash} == /* ]] \
		|| die "CREATE_USER_SHELL must be an absolute path"

	case "${CREATE_USER_SUDO:-true}" in
		true|false) ;;
		*) die "CREATE_USER_SUDO must be either true or false" ;;
	esac
}

function validate_kernel_type() {
	case "${KERNEL_TYPE:-bin}" in
		bin|source) return 0 ;;
		*) die "KERNEL_TYPE must be either 'bin' or 'source' (got '${KERNEL_TYPE}')" ;;
	esac
}

function validate_bootloader() {
	local selected_bootloader="${BOOTLOADER:-}"
	if [[ -z $selected_bootloader ]]; then
		if [[ ${IS_EFI:-false} == true ]]; then
			selected_bootloader=grub
		else
			selected_bootloader=limine
		fi
		BOOTLOADER="$selected_bootloader"
	fi

	case "$selected_bootloader" in
		grub|limine|systemd-boot) ;;
		*) die "BOOTLOADER must be one of 'grub', 'limine', or 'systemd-boot' (got '$selected_bootloader')" ;;
	esac

	if [[ $selected_bootloader == "systemd-boot" && ${IS_EFI:-false} != true ]]; then
		die "BOOTLOADER=systemd-boot requires EFI boot; use type=efi or choose BOOTLOADER=limine"
	fi

	if [[ $selected_bootloader == "grub" && ${IS_EFI:-false} != true ]]; then
		die "BOOTLOADER=grub is currently supported only with EFI boot by this installer; use type=efi or choose BOOTLOADER=limine"
	fi
}

function preprocess_config() {
	disk_configuration

	# Check encryption key if used
	[[ $USED_ENCRYPTION == "true" ]] \
		&& check_encryption_key

	check_config
}

# Prepare the shared live-environment directory without following a hostile
# pre-created symlink. Existing directories must already have the exact owner
# and permissions expected by the installer; silently repairing them could
# make attacker-controlled contents trusted as installer state.
function prepare_secure_tmp_dir() {
	[[ $EUID == 0 ]] \
		|| die "Must be root"
	[[ $TMP_DIR == /tmp/* && $TMP_DIR != *'/../'* && $TMP_DIR != */.. ]] \
		|| die "TMP_DIR must be a direct path below /tmp without '..' components"

	if [[ -e $TMP_DIR || -L $TMP_DIR ]]; then
		[[ ! -L $TMP_DIR && -d $TMP_DIR ]] \
			|| die "Unsafe TMP_DIR '$TMP_DIR': expected a non-symlink directory"
		local owner mode
		read -r owner mode < <(stat -Lc '%u %a' -- "$TMP_DIR") \
			|| die "Could not inspect TMP_DIR '$TMP_DIR'"
		[[ $owner == 0 && $mode == 700 ]] \
			|| die "Unsafe TMP_DIR '$TMP_DIR': it must be owned by root with mode 0700 (found uid=$owner mode=$mode)"
	else
		mkdir --mode=0700 -- "$TMP_DIR" \
			|| die "Could not create secure TMP_DIR '$TMP_DIR'"
	fi

	# Re-check after creation to catch unexpected replacement as early as shell
	# tooling permits. All sensitive child paths inherit the installer's umask.
	[[ ! -L $TMP_DIR && -d $TMP_DIR ]] \
		|| die "TMP_DIR '$TMP_DIR' was replaced while being prepared"
	local final_owner final_mode
	read -r final_owner final_mode < <(stat -Lc '%u %a' -- "$TMP_DIR") \
		|| die "Could not verify TMP_DIR '$TMP_DIR'"
	[[ $final_owner == 0 && $final_mode == 700 ]] \
		|| die "TMP_DIR '$TMP_DIR' failed its final ownership or permission check"
}

function installer_luks_mapping_is_active() {
	cryptsetup status "$1" >/dev/null 2>&1
}

function installer_md_array_is_active() {
	mdadm --detail "$1" >/dev/null 2>&1
}

function installer_rpool_is_active() {
	zpool list -H -o name rpool 2>/dev/null | grep -qx rpool
}

# Record resource state before invoking any destructive action. A name
# collision is rejected rather than later guessing which resource is ours.
function capture_installer_resource_baselines() {
	local resource

	for resource in "${INSTALLER_PLANNED_MD_ARRAYS[@]}"; do
		if installer_md_array_is_active "$resource"; then
			INSTALLER_MD_ARRAY_PREEXISTED[$resource]=true
			die "Refusing disk actions: RAID array '$resource' is already active"
		fi
		INSTALLER_MD_ARRAY_PREEXISTED[$resource]=false
	done

	for resource in "${INSTALLER_PLANNED_LUKS_MAPPINGS[@]}"; do
		if installer_luks_mapping_is_active "$resource"; then
			INSTALLER_LUKS_MAPPING_PREEXISTED[$resource]=true
			die "Refusing disk actions: LUKS mapping '$resource' is already active"
		fi
		INSTALLER_LUKS_MAPPING_PREEXISTED[$resource]=false
	done

	if [[ $USED_ZFS == true ]] && installer_rpool_is_active; then
		INSTALLER_RPOOL_PREEXISTED=true
		die "Refusing disk actions: ZFS pool 'rpool' is already imported"
	fi
	INSTALLER_RPOOL_PREEXISTED=false
	INSTALLER_RESOURCE_BASELINES_CAPTURED=true
}

function record_installer_created_mount() {
	local mount_path="$1"
	if [[ ! -v "INSTALLER_CREATED_MOUNT_SET[$mount_path]" ]]; then
		INSTALLER_CREATED_MOUNT_SET[$mount_path]=true
		INSTALLER_CREATED_MOUNTS+=("$mount_path")
	fi
}

function unrecord_installer_created_mount() {
	local mount_path="$1"
	local recorded_path
	local -a remaining_mounts=()

	unset 'INSTALLER_CREATED_MOUNT_SET[$mount_path]'
	for recorded_path in "${INSTALLER_CREATED_MOUNTS[@]}"; do
		[[ $recorded_path == "$mount_path" ]] \
			|| remaining_mounts+=("$recorded_path")
	done
	INSTALLER_CREATED_MOUNTS=("${remaining_mounts[@]}")
}

# A lazy unmount detaches the tree but keeps the filesystem open, which blocks every later mkfs on that device
function unmount_recursively() {
	local path="$1"
	umount -R -- "$path" 2>/dev/null \
		&& return 0

	sync
	command -v udevadm >/dev/null 2>&1 \
		&& udevadm settle --timeout=10 &>/dev/null
	umount -R -- "$path" \
		&& return 0

	ewarn "Could not unmount '$path' cleanly, falling back to a lazy unmount"
	ewarn "Its filesystems stay open until every reference is gone, which can require a reboot before the devices are usable again"
	umount -R -l -- "$path"
}

# Best-effort and idempotent: this function is called from EXIT handling, where
# preserving the original failure status matters more than a secondary error.
function cleanup_installer_mounts() {
	if [[ $INSTALLER_OWNS_TARGET_MOUNTS == true ]] \
		&& command -v mountpoint >/dev/null 2>&1 \
		&& mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		einfo "Cleaning target filesystems below '$ROOT_MOUNTPOINT'"
		unmount_recursively "$ROOT_MOUNTPOINT" \
			|| ewarn "Could not fully unmount target filesystems below '$ROOT_MOUNTPOINT'"
	fi
	cleanup_installer_mounts_from 0
	return 0
}

function cleanup_installer_mounts_from() {
	local start_index="$1"
	local i mount_path
	local cleanup_status=0
	local -a mounts_to_clean=("${INSTALLER_CREATED_MOUNTS[@]:start_index}")

	for ((i=${#mounts_to_clean[@]} - 1; i >= 0; i--)); do
		mount_path="${mounts_to_clean[$i]}"
		command -v mountpoint >/dev/null 2>&1 || continue
		if mountpoint -q -- "$mount_path"; then
			einfo "Cleaning installer-created mount '$mount_path'"
			if ! unmount_recursively "$mount_path"; then
				ewarn "Could not unmount installer-created mount '$mount_path'"
				cleanup_status=1
				continue
			fi
		fi
		unrecord_installer_created_mount "$mount_path"
	done
	return "$cleanup_status"
}

function cleanup_installer_failure_resources() {
	[[ ${RUNNING_IN_INSTALLER_CHROOT:-false} != true ]] || return 0
	[[ $INSTALLER_FAILURE_CLEANUP_RUNNING != true ]] || return 0
	INSTALLER_FAILURE_CLEANUP_RUNNING=true

	cleanup_installer_mounts

	if [[ $INSTALLER_RESOURCE_BASELINES_CAPTURED == true ]]; then
		if [[ $INSTALLER_CREATED_RPOOL == true ]] \
			&& command -v zpool >/dev/null 2>&1 \
			&& installer_rpool_is_active; then
			einfo "Exporting installer-created ZFS pool 'rpool'"
			zpool export rpool \
				|| ewarn "Could not export installer-created ZFS pool 'rpool'"
		fi

		local i resource
		for ((i=${#INSTALLER_CREATED_LUKS_MAPPINGS[@]} - 1; i >= 0; i--)); do
			resource="${INSTALLER_CREATED_LUKS_MAPPINGS[$i]}"
			command -v cryptsetup >/dev/null 2>&1 || continue
			installer_luks_mapping_is_active "$resource" || continue
			einfo "Closing installer-created LUKS mapping '$resource'"
			cryptsetup close "$resource" \
				|| ewarn "Could not close installer-created LUKS mapping '$resource'"
		done

		for ((i=${#INSTALLER_CREATED_MD_ARRAYS[@]} - 1; i >= 0; i--)); do
			resource="${INSTALLER_CREATED_MD_ARRAYS[$i]}"
			command -v mdadm >/dev/null 2>&1 || continue
			installer_md_array_is_active "$resource" || continue
			einfo "Stopping installer-created RAID array '$resource'"
			mdadm --stop "$resource" \
				|| ewarn "Could not stop installer-created RAID array '$resource'"
		done
	fi

	INSTALLER_FAILURE_CLEANUP_RUNNING=false
}

function installer_exit_handler() {
	local status="$1"
	trap - EXIT INT TERM HUP
	[[ $status -ne 0 ]] || return 0
	[[ ${RUNNING_IN_INSTALLER_CHROOT:-false} != true ]] || return 0
	[[ -z ${INSTALL_LOG:-} ]] \
		|| eerror "The full output of this run was logged to '$INSTALL_LOG'"
	cleanup_installer_failure_resources
}

function installer_signal_handler() {
	local status="$1"
	trap - INT TERM HUP
	exit "$status"
}

# Mounts below a shared mount propagate into every service mount namespace, and a lazy unmount never removes those copies
function isolate_installer_tmp_dir() {
	[[ ${RUNNING_IN_INSTALLER_CHROOT:-false} != true ]] \
		|| return 0
	command -v mountpoint >/dev/null 2>&1 \
		|| return 0

	# Deliberately not cleaned up: the open install.log holds it, and a self-bind pins no device
	if ! mountpoint -q -- "$TMP_DIR"; then
		mount --bind -- "$TMP_DIR" "$TMP_DIR" \
			|| die "Could not bind '$TMP_DIR' onto itself"
	fi

	# Everything mounted below this point inherits private propagation from it
	mount --make-rprivate -- "$TMP_DIR" \
		|| die "Could not make '$TMP_DIR' a private mount"
}

function prepare_installation_environment() {
	maybe_exec 'before_prepare_environment' \
		|| die "Hook before_prepare_environment failed"

	einfo "Preparing installation environment"
	isolate_installer_tmp_dir

	local wanted_programs=(
		awk
		base64
		basename
		blkid
		chroot
		date
		dirname
		find
		grep
		gpg
		head
		hwclock
		install
		lsblk
		mkfs.fat
		mktemp
		mount
		mountpoint
		partprobe
		python3
		readlink
		realpath
		sed
		sha512sum
		sgdisk
		sort
		stat
		tar
		tr
		umount
		uuidgen
		wc
		wget
		wipefs
	)
	# Only one authenticated time source is needed duh
	if command -v chronyd >/dev/null 2>&1; then
		wanted_programs+=(chronyd)
	elif ! command -v ntpd >/dev/null 2>&1 && ! has_systemd_timesyncd; then
		wanted_programs+=(ntpd)
	fi

	[[ -v DISK_ID_SWAP ]] \
		&& wanted_programs+=(mkswap)
	[[ $DISK_ID_ROOT_TYPE == "ext4" ]] \
		&& wanted_programs+=(mkfs.ext4)
	[[ $USED_BTRFS == "true" ]] \
		&& wanted_programs+=(btrfs mkfs.btrfs)
	[[ $USED_ZFS == "true" ]] \
		&& wanted_programs+=(zfs zpool)
	[[ $USED_RAID == "true" ]] \
		&& wanted_programs+=(mdadm)
	[[ $USED_LUKS == "true" ]] \
		&& wanted_programs+=(cryptsetup)

	# Check for existence of required programs
	check_wanted_programs "${wanted_programs[@]}"
	validate_luks_header_export_destination

	# Sync time now to prevent issues later
	sync_time

	maybe_exec 'after_prepare_environment' \
		|| die "Hook after_prepare_environment failed"
}

function validate_luks_header_export_destination() {
	LUKS_HEADER_EXPORT_READY=false
	[[ $USED_LUKS == true ]] || return 0

	if [[ -z ${LUKS_HEADER_EXPORT_DIR:-} ]]; then
		[[ $REQUIRE_LUKS_HEADER_EXPORT != true ]] \
			|| die "REQUIRE_LUKS_HEADER_EXPORT=true requires LUKS_HEADER_EXPORT_DIR"
		return 0
	fi

	local reason=""
	[[ $LUKS_HEADER_EXPORT_DIR == /* ]] \
		|| reason="it is not an absolute path"
	if [[ -z $reason && ( -L $LUKS_HEADER_EXPORT_DIR || ! -d $LUKS_HEADER_EXPORT_DIR ) ]]; then
		reason="it is not an existing non-symlink directory"
	fi
	[[ -n $reason || -w $LUKS_HEADER_EXPORT_DIR ]] \
		|| reason="it is not writable"

	if [[ -n $reason ]]; then
		if [[ $REQUIRE_LUKS_HEADER_EXPORT == true ]]; then
			die "Required LUKS header export directory '$LUKS_HEADER_EXPORT_DIR' is unavailable: $reason"
		fi
		ewarn "Skipping optional LUKS header export to '$LUKS_HEADER_EXPORT_DIR': $reason"
		return 0
	fi

	LUKS_HEADER_EXPORT_READY=true
}

function check_encryption_key() {
	if [[ -z "${GENTOO_INSTALL_ENCRYPTION_KEY+set}" ]]; then
		elog "You have enabled encryption, but haven't specified a key in the environment variable GENTOO_INSTALL_ENCRYPTION_KEY."
		if ask "Do you want to enter an encryption key now?"; then
			local encryption_key_1
			local encryption_key_2

			while true; do
				flush_stdin
				IFS="" read -s -r -p "Enter encryption key: " encryption_key_1 \
					|| die "Error in read"
				echo

				[[ ${#encryption_key_1} -ge 8 ]] \
					|| { ewarn "Your encryption key must be at least 8 characters long."; continue; }

				flush_stdin
				IFS="" read -s -r -p "Repeat encryption key: " encryption_key_2 \
					|| die "Error in read"
				echo

				[[ "$encryption_key_1" == "$encryption_key_2" ]] \
					|| { ewarn "Encryption keys mismatch."; continue; }
				break
			done

			export GENTOO_INSTALL_ENCRYPTION_KEY="$encryption_key_1"
		else
			die "Please export GENTOO_INSTALL_ENCRYPTION_KEY with the desired key."
		fi
	fi

	[[ ${#GENTOO_INSTALL_ENCRYPTION_KEY} -ge 8 ]] \
		|| die "Your encryption key must be at least 8 characters long."
}

function add_summary_entry() {
	local parent="$1"
	local id="$2"
	local name="$3"
	local hint="$4"
	local desc="$5"

	local ptr
	case "$id" in
		"${DISK_ID_BIOS-__unused__}")  ptr="[1;32m← bios[m" ;;
		"${DISK_ID_EFI-__unused__}")   ptr="[1;32m← efi[m"  ;;
		"${DISK_ID_SWAP-__unused__}")  ptr="[1;34m← swap[m" ;;
		"${DISK_ID_ROOT-__unused__}")  ptr="[1;33m← root[m" ;;
		# \x1f characters compensate for printf byte count and unicode character count mismatch due to '←'
		*)                             ptr="[1;32m[m$(echo -e "\x1f\x1f")" ;;
	esac

	summary_tree[$parent]+=";$id"
	summary_name[$id]="$name"
	summary_hint[$id]="$hint"
	summary_ptr[$id]="$ptr"
	summary_desc[$id]="$desc"
}

function summary_color_args() {
	for arg in "$@"; do
		if [[ -v "arguments[$arg]" ]]; then
			printf '%-28s ' "[1;34m$arg[2m=[m${arguments[$arg]}"
		fi
	done
}

function disk_existing() {
	local new_id="${arguments[new_id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry __root__ "$new_id" "${arguments[device]}" "(no-format, existing)" ""
	fi
	# no-op;
}

function disk_create_gpt() {
	local new_id="${arguments[new_id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -v arguments[id] ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "gpt" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(gpt)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -v arguments[id] ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")" \
			|| die "Could not resolve device with id=${arguments[id]}"
		device_desc="$device (${arguments[id]})"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	local ptuuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "Creating new gpt partition table ($new_id) on $device_desc"
	wipefs --quiet --all --force "$device" \
		|| die "Could not erase previous file system signatures from '$device'"
	sgdisk -Z -U "$ptuuid" "$device" >/dev/null \
		|| die "Could not create new gpt partition table ($new_id) on '$device'"
	partprobe "$device" \
		|| die "Could not notify the kernel about the new GPT on '$device'"
}

function disk_create_partition() {
	local new_id="${arguments[new_id]}"
	local id="${arguments[id]}"
	local size="${arguments[size]}"
	local type="${arguments[type]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry "$id" "$new_id" "part" "($type)" "$(summary_color_args size)"
		return 0
	fi

	if [[ $size == "remaining" ]]; then
		arg_size=0
	else
		arg_size="+$size"
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"
	local partuuid="${DISK_ID_TO_UUID[$new_id]}"
	local extra_args=""
	case "$type" in
		'bios')  type='ef02' extra_args='--attributes=0:set:2';;
		'efi')   type='ef00' ;;
		'swap')  type='8200' ;;
		'raid')  type='fd00' ;;
		'luks')  type='8309' ;;
		'linux') type='8300' ;;
		*) ;;
	esac

	einfo "Creating partition ($new_id) with type=$type, size=$size on $device"
	# shellcheck disable=SC2086
	sgdisk -n "0:0:$arg_size" -t "0:$type" -u "0:$partuuid" $extra_args "$device" >/dev/null \
		|| die "Could not create new gpt partition ($new_id) on '$device' ($id)"
	partprobe "$device" \
		|| die "Could not notify the kernel about the new partition on '$device'"

	# On some system, we need to wait a bit for the partition to show up.
	local new_device="/dev/disk/by-partuuid/${partuuid,,}"
	for i in {1..10}; do
		[[ -e "$new_device" ]] && break
		[[ "$i" -eq 1 ]] && printf "Waiting for partition (%s) to appear..." "$new_device"
		printf " %s" "$((10 - i + 1))"
		sleep 1
		[[ "$i" -eq 10 ]] && echo
	done
	[[ -e $new_device ]] \
		|| die "New partition ($new_id) did not appear at '$new_device'"
}

function disk_create_raid() {
	local new_id="${arguments[new_id]}"
	local level="${arguments[level]}"
	local name="${arguments[name]}"
	local ids="${arguments[ids]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "_$new_id" "raid$level" "" "$(summary_color_args name)"
		done

		add_summary_entry __root__ "$new_id" "raid$level" "" "$(summary_color_args name)"
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	local mddevice="/dev/md/$name"
	local uuid="${DISK_ID_TO_UUID[$new_id]}"

	extra_args=()
	if [[ "$level" == 1 && ("$name" == "efi" || "$name" == "bios") ]]; then
		extra_args+=("--metadata=1.0")
	else
		extra_args+=("--metadata=1.2")
	fi

# See https://serverfault.com/questions/1163715/mdadm-value-arch12021-cannot-be-set-as-devname-reason-not-posix-compatible
	# Reused partitions can still carry a raid superblock, which would make mdadm ask for confirmation
	release_device_claims "${devices[@]}"
	wipefs --quiet --all --force "${devices[@]}" \
		|| die "Could not erase previous file system signatures from $devices_desc"

	einfo "Creating raid$level ($new_id) on $devices_desc"
	mdadm \
			--create "$mddevice" \
			--verbose \
			--level="$level" \
			--raid-devices="${#devices[@]}" \
			--uuid="$uuid" \
			--homehost="$HOSTNAME" \
			"${extra_args[@]}" \
			"${devices[@]}" \
		|| die "Could not create raid$level array '$mddevice' ($new_id) on $devices_desc"
	INSTALLER_CREATED_MD_ARRAYS+=("$mddevice")
}

function disk_create_luks() {
	local new_id="${arguments[new_id]}"
	local name="${arguments[name]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -v arguments[id] ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "luks" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(luks)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -v arguments[id] ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")" \
			|| die "Could not resolve device with id=${arguments[id]}"
		device_desc="$device (${arguments[id]})"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	local uuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "Creating luks ($new_id) on $device_desc"
	release_device_claims "$device"
	cryptsetup luksFormat \
			--type luks2 \
			--uuid "$uuid" \
			--key-file <(echo -n "$GENTOO_INSTALL_ENCRYPTION_KEY") \
			--cipher aes-xts-plain64 \
			--hash sha512 \
			--pbkdf argon2id \
			--iter-time 4000 \
			--key-size 512 \
			--batch-mode \
			"$device" \
		|| die "Could not create luks on $device_desc"
	[[ ! -L $LUKS_HEADER_BACKUP_DIR ]] \
		|| die "Refusing symlink LUKS header backup directory '$LUKS_HEADER_BACKUP_DIR'"
	install -d -m 0700 -o root -g root -- "$LUKS_HEADER_BACKUP_DIR" \
		|| die "Could not create LUKS header backup dir '$LUKS_HEADER_BACKUP_DIR'"
	local header_file="$LUKS_HEADER_BACKUP_DIR/luks-header-${uuid,,}.img"
	[[ ! -e $header_file ]] \
		|| rm "$header_file" \
		|| die "Could not remove old luks header backup file '$header_file'"
	cryptsetup luksHeaderBackup "$device" \
			--header-backup-file "$header_file" \
		|| die "Could not backup luks header on $device_desc"
	chmod 0400 -- "$header_file" \
		|| die "Could not protect LUKS header backup '$header_file'"
	INSTALLER_CREATED_LUKS_HEADERS+=("$header_file")
	cryptsetup open --type luks2 \
			--key-file <(echo -n "$GENTOO_INSTALL_ENCRYPTION_KEY") \
			"$device" "$name" \
		|| die "Could not open luks encrypted device $device_desc"
	INSTALLER_CREATED_LUKS_MAPPINGS+=("$name")
}

function disk_create_dummy() {
	local new_id="${arguments[new_id]}"
	local device="${arguments[device]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry __root__ "$new_id" "$device" "" ""
		return 0
	fi
}

function init_btrfs() {
	local device="$1"
	local desc="$2"
	mkdir -p /btrfs \
		|| die "Could not create /btrfs directory"
	mount "$device" /btrfs \
		|| die "Could not mount $desc to /btrfs"
	record_installer_created_mount /btrfs
	btrfs subvolume create /btrfs/root \
		|| die "Could not create btrfs subvolume /root on $desc"
	btrfs subvolume set-default /btrfs/root \
		|| die "Could not set default btrfs subvolume to /root on $desc"
	umount /btrfs \
		|| die "Could not unmount btrfs on $desc"
	unrecord_installer_created_mount /btrfs
}

# Drops stale claims on a device, a registered btrfs keeps it open and makes mkfs fail with EBUSY
function release_device_claims() {
	local device
	local output
	for device in "$@"; do
		swapoff "$device" &>/dev/null
		if command -v btrfs >/dev/null 2>&1; then
			if output="$(btrfs device scan --forget "$device" 2>&1)"; then
				elog "Released stale btrfs registration for '$device'"
			elif [[ -n $output ]]; then
				elog "btrfs device scan --forget '$device': $output"
			fi
		fi
	done

	command -v udevadm >/dev/null 2>&1 \
		&& udevadm settle --timeout=10 &>/dev/null
	return 0
}

# Probes the exclusive open that mkfs and cryptsetup need, without writing anything
function device_is_free() {
	# Without python3 the probe is skipped, the format itself still reports a busy device
	command -v python3 >/dev/null 2>&1 \
		|| return 0

	python3 -c 'import os, sys; os.close(os.open(sys.argv[1], os.O_WRONLY | os.O_EXCL))' "$1" &>/dev/null
}

# Prints whatever still claims a device, since an exclusive open fails while any of this exists
function report_device_holders() {
	local device="$1"
	local real
	real="$(realpath -e -- "$device" 2>/dev/null)" \
		|| real="$device"
	local name="${real##*/}"
	local line
	local devno
	devno="$(lsblk --nodeps --noheadings --output MAJ:MIN -- "$real" 2>/dev/null | tr -d '[:space:]')"

	# A mount records the path it was given, and only its own namespace lists it, so match the device number everywhere
	local -A seen_namespaces=()
	local mountinfo pid namespace
	for mountinfo in /proc/[0-9]*/mountinfo; do
		[[ -n $devno ]] \
			|| break
		grep -q " $devno " "$mountinfo" 2>/dev/null \
			|| continue
		pid="${mountinfo#/proc/}"
		pid="${pid%%/*}"
		namespace="$(readlink -- "/proc/$pid/ns/mnt" 2>/dev/null)" \
			|| namespace="unknown"
		[[ -v seen_namespaces[$namespace] ]] \
			&& continue
		seen_namespaces[$namespace]=true
		eerror "  mounted in the namespace of pid $pid ($(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)):"
		while read -r line; do
			eerror "    $line"
		done < <(grep " $devno " "$mountinfo" 2>/dev/null)
	done

	while read -r line; do
		[[ -z $line ]] \
			|| eerror "  swap: $line"
	done < <(grep -F -- "$name" /proc/swaps 2>/dev/null)

	local holder
	for holder in "/sys/class/block/$name/holders"/*; do
		[[ -e $holder ]] \
			&& eerror "  stacked device: ${holder##*/}"
	done

	local fd pid
	for fd in /proc/[0-9]*/fd/*; do
		[[ "$(readlink -- "$fd" 2>/dev/null)" == "$real" ]] \
			|| continue
		pid="${fd#/proc/}"
		pid="${pid%%/*}"
		eerror "  opened by pid $pid: $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
	done

	if command -v btrfs >/dev/null 2>&1; then
		while read -r line; do
			[[ -z $line ]] \
				|| eerror "  btrfs: $line"
		done < <(btrfs filesystem show "$real" 2>&1)
	fi
}

function disk_format() {
	local id="${arguments[id]}"
	local type="${arguments[type]}"
	local label="${arguments[label]-}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry "${arguments[id]}" "__fs__${arguments[id]}" "${arguments[type]}" "(fs)" "$(summary_color_args label)"
		return 0
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"

	einfo "Formatting $device ($id) with $type"
	release_device_claims "$device"
	if ! device_is_free "$device"; then
		eerror "Something still holds '$device' ($id), formatting it will most likely fail:"
		report_device_holders "$device"
	fi
	wipefs --quiet --all --force "$device" \
		|| die "Could not erase previous file system signatures from '$device' ($id)"

	case "$type" in
		'bios'|'efi')
			if [[ -v "arguments[label]" ]]; then
				mkfs.fat -F 32 -n "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.fat -F 32 "$device" \
					|| die "Could not format device '$device' ($id)"
			fi
			;;
		'swap')
			if [[ -v "arguments[label]" ]]; then
				mkswap -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkswap "$device" \
					|| die "Could not format device '$device' ($id)"
			fi

			# Try to swapoff in case the system enabled swap automatically
			swapoff "$device" &>/dev/null
			;;
		'ext4')
			if [[ -v "arguments[label]" ]]; then
				mkfs.ext4 -q -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.ext4 -q "$device" \
					|| die "Could not format device '$device' ($id)"
			fi
			;;
		'btrfs')
			if [[ -v "arguments[label]" ]]; then
				mkfs.btrfs -q -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.btrfs -q "$device" \
					|| die "Could not format device '$device' ($id)"
			fi

			init_btrfs "$device" "'$device' ($id)"
			;;
		*) die "Unknown filesystem type" ;;
	esac
}

# This function will be called when a custom zfs pool type has been chosen.
# $1: either 'true' or 'false' determining if the datasets should be encrypted
# $2: either 'false' or a value determining the dataset compression algorithm
# $3: a string describing all device paths (for error messages)
# $@: device paths
function format_zfs_standard() {
	local encrypt="$1"
	local compress="$2"
	local device_desc="$3"
	shift 3
	local devices=("$@")
	local extra_args=()

	einfo "Creating zfs pool on $devices_desc"

	local zfs_stdin=""
	if [[ "$encrypt" == true ]]; then
		extra_args+=(
			"-O" "encryption=aes-256-gcm"
			"-O" "keyformat=passphrase"
			"-O" "keylocation=prompt"
			)

		zfs_stdin="$GENTOO_INSTALL_ENCRYPTION_KEY"
	fi

	# dnodesize=legacy might be needed for GRUB2, but auto is preferred for xattr=sa.
	zpool create \
		-R "$ROOT_MOUNTPOINT" \
		-o ashift=12          \
		-O acltype=posix      \
		-O atime=off          \
		-O xattr=sa           \
		-O dnodesize=auto     \
		-O mountpoint=none    \
		-O canmount=noauto    \
		-O devices=off        \
		"${extra_args[@]}"    \
		rpool                 \
		"${devices[@]}"       \
			<<< "$zfs_stdin"  \
		|| die "Could not create zfs pool on $devices_desc"
	INSTALLER_CREATED_RPOOL=true

	if [[ "$compress" != false ]]; then
		zfs set "compression=$compress" rpool \
			|| die "Could enable compression on dataset 'rpool'"
	fi
	zfs create rpool/ROOT \
		|| die "Could not create zfs dataset 'rpool/ROOT'"
	zfs create -o mountpoint=/ rpool/ROOT/default \
		|| die "Could not create zfs dataset 'rpool/ROOT/default'"
	zpool set bootfs=rpool/ROOT/default rpool \
		|| die "Could not set zfs property bootfs on rpool"
}

function disk_format_zfs() {
	local ids="${arguments[ids]}"
	local pool_type="${arguments[pool_type]:-standard}"
	local encrypt="${arguments[encrypt]-false}"
	local compress="${arguments[compress]-false}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "__fs__$id" "zfs" "(fs)" "$(summary_color_args label)"
		done
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	release_device_claims "${devices[@]}"
	wipefs --quiet --all --force "${devices[@]}" \
		|| die "Could not erase previous file system signatures from $devices_desc"

	if [[ "$pool_type" == "custom" ]]; then
		format_zfs_custom "$devices_desc" "${devices[@]}" \
			|| die "Custom ZFS pool creation failed"
	else
		format_zfs_standard "$encrypt" "$compress" "$devices_desc" "${devices[@]}" \
			|| die "Standard ZFS pool creation failed"
	fi
	installer_rpool_is_active \
		|| die "ZFS formatting returned without an active 'rpool'"
	INSTALLER_CREATED_RPOOL=true
}

function disk_format_btrfs() {
	local ids="${arguments[ids]}"
	local label="${arguments[label]-}"
	local raid_type="${arguments[raid_type]:-raid0}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "__fs__$id" "btrfs" "(fs)" "$(summary_color_args label)"
		done
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	release_device_claims "${devices[@]}"
	wipefs --quiet --all --force "${devices[@]}" \
		|| die "Could not erase previous file system signatures from $devices_desc"

	# Collect extra arguments
	extra_args=()
	if [[ "${#devices}" -gt 1 ]] && [[ -v "arguments[raid_type]" ]]; then
		extra_args+=("-d" "$raid_type")
	fi

	if [[ -v "arguments[label]" ]]; then
		extra_args+=("-L" "$label")
	fi

	einfo "Creating btrfs on $devices_desc"
	mkfs.btrfs -q "${extra_args[@]}" "${devices[@]}" \
		|| die "Could not create btrfs on $devices_desc"

	init_btrfs "${devices[0]}" "btrfs array ($devices_desc)"
}

# Prints the gpt type code that create_partition would use for a configured partition type
function gpt_type_code_for_type() {
	case "$1" in
		'bios')  echo -n ef02 ;;
		'efi')   echo -n ef00 ;;
		'swap')  echo -n 8200 ;;
		'raid')  echo -n fd00 ;;
		'luks')  echo -n 8309 ;;
		'linux') echo -n 8300 ;;
		*)       echo -n "${1,,}" ;;
	esac
}

# Converts a gdisk size specification like 8GiB or 512M to bytes, a plain number is a sector count
function gdisk_size_to_bytes() {
	local spec="$1"
	local sector_size="$2"
	local number="${spec%%[!0-9]*}"
	[[ -n $number ]] \
		|| return 1

	case "${spec:${#number}:1}" in
		'')             echo -n "$((number * sector_size))" ;;
		'k'|'K')        echo -n "$((number * 1024))" ;;
		'm'|'M')        echo -n "$((number * 1024 ** 2))" ;;
		'g'|'G')        echo -n "$((number * 1024 ** 3))" ;;
		't'|'T')        echo -n "$((number * 1024 ** 4))" ;;
		'p'|'P')        echo -n "$((number * 1024 ** 5))" ;;
		*)              return 1 ;;
	esac
}

# Prints the sgdisk table of a device, but only if the device really carries a gpt
function gpt_print_table() {
	local pttype
	pttype="$(lsblk --nodeps --noheadings --output PTTYPE -- "$1" 2>/dev/null)" \
		|| return 1
	[[ ${pttype//[[:space:]]/} == "gpt" ]] \
		|| return 1
	sgdisk --print "$1" 2>/dev/null
}

# Prints "start end code" for the given partition number of an sgdisk table
function gpt_partition_row() {
	awk -v number="$2" 'in_table && $1 == number { print $2, $3, $6; found = 1; exit } /^Number / { in_table = 1 } END { exit !found }' <<< "$1"
}

# Prints how many partitions an sgdisk table lists
function gpt_partition_count() {
	awk 'in_table && NF >= 6 { count++ } /^Number / { in_table = 1 } END { print count + 0 }' <<< "$1"
}

# Prints the unique partition guid of the given partition number
function gpt_partition_guid() {
	local guid
	guid="$(sgdisk --info="$2" "$1" 2>/dev/null | sed -n 's/^Partition unique GUID: *\([^ ]*\).*/\1/p' | head -n1)" \
		|| return 1
	[[ -n $guid ]] \
		|| return 1
	echo -n "$guid"
}

# Checks one partition of an sgdisk table against the configured type and size
function gpt_partition_matches() {
	local table="$1"
	local sector_size="$2"
	local last_usable="$3"
	local number="$4"
	local type="$5"
	local size="$6"

	local row
	row="$(gpt_partition_row "$table" "$number")" \
		|| return 1
	local start end code
	read -r start end code <<< "$row"
	[[ ${code,,} == "$(gpt_type_code_for_type "$type")" ]] \
		|| return 1

	# Partition starts are aligned, so accept a small deviation from the configured size
	local slack=$((2 * 1024 ** 2))
	if [[ $size == "remaining" ]]; then
		[[ $(((last_usable - end) * sector_size)) -le $slack ]]
		return
	fi

	local wanted_bytes
	wanted_bytes="$(gdisk_size_to_bytes "$size" "$sector_size")" \
		|| return 1
	local difference=$((((end - start + 1) * sector_size) - wanted_bytes))
	[[ ${difference#-} -le $slack ]]
}

# Succeeds when every configured gpt and partition already exists on disk as described
function detect_existing_partition_layout() {
	DISK_DETECTED_UUIDS=()
	local -A gpt_device=()
	local -A gpt_table=()
	local -A gpt_sector_size=()
	local -A gpt_last_usable=()
	local -A gpt_parts=()
	local -A action=()
	local -a current=()
	local param
	local key_value

	for param in "${DISK_ACTIONS[@]}"; do
		if [[ $param != ';' ]]; then
			current+=("$param")
			continue
		fi

		action=()
		for key_value in "${current[@]}"; do
			action["${key_value%%=*}"]="${key_value#*=}"
		done
		current=()

		case "${action[action]}" in
			'create_gpt')
				# A gpt on top of another id (raid, luks) is not detected, those are always recreated
				[[ -v action[device] ]] \
					|| return 1
				local gpt_id="${action[new_id]}"
				local device
				device="$(canonicalize_whole_block_device "${action[device]}")" \
					|| return 1
				local table
				table="$(gpt_print_table "$device")" \
					|| return 1
				local sector_size last_usable disk_guid
				sector_size="$(sed -n 's|^Sector size (logical/physical): *\([0-9]\{1,\}\)/.*|\1|p' <<< "$table" | head -n1)"
				last_usable="$(sed -n 's/.*last usable sector is \([0-9]\{1,\}\).*/\1/p' <<< "$table" | head -n1)"
				disk_guid="$(sed -n 's/^Disk identifier (GUID): *\([^ ]*\).*/\1/p' <<< "$table" | head -n1)"
				[[ -n $sector_size && -n $last_usable && -n $disk_guid ]] \
					|| return 1
				gpt_device[$gpt_id]="$device"
				gpt_table[$gpt_id]="$table"
				gpt_sector_size[$gpt_id]="$sector_size"
				gpt_last_usable[$gpt_id]="$last_usable"
				gpt_parts[$gpt_id]=0
				DISK_DETECTED_UUIDS[$gpt_id]="$disk_guid"
				;;
			'create_partition')
				local parent_id="${action[id]}"
				[[ -v gpt_device[$parent_id] ]] \
					|| return 1
				local number=$((gpt_parts[$parent_id] + 1))
				gpt_parts[$parent_id]="$number"
				gpt_partition_matches \
						"${gpt_table[$parent_id]}" \
						"${gpt_sector_size[$parent_id]}" \
						"${gpt_last_usable[$parent_id]}" \
						"$number" \
						"${action[type]}" \
						"${action[size]}" \
					|| return 1
				local partition_guid
				partition_guid="$(gpt_partition_guid "${gpt_device[$parent_id]}" "$number")" \
					|| return 1
				DISK_DETECTED_UUIDS["${action[new_id]}"]="$partition_guid"
				;;
		esac
	done

	[[ ${#gpt_device[@]} -gt 0 ]] \
		|| return 1

	# An extra partition means the disk holds something the configuration does not describe
	local id
	for id in "${!gpt_device[@]}"; do
		[[ ${gpt_parts[$id]} -gt 0 ]] \
			|| return 1
		[[ "$(gpt_partition_count "${gpt_table[$id]}")" -eq "${gpt_parts[$id]}" ]] \
			|| return 1
	done

	for id in "${!DISK_DETECTED_UUIDS[@]}"; do
		DISK_DETECTED_UUIDS[$id]="${DISK_DETECTED_UUIDS[$id],,}"
		[[ ${DISK_DETECTED_UUIDS[$id]} =~ $INSTALLER_UUID_REGEX ]] \
			|| return 1
	done

	return 0
}

# Replaces the generated uuids with the ones found on disk so every later step resolves the reused partitions
function adopt_detected_partition_uuids() {
	local id
	local uuid
	local resolvable_type
	for id in "${!DISK_DETECTED_UUIDS[@]}"; do
		uuid="${DISK_DETECTED_UUIDS[$id]}"
		resolvable_type="${DISK_ID_TO_RESOLVABLE[$id]%%:*}"
		DISK_ID_TO_UUID[$id]="$uuid"
		create_resolve_entry "$id" "$resolvable_type" "$uuid"
		persist_installer_uuid "$id" "$uuid"
	done
}

# Reused partitions must be claimable, otherwise every mkfs and cryptsetup on them fails with EBUSY
function detected_partitions_are_free() {
	local id
	local device
	for id in "${!DISK_DETECTED_UUIDS[@]}"; do
		[[ ${DISK_ID_TO_RESOLVABLE[$id]} == partuuid:* ]] \
			|| continue

		device="/dev/disk/by-partuuid/${DISK_DETECTED_UUIDS[$id]}"
		[[ -e $device ]] \
			|| return 1
		release_device_claims "$device"
		if ! device_is_free "$device"; then
			eerror "Partition '$(realpath -e -- "$device" 2>/dev/null || echo "$device")' ($id) is still in use:"
			report_device_holders "$device"
			return 1
		fi
	done

	return 0
}

# Offers to keep an existing partition table which already matches the configuration
function maybe_reuse_existing_partitions() {
	[[ ${DETECT_EXISTING_PARTITIONS:-true} == "true" ]] \
		|| return 0

	einfo "Checking whether the disks are already partitioned as configured"
	if ! detect_existing_partition_layout; then
		elog "The existing partitions do not match the configuration, the disks will be partitioned from scratch."
		return 0
	fi

	if ! detected_partitions_are_free; then
		ewarn "The existing partitions match, but they cannot be claimed exclusively."
		ewarn "They will be repartitioned instead, which also releases whatever holds them."
		return 0
	fi

	elog "The existing partitions already match the configured layout."
	elog "Reusing them skips repartitioning, which otherwise often needs a reboot after a failed run."
	ask "Do you want to reuse the existing partitions?" \
		|| return 0

	adopt_detected_partition_uuids
	REUSE_EXISTING_PARTITIONS=true

	if [[ $USED_LUKS == "true" || $USED_RAID == "true" || $USED_ZFS == "true" ]]; then
		ewarn "Keeping existing filesystems is not supported for luks, raid or zfs layouts. They will be recreated."
		return 0
	fi

	ask "Do you want to reformat the filesystems on the reused partitions?" \
		&& return 0
	KEEP_EXISTING_FILESYSTEMS=true
}

# True when an action must not run because existing partitions or filesystems are reused
function disk_action_is_skipped() {
	case "$1" in
		'create_gpt'|'create_partition')       [[ $REUSE_EXISTING_PARTITIONS == "true" ]] ;;
		'format'|'format_zfs'|'format_btrfs')  [[ $KEEP_EXISTING_FILESYSTEMS == "true" ]] ;;
		*) return 1 ;;
	esac
}

function apply_disk_action() {
	unset known_arguments
	unset arguments; declare -A arguments; parse_arguments "$@"
	if [[ ${disk_action_summarize_only-false} != "true" ]] && disk_action_is_skipped "${arguments[action]}"; then
		einfo "Skipping ${arguments[action]}, the existing disk state is reused"
		return 0
	fi
	case "${arguments[action]}" in
		'existing')          disk_existing         ;;
		'create_gpt')        disk_create_gpt       ;;
		'create_partition')  disk_create_partition ;;
		'create_raid')       disk_create_raid      ;;
		'create_luks')       disk_create_luks      ;;
		'create_dummy')      disk_create_dummy     ;;
		'format')            disk_format           ;;
		'format_zfs')        disk_format_zfs       ;;
		'format_btrfs')      disk_format_btrfs     ;;
		*) echo "Ignoring invalid action: ${arguments[action]}" ;;
	esac
}

function print_summary_tree_entry() {
	local indent_chars=""
	local indent="0"
	local d="1"
	local maxd="$((depth - 1))"
	while [[ $d -lt $maxd ]]; do
		if [[ ${summary_depth_continues[$d]} == "true" ]]; then
			indent_chars+='│ '
		else
			indent_chars+='  '
		fi
		indent=$((indent + 2))
		d="$((d + 1))"
	done
	if [[ $maxd -gt 0 ]]; then
		if [[ ${summary_depth_continues[$maxd]} == "true" ]]; then
			indent_chars+='├─'
		else
			indent_chars+='└─'
		fi
		indent=$((indent + 2))
	fi

	local name="${summary_name[$root]}"
	local hint="${summary_hint[$root]}"
	local desc="${summary_desc[$root]}"
	local ptr="${summary_ptr[$root]}"
	local id_name="[2m[m"
	if [[ $root != __* ]]; then
		if [[ $root == _* ]]; then
			id_name="[2m${root:1}[m"
		else
			id_name="[2m${root}[m"
		fi
	fi

	local align=0
	if [[ $indent -lt 33 ]]; then
		align="$((33 - indent))"
	fi

	elog "$indent_chars$(printf "%-${align}s %-47s %s" \
		"$name [2m$hint[m" \
		"$id_name $ptr" \
		"$desc")"
}

function print_summary_tree() {
	local root="$1"
	local depth="$((depth + 1))"
	local has_children=false

	if [[ -v "summary_tree[$root]" ]]; then
		local children="${summary_tree[$root]}"
		has_children=true
		summary_depth_continues[$depth]=true
	else
		summary_depth_continues[$depth]=false
	fi

	if [[ $root != __root__ ]]; then
		print_summary_tree_entry "$root"
	fi

	if [[ $has_children == "true" ]]; then
		local count
		count="$(tr ';' '\n' <<< "$children" | grep -c '\S')" \
			|| count=0
		local idx=0
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${children//';'/ }; do
			idx="$((idx + 1))"
			[[ $idx == "$count" ]] \
				&& summary_depth_continues[$depth]=false
			print_summary_tree "$id"
			# separate blocks by newline
			[[ ${summary_depth_continues[0]} == "true" ]] && [[ $depth == 1 ]] && [[ $idx == "$count" ]] \
				&& elog
		done
	fi
}

function apply_disk_actions() {
	local param
	local current_params=()
	for param in "${DISK_ACTIONS[@]}"; do
		if [[ $param == ';' ]]; then
			apply_disk_action "${current_params[@]}"
			current_params=()
		else
			current_params+=("$param")
		fi
	done
}

function summarize_disk_actions() {
	elog "[1mCurrent lsblk output:[m"
	for_line_in <(lsblk \
		|| die "Error in lsblk") elog

	local disk_action_summarize_only=true
	declare -A summary_tree
	declare -A summary_name
	declare -A summary_hint
	declare -A summary_ptr
	declare -A summary_desc
	declare -A summary_depth_continues
	apply_disk_actions

	local depth=-1
	elog
	elog "[1mConfigured disk layout:[m"
	elog ────────────────────────────────────────────────────────────────────────────────
	elog "$(printf '%-26s %-28s %s' NODE ID OPTIONS)"
	elog ────────────────────────────────────────────────────────────────────────────────
	print_summary_tree __root__
	elog ────────────────────────────────────────────────────────────────────────────────
}

function apply_disk_configuration() {
	summarize_disk_actions
	capture_installer_resource_baselines
	local -a confirmed_destructive_devices=()

	if [[ $NO_PARTITIONING_OR_FORMATTING == true ]]; then
		elog "You have chosen an existing disk configuration. No devices will"
		elog "actually be re-partitioned or formatted. Please make sure that all"
		elog "devices are already formatted."
		ask "Do you want to use this existing disk configuration?" \
			|| die "Aborted"
	else
		[[ ${#DESTRUCTIVE_DEVICES[@]} -gt 0 ]] \
			|| die "No physical devices were registered for destructive disk actions"
		# Re-check immediately before confirmation. A device may have become busy
		# after the configuration was initially parsed.
		validate_destructive_whole_block_devices 1 "configured disk layout" "${DESTRUCTIVE_DEVICES[@]}"
		maybe_reuse_existing_partitions

		local destructive_device
		if [[ $KEEP_EXISTING_FILESYSTEMS == "true" ]]; then
			elog "The existing partitions and filesystems on these devices will be kept:"
			for destructive_device in "${DESTRUCTIVE_DEVICES[@]}"; do
				elog "  $destructive_device"
			done
			ask "Continue without partitioning or formatting anything?" \
				|| die "Destructive disk operation cancelled"
		else
			if [[ $REUSE_EXISTING_PARTITIONS == "true" ]]; then
				ewarn "The existing partitions will be kept, but everything stored in them will be erased:"
			else
				ewarn "The following whole devices will be irreversibly erased:"
			fi
			for destructive_device in "${DESTRUCTIVE_DEVICES[@]}"; do
				ewarn "  $destructive_device"
			done
			# I hate it when scripts try and and babysit me
			ask "This destroys all data on the listed devices. Continue?" \
				|| die "Destructive disk operation cancelled"
		fi
		confirmed_destructive_devices=("${DESTRUCTIVE_DEVICES[@]}")
	fi
	countdown "Applying in " 5

	maybe_exec 'before_disk_configuration' \
		|| die "Hook before_disk_configuration failed"
	if [[ $NO_PARTITIONING_OR_FORMATTING != true ]]; then
		[[ ${#DESTRUCTIVE_DEVICES[@]} -eq ${#confirmed_destructive_devices[@]} ]] \
			|| die "Destructive-device set changed after confirmation"
		local confirmed_index
		for confirmed_index in "${!confirmed_destructive_devices[@]}"; do
			[[ ${DESTRUCTIVE_DEVICES[$confirmed_index]} == "${confirmed_destructive_devices[$confirmed_index]}" ]] \
				|| die "Destructive-device set changed after confirmation"
		done
		# Close the automount/hotplug window after the prompt, countdown, and
		# user-defined hook. No destructive command runs after a failed recheck.
		validate_destructive_whole_block_devices \
			1 \
			"confirmed disk layout" \
			"${confirmed_destructive_devices[@]}"
	fi

	einfo "Applying disk configuration"
	apply_disk_actions

	einfo "Disk configuration was applied successfully"
	elog "[1mNew lsblk output:[m"
	for_line_in <(lsblk \
		|| die "Error in lsblk") elog

	maybe_exec 'after_disk_configuration' \
		|| die "Hook after_disk_configuration failed"
}

function mount_efivars() {
	# Skip if already mounted
	mountpoint -q -- "/sys/firmware/efi/efivars" \
		&& return

	# Mount efivars
	einfo "Mounting efivars"
	mount -t efivarfs efivarfs "/sys/firmware/efi/efivars" \
		|| die "Could not mount efivarfs"
	record_installer_created_mount "/sys/firmware/efi/efivars"
}

function mount_by_id() {
	local dev
	local id="$1"
	local mountpoint="$2"

	# Skip if already mounted
	mountpoint -q -- "$mountpoint" \
		&& return

	# Mount device
	einfo "Mounting device with id=$id to '$mountpoint'"
	mkdir -p "$mountpoint" \
		|| die "Could not create mountpoint directory '$mountpoint'"
	dev="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"
	mount "$dev" "$mountpoint" \
		|| die "Could not mount device '$dev'"
	record_installer_created_mount "$mountpoint"
}

function mount_root() {
	if [[ $USED_ZFS == "true" ]] && ! mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		die "Error: Expected zfs to be mounted under '$ROOT_MOUNTPOINT', but it isn't."
	else
		mount_by_id "$DISK_ID_ROOT" "$ROOT_MOUNTPOINT"
	fi
}

function bind_repo_dir() {
	local chroot_dir="$1"
	local host_bind_target="$chroot_dir$GENTOO_INSTALL_REPO_BIND"

	# Commands inside the chroot use this logical location. Mount it directly
	# below the target instead of relying on the target's /tmp being an rbind of
	# the host /tmp; a separately mounted target /tmp is valid and common.
	export GENTOO_INSTALL_REPO_DIR="$GENTOO_INSTALL_REPO_BIND"

	[[ ! -L $host_bind_target ]] \
		|| die "Refusing symlink repository bind target '$host_bind_target'"
	mountpoint -q -- "$host_bind_target" \
		&& die "Repository bind target is unexpectedly already mounted: '$host_bind_target'"

	einfo "Bind mounting repo directory"
	install -d -m 0700 -o root -g root -- "$host_bind_target" \
		|| die "Could not create mountpoint directory '$host_bind_target'"
	mount --bind "$GENTOO_INSTALL_REPO_DIR_ORIGINAL" "$host_bind_target" \
		|| die "Could not bind mount '$GENTOO_INSTALL_REPO_DIR_ORIGINAL' to '$host_bind_target'"
	record_installer_created_mount "$host_bind_target"
}

function prepare_chroot_installer_tmp_dir() {
	local chroot_dir="$1"
	local target_tmp="$chroot_dir$TMP_DIR"
	local owner mode

	[[ ! -L $chroot_dir/tmp ]] \
		|| die "Refusing symlink /tmp inside chroot: '$chroot_dir/tmp'"
	[[ ! -L $target_tmp ]] \
		|| die "Refusing symlink installer directory inside chroot: '$target_tmp'"
	install -d -m 0700 -o root -g root -- "$target_tmp" \
		|| die "Could not create secure installer directory inside chroot: '$target_tmp'"
	read -r owner mode < <(stat -Lc '%u %a' -- "$target_tmp") \
		|| die "Could not inspect installer directory inside chroot: '$target_tmp'"
	[[ $owner == 0 && $mode == 700 ]] \
		|| die "Installer directory inside chroot must be root-owned mode 0700: '$target_tmp'"
}

function bind_installer_uuid_storage() {
	local chroot_dir="$1"
	local host_target="$chroot_dir$UUID_STORAGE_DIR"

	[[ ! -L $UUID_STORAGE_DIR ]] \
		|| die "Refusing symlink UUID storage '$UUID_STORAGE_DIR'"
	install -d -m 0700 -o root -g root -- "$UUID_STORAGE_DIR" \
		|| die "Could not prepare UUID storage '$UUID_STORAGE_DIR'"
	[[ ! -L $host_target ]] \
		|| die "Refusing symlink UUID storage inside chroot: '$host_target'"
	install -d -m 0700 -o root -g root -- "$host_target" \
		|| die "Could not prepare UUID storage inside chroot: '$host_target'"
	mountpoint -q -- "$host_target" \
		&& die "UUID storage inside chroot is already a mountpoint: '$host_target'"
	mount --bind "$UUID_STORAGE_DIR" "$host_target" \
		|| die "Could not share installer UUID storage with chroot"
	record_installer_created_mount "$host_target"
}

function gentoo_release_key_uid_for_fingerprint() {
	case "$1" in
		13EBBDBEDE7A12775DFDB1BABB572E0E2D182910)
			echo 'Gentoo Linux Release Engineering (Automated Weekly Release Key) <releng@gentoo.org>'
			;;
		D99EAC7379A850BCE47DA5F29E6438C817072058)
			echo 'Gentoo Linux Release Engineering (Gentoo Linux Release Signing Key) <releng@gentoo.org>'
			;;
		*)
			return 1
			;;
	esac
}

function extract_verified_openpgp_payload() {
	local gpg_home="$1"
	local signed_file="$2"
	local output_file="$3"

	[[ ! -e $output_file && ! -L $output_file ]] \
		|| { eerror "Refusing existing OpenPGP payload output '$output_file'"; return 1; }
	gpg --homedir "$gpg_home" \
		--batch \
		--status-fd=1 \
		--output "$output_file" \
		--decrypt "$signed_file" 2>/dev/null
}

function verify_gentoo_release_signature() (
	local signed_file="$1"
	local gpg_home
	gpg_home="$(mktemp -d "${TMP_DIR%/}/gentoo-releng-gpg.XXXXXXXX")" \
		|| { eerror "Could not create an isolated GnuPG directory"; return 1; }
	trap 'rm -rf -- "$gpg_home"' EXIT
	chmod 0700 "$gpg_home" \
		|| { eerror "Could not secure the isolated GnuPG directory"; return 1; }
	export GNUPGHOME="$gpg_home"

	local key_file="$gpg_home/releng.gpg"
	download 'https://gentoo.org/.well-known/openpgpkey/hu/wtktzo4gyuhzu8a4z5fdj3fgmr1u6tob?l=releng' "$key_file" \
		|| { eerror "Could not retrieve the Gentoo release engineering key"; return 1; }
	gpg --homedir "$gpg_home" --batch --quiet --import-options import-minimal --import "$key_file" \
		|| { eerror "Could not import the Gentoo release engineering key"; return 1; }

	# Pin both release-media keys published by Gentoo.  Do not trust a key merely
	# because it was returned by the WKD endpoint.
	local -a trusted_fingerprints=(
		13EBBDBEDE7A12775DFDB1BABB572E0E2D182910
		D99EAC7379A850BCE47DA5F29E6438C817072058
	)
	local fingerprint expected_uid key_details imported_fingerprint
	local trusted_key_found=false
	for fingerprint in "${trusted_fingerprints[@]}"; do
		expected_uid="$(gentoo_release_key_uid_for_fingerprint "$fingerprint")" \
			|| { eerror "Missing identity for trusted Gentoo key '$fingerprint'"; return 1; }
		key_details="$(gpg --homedir "$gpg_home" --batch --with-colons --fingerprint --list-keys "$fingerprint" 2>/dev/null)" \
			|| continue
		imported_fingerprint="$(awk -F: '$1 == "fpr" { print $10; exit }' <<< "$key_details")"
		[[ $imported_fingerprint == "$fingerprint" ]] \
			|| { eerror "Gentoo release key fingerprint mismatch"; return 1; }
		awk -F: -v expected_uid="$expected_uid" \
			'$1 == "uid" && $2 != "r" && $2 != "d" && $10 == expected_uid { found = 1 } END { exit !found }' <<< "$key_details" \
			|| { eerror "Gentoo release key identity mismatch for '$fingerprint'"; return 1; }
		trusted_key_found=true
	done
	[[ $trusted_key_found == true ]] \
		|| { eerror "No trusted Gentoo release key was imported"; return 1; }

	# Verify and extract the signed cleartext in one GnuPG operation. Callers must
	# hash only this payload; bytes appended after the clearsigned message are not
	# authenticated even when GnuPG reports a valid signature for the message.
	local verified_payload="$gpg_home/verified-digests"
	local signature_status
	signature_status="$(extract_verified_openpgp_payload "$gpg_home" "$signed_file" "$verified_payload")" \
		|| { eerror "OpenPGP signature verification failed for '$signed_file'"; return 1; }
	[[ -s $verified_payload ]] \
		|| { eerror "Verified OpenPGP payload for '$signed_file' is empty"; return 1; }
	if grep -Eq '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|KEYEXPIRED|REVKEYSIG|KEYREVOKED|NO_PUBKEY|SIGEXPIRED)( |$)' <<< "$signature_status"; then
		eerror "OpenPGP reported an invalid, expired, or revoked signature for '$signed_file'"
		return 1
	fi

	local -a valid_signatures=()
	mapfile -t valid_signatures < <(
		awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {
			primary = (NF >= 12 ? $12 : $3)
			print $3, primary
		}' <<< "$signature_status"
	)
	[[ ${#valid_signatures[@]} -eq 1 ]] \
		|| { eerror "Expected exactly one valid OpenPGP signature for '$signed_file'"; return 1; }

	local signing_fingerprint primary_fingerprint
	read -r signing_fingerprint primary_fingerprint <<< "${valid_signatures[0]}"
	expected_uid="$(gentoo_release_key_uid_for_fingerprint "$primary_fingerprint")" \
		|| { eerror "Signature was made by untrusted key '$primary_fingerprint'"; return 1; }
	[[ $signing_fingerprint =~ ^[0-9A-F]{40}$ ]] \
		|| { eerror "GnuPG returned an invalid signing-key fingerprint"; return 1; }

	# Re-check the UID on the exact primary key which made the signature.
	key_details="$(gpg --homedir "$gpg_home" --batch --with-colons --fingerprint --list-keys "$primary_fingerprint" 2>/dev/null)" \
		|| { eerror "Could not inspect the Gentoo signing key"; return 1; }
	awk -F: -v expected_uid="$expected_uid" \
		'$1 == "uid" && $2 != "r" && $2 != "d" && $10 == expected_uid { found = 1 } END { exit !found }' <<< "$key_details" \
		|| { eerror "Gentoo signing-key identity does not match its pinned identity"; return 1; }

	cat -- "$verified_payload" \
		|| { eerror "Could not return verified OpenPGP payload"; return 1; }
)

function verify_stage3_sha512() {
	local archive="$1"
	local digests_file="$2"
	local -a expected_hashes=()

	# A DIGESTS file contains multiple algorithms and may contain checksums for
	# related files.  Select only the SHA512 entry whose filename is exactly the
	# stage3 archive requested by the installer.
	mapfile -t expected_hashes < <(
		awk -v archive="$archive" '
			$0 == "# SHA512 HASH" { in_sha512 = 1; next }
			/^# / { in_sha512 = 0; next }
			in_sha512 && NF == 2 && $2 == archive { print $1 }
		' "$digests_file"
	)
	[[ ${#expected_hashes[@]} -eq 1 ]] \
		|| { eerror "Expected exactly one SHA512 checksum for '$archive'"; return 1; }
	[[ ${expected_hashes[0]} =~ ^[[:xdigit:]]{128}$ ]] \
		|| { eerror "Invalid SHA512 checksum for '$archive'"; return 1; }

	local checksum_output actual_hash expected_hash
	checksum_output="$(sha512sum -- "$archive")" \
		|| { eerror "Could not calculate SHA512 checksum for '$archive'"; return 1; }
	actual_hash="${checksum_output%% *}"
	expected_hash="${expected_hashes[0],,}"
	[[ $actual_hash == "$expected_hash" ]] \
		|| { eerror "SHA512 checksum mismatch for '$archive'"; return 1; }
}

function validate_stage3_freshness() {
	local archive="$1"
	local max_age_days="${MAX_STAGE3_AGE_DAYS:-45}"
	[[ $max_age_days =~ ^[0-9]+$ ]] \
		|| { eerror "MAX_STAGE3_AGE_DAYS must be a non-negative integer"; return 1; }
	[[ $max_age_days -gt 0 ]] || return 0

	[[ $archive =~ -([0-9]{8})T([0-9]{6})Z\.tar\.xz$ ]] \
		|| { eerror "Could not parse stage3 build timestamp from '$archive'"; return 1; }
	local build_date="${BASH_REMATCH[1]}"
	local build_time="${BASH_REMATCH[2]}"
	local build_epoch now_epoch
	build_epoch="$(date -u -d \
		"${build_date:0:4}-${build_date:4:2}-${build_date:6:2} ${build_time:0:2}:${build_time:2:2}:${build_time:4:2} UTC" \
		+%s 2>/dev/null)" \
		|| { eerror "Invalid stage3 build timestamp in '$archive'"; return 1; }
	now_epoch="$(date -u +%s)" \
		|| { eerror "Could not read current time for stage3 freshness check"; return 1; }

	# Permit modest clock/release skew, but reject implausible future builds.
	[[ $build_epoch -le $((now_epoch + 86400)) ]] \
		|| { eerror "Stage3 '$archive' is dated too far in the future"; return 1; }
	local age_seconds=$((now_epoch - build_epoch))
	[[ $age_seconds -le $((max_age_days * 86400)) ]] \
		|| { eerror "Stage3 '$archive' is older than the allowed $max_age_days days"; return 1; }
}

function download_stage3() {
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"

	local STAGE3_BASENAME_FINAL
	if [[ ("$GENTOO_ARCH" == "amd64" && "$STAGE3_VARIANT" == *x32*) || ("$GENTOO_ARCH" == "x86" && -n "$GENTOO_SUBARCH") ]]; then
		STAGE3_BASENAME_FINAL="${STAGE3_BASENAME_CUSTOM:-}"
		[[ -n $STAGE3_BASENAME_FINAL ]] \
			|| die "This arch and variant combination requires STAGE3_BASENAME_CUSTOM to be set in your configuration"
	else
		STAGE3_BASENAME_FINAL="$STAGE3_BASENAME"
	fi

	local STAGE3_RELEASES="$GENTOO_MIRROR/releases/$GENTOO_ARCH/autobuilds/current-$STAGE3_BASENAME_FINAL/"

	# Download upstream list of files
	CURRENT_STAGE3="$(download_stdout "$STAGE3_RELEASES")" \
		|| die "Could not retrieve list of tarballs"
	# Decode urlencoded strings
	CURRENT_STAGE3="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))' <<< "$CURRENT_STAGE3")" \
		|| die "Could not decode the stage3 listing"
	# Parse output for correct filename
	CURRENT_STAGE3="$(grep -o "\"${STAGE3_BASENAME_FINAL}-[0-9A-Z]*.tar.xz\"" <<< "$CURRENT_STAGE3" \
		| sort -u | tail -1)" \
		|| die "Could not parse list of tarballs"
	# Strip quotes
	CURRENT_STAGE3="${CURRENT_STAGE3:1:-1}"
	[[ -n $CURRENT_STAGE3 ]] \
		|| die "No stage3 tarball matching '$STAGE3_BASENAME_FINAL' was listed"
	validate_stage3_freshness "$CURRENT_STAGE3" \
		|| die "Refusing stale or invalid stage3 build '$CURRENT_STAGE3'"
	# File to indiciate successful verification
	CURRENT_STAGE3_VERIFIED="${CURRENT_STAGE3}.verified"
	[[ ! -L $CURRENT_STAGE3 \
		&& ! -L ${CURRENT_STAGE3}.DIGESTS \
		&& ! -L $CURRENT_STAGE3_VERIFIED ]] \
		|| die "Refusing symlink in cached stage3 state"

	maybe_exec 'before_download_stage3' "$STAGE3_BASENAME_FINAL" \
		|| die "Hook before_download_stage3 failed"

	# A marker permits use of the cached downloads, but never skips signature or
	# checksum verification.  A forged or stale marker therefore cannot bless a
	# modified archive.
	if [[ -e $CURRENT_STAGE3_VERIFIED && -s $CURRENT_STAGE3 && -s "${CURRENT_STAGE3}.DIGESTS" ]]; then
		einfo "$STAGE3_BASENAME_FINAL tarball already downloaded; re-verifying it"
	else
		einfo "Downloading $STAGE3_BASENAME_FINAL tarball"
		rm -f -- "$CURRENT_STAGE3_VERIFIED" \
			|| die "Could not remove stale verification marker"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}" "${CURRENT_STAGE3}" \
			|| die "Could not download stage3 archive '$CURRENT_STAGE3'"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}.DIGESTS" "${CURRENT_STAGE3}.DIGESTS" \
			|| die "Could not download stage3 DIGESTS"
	fi
	# Run the post-download hook before verification so any accidental archive or
	# DIGESTS modification is detected rather than blessed by the cache marker.
	maybe_exec 'after_download_stage3' "${CURRENT_STAGE3}" \
		|| die "Hook after_download_stage3 failed"

	# Remove the marker before validation so an interrupted or failed validation
	# cannot leave a success marker behind.
	rm -f -- "$CURRENT_STAGE3_VERIFIED" \
		|| die "Could not clear the verification marker"

	einfo "Verifying Gentoo release signature"
	local verified_digests
	verified_digests="$(mktemp "${TMP_DIR%/}/verified-digests.XXXXXXXX")" \
		|| die "Could not create temporary file for verified stage3 digests"
	rm -f -- "$verified_digests" \
		|| die "Could not prepare temporary file for verified stage3 digests"
	if ! verify_gentoo_release_signature "${CURRENT_STAGE3}.DIGESTS" > "$verified_digests"; then
		rm -f -- "$verified_digests"
		die "Signature of '${CURRENT_STAGE3}.DIGESTS' is not from a trusted Gentoo release key"
	fi
	chmod 0600 -- "$verified_digests" \
		|| { rm -f -- "$verified_digests"; die "Could not protect verified stage3 digests"; }

	einfo "Verifying stage3 SHA512 checksum"
	if ! verify_stage3_sha512 "$CURRENT_STAGE3" "$verified_digests"; then
		rm -f -- "$verified_digests"
		die "Checksum mismatch for '$CURRENT_STAGE3'"
	fi
	rm -f -- "$verified_digests" \
		|| die "Could not remove temporary verified stage3 digests"

	# Record success for restart/download caching only.  Future runs still verify.
	touch_or_die 0644 "$CURRENT_STAGE3_VERIFIED"

}

function extract_stage3() {
	mount_root

	[[ -n $CURRENT_STAGE3 ]] \
		|| die "CURRENT_STAGE3 is not set"
	[[ -e "$TMP_DIR/$CURRENT_STAGE3" ]] \
		|| die "stage3 file does not exist"

	maybe_exec 'before_extract_stage3' "$TMP_DIR/$CURRENT_STAGE3" "$ROOT_MOUNTPOINT" \
		|| die "Hook before_extract_stage3 failed"

	# Go to root directory
	cd "$ROOT_MOUNTPOINT" \
		|| die "Could not move to '$ROOT_MOUNTPOINT'"
	# Ensure the directory is empty
	find . -mindepth 1 -maxdepth 1 -not -name 'lost+found' \
		| grep -q . \
		&& die "root directory '$ROOT_MOUNTPOINT' is not empty"

	# Extract tarball
	einfo "Extracting stage3 tarball"
	tar xpf "$TMP_DIR/$CURRENT_STAGE3" --xattrs --numeric-owner \
		|| die "Error while extracting tarball"
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"

	maybe_exec 'after_extract_stage3' "$TMP_DIR/$CURRENT_STAGE3" "$ROOT_MOUNTPOINT" \
		|| die "Hook after_extract_stage3 failed"
}

function persist_luks_header_backups() {
	[[ $USED_LUKS == true ]] || return 0

	local headers=("${INSTALLER_CREATED_LUKS_HEADERS[@]}")
	[[ ${#headers[@]} -gt 0 ]] \
		|| die "LUKS was used, but no generated header backups were found"

	local target_dir="$ROOT_MOUNTPOINT$LUKS_HEADER_TARGET_DIR"
	[[ ! -L $target_dir ]] \
		|| die "Refusing symlink target LUKS header directory '$target_dir'"
	install -d -m 0700 -o root -g root -- "$target_dir" \
		|| die "Could not create target LUKS header directory '$target_dir'"

	local header destination owner mode
	for header in "${headers[@]}"; do
		destination="$target_dir/$(basename "$header")"
		[[ ! -L $destination ]] \
			|| die "Refusing symlink target LUKS header file '$destination'"
		install -m 0400 -o root -g root -- "$header" "$destination" \
			|| die "Could not persist LUKS header backup '$destination'"
		read -r owner mode < <(stat -Lc '%u %a' -- "$destination") \
			|| die "Could not verify persisted LUKS header '$destination'"
		[[ $owner == 0 && $mode == 400 ]] \
			|| die "Persisted LUKS header '$destination' is not root-owned mode 0400"
	done

	ewarn "LUKS headers were copied to '$LUKS_HEADER_TARGET_DIR' in the target system. This is not an independent recovery copy because it is stored behind the encrypted container."

	# Revalidate immediately before copying in case removable storage was
	# detached or the path was replaced after the pre-disk check.
	validate_luks_header_export_destination
	[[ ${LUKS_HEADER_EXPORT_READY:-false} == true ]] || return 0
	local export_complete=true
	for header in "${headers[@]}"; do
		destination="$LUKS_HEADER_EXPORT_DIR/$(basename "$header")"
		if [[ -L $destination ]] \
			|| ! install -m 0400 -- "$header" "$destination"; then
			if [[ $REQUIRE_LUKS_HEADER_EXPORT == true ]]; then
				die "Required external LUKS header export failed for '$destination'"
			fi
			ewarn "Could not export optional LUKS header backup to '$destination'"
			export_complete=false
			continue
		fi
	done
	[[ $export_complete == false ]] \
		|| einfo "Exported LUKS header backups to host directory '$LUKS_HEADER_EXPORT_DIR'"
}

function gentoo_umount() {
	if mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		einfo "Unmounting root filesystem"
		# Do not use lazy unmount before destructive validation: a detached but
		# still-busy mount could disappear from lsblk and then be formatted.
		umount -R -- "$ROOT_MOUNTPOINT" \
			|| die "Could not unmount filesystems"
	fi
}

function init_bash() {
	source_profile
	umask 0077
	export PS1='(chroot) \[[0;31m\]\u\[[1;31m\]@\h \[[1;34m\]\w \[[m\]\$ \[[m\]'
}; export -f init_bash

function env_update() {
	env-update \
		|| die "Error in env-update"
	source_profile \
		|| die "Could not source /etc/profile"
	umask 0077
}

function mkdir_or_die() {
	install -d -m "$1" -- "$2" \
		|| die "Could not create directory '$2'"
}

function touch_or_die() {
	touch "$2" \
		|| die "Could not touch '$2'"
	chmod "$1" "$2" \
		|| die "Could not set permissions on '$2'"
}

# $1: root directory
# $@: command...
function gentoo_chroot() {
	if [[ $# -eq 1 ]]; then
		gentoo_chroot "$1" /bin/bash --init-file <(echo 'init_bash')
		return $?
	fi

	[[ ${RUNNING_IN_INSTALLER_CHROOT:-false} != true ]] \
		|| die "Already in chroot"

	local chroot_dir="$1"
	shift
	local created_mount_start=${#INSTALLER_CREATED_MOUNTS[@]}

	# Copy resolv.conf
	einfo "Preparing chroot environment"
	install --mode=0644 /etc/resolv.conf "$chroot_dir/etc/resolv.conf" \
		|| die "Could not copy resolv.conf"

	# Mount virtual filesystems
	einfo "Mounting virtual filesystems"
	if ! mountpoint -q -- "$chroot_dir/proc"; then
		mount -t proc /proc "$chroot_dir/proc" \
			|| die "Could not mount proc in '$chroot_dir'"
		record_installer_created_mount "$chroot_dir/proc"
	fi
	local virtual_source virtual_target
	for virtual_source in /run /sys /dev; do
		virtual_target="$chroot_dir$virtual_source"
		mountpoint -q -- "$virtual_target" && continue
		mount --rbind "$virtual_source" "$virtual_target" \
			|| die "Could not bind mount '$virtual_source' in '$chroot_dir'"
		record_installer_created_mount "$virtual_target"
		mount --make-rslave "$virtual_target" \
			|| die "Could not make '$virtual_target' a slave mount"
	done

	# Mount this after preparing /tmp so an rbind of the parent cannot hide the
	# repository mount. This also works when the target already has its own /tmp.
	prepare_chroot_installer_tmp_dir "$chroot_dir"
	bind_installer_uuid_storage "$chroot_dir"
	bind_repo_dir "$chroot_dir"

	# Cache lsblk output, because it doesn't work correctly in chroot (returns almost no info for devices, e.g. empty uuids)
	cache_lsblk_output

	# Execute command
	einfo "Chrooting..."
	local chroot_status
	# TMP_DIR isch readonly ah demm punkt. Bash het kei bock uhf das drum lahts denn halt eifach garnix meh laufeh. So behindert mann.
	EXECUTED_IN_CHROOT=true \
		CACHED_LSBLK_OUTPUT="$CACHED_LSBLK_OUTPUT" \
		chroot -- "$chroot_dir" "$GENTOO_INSTALL_REPO_DIR/scripts/dispatch_chroot.sh" "$@"
	chroot_status=$?
	[[ $chroot_status -eq 0 ]] \
		|| eerror "Command in chroot '$chroot_dir' failed with status $chroot_status"
	# Only tear down mounts created for this chroot invocation. Root, boot, and
	# efivar mounts established by the installation remain available for repair.
	if ! cleanup_installer_mounts_from "$created_mount_start"; then
		[[ $chroot_status -ne 0 ]] \
			|| chroot_status=1
	fi
	return "$chroot_status"
}

function enable_service() {
	if [[ $SYSTEMD == "true" ]]; then
		try_fatal systemctl enable "$1"
	else
		try_fatal rc-update add "$1" default
	fi
}
