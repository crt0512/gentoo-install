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

expect_equal() {
	[[ $2 == "$3" ]] \
		|| fail "$1: expected '$3' but got '$2'"
}

# A real 'sgdisk --print' table for a classic single disk layout (1GiB efi, 8GiB swap, rest root)
TABLE="$(cat <<'EOF'
Disk /dev/sda: 234441648 sectors, 111.8 GiB
Model: QEMU HARDDISK
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 0F84A9F2-1CE0-4B62-9F86-8E2D3B2F1A44
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 234441614
Partitions will be aligned on 2048-sector boundaries
Total free space is 2669 sectors (1.3 MiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048         2099199   1024.0 MiB  EF00  EFI system partition
   2         2099200        18876415   8.0 GiB     8200  Linux swap
   3        18876416       234441614   102.8 GiB   8300  Linux filesystem
EOF
)"
SECTOR_SIZE=512
LAST_USABLE=234441614

# The configured partition types must map to the codes sgdisk reports
expect_equal 'efi type code' "$(gpt_type_code_for_type efi)" ef00
expect_equal 'bios type code' "$(gpt_type_code_for_type bios)" ef02
expect_equal 'swap type code' "$(gpt_type_code_for_type swap)" 8200
expect_equal 'raid type code' "$(gpt_type_code_for_type raid)" fd00
expect_equal 'luks type code' "$(gpt_type_code_for_type luks)" 8309
expect_equal 'linux type code' "$(gpt_type_code_for_type linux)" 8300

expect_equal '8GiB in bytes' "$(gdisk_size_to_bytes 8GiB "$SECTOR_SIZE")" 8589934592
expect_equal '512MiB in bytes' "$(gdisk_size_to_bytes 512MiB "$SECTOR_SIZE")" 536870912
expect_equal '4G in bytes' "$(gdisk_size_to_bytes 4G "$SECTOR_SIZE")" 4294967296
expect_equal 'plain number is a sector count' "$(gdisk_size_to_bytes 2048 "$SECTOR_SIZE")" 1048576
gdisk_size_to_bytes remaining "$SECTOR_SIZE" >/dev/null 2>&1 \
	&& fail "'remaining' was accepted as a size"
gdisk_size_to_bytes '' "$SECTOR_SIZE" >/dev/null 2>&1 \
	&& fail 'an empty size was accepted'

expect_equal 'partition count' "$(gpt_partition_count "$TABLE")" 3
expect_equal 'first partition row' "$(gpt_partition_row "$TABLE" 1)" '2048 2099199 EF00'
expect_equal 'third partition row' "$(gpt_partition_row "$TABLE" 3)" '18876416 234441614 8300'
gpt_partition_row "$TABLE" 4 >/dev/null 2>&1 \
	&& fail 'a nonexistent partition was reported'

matches() {
	gpt_partition_matches "$TABLE" "$SECTOR_SIZE" "$LAST_USABLE" "$@"
}

matches 1 efi 1GiB \
	|| fail 'the configured efi partition was not recognized'
matches 2 swap 8GiB \
	|| fail 'the configured swap partition was not recognized'
matches 3 linux remaining \
	|| fail 'the configured root partition was not recognized'

# A layout which differs in type or size must never be reused
matches 1 linux 1GiB \
	&& fail 'a partition with a different type was accepted'
matches 2 swap 4GiB \
	&& fail 'a partition with a different size was accepted'
matches 1 efi remaining \
	&& fail "a partition which is not the last one was accepted for size=remaining"

# Actions are only skipped once the corresponding reuse was confirmed
REUSE_EXISTING_PARTITIONS=false
KEEP_EXISTING_FILESYSTEMS=false
disk_action_is_skipped create_gpt \
	&& fail 'partitioning was skipped without confirmation'
disk_action_is_skipped format \
	&& fail 'formatting was skipped without confirmation'

REUSE_EXISTING_PARTITIONS=true
disk_action_is_skipped create_gpt \
	|| fail 'the gpt was recreated although the partitions are reused'
disk_action_is_skipped create_partition \
	|| fail 'partitions were recreated although the partitions are reused'
disk_action_is_skipped format \
	&& fail 'formatting was skipped although only the partitions are reused'

KEEP_EXISTING_FILESYSTEMS=true
disk_action_is_skipped format \
	|| fail 'a filesystem was recreated although the filesystems are kept'
disk_action_is_skipped format_btrfs \
	|| fail 'a btrfs filesystem was recreated although the filesystems are kept'
disk_action_is_skipped create_luks \
	&& fail 'luks creation must never be skipped'

echo 'partition detection tests passed'
