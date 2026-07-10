#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATOR="$REPO_DIR/configure"

expect_failure_containing() {
	local expected="$1"
	shift
	local output
	if output="$("$@" 2>&1)"; then
		echo "Command unexpectedly succeeded: $*" >&2
		exit 1
	fi
	[[ $output == *"$expected"* ]] \
		|| { echo "Failure did not contain '$expected': $output" >&2; exit 1; }
}

"$CONFIGURATOR" --help >/dev/null
expect_failure_containing "Invalid option '--unknown'" "$CONFIGURATOR" --unknown
expect_failure_containing 'Only one configuration path may be specified' \
	"$CONFIGURATOR" one.conf two.conf

echo 'configurator CLI validation tests passed'
