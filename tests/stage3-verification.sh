#!/bin/bash
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
export GENTOO_INSTALL_REPO_DIR="$REPO_DIR"
export GENTOO_INSTALL_REPO_SCRIPT_ACTIVE=true

function eerror() {
	echo "error: $*" >&2
}

# shellcheck source=../scripts/functions.sh
source "$REPO_DIR/scripts/functions.sh"

TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$TEST_DIR"' EXIT
cd "$TEST_DIR" || exit 1

# GnuPG must return only authenticated cleartext from a clearsigned document.
# In particular, bytes appended after the signature must never reach the
# checksum parser.
fixture_gpg_home="$TEST_DIR/gpg"
mkdir -m 0700 "$fixture_gpg_home" || exit 1
gpg --homedir "$fixture_gpg_home" \
	--batch \
	--pinentry-mode loopback \
	--passphrase '' \
	--quick-generate-key 'Stage3 Test <stage3-test@example.invalid>' ed25519 sign 1d \
	>/dev/null 2>&1 \
	|| { echo 'could not generate fixture signing key' >&2; exit 1; }
printf '# SHA512 HASH\nauthenticated payload\n' > signed-payload
gpg --homedir "$fixture_gpg_home" \
	--batch \
	--armor \
	--output clearsigned-digests \
	--clear-sign signed-payload \
	>/dev/null 2>&1 \
	|| { echo 'could not create clearsigned fixture' >&2; exit 1; }
printf '# SHA512 HASH\nunsigned trailing payload\n' >> clearsigned-digests
openpgp_status="$(
	extract_verified_openpgp_payload \
		"$fixture_gpg_home" \
		clearsigned-digests \
		extracted-payload
)" || { echo 'could not extract verified clearsigned payload' >&2; exit 1; }
cmp -s signed-payload extracted-payload \
	|| { echo 'unsigned trailing data reached the verified payload' >&2; exit 1; }
grep -q '^\[GNUPG:\] VALIDSIG ' <<< "$openpgp_status" \
	|| { echo 'fixture did not produce a valid-signature status' >&2; exit 1; }

archive='stage3-amd64-systemd-20990101T000000Z.tar.xz'
printf 'test stage3 payload\n' > "$archive"
sha512="$(sha512sum -- "$archive")"
sha512="${sha512%% *}"
blake2b='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

write_valid_digests() {
	cat > "$archive.DIGESTS" <<EOF
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

# SHA512 HASH
$sha512  $archive
# BLAKE2B HASH
$blake2b  $archive
# SHA512 HASH
$blake2b  $archive.CONTENTS.gz
-----BEGIN PGP SIGNATURE-----
EOF
}

write_valid_digests
verify_stage3_sha512 "$archive" "$archive.DIGESTS" \
	|| { echo 'mixed SHA512/BLAKE2B fixture should verify' >&2; exit 1; }

printf 'tampered payload\n' >> "$archive"
if verify_stage3_sha512 "$archive" "$archive.DIGESTS" 2>/dev/null; then
	echo 'tampered archive unexpectedly verified' >&2
	exit 1
fi

printf 'test stage3 payload\n' > "$archive"
write_valid_digests
sed -i "/$sha512/a $sha512  $archive" "$archive.DIGESTS"
if verify_stage3_sha512 "$archive" "$archive.DIGESTS" 2>/dev/null; then
	echo 'duplicate SHA512 entry unexpectedly verified' >&2
	exit 1
fi

write_valid_digests
sed -i "s/  $archive$/  other-stage3.tar.xz/" "$archive.DIGESTS"
if verify_stage3_sha512 "$archive" "$archive.DIGESTS" 2>/dev/null; then
	echo 'checksum for a different filename unexpectedly verified' >&2
	exit 1
fi

# Signed release metadata can still be replayed, so enforce the configured age
# and future-skew boundaries independently of signature validity.
MAX_STAGE3_AGE_DAYS=45
current_stamp="$(date -u +%Y%m%dT%H%M%SZ)" || exit 1
stale_stamp="$(date -u -d '46 days ago' +%Y%m%dT%H%M%SZ)" || exit 1
future_stamp="$(date -u -d '2 days' +%Y%m%dT%H%M%SZ)" || exit 1
validate_stage3_freshness "stage3-amd64-systemd-$current_stamp.tar.xz" \
	|| { echo 'current stage3 timestamp was rejected' >&2; exit 1; }
if validate_stage3_freshness "stage3-amd64-systemd-$stale_stamp.tar.xz" 2>/dev/null; then
	echo 'stale stage3 timestamp was accepted' >&2
	exit 1
fi
if validate_stage3_freshness "stage3-amd64-systemd-$future_stamp.tar.xz" 2>/dev/null; then
	echo 'far-future stage3 timestamp was accepted' >&2
	exit 1
fi
if validate_stage3_freshness 'stage3-amd64-systemd-no-date.tar.xz' 2>/dev/null; then
	echo 'malformed stage3 timestamp was accepted' >&2
	exit 1
fi

# Exercise the cache-marker path without network access.  The marker may skip
# downloading, but a modified archive must still fail and clear the marker.
cache_dir="$TEST_DIR/cache"
mkdir "$cache_dir" || exit 1
export TMP_DIR="$cache_dir"
GENTOO_ARCH='amd64'
GENTOO_SUBARCH=''
GENTOO_MIRROR='https://example.invalid/gentoo'
STAGE3_BASENAME='stage3-amd64-systemd'
STAGE3_VARIANT='systemd'
MAX_STAGE3_AGE_DAYS=0

function download_stdout() {
	echo "<a href=\"$archive\">$archive</a>"
}

function download() {
	local url="$1"
	local destination="$2"
	if [[ $url == *.DIGESTS ]]; then
		local downloaded_hash
		downloaded_hash="$(sha512sum -- "$archive")"
		downloaded_hash="${downloaded_hash%% *}"
		cat > "$destination" <<EOF
# SHA512 HASH
$downloaded_hash  $archive
# BLAKE2B HASH
$blake2b  $archive
EOF
	else
		printf 'cached stage3 payload\n' > "$destination"
	fi
}

function maybe_exec() { :; }
function einfo() { :; }
function verify_gentoo_release_signature() { cat -- "$1"; }
function touch_or_die() {
	local mode="$1"
	local path="$2"
	: > "$path" && chmod "$mode" "$path"
}
function die() {
	eerror "$*"
	exit 1
}

(download_stage3) || { echo 'initial cached-stage3 fixture failed' >&2; exit 1; }
marker="$cache_dir/$archive.verified"
[[ -e $marker ]] || { echo 'successful verification did not create a marker' >&2; exit 1; }
printf 'tampered after verification\n' >> "$cache_dir/$archive"
if (download_stage3) 2>/dev/null; then
	echo 'verification marker bypassed archive revalidation' >&2
	exit 1
fi
[[ ! -e $marker ]] || { echo 'failed revalidation left a stale marker' >&2; exit 1; }

echo 'stage3 checksum verification tests passed'
