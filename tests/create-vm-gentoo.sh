#!/bin/bash
set -euo pipefail

usage() {
	cat <<'EOF'
Create a Gentoo test VM with virt-install.

Usage:
  create-vm-gentoo.sh --iso PATH --disk PATH --name NAME [options]

Required values may also be provided through the environment:
  GENTOO_VM_ISO, GENTOO_VM_DISK, GENTOO_VM_NAME

Options:
  --iso PATH          Gentoo installation ISO
  --disk PATH         VM disk image (created by virt-install if absent)
  --name NAME         Libvirt domain name
  --vcpus COUNT       Virtual CPU count (default: GENTOO_VM_VCPUS or 2)
  --memory MIB        Memory in MiB (default: GENTOO_VM_MEMORY_MIB or 2048)
  --disk-size GIB     New disk size in GiB (default: GENTOO_VM_DISK_SIZE_GIB or 25)
  --connect URI       Libvirt URI (default: GENTOO_VM_CONNECT_URI or qemu:///system)
  --boot MODE         virt-install boot mode (default: GENTOO_VM_BOOT or uefi)
  --dry-run           Print the quoted virt-install command without running it
  -h, --help          Show this help
EOF
}

die() {
	echo "Error: $*" >&2
	exit 2
}

require_option_value() {
	local option="$1"
	local value="${2-}"
	[[ -n $value && $value != --* ]] || die "$option requires a value"
}

iso_path="${GENTOO_VM_ISO:-}"
disk_path="${GENTOO_VM_DISK:-}"
vm_name="${GENTOO_VM_NAME:-}"
vcpus="${GENTOO_VM_VCPUS:-2}"
memory_mib="${GENTOO_VM_MEMORY_MIB:-2048}"
disk_size_gib="${GENTOO_VM_DISK_SIZE_GIB:-25}"
connect_uri="${GENTOO_VM_CONNECT_URI:-qemu:///system}"
boot_mode="${GENTOO_VM_BOOT:-uefi}"
dry_run=false

while (($# > 0)); do
	case "$1" in
		--iso)
			require_option_value "$1" "${2-}"
			iso_path="$2"
			shift 2
			;;
		--disk)
			require_option_value "$1" "${2-}"
			disk_path="$2"
			shift 2
			;;
		--name)
			require_option_value "$1" "${2-}"
			vm_name="$2"
			shift 2
			;;
		--vcpus)
			require_option_value "$1" "${2-}"
			vcpus="$2"
			shift 2
			;;
		--memory)
			require_option_value "$1" "${2-}"
			memory_mib="$2"
			shift 2
			;;
		--disk-size)
			require_option_value "$1" "${2-}"
			disk_size_gib="$2"
			shift 2
			;;
		--connect)
			require_option_value "$1" "${2-}"
			connect_uri="$2"
			shift 2
			;;
		--boot)
			require_option_value "$1" "${2-}"
			boot_mode="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

[[ -n $iso_path ]] || die 'provide --iso or GENTOO_VM_ISO'
[[ -n $disk_path ]] || die 'provide --disk or GENTOO_VM_DISK'
[[ -n $vm_name ]] || die 'provide --name or GENTOO_VM_NAME'
[[ -r $iso_path && -f $iso_path ]] || die "ISO is not a readable file: $iso_path"
[[ $disk_path != *,* ]] || die 'disk paths containing commas are not supported by virt-install'
[[ ! -d $disk_path ]] || die "disk path is a directory: $disk_path"
[[ -d $(dirname "$disk_path") ]] || die "disk parent directory does not exist: $(dirname "$disk_path")"
[[ $vm_name =~ ^[A-Za-z0-9_.+-]+$ ]] || die 'name may contain only letters, numbers, dot, underscore, plus, and hyphen'
[[ $vcpus =~ ^[1-9][0-9]*$ ]] || die '--vcpus must be a positive integer'
[[ $memory_mib =~ ^[1-9][0-9]*$ ]] || die '--memory must be a positive integer'
[[ $disk_size_gib =~ ^[1-9][0-9]*$ ]] || die '--disk-size must be a positive integer'

virt_install=(
	virt-install
	--connect "$connect_uri"
	--name "$vm_name"
	--vcpus "$vcpus"
	--memory "$memory_mib"
	--cdrom "$iso_path"
	--disk "path=$disk_path,size=$disk_size_gib"
	--boot "$boot_mode"
	--os-variant gentoo
	--noautoconsole
)

if [[ $dry_run == true ]]; then
	printf '%q ' "${virt_install[@]}"
	printf '\n'
	exit 0
fi

command -v virt-install >/dev/null 2>&1 || die 'virt-install is not installed'
exec "${virt_install[@]}"
