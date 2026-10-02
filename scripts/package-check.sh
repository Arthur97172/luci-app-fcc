#!/bin/sh
# luci-app-fcc — static package check.
#
# Everything here is a check a build would otherwise discover late, or not at
# all: a manifest that names a file that moved, JSON that does not parse, a
# shell script busybox cannot read, a dependency that drags a language runtime
# onto the router. None of it needs a cross-compiler, an OpenWrt tree or root,
# so it runs on any development machine and in CI.
#
# This is deliberately independent of tests/: those verify behaviour and policy
# against the specification, this verifies the package is *buildable*. It shares
# no code with them so a mistake in one does not hide a problem from the other.
#
# Usage: scripts/package-check.sh [-q]
#   -q   only print failures

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
cd "$ROOT" || exit 1

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

n_pass=0
n_fail=0
n_skip=0

ok()   { n_pass=$((n_pass + 1)); [ "$QUIET" = 1 ] || printf '  ok    %s\n' "$1"; }
bad()  { n_fail=$((n_fail + 1)); printf '  FAIL  %s\n' "$1"; }
note() { n_skip=$((n_skip + 1)); [ "$QUIET" = 1 ] || printf '  skip  %s\n' "$1"; }
sect() { [ "$QUIET" = 1 ] || printf '\n%s\n' "$1"; }

# Run a command, record ok/bad against a description.
check() { # check <description> <cmd...>
	# Prefixed like every other local in the tree: scripts/ is covered by the
	# same naming contract as the backend (tests/test_shell.sh enforces it).
	_ck_desc="$1"; shift
	if "$@" >/dev/null 2>&1; then ok "$_ck_desc"; else bad "$_ck_desc"; fi
}

# ---------------------------------------------------------------------------
sect "Version"
# ---------------------------------------------------------------------------

if [ -f VERSION ]; then
	v_file=$(tr -d ' \t\r\n' < VERSION)
	case "$v_file" in
		[0-9]*.[0-9]*.[0-9]*) ok "VERSION is a dotted version ($v_file)" ;;
		*) bad "VERSION is not a dotted version: [$v_file]" ;;
	esac
	# The Makefile carries a fallback for the case where VERSION is missing from
	# a tarball; if the two disagree, an out-of-tree build reports a version the
	# source does not.
	if grep -q "echo $v_file)" Makefile; then
		ok "the Makefile fallback matches VERSION"
	else
		bad "the Makefile fallback does not match VERSION ($v_file)"
	fi
else
	bad "VERSION is missing"
fi

# ---------------------------------------------------------------------------
sect "Install manifest"
# ---------------------------------------------------------------------------

manifest_sources=$(sed -n '/^define Package\/luci-app-fcc\/install$/,/^endef$/p' Makefile \
	| grep -v '^[[:space:]]*#' | grep -o '\./[^ 	]*' | sed 's#^\./##' | LC_ALL=C sort -u)

missing=""
for f in $manifest_sources; do
	[ -e "$f" ] || missing="$missing $f"
done
[ -z "$missing" ] && ok "every manifest source exists" \
	|| bad "manifest names missing files:$missing"

unlisted=""
for f in $(find root htdocs luasrc -type f 2>/dev/null | LC_ALL=C sort); do
	case " $(printf '%s' "$manifest_sources" | tr '\n' ' ') " in
		*" $f "*) : ;;
		*) unlisted="$unlisted $f" ;;
	esac
done
[ -z "$unlisted" ] && ok "every shipped file is in the manifest" \
	|| bad "files in the tree but not in the manifest:$unlisted"

# luasrc/ maps onto /usr/lib/lua/luci/, so the destination has to mirror the
# module path or require() fails at runtime with no build-time symptom.
luabad=""
for f in luasrc/fcc/*.lua; do
	[ -f "$f" ] || continue
	grep -q "\./$f \$(1)/usr/lib/lua/luci/fcc/$(basename "$f")" Makefile || luabad="$luabad $f"
done
[ -z "$luabad" ] && ok "Lua module destinations mirror the module path" \
	|| bad "Lua modules installed to the wrong path:$luabad"

# ---------------------------------------------------------------------------
sect "Dependencies"
# ---------------------------------------------------------------------------

depends=$(sed -n '/^define Package\/luci-app-fcc$/,/^endef$/p' Makefile \
	| sed -n 's/^[[:space:]]*DEPENDS:=//p')

[ -n "$depends" ] && ok "the app package declares DEPENDS" || bad "the app package has no DEPENDS"

forbidden=""
for d in node nodejs npm python python3 uv ruby php perl java go rust; do
	case "$depends" in
		*"$d"*) forbidden="$forbidden $d" ;;
	esac
done
[ -z "$forbidden" ] && ok "DEPENDS pulls in no language runtime" \
	|| bad "DEPENDS pulls in a runtime:$forbidden"

for d in luci-base luci-compat curl ca-bundle tar tmux; do
	case "$depends" in
		*"+$d"*) : ;;
		*) bad "DEPENDS is missing +$d" ;;
	esac
done
case "$depends" in
	*"+tmux"*) ok "tmux, which the Web Console requires, is declared" ;;
esac

# ---------------------------------------------------------------------------
sect "Shell syntax"
# ---------------------------------------------------------------------------

# POSIX sh, because these run under busybox ash on the router. dash is the
# closest thing to ash generally available on a development machine; busybox
# itself is used when present.
shell_files=$(find root -type f 2>/dev/null | while IFS= read -r f; do
	head -n1 "$f" 2>/dev/null | grep -q '^#!.*\bsh\b' && printf '%s\n' "$f"
done)

if [ -z "$shell_files" ]; then
	bad "no shell scripts found under root/"
else
	shbad=""
	for f in $shell_files; do
		dash -n "$f" 2>/dev/null || shbad="$shbad $f(dash)"
		if command -v busybox >/dev/null 2>&1; then
			busybox ash -n "$f" 2>/dev/null || shbad="$shbad $f(ash)"
		fi
	done
	[ -z "$shbad" ] && ok "all $(printf '%s\n' "$shell_files" | wc -l | tr -d ' ') shell scripts parse under dash and busybox ash" \
		|| bad "shell syntax errors:$shbad"
fi

# ---------------------------------------------------------------------------
sect "Lua syntax"
# ---------------------------------------------------------------------------

lua_bin=""
for c in luac lua5.1 lua5.3 lua; do
	if command -v "$c" >/dev/null 2>&1; then lua_bin="$c"; break; fi
done

if [ -z "$lua_bin" ]; then
	note "no Lua interpreter available — syntax not checked"
else
	luabad=""
	for f in luasrc/controller/fcc.lua luasrc/fcc/*.lua; do
		[ -f "$f" ] || continue
		case "$lua_bin" in
			luac*) luac -p "$f" 2>/dev/null || luabad="$luabad $f" ;;
			*)     "$lua_bin" -e "assert(loadfile('$f'))" 2>/dev/null || luabad="$luabad $f" ;;
		esac
	done
	[ -z "$luabad" ] && ok "all Lua files parse under $lua_bin" \
		|| bad "Lua syntax errors:$luabad"
fi

# ---------------------------------------------------------------------------
sect "JSON"
# ---------------------------------------------------------------------------

json_files=$(find root htdocs luasrc -name '*.json' -type f 2>/dev/null)
if [ -z "$json_files" ]; then
	bad "no JSON files found (the ACL is missing?)"
elif command -v python3 >/dev/null 2>&1; then
	jsonbad=""
	for f in $json_files; do
		python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null \
			|| jsonbad="$jsonbad $f"
	done
	[ -z "$jsonbad" ] && ok "every JSON file parses" || bad "invalid JSON:$jsonbad"
elif command -v jq >/dev/null 2>&1; then
	jsonbad=""
	for f in $json_files; do jq empty "$f" >/dev/null 2>&1 || jsonbad="$jsonbad $f"; done
	[ -z "$jsonbad" ] && ok "every JSON file parses" || bad "invalid JSON:$jsonbad"
else
	note "no JSON parser available — JSON not checked"
fi

# ---------------------------------------------------------------------------
sect "Executables"
# ---------------------------------------------------------------------------

execbad=""
for f in $(find root -type f -perm -u+x 2>/dev/null); do
	head -n1 "$f" | grep -q '^#!' || execbad="$execbad $f(no shebang)"
done
[ -z "$execbad" ] && ok "every executable under root/ has a shebang" \
	|| bad "executables without a shebang:$execbad"

modebad=""
for f in root/etc/init.d/fcc root/usr/bin/fcc-env root/usr/libexec/fcc/*.sh \
         root/etc/uci-defaults/99-fcc; do
	[ -e "$f" ] || continue
	[ -x "$f" ] || modebad="$modebad $f"
done
[ -z "$modebad" ] && ok "every script that is exec'd is executable" \
	|| bad "not executable:$modebad"

# ---------------------------------------------------------------------------
sect "Translation"
# ---------------------------------------------------------------------------

if [ -f po/templates/fcc.pot ] && [ -f po/zh_Hans/fcc.po ]; then
	if sh scripts/gen-po.sh --check >/dev/null 2>&1; then
		ok "the translation template is up to date"
	else
		bad "po/templates/fcc.pot is stale — run scripts/gen-po.sh"
	fi
else
	bad "a translation catalogue is missing"
fi

# ---------------------------------------------------------------------------
sect "Summary"
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed, %d skipped\n' "$n_pass" "$n_fail" "$n_skip"
[ "$n_fail" -eq 0 ] || exit 1
exit 0
