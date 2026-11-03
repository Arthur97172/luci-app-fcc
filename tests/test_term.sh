#!/bin/sh
# luci-app-fcc — the Web Console's fast transport (root/www/cgi-bin/fcc-term).
#
# The console's two hot requests — one per keystroke and the long-poll that
# carries the pane's echo — are served by this CGI instead of the LuCI
# dispatcher. It is the one file in the package that takes user input *outside*
# LuCI's own request pipeline, so its guards are tested here rather than
# assumed: session-cookie authentication through ubus, the access group, the
# CSRF header, the origin, the session-name grammar, and POST for anything that
# types.
#
# The CGI runs under a real Lua interpreter with luci.fcc.util and
# luci.fcc.paths loaded from the working tree, and fake `ubus`/`tmux` programs
# on the two environment overrides the backend already uses for this. Nothing
# here needs a router, root, or a cross-compiler.

TESTS_NAME="term"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

CGI="$ROOT/root/www/cgi-bin/fcc-term"
COMMON="$ROOT/htdocs/luci-static/resources/fcc/fcc-common.js"
TERMINAL="$ROOT/htdocs/luci-static/resources/fcc/fcc-terminal.js"
POPOUT="$ROOT/htdocs/luci-static/resources/fcc/fcc-popout.js"

# 5.1 first: it is what LuCI on OpenWrt runs, and it is where io.popen's
# close() returns the exit status the CGI reads.
LUA=""
for _tt_c in lua5.1 lua luajit; do
	if command -v "$_tt_c" >/dev/null 2>&1; then LUA="$_tt_c"; break; fi
done

_t_sand=""

# ---------------------------------------------------------------------------
# Sandbox: fake ubus and tmux, one session, one agent registry.
# ---------------------------------------------------------------------------

setup() {
	[ -n "$_t_sand" ] && return 0
	_t_sand="$(mktemp -d)"
	trap 'rm -rf "$_t_sand"' EXIT INT TERM
	mkdir -p "$_t_sand/bin" "$_t_sand/sessions" "$_t_sand/state"

	cat > "$_t_sand/bin/ubus" <<'UBUS'
#!/bin/sh
# Fake ubus: whose answer is controlled by the environment.
[ "${FCC_TEST_AUTH:-live}" = "dead" ] && exit 1
# An id of all f's is the one this fake does not know, so a test can hand the
# CGI a dead id under one cookie and a live one under another.
case "$4" in *ffffffff*) exit 1 ;; esac
case "$3" in
	get)    printf '{"token":"0123456789abcdef","username":"root"}\n' ;;
	access)
		case "${FCC_TEST_ACL:-root}" in
			root)  printf '{"access-group":{"root":["read","write"]}}\n' ;;
			fcc)   printf '{"access-group":{"luci-app-fcc":["read"]}}\n' ;;
			other) printf '{"access-group":{"luci-app-other":["read"]}}\n' ;;
			none)  printf '{"access-group":{}}\n' ;;
			*)     printf '{}\n' ;;
		esac ;;
	*) exit 1 ;;
esac
UBUS

	cat > "$_t_sand/bin/tmux" <<'TMUX'
#!/bin/sh
# Fake tmux: one session, its scrollback written by the test, its input logged.
cmd="$1"; shift
case "$cmd" in
	has-session)
		[ -f "${FCC_TEST_STATE}/alive" ] ;;
	send-keys)
		seen=0; hex=""
		for a in "$@"; do
			case "$a" in
				-H) seen=1 ;;
				-t) : ;;
				*) [ "$seen" = 1 ] && hex="$hex$a" ;;
			esac
		done
		printf '%s\n' "$hex" >> "${FCC_TEST_STATE}/sent" ;;
	display-message)
		printf '%s' "${FCC_TEST_PANE:-80x24x0x}" ;;
	*) exit 1 ;;
esac
TMUX

	chmod +x "$_t_sand/bin/ubus" "$_t_sand/bin/tmux"

	# Two agents is enough to tell "known" from "unknown".
	printf 'dsh|DeepSeek Harness|fcc-dsh|1|130|180|dsh\nclaude|Claude Code|fcc-claude|1|140|180|claude\n' \
		> "$_t_sand/agents.conf"

	: > "$_t_sand/sessions/fcc-dsh-001.out"
	printf '0' > "$_t_sand/sessions/fcc-dsh-001.base"
	: > "$_t_sand/state/alive"

	# The modules, exactly as the working tree has them, with the two nixio
	# functions this CGI uses. nanosleep really sleeps, so the long-poll test
	# measures the loop rather than a spin.
	cat > "$_t_sand/probe.lua" <<'LUA'
local ROOT = assert(os.getenv("FCC_TEST_ROOT"))
table.insert(package.loaders, 1, function(name)
	local short = name:match("^luci%.fcc%.([a-z_]+)$")
	if not short then return nil end
	local fh = io.open(ROOT .. "/luasrc/fcc/" .. short .. ".lua", "r")
	if not fh then return nil end
	local src = fh:read("*a"); fh:close()
	return assert(loadstring(src, "@" .. short))
end)
package.preload["nixio"] = function()
	return {
		nanosleep = function(sec, nsec)
			os.execute(string.format("sleep %.3f", sec + nsec / 1000000000))
		end
	}
end
package.preload["nixio.fs"] = function()
	return {
		access = function(p)
			local fh = io.open(p, "rb")
			if fh then fh:close(); return true end
			return nil
		end,
		stat = function(p)
			local fh = io.open(p, "rb")
			if not fh then return nil end
			local size = fh:seek("end"); fh:close()
			return { size = size, type = "reg" }
		end
	}
end
local chunk = assert(loadfile(ROOT .. "/root/www/cgi-bin/fcc-term"))
chunk()
LUA
}

# ---------------------------------------------------------------------------
# Driving the CGI
# ---------------------------------------------------------------------------

# Per-request knobs, reset by t_reset. Keeping them as shell variables rather
# than arguments keeps the assertions readable.
t_reset() {
	setup
	# One fresh, empty session per test: the sandbox is shared, and a test that
	# leaves a base offset or a big scrollback behind would decide another's
	# answer.
	: > "$_t_sand/sessions/fcc-dsh-001.out"
	printf '0' > "$_t_sand/sessions/fcc-dsh-001.base"
	: > "$_t_sand/state/alive"
	_tt_qs=""
	_tt_method="GET"
	_tt_auth="live"
	_tt_acl="root"
	_tt_origin=""
	_tt_referer=""
	_tt_host="192.168.10.1"
	_tt_cookie="sysauth_https=0123456789abcdef0123456789abcdef"
	_tt_pane="80x24x0x"
}

term_run() { # term_run [request body]
	setup
	_tt_body="${1-}"
	: > "$_t_sand/state/sent"
	printf '%s' "$_tt_body" | env \
		FCC_TEST_ROOT="$ROOT" \
		FCC_UBUS="$_t_sand/bin/ubus" \
		FCC_TMUX="$_t_sand/bin/tmux" \
		FCC_AGENTS_CONF="$_t_sand/agents.conf" \
		FCC_SESSIONS_DIR="$_t_sand/sessions" \
		FCC_TEST_STATE="$_t_sand/state" \
		FCC_TEST_AUTH="$_tt_auth" \
		FCC_TEST_ACL="$_tt_acl" \
		FCC_TEST_PANE="$_tt_pane" \
		QUERY_STRING="$_tt_qs" \
		REQUEST_METHOD="$_tt_method" \
		CONTENT_LENGTH="${#_tt_body}" \
		HTTP_COOKIE="$_tt_cookie" \
		HTTP_ORIGIN="$_tt_origin" \
		HTTP_REFERER="$_tt_referer" \
		HTTP_HOST="$_tt_host" \
		"$LUA" "$_t_sand/probe.lua" > "$_t_sand/resp" 2>"$_t_sand/err"
}

status_of() { sed -n '1p' "$_t_sand/resp" | tr -d '\r'; }

# Everything after the blank line that ends the headers, with CRs removed.
body() {
	tr -d '\r' < "$_t_sand/resp" | sed -n '/^$/,$p' | sed '1d'
}

assert_status() { # assert_status <expected> <what>
	assert_eq "Status: $1" "$(status_of)" "$2"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

test_output_returns_the_stream() {
	t_reset
	setup
	printf 'hello' > "$_t_sand/sessions/fcc-dsh-001.out"
	_tt_qs="action=output&name=fcc-dsh-001&offset=0&wait=0"
	term_run
	assert_status "200 OK" "a poll with a live session answers 200"
	_tt_b="$(body)"
	assert_contains "$_tt_b" '"offset":5' "the answer reports the stream end"
	assert_contains "$_tt_b" '"reset":false' "nothing was trimmed away"
	assert_contains "$_tt_b" '"alive":true' "the pane is alive"
	assert_contains "$_tt_b" '"eof":false' "the stream has not ended"
	assert_contains "$_tt_b" '"data":"aGVsbG8="' "the bytes arrive base64-encoded"
	assert_contains "$(cat "$_t_sand/resp")" "Content-Type: application/json" \
		"the answer says it is JSON"
	assert_contains "$(cat "$_t_sand/resp")" "Cache-Control: no-store" \
		"a terminal stream is never cached"
}

test_output_resumes_from_offset() {
	t_reset
	setup
	printf 'abcdef' > "$_t_sand/sessions/fcc-dsh-001.out"
	_tt_qs="action=output&name=fcc-dsh-001&offset=3&wait=0"
	term_run
	assert_status "200 OK" "an offset inside the stream still answers 200"
	assert_contains "$(body)" '"data":"ZGVm"' "only the bytes past the offset are sent"
	assert_contains "$(body)" '"offset":6' "the answer reports the new end"
}

test_output_reports_a_trimmed_stream() {
	t_reset
	setup
	# The base moved past the caller's offset: bytes it never saw are gone, and
	# the page has to repaint rather than silently skip them.
	printf 'abc' > "$_t_sand/sessions/fcc-dsh-001.out"
	printf '100' > "$_t_sand/sessions/fcc-dsh-001.base"
	_tt_qs="action=output&name=fcc-dsh-001&offset=40&wait=0"
	term_run
	assert_status "200 OK" "a trimmed stream still answers 200"
	assert_contains "$(body)" '"reset":true' "the page is told to repaint"
	assert_contains "$(body)" '"offset":103' "the offset is the new end"
}

test_output_waits_for_new_bytes() {
	t_reset
	setup
	_t_sessions="$_t_sand/sessions"
	# The writer lands well inside a one-second wait, so the answer can only
	# carry these bytes if the loop actually waited for them.
	( sleep 0.2; printf 'xy' >> "$_t_sessions/fcc-dsh-001.out" ) &
	_tt_qs="action=output&name=fcc-dsh-001&offset=0&wait=1"
	term_run
	wait
	assert_status "200 OK" "a long poll answers 200"
	assert_contains "$(body)" '"data":"eHk="' "the long poll returned the bytes that arrived while it waited"
	assert_contains "$(body)" '"offset":2' "the offset is what was actually sent"
}

test_output_reports_a_dead_pane() {
	t_reset
	_tt_pane="80x24x1x0"
	_tt_qs="action=output&name=fcc-dsh-001&offset=0&wait=0"
	term_run
	assert_status "200 OK" "a dead pane is an answer, not an error"
	_tt_b="$(body)"
	assert_contains "$_tt_b" '"alive":false' "the pane is reported dead"
	assert_contains "$_tt_b" '"eof":true' "the stream has ended"
	assert_contains "$_tt_b" '"exit_code":0' "the pane's exit status is passed on"
	assert_contains "$_tt_b" '"cols":80' "the pane's grid comes with the answer"
	assert_contains "$_tt_b" '"rows":24' "the pane's grid comes with the answer"
}

test_output_refuses_bad_session_names() {
	t_reset
	setup
	_tt_qs="action=output&name=fcc-dsh-001%3Brm%20-rf%20%2F&offset=0&wait=0"
	term_run
	assert_status "400 Bad Request" "a name with shell syntax is refused"

	_tt_qs="action=output&name=..%2F..%2Fetc%2Fpasswd&offset=0&wait=0"
	term_run
	assert_status "400 Bad Request" "a path is refused"

	_tt_qs="action=output&name=fcc-unknown-001&offset=0&wait=0"
	term_run
	assert_status "400 Bad Request" "an agent the package does not know is refused"

	_tt_qs="action=output&name=fcc-dsh-1&offset=0&wait=0"
	term_run
	assert_status "400 Bad Request" "a name off the fcc-<agent>-NNN grammar is refused"
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

test_input_types_the_bytes() {
	t_reset
	setup
	_tt_method="POST"
	_tt_qs="action=input"
	_tt_origin="http://192.168.10.1"
	term_run "name=fcc-dsh-001&data=6c73"
	assert_status "200 OK" "a POSTed keystroke is accepted"
	assert_contains "$(body)" '"ok":true' "the answer says so"
	assert_eq "6c73" "$(cat "$_t_sand/state/sent")" "tmux receive exactly the posted bytes"
}

test_input_requires_post() {
	t_reset
	setup
	_tt_method="GET"
	_tt_qs="action=input&name=fcc-dsh-001&data=6c73"
	term_run
	assert_status "400 Bad Request" "typing is refused over GET"
	assert_eq "" "$(cat "$_t_sand/state/sent")" "nothing reached tmux"
}

test_input_refuses_malformed_hex() {
	t_reset
	setup
	_tt_method="POST"
	_tt_qs="action=input"
	_tt_origin="http://192.168.10.1"

	term_run "name=fcc-dsh-001&data=zz"
	assert_status "400 Bad Request" "non-hex bytes are refused"

	term_run "name=fcc-dsh-001&data=6"
	assert_status "400 Bad Request" "an odd-length byte string is refused"

	term_run "name=fcc-nope-001&data=6c"
	assert_status "400 Bad Request" "input to an unknown session is refused"

	# Nothing above may have reached tmux.
	assert_eq "" "$(cat "$_t_sand/state/sent")" "refused input never reaches tmux"
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

test_input_needs_a_same_origin_post() {
	t_reset
	setup
	_tt_method="POST"
	_tt_qs="action=input"
	_tt_body="name=fcc-dsh-001&data=6c73"

	term_run "$_tt_body"
	assert_status "403 Forbidden" "a POST stating no origin is refused"
	assert_eq "" "$(cat "$_t_sand/state/sent")" "and nothing reaches tmux"

	_tt_origin="http://evil.example"
	term_run "$_tt_body"
	assert_status "403 Forbidden" "a POST from another origin is refused"

	_tt_origin=""
	_tt_referer="http://192.168.10.1/cgi-bin/luci/admin/services/fcc/console"
	term_run "$_tt_body"
	assert_status "200 OK" "a same-origin Referer is accepted when no Origin is sent"

	_tt_referer="http://evil.example/"
	term_run "$_tt_body"
	assert_status "403 Forbidden" "a foreign Referer is refused"

	_tt_referer=""
	_tt_origin="http://192.168.10.1"
	term_run "$_tt_body"
	assert_status "200 OK" "the page's own Origin is accepted"
	assert_eq "6c73" "$(cat "$_t_sand/state/sent")" "and the bytes reach tmux"
}

test_origin_must_match_the_host() {
	t_reset
	setup
	_tt_qs="action=output&name=fcc-dsh-001&offset=0&wait=0"

	_tt_origin="http://evil.example"
	term_run
	assert_status "403 Forbidden" "a foreign Origin is refused"

	_tt_origin="http://192.168.10.1"
	term_run
	assert_status "200 OK" "the page's own Origin is accepted"

	_tt_origin=""
	term_run
	assert_status "200 OK" "an absent Origin is what a same-origin GET sends"
}

test_requires_a_live_session() {
	t_reset
	setup
	_tt_qs="action=output&name=fcc-dsh-001&offset=0&wait=0"

	_tt_cookie=""
	term_run
	assert_status "403 Forbidden" "no cookie means no session"

	_tt_cookie="sysauth_https=not%20a%20session"
	term_run
	assert_status "403 Forbidden" "a malformed id never reaches ubus"

	_tt_cookie="sysauth_https=0123456789abcdef0123456789abcdef"
	_tt_auth="dead"
	term_run
	assert_status "403 Forbidden" "a session ubus does not know is refused"
}

test_access_group_must_include_this_app() {
	t_reset
	setup
	_tt_qs="action=output&name=fcc-dsh-001&offset=0&wait=0"

	_tt_acl="other"
	term_run
	assert_status "403 Forbidden" "a session restricted to another app is refused"

	_tt_acl="fcc"
	term_run
	assert_status "200 OK" "the package's own ACL group is accepted"

	_tt_acl="root"
	term_run
	assert_status "200 OK" "root is accepted"
}

test_unknown_action_is_refused() {
	t_reset
	_tt_qs="action=shell&name=fcc-dsh-001"
	term_run
	assert_status "400 Bad Request" "an action this CGI does not have is refused"
}

# ---------------------------------------------------------------------------
# Trim: the inode has to survive
# ---------------------------------------------------------------------------

test_trim_rewrites_in_place() {
	t_reset
	setup
	_tt_out="$_t_sand/sessions/fcc-dsh-001.out"
	# Past the 4 MiB cap. The content is uniform, so the answer is a 1 MiB tail
	# at the new base; what matters is that the path still names the same file
	# afterwards, because pipe-pane's `cat >>` holds that inode.
	head -c 4194305 /dev/zero | tr '\0' 'a' > "$_tt_out"
	_tt_ino_before="$(ls -i "$_tt_out" | awk '{print $1}')"
	_tt_qs="action=output&name=fcc-dsh-001&offset=0&wait=0"
	term_run
	_tt_ino_after="$(ls -i "$_tt_out" | awk '{print $1}')"
	_tt_size="$(wc -c < "$_tt_out" | tr -d ' ')"
	assert_eq "$_tt_ino_before" "$_tt_ino_after" "trimming keeps the scrollback file's inode"
	assert_eq "1048576" "$_tt_size" "the file is cut to the trim target"
	assert_contains "$(body)" '"reset":true' "the caller is told its offset moved"
	assert_contains "$(body)" '"offset":4194305' "the absolute offset accounts for the trim"
	assert_contains "$(cat "$_t_sand/sessions/fcc-dsh-001.base")" "3145729" \
		"the base advances by exactly what was dropped"
}

# ---------------------------------------------------------------------------
# Wiring: the package ships it and both pages prefer it, with a fallback
# ---------------------------------------------------------------------------

test_package_installs_the_cgi() {
	assert_file "$CGI"
	assert_exec "$CGI"
	assert_contains "$(cat "$ROOT/Makefile")" \
		'./root/www/cgi-bin/fcc-term $(1)/www/cgi-bin/fcc-term' \
		"the Makefile installs the CGI"
}

test_views_publish_the_fast_endpoint() {
	for _tt_f in "$ROOT/luasrc/view/fcc/console.htm" "$ROOT/luasrc/view/fcc/popout.htm"; do
		_tt_src="$(cat "$_tt_f")"
		assert_contains "$_tt_src" "var FCC_TERM" "$(basename "$_tt_f") publishes the endpoint"
		assert_contains "$_tt_src" '/luci/' "$(basename "$_tt_f") derives it from the dispatcher's mount point"
		assert_contains "$_tt_src" 'fcc-term' "$(basename "$_tt_f") names the CGI"
	done
}

test_views_republish_the_session_cookie() {
	# LuCI sets its cookie with path=build_url(), i.e. /cgi-bin/luci, so a
	# browser never sends it to /cgi-bin/fcc-term.  Both pages publish the same
	# id under the transport's own path; without that the endpoint answers 403
	# and every keystroke stays on the slow route.
	#
	# The header is written before the page's first byte of markup: LuCI emits
	# the response headers when output starts, so a Set-Cookie set later would
	# never reach the browser.
	for _tt_f in "$ROOT/luasrc/view/fcc/console.htm" "$ROOT/luasrc/view/fcc/popout.htm"; do
		_tt_name="$(basename "$_tt_f")"
		_tt_src="$(cat "$_tt_f")"
		assert_contains "$_tt_src" 'getcookie("sysauth_https")' \
			"$_tt_name reads the LuCI session id"
		assert_contains "$_tt_src" '"Set-Cookie", "fcc_term="' \
			"$_tt_name republishes it as fcc_term"
		assert_contains "$_tt_src" '"; path=" .. _term' \
			"$_tt_name scopes the copy to the transport's own path"
		assert_contains "$_tt_src" 'HttpOnly; SameSite=strict' \
			"$_tt_name keeps the copy as strict as the original"
		assert_contains "$_tt_src" 'getenv("HTTPS") == "on"' \
			"$_tt_name marks the copy secure when the page is served over TLS"
		_tt_set_at="$(grep -n '"Set-Cookie", "fcc_term="' "$_tt_f" | cut -d: -f1)"
		_tt_out_at="$(grep -n -m1 -e '<%+header%>' -e '<!DOCTYPE' "$_tt_f" | cut -d: -f1)"
		assert_ok "$_tt_name sets its cookie before any output begins" \
			test "$_tt_set_at" -lt "$_tt_out_at"
	done
}

test_fcc_term_cookie_authenticates() {
	# The copy is what a browser sends; the endpoint must accept it, and prefer
	# it over the dispatcher's names when both are present.
	t_reset
	setup
	_tt_qs="action=output&name=fcc-dsh-001&offset=0&wait=0"
	_tt_cookie="fcc_term=0123456789abcdef0123456789abcdef"
	term_run
	assert_status "200 OK" "the republished cookie authenticates"

	_tt_cookie="sysauth_https=ffffffffffffffffffffffffffffffff"
	term_run
	assert_status "403 Forbidden" "and the dispatcher's cookie alone is not enough when it is dead"

	_tt_cookie="sysauth_https=ffffffffffffffffffffffffffffffff;fcc_term=0123456789abcdef0123456789abcdef"
	term_run
	assert_status "200 OK" "the republished copy is preferred when both are sent"
}

test_client_falls_back_to_luci() {
	_tt_src="$(cat "$COMMON")"
	assert_contains "$_tt_src" "api('session_output'" \
		"the shared client falls back to the LuCI output action"
	assert_contains "$_tt_src" "api('session_input'" \
		"the shared client falls back to the LuCI input action"
	assert_contains "$_tt_src" "fastBroken" \
		"the fallback is decided by the failure, not by a guess"
}

test_pages_share_the_key_queue() {
	for _tt_f in "$TERMINAL" "$POPOUT"; do
		_tt_src="$(cat "$_tt_f")"
		assert_contains "$_tt_src" "FCC.keyQueue" "$(basename "$_tt_f") queues its keystrokes"
		assert_contains "$_tt_src" "FCC.strToHex" "$(basename "$_tt_f") sends hex, as tmux takes"
		assert_contains "$_tt_src" "FCC.termPoll" "$(basename "$_tt_f") polls through the fast transport"
		assert_not_contains "$_tt_src" "FCC.api('session_input'" \
			"$(basename "$_tt_f") has no direct LuCI input call left"
		assert_not_contains "$_tt_src" "FCC.api('session_output'" \
			"$(basename "$_tt_f") has no direct LuCI output call left"
	done
}

# ---------------------------------------------------------------------------
# The console names where the agent runs
#
# "Where does this agent run" cannot be answered by a path on every platform:
# a LAN target on Linux or macOS starts the launcher from that account's PATH,
# so there is no runtime directory to name. The line therefore answers per
# mode — this router names its runtime, a LAN target names the account and the
# working directory a new session starts in — and it is the same row under the
# hint in both cases.
# ---------------------------------------------------------------------------

test_console_names_where_the_agent_runs() {
	_tt_view="$ROOT/luasrc/view/fcc/console.htm"
	_tt_src="$(cat "$TERMINAL")"
	_tt_css="$ROOT/htdocs/luci-static/resources/fcc/fcc.css"

	# The row exists before the first answer and is the page's first element,
	# so a console with nothing to say does not shift the pane down.
	assert_contains "$(cat "$_tt_view")" 'id="fcc-term-where"' \
		"the console has the where row"
	assert_contains "$(sed -n '/id="fcc-term-where"/p' "$_tt_view")" 'hidden' \
		"hidden until there is an answer"
	_tt_where_at="$(grep -n 'id="fcc-term-where"' "$_tt_view" | cut -d: -f1)"
	_tt_toolbar_at="$(grep -n 'class="fcc-toolbar"' "$_tt_view" | head -1 | cut -d: -f1)"
	assert_eq 1 "$((_tt_where_at < _tt_toolbar_at))" \
		"the row stands above the toolbar"

	# The page's two hint paragraphs were removed on request: the tab bar and
	# the toolbar name the page, and neither paragraph left a blank slot.
	assert_not_contains "$(cat "$_tt_view")" 'cbi-map-descr' \
		"the console carries no top hint"
	assert_not_contains "$(cat "$_tt_view")" 'Sessions are hosted by tmux' \
		"and no bottom note"
	assert_not_contains "$(cat "$_tt_view")" 'survive a page reload' \
		"nor any fragment of one"

	# What the script draws, per mode.
	assert_contains "$_tt_src" 'function renderRuntimeLine()' \
		"the console has one renderer for the row"
	assert_contains "$_tt_src" "FCC.\$('#fcc-term-where')" \
		"which owns that element"
	assert_contains "$_tt_src" 'state.runtime' \
		"and reads the runtime answer"
	assert_contains "$_tt_src" 'workdir_enabled' \
		"the working directory counts only while it is enabled"
	assert_contains "$_tt_src" 'login directory (default)' \
		"an unset directory says which default applies"
	assert_contains "$_tt_src" 'This router · agent runtime:' \
		"local mode names this router's runtime"
	assert_contains "$_tt_src" 'LAN machine:' \
		"and LAN mode names the machine it reaches"

	# The ten-second target poll carries the fields, so a directory changed on
	# the Configuration tab reaches an open console without an SSH round trip.
	assert_contains "$(sed -n '/function refreshTarget()/,/^	}$/p' "$TERMINAL")" \
		'state.runtime = {' "the poll refreshes the runtime answer"
	assert_contains "$(sed -n '/function refreshTarget()/,/^	}$/p' "$TERMINAL")" \
		'renderRuntimeLine();' "and redraws the row when only the directory changed"

	assert_contains "$(cat "$_tt_css")" '.fcc-term-where' \
		"the row has its own style"
}

test_cgi_quotes_its_argv() {
	_tt_src="$(cat "$CGI")"
	assert_not_contains "$_tt_src" "os.execute" "the CGI never builds a shell command"
	assert_not_contains "$_tt_src" "io.popen" "the CGI runs programs through util.exec_argv only"
	assert_contains "$_tt_src" "util.exec_argv" "and that is what it uses"
}

tests_main
