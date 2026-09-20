#!/bin/bash
# Reports what still claims a block device, run it as: ./contrib/whoholds.sh /dev/nvme0n1p3
D="${1:?usage: whoholds.sh /dev/DEVICE}"
R="$(realpath -e -- "$D")" || exit 1
N="${R##*/}"

echo "=== device ==="
lsblk -o NAME,MAJ:MIN,FSTYPE,LABEL,MOUNTPOINTS "$R"
echo "=== mounts ==="
grep -F -- "$N" /proc/mounts || echo "(none)"
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
echo "=== btrfs ==="
btrfs filesystem show 2>&1
echo "--- forget ---"
btrfs device scan --forget "$R" 2>&1; echo "forget exit: $?"
echo "=== exclusive open probe ==="
if dd if=/dev/null of="$R" count=0 conv=nocreat,notrunc oflag=excl 2>&1; then
	echo "RESULT: device is FREE"
else
	echo "RESULT: device is BUSY"
fi
