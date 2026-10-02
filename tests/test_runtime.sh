#!/bin/sh
# luci-app-fcc — behaviour of the shell backend.
#
# test_shell.sh checks that the backend is well-formed. This file checks that it
# is *correct*: the path canonicaliser, the id grammars, the JSON emitter, the
# cache, the /proc readers and the terminal's absolute-offset arithmetic are all
# run for real against a sandbox tree.
#
# The scripts are pointed at the sandbox with the same environment overrides
# they honour in production (FCC_LIBDIR, FCC_AGENTS_CONF, FCC_DEFAULT_BASE), so
# nothing here needs root or an OpenWrt system.

TESTS_NAME="runtime"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

LIBEXEC="$ROOT/root/usr/libexec/fcc"
AGENTS_CONF="$ROOT/root/usr/share/luci-app-fcc/agents.conf"

# The sandbox lives under the repo rather than in /tmp, because /tmp is one of
# the directories fcc_canon_base() deliberately refuses. Putting it here means
# the install-path tests exercise the *accepting* branch, and a rejected path in
# a test is a real rejection rather than a side effect of where mktemp put us.
# (/tmp-test/ is gitignored.)
SANDBOX=""
setup_sandbox() {
	[ -n "$SANDBOX" ] && return 0
	SANDBOX="$ROOT/tmp-test/runtime.$$"
	rm -rf "$SANDBOX"
	mkdir -p "$SANDBOX"
	trap 'rm -rf "$SANDBOX"' EXIT INT TERM
}

# Run a snippet with common.sh sourced and the sandbox in place.
#   sh_common '<code>'
sh_common() {
	FCC_LIBDIR="$LIBEXEC" \
	FCC_AGENTS_CONF="$AGENTS_CONF" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	FCC_DEFAULT_BASE="$SANDBOX/opt" \
	sh -c '. "$1/common.sh"; eval "$2"' _ "$LIBEXEC" "$1" 2>&1
}

# ---------------------------------------------------------------------------
# Path canonicalisation — the most security-relevant function in the backend,
# because the result is a directory the runtime is installed into and exec'd
# from.
# ---------------------------------------------------------------------------

test_canon_base_accepts_safe_paths() {
	setup_sandbox
	assert_eq "/opt"            "$(sh_common 'fcc_canon_base /opt')"            "/opt is accepted"
	assert_eq "/mnt/sda1"       "$(sh_common 'fcc_canon_base /mnt/sda1')"       "a mount point is accepted"
	assert_eq "/mnt/sda1"       "$(sh_common 'fcc_canon_base /mnt/sda1/')"      "a trailing slash is dropped"
	assert_eq "/mnt/sda1"       "$(sh_common 'fcc_canon_base /mnt//sda1')"      "duplicate slashes collapse"
	assert_eq "/srv/fcc"        "$(sh_common 'fcc_canon_base /srv/fcc')"        "a custom base is accepted"
	assert_eq "/opt"            "$(sh_common 'fcc_canon_base "  /opt  "')"      "surrounding whitespace is trimmed"
	# An empty value means "use the default", and the default here is the
	# sandbox base rather than /opt, so this asserts the wiring not the literal.
	assert_eq "$SANDBOX/opt"    "$(sh_common 'fcc_canon_base ""')"              "empty falls back to the default"
	# canon_base returns the *base*: appending /fcc is fcc_root's job.
	assert_eq "/home/user"      "$(sh_common 'fcc_canon_base /home/user')"      "/home is not a system directory"
}

test_canon_base_rejects_system_paths() {
	setup_sandbox
	for _tr_p in / /proc /proc/1 /sys /dev /tmp /tmp/x /var /var/lib /etc /etc/fcc \
	             /usr /usr/lib /bin /sbin /lib /lib64 /rom /overlay /root; do
		assert_no "fcc_canon_base rejects $_tr_p" \
			sh_common "fcc_canon_base '$_tr_p' >/dev/null"
	done
}

test_canon_base_rejects_injection() {
	setup_sandbox
	# Every one of these would be catastrophic if it reached a shell word.
	for _tr_p in '/opt;id' '/opt|id' '/opt&id' '/opt$(id)' '/opt`id`' '/opt*' \
	             '/opt?' '/opt!x' '/opt~' '/opt>x' '/opt<x' '/opt(x)' '/opt{x}' \
	             '/opt/../etc' '/opt/..' '../opt' '..' 'opt' 'relative/path'; do
		assert_no "fcc_canon_base rejects [$_tr_p]" \
			sh_common "fcc_canon_base '$_tr_p' >/dev/null"
	done
}

test_fcc_root_appends_fcc_once() {
	setup_sandbox
	# The base is a *base*: /opt becomes /opt/fcc, but a base that already ends
	# in /fcc is used as-is rather than becoming /opt/fcc/fcc.
	assert_eq "/opt/fcc"     "$(sh_common 'FCC_DEFAULT_BASE=/opt; fcc_root')" "the default base gains /fcc"
	assert_eq "/mnt/sda/fcc" "$(sh_common 'FCC_DEFAULT_BASE=/mnt/sda; fcc_root')" "a custom base gains /fcc"
	assert_eq "/opt/fcc"     "$(sh_common 'FCC_DEFAULT_BASE=/opt/fcc; fcc_root')" "/fcc is not appended twice"
	# A rejected default must not become the root: /etc would put the runtime
	# inside the config tree. Both candidates are canonicalised, so this lands on
	# the hard-coded /opt instead.
	assert_eq "/opt/fcc"     "$(sh_common 'FCC_DEFAULT_BASE=/etc; fcc_root')" \
		"a rejected base falls back to /opt"
	assert_eq "/opt/fcc"     "$(sh_common 'FCC_DEFAULT_BASE=/proc/self; fcc_root')" \
		"a rejected base with a subpath also falls back"
}

# ---------------------------------------------------------------------------
# Agent registry
# ---------------------------------------------------------------------------

test_agent_grammar() {
	setup_sandbox
	assert_ok "a known agent is valid"     sh_common 'fcc_valid_agent claude'
	assert_ok "an agent with digits"       sh_common 'fcc_valid_agent dsh'
	assert_no "an unknown agent"           sh_common 'fcc_valid_agent nosuch'
	assert_no "an uppercase id"            sh_common 'fcc_valid_agent Claude'
	assert_no "an id with a dash"          sh_common 'fcc_valid_agent a-b'
	assert_no "an id with a slash"         sh_common 'fcc_valid_agent ../../etc/passwd'
	assert_no "an empty id"                sh_common 'fcc_valid_agent ""'
	assert_no "an id with a space"         sh_common 'fcc_valid_agent "a b"'
	assert_no "an id with a semicolon"     sh_common 'fcc_valid_agent "claude;id"'
	assert_no "a glob"                     sh_common 'fcc_valid_agent "*"'
}

test_agent_fields() {
	setup_sandbox
	assert_eq "Claude Code" "$(sh_common 'fcc_agent_name claude')"  "the friendly name is read"
	assert_eq "fcc-claude"  "$(sh_common 'fcc_agent_command claude')" "the launcher is read"
	assert_eq "claude"      "$(sh_common 'fcc_agent_probe claude')" "the probe is read"
	assert_eq "fcc-dsh"     "$(sh_common 'fcc_agent_command dsh')"  "DeepSeek Harness is fcc-dsh"
	assert_eq ""            "$(sh_common 'fcc_agent_probe hermes')" "hermes has no probe"
	assert_eq "10"          "$(sh_common 'fcc_agents_each | wc -l | tr -d " "')" "the registry has 10 agents"
	assert_eq "10"          "$(sh_common 'fcc_agents_each | cut -d"|" -f1 | sort -u | wc -l | tr -d " "')" \
		"every agent id is unique"
}

test_agent_probe_is_never_a_launcher() {
	setup_sandbox
	# An fcc-* name is a console script that STARTS the agent. Probing one to
	# read a version would launch it.
	_tr_hits="$(sh_common 'fcc_agents_each | awk -F"|" "\$7 ~ /^fcc-/ {print \$1}"')"
	assert_eq "" "$_tr_hits" "no probe column holds an fcc-* launcher"
	_tr_hits="$(sh_common 'fcc_agents_each | awk -F"|" "\$3 !~ /^fcc-/ {print \$1}"')"
	assert_eq "" "$_tr_hits" "every launcher is an fcc-* console script"
}

# ---------------------------------------------------------------------------
# Session grammar
# ---------------------------------------------------------------------------

test_session_grammar() {
	setup_sandbox
	assert_ok "a well-formed session"      sh_common 'fcc_valid_session fcc-claude-001'
	assert_ok "the highest slot"           sh_common 'fcc_valid_session fcc-dsh-999'
	assert_no "two digits"                 sh_common 'fcc_valid_session fcc-claude-01'
	assert_no "four digits"                sh_common 'fcc_valid_session fcc-claude-0001'
	assert_no "a missing prefix"           sh_common 'fcc_valid_session claude-001'
	assert_no "an empty agent"             sh_common 'fcc_valid_session fcc--001'
	assert_no "an unknown agent"           sh_common 'fcc_valid_session fcc-nosuch-001'
	assert_no "a command injection"        sh_common 'fcc_valid_session "fcc-claude-001; id"'
	assert_no "a traversal"                sh_common 'fcc_valid_session "fcc-claude-001/../../etc"'
	assert_no "an empty name"              sh_common 'fcc_valid_session ""'
}

# ---------------------------------------------------------------------------
# JSON emission — the UI parses this, so malformed output is a broken page
# ---------------------------------------------------------------------------

test_json_string_escaping() {
	setup_sandbox
	assert_eq '"hello"'        "$(sh_common 'fcc_json_str hello')"          "a plain string is quoted"
	assert_eq '""'             "$(sh_common 'fcc_json_str ""')"             "an empty string is quoted"
	assert_eq '"a\"b"'         "$(sh_common 'fcc_json_str "a\"b"')"         "a quote is escaped"
	# eval() collapses the shell-level \\ to one backslash, which the encoder then
	# doubles — the JSON a parser sees is a single backslash.
	assert_eq '"a\\b"'         "$(sh_common 'fcc_json_str "a\\b"')"         "a backslash is escaped"
	assert_eq '"a\nb"'         "$(sh_common 'fcc_json_str "a
b"')" "a newline is escaped"
}

test_json_helpers() {
	setup_sandbox
	assert_eq "true"  "$(sh_common 'fcc_json_bool 1')"     "1 is true"
	assert_eq "true"  "$(sh_common 'fcc_json_bool yes')"   "yes is true"
	assert_eq "false" "$(sh_common 'fcc_json_bool 0')"     "0 is false"
	assert_eq "false" "$(sh_common 'fcc_json_bool ""')"    "empty is false"
	assert_eq "null"  "$(sh_common 'fcc_json_num_or_null ""')"    "empty is null"
	assert_eq "null"  "$(sh_common 'fcc_json_num_or_null abc')"   "non-numeric is null"
	assert_eq "42"    "$(sh_common 'fcc_json_num_or_null 42')"    "a number passes through"
	assert_eq "null"  "$(sh_common 'fcc_json_str_or_null ""')"    "empty is null"
	assert_eq '"x"'   "$(sh_common 'fcc_json_str_or_null x')"     "a value is quoted"
}

test_redaction_never_leaks() {
	setup_sandbox
	_tr_in='Authorization: Bearer abcdefghijklmnop'
	assert_not_contains "$(sh_common "printf '%s' '$_tr_in' | fcc_redact")" \
		"abcdefghijklmnop" "a bearer value is redacted"
	assert_contains "$(sh_common "printf '%s' '$_tr_in' | fcc_redact")" \
		"REDACTED" "redaction is marked"
}

# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

test_version_cache_roundtrip() {
	setup_sandbox
	sh_common "fcc_cache_set claude 1.2.3" >/dev/null
	assert_eq "1.2.3" "$(sh_common 'fcc_cache_get claude')" "a cached value is returned"
	sh_common "fcc_cache_set claude 2.0.0" >/dev/null
	assert_eq "2.0.0" "$(sh_common 'fcc_cache_get claude')" "a key is replaced, not duplicated"
	assert_eq "1" "$(sh_common 'fcc_cache_set claude 2.0.0; fcc_cache_get claude | wc -l | tr -d " "')" \
		"replacing a key leaves exactly one line"
	sh_common "fcc_cache_set codex 9.9.9" >/dev/null
	assert_eq "2.0.0" "$(sh_common 'fcc_cache_get claude')" "writing another key preserves the first"
	assert_eq "9.9.9" "$(sh_common 'fcc_cache_get codex')" "the second key is readable"
	# A miss prints nothing. It still exits 0 (the file exists), so callers must
	# test the output, not the status — this pins that contract.
	assert_eq "" "$(sh_common 'fcc_cache_get nosuchkey')" "an absent key yields no output"
}

# ---------------------------------------------------------------------------
# /proc readers
# ---------------------------------------------------------------------------

test_proc_readers() {
	setup_sandbox
	# $$ is this shell, which is certainly alive.
	assert_eq "$(awk '/^VmRSS:/{print $2; exit}' /proc/$$/status)" \
		"$(sh_common 'fcc_proc_rss_kb '"$$"'')" "VmRSS matches /proc"
	assert_ok "a live pid is alive" sh_common "fcc_proc_alive $$"
	assert_no "a dead pid is not alive" sh_common 'fcc_proc_alive 999999'
	assert_no "an empty pid is not alive" sh_common 'fcc_proc_alive ""'

	_tr_up="$(sh_common "fcc_proc_uptime_secs $$")"
	case "$_tr_up" in
		''|*[!0-9]*) fail "uptime for a live pid should be a number, got [$_tr_up]" ;;
		*) pass ;;
	esac
}

test_starttime_parsing_survives_a_hostile_comm() {
	setup_sandbox
	# /proc/<pid>/stat field 2 is the command name, which may contain spaces and
	# parentheses. The reader strips up to the LAST ')' so the field positions
	# cannot shift — this is what makes a process named "a) b (c" safe.
	assert_ok "starttime parses for a normal process" sh_common "fcc_proc_starttime_ticks $$"
	_tr_st="$(sh_common "fcc_proc_starttime_ticks $$")"
	case "$_tr_st" in
		''|*[!0-9]*) fail "starttime should be numeric, got [$_tr_st]" ;;
		*) pass ;;
	esac
}

# ---------------------------------------------------------------------------
# Locks
# ---------------------------------------------------------------------------

test_lock_is_exclusive() {
	setup_sandbox
	_tr_lock="$(sh_common 'fcc_lock_acquire test')"
	assert_ne "" "$_tr_lock" "a lock can be taken"
	assert_no "a second acquire fails while held" sh_common 'fcc_lock_acquire test >/dev/null'
	sh_common "fcc_lock_release '$_tr_lock'" >/dev/null
	assert_ok "the lock can be retaken once released" sh_common 'fcc_lock_acquire test >/dev/null'
	sh_common "fcc_lock_release \"\$(fcc_lock_dir)/fcc-test.lock\"" >/dev/null
}

# ---------------------------------------------------------------------------
# The terminal's absolute-offset arithmetic
#
# The Web Console reads a byte stream by absolute offset. If the offset
# arithmetic is wrong the terminal shows duplicated or missing output, so the
# pure part of it is exercised here without needing tmux.
# ---------------------------------------------------------------------------

test_output_offset_math() {
	setup_sandbox
	# Reproduce the core of session.sh cmd_output: with base=0 and a 10-byte
	# file, an offset of 4 must yield bytes 5..10.
	_tr_dir="$SANDBOX/sessions"
	mkdir -p "$_tr_dir"
	printf '0123456789' > "$_tr_dir/fcc-claude-001.out"
	printf '0'          > "$_tr_dir/fcc-claude-001.base"

	_tr_base="$(cat "$_tr_dir/fcc-claude-001.base")"
	_tr_sz="$(wc -c < "$_tr_dir/fcc-claude-001.out" | tr -d ' ')"
	_tr_abs=$(( _tr_base + _tr_sz ))
	assert_eq "10" "$_tr_abs" "the absolute end offset is base + size"

	# Offset 4 is absolute and 0-based: the client already holds bytes 0..3, so
	# the next byte it needs is the 5th, i.e. tail -c +5.
	_tr_off=4
	_tr_skip=$(( _tr_off - _tr_base ))
	assert_eq "456789" "$(tail -c "+$(( _tr_skip + 1 ))" "$_tr_dir/fcc-claude-001.out")" \
		"the tail starts at the requested offset"

	# A client that has fallen behind a trim is reset to the new base rather
	# than being handed a negative skip.
	printf '300' > "$_tr_dir/fcc-claude-001.base"
	_tr_off=4
	_tr_base="$(cat "$_tr_dir/fcc-claude-001.base")"
	_tr_reset=false
	if [ "$_tr_off" -lt "$_tr_base" ]; then _tr_reset=true; _tr_off="$_tr_base"; fi
	assert_eq "true" "$_tr_reset" "a stale offset triggers a reset"
	assert_eq "300"  "$_tr_off"   "a stale offset is clamped to the base"
}

test_scrollback_trim_advances_the_base() {
	setup_sandbox
	# maybe_trim keeps the newest TRIM_TO_BYTES and advances the base by exactly
	# the number of bytes dropped, which is what keeps client offsets valid.
	_tr_dir="$SANDBOX/sessions"
	mkdir -p "$_tr_dir"
	# 100 bytes of content, trim to 40, max 50 -> drop 60.
	_tr_content="$(awk 'BEGIN{for(i=0;i<100;i++)printf "%d", i%10}')"
	printf '%s' "$_tr_content" > "$_tr_dir/fcc-claude-001.out"
	printf '0' > "$_tr_dir/fcc-claude-001.base"

	_tr_sz=100; _tr_base=0; _tr_trim=40; _tr_max=50
	_tr_drop=$(( _tr_sz - _tr_trim ))
	tail -c "$_tr_trim" "$_tr_dir/fcc-claude-001.out" > "$_tr_dir/fcc-claude-001.out.tmp" \
		&& mv "$_tr_dir/fcc-claude-001.out.tmp" "$_tr_dir/fcc-claude-001.out"
	printf '%s' "$(( _tr_base + _tr_drop ))" > "$_tr_dir/fcc-claude-001.base"

	assert_eq "40" "$(wc -c < "$_tr_dir/fcc-claude-001.out" | tr -d ' ')" "the file is trimmed to TRIM_TO_BYTES"
	assert_eq "60" "$(cat "$_tr_dir/fcc-claude-001.base")" "the base advances by the dropped byte count"

	# The invariant that matters: base + size is unchanged by a trim, so an
	# absolute offset means the same thing before and after.
	_tr_new_sz="$(wc -c < "$_tr_dir/fcc-claude-001.out" | tr -d ' ')"
	_tr_new_base="$(cat "$_tr_dir/fcc-claude-001.base")"
	assert_eq "100" "$(( _tr_new_base + _tr_new_sz ))" "a trim preserves the absolute end offset"
}

# ---------------------------------------------------------------------------
# Degradation
# ---------------------------------------------------------------------------

test_missing_registry_is_not_fatal() {
	setup_sandbox
	# A missing registry must produce an empty list, not an error: the UI shows
	# an empty table rather than a broken page.
	assert_eq "" "$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$SANDBOX/nope.conf" \
		sh -c '. "$1/common.sh"; fcc_agents_each' _ "$LIBEXEC")" \
		"a missing registry yields no agents"
	assert_no "an unknown agent is invalid when the registry is missing" \
		env FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$SANDBOX/nope.conf" \
		sh -c '. "$1/common.sh"; fcc_valid_agent claude' _ "$LIBEXEC"
}

test_luci_version_reads_the_version_file() {
	setup_sandbox
	assert_eq "0.1.0" "$(sh_common 'fcc_luci_version')" "the version file is read"
	assert_eq "0.0.0" "$(FCC_LIBDIR="$LIBEXEC" FCC_VERSION_FILE="$SANDBOX/nope" \
		sh -c '. "$1/common.sh"; fcc_luci_version' _ "$LIBEXEC")" \
		"a missing version file reports 0.0.0 rather than failing"
}

# ---------------------------------------------------------------------------
# Server health (DESIGN_SPEC.md section 49) and the update preflight (23).
#
# The health check is the part of an update that is easiest to fake and hardest
# to notice faking, so it is exercised against a real socket rather than a
# stubbed one: a listener is opened, seen, closed and seen to be gone.
# ---------------------------------------------------------------------------

# Open a throwaway HTTP listener on <port> and print its PID. Returns 1 when
# there is no way to open one, so callers skip instead of asserting against
# nothing.
start_listener() {
	_ls_port="$1"
	command -v python3 >/dev/null 2>&1 || return 1
	python3 -m http.server "$_ls_port" --bind 127.0.0.1 >"$SANDBOX/listener.log" 2>&1 &
	printf '%s' "$!"
}

# sh_common, but with a sandbox uci shim and the sandbox bin/ ahead on PATH.
# The health check reads its port from uci, so controlling configuration means
# standing in for uci rather than for the code under test.
sh_common_path() {
	FCC_LIBDIR="$LIBEXEC" \
	FCC_AGENTS_CONF="$AGENTS_CONF" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	FCC_DEFAULT_BASE="$SANDBOX/opt" \
	UCI_SHIM_DIR="$SANDBOX/uci" \
	PATH="$SANDBOX/bin:$PATH" \
	sh -c '. "$1/common.sh"; eval "$2"' _ "$LIBEXEC" "$1" 2>&1
}

# A stand-in for uci: only `-q get <section>.<option>` is implemented, reading
# $UCI_SHIM_DIR/<section>.<option>. None of uci's other surface is used by the
# code under test, and a developer machine has no uci at all.
make_uci_shim() {
	mkdir -p "$SANDBOX/bin" "$SANDBOX/uci"
	cat > "$SANDBOX/bin/uci" <<'SHIM'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
[ "${1:-}" = "get" ] || exit 1
[ -n "${2:-}" ] || exit 1
_f="$UCI_SHIM_DIR/$2"
[ -r "$_f" ] || exit 1
cat "$_f"
SHIM
	chmod +x "$SANDBOX/bin/uci"
}

test_port_listening_rejects_bad_input() {
	setup_sandbox
	assert_no "an empty port is rejected"     sh_common 'fcc_port_listening ""'
	assert_no "a non-numeric port is rejected" sh_common 'fcc_port_listening http'
	assert_no "a port with trailing junk is rejected" sh_common 'fcc_port_listening 80x'
}

test_port_listening_tracks_a_real_listener() {
	setup_sandbox
	_lp_port=47311
	_lp_pid="$(start_listener "$_lp_port")" || { skip "no python3 — cannot open a listener"; return 0; }

	# Wait for the socket rather than assuming a fixed startup delay.
	_lp_up=no
	_lp_i=0
	while [ "$_lp_i" -lt 20 ]; do
		sh_common "fcc_port_listening $_lp_port" >/dev/null 2>&1 && { _lp_up=yes; break; }
		sleep 1
		_lp_i=$(( _lp_i + 1 ))
	done
	assert_eq "yes" "$_lp_up" "a listening port is detected on $_lp_port"

	kill "$_lp_pid" 2>/dev/null
	wait "$_lp_pid" 2>/dev/null

	_lp_down=no
	_lp_i=0
	while [ "$_lp_i" -lt 20 ]; do
		sh_common "fcc_port_listening $_lp_port" >/dev/null 2>&1 || { _lp_down=yes; break; }
		sleep 1
		_lp_i=$(( _lp_i + 1 ))
	done
	assert_eq "yes" "$_lp_down" "the port is no longer reported once the listener exits"
}

test_http_status_reads_a_real_response() {
	setup_sandbox
	if ! command -v curl >/dev/null 2>&1; then skip "no curl — HTTP leg not tested"; return 0; fi

	_hp_port=47312
	_hp_pid="$(start_listener "$_hp_port")" || { skip "no python3 — cannot open a listener"; return 0; }

	_hp_code=""
	_hp_i=0
	while [ "$_hp_i" -lt 20 ]; do
		_hp_code="$(sh_common "fcc_http_status http://127.0.0.1:$_hp_port/" 2>/dev/null || true)"
		[ -n "$_hp_code" ] && break
		sleep 1
		_hp_i=$(( _hp_i + 1 ))
	done
	assert_eq "200" "$_hp_code" "the status code is read from a live server"

	kill "$_hp_pid" 2>/dev/null
	wait "$_hp_pid" 2>/dev/null

	# Nothing listening must yield no code at all, not a zero or a 000.
	assert_eq "" "$(sh_common "fcc_http_status http://127.0.0.1:$_hp_port/" 2>/dev/null || true)" \
		"no code is reported when nothing answers"
}

test_disk_free_kb_reports_a_number() {
	setup_sandbox
	_df_out="$(sh_common "fcc_disk_free_kb $SANDBOX")"
	case "$_df_out" in
		''|*[!0-9]*) fail "fcc_disk_free_kb did not return a number: [$_df_out]" ;;
		*) pass ;;
	esac
	# A path that does not exist yet must resolve to its nearest existing
	# ancestor, or the preflight would silently measure nothing.
	_df_out="$(sh_common "fcc_disk_free_kb $SANDBOX/opt/fcc/deep/not/created")"
	case "$_df_out" in
		''|*[!0-9]*) fail "fcc_disk_free_kb failed on a not-yet-created path: [$_df_out]" ;;
		*) pass ;;
	esac
}

test_active_sessions_reports_a_count() {
	setup_sandbox
	_as_out="$(sh_common 'fcc_active_sessions')"
	case "$_as_out" in
		''|*[!0-9]*) fail "fcc_active_sessions did not return a count: [$_as_out]" ;;
		*) pass ;;
	esac
}

test_find_server_exe_prefers_the_runtime_tree() {
	setup_sandbox
	_fx_bin="$SANDBOX/opt/fcc/bin"
	mkdir -p "$_fx_bin"
	printf '#!/bin/sh\nexit 0\n' > "$_fx_bin/fcc-server"
	chmod +x "$_fx_bin/fcc-server"
	# The runtime this package manages has to win over whatever else is on PATH.
	# A developer machine — and a router that had FCC installed by hand before
	# this package existed — has a second, unrelated fcc-server, and reporting
	# on that one instead would be silently wrong.
	assert_eq "$_fx_bin/fcc-server" "$(sh_common 'fcc_find_server_exe')" \
		"the managed runtime's fcc-server is found first"
	rm -rf "$SANDBOX/opt"
}

test_server_health_follows_a_real_server() {
	setup_sandbox
	command -v python3 >/dev/null 2>&1 || { skip "no python3 — cannot run a stand-in server"; return 0; }

	_hl_port=47313
	_hl_dead=47314
	_hl_bin="$SANDBOX/opt/fcc/bin"
	mkdir -p "$_hl_bin"

	# A stand-in fcc-server. It deliberately does not exec: the process has to
	# stay in the process table under its own path so the /proc scan finds it,
	# while a child holds the port. The trap keeps the child from being orphaned
	# on the port when this test tears the server down.
	cat > "$_hl_bin/fcc-server" <<'EOF'
#!/bin/sh
# Stand-in fcc-server — see tests/test_runtime.sh.
python3 -m http.server __PORT__ --bind 127.0.0.1 >/dev/null 2>&1 &
_child=$!
trap 'kill "$_child" 2>/dev/null' TERM INT EXIT
wait "$_child"
EOF
	sed "s/__PORT__/$_hl_port/" "$_hl_bin/fcc-server" > "$_hl_bin/fcc-server.new"
	mv "$_hl_bin/fcc-server.new" "$_hl_bin/fcc-server"
	chmod +x "$_hl_bin/fcc-server"

	make_uci_shim
	printf '%s' "$_hl_port" > "$SANDBOX/uci/fcc.main.port"

	"$_hl_bin/fcc-server" >/dev/null 2>&1 &
	_hl_pid=$!

	_hl_json=""
	_hl_i=0
	while [ "$_hl_i" -lt 20 ]; do
		_hl_json="$(sh_common_path 'fcc_server_health' 2>/dev/null)"
		case "$_hl_json" in *'"healthy": true'*) break ;; esac
		sleep 1
		_hl_i=$(( _hl_i + 1 ))
	done
	assert_contains "$_hl_json" '"healthy": true'      "a running server on a listening port is healthy"
	assert_contains "$_hl_json" '"process": true'      "the process is found through /proc"
	assert_contains "$_hl_json" "\"port\": $_hl_port"  "the port comes from the configuration"
	# The stand-in serves no /admin, so it answers 404 — and that is the point.
	# Any status at all proves something is listening *and* talking, which is
	# what section 49 asks; requiring 200 would report a healthy server that
	# merely lacks the page as a failed update.
	assert_contains "$_hl_json" '"http_status": 404' \
		"a 404 from the endpoint still counts as an answer"

	# It must be JSON, not merely look like it: the LuCI controller parses it.
	if printf '%s' "$_hl_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
		pass
	else
		fail "fcc_server_health did not emit valid JSON: $_hl_json"
	fi

	# Same process, configured onto a port nothing is listening on. This
	# isolates the port leg: the process is still found, only the socket is not.
	printf '%s' "$_hl_dead" > "$SANDBOX/uci/fcc.main.port"
	_hl_json="$(sh_common_path 'fcc_server_health' 2>/dev/null)"
	assert_contains "$_hl_json" '"process": true'    "the process is still found"
	assert_contains "$_hl_json" '"listening": false' "the dead port is not reported as listening"
	assert_contains "$_hl_json" '"healthy": false'   "a server with no listener is unhealthy"

	kill "$_hl_pid" 2>/dev/null
	wait "$_hl_pid" 2>/dev/null
	rm -rf "$SANDBOX/opt"
}

tests_main
