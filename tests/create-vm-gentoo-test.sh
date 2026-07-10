#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VM_HELPER="$REPO_DIR/tests/create-vm-gentoo.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

iso_path="$TEST_DIR/gentoo install.iso"
disk_path="$TEST_DIR/gentoo test.qcow2"
: > "$iso_path"

output="$("$VM_HELPER" \
	--iso "$iso_path" \
	--disk "$disk_path" \
	--name gentoo-ci \
	--vcpus 4 \
	--memory 4096 \
	--dry-run)"

[[ $output == *'--name gentoo-ci'* ]] || {
	echo 'VM name was not included in the generated command.' >&2
	exit 1
}
[[ $output == *'--vcpus 4'* && $output == *'--memory 4096'* ]] || {
	echo 'VM resource arguments were not included in the generated command.' >&2
	exit 1
}
[[ ! -e $disk_path ]] || {
	echo 'Dry-run mode unexpectedly created the VM disk.' >&2
	exit 1
}

env_output="$(
	GENTOO_VM_ISO="$iso_path" \
		GENTOO_VM_DISK="$TEST_DIR/env.qcow2" \
		GENTOO_VM_NAME=gentoo-env \
		"$VM_HELPER" --dry-run
)"
[[ $env_output == *'--name gentoo-env'* ]] || {
	echo 'Environment-based VM configuration was not applied.' >&2
	exit 1
}

if "$VM_HELPER" --dry-run >/dev/null 2>&1; then
	echo 'VM helper accepted missing required inputs.' >&2
	exit 1
fi

if "$VM_HELPER" \
	--iso "$iso_path" \
	--disk "$disk_path" \
	--name gentoo-ci \
	--vcpus 0 \
	--dry-run >/dev/null 2>&1; then
	echo 'VM helper accepted an invalid vCPU count.' >&2
	exit 1
fi

echo 'VM helper argument tests passed'
