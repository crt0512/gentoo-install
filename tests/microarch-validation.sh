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

# A realistic flags line of a cpu which supports x86-64-v3
V3_FLAGS="fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr \
sse sse2 ht syscall nx pdpe1gb rdtscp lm constant_tsc rep_good nopl xtopology cpuid pni pclmulqdq \
ssse3 fma cx16 sse4_1 sse4_2 movbe popcnt aes xsave avx f16c rdrand lahf_lm abm bmi1 avx2 bmi2 erms \
invpcid rdseed adx clflushopt xsaveopt"
V2_FLAGS="fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr \
sse sse2 ht syscall nx lm constant_tsc pni ssse3 cx16 sse4_1 sse4_2 popcnt lahf_lm xsave"

cpu_flags_support_x86_64_v3 "$V3_FLAGS" \
	|| fail 'a x86-64-v3 capable cpu was not recognized'
cpu_flags_support_x86_64_v3 "$V2_FLAGS" \
	&& fail 'a x86-64-v2 only cpu was accepted as v3'

# Missing any single required feature must disqualify the whole level
for feature in avx2 bmi1 bmi2 fma f16c movbe abm xsave cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3; do
	if cpu_flags_support_x86_64_v3 "${V3_FLAGS/ $feature/}"; then
		fail "a cpu without '$feature' was accepted as x86-64-v3"
	fi
done

GENTOO_ARCH=amd64

# auto follows the detection result
cpu_supports_x86_64_v3() { return 0; }
CPU_MICROARCH=auto
[[ "$(resolve_cpu_microarch)" == "x86-64-v3" ]] \
	|| fail 'auto did not select x86-64-v3 on a capable cpu'

cpu_supports_x86_64_v3() { return 1; }
[[ "$(resolve_cpu_microarch)" == "x86-64" ]] \
	|| fail 'auto did not fall back to the baseline level'

# An explicit level is always honoured, whatever the cpu reports
CPU_MICROARCH=x86-64-v3
[[ "$(resolve_cpu_microarch)" == "x86-64-v3" ]] \
	|| fail 'an explicit x86-64-v3 was not honoured'

cpu_supports_x86_64_v3() { return 0; }
CPU_MICROARCH=x86-64
[[ "$(resolve_cpu_microarch)" == "x86-64" ]] \
	|| fail 'an explicit baseline level was not honoured'

# Only amd64 has microarchitecture levels
GENTOO_ARCH=x86
CPU_MICROARCH=auto
[[ "$(resolve_cpu_microarch)" == "x86-64" ]] \
	|| fail 'auto selected a microarchitecture level on a non-amd64 arch'

echo 'microarch tests passed'
