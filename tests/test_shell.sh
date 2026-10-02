#!/bin/sh
# luci-app-fcc — static checks over every shell script in the package.
#
# These run on the development host, not on the router. The router-side
# behaviour of the backend is exercised by tests/test_runtime.sh.
#
# bashism-scan: ignore
#   The portability checks below have to spell their needles out literally,
#   which makes this file match itself. It is excluded from its own scans —
#   it is host-side test code and never runs on the router anyway.

TESTS_NAME="shell"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Every file in the tree whose first line is a sh shebang. This is how the
# package's executable scripts are identified: root/etc/init.d/fcc,
# root/usr/bin/fcc-env and root/etc/uci-defaults/99-fcc have no .sh extension.
shell_files() {
	find "$ROOT/root" "$ROOT/scripts" "$ROOT/tests" -type f 2>/dev/null \
		| LC_ALL=C sort \
		| while IFS= read -r _sh_f; do
			head -n1 "$_sh_f" 2>/dev/null | grep -q '^#!.*sh' && printf '%s\n' "$_sh_f"
		done
}

# The subset that must obey the prefixed-locals contract: everything except the
# test harness itself, which is host-side and never sourced by the backend.
backend_files() {
	shell_files | grep -v '/tests/'
}

# Files the bashism scans may look at. This file is excluded because it has to
# spell the needles out literally, which makes it match itself — see the
# "bashism-scan: ignore" marker below.
bashism_scan_files() {
	shell_files | while IFS= read -r _bs_f; do
		grep -q 'bashism-scan: ignore' "$_bs_f" || printf '%s\n' "$_bs_f"
	done
}

rel() { printf '%s' "$1" | sed "s#^$ROOT/##"; }

# Full-line comments stripped, for checks that grep for things a comment may
# legitimately mention (e.g. a note explaining why 0.0.0.0 is *not* used).
without_comments() {
	grep -v '^[[:space:]]*#' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Shebangs
# ---------------------------------------------------------------------------

test_shebangs_are_posix() {
	_ts_bad=""
	for _ts_f in $(shell_files); do
		_ts_line="$(head -n1 "$_ts_f")"
		case "$_ts_line" in
			'#!/bin/sh'|'#!/bin/sh /etc/rc.common') : ;;
			*) _ts_bad="$_ts_bad $(rel "$_ts_f")[$_ts_line]" ;;
		esac
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every script uses a /bin/sh shebang"
}

# ---------------------------------------------------------------------------
# Syntax
# ---------------------------------------------------------------------------

test_parses_with_dash() {
	_ts_bad=""
	for _ts_f in $(shell_files); do
		dash -n "$_ts_f" 2>/dev/null || _ts_bad="$_ts_bad $(rel "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every script parses under dash -n"
}

test_parses_with_busybox_ash() {
	# busybox ash is what actually runs on OpenWrt; dash is the closest thing a
	# development host has. Checking both catches dialect drift in either
	# direction.
	if ! command -v busybox >/dev/null 2>&1; then
		skip "busybox not available"
		return
	fi
	_ts_bad=""
	for _ts_f in $(shell_files); do
		busybox ash -n "$_ts_f" 2>/dev/null || _ts_bad="$_ts_bad $(rel "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every script parses under busybox ash -n"
}

# ---------------------------------------------------------------------------
# Portability
#
# The package targets busybox ash (OpenWrt's /bin/sh). bash is not installed on
# a stock router, so a bashism is a runtime failure, not a style question.
# ---------------------------------------------------------------------------

test_no_double_bracket_conditionals() {
	# Build the needle from parts so this file does not match itself.
	_ts_needle='['
	_ts_needle="${_ts_needle}["
	_ts_bad=""
	for _ts_f in $(bashism_scan_files); do
		# Strip POSIX character classes first: `[[:space:]]` is not a
		# conditional, and it is used heavily in the sed/grep/awk expressions.
		if sed -e 's/\[\[:[a-z]*:\]\]//g' "$_ts_f" | grep -qF "$_ts_needle"; then
			_ts_bad="$_ts_bad $(rel "$_ts_f")"
		fi
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "no [[ conditionals"
}

test_no_bash_function_keyword() {
	_ts_bad=""
	for _ts_f in $(shell_files); do
		grep -q '^[[:space:]]*function[[:space:]]' "$_ts_f" && _ts_bad="$_ts_bad $(rel "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "no 'function' keyword"
}

test_no_local_keyword() {
	# The contract is deliberately not `local`: `local` is not POSIX, busybox
	# ash's version has surprising scoping, and the prefixed-global rule keeps
	# the same discipline across every script.
	_ts_bad=""
	for _ts_f in $(backend_files); do
		grep -q '^[[:space:]]*local[[:space:]]' "$_ts_f" && _ts_bad="$_ts_bad $(rel "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "no 'local' keyword in backend scripts"
}

test_no_equals_in_test_brackets() {
	# `[ "$a" == "$b" ]` works in bash and is a silent string-vs-pattern trap in
	# ash. POSIX is `=`.
	_ts_bad=""
	for _ts_f in $(bashism_scan_files); do
		grep -qE '\[[^]]*[[:space:]]==[[:space:]]' "$_ts_f" && _ts_bad="$_ts_bad $(rel "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "no '==' inside [ ]"
}

# ---------------------------------------------------------------------------
# The prefixed-locals contract
# ---------------------------------------------------------------------------

test_locals_are_prefixed() {
	_ts_out=""
	for _ts_f in $(backend_files); do
		_ts_hits="$(awk -v file="$(rel "$_ts_f")" -f "$ROOT/tests/locals.awk" "$_ts_f")"
		if [ -n "$_ts_hits" ]; then
			_ts_out="$_ts_out
$_ts_hits"
		fi
	done
	assert_eq "" "$(printf '%s' "$_ts_out" | sed '/^$/d')" "every backend local carries its function prefix"
}

test_contract_is_documented() {
	# The rule is only enforceable if the next person to edit these files knows
	# about it, so common.sh must keep saying so.
	assert_contains "$(cat "$ROOT/root/usr/libexec/fcc/common.sh")" \
		"ONE global scope" "common.sh documents the shared-scope contract"
}

# ---------------------------------------------------------------------------
# Backend structure
# ---------------------------------------------------------------------------

test_backend_scripts_are_strict() {
	# `set -u` is what turns a mistyped variable into a loud failure instead of
	# an empty string silently becoming an argument.
	#
	# common.sh is the exception: it is *sourced*, so setting -u there would
	# change the shell options of whatever sourced it.
	_ts_bad=""
	for _ts_f in "$ROOT"/root/usr/libexec/fcc/*.sh; do
		[ "$(basename "$_ts_f")" = "common.sh" ] && continue
		grep -q '^set -u' "$_ts_f" || _ts_bad="$_ts_bad $(basename "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every executed backend script sets -u"
}

test_common_is_sourceable() {
	# The mirror of the rule above: common.sh must NOT set -u, or sourcing it
	# would silently tighten a caller that did not ask for it.
	assert_eq "0" "$(grep -c '^set -' "$ROOT/root/usr/libexec/fcc/common.sh")" \
		"common.sh sets no shell options"
}

test_backend_scripts_source_common() {
	_ts_bad=""
	for _ts_f in "$ROOT"/root/usr/libexec/fcc/*.sh; do
		[ "$(basename "$_ts_f")" = "common.sh" ] && continue
		grep -q 'FCC_LIBDIR:-/usr/libexec/fcc}/common.sh' "$_ts_f" \
			|| _ts_bad="$_ts_bad $(basename "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every backend script sources common.sh via FCC_LIBDIR"
}

test_backend_scripts_read_arguments() {
	# Every backend script is driven from the controller, so each one has to
	# look at $1. Multi-command scripts dispatch with `case "${1:-}" in`;
	# single-purpose ones (status.sh, doctor.sh) just test a flag. Both read it
	# as ${1:-}, which is what makes them safe under `set -u`.
	_ts_bad=""
	for _ts_f in "$ROOT"/root/usr/libexec/fcc/*.sh; do
		[ "$(basename "$_ts_f")" = "common.sh" ] && continue
		grep -q '\${1:-}' "$_ts_f" || _ts_bad="$_ts_bad $(basename "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every backend script reads \${1:-}"
}

test_multi_command_scripts_dispatch() {
	_ts_bad=""
	for _ts_f in agent session install update; do
		grep -q '^case "\${1:-}" in' "$ROOT/root/usr/libexec/fcc/$_ts_f.sh" \
			|| _ts_bad="$_ts_bad $_ts_f.sh"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "multi-command scripts dispatch on \$1"
}

test_backend_scripts_are_executable() {
	_ts_bad=""
	for _ts_f in "$ROOT"/root/usr/libexec/fcc/*.sh "$ROOT"/root/usr/bin/fcc-env \
	            "$ROOT"/root/etc/init.d/fcc "$ROOT"/root/etc/uci-defaults/99-fcc; do
		[ -x "$_ts_f" ] || _ts_bad="$_ts_bad $(rel "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every installed script is executable"
}

# ---------------------------------------------------------------------------
# Section 87 prohibitions that are visible in the shell layer
# ---------------------------------------------------------------------------

test_no_shell_string_execution() {
	# Section 30: arguments are passed as an explicit argv, never concatenated
	# into a command string. `eval` and `sh -c "$var"` are the two ways that
	# rule gets broken.
	_ts_bad=""
	for _ts_f in $(backend_files); do
		grep -nE '^[^#]*\beval\b' "$_ts_f" | grep -v 'eval-able' >/dev/null 2>&1 \
			&& _ts_bad="$_ts_bad $(rel "$_ts_f"):eval"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "no eval in the backend"
}

test_no_pipe_to_shell() {
	# Section 40: the installer is downloaded to a file, hashed, then executed.
	# It is never piped into a shell.
	_ts_bad=""
	for _ts_f in $(backend_files); do
		# Comments are stripped first: install.sh's header explains the rule by
		# naming the thing it forbids.
		without_comments "$_ts_f" | grep -qE '\|[[:space:]]*(sh|ash|bash)([[:space:]]|$)' \
			&& _ts_bad="$_ts_bad $(rel "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "nothing is piped into a shell"
}

test_no_wan_bind_default() {
	# Section 87: 8082 must never be exposed on the WAN. The shipped default is
	# loopback, and the init script pins it.
	assert_contains "$(cat "$ROOT/root/etc/config/fcc")" "option bind '127.0.0.1'" \
		"the shipped bind default is loopback"
	_ts_hits="$(grep -rn "0\.0\.0\.0" "$ROOT/root" "$ROOT/luasrc" "$ROOT/htdocs" 2>/dev/null \
		| grep -v '127\.0\.0\.1' | grep -v ':[[:space:]]*#' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')"
	assert_eq "" "$_ts_hits" "0.0.0.0 appears in no bind address and no code"
}

tests_main
