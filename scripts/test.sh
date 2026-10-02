#!/bin/sh
# luci-app-fcc — run the whole check suite.
#
# Two layers, both required:
#
#   package-check.sh   is the package buildable? (manifest, syntax, deps)
#   tests/test_*.sh    is it correct, and does it still obey the spec?
#
# Every test file is a standalone POSIX sh script that reports its own counts
# and exits non-zero on failure, so this runner only has to collect results.
#
# Usage: scripts/test.sh [-q] [name ...]
#   -q        quiet: pass the flag through to package-check and print only
#             per-file summaries
#   name ...  run only the named suites (e.g. `scripts/test.sh lua shell`)

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
cd "$ROOT" || exit 1

QUIET=0
if [ "${1:-}" = "-q" ]; then QUIET=1; shift; fi

WANT="$*"

# Select the test files: every tests/test_*.sh, minus any the caller excluded.
selected=""
for f in tests/test_*.sh; do
	[ -f "$f" ] || continue
	name=$(basename "$f" .sh)
	name=${name#test_}
	if [ -n "$WANT" ]; then
		case " $WANT " in
			*" $name "*) : ;;
			*) continue ;;
		esac
	fi
	selected="$selected $f"
done

if [ -z "$selected" ]; then
	printf 'no test suites selected (wanted: %s)\n' "$WANT" >&2
	exit 1
fi

# --- package check ----------------------------------------------------------

printf '== package-check ==\n'
if [ "$QUIET" = 1 ]; then
	sh scripts/package-check.sh -q
else
	sh scripts/package-check.sh
fi
pkg_rc=$?
if [ "$pkg_rc" -ne 0 ]; then
	printf '== package-check FAILED ==\n'
fi

# --- test suites ------------------------------------------------------------

suites=0
failed=0
failed_names=""

for f in $selected; do
	suites=$((suites + 1))
	if [ "$QUIET" = 1 ]; then
		# Keep the summary line and any failure detail, drop the per-test noise.
		out=$(sh "$f" 2>&1)
		rc=$?
		printf '%s\n' "$out" | grep -E '^(==|    (FAIL|SKIP)|failed checks:|  [a-z_]+:)' || true
	else
		sh "$f"
		rc=$?
	fi
	if [ "$rc" -ne 0 ]; then
		failed=$((failed + 1))
		failed_names="$failed_names $(basename "$f")"
	fi
done

# --- summary ----------------------------------------------------------------

printf '\n=============================\n'
if [ "$pkg_rc" -eq 0 ] && [ "$failed" -eq 0 ]; then
	printf 'ALL PASS — package-check + %d suites\n' "$suites"
	exit 0
fi

[ "$pkg_rc" -ne 0 ] && printf 'package-check: FAILED\n'
[ "$failed" -gt 0 ] && printf '%d of %d suites FAILED:%s\n' "$failed" "$suites" "$failed_names"
exit 1
