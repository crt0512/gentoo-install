#!/bin/bash
# Reports what still claims a block device, run it as: ./contrib/whoholds.sh /dev/nvme0n1p3
D="${1:?usage: whoholds.sh /dev/DEVICE}"
R="$(realpath -e -- "$D")" || exit 1
N="${R##*/}"
MM="$(lsblk --nodeps --noheadings --output MAJ:MIN -- "$R" | tr -d '[:space:]')"
MAJ="${MM%%:*}"
MIN="${MM##*:}"
# st_dev as stat reports it, so a file can be matched against this partition
DEVNUM=$(( (MAJ << 8) | (MIN & 255) | ((MIN & ~255) << 12) ))

echo "=== device ==="
lsblk -o NAME,MAJ:MIN,FSTYPE,LABEL,MOUNTPOINTS "$R"
echo "device number: $MM"

# btrfs reports an anonymous device number for its mounts, so match the source path too
echo "=== mounts of $MM or $R in every mount namespace ==="
found=0
declare -A seen=()
for mi in /proc/[0-9]*/mountinfo; do
	grep -qE " $MM | $R | $D " "$mi" 2>/dev/null || continue
	p="${mi#/proc/}"; p="${p%%/*}"
	ns="$(readlink -- "/proc/$p/ns/mnt" 2>/dev/null)" || ns="unknown"
	[[ -v seen[$ns] ]] && continue
	seen[$ns]=true
	found=1
	echo "pid $p [$ns] $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
	grep -E " $MM | $R | $D " "$mi" | sed 's/^/    /'
done
[[ $found == 1 ]] || echo "(none)"

echo "=== swaps ==="
grep -F -- "$N" /proc/swaps || echo "(none)"
echo "=== stacked devices (dm/md) ==="
ls -1 "/sys/class/block/$N/holders/" 2>/dev/null || echo "(none)"

echo "=== processes holding it open ==="
found=0
for f in /proc/[0-9]*/fd/*; do
	t="$(readlink -- "$f" 2>/dev/null)" || continue
	[[ $t == "$R" || $t == "$D" ]] || continue
	p="${f#/proc/}"; p="${p%%/*}"
	echo "pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
	found=1
done
[[ $found == 1 ]] || echo "(none)"

# A lazy unmount detaches the tree but keeps the superblock alive while anything still references it
echo "=== processes with a cwd, root or open file on device $MM ==="
found=0
for p in /proc/[0-9]*; do
	pid="${p#/proc/}"
	hit=""
	for link in cwd root exe; do
		t="$(stat -c '%d' -L "$p/$link" 2>/dev/null)" || continue
		[[ $t == "$DEVNUM" ]] && hit="$hit $link"
	done
	for f in "$p"/fd/*; do
		t="$(stat -c '%d' -L "$f" 2>/dev/null)" || continue
		[[ $t == "$DEVNUM" ]] && { hit="$hit fd:${f##*/}"; break; }
	done
	[[ -n $hit ]] || continue
	echo "pid $pid ($(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)) ->$hit"
	found=1
done
[[ $found == 1 ]] || echo "(none)"

# A detached mount stays alive while any child mount inside it does, and those children are tmpfs, not this device
echo "=== mounts under the installer tmp dir in every namespace ==="
found=0
declare -A seen_ns=()
for mi in /proc/[0-9]*/mountinfo; do
	p="${mi#/proc/}"; p="${p%%/*}"
	ns="$(readlink -- "/proc/$p/ns/mnt" 2>/dev/null)" || continue
	[[ -v seen_ns[$ns] ]] && continue
	seen_ns[$ns]=true
	hits="$(grep -E -- "${TMPDIR_PATTERN:-gentoo-install}" "$mi" 2>/dev/null)" || continue
	[[ -n $hits ]] || continue
	echo "pid $p [$ns] $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
	sed 's/^/    /' <<< "$hits"
	found=1
done
[[ $found == 1 ]] || echo "(none)"

echo "=== mount count per namespace (a leftover shows up as a different count) ==="
declare -A counted=()
for mi in /proc/[0-9]*/mountinfo; do
	p="${mi#/proc/}"; p="${p%%/*}"
	ns="$(readlink -- "/proc/$p/ns/mnt" 2>/dev/null)" || continue
	[[ -v counted[$ns] ]] && continue
	counted[$ns]=true
	printf '%s pid %-7s %4s mounts  %s\n' "$ns" "$p" "$(wc -l < "$mi")" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-60)"
done

echo "=== mount namespaces on this system ==="
command -v lsns >/dev/null 2>&1 && lsns -t mnt || echo "(lsns not available)"

echo "=== btrfs ==="
btrfs filesystem show 2>&1
echo "--- forget ---"
btrfs device scan --forget "$R" 2>&1; echo "forget exit: $?"

echo "=== exclusive open probe ==="
if python3 -c 'import os, sys; os.close(os.open(sys.argv[1], os.O_WRONLY | os.O_EXCL))' "$R" 2>&1; then
	echo "RESULT: device is FREE"
else
	echo "RESULT: device is BUSY (something holds it exclusively)"
fi
