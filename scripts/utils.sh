# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1

function elog() {
	echo "[[1m+[m] $*"
}

function einfo() {
	echo "[[1m+[m] [1;33m$*[m"
}

function ewarn() {
	echo "[[1;31m![m] [1;33m$*[m" >&2
}

function eerror() {
	echo "[1;31merror:[m $*" >&2
}

function die() {
	eerror "$*"
	[[ -v GENTOO_INSTALL_REPO_SCRIPT_PID && $$ -ne $GENTOO_INSTALL_REPO_SCRIPT_PID ]] \
		&& kill "$GENTOO_INSTALL_REPO_SCRIPT_PID"
	exit 1
}

# Prints an error with file:line info of the nth "stack frame".
# 0 is this function, 1 the calling function, 2 its parent, and so on.
function die_trace() {
	local idx="${1:-0}"
	shift
	echo "[1m${BASH_SOURCE[$((idx + 1))]}:${BASH_LINENO[$idx]}: [1;31merror:[m ${FUNCNAME[$idx]}: $*" >&2
	exit 1
}

# Mirrors everything this process and its children print into TMP_DIR/install.log
function start_install_log() {
	# The installer inside the chroot writes through the outer process, which already logs
	[[ ${RUNNING_IN_INSTALLER_CHROOT:-false} != true ]] \
		|| return 0
	[[ -z ${INSTALL_LOG:-} ]] \
		|| return 0

	local log="$TMP_DIR/install.log"
	[[ ! -L $log ]] \
		|| die "Refusing symlinked install log '$log'"
	touch -- "$log" \
		|| die "Could not create install log '$log'"
	chmod 0600 -- "$log" \
		|| die "Could not protect install log '$log'"

	INSTALL_LOG="$log"
	export INSTALL_LOG
	printf '\n===== %s: starting %s =====\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$log" \
		|| die "Could not write to install log '$log'"
	exec > >(tee -a -- "$log") 2>&1
	einfo "Logging this installation to $log"
}

# Runs an interactive shell on the terminal, because the logged stdio is a pipe
function run_recovery_shell() {
	if [[ -n ${INSTALL_LOG:-} && -c /dev/tty ]]; then
		/bin/bash --init-file <(echo "init_bash") >/dev/tty 2>/dev/tty
	else
		/bin/bash --init-file <(echo "init_bash")
	fi
}

function for_line_in() {
	while IFS="" read -r line || [[ -n $line ]]; do
		"$2" "$line"
	done <"$1"
}

function flush_stdin() {
	local empty_stdin
	# Unused variable is intentional.
	# shellcheck disable=SC2034
	while read -r -t 0.01 empty_stdin; do true; done
}

# Source /etc/profile mit `nounset` im chiller relaxed modus
function source_profile() {
	local restore_nounset=false
	if [[ -o nounset ]]; then
		restore_nounset=true
	fi

	local status
	set +u
	# shellcheck disable=SC1091
	source /etc/profile
	status=$?
	if [[ $restore_nounset == true ]]; then
		set -u
	fi

	return "$status"
}; export -f source_profile

function ask() {
	local response
	while true; do
		flush_stdin
		read -r -p "$* (Y/n) " response \
			|| die "Error in read"
		case "${response,,}" in
			'') return 0 ;;
			y|yes) return 0 ;;
			n|no) return 1 ;;
			*) continue ;;
		esac
	done
}

function try() {
	local response
	local cmd_status
	local prompt_parens="([1mS[mhell/[1mr[metry/[1ma[mbort/[1mc[montinue/[1mp[mrint)"

	# Outer loop, allows us to retry the command
	while true; do
		# Try command
		"$@"
		cmd_status="$?"

		if [[ $cmd_status != 0 ]]; then
			echo "[1;31m * Command failed: [1;33m\$[m $*"
			echo "Last command failed with exit code $cmd_status"

			# Prompt until input is valid
			while true; do
				echo -n "Specify next action $prompt_parens "
				flush_stdin
				read -r response \
					|| die "Error in read"
				case "${response,,}" in
					''|s|shell)
						echo "You will be prompted for action again after exiting this shell."
						run_recovery_shell
						;;
					r|retry) continue 2 ;;
					a|abort) die "Installation aborted" ;;
					c|continue) return 0 ;;
					p|print) echo "[1;33m\$[m $*" ;;
					*) ;;
				esac
			done
		fi

		return
	done
}

# Run a required command with interactive recovery, but never allow its failure
# to be treated as success. This is for operations required for a bootable or
# internally consistent installation.
function try_fatal() {
	local response
	local cmd_status
	local prompt_parens="([1mS[mhell/[1mr[metry/[1ma[mbort/[1mp[mrint)"

	while true; do
		if "$@"; then
			return 0
		else
			cmd_status="$?"
		fi

		eerror "Required command failed with exit code $cmd_status: $*"
		while true; do
			echo -n "Specify next action $prompt_parens "
			flush_stdin
			read -r response \
				|| die "Error in read"
			case "${response,,}" in
				''|s|shell)
					echo "You will be prompted again after exiting the recovery shell."
					run_recovery_shell
					;;
				r|retry) continue 2 ;;
				a|abort) die "Installation aborted after required command failure" ;;
				p|print) printf '[1;33m$[m'; printf ' %q' "$@"; printf '\n' ;;
				*) ;;
			esac
		done
	done
}

function countdown() {
	echo -n "$1" >&2

	local i="$2"
	while [[ $i -gt 0 ]]; do
		echo -n "[1;31m$i[m " >&2
		i=$((i - 1))
		sleep 1
	done
	echo >&2
}

function download_stdout() {
	wget --quiet --https-only --secure-protocol=PFS -O - -- "$1"
}

function download() {
	wget --quiet --https-only --secure-protocol=PFS --show-progress -O "$2" -- "$1"
}

function get_blkid_field_by_device() {
	local blkid_field="$1"
	local device="$2"
	blkid -g -c /dev/null \
		|| die "Error while executing blkid"
	partprobe &>/dev/null
	local val
	val="$(blkid -c /dev/null -o export "$device")" \
		|| die "Error while executing blkid '$device'"
	val="$(grep -- "^$blkid_field=" <<< "$val")" \
		|| die "Could not find $blkid_field=... in blkid output"
	val="${val#"$blkid_field="}"
	echo -n "$val"
}

function get_blkid_uuid_for_id() {
	local dev
	dev="$(resolve_device_by_id "$1")" \
		|| die "Could not resolve device with id=$1"
	local uuid
	uuid="$(get_blkid_field_by_device 'UUID' "$dev")" \
		|| die "Could not get UUID from blkid for device=$dev"
	echo -n "$uuid"
}

function get_device_by_blkid_field() {
	local blkid_field="$1"
	local field_value="$2"
	blkid -g -c /dev/null \
		|| die "Error while executing blkid"
	type partprobe &>/dev/null && partprobe &>/dev/null
	local dev
	dev="$(blkid -c /dev/null -o export -t "$blkid_field=$field_value")" \
		|| die "Error while executing blkid to find $blkid_field=$field_value"
	dev="$(grep DEVNAME <<< "$dev")" \
		|| die "Could not find DEVNAME=... in blkid output"
	dev="${dev#"DEVNAME="}"
	echo -n "$dev"
}

function get_device_by_partuuid() {
	if [[ -e "/dev/disk/by-partuuid/$1" ]]; then
		echo -n "/dev/disk/by-partuuid/$1"
	else
		get_device_by_blkid_field 'PARTUUID' "$1"
	fi
}

function get_device_by_uuid() {
	if [[ -e "/dev/disk/by-uuid/$1" ]]; then
		echo -n "/dev/disk/by-uuid/$1"
	else
		get_device_by_blkid_field 'UUID' "$1"
	fi
}

function cache_lsblk_output() {
	CACHED_LSBLK_OUTPUT="$(lsblk --all --path --pairs --output NAME,PTUUID,PARTUUID)" \
		|| die "Error while executing lsblk to cache output"
}

function get_device_by_ptuuid() {
	local ptuuid="${1,,}"
	local dev
	if [[ -v CACHED_LSBLK_OUTPUT && -n "$CACHED_LSBLK_OUTPUT" ]]; then
		dev="$CACHED_LSBLK_OUTPUT"
	else
		dev="$(lsblk --all --path --pairs --output NAME,PTUUID,PARTUUID)" \
			|| die "Error while executing lsblk to find PTUUID=$ptuuid"
	fi
	dev="$(grep "ptuuid=\"$ptuuid\" partuuid=\"\"" <<< "${dev,,}")" \
		|| die "Could not find PTUUID=... in lsblk output"
	dev="${dev%'" ptuuid='*}"
	dev="${dev#'name="'}"
	echo -n "$dev"
}

function uuid_to_mduuid() {
	local mduuid="${1,,}"
	mduuid="${mduuid//-/}"
	mduuid="${mduuid:0:8}:${mduuid:8:8}:${mduuid:16:8}:${mduuid:24:8}"
	echo -n "$mduuid"
}

function get_device_by_mdadm_uuid() {
	local mduuid
	mduuid="$(uuid_to_mduuid "$1")" \
		|| die "Could not resolve mduuid from uuid=$1"
	local dev
	dev="$(mdadm --examine --scan)" \
		|| die "Error while executing mdadm to find array with UUID=$mduuid"
	dev="$(grep "uuid=$mduuid" <<< "${dev,,}")" \
		|| die "Could not find UUID=... in mdadm output"
	dev="${dev%'metadata='*}"
	dev="${dev#'array'}"
	dev="${dev#"${dev%%[![:space:]]*}"}"
	dev="${dev%"${dev##*[![:space:]]}"}"
	echo -n "$dev"
}

function get_device_by_luks_name() {
	echo -n "/dev/mapper/$1"
}

function create_resolve_entry() {
	local id="$1"
	local type="$2"
	local arg="${3,,}"

	DISK_ID_TO_RESOLVABLE[$id]="$type:$arg"
}

function create_resolve_entry_device() {
	local id="$1"
	local dev="$2"

	DISK_ID_TO_RESOLVABLE[$id]="device:$dev"
}

# Returns the basename of the device, if its path starts with /dev/disk/by-id/
function shorten_device() {
	echo -n "${1#/dev/disk/by-id/}"
}

# Return matching device from /dev/disk/by-id/ if possible,
# otherwise return the parameter unchanged.
function canonicalize_device() {
	local given_dev
	local dev
	given_dev="$(realpath -e -- "$1" 2>/dev/null)" \
		|| { eerror "Could not canonicalize device '$1'"; return 1; }
	for dev in /dev/disk/by-id/*; do
		[[ -e $dev ]] || continue
		if [[ "$(realpath -e -- "$dev" 2>/dev/null)" == "$given_dev" ]]; then
			echo -n "$dev"
			return 0
		fi
	done

	echo -n "$1"
}

# Print the canonical kernel path for any existing block device.
function canonicalize_block_device() {
	local device="$1"
	local canonical

	canonical="$(realpath -e -- "$device" 2>/dev/null)" \
		|| { eerror "Block device '$device' does not exist"; return 1; }
	[[ -b "$canonical" ]] \
		|| { eerror "'$device' does not resolve to a block device"; return 1; }
	echo -n "$canonical"
}

# Print the canonical kernel path for a whole device suitable for destructive
# partitioning/formatting. Partitions and stacked block devices are rejected.
function canonicalize_whole_block_device() {
	local device="$1"
	local canonical
	local device_type

	canonical="$(canonicalize_block_device "$device")" || return 1

	device_type="$(lsblk --nodeps --noheadings --output TYPE -- "$canonical" 2>/dev/null)" \
		|| { eerror "Could not inspect block device '$device'"; return 1; }
	device_type="${device_type//[[:space:]]/}"
	case "$device_type" in
		disk|loop) ;;
		*)
			eerror "'$device' is not a whole disk device (lsblk type: ${device_type:-unknown})"
			return 1
			;;
	esac

	echo -n "$canonical"
}

# Return success when a device, or one of its descendants, is mounted, used as
# swap, held by a stacked block target (md/dm/LVM/LUKS), or part of an imported
# ZFS pool. The input must already be a canonical block-device path.
function block_device_is_in_use() {
	local device="$1"
	local lsblk_names
	local mountpoints
	local node
	local node_canonical
	local sys_name
	local swap_device
	local zpool_status
	local zpool_device
	local -a nodes=()
	local -A node_set=()

	lsblk_names="$(lsblk --noheadings --raw --paths --output NAME -- "$device" 2>/dev/null)" \
		|| return 0
	mapfile -t nodes <<< "$lsblk_names"
	for node in "${nodes[@]}"; do
		[[ -n "$node" ]] || continue
		node_canonical="$(realpath -e -- "$node" 2>/dev/null)" || node_canonical="$node"
		node_set[$node_canonical]=true
	done
	[[ "${#node_set[@]}" -gt 0 ]] || return 0

	mountpoints="$(lsblk --noheadings --raw --output MOUNTPOINTS -- "$device" 2>/dev/null)" \
		|| return 0
	[[ -z "${mountpoints//[[:space:]]/}" ]] || return 0

	while read -r swap_device _; do
		[[ -n "$swap_device" && "$swap_device" != "Filename" ]] || continue
		swap_device="$(realpath -e -- "$swap_device" 2>/dev/null)" || continue
		[[ -v "node_set[$swap_device]" ]] && return 0
	done < /proc/swaps

	for node in "${!node_set[@]}"; do
		sys_name="$(basename -- "$node")"
		if compgen -G "/sys/class/block/$sys_name/holders/*" >/dev/null; then
			return 0
		fi
	done

	if command -v zpool >/dev/null 2>&1; then
		zpool_status="$(zpool status -P 2>/dev/null)" || zpool_status=""
		while read -r zpool_device _; do
			[[ "$zpool_device" == /dev/* ]] || continue
			zpool_device="$(realpath -e -- "$zpool_device" 2>/dev/null)" || continue
			[[ -v "node_set[$zpool_device]" ]] && return 0
		done <<< "$zpool_status"
	fi

	return 1
}

# Validate destructive whole-device arguments before any disk action is queued.
# All paths are resolved first so aliases of the same device are rejected.
#
# $1: minimum number of distinct devices
# $2: human-readable layout name used in errors
# $@: device paths
function validate_destructive_whole_block_devices() {
	# The nested installer replays disk_configuration only to reconstruct IDs and
	# boot parameters. At that point the outer installer has intentionally
	# mounted the target, so host-side busy checks would reject every valid run.
	[[ ${RUNNING_IN_INSTALLER_CHROOT:-false} != true ]] || return 0

	local minimum="$1"
	local layout_name="$2"
	shift 2
	local device
	local canonical
	local -A seen=()

	[[ "$minimum" =~ ^[1-9][0-9]*$ ]] \
		|| die "Invalid minimum device count '$minimum'"
	[[ "$#" -ge "$minimum" ]] \
		|| die "$layout_name requires at least $minimum distinct whole block devices"

	for device in "$@"; do
		canonical="$(canonicalize_whole_block_device "$device")" \
			|| die "Invalid destructive device '$device' for $layout_name"
		[[ ! -v "seen[$canonical]" ]] \
			|| die "$layout_name contains the same device more than once ('$device' resolves to '$canonical')"
		seen[$canonical]=true

		if block_device_is_in_use "$canonical"; then
			die "Refusing to modify '$device' ('$canonical'): the device or one of its children is mounted or otherwise in use"
		fi
	done
}

function resolve_device_by_id() {
	local id="$1"
	[[ -v DISK_ID_TO_RESOLVABLE[$id] ]] \
		|| die "Cannot resolve id='$id' to a block device (no table entry)"

	local type="${DISK_ID_TO_RESOLVABLE[$id]%%:*}"
	local arg="${DISK_ID_TO_RESOLVABLE[$id]#*:}"

	local dev
	case "$type" in
		'partuuid') dev="$(get_device_by_partuuid   "$arg")" || return 1 ;;
		'ptuuid')   dev="$(get_device_by_ptuuid     "$arg")" || return 1 ;;
		'uuid')     dev="$(get_device_by_uuid       "$arg")" || return 1 ;;
		'mdadm')    dev="$(get_device_by_mdadm_uuid "$arg")" || return 1 ;;
		'luks')     dev="$(get_device_by_luks_name  "$arg")" || return 1 ;;
		'device')   dev="$arg" ;;
		*) die "Cannot resolve '$type:$arg' to device (unknown type)"
	esac

	[[ -n $dev ]] \
		|| { eerror "Resolved id '$id' to an empty device path"; return 1; }
	canonicalize_device "$dev" || return 1
}

function load_or_generate_uuid() {
	local uuid
	local uuid_file="$UUID_STORAGE_DIR/$1"

	if [[ -e $uuid_file || -L $uuid_file ]]; then
		[[ ! -L $uuid_file && -f $uuid_file ]] \
			|| die "Unsafe UUID state file '$uuid_file'"
		uuid="$(cat -- "$uuid_file")" \
			|| die "Could not read UUID state file '$uuid_file'"
	else
		uuid="$(uuidgen -r)" \
			|| die "Could not generate UUID for installer state"
		install -d -m 0700 -- "$UUID_STORAGE_DIR" \
			|| die "Could not create UUID storage '$UUID_STORAGE_DIR'"
		printf '%s' "$uuid" > "$uuid_file" \
			|| die "Could not write UUID state file '$uuid_file'"
		chmod 0600 -- "$uuid_file" \
			|| die "Could not protect UUID state file '$uuid_file'"
	fi
	[[ $uuid =~ $INSTALLER_UUID_REGEX ]] \
		|| die "Invalid UUID in installer state file '$uuid_file'"

	echo -n "$uuid"
}

# Encodes a disk id the same way create_new_id does for its state file name
function uuid_storage_key() {
	base64 -w 0 <<< "$1" \
		|| die "Could not encode identifier '$1' for UUID storage"
}

# Overwrites the stored uuid of an id so the installer inside the chroot resolves the same device
function persist_installer_uuid() {
	local id="$1"
	local uuid="$2"
	[[ $uuid =~ $INSTALLER_UUID_REGEX ]] \
		|| die "Refusing to store malformed UUID '$uuid' for identifier '$id'"

	local storage_key
	storage_key="$(uuid_storage_key "$id")" \
		|| die "Could not encode identifier '$id' for UUID storage"
	local uuid_file="$UUID_STORAGE_DIR/$storage_key"
	[[ ! -L $uuid_file ]] \
		|| die "Unsafe UUID state file '$uuid_file'"
	install -d -m 0700 -- "$UUID_STORAGE_DIR" \
		|| die "Could not create UUID storage '$UUID_STORAGE_DIR'"
	printf '%s' "$uuid" > "$uuid_file" \
		|| die "Could not write UUID state file '$uuid_file'"
	chmod 0600 -- "$uuid_file" \
		|| die "Could not protect UUID state file '$uuid_file'"
}

# Parses named arguments and stores them in the associative array `arguments`.
# If given, the associative array `known_arguments` must contain a list of arguments
# prefixed with + (mandatory) or ? (optional). "at least one of" can be expressed by +a|b|c.
function parse_arguments() {
	local key
	local value
	local a
	for a in "$@"; do
		key="${a%%=*}"
		value="${a#*=}"

		if [[ $key == "$a" ]]; then
			extra_arguments+=("$a")
			continue
		fi

		arguments[$key]="$value"
	done

	declare -A allowed_keys
	if [[ -v known_arguments ]]; then
		local m
		for m in "${known_arguments[@]}"; do
			case "${m:0:1}" in
				'+')
					m="${m:1}"
					local has_opt=false
					local m_opt
					# Splitting is intentional here
					# shellcheck disable=SC2086
					for m_opt in ${m//|/ }; do
						allowed_keys[$m_opt]=true
						if [[ -v arguments[$m_opt] ]]; then
							has_opt=true
						fi
					done

					[[ $has_opt == "true" ]] \
						|| die_trace 2 "Missing mandatory argument $m=..."
					;;

				'?')
					allowed_keys[${m:1}]=true
					;;

				*) die_trace 2 "Invalid start character in known_arguments, in argument '$m'" ;;
			esac
		done

		for a in "${!arguments[@]}"; do
			[[ -v allowed_keys[$a] ]] \
				|| die_trace 2 "Unknown argument '$a'"
		done
	fi
}

# $1: program
# $2: checkfile
function has_program() {
	local program="$1"
	local checkfile="$2"
	if [[ -z "$checkfile" ]]; then
		type "$program" &>/dev/null \
			|| return 1
	elif [[ "${checkfile:0:1}" == "/" ]]; then
		[[ -e "$checkfile" ]] \
			|| return 1
	else
		type "$checkfile" &>/dev/null \
			|| return 1
	fi
	return 0
}

function check_wanted_programs() {
	local -a missing_required=()
	local -a missing_wanted=()
	local tuple
	local program
	local checkfile
	for tuple in "$@"; do
		program="${tuple%%=*}"
		checkfile=""
		[[ "$tuple" == *=* ]] \
			&& checkfile="${tuple##*=}"
		if ! has_program "${program#"?"}" "$checkfile"; then
			if [[ "$program" == "?"* ]]; then
				missing_wanted+=("${program#"?"}")
			else
				missing_required+=("$program")
			fi
		fi
	done

	[[ "${#missing_required[@]}" -eq 0 && "${#missing_wanted[@]}" -eq 0 ]] \
		&& return

	if [[ "${#missing_required[@]}" -gt 0 ]]; then
		elog "The following programs are required for the installer to work, but are currently missing on your system:" >&2
		elog "  ${missing_required[*]}" >&2
	fi
	if [[ "${#missing_wanted[@]}" -gt 0 ]]; then
		elog "Missing optional programs:" >&2
		elog "  ${missing_wanted[*]}" >&2
	fi

	if type pacman &>/dev/null; then
		declare -A pacman_packages
		pacman_packages=(
			[awk]=gawk
			[base64]=coreutils
			[basename]=coreutils
			[blkid]=util-linux
			[btrfs]=btrfs-progs
			[chronyd]=chrony
			[chroot]=coreutils
			[date]=coreutils
			[dirname]=coreutils
			[find]=findutils
			[findmnt]=util-linux
			[gpg]=gnupg
			[grep]=grep
			[head]=coreutils
			[hwclock]=util-linux
			[install]=coreutils
			[lsblk]=util-linux
			[mkfs.btrfs]=btrfs-progs
			[mkfs.ext4]=e2fsprogs
			[mkfs.fat]=dosfstools
			[mktemp]=coreutils
			[mkswap]=util-linux
			[mount]=util-linux
			[mountpoint]=util-linux
			[ncurses]=ncurses
			[ntpd]=ntp
			[partprobe]=parted
			[python3]=python
			[readlink]=coreutils
			[realpath]=coreutils
			[sed]=sed
			[sha512sum]=coreutils
			[sgdisk]=gptfdisk
			[sort]=coreutils
			[stat]=coreutils
			[tar]=tar
			[tr]=coreutils
			[umount]=util-linux
			[uuidgen]=util-linux
			[wc]=coreutils
			[wipefs]=util-linux
			[zfs]=""
			[zpool]=""
		)
		elog "Detected pacman package manager."
		if ask "Do you want to install all missing programs automatically?"; then
			local -a packages=()
			local -A package_set=()
			local package
			local need_zfs=false

			for program in "${missing_required[@]}" "${missing_wanted[@]}"; do
				[[ "$program" == "zfs" || "$program" == "zpool" ]] \
					&& need_zfs=true

				if [[ -v "pacman_packages[$program]" ]]; then
					# Assignments to the empty string are explicitly ignored,
					# as for example, zfs needs to be handled separately.
					package="${pacman_packages[$program]}"
				else
					package="$program"
				fi
				if [[ -n "$package" && ! -v "package_set[$package]" ]]; then
					package_set[$package]=true
					packages+=("$package")
				fi
			done
			if [[ "${#packages[@]}" -gt 0 ]]; then
				pacman -Sy --needed "${packages[@]}" \
					|| ewarn "Package installation failed; dependencies will be checked again."
			fi

			if [[ "$need_zfs" == true ]]; then
				ewarn "Automatic ZFS bootstrapping is disabled: executing an unpinned remote script as root is unsafe."
				ewarn "Install trusted ZFS userspace tools and a module matching the running live kernel, verify both 'zfs' and 'zpool', then rerun the installer."
			fi
		fi
	elif type emerge &>/dev/null; then
		elog "Detected Portage (emerge) package manager."
		if ask "Do you want to install all missing programs automatically?"; then
			elog "Updating Portage repository cache..."
			emerge --sync || die "Failed to synchronize Portage repositories."

			for program in "${missing_required[@]}" "${missing_wanted[@]}"; do
				case "$program" in
					ntpd)
						elog "Installing ntpd using emerge..."
						emerge --ask net-misc/ntp \
							|| ewarn "Failed to install ntpd; dependencies will be checked again."
						;;
					chronyd)
						elog "Installing chronyd using emerge..."
						emerge --ask net-misc/chrony \
							|| ewarn "Failed to install chronyd; dependencies will be checked again."
						;;
					*) elog "You need to manually install $program." ;;
				esac
			done
		fi
	fi

	# Never trust the package-manager command alone: verify every original tuple
	# again, including tuples which use a separate checkfile.
	missing_required=()
	missing_wanted=()
	for tuple in "$@"; do
		program="${tuple%%=*}"
		checkfile=""
		[[ "$tuple" == *=* ]] \
			&& checkfile="${tuple##*=}"
		if ! has_program "${program#"?"}" "$checkfile"; then
			if [[ "$program" == "?"* ]]; then
				missing_wanted+=("${program#"?"}")
			else
				missing_required+=("$program")
			fi
		fi
	done

	if [[ "${#missing_required[@]}" -gt 0 ]]; then
		die "Aborted installer because required programs are still missing: ${missing_required[*]}"
	fi
	if [[ "${#missing_wanted[@]}" -gt 0 ]]; then
		ewarn "Optional programs are still missing: ${missing_wanted[*]}"
		ask "Continue without these optional programs?" \
			|| die "Aborted because optional dependencies were declined"
	fi
}

# exec function if defined
# $@ function name and arguments
function maybe_exec() {
	if type "$1" &>/dev/null; then
		"$@"
	else
		return 0
	fi
}
