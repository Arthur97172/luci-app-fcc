#!/bin/sh
# luci-app-fcc — Lua module checks.
#
# The module logic runs in tests/lua_driver.lua (it needs a Lua interpreter and
# a few LuCI stubs). This file supplies the interpreter, reports the driver's
# per-check results through the shared harness, and adds the cross-language
# checks that need both sides: the Lua validators and the shell backend must
# agree about what an acceptable install path is.

TESTS_NAME="lua"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

# Prefer 5.1: it is what LuCI on OpenWrt runs, and it is where `module()` and
# `loadstring` behave the way the code assumes.
LUA=""
for _tl_c in lua5.1 lua luajit; do
	if command -v "$_tl_c" >/dev/null 2>&1; then LUA="$_tl_c"; break; fi
done

# Run the driver once and cache its output, so every test_* below reads the
# same run instead of re-executing it.
_tl_out=""
_tl_rc=1

run_driver() {
	if [ -n "$_tl_out" ] || [ "$_tl_rc" -eq 0 ]; then return 0; fi
	if [ -z "$LUA" ]; then return 1; fi
	_tl_file="$(mktemp)"
	# paths.lua resolves the registry and the VERSION file from the environment
	# first, which is how a development tree is exercised without installing
	# into /usr.
	FCC_TEST_ROOT="$ROOT" \
	FCC_AGENTS_CONF="$ROOT/root/usr/share/luci-app-fcc/agents.conf" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	"$LUA" "$ROOT/tests/lua_driver.lua" > "$_tl_file" 2>&1
	_tl_rc=$?
	_tl_out="$(cat "$_tl_file")"
	rm -f "$_tl_file"
	return 0
}

# Feed each `ok`/`fail` line from the driver into the harness. Reading from a
# file rather than a pipe keeps the loop in this shell, so the counters the
# harness keeps are not lost in a subshell.
report_driver() {
	if [ -z "$LUA" ]; then
		skip "no Lua interpreter available"
		return
	fi
	run_driver
	_tl_f="$(mktemp)"
	printf '%s\n' "$_tl_out" > "$_tl_f"
	while IFS= read -r _tl_line; do
		case "$_tl_line" in
			'ok '*)   pass ;;
			'fail '*) fail "$(printf '%s' "${_tl_line#fail }" | tr '|' ':')" ;;
		esac
	done < "$_tl_f"
	rm -f "$_tl_f"
}

# ---------------------------------------------------------------------------

test_syntax() {
	_ts_bad=""
	for _ts_f in "$ROOT"/luasrc/controller/*.lua "$ROOT"/luasrc/fcc/*.lua; do
		if [ -n "$LUA" ]; then
			"$LUA" -e "assert(loadfile('$_ts_f'))" >/dev/null 2>&1 \
				|| _ts_bad="$_ts_bad $(basename "$_ts_f")"
		fi
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every Lua module compiles"
}

test_modules_load() {
	report_driver
}

test_driver_reported_every_check() {
	if [ -z "$LUA" ]; then
		skip "no Lua interpreter available"
		return
	fi
	run_driver
	# The driver's own total must match the number of ok/fail lines it printed.
	# A check that silently never ran — because an error stopped the file
	# part-way — is worse than one that failed, and this is what catches it.
	_ts_reported="$(printf '%s\n' "$_tl_out" | grep -cE '^(ok|fail) ')"
	_ts_total="$(printf '%s\n' "$_tl_out" | sed -n 's/^RESULT \([0-9]*\) [0-9]*$/\1/p')"
	assert_ne "" "$_ts_total" "the driver reached the end and printed a RESULT line"
	assert_eq "$_ts_reported" "$_ts_total" "ok+fail lines equal the driver's total"
}

test_driver_ran_on_lua51() {
	if [ -z "$LUA" ]; then
		skip "no Lua interpreter available"
		return
	fi
	run_driver
	# Guard against the driver dying early (a missing stub, a syntax error):
	# if it did, every check would be missing rather than failing.
	_ts_ok="$(printf '%s\n' "$_tl_out" | grep -c '^ok ')"
	if [ "$_ts_ok" -gt 100 ]; then pass; else fail "driver produced only $_ts_ok passing checks"; fi
}

# ---------------------------------------------------------------------------
# Cross-language agreement
#
# util.valid_install_path() and fcc_canon_base() implement the same rule twice:
# once for the UI, once for the shell that actually creates and execs from the
# path. If they ever disagree, the UI would accept a path the backend rejects
# (or worse, the reverse).
# ---------------------------------------------------------------------------

test_install_path_parity() {
	if [ -z "$LUA" ]; then
		skip "no Lua interpreter available"
		return
	fi

	_ts_probe="$(mktemp)"
	cat > "$_ts_probe" <<'LUA'
local ROOT = assert(os.getenv("FCC_TEST_ROOT"))
table.insert(package.loaders, 1, function(name)
	local short = name:match("^luci%.fcc%.([a-z_]+)$")
	if not short then return nil end
	local fh = io.open(ROOT .. "/luasrc/fcc/" .. short .. ".lua", "r")
	if not fh then return nil end
	local src = fh:read("*a"); fh:close()
	return assert(loadstring(src, "@" .. short))
end)
package.preload["nixio.fs"] = function()
	return { access = function(p) local f = io.open(p, "r"); if f then f:close() return true end return os.rename(p,p) ~= nil or nil end }
end
local util = require "luci.fcc.util"
for line in io.lines() do
	if line ~= "" then
		io.write((util.valid_install_path(line) and "accept") or "reject", "\n")
	end
end
LUA

	_ts_paths='/
/etc
/etc/fcc
/usr
/usr/lib
/tmp/fcc
/opt
/opt/fcc
/mnt/sda1
/opt/../etc
/opt;id
/opt`id`
/opt/$(id)
/opt/*
relative/path
/home/user
/srv/fcc
/var/lib/fcc
'

	_ts_lua="$(printf '%s' "$_ts_paths" | FCC_TEST_ROOT="$ROOT" "$LUA" "$_ts_probe")"
	rm -f "$_ts_probe"

	# The same inputs through the shell implementation. fcc_canon_base is the
	# function that actually gates the path the backend will use.
	_ts_sh="$(printf '%s' "$_ts_paths" | while IFS= read -r _ts_p; do
		[ -n "$_ts_p" ] || continue
		if FCC_AGENTS_CONF="$ROOT/root/usr/share/luci-app-fcc/agents.conf" \
		   FCC_LIBDIR="$ROOT/root/usr/libexec/fcc" \
		   sh -c '. "$1/common.sh"; fcc_canon_base "$2" >/dev/null 2>&1' _ \
		      "$ROOT/root/usr/libexec/fcc" "$_ts_p"; then
			printf 'accept\n'
		else
			printf 'reject\n'
		fi
	done)"

	assert_eq "$_ts_sh" "$_ts_lua" "Lua and shell agree on every install path"
}

test_agent_registry_parity() {
	# The Lua parser and the shell parser read the same file. If they ever
	# disagree about the agent list, the UI and the backend would act on
	# different registries.
	if [ -z "$LUA" ]; then
		skip "no Lua interpreter available"
		return
	fi
	_ts_sh_ids="$(FCC_AGENTS_CONF="$ROOT/root/usr/share/luci-app-fcc/agents.conf" \
		sh -c '. "$1/common.sh"; fcc_agents_each | cut -d"|" -f1 | tr "\n" ","' _ \
		"$ROOT/root/usr/libexec/fcc" | sed 's/,$//')"
	assert_eq "claude,codex,pi,opencode,cline,hermes,dsh,grok,muse,aider" \
		"$_ts_sh_ids" "the shell reads the registry the Lua tests assert on"
}

tests_main
