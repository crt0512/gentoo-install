# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Functions

function install_stage3() {
	prepare_installation_environment
	download_stage3
	# A required removable backup destination may have disappeared during the
	# download. Revalidate it immediately before any disk can be modified.
	validate_luks_header_export_destination
	apply_disk_configuration
	extract_stage3
}

function configure_base_system() {
	if [[ $MUSL == "true" ]]; then
		einfo "Installing musl-locales"
		try_fatal emerge --verbose sys-apps/musl-locales
		echo 'MUSL_LOCPATH="/usr/share/i18n/locales/musl"' >> /etc/env.d/00local \
			|| die "Could not write to /etc/env.d/00local"
	else
		einfo "Generating locales"
		echo "$LOCALES" > /etc/locale.gen \
			|| die "Could not write /etc/locale.gen"
		locale-gen \
			|| die "Could not generate locales"
	fi

	if [[ $SYSTEMD == "true" ]]; then
		einfo "Setting machine-id"
		systemd-machine-id-setup \
			|| die "Could not setup systemd machine id"

		# Set hostname
		einfo "Selecting hostname"
		echo "$HOSTNAME" > /etc/hostname \
			|| die "Could not write /etc/hostname"

		# Set keymap
		einfo "Selecting keymap"
		echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf \
			|| die "Could not write /etc/vconsole.conf"

		# Set locale
		einfo "Selecting locale"
		echo "LANG=$LOCALE" > /etc/locale.conf \
			|| die "Could not write /etc/locale.conf"

		einfo "Selecting timezone"
		ln -sfn "../usr/share/zoneinfo/$TIMEZONE" /etc/localtime \
			|| die "Could not change /etc/localtime link"
	else
		# Set hostname
		einfo "Selecting hostname"
		sed -i "/hostname=/c\\hostname=\"$HOSTNAME\"" /etc/conf.d/hostname \
			|| die "Could not sed replace in /etc/conf.d/hostname"

		# Set timezone
		if [[ $MUSL == "true" ]]; then
			try_fatal emerge -v sys-libs/timezone-data
			einfo "Selecting timezone"
			echo -e "TZ=\"$TIMEZONE\"" >> /etc/env.d/00local \
				|| die "Could not write to /etc/env.d/00local"
		else
			einfo "Selecting timezone"
			echo "$TIMEZONE" > /etc/timezone \
				|| die "Could not write /etc/timezone"
			chmod 644 /etc/timezone \
				|| die "Could not set correct permissions for /etc/timezone"
			try_fatal emerge -v --config sys-libs/timezone-data
		fi

		# Set keymap
		einfo "Selecting keymap"
		sed -i "/keymap=/c\\keymap=\"$KEYMAP\"" /etc/conf.d/keymaps \
			|| die "Could not sed replace in /etc/conf.d/keymaps"

		# Set locale
		einfo "Selecting locale"
		try_fatal eselect locale set "$LOCALE"
	fi

	# Update environment
	env_update
}

# Restricts mirrorselect to one country, which avoids probing the full worldwide mirror list
function select_mirrors_in_country() {
	einfo "Restricting mirror selection to $SELECT_MIRRORS_COUNTRY"
	if ! mirrorselect -c "$SELECT_MIRRORS_COUNTRY" "$@"; then
		ewarn "mirrorselect found no usable mirrors in $SELECT_MIRRORS_COUNTRY, falling back to the full mirror list"
		return 1
	fi

	# A filter matching nothing can still exit successfully, so make sure a mirror was really written
	local mirrors
	mirrors="$(sed -n 's/^GENTOO_MIRRORS=//p' /etc/portage/make.conf 2>/dev/null | tail -n1)"
	mirrors="${mirrors//[\"[:space:]]/}"
	if [[ -z $mirrors ]]; then
		ewarn "mirrorselect did not select any mirror in $SELECT_MIRRORS_COUNTRY, falling back to the full mirror list"
		return 1
	fi
}

function configure_portage() {
	# Prepare /etc/portage for autounmask
	mkdir_or_die 0755 "/etc/portage/package.use"
	touch_or_die 0644 "/etc/portage/package.use/zz-autounmask"
	mkdir_or_die 0755 "/etc/portage/package.keywords"
	touch_or_die 0644 "/etc/portage/package.keywords/zz-autounmask"
	touch_or_die 0644 "/etc/portage/package.license"

	if [[ $SELECT_MIRRORS == "true" ]]; then
		einfo "Temporarily installing mirrorselect"
		try emerge --verbose --oneshot app-portage/mirrorselect

		einfo "Selecting fastest portage mirrors"
		mirrorselect_params=("-s" "4" "-b" "10")
		[[ $SELECT_MIRRORS_LARGE_FILE == "true" ]] \
			&& mirrorselect_params+=("-D")
		if [[ -n ${SELECT_MIRRORS_COUNTRY:-} ]] && select_mirrors_in_country "${mirrorselect_params[@]}"; then
			einfo "Selected portage mirrors in $SELECT_MIRRORS_COUNTRY"
		else
			try mirrorselect "${mirrorselect_params[@]}"
		fi
	fi

	if [[ $ENABLE_BINPKG == "true" ]]; then
		echo 'FEATURES="getbinpkg binpkg-request-signature"' >> /etc/portage/make.conf \
			|| die "Could not enable verified binary packages"
		getuto \
			|| die "Could not initialize Gentoo binary-package trust"
		chmod 644 /etc/portage/gnupg/pubring.kbx \
			|| die "Could not protect the binary-package keyring"
	fi

	chmod 644 /etc/portage/make.conf \
		|| die "Could not chmod 644 /etc/portage/make.conf"
}

function enable_sshd() {
	einfo "Installing and enabling sshd"
	install -m0600 -o root -g root "$GENTOO_INSTALL_REPO_DIR/contrib/sshd_config" /etc/ssh/sshd_config \
		|| die "Could not install /etc/ssh/sshd_config"
	enable_service sshd
}

function install_authorized_keys() {
	mkdir_or_die 0700 "/root/"
	mkdir_or_die 0700 "/root/.ssh"

	if [[ -n "$ROOT_SSH_AUTHORIZED_KEYS" ]]; then
		einfo "Adding authorized keys for root"
		touch_or_die 0600 "/root/.ssh/authorized_keys"
		echo "$ROOT_SSH_AUTHORIZED_KEYS" > "/root/.ssh/authorized_keys" \
			|| die "Could not add ssh key to /root/.ssh/authorized_keys"
	fi
}

function group_exists() {
	local name
	while IFS=: read -r name _; do
		[[ $name == "$1" ]] \
			&& return 0
	done < /etc/group
	return 1
}

function account_exists() {
	local login
	while IFS=: read -r login _; do
		[[ $login == "$1" ]] \
			&& return 0
	done < /etc/passwd
	return 1
}

function account_is_in_group() {
	local name members
	while IFS=: read -r name _ _ members; do
		[[ $name == "$2" ]] \
			|| continue
		[[ ",$members," == *",$1,"* ]] \
			&& return 0
	done < /etc/group
	return 1
}

function account_home_dir() {
	local login home
	while IFS=: read -r login _ _ _ _ home _; do
		[[ $login == "$1" ]] \
			|| continue
		echo -n "$home"
		return 0
	done < /etc/passwd
	return 1
}

# Prints the subset of CREATE_USER_GROUPS which actually exists in the new system
function existing_user_groups() {
	local -a existing=()
	local group
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for group in ${CREATE_USER_GROUPS//,/ }; do
		if group_exists "$group"; then
			existing+=("$group")
		else
			ewarn "Skipping group '$group' for user '$CREATE_USER', it does not exist"
		fi
	done

	local IFS=,
	echo -n "${existing[*]-}"
}

function install_user_authorized_keys() {
	local home
	home="$(account_home_dir "$CREATE_USER")" \
		|| die "Could not determine the home directory of '$CREATE_USER'"
	[[ -n $home && -d $home ]] \
		|| die "User '$CREATE_USER' has no home directory"

	einfo "Adding authorized keys for $CREATE_USER"
	mkdir_or_die 0700 "$home/.ssh"
	touch_or_die 0600 "$home/.ssh/authorized_keys"
	echo "$CREATE_USER_SSH_AUTHORIZED_KEYS" > "$home/.ssh/authorized_keys" \
		|| die "Could not add ssh keys to '$home/.ssh/authorized_keys'"
	chown -R "$CREATE_USER:" "$home/.ssh" \
		|| die "Could not change owner of '$home/.ssh'"
}

function configure_user_sudo() {
	einfo "Installing sudo"
	try_fatal emerge --verbose app-admin/sudo

	mkdir_or_die 0750 "/etc/sudoers.d"
	echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel \
		|| die "Could not write /etc/sudoers.d/10-wheel"
	chmod 0440 /etc/sudoers.d/10-wheel \
		|| die "Could not protect /etc/sudoers.d/10-wheel"
	visudo -c -f /etc/sudoers.d/10-wheel >/dev/null \
		|| die "Generated an invalid /etc/sudoers.d/10-wheel"
}

function create_configured_user() {
	[[ -n ${CREATE_USER:-} ]] \
		|| return 0

	local groups
	groups="$(existing_user_groups)"
	local -a group_args=()
	[[ -z $groups ]] \
		|| group_args=("-G" "$groups")

	einfo "Creating user $CREATE_USER"
	if account_exists "$CREATE_USER"; then
		ewarn "User '$CREATE_USER' already exists, only its groups and shell will be updated"
		if [[ ${#group_args[@]} -gt 0 ]]; then
			try_fatal usermod -a "${group_args[@]}" -s "$CREATE_USER_SHELL" "$CREATE_USER"
		else
			try_fatal usermod -s "$CREATE_USER_SHELL" "$CREATE_USER"
		fi
	else
		try_fatal useradd -m "${group_args[@]}" -s "$CREATE_USER_SHELL" "$CREATE_USER"
	fi

	[[ -z $CREATE_USER_SSH_AUTHORIZED_KEYS ]] \
		|| install_user_authorized_keys
	[[ $CREATE_USER_SUDO != "true" ]] \
		|| configure_user_sudo

	if ask "Do you want to assign a password for $CREATE_USER now?"; then
		passwd "$CREATE_USER" \
			|| die "Could not set the password of '$CREATE_USER'"
		account_has_password "$CREATE_USER" \
			|| die "Password of '$CREATE_USER' was not set"
		einfo "Password for $CREATE_USER assigned"
	else
		ewarn "User '$CREATE_USER' has no password and can only log in with an ssh key"
	fi
}

# True when the created user can administer the system, which makes a root password optional
function configured_user_can_administer() {
	[[ -n ${CREATE_USER:-} && $CREATE_USER_SUDO == "true" ]] \
		|| return 1
	account_has_password "$CREATE_USER" \
		|| return 1
	account_is_in_group "$CREATE_USER" wheel
}

function account_has_password() {
	local account="$1"
	local login
	local password_hash
	[[ -r /etc/shadow ]] || return 1
	while IFS=: read -r login password_hash _; do
		[[ $login == "$account" ]] || continue
		[[ -n $password_hash && $password_hash != '!'* && $password_hash != '*'* ]]
		return
	done < /etc/shadow
	return 1
}

function lock_root_account() {
	passwd -l root \
		|| die "Could not lock root account"
	if account_has_password root; then
		die "Root account still has an active password after it was locked"
	fi
	return 0
}

function ensure_safe_admin_access() {
	if account_has_password root; then
		einfo "Verified password access for root"
		return 0
	fi

	if configured_user_can_administer; then
		einfo "Verified password access for $CREATE_USER, which can use sudo"
		return 0
	fi

	ewarn "No usable root password was found."
	einfo "A root password is required to avoid installing an inaccessible system."
	passwd root \
		|| die "Could not set the required root password"
	account_has_password root \
		|| die "Root password was not set"
}

function generate_initramfs() {
	local output="$1"

	# Generate initramfs
	einfo "Generating initramfs"

	local modules=()
	[[ $USED_RAID == "true" ]] \
		&& modules+=("mdraid")
	[[ $USED_LUKS == "true" ]] \
		&& modules+=("crypt crypt-gpg")
	[[ $USED_BTRFS == "true" ]] \
		&& modules+=("btrfs")
	[[ $USED_ZFS == "true" ]] \
		&& modules+=("zfs")

	local kver
	kver="$(readlink /usr/src/linux)" \
		|| die "Could not figure out kernel version from /usr/src/linux symlink."
	kver="${kver#linux-}"

	local dracut_opts=()
	if [[ $SYSTEMD == "true" && $SYSTEMD_INITRAMFS_SSHD == "true" ]]; then
		# Pin dracut-sshd to an immutable commit. Checking the resolved commit
		# prevents a moved tag from silently changing initramfs code run as root.
		local dracut_sshd_ref="0.7.1"
		local dracut_sshd_commit="777c87cf7b34d24df55a66b4d5beed1300d63a1b"
		local dracut_sshd_tmp
		dracut_sshd_tmp="$(mktemp -d /tmp/dracut-sshd.XXXXXXXX)" \
			|| die "Could not create temporary directory for dracut-sshd"
		git clone --quiet --depth 1 --branch "$dracut_sshd_ref" \
			https://github.com/gsauthof/dracut-sshd.git "$dracut_sshd_tmp/repo" \
			|| die "Could not clone pinned dracut-sshd release $dracut_sshd_ref"
		local dracut_sshd_resolved_commit
		dracut_sshd_resolved_commit="$(git -C "$dracut_sshd_tmp/repo" rev-parse --verify HEAD^{commit})" \
			|| die "Could not resolve cloned dracut-sshd commit"
		[[ $dracut_sshd_resolved_commit == "$dracut_sshd_commit" ]] \
			|| die "dracut-sshd commit mismatch (expected $dracut_sshd_commit, got $dracut_sshd_resolved_commit)"
		[[ -d "$dracut_sshd_tmp/repo/46sshd" ]] \
			|| die "Pinned dracut-sshd checkout does not contain the 46sshd module"

		local dracut_sshd_module="/usr/lib/dracut/modules.d/46sshd"
		rm -rf -- "$dracut_sshd_module" \
			|| die "Could not remove an existing dracut-sshd module"
		mkdir_or_die 0755 "$dracut_sshd_module"
		cp -a -- "$dracut_sshd_tmp/repo/46sshd/." "$dracut_sshd_module/" \
			|| die "Could not install the pinned dracut-sshd module"
		rm -rf -- "$dracut_sshd_tmp" \
			|| die "Could not remove temporary dracut-sshd checkout"
		sed -e 's/^Type=notify/Type=simple/' \
			-e 's@^\(ExecStart=/usr/sbin/sshd\) -D@\1 -e -D@' \
			-i "$dracut_sshd_module/sshd.service" \
			|| die "Could not replace sshd options in service file"
		grep -qx 'Type=simple' "$dracut_sshd_module/sshd.service" \
			|| die "Pinned dracut-sshd service was not adapted for Gentoo OpenSSH"
		grep -q '^ExecStart=/usr/sbin/sshd -e -D' "$dracut_sshd_module/sshd.service" \
			|| die "Pinned dracut-sshd service is missing the required stderr logging option"
		dracut_opts+=("--install" "/etc/systemd/network/20-wired.network")
		modules+=("systemd-networkd")
	fi

	# Generate initramfs
	# TODO --conf          "/dev/null" \
	# TODO --confdir       "/dev/null" \
	dracut \
		--kver          "$kver" \
		--zstd \
		--no-hostonly \
		--ro-mnt \
		--add           "bash ${modules[*]}" \
		"${dracut_opts[@]}" \
		--force \
		"$output" \
		|| die "Could not generate initramfs '$output'"

	# Create script to repeat initramfs generation
	local regenerate_script="$(dirname "$output")/generate_initramfs.sh"
	cat > "$regenerate_script" <<EOF || die "Could not write '$regenerate_script'"
#!/bin/bash
kver="\$1"
output="\$2" # At setup time, this was "$output"
[[ -n "\$kver" ]] || { echo "usage \$0 <kernel_version> <output>" >&2; exit 1; }
dracut \\
	--kver          "\$kver" \\
	--zstd \\
	--no-hostonly \\
	--ro-mnt \\
	--add           "bash ${modules[*]}" \\
	${dracut_opts[@]@Q} \\
	--force \\
	"\$output"
EOF
	chmod 0700 "$regenerate_script" \
		|| die "Could not make '$regenerate_script' executable"
}

function get_cmdline() {
	local cmdline=("rd.vconsole.keymap=$KEYMAP_INITRAMFS")
	cmdline+=("${DISK_DRACUT_CMDLINE[@]}")

	if [[ $USED_ZFS != "true" ]]; then
		local root_uuid
		root_uuid="$(get_blkid_uuid_for_id "$DISK_ID_ROOT")" \
			|| return 1
		[[ -n $root_uuid ]] || return 1
		cmdline+=("root=UUID=$root_uuid")
	fi

	echo -n "${cmdline[*]}"
}

function write_kernel_cmdline_files() {
	local cmdline
	cmdline="$(get_cmdline)" \
		|| die "Could not generate kernel command line"
	[[ -n $cmdline ]] \
		|| die "Refusing to install a kernel with an empty command line"

	mkdir_or_die 0755 "/etc/kernel"
	printf '%s\n' "$cmdline" > /etc/cmdline \
		|| die "Could not write /etc/cmdline"
	printf '%s\n' "$cmdline" > /etc/kernel/cmdline \
		|| die "Could not write /etc/kernel/cmdline"
	chmod 0644 /etc/cmdline /etc/kernel/cmdline \
		|| die "Could not set permissions on kernel command-line files"
}

# Return the physical partitions that firmware can boot for a boot filesystem.
# A RAID1 boot filesystem must use metadata 1.0 so its members remain directly
# readable by firmware and bootloaders.
function collect_boot_partition_members() {
	local boot_device="$1"
	local -n output_members="$2"
	output_members=()

	boot_device="$(realpath -- "$boot_device")" \
		|| die "Could not canonicalize boot device '$boot_device'"
	[[ -b $boot_device ]] \
		|| die "Boot device is not a block device: '$boot_device'"

	local sys_device="/sys/class/block/$(basename "$boot_device")"
	[[ -e $sys_device ]] \
		|| die "Could not find sysfs information for boot device '$boot_device'"

	if [[ -d $sys_device/md ]]; then
		local raid_level
		local metadata_version
		read -r raid_level < "$sys_device/md/level" \
			|| die "Could not read RAID level for boot device '$boot_device'"
		read -r metadata_version < "$sys_device/md/metadata_version" \
			|| die "Could not read RAID metadata version for boot device '$boot_device'"
		[[ $raid_level == "raid1" ]] \
			|| die "Boot device '$boot_device' uses unsupported RAID level '$raid_level'; only RAID1 is bootable"
		[[ $metadata_version == "1.0" ]] \
			|| die "Boot RAID '$boot_device' uses metadata $metadata_version; metadata 1.0 is required for firmware-readable members"

		local slave
		for slave in "$sys_device/slaves"/*; do
			[[ -e $slave ]] || continue
			output_members+=("/dev/$(basename "$slave")")
		done
		[[ ${#output_members[@]} -gt 0 ]] \
			|| die "Boot RAID '$boot_device' has no visible member partitions"
	else
		output_members+=("$boot_device")
	fi
}

# Resolve a partition to the whole disk and partition number expected by
# efibootmgr and bootloader installers.
function resolve_partition_location() {
	local partition_device="$1"
	local -n output_parent_disk="$2"
	local -n output_partition_number="$3"

	partition_device="$(realpath -- "$partition_device")" \
		|| die "Could not canonicalize boot partition '$partition_device'"
	[[ -b $partition_device ]] \
		|| die "Boot RAID member is not a block device: '$partition_device'"

	local sys_partition="/sys/class/block/$(basename "$partition_device")"
	[[ -r $sys_partition/partition ]] \
		|| die "Boot device '$partition_device' is not a physical partition"
	read -r output_partition_number < "$sys_partition/partition" \
		|| die "Could not read partition number for '$partition_device'"
	[[ $output_partition_number =~ ^[1-9][0-9]*$ ]] \
		|| die "Invalid partition number '$output_partition_number' for '$partition_device'"

	local parent_sys
	parent_sys="$(realpath -- "$sys_partition/..")" \
		|| die "Could not resolve parent disk for '$partition_device'"
	output_parent_disk="/dev/$(basename "$parent_sys")"
	[[ -b $output_parent_disk ]] \
		|| die "Resolved parent '$output_parent_disk' for '$partition_device' is not a block device"
}

function get_boot_mountpoint() {
	if [[ $IS_EFI == "true" ]]; then
		echo -n "/boot/efi"
	else
		echo -n "/boot/bios"
	fi
}

function find_installed_kernel_file() {
	local kernel_file
	kernel_file="$(find "/boot" \( -name "vmlinuz-*" -or -name 'kernel-*' \) -printf '%f\n' | sort -V | tail -n 1)" \
		|| die "Could not list newest kernel file"
	[[ -n $kernel_file && -f /boot/$kernel_file ]] \
		|| die "Could not find an installed kernel in /boot"
	echo -n "/boot/$kernel_file"
}

function install_kernel_boot_assets() {
	local boot_dir
	local kernel_file
	boot_dir="$(get_boot_mountpoint)"
	kernel_file="$(find_installed_kernel_file)"

	cp -- "$kernel_file" "$boot_dir/vmlinuz-current" \
		|| die "Could not copy kernel to $boot_dir/vmlinuz-current"
	generate_initramfs "$boot_dir/initramfs.img"
}

function efi_arch_suffix() {
	case "$GENTOO_ARCH" in
		amd64) echo -n "x64" ;;
		x86)   echo -n "ia32" ;;
		arm64) echo -n "aa64" ;;
		*) die "EFI bootloader installation is not implemented for GENTOO_ARCH='$GENTOO_ARCH'" ;;
	esac
}

function efi_fallback_binary_name() {
	local suffix
	suffix="$(efi_arch_suffix)"
	echo -n "BOOT${suffix^^}.EFI"
}

function grub_efi_target() {
	case "$GENTOO_ARCH" in
		amd64) echo -n "x86_64-efi" ;;
		x86)   echo -n "i386-efi" ;;
		*) die "GRUB EFI installation is implemented only for GENTOO_ARCH=amd64 or x86" ;;
	esac
}

function grub_platform_useflag() {
	case "$GENTOO_ARCH" in
		amd64) echo -n "efi-64" ;;
		x86)   echo -n "efi-32" ;;
		*) die "GRUB EFI installation is implemented only for GENTOO_ARCH=amd64 or x86" ;;
	esac
}

function grub_efi_loader_path() {
	case "$GENTOO_ARCH" in
		amd64) echo -n '\EFI\gentoo\grubx64.efi' ;;
		x86)   echo -n '\EFI\gentoo\grubia32.efi' ;;
		*) die "GRUB EFI loader path is implemented only for GENTOO_ARCH=amd64 or x86" ;;
	esac
}

function limine_efi_useflag() {
	case "$GENTOO_ARCH" in
		amd64) echo -n "uefi-x86-64" ;;
		x86)   echo -n "uefi-ia32" ;;
		arm64) echo -n "uefi-aarch64" ;;
		*) die "Limine EFI installation is not implemented for GENTOO_ARCH='$GENTOO_ARCH'" ;;
	esac
}

function limine_efi_binary() {
	local binary
	binary="/usr/share/limine/$(efi_fallback_binary_name)"
	[[ -f $binary ]] \
		|| die "Could not find Limine EFI binary '$binary'"
	echo -n "$binary"
}

function systemd_boot_efi_loader_path() {
	local suffix
	suffix="$(efi_arch_suffix)"
	echo -n "\\EFI\\systemd\\systemd-boot${suffix}.efi"
}

function create_efi_boot_entries() {
	local label="$1"
	local loader="$2"
	local unicode_args="${3:-}"
	local boot_dir
	boot_dir="$(get_boot_mountpoint)"

	emerge --verbose sys-boot/efibootmgr \
		|| die "Could not install efibootmgr"

	local efipartdev
	efipartdev="$(resolve_device_by_id "$DISK_ID_EFI")" \
		|| die "Could not resolve device with id=$DISK_ID_EFI"
	local boot_partitions=()
	collect_boot_partition_members "$efipartdev" boot_partitions

	local add_entry_script="$boot_dir/efibootmgr_add_${label}_entry.sh"
	printf '%s\n' \
		'#!/bin/bash' \
		'set -euo pipefail' \
		'# Recreate the EFI boot entries generated by gentoo-easy-install.' \
		> "$add_entry_script" \
		|| die "Could not create '$add_entry_script'"

	local boot_partition
	local parent_disk
	local partition_number
	local -a efibootmgr_args
	for boot_partition in "${boot_partitions[@]}"; do
		resolve_partition_location "$boot_partition" parent_disk partition_number
		einfo "Adding EFI boot entry '$label' for $boot_partition on $parent_disk (partition $partition_number)"
		efibootmgr_args=(
			--verbose
			--create
			--disk "$parent_disk" \
			--part "$partition_number" \
			--label "$label" \
			--loader "$loader"
		)
		[[ -z $unicode_args ]] \
			|| efibootmgr_args+=(--unicode "$unicode_args")
		efibootmgr "${efibootmgr_args[@]}" \
			|| die "Could not create EFI boot entry for '$boot_partition'"
		printf '%q ' efibootmgr "${efibootmgr_args[@]}" \
			>> "$add_entry_script" \
			|| die "Could not update '$add_entry_script'"
		printf '\n' >> "$add_entry_script" \
			|| die "Could not update '$add_entry_script'"
	done
	chmod 0700 "$add_entry_script" \
		|| die "Could not make '$add_entry_script' executable"
}

function write_grub_cfg() {
	local boot_dir="$1"
	local kernel_cmdline
	kernel_cmdline="$(get_cmdline)" \
		|| die "Could not generate GRUB kernel command line"
	# DISK_ID_BIOS does not exist on efi systems, so it must not be expanded there
	local boot_id
	if [[ $IS_EFI == "true" ]]; then
		boot_id="$DISK_ID_EFI"
	else
		boot_id="$DISK_ID_BIOS"
	fi
	local boot_uuid
	boot_uuid="$(get_blkid_uuid_for_id "$boot_id")" \
		|| die "Could not resolve filesystem UUID for boot id '$boot_id'"
	[[ -n $boot_uuid ]] \
		|| die "Resolved an empty filesystem UUID for boot id '$boot_id'"

	mkdir_or_die 0755 "$boot_dir/grub"
	cat > "$boot_dir/grub/grub.cfg" <<EOF || die "Could not write '$boot_dir/grub/grub.cfg'"
set default=0
set timeout=5

insmod part_gpt
insmod fat
search --no-floppy --fs-uuid --set=root $boot_uuid

menuentry 'Gentoo Linux' {
	linux /vmlinuz-current $kernel_cmdline
	initrd /initramfs.img
}
EOF
}

function install_bootloader_grub() {
	[[ $IS_EFI == "true" ]] \
		|| die "BOOTLOADER=grub is currently supported only with EFI boot by this installer"

	local boot_dir
	local target
	local platform
	local loader
	boot_dir="$(get_boot_mountpoint)"
	target="$(grub_efi_target)"
	platform="$(grub_platform_useflag)"
	loader="$(grub_efi_loader_path)"

	einfo "Selecting GRUB platform '$platform'"
	mkdir_or_die 0755 "/etc/portage/package.use"
	printf 'sys-boot/grub grub_platforms_%s\n' "$platform" > /etc/portage/package.use/grub-platforms \
		|| die "Could not write /etc/portage/package.use/grub-platforms"

	einfo "Installing GRUB bootloader"
	emerge --verbose sys-boot/grub \
		|| die "Could not install GRUB"
	write_grub_cfg "$boot_dir"
	grub-install \
		--target="$target" \
		--efi-directory="$boot_dir" \
		--boot-directory="$boot_dir" \
		--bootloader-id=gentoo \
		--no-nvram \
		--recheck \
		|| die "Could not install GRUB EFI loader"
	create_efi_boot_entries "gentoo-grub" "$loader"
}

function write_limine_config() {
	local boot_dir="$1"
	local kernel_cmdline
	kernel_cmdline="$(get_cmdline)" \
		|| die "Could not generate Limine kernel command line"

	cat > "$boot_dir/limine.conf" <<EOF || die "Could not write '$boot_dir/limine.conf'"
timeout: 5

/Gentoo Linux
	protocol: linux
	kernel_path: boot():/vmlinuz-current
	module_path: boot():/initramfs.img
	cmdline: $kernel_cmdline
EOF
}

function install_limine_package() {
	mkdir_or_die 0755 "/etc/portage/package.accept_keywords"
	printf 'sys-boot/limine ~%s\n' "$GENTOO_ARCH" > /etc/portage/package.accept_keywords/limine \
		|| die "Could not write /etc/portage/package.accept_keywords/limine"

	mkdir_or_die 0755 "/etc/portage/package.use"
	if [[ $IS_EFI == "true" ]]; then
		printf 'sys-boot/limine %s\n' "$(limine_efi_useflag)" > /etc/portage/package.use/limine \
			|| die "Could not write /etc/portage/package.use/limine"
	else
		printf 'sys-boot/limine bios\n' > /etc/portage/package.use/limine \
			|| die "Could not write /etc/portage/package.use/limine"
	fi

	emerge --verbose sys-boot/limine \
		|| die "Could not install Limine"
}

function install_bootloader_limine() {
	local boot_dir
	boot_dir="$(get_boot_mountpoint)"

	einfo "Installing Limine bootloader"
	install_limine_package
	write_limine_config "$boot_dir"

	if [[ $IS_EFI == "true" ]]; then
		local efi_binary
		local fallback_binary
		efi_binary="$(limine_efi_binary)"
		fallback_binary="$(efi_fallback_binary_name)"
		mkdir_or_die 0755 "$boot_dir/EFI/limine"
		mkdir_or_die 0755 "$boot_dir/EFI/BOOT"
		install -m0644 -- "$efi_binary" "$boot_dir/EFI/limine/limine.efi" \
			|| die "Could not install Limine EFI loader"
		install -m0644 -- "$efi_binary" "$boot_dir/EFI/BOOT/$fallback_binary" \
			|| die "Could not install Limine fallback EFI loader"
		create_efi_boot_entries "gentoo-limine" '\EFI\limine\limine.efi'
		return 0
	fi

	local biosdev
	biosdev="$(resolve_device_by_id "$DISK_ID_BIOS")" \
		|| die "Could not resolve device with id=$DISK_ID_BIOS"
	local boot_partitions=()
	collect_boot_partition_members "$biosdev" boot_partitions

	install -m0644 -- /usr/share/limine/limine-bios.sys "$boot_dir/limine-bios.sys" \
		|| die "Could not install Limine BIOS support file"

	local boot_partition
	local parent_disk
	local partition_number
	for boot_partition in "${boot_partitions[@]}"; do
		resolve_partition_location "$boot_partition" parent_disk partition_number
		einfo "Installing Limine BIOS loader on $parent_disk for $boot_partition (partition $partition_number)"
		limine bios-install "$parent_disk" \
			|| die "Could not install Limine BIOS loader on '$parent_disk'"
	done
}

function install_systemd_boot_package() {
	mkdir_or_die 0755 "/etc/portage/package.use"
	if [[ $SYSTEMD == "true" ]]; then
		printf 'sys-apps/systemd boot\n' > /etc/portage/package.use/systemd-boot \
			|| die "Could not write /etc/portage/package.use/systemd-boot"
		emerge --verbose --changed-use --oneshot sys-apps/systemd \
			|| die "Could not install systemd-boot support"
	else
		printf 'sys-apps/systemd-utils boot\n' > /etc/portage/package.use/systemd-utils-boot \
			|| die "Could not write /etc/portage/package.use/systemd-utils-boot"
		emerge --verbose sys-apps/systemd-utils \
			|| die "Could not install systemd-boot support"
	fi
}

function write_systemd_boot_config() {
	local boot_dir="$1"
	local kernel_cmdline
	kernel_cmdline="$(get_cmdline)" \
		|| die "Could not generate systemd-boot kernel command line"

	mkdir_or_die 0755 "$boot_dir/loader/entries"
	cat > "$boot_dir/loader/loader.conf" <<EOF || die "Could not write '$boot_dir/loader/loader.conf'"
default gentoo.conf
timeout 5
editor no
EOF
	cat > "$boot_dir/loader/entries/gentoo.conf" <<EOF || die "Could not write '$boot_dir/loader/entries/gentoo.conf'"
title Gentoo Linux
linux /vmlinuz-current
initrd /initramfs.img
options $kernel_cmdline
EOF
}

function install_bootloader_systemd_boot() {
	[[ $IS_EFI == "true" ]] \
		|| die "BOOTLOADER=systemd-boot requires EFI boot"

	local boot_dir
	local loader
	boot_dir="$(get_boot_mountpoint)"
	loader="$(systemd_boot_efi_loader_path)"

	einfo "Installing systemd-boot"
	install_systemd_boot_package
	write_systemd_boot_config "$boot_dir"
	bootctl --esp-path="$boot_dir" --no-variables install \
		|| die "Could not install systemd-boot"
	create_efi_boot_entries "gentoo-systemd-boot" "$loader"
}

function install_kernel() {
	# Install vanilla kernel
	einfo "Installing vanilla kernel and related tools"
	install_kernel_boot_assets

	case "${BOOTLOADER:-grub}" in
		grub)         install_bootloader_grub ;;
		limine)       install_bootloader_limine ;;
		systemd-boot) install_bootloader_systemd_boot ;;
		*) die "Unsupported BOOTLOADER='${BOOTLOADER:-}'" ;;
	esac

	einfo "Installing linux-firmware"
	echo "sys-kernel/linux-firmware linux-fw-redistributable no-source-code" >> /etc/portage/package.license \
		|| die "Could not write to /etc/portage/package.license"
	try_fatal emerge --verbose linux-firmware
}

function add_fstab_entry() {
	printf '%-46s  %-24s  %-6s  %-96s %s\n' "$1" "$2" "$3" "$4" "$5" >> /etc/fstab \
		|| die "Could not append entry to fstab"
}

function generate_fstab() {
	einfo "Generating fstab"
	install -m0644 -o root -g root "$GENTOO_INSTALL_REPO_DIR/contrib/fstab" /etc/fstab \
		|| die "Could not overwrite /etc/fstab"
	if [[ $USED_ZFS != "true" ]]; then
		local root_type="${DISK_ID_ROOT_TYPE:-}"
		local root_mount_opts="${DISK_ID_ROOT_MOUNT_OPTS:-}"
		if [[ -z $root_type ]]; then
			local root_device
			root_device="$(resolve_device_by_id "$DISK_ID_ROOT")" \
				|| die "Could not resolve root device with id=$DISK_ID_ROOT"
			root_type="$(get_blkid_field_by_device 'TYPE' "$root_device")" \
				|| die "Could not detect filesystem type for existing root device '$root_device'"
		fi

		case "$root_type" in
			'ext4')
				[[ -n $root_mount_opts ]] \
					|| root_mount_opts="defaults,noatime,errors=remount-ro"
				;;
			'btrfs')
				[[ -n $root_mount_opts ]] \
					|| root_mount_opts="defaults,noatime"
				;;
			*)
				die "Unsupported or empty root filesystem type '$root_type'; supported types are ext4 and btrfs"
				;;
		esac
		local root_uuid
		root_uuid="$(get_blkid_uuid_for_id "$DISK_ID_ROOT")" \
			|| die "Could not resolve filesystem UUID for root id '$DISK_ID_ROOT'"
		[[ -n $root_uuid ]] \
			|| die "Resolved an empty filesystem UUID for root id '$DISK_ID_ROOT'"
		add_fstab_entry "UUID=$root_uuid" "/" "$root_type" "$root_mount_opts" "0 1"
	fi
	local boot_uuid
	if [[ $IS_EFI == "true" ]]; then
		boot_uuid="$(get_blkid_uuid_for_id "$DISK_ID_EFI")" \
			|| die "Could not resolve filesystem UUID for EFI id '$DISK_ID_EFI'"
		[[ -n $boot_uuid ]] \
			|| die "Resolved an empty filesystem UUID for EFI id '$DISK_ID_EFI'"
		add_fstab_entry "UUID=$boot_uuid" "/boot/efi" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	else
		boot_uuid="$(get_blkid_uuid_for_id "$DISK_ID_BIOS")" \
			|| die "Could not resolve filesystem UUID for BIOS id '$DISK_ID_BIOS'"
		[[ -n $boot_uuid ]] \
			|| die "Resolved an empty filesystem UUID for BIOS id '$DISK_ID_BIOS'"
		add_fstab_entry "UUID=$boot_uuid" "/boot/bios" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	fi
	if [[ -v "DISK_ID_SWAP" ]]; then
		local swap_uuid
		swap_uuid="$(get_blkid_uuid_for_id "$DISK_ID_SWAP")" \
			|| die "Could not resolve filesystem UUID for swap id '$DISK_ID_SWAP'"
		[[ -n $swap_uuid ]] \
			|| die "Resolved an empty filesystem UUID for swap id '$DISK_ID_SWAP'"
		add_fstab_entry "UUID=$swap_uuid" "none" "swap" "defaults,discard" "0 0"
	fi
}

function main_install_gentoo_in_chroot() {
	[[ $# == 0 ]] || die "Too many arguments"

	maybe_exec 'before_install' \
		|| die "Hook before_install failed"

	# Installer commands already run as root and do not need password login.
	# Keep the account locked until an explicit, verified access method exists.
	einfo "Locking root account during installation"
	lock_root_account

	# Sync portage
	einfo "Syncing portage tree"
	try_fatal emerge-webrsync

	# Install mdadm if we used RAID (needed for UUID resolving)
	if [[ $USED_RAID == "true" ]]; then
		einfo "Installing mdadm"
		try_fatal emerge --verbose sys-fs/mdadm
	fi

	if [[ $IS_EFI == "true" ]]; then
		# Mount efi partition
		mount_efivars
		einfo "Mounting efi partition"
		mount_by_id "$DISK_ID_EFI" "/boot/efi"
	else
		# Mount bios partition
		einfo "Mounting bios partition"
		mount_by_id "$DISK_ID_BIOS" "/boot/bios"
	fi

	# Configure basic system things like timezone, locale, ...
	maybe_exec 'before_configure_base_system' \
		|| die "Hook before_configure_base_system failed"
	configure_base_system
	maybe_exec 'after_configure_base_system' \
		|| die "Hook after_configure_base_system failed"

	# Prepare portage environment
	maybe_exec 'before_configure_portage' \
		|| die "Hook before_configure_portage failed"
	configure_portage

	# Install git (for git portage overlays)
	einfo "Installing git"
	try_fatal emerge --verbose dev-vcs/git

	if [[ "$PORTAGE_SYNC_TYPE" == "git" ]]; then
		mkdir_or_die 0755 "/etc/portage/repos.conf"
		cat > /etc/portage/repos.conf/gentoo.conf <<EOF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = $PORTAGE_GIT_MIRROR
auto-sync = yes
sync-depth = $([[ $PORTAGE_GIT_FULL_HISTORY == true ]] && echo -n 0 || echo -n 1)
sync-git-verify-commit-signature = yes
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
EOF
		chmod 644 /etc/portage/repos.conf/gentoo.conf \
			|| die "Could not change permissions of '/etc/portage/repos.conf/gentoo.conf'"
		rm -rf /var/db/repos/gentoo \
			|| die "Could not delete obsolete rsync gentoo repository"
		try_fatal emerge --sync
	fi
	maybe_exec 'after_configure_portage' \
		|| die "Hook after_configure_portage failed"

	einfo "Generating ssh host keys"
	try_fatal ssh-keygen -A

	# Install authorized_keys before dracut, which might need them for remote unlocking.
	install_authorized_keys
	write_kernel_cmdline_files

	einfo "Enabling dracut USE flag on sys-kernel/installkernel"
	echo "sys-kernel/installkernel dracut" > /etc/portage/package.use/installkernel \
		|| die "Could not write /etc/portage/package.use/installkernel"

	# Install required programs and kernel now, in order to
	# prevent emerging module before an imminent kernel upgrade
	if [[ "${KERNEL_TYPE:-bin}" == "source" ]]; then
		einfo "Building kernel from source (sys-kernel/gentoo-kernel)"
		emerge --verbose sys-kernel/dracut sys-kernel/gentoo-kernel app-arch/zstd \
			|| die "Could not install the source-built Gentoo kernel"
	else
		einfo "Installing binary kernel (sys-kernel/gentoo-kernel-bin)"
		emerge --verbose sys-kernel/dracut sys-kernel/gentoo-kernel-bin app-arch/zstd \
			|| die "Could not install the binary Gentoo kernel"
	fi

	# Install cryptsetup if we used LUKS
	if [[ $USED_LUKS == "true" ]]; then
		einfo "Installing cryptsetup"
		try_fatal emerge --verbose sys-fs/cryptsetup
	fi

	if [[ $SYSTEMD == "true" && $USED_LUKS == "true" ]] ; then
		einfo "Enabling cryptsetup USE flag on sys-apps/systemd"
		echo "sys-apps/systemd cryptsetup" > /etc/portage/package.use/systemd \
			|| die "Could not write /etc/portage/package.use/systemd"
		einfo "Rebuilding systemd with changed USE flag"
		try_fatal emerge --verbose --changed-use --oneshot sys-apps/systemd
	fi

	# Install btrfs-progs if we used Btrfs
	if [[ $USED_BTRFS == "true" ]]; then
		einfo "Installing btrfs-progs"
		try_fatal emerge --verbose sys-fs/btrfs-progs
	fi

	# Install ZFS kernel module and tools if we used ZFS
	if [[ $USED_ZFS == "true" ]]; then
		einfo "Installing zfs"
		try_fatal emerge --verbose sys-fs/zfs sys-fs/zfs-kmod

		einfo "Enabling zfs services"
		if [[ $SYSTEMD == "true" ]]; then
			try_fatal systemctl enable zfs.target
			try_fatal systemctl enable zfs-import-cache
			try_fatal systemctl enable zfs-mount
			try_fatal systemctl enable zfs-import.target
		else
			try_fatal rc-update add zfs-import boot
			try_fatal rc-update add zfs-mount boot
		fi
	fi

	# Install kernel and initramfs
	maybe_exec 'before_install_kernel' \
		|| die "Hook before_install_kernel failed"
	install_kernel
	maybe_exec 'after_install_kernel' \
		|| die "Hook after_install_kernel failed"

	# Generate a valid fstab file
	generate_fstab

	# Install gentoolkit
	einfo "Installing gentoolkit"
	try emerge --verbose app-portage/gentoolkit

	if [[ $SYSTEMD == "true" ]]; then
		if [[ $SYSTEMD_NETWORKD == "true" ]]; then
			# Enable systemd networking and dhcp
			enable_service systemd-networkd
			enable_service systemd-resolved
			if [[ $SYSTEMD_NETWORKD_DHCP == "true" ]]; then
				echo -en "[Match]\nName=${SYSTEMD_NETWORKD_INTERFACE_NAME}\n\n[Network]\nDHCP=yes" > /etc/systemd/network/20-wired.network \
					|| die "Could not write dhcp network config to '/etc/systemd/network/20-wired.network'"
			else
				addresses=""
				for addr in "${SYSTEMD_NETWORKD_ADDRESSES[@]}"; do
					addresses="${addresses}Address=$addr\n"
				done
				echo -en "[Match]\nName=${SYSTEMD_NETWORKD_INTERFACE_NAME}\n\n[Network]\n${addresses}Gateway=$SYSTEMD_NETWORKD_GATEWAY" > /etc/systemd/network/20-wired.network \
					|| die "Could not write dhcp network config to '/etc/systemd/network/20-wired.network'"
			fi
			chown root:systemd-network /etc/systemd/network/20-wired.network \
				|| die "Could not change owner of '/etc/systemd/network/20-wired.network'"
			chmod 640 /etc/systemd/network/20-wired.network \
				|| die "Could not change permissions of '/etc/systemd/network/20-wired.network'"
		fi
	else
		# Install and enable dhcpcd
		einfo "Installing dhcpcd"
		try_fatal emerge --verbose net-misc/dhcpcd

		enable_service dhcpcd
	fi

	if [[ $ENABLE_SSHD == "true" ]]; then
		enable_sshd
	fi

	# Install additional packages, if any.
	if [[ ${#ADDITIONAL_PACKAGES[@]} -gt 0 ]]; then
		einfo "Installing additional packages"
		try_fatal emerge --verbose --autounmask-continue=y -- "${ADDITIONAL_PACKAGES[@]}"
	fi

	create_configured_user

	if ask "Do you want to assign a root password now?"; then
		passwd root \
			|| die "Could not set root password"
		account_has_password root \
			|| die "Root password was not set"
		einfo "Root password assigned"
	else
		lock_root_account
		einfo "Root password login remains locked"
	fi

	# If configured, change to gentoo testing at the last moment.
	# This is to ensure a smooth installation process. You can deal
	# with the blockers after installation ;)
	if [[ $USE_PORTAGE_TESTING == "true" ]]; then
		einfo "Adding ~$GENTOO_ARCH to ACCEPT_KEYWORDS"
		echo "ACCEPT_KEYWORDS=\"~$GENTOO_ARCH\"" >> /etc/portage/make.conf \
			|| die "Could not modify /etc/portage/make.conf"
	fi

	maybe_exec 'after_install' \
		|| die "Hook after_install failed"
	ensure_safe_admin_access

	einfo "Gentoo installation complete."
	[[ -z ${INSTALL_LOG:-} ]] \
		|| einfo "The full output of this run was logged to '$INSTALL_LOG'"
	[[ $USED_LUKS == "true" ]] \
		&& einfo "LUKS header backups are stored at '$LUKS_HEADER_TARGET_DIR'. Keep an external copy for independent recovery."
	einfo "You may now reboot your system or execute ./install --chroot $ROOT_MOUNTPOINT to enter your system in a chroot."
	einfo "Chrooting in this way is always possible in case you need to fix something after rebooting."
}

function main_install() {
	[[ $# == 0 ]] || die "Too many arguments"

	gentoo_umount
	INSTALLER_OWNS_TARGET_MOUNTS=true
	install_stage3
	persist_luks_header_backups

	[[ $IS_EFI == "true" ]] \
		&& mount_efivars
	gentoo_chroot "$ROOT_MOUNTPOINT" \
		"$GENTOO_INSTALL_REPO_BIND/install" \
		--config "$GENTOO_INSTALL_REPO_BIND/$GENTOO_INSTALL_CONFIG_RELATIVE" \
		__install_gentoo_in_chroot
	return $?
}

function main_chroot() {
	# Skip if already mounted
	mountpoint -q -- "$1" \
		|| die "'$1' is not a mountpoint"

	local chroot_status
	gentoo_chroot "$@"
	chroot_status=$?
	return "$chroot_status"
}
