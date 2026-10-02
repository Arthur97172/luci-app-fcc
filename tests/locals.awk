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

function check(name) {
	if (name ~ /^_[a-z0-9]{2,5}_/) return
	if (name ~ /^[A-Z][A-Z0-9_]*$/) return
	printf "%s: %s() assigns unprefixed '%s'\n", file, fn, name
}
