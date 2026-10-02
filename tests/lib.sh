#!/bin/sh
# luci-app-fcc — minimal POSIX test harness.
#
# Sourced by every tests/test_*.sh. Assertions *record* failures instead of
# aborting, so one run reports every problem rather than only the first.
#
# A test file looks like:
#
#     TESTS_NAME="shell"
#     ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
#     . "$(dirname -- "$0")/lib.sh"
#
#     test_something() { assert_eq a a "trivial"; }
#
#     tests_main
#
# Every variable in this file is prefixed `_t_`, for the same reason the backend
# scripts are: POSIX sh gives every function one shared global scope, so a bare
# `_case` here would clobber whatever the test file set.

TESTS_NAME="${TESTS_NAME:-$(basename "$0")}"

_t_self="$0"
_t_run=0
_t_fail=0
_t_skip=0
_t_case=""
_t_log=""

# --- recording --------------------------------------------------------------

pass() { _t_run=$((_t_run + 1)); }

fail() {
	_t_run=$((_t_run + 1))
	_t_fail=$((_t_fail + 1))
	printf '    FAIL  %s\n' "$1"
	_t_log="$_t_log
  $_t_case: $1"
}

skip() {
	_t_skip=$((_t_skip + 1))
	printf '    SKIP  %s\n' "$1"
}

# --- assertions -------------------------------------------------------------

assert_eq() { # assert_eq <expected> <actual> <what>
	if [ "$1" = "$2" ]; then pass; else fail "$3: expected [$1], got [$2]"; fi
}

assert_ne() { # assert_ne <not-expected> <actual> <what>
	if [ "$1" != "$2" ]; then pass; else fail "$3: expected anything but [$1]"; fi
}

assert_ok() { # assert_ok <what> <cmd> [args...]
	_ao_what="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass
	else
		fail "$_ao_what: '$*' should have succeeded"
	fi
}

assert_no() { # assert_no <what> <cmd> [args...]
	_an_what="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		fail "$_an_what: '$*' should have failed"
	else
		pass
	fi
}

assert_contains() { # assert_contains <haystack> <needle> <what>
	case "$1" in
		*"$2"*) pass ;;
		*) fail "$3: [$1] does not contain [$2]" ;;
	esac
}

assert_not_contains() { # assert_not_contains <haystack> <needle> <what>
	case "$1" in
		*"$2"*) fail "$3: [$1] unexpectedly contains [$2]" ;;
		*) pass ;;
	esac
}

assert_file() {
	if [ -f "$1" ]; then pass; else fail "missing file: $1"; fi
}

assert_dir() {
	if [ -d "$1" ]; then pass; else fail "missing directory: $1"; fi
}

assert_exec() {
	if [ -x "$1" ]; then pass; else fail "not executable: $1"; fi
}

# --- runner -----------------------------------------------------------------

tests_main() {
	_t_tests="$(grep -o '^test_[A-Za-z0-9_]*[[:space:]]*()' "$_t_self" 2>/dev/null \
		| sed -e 's/[[:space:]]*()$//' | LC_ALL=C sort -u)"
	if [ -z "$_t_tests" ]; then
		printf '%s: no test_* functions found in %s\n' "$TESTS_NAME" "$_t_self" >&2
		return 1
	fi

	printf '\n== %s ==\n' "$TESTS_NAME"
	for _t_fn in $_t_tests; do
		_t_case="$_t_fn"
		printf '  %s\n' "$_t_fn"
		"$_t_fn"
	done

	if [ "$_t_fail" -eq 0 ]; then
		printf '== %s: %d checks passed' "$TESTS_NAME" "$_t_run"
	else
		printf '== %s: %d checks, %d FAILED' "$TESTS_NAME" "$_t_run" "$_t_fail"
	fi
	if [ "$_t_skip" -gt 0 ]; then
		printf ', %d skipped' "$_t_skip"
	fi
	printf ' ==\n'

	if [ "$_t_fail" -gt 0 ]; then
		printf 'failed checks:%s\n' "$_t_log"
		return 1
	fi
	return 0
}
