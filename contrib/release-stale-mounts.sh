#!/bin/bash
# Unmounts leftover installer mounts that survive in other mount namespaces.
# A lazy unmount detaches them only locally, so copies which propagated into
# service namespaces keep the target filesystem open and its device busy.
# Usage: ./contrib/release-stale-mounts.sh [/tmp/gentoo-install]
set -uo pipefail

TARGET="${1:-/tmp/gentoo-install}"
command -v nsenter >/dev/null 2>&1 || { echo "nsenter is required" >&2; exit 1; }
[[ $EUID == 0 ]] || { echo "must be root" >&2; exit 1; }

declare -A seen=()
released=0

for mi in /proc/[0-9]*/mountinfo; do
	p="${mi#/proc/}"; p="${p%%/*}"
	ns="$(readlink -- "/proc/$p/ns/mnt" 2>/dev/null)" || continue
	[[ -v seen[$ns] ]] && continue
	seen[$ns]=true

	grep -q " $TARGET" "$mi" 2>/dev/null || continue
	echo "== pid $p [$ns] $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"

	# Deepest mount points first, so parents are free by the time they are unmounted
	while read -r mountpoint; do
		[[ -n $mountpoint ]] || continue
		if nsenter -t "$p" -m -- umount -R -- "$mountpoint" 2>/dev/null; then
			echo "   unmounted $mountpoint"
			released=1
		else
			echo "   FAILED to unmount $mountpoint"
		fi
	done < <(awk -v t="$TARGET" '$5 == t || index($5, t "/") == 1 { print length($5), $5 }' "$mi" \
		| sort -rn | cut -d' ' -f2- | awk '!seen[$0]++')
done

echo
if [[ $released == 1 ]]; then
	echo "Released stale mounts. Verify with:"
else
	echo "No stale installer mounts found. Verify the device with:"
fi
echo "  ./contrib/whoholds.sh /dev/DEVICE"
