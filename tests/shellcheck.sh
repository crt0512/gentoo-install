#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# `install` sources the implementation modules, so --check-sourced checks the
# entrypoint and all maintained files below scripts/ as one program. These
# exclusions record existing cross-file/style debt without hiding new warning
# classes from CI.
shellcheck \
	--shell=bash \
	--check-sourced \
	--external-sources \
	--exclude=SC2004,SC2034,SC2155 \
	install configure

# This script is executed as a separate program inside the chroot. /etc/profile
# is intentionally supplied by the installed system rather than this repository.
shellcheck \
	--shell=bash \
	--exclude=SC1091,SC2155 \
	scripts/dispatch_chroot.sh

# Test source directives are relative to tests/, so lint from that directory.
# The glob ensures newly added shell tests are included automatically.
(
	cd tests
	shopt -s nullglob
	test_scripts=(*.sh)
	((${#test_scripts[@]} > 0)) || {
		echo 'No shell test files found.' >&2
		exit 1
	}
	shellcheck --shell=bash --external-sources "${test_scripts[@]}"
)
