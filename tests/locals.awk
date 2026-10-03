# luci-app-fcc — check the per-function-prefixed-local contract.
#
# POSIX sh gives every function ONE global scope. A helper that assigns a bare
# `_name` clobbers its caller's `_name`, and a helper that `unset`s it makes a
# caller running under `set -u` die with "parameter not set". Every local in
# this package therefore carries its function's tag: `_ug_v` in fcc_uci_get,
# `_la_lock` in fcc_lock_acquire, `_ou_off` in cmd_output.
#
# This checks the mechanical part of that rule: each variable a function
# assigns must be either
#
#   * prefixed with an `_xxx_` tag, or
#   * ALL_CAPS (a constant, an exported global, or a documented global).
#
# It is a heuristic. It reads simple assignments and for-loop variables, not
# every construct sh allows — `read -r a b` targets and `$(...)` side effects
# are invisible to it. But it catches exactly the mistake the contract exists to
# prevent, which is a hand-written `_name=` inside a helper.
#
# Usage: awk -v file=<path> -f tests/locals.awk <path>

# A function header: name at column 0, optionally with () and a brace.
/^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/ {
	fn = $0
	sub(/[[:space:]]*\(\).*/, "", fn)
	next
}

# A closing brace at column 0 ends the function. Everything after it is
# top-level, where unprefixed names are legitimate (ROOT=..., FCC_HZ=...).
/^\}/ { fn = ""; next }

fn == "" { next }

# Simple assignment at the start of a line.
/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {
	name = $0
	sub(/^[[:space:]]*/, "", name)
	sub(/=.*/, "", name)
	check(name)
	next
}

# for-loop variable: `for x in ...` and `for x; do`.
/^[[:space:]]*for[[:space:]]+[A-Za-z_]/ {
	name = $0
	sub(/^[[:space:]]*for[[:space:]]+/, "", name)
	sub(/[[:space:];].*/, "", name)
	check(name)
	next
}

function check(name,   tag, rest) {
	# An `_tag_` prefix, tag being 2-5 lower-case alphanumerics. Spelled out
	# rather than written as /^_[a-z0-9]{2,5}_/ on purpose: mawk, which is the
	# awk Debian and Ubuntu install as /usr/bin/awk, does not implement interval
	# expressions. It reads the braces literally, the pattern then matches
	# nothing, and every correctly-prefixed local in the package is reported as
	# a violation. gawk accepts the braces, which is why this only shows up on a
	# machine that has no gawk — including a stock Ubuntu container.
	if (name ~ /^_[a-z0-9]/) {
		rest = substr(name, 2)
		tag = rest
		sub(/_.*/, "", tag)
		# tag != rest means there was a second underscore to strip, so the
		# name really is `_tag_something` and not a bare `_name`.
		if (tag != rest && length(tag) >= 2 && length(tag) <= 5 \
		    && tag ~ /^[a-z0-9]+$/) return
	}
	if (name ~ /^[A-Z][A-Z0-9_]*$/) return
	printf "%s: %s() assigns unprefixed '%s'\n", file, fn, name
}
