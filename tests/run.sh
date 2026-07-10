#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

shopt -s nullglob
test_scripts=(tests/*.sh)
tests_run=0

for test_script in "${test_scripts[@]}"; do
	case "$(basename "$test_script")" in
		create-vm-gentoo.sh | run.sh | shellcheck.sh)
			continue
			;;
	esac

	printf '==> %s\n' "$test_script"
	bash "$test_script"
	((tests_run += 1))
done

((tests_run > 0)) || {
	echo 'No regression tests found.' >&2
	exit 1
}

printf 'Completed %d regression test(s).\n' "$tests_run"
