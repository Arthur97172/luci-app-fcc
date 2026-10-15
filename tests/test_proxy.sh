#!/bin/sh
# luci-app-fcc — the LuCI reverse proxy for the FCC Admin UI.
#
# "Open FCC Admin" used to send the browser to http://<router>:8082/admin and
# the server answered {"detail":"Admin UI is local-only"}. Upstream refuses
# every admin route unless the TCP peer is loopback, so no bind address can fix
# it — the page's old advice to bind the server to the router's LAN address was
# advice that could not work.
#
# The fix is a reverse proxy under LuCI (DESIGN_SPEC.md section 13, recorded as
# section 104.22): the request reaches the FCC server from the router itself, so
# the peer is loopback, and access stays behind LuCI's own authentication — a
# stronger gate than the loopback check it stands in for.
#
# The behaviour runs in tests/proxy_driver.lua against a stubbed LuCI, because
# what matters is what serve() hands to the HTTP client, which is not greppable.
# This file supplies the interpreter, reports the driver's results through the
# shared harness, and adds the packaging checks that need the tree.

TESTS_NAME="proxy"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

CTRL="$ROOT/luasrc/controller/fcc.lua"
MOD="$ROOT/luasrc/fcc/adminproxy.lua"
MAKEFILE="$ROOT/Makefile"
VIEW="$ROOT/luasrc/view/fcc/config.htm"

# Prefer 5.1, as tests/test_lua.sh does: it is what LuCI on OpenWrt runs.
LUA=""
for _tp_c in lua5.1 lua luajit; do
	if command -v "$_tp_c" >/dev/null 2>&1; then LUA="$_tp_c"; break; fi
done

_tp_out=""
_tp_rc=1

run_driver() {
	if [ -n "$_tp_out" ] || [ "$_tp_rc" -eq 0 ]; then return 0; fi
	if [ -z "$LUA" ]; then return 1; fi
	_tp_file="$(mktemp)"
	FCC_TEST_ROOT="$ROOT" \
	FCC_AGENTS_CONF="$ROOT/root/usr/share/luci-app-fcc/agents.conf" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	"$LUA" "$ROOT/tests/proxy_driver.lua" > "$_tp_file" 2>&1
	_tp_rc=$?
	_tp_out="$(cat "$_tp_file")"
	rm -f "$_tp_file"
	return 0
}

report_driver() {
	if [ -z "$LUA" ]; then
		skip "no Lua interpreter available"
		return
	fi
	run_driver
	_tp_f="$(mktemp)"
	printf '%s\n' "$_tp_out" > "$_tp_f"
	while IFS= read -r _tp_line; do
		case "$_tp_line" in
			'ok '*)   pass ;;
			'fail '*) fail "$(printf '%s' "${_tp_line#fail }" | tr '|' ':')" ;;
		esac
	done < "$_tp_f"
	rm -f "$_tp_f"
}

# ---------------------------------------------------------------------------

test_the_proxy_behaves() {
	report_driver
}

test_the_module_is_installed() {
	# The controller loads it with pcall(require, ...), so a module the manifest
	# forgot is not a 500 — it is a page that says the proxy is unavailable.
	# That is the right failure, and it is also one a packaging check should
	# never let through.
	assert_file "$MOD" "the proxy module is in the tree"
	assert_contains "$(cat "$MAKEFILE")" 'luci/fcc/adminproxy.lua' \
		"the manifest installs it under /usr/lib/lua/luci/fcc/"
}

test_the_module_compiles() {
	if [ -z "$LUA" ]; then
		skip "no Lua interpreter available"
		return
	fi
	"$LUA" -e "assert(loadfile('$MOD'))" >/dev/null 2>&1
	assert_eq "0" "$?" "the proxy module compiles"
}

test_the_route_is_behind_luci_auth() {
	# The route is inside the admin tree, so reaching it requires a LuCI session.
	# That is the point of proxying rather than listening on a LAN port: the FCC
	# admin API is not authenticated at all, so anything that reaches it directly
	# reaches all of it.
	assert_contains "$(cat "$CTRL")" 'entry({ "admin", "services", "fcc", "adminproxy" }' \
		"the proxy route is inside the admin tree"

	# And the module must never build an upstream from the configured bind. A
	# bind other than loopback is exactly the case this proxy exists for, and
	# reaching it would put the browser's problem back.
	assert_not_contains "$(cat "$MOD")" 'main", "bind"' \
		"the proxy never reads the bind address"
	assert_contains "$(cat "$MOD")" 'return "http://127.0.0.1:" .. port()' \
		"its upstream is loopback, always"
}

test_the_link_and_the_proxy_agree_on_the_route() {
	# The page's href and the module's ROUTE constant are two spellings of one
	# path. A drift between them is a link to a 404 that no other check notices,
	# because the route would still be registered — just somewhere else.
	#
	# The two spellings differ by the leading slash and only by it: url() takes
	# a path relative to the LuCI root, ROUTE is absolute because it is also
	# what the shim strips a request path against. Comparing them after that
	# slash is removed keeps the check about the route rather than about the
	# convention each side writes it in.
	_ts_route="$(grep -o 'ROUTE = "[^"]*"' "$MOD" | sed 's/^ROUTE = "\///; s/"$//')"
	assert_contains "$(cat "$VIEW")" "url(\"$_ts_route\")" \
		"the Admin link points at the path the module is mounted on"
	assert_contains "$(cat "$MOD")" "ROUTE = \"/$_ts_route\"" \
		"and that is the route the module declares"
}

test_the_shim_survives_a_double_application() {
	# The shim's url() maps a leading /admin to the base and passes anything else
	# through. That is what makes it safe to patch fetch, EventSource, pushState
	# and replaceState all at once — a URL already translated is left alone.
	# Stated here because the alternative (rewriting the SPA's literals) is the
	# change that looks equivalent and is not: the code-sessions module matches
	# the current path against /^\/admin\/code\/([0-9a-f-]+)$/ and compares it
	# with the literals it pushed, so half the file would be in one convention.
	assert_contains "$(cat "$MOD")" 'u.slice(0, 6) === "/admin" ? base + u.slice(6) : u' \
		"the shim's url() only rewrites a leading /admin"
	assert_contains "$(cat "$MOD")" 'window.__fccPath = function ()' \
		"and the current path is read back through a helper"
}

tests_main
