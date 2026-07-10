#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_DIR/install"
OUTSIDE_CONFIG="$(mktemp)"
trap 'rm -f -- "$OUTSIDE_CONFIG"' EXIT

expect_failure_containing() {
	local expected="$1"
	shift
	local output

	if output="$("$@" 2>&1)"; then
		echo "Command unexpectedly succeeded: $*" >&2
		exit 1
	fi
	[[ $output == *"$expected"* ]] || {
		echo "Failure did not contain expected text: $expected" >&2
		echo "$output" >&2
		exit 1
	}
}

expect_failure_containing \
	"Missing argument for '--config'" \
	"$INSTALLER" --config

expect_failure_containing \
	'Configuration file must be inside the installation directory' \
	"$INSTALLER" --config "$OUTSIDE_CONFIG" --install

expect_failure_containing \
	'Internal installation action may only run inside the installer chroot' \
	"$INSTALLER" __install_gentoo_in_chroot
expect_failure_containing \
	'Internal installation action may only run inside the installer chroot' \
	env EXECUTED_IN_CHROOT=true "$INSTALLER" __install_gentoo_in_chroot

expect_failure_containing \
	'Refusing to use the live system root as a chroot target' \
	"$INSTALLER" --chroot /

# This reaches the privilege gate, proving that a valid repo-relative --config
# path survived canonicalization and the in-repository containment check.
nonroot_prefix=()
if [[ $EUID -eq 0 ]]; then
	command -v setpriv >/dev/null 2>&1 \
		|| { echo 'setpriv is required to run this test suite as root.' >&2; exit 1; }
	nonroot_prefix=(setpriv --reuid=65534 --regid=65534 --clear-groups)
fi
expect_failure_containing \
	'Must be root' \
	"${nonroot_prefix[@]}" "$INSTALLER" --config gentoo.conf --install

echo 'installer CLI validation tests passed'
