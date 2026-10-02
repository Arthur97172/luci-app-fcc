#!/bin/sh
# luci-app-fcc — security policy checks.
#
# These encode the security requirements of DESIGN_SPEC.md sections 29, 30 and
# 87 as executable assertions, so a later edit cannot quietly undo one:
#
#   * no credential is ever stored in UCI, and none is committed
#   * the FCC port is never bound to the WAN
#   * every state-changing API action requires POST
#   * the ACL grants the fcc config and the backend scripts, nothing wider
#   * the runtime installer is fetched over HTTPS and never piped to a shell
#   * the UI does not poll faster than the spec allows, and runs no
#     Node/Python WebSocket server

TESTS_NAME="security"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

CTRL="$ROOT/luasrc/controller/fcc.lua"
ACL="$ROOT/root/usr/share/rpcd/acl.d/luci-app-fcc.json"

# Everything that would be published. DESIGN_SPEC.md and CLAUDE.md are excluded
# deliberately: they are the specification and the working notes, they are not
# part of the package, and the push explicitly leaves them out (which
# test_local_notes_are_ignored below enforces).
shipped_files() {
	find "$ROOT/root" "$ROOT/htdocs" "$ROOT/luasrc" "$ROOT/po" \
	     "$ROOT/scripts" "$ROOT/tests" "$ROOT/.github" -type f 2>/dev/null
	printf '%s\n' "$ROOT/Makefile" "$ROOT/VERSION" "$ROOT/LICENSE" "$ROOT/.gitignore"
	[ -f "$ROOT/README.md" ] && printf '%s\n' "$ROOT/README.md"
}

# The body of one controller function. The optional `local` matters: the guard
# helpers are declared `local function ...`.
action_body() {
	awk "/^(local )?function $1\(\)\$/,/^end\$/" "$CTRL"
}

# Actions that change state. Each must refuse a GET, so that a browser prefetch,
# an <img> tag or a link cannot start an install or type into a terminal.
mutating_actions() {
	cat <<'EOF'
act_agent_install
act_agent_remove
act_config_set
act_install_runtime
act_server
act_session_cleanup
act_session_close
act_session_create
act_session_input
act_session_resize
act_status_refresh
act_uninstall_runtime
act_update_runtime
EOF
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

test_no_credentials_are_committed() {
	_ts_hits=""
	while IFS= read -r _ts_pat; do
		case "$_ts_pat" in ''|\#*) continue ;; esac
		_ts_found="$(shipped_files | while IFS= read -r _ts_f; do
			[ "$_ts_f" = "$ROOT/tests/secrets.patterns" ] && continue
			grep -nE -- "$_ts_pat" "$_ts_f" 2>/dev/null | sed "s#^#$(printf '%s' "$_ts_f" | sed "s#^$ROOT/##"):#"
		done)"
		if [ -n "$_ts_found" ]; then
			_ts_hits="$_ts_hits
$_ts_found"
		fi
	done < "$ROOT/tests/secrets.patterns"
	assert_eq "" "$(printf '%s' "$_ts_hits" | sed '/^$/d')" "no credential pattern matches a shipped file"
}

test_no_credentials_in_uci_config() {
	# Section 29: API keys live in FCC's own configuration, managed by FCC.
	# luci-app-fcc only links to FCC Admin; it never holds a key.
	_ts_cfg="$(cat "$ROOT/root/etc/config/fcc")"
	for _ts_opt in key token secret password apikey api_key credential bearer; do
		case "$_ts_cfg" in
			*"option $_ts_opt"*) fail "the UCI config must not carry an option named $_ts_opt" ;;
			*) pass ;;
		esac
	done
	# The only section is `fcc main`; no provider sections, no credentials.
	assert_eq "1" "$(grep -c '^config ' "$ROOT/root/etc/config/fcc")" \
		"the UCI config has exactly one section"
}

test_local_notes_are_not_published() {
	# The specification and the working notes stay local. They are gitignored so
	# that a `git add .` cannot publish them by accident.
	_ts_ignored="$(cat "$ROOT/.gitignore")"
	assert_contains "$_ts_ignored" "DESIGN_SPEC.md" "DESIGN_SPEC.md is gitignored"
	assert_contains "$_ts_ignored" "CLAUDE.md" "CLAUDE.md is gitignored"
}

test_redaction_covers_the_token_formats() {
	# The backend logs command output; fcc_redact() is the last line of defence
	# if something credential-shaped ever reaches a log line.
	#
	# The samples are assembled from parts so this file does not itself contain a
	# token-shaped literal — test_no_credentials_are_committed scans it too.
	_ts_gh='ghp_'
	_ts_sample1="${_ts_gh}abcdefghijklmnopqrstuvwxyz"
	_ts_sample2="${_ts_gh}0123456789abcdefghij"
	_ts_sample3='sk-abcdef123456789'

	_ts_red="$(FCC_LIBDIR="$ROOT/root/usr/libexec/fcc" \
		sh -c '. "$1/common.sh"; fcc_redact' _ "$ROOT/root/usr/libexec/fcc" <<EOF
Authorization: Bearer $_ts_sample3
api_key=$_ts_sample1
token: $_ts_sample2
EOF
)"
	assert_not_contains "$_ts_red" "$_ts_sample3" "a bearer token is redacted"
	assert_not_contains "$_ts_red" "$_ts_sample1" "an api_key value is redacted"
	assert_not_contains "$_ts_red" "$_ts_sample2" "a token value is redacted"
	assert_contains "$_ts_red" "REDACTED" "redaction marks what it removed"
}

# ---------------------------------------------------------------------------
# Network exposure (section 87: 8082 is never on the WAN)
# ---------------------------------------------------------------------------

test_port_defaults_to_loopback() {
	assert_contains "$(cat "$ROOT/root/etc/config/fcc")" "option bind '127.0.0.1'" \
		"the shipped bind default is loopback"
	assert_contains "$(cat "$ROOT/root/etc/init.d/fcc")" 'HOST="$_ss_bind"' \
		"the init script passes the UCI bind to the server"
	assert_contains "$(cat "$ROOT/root/etc/init.d/fcc")" 'valid_bind "$_ss_bind" || _ss_bind=127.0.0.1' \
		"an invalid bind falls back to loopback, not to all interfaces"
}

test_init_forces_host_over_upstream_default() {
	# Upstream's own default for HOST is 0.0.0.0. The init script must set HOST
	# explicitly, or the server would listen on the WAN.
	_ts_init="$(cat "$ROOT/root/etc/init.d/fcc")"
	assert_contains "$_ts_init" "Upstream defaults HOST to 0.0.0.0" \
		"the init script records why HOST is forced"
	assert_contains "$_ts_init" 'HOST="$_ss_bind"' "HOST is forced from UCI"
}

test_bind_is_validated_in_both_layers() {
	# The UI and the init script both reject a non-literal bind, so a hostname
	# that resolves to a WAN address cannot be typed in.
	assert_contains "$(cat "$ROOT/luasrc/fcc/util.lua")" "function valid_bind" \
		"the Lua layer validates the bind address"
	assert_contains "$(cat "$ROOT/root/etc/init.d/fcc")" "valid_bind()" \
		"the init layer validates the bind address"
}

# ---------------------------------------------------------------------------
# Request handling (section 30)
# ---------------------------------------------------------------------------

test_mutating_actions_require_post() {
	_ts_bad=""
	for _ts_a in $(mutating_actions); do
		case "$(action_body "$_ts_a")" in
			*"require_post()"*) : ;;
			*) _ts_bad="$_ts_bad $_ts_a" ;;
		esac
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every state-changing action requires POST"
}

test_every_action_is_declared() {
	# A new act_* function that nobody routed is dead code; a route to a missing
	# function is a 500. Both are caught by comparing the two lists.
	_ts_declared="$(grep -o '^function act_[a-z_]*' "$CTRL" | sed 's/^function //' | LC_ALL=C sort)"
	_ts_routed="$(sed -n '/^\tlocal actions = {/,/^\t}/p' "$CTRL" \
		| grep -o 'act_[a-z_]*' | LC_ALL=C sort -u)"
	assert_eq "$_ts_routed" "$_ts_declared" "every act_* function is routed and every route has a function"
}

test_require_post_rejects_non_post() {
	# The guard pair. is_post() does the comparison and must fail closed: a
	# missing REQUEST_METHOD has to read as GET, not as "allow".
	_ts_is="$(action_body is_post)"
	assert_contains "$_ts_is" 'http.getenv("REQUEST_METHOD")' "is_post reads the request method"
	assert_contains "$_ts_is" 'or "GET"' "a missing request method is treated as GET"
	assert_contains "$_ts_is" '"POST"' "is_post compares against POST"

	_ts_req="$(action_body require_post)"
	assert_contains "$_ts_req" "is_post()" "require_post delegates to is_post"
	assert_contains "$_ts_req" "return false" "require_post returns false when the method is wrong"
}

# ---------------------------------------------------------------------------
# ACL
# ---------------------------------------------------------------------------

test_acl_is_scoped_to_fcc() {
	_ts_acl="$(cat "$ACL")"
	assert_not_contains "$_ts_acl" '"uci": [ "*" ]' "the ACL does not grant every UCI config"
	assert_not_contains "$_ts_acl" '"*"' "the ACL contains no wildcard grant"
	assert_contains "$_ts_acl" '"uci": [ "fcc" ]' "the ACL grants the fcc config"
}

test_acl_has_no_unauthenticated_section() {
	# An "unauthenticated" block would expose the API before login.
	assert_not_contains "$(cat "$ACL")" "unauthenticated" "the ACL has no unauthenticated section"
}

test_acl_grants_exec_only_on_our_scripts() {
	_ts_bad=""
	for _ts_p in $(grep -o '"/usr/[^"]*"' "$ACL" | tr -d '"' | LC_ALL=C sort -u); do
		case "$_ts_p" in
			/usr/libexec/fcc/*.sh|/usr/bin/fcc-env) : ;;
			*) _ts_bad="$_ts_bad $_ts_p" ;;
		esac
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "the ACL execs only this package's scripts"
}

# ---------------------------------------------------------------------------
# Runtime installer (section 40)
# ---------------------------------------------------------------------------

test_installer_is_https_only() {
	_ts_install="$(cat "$ROOT/root/usr/libexec/fcc/install.sh")"
	assert_contains "$_ts_install" "refusing non-HTTPS installer URL" "a non-HTTPS installer URL is refused"
	assert_contains "$_ts_install" "https://raw.githubusercontent.com" "the default installer URL is HTTPS"
	assert_contains "$_ts_install" "--proto '=https'" "curl is pinned to HTTPS"
}

test_installer_is_hashed_before_it_runs() {
	_ts_install="$(cat "$ROOT/root/usr/libexec/fcc/install.sh")"
	assert_contains "$_ts_install" "sha256_of" "the installer is hashed"
	assert_contains "$_ts_install" "installer-hashes.log" "the hash is recorded"
}

test_install_path_is_validated_before_use() {
	# The path the runtime is installed into is exec'd from, so it is the most
	# dangerous input in the package.
	assert_contains "$(cat "$ROOT/root/usr/libexec/fcc/common.sh")" "fcc_canon_base" \
		"the shell canonicalises the install path"
	assert_contains "$(cat "$ROOT/luasrc/fcc/util.lua")" "function valid_install_path" \
		"the Lua layer validates the install path"
}

# ---------------------------------------------------------------------------
# Section 87: no forbidden runtime, no aggressive polling
# ---------------------------------------------------------------------------

test_no_websocket_server() {
	# The Web Console uses an HTTP byte stream with absolute offsets instead.
	# A Node/Python WebSocket server is explicitly forbidden, and uhttpd has no
	# WebSocket support to fall back on.
	_ts_bad=""
	for _ts_f in "$ROOT"/htdocs/luci-static/resources/fcc/fcc-*.js \
	              "$ROOT"/root/usr/libexec/fcc/*.sh "$CTRL"; do
		grep -nE 'new[[:space:]]+WebSocket|ws://|wss://' "$_ts_f" >/dev/null 2>&1 \
			&& _ts_bad="$_ts_bad $(basename "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "no WebSocket client or server anywhere"
}

test_polling_is_not_aggressive() {
	# Section 87 forbids 100 ms polling. Every interval in the UI must be at
	# least a second, and the terminal's long-poll must be a long poll.
	_ts_bad=""
	for _ts_f in "$ROOT"/htdocs/luci-static/resources/fcc/fcc-*.js; do
		_ts_line="$(grep -n 'setInterval' "$_ts_f")"
		[ -n "$_ts_line" ] || continue
		for _ts_ms in $(printf '%s\n' "$_ts_line" | grep -oE ',[[:space:]]*[0-9]+\)' | grep -oE '[0-9]+'); do
			[ "$_ts_ms" -ge 1000 ] || _ts_bad="$_ts_bad $(basename "$_ts_f"):${_ts_ms}ms"
		done
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "no polling interval is under one second"
}

test_terminal_long_polls() {
	# The console must not spin: it waits for the backend, which caps the wait.
	assert_contains "$(cat "$ROOT/htdocs/luci-static/resources/fcc/fcc-terminal.js")" "wait" \
		"the terminal sends a wait parameter"
	_ts_sh="$(cat "$ROOT/root/usr/libexec/fcc/session.sh")"
	assert_contains "$_ts_sh" '[ "$_ou_wait" -le 25 ] || _ou_wait=25' \
		"the backend caps the long-poll wait"
}

test_no_persistent_daemon() {
	# Section 87: no persistent Python/Node daemon. The only long-lived process
	# is the FCC server itself, supervised by procd, plus tmux panes.
	_ts_bad=""
	for _ts_f in "$ROOT"/root/usr/libexec/fcc/*.sh "$ROOT"/root/etc/init.d/fcc; do
		grep -nE 'nohup|start-stop-daemon|--daemon' "$_ts_f" >/dev/null 2>&1 \
			&& _ts_bad="$_ts_bad $(basename "$_ts_f")"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "the backend starts no daemon of its own"
}

test_no_shell_interpolation_of_user_input() {
	# Section 30: nothing user-supplied is concatenated into a shell command.
	# In Lua that means every argv word goes through shell_quote().
	_ts_bad=""
	for _ts_f in "$ROOT"/luasrc/fcc/*.lua "$CTRL"; do
		grep -nE 'os\.execute' "$_ts_f" >/dev/null 2>&1 && _ts_bad="$_ts_bad $(basename "$_ts_f"):os.execute"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "no os.execute anywhere"
	assert_contains "$(cat "$ROOT/luasrc/fcc/util.lua")" "local parts = { shell_quote(cmd) }" \
		"exec_argv quotes every word it passes"
}

tests_main
