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

# ---------------------------------------------------------------------------
# Cross-language agreement: job locks
#
# util.FCC_LOCK_STALE_SECS / lock_dir() / job_running() are the same rule as
# FCC_LOCK_STALE_SECS / fcc_lock_dir() / fcc_lock_held() in common.sh: one for the
# page, which polls a job to decide whether to keep the progress bar moving, and
# one for the backend, which decides whether a job may start. A page that believed
# a different window from the backend would offer to start a job the backend
# refuses, or show a job as running an hour after it was killed; a page looking in
# a different directory would never see the job at all.
#
# The Lua side is asked through a nixio stub that consults the real filesystem,
# because the point is that the two implementations read the *same* lock: access()
# answers by trying, and stat("mtime") by running the same `date -r` that
# fcc_lock_age() runs. A stub that invented an answer could not show that.
# ---------------------------------------------------------------------------

# One question, in the same shape the backend asks it.
sh_lock() { # sh_lock '<code>'
	FCC_LIBDIR="$ROOT/root/usr/libexec/fcc" \
	FCC_AGENTS_CONF="$ROOT/root/usr/share/luci-app-fcc/agents.conf" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	sh -c '. "$1/common.sh"; eval "$2"' _ "$ROOT/root/usr/libexec/fcc" "$1" 2>&1
}

# The Lua side's answers about a lock of this name, one per line.
lock_probe() { # lock_probe <lockname>
	_ts_lp="$(mktemp)"
	cat > "$_ts_lp" <<'LUA'
local ROOT = assert(os.getenv("FCC_TEST_ROOT"))
table.insert(package.loaders, 1, function(name)
	local short = name:match("^luci%.fcc%.([a-z_]+)$")
	if not short then return nil end
	local fh = io.open(ROOT .. "/luasrc/fcc/" .. short .. ".lua", "r")
	if not fh then return nil end
	local src = fh:read("*a"); fh:close()
	return assert(loadstring(src, "@" .. short))
end)

local function exists(p)
	if type(p) ~= "string" or p == "" then return false end
	local f = io.open(p, "r")
	if f then f:close() return true end
	return os.rename(p, p) ~= nil
end

local function writable(p)
	local probe = p .. "/.fcc-lock-probe"
	local f = io.open(probe, "w")
	if not f then return nil end
	f:close(); os.remove(probe)
	return true
end

local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function mtime(p)
	local fh = io.popen("date -r " .. quote(p) .. " +%s 2>/dev/null")
	if not fh then return nil end
	local out = fh:read("*a") or ""
	fh:close()
	return tonumber(out:match("%d+"))
end

package.preload["nixio.fs"] = function()
	return {
		access = function(p, mode)
			if mode == "w" then return writable(p) end
			return exists(p) or nil
		end,
		stat = function(p, what)
			if what ~= "mtime" then return nil end
			return mtime(p)
		end,
	}
end

local util = require "luci.fcc.util"
print("dir=" .. tostring(util.lock_dir()))
print("window=" .. tostring(util.FCC_LOCK_STALE_SECS))
print("running=" .. tostring(util.job_running(os.getenv("FCC_PROBE_LOCK"))))
LUA
	FCC_TEST_ROOT="$ROOT" FCC_PROBE_LOCK="$1" "$LUA" "$_ts_lp"
	rm -f "$_ts_lp"
}

test_lock_rules_match_the_shell() {
	if [ -z "$LUA" ]; then
		skip "no Lua interpreter available"
		return
	fi

	_ts_dir="$(sh_lock 'fcc_lock_dir')"
	_ts_win="$(sh_lock 'printf "%s" "$FCC_LOCK_STALE_SECS"')"
	_ts_lock="$_ts_dir/fcc-luaprobe.lock"

	# Neither side has a lock, and both say so from the same two facts.
	_ts_out="$(lock_probe luaprobe)"
	assert_contains "$_ts_out" "dir=$_ts_dir" \
		"Lua and shell choose the same lock directory"
	assert_contains "$_ts_out" "window=$_ts_win" \
		"Lua and shell use the same staleness window"
	assert_contains "$_ts_out" "running=false" \
		"an absent lock is not running"

	# A lock taken now, made the way the backend makes one.
	mkdir -p "$_ts_lock"
	_ts_out="$(lock_probe luaprobe)"
	assert_contains "$_ts_out" "running=true" "a fresh lock reads as held"
	assert_ok "and the shell agrees it is held" sh_lock 'fcc_lock_held luaprobe'

	# The same lock, old enough that the acquirer would reclaim it. This is what
	# a router that rebooted mid-install leaves behind, and the two sides have to
	# agree about it in both directions: the page must stop showing the job as
	# running, and the backend must let the next job start.
	touch -t 202001010000 "$_ts_lock"
	_ts_out="$(lock_probe luaprobe)"
	assert_contains "$_ts_out" "running=false" "a stale lock is not running"
	assert_no "and the shell does not report it held" sh_lock 'fcc_lock_held luaprobe'
	assert_ok "and the next job may take it" sh_lock 'fcc_lock_acquire luaprobe'

	rm -rf "$_ts_lock"
}

# ---------------------------------------------------------------------------
# The controller's job wiring
#
# What is left in the controller once the rules live in luci.fcc.util is the
# order of three calls, and the order is the whole of it: the lock is asked
# before anything is spawned, the run's marker is written before the fork, and
# the log the page is shown is cut to the current run. Each is a line somebody
# can move, and moving any of them is silent — the job still runs and the page
# still draws, and the only thing that changes is what a person reads when it
# goes wrong. The rules themselves are exercised for real in the driver and in
# test_lock_rules_match_the_shell above; what is checked here is that they are
# called, and called in that order.
# ---------------------------------------------------------------------------

# The body of one controller function, parameter list and all. test_security.sh
# has a version of this for the no-argument guards; the job functions take
# arguments, so the match has to allow for them.
ctrl_function() {
	awk -v fn="$1" '
		$0 ~ "^(local )?function " fn "\\(" { inside = 1 }
		inside { print }
		inside && /^end$/ { exit }
	' "$ROOT/luasrc/controller/fcc.lua"
}

# The line number of the first line of a body matching a pattern, or nothing.
body_line() { # body_line <body> <pattern>
	printf '%s\n' "$1" | grep -n "$2" | head -1 | cut -d: -f1
}

test_controller_job_wiring() {
	_ts_start="$(ctrl_function start_job)"
	_ts_job="$(ctrl_function act_job)"

	assert_ne "" "$_ts_start" "start_job was found in the controller"
	assert_ne "" "$_ts_job" "act_job was found in the controller"

	_ts_n_lock="$(body_line "$_ts_start" 'util\.job_running')"
	_ts_n_mark="$(body_line "$_ts_start" 'write_job_marker')"
	_ts_n_spawn="$(body_line "$_ts_start" 'util\.spawn_detached')"

	assert_ne "" "$_ts_n_lock" "start_job asks whether a job is already running"
	assert_ne "" "$_ts_n_spawn" "start_job starts the job"

	# The refusal has to come first: asking after the fork is asking too late,
	# and it is the fork that produces the "no process id" report when the loser
	# of the race exits before its pid is read back.
	if [ -n "$_ts_n_lock" ] && [ -n "$_ts_n_spawn" ] && [ "$_ts_n_lock" -lt "$_ts_n_spawn" ]; then
		pass
	else
		fail "start_job checks the lock before it spawns anything"
	fi

	# And the marker before the fork, because the child shares nothing with this
	# process: written after spawn_detached() returns, it can land in the middle
	# of the run's own output, and the slice in act_job would then throw away the
	# start of the run it was written for.
	if [ -n "$_ts_n_mark" ] && [ -n "$_ts_n_spawn" ] && [ "$_ts_n_mark" -lt "$_ts_n_spawn" ]; then
		pass
	else
		fail "start_job marks the run before it spawns anything"
	fi

	# The same sentence the backend prints when fcc_lock_acquire loses, so the
	# page and the log do not describe one situation in two ways.
	assert_contains "$_ts_start" 'fail("another install/update is already running")' \
		"the refusal is worded as the backend words it"

	assert_contains "$_ts_job" "util.job_running(" \
		"act_job asks the same liveness question"
	assert_contains "$_ts_job" "util.current_run(" \
		"act_job reports the current run's lines only"

	# One rule, one place. The controller had its own copy of the lock directory
	# rule and its own marker constant before; a second copy is how the two sides
	# start disagreeing.
	assert_not_contains "$(cat "$ROOT/luasrc/controller/fcc.lua")" 'lockdir' \
		"the lock directory rule is not duplicated in the controller"
	assert_not_contains "$(cat "$ROOT/luasrc/controller/fcc.lua")" '===== fcc job start' \
		"the marker is not duplicated in the controller"
}

tests_main
