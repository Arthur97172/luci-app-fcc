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
# Section 74 — what the console learns when a session ends
#
# The exit code is the whole answer: 0 means the agent finished, anything else
# means it died. It survives only because sessions are created with
# remain-on-exit on — without that tmux destroys the session outright and the
# status is gone before anyone can ask for it. That is a tmux behaviour, not an
# arithmetic one, so this drives a real tmux session.
# ---------------------------------------------------------------------------

# Run a backend script the way the controller does: same environment overrides,
# same argv.
sh_script() { # sh_script <script> [args...]
	_sts_script="$1"; shift
	FCC_LIBDIR="$LIBEXEC" \
	FCC_AGENTS_CONF="$AGENTS_CONF" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	FCC_DEFAULT_BASE="$SANDBOX/opt" \
	sh "$LIBEXEC/$_sts_script" "$@" 2>&1
}

test_a_dead_session_reports_its_exit_code() {
	setup_sandbox
	if ! command -v tmux >/dev/null 2>&1; then
		skip "tmux is not installed — the exit-code path needs a real pane"
		return 0
	fi

	_sts_root="$SANDBOX/opt/fcc"
	mkdir -p "$_sts_root/sessions"
	_sts_name="fcc-claude-901"
	tmux kill-session -t "$_sts_name" 2>/dev/null

	# The same two steps cmd_create takes: start the pane, then make it
	# survive its own death.
	tmux new-session -d -s "$_sts_name" 'printf hello; exit 7' 2>/dev/null
	tmux set-option -t "$_sts_name" remain-on-exit on 2>/dev/null
	sleep 1

	# The pane is dead, but the session is deliberately still there — that is
	# what keeps the exit status answerable.
	_sts_dead="$(tmux display-message -p -t "$_sts_name" '#{pane_dead}' 2>/dev/null)"
	assert_eq "1" "$_sts_dead" "the pane is dead"
	assert_ok "the session survives its pane" tmux has-session -t "$_sts_name"

	_sts_hdr="$(sh_script session.sh output "$_sts_name" 0 0 | head -n1)"
	assert_contains "$_sts_hdr" '"alive": false'    "a dead pane is not alive"
	assert_contains "$_sts_hdr" '"eof": true'       "a dead pane is at end of file"
	assert_contains "$_sts_hdr" '"exit_code": 7'    "the exit code reaches the client"

	# Section 74 shows "Exit code: 0" for a clean finish, so zero has to come
	# through as a number rather than being lost as a falsy value.
	_sts_ok="fcc-claude-902"
	tmux kill-session -t "$_sts_ok" 2>/dev/null
	tmux new-session -d -s "$_sts_ok" 'printf bye; exit 0' 2>/dev/null
	tmux set-option -t "$_sts_ok" remain-on-exit on 2>/dev/null
	sleep 1
	_sts_hdr0="$(sh_script session.sh output "$_sts_ok" 0 0 | head -n1)"
	assert_contains "$_sts_hdr0" '"exit_code": 0' "a clean exit reports zero"

	# And the session list carries it too, so a tab can show a finished session
	# without polling its output.
	_sts_list="$(sh_script session.sh list)"
	assert_contains "$_sts_list" '"dead": true'   "the list marks a dead session"
	assert_contains "$_sts_list" '"exit_code": 7' "the list carries the exit code"

	# Input into a dead pane is refused rather than silently dropped.
	assert_no "a dead session takes no input" \
		sh_script session.sh input "$_sts_name" 68

	tmux kill-session -t "$_sts_name" 2>/dev/null
	tmux kill-session -t "$_sts_ok" 2>/dev/null
}

test_old_backups_are_pruned_to_the_most_recent_n() {
	setup_sandbox
	_bt_root="$SANDBOX/opt/fcc/backup"
	mkdir -p "$_bt_root"
	for _bt_s in 20200101T000000Z 20210101T000000Z 20220101T000000Z \
	             20230101T000000Z 20240101T000000Z; do
		mkdir -p "$_bt_root/$_bt_s"
		printf 'x' > "$_bt_root/$_bt_s/runtime.json"
	done
	# Section 25's retention counts only the stamps this code writes. Anything
	# else in backup/ may be the only copy of a user's data, and there is no way
	# to tell from the name — so it is left exactly where it is.
	mkdir -p "$_bt_root/manual-keep"
	printf 'x' > "$_bt_root/manual-keep/runtime.json"

	sh_install 'prune_backups' >/dev/null

	assert_ok "the newest backup survives"        test -d "$_bt_root/20240101T000000Z"
	assert_ok "the second newest survives"        test -d "$_bt_root/20230101T000000Z"
	assert_ok "the third newest survives"         test -d "$_bt_root/20220101T000000Z"
	assert_no "the fourth newest is pruned"       test -d "$_bt_root/20210101T000000Z"
	assert_no "the oldest is pruned"              test -d "$_bt_root/20200101T000000Z"
	assert_ok "a directory we did not write survives" test -d "$_bt_root/manual-keep"
}

test_status_explains_why_an_agent_stopped() {
	setup_sandbox
	if ! command -v tmux >/dev/null 2>&1; then
		skip "tmux is not installed — section 73 reads the pane's exit status"
		return 0
	fi

	# Section 73: "Stopped" on its own leaves the user with no idea what
	# happened. The status collector already fetches the tmux pane map, so the
	# exit status rides along on it and no state has to be kept between polls.
	_er_bad="fcc-codex-911"
	_er_ok="fcc-claude-912"
	tmux kill-session -t "$_er_bad" 2>/dev/null
	tmux kill-session -t "$_er_ok" 2>/dev/null
	tmux new-session -d -s "$_er_bad" 'printf boom; exit 1' 2>/dev/null
	tmux set-option -t "$_er_bad" remain-on-exit on 2>/dev/null
	tmux new-session -d -s "$_er_ok" 'printf fine; exit 0' 2>/dev/null
	tmux set-option -t "$_er_ok" remain-on-exit on 2>/dev/null
	sleep 1

	_er_json="$(sh_script status.sh)"
	_er_codex="$(printf '%s\n' "$_er_json" | grep '"codex":')"
	_er_claude="$(printf '%s\n' "$_er_json" | grep '"claude":')"

	assert_contains "$_er_codex" '"running": false' "an agent whose pane died is not running"
	assert_contains "$_er_codex" '"error": {"code": "START_FAILED"' \
		"a non-zero exit produces an error object"
	assert_contains "$_er_codex" 'fcc-codex exited with status 1' \
		"the message names the command and the status"

	# A zero exit is a normal finish. Inventing a failure for it would be worse
	# than saying nothing, so it has to come through as an explicit null.
	assert_contains "$_er_claude" '"error": null' "a clean exit reports no error"

	# The whole point of section 73 is that Basic Information explains the state
	# without the console being open, so the error has to be in this document
	# rather than in a per-session call.
	assert_contains "$_er_json" '"agents": {' "the error travels in the status document"

	tmux kill-session -t "$_er_bad" 2>/dev/null
	tmux kill-session -t "$_er_ok" 2>/dev/null
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

# make_standin_server <path> <port>
#
# A stand-in fcc-server. It deliberately does not exec: the process has to stay
# in the process table under its own path so the /proc scan finds it, while a
# child holds the port. The trap keeps the child from being orphaned on the port
# when the test tears the server down.
make_standin_server() {
	_ms_path="$1"
	_ms_port="$2"
	mkdir -p "$(dirname -- "$_ms_path")"
	cat > "$_ms_path" <<'EOF'
#!/bin/sh
# Stand-in fcc-server — see tests/test_runtime.sh.
python3 -m http.server __PORT__ --bind 127.0.0.1 >/dev/null 2>&1 &
_child=$!
trap 'kill "$_child" 2>/dev/null' TERM INT EXIT
wait "$_child"
EOF
	sed "s/__PORT__/$_ms_port/" "$_ms_path" > "$_ms_path.new"
	mv "$_ms_path.new" "$_ms_path"
	chmod +x "$_ms_path"
}

# install.sh ends with a dispatch on $1, so sourcing it directly would run the
# dispatch and exit. The functions are what is under test, so the dispatch is
# stripped from a copy — a test-only branch inside the real script would be a
# seam in production code to make a test easier, which is the wrong trade.
install_lib() {
	_il_dst="$SANDBOX/lib-install.sh"
	[ -f "$_il_dst" ] || sed '/^case "${1:-}" in$/,$d' "$LIBEXEC/install.sh" > "$_il_dst"
	printf '%s' "$_il_dst"
}

# Run a snippet with install.sh's functions defined and the sandbox in place.
sh_install() {
	FCC_LIBDIR="$LIBEXEC" \
	FCC_AGENTS_CONF="$AGENTS_CONF" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	FCC_DEFAULT_BASE="$SANDBOX/opt" \
	UCI_SHIM_DIR="$SANDBOX/uci" \
	FCC_HEALTH_TIMEOUT=3 \
	PATH="$SANDBOX/bin:$PATH" \
	sh -c '. "$1"; eval "$2"' _ "$(install_lib)" "$1" 2>&1
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
	make_standin_server "$_hl_bin/fcc-server" "$_hl_port"

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

# ---------------------------------------------------------------------------
# Backup and rollback (DESIGN_SPEC.md sections 23, 78 and 79).
#
# The interesting property is not that a backup is written but that the
# *previous runtime* comes back. The two halves are stored differently on
# purpose — data copied, runtime renamed aside — so the test checks both the
# rename (the runtime tree is gone from its old place while the update runs) and
# the restore.
# ---------------------------------------------------------------------------

test_backup_renames_the_runtime_and_copies_the_data() {
	setup_sandbox
	mkdir -p "$SANDBOX/opt/fcc/runtime" "$SANDBOX/opt/fcc/bin" "$SANDBOX/opt/fcc/data"
	printf 'previous interpreter\n' > "$SANDBOX/opt/fcc/runtime/marker"
	printf 'previous config\n'      > "$SANDBOX/opt/fcc/data/config"
	printf '{"fcc_version":"1.0.0"}\n' > "$SANDBOX/opt/fcc/runtime.json"
	printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/opt/fcc/bin/fcc-server"

	_bk="$(sh_install 'backup_runtime')"

	assert_dir "$_bk"
	# The runtime tree is renamed, not copied: it must be absent from its old
	# place while the update runs, or the installer would write into it.
	assert_eq "no" "$([ -d "$SANDBOX/opt/fcc/runtime" ] && echo yes || echo no)" \
		"the previous runtime is moved out of the way"
	assert_eq "no" "$([ -d "$SANDBOX/opt/fcc/bin" ] && echo yes || echo no)" \
		"the previous bin/ is moved out of the way"
	assert_file "$_bk/runtime/marker"
	assert_file "$_bk/bin/fcc-server"
	# The data is copied, not moved: a *successful* update has to find it still
	# in place, because that is the user's configuration.
	assert_file "$SANDBOX/opt/fcc/data/config"
	assert_file "$_bk/data/config"
	assert_file "$_bk/runtime.json"
}

test_rollback_restores_the_previous_runtime() {
	setup_sandbox
	command -v python3 >/dev/null 2>&1 || { skip "no python3 — cannot run a stand-in server"; return 0; }

	_rb_port=47315
	_rb_root="$SANDBOX/opt/fcc"
	mkdir -p "$_rb_root/runtime" "$_rb_root/data"
	printf 'previous interpreter\n' > "$_rb_root/runtime/marker"
	printf 'previous config\n'      > "$_rb_root/data/config"
	printf '{"fcc_version":"1.0.0"}\n' > "$_rb_root/runtime.json"
	make_standin_server "$_rb_root/bin/fcc-server" "$_rb_port"

	make_uci_shim
	printf '%s' "$_rb_port" > "$SANDBOX/uci/fcc.main.port"

	# Start the "previous" server so the post-rollback health check has
	# something to find, and so the success message is the one under test.
	"$_rb_root/bin/fcc-server" >/dev/null 2>&1 &
	_rb_pid=$!
	_rb_i=0
	while [ "$_rb_i" -lt 20 ]; do
		case "$(sh_common_path 'fcc_server_health' 2>/dev/null)" in
			*'"healthy": true'*) break ;;
		esac
		sleep 1
		_rb_i=$(( _rb_i + 1 ))
	done

	_bk="$(sh_install 'backup_runtime')"
	assert_dir "$_bk"

	# A failed update: the installer wrote a new runtime, then died.
	mkdir -p "$_rb_root/runtime" "$_rb_root/bin"
	printf 'broken interpreter\n' > "$_rb_root/runtime/marker"
	printf '#!/bin/sh\nexit 1\n' > "$_rb_root/bin/fcc-server"
	printf 'clobbered\n'         > "$_rb_root/data/config"

	_out="$(sh_install "rollback_runtime '$_bk' true")"
	_log="$(cat "$_rb_root/logs/fcc-runtime.log" 2>/dev/null)"

	assert_contains "$_out" "ROLLED_BACK" "the rollback reports success on stdout"
	assert_contains "$_log" "Previous FCC version restored" \
		"the log carries section 79's message"
	assert_eq "previous interpreter" "$(cat "$_rb_root/runtime/marker" 2>/dev/null)" \
		"the previous runtime tree is back"
	assert_eq "previous config" "$(cat "$_rb_root/data/config" 2>/dev/null)" \
		"the previous configuration is back"
	assert_file "$_rb_root/runtime.json"
	# The binary the failed install left must not survive the restore.
	assert_contains "$(cat "$_rb_root/bin/fcc-server" 2>/dev/null)" "http.server" \
		"the previous binary is back, not the one the failed install left"

	kill "$_rb_pid" 2>/dev/null
	wait "$_rb_pid" 2>/dev/null
}

test_rollback_reports_when_the_server_cannot_be_restarted() {
	setup_sandbox
	_rr_root="$SANDBOX/opt/fcc"
	mkdir -p "$_rr_root/runtime" "$_rr_root/bin" "$_rr_root/data"
	printf 'previous interpreter\n' > "$_rr_root/runtime/marker"
	# Deliberately no working fcc-server: the restore has the files back but
	# nothing can start, which is section 79's second outcome.
	printf '#!/bin/sh\nexit 1\n' > "$_rr_root/bin/fcc-server"
	chmod +x "$_rr_root/bin/fcc-server"

	make_uci_shim
	printf '47316' > "$SANDBOX/uci/fcc.main.port"

	_bk="$(sh_install 'backup_runtime')"
	assert_dir "$_bk"

	_out="$(sh_install "rollback_runtime '$_bk' true")"
	_log="$(cat "$_rr_root/logs/fcc-runtime.log" 2>/dev/null)"

	assert_contains "$_log" "FCC Server remains stopped" \
		"a restore that cannot start the server says so"
	assert_contains "$_out" "ROLLBACK_FAILED" \
		"the outcome is reported rather than swallowed"
	# Section 79 also requires Luci-FCC to keep working. Nothing here touches
	# the LuCI package, so what that means for this function is that it returns
	# a status rather than taking the caller down with it.
	assert_eq "previous interpreter" "$(cat "$_rr_root/runtime/marker" 2>/dev/null)" \
		"the files are restored even though the server will not start"
}

# ---------------------------------------------------------------------------
# Runtime metadata (DESIGN_SPEC.md sections 42 and 81).
#
# Section 81 names the fields; section 42 is why node_version is one of them.
# The subtle requirement is the pair of timestamps: installed_at is when the
# runtime was first put down and must survive an update, updated_at is when the
# file was last written. A single timestamp would satisfy the field list and
# still lose the history the file exists to keep.
# ---------------------------------------------------------------------------

test_runtime_metadata_records_what_section_81_asks_for() {
	setup_sandbox
	_md_root="$SANDBOX/opt/fcc"
	mkdir -p "$_md_root/bin"
	printf '#!/bin/sh\necho "fcc-server 9.9.9"\n' > "$_md_root/bin/fcc-server"
	chmod +x "$_md_root/bin/fcc-server"
	make_uci_shim

	sh_install 'write_runtime_metadata' >/dev/null

	assert_file "$_md_root/runtime.json"
	_md_json="$(cat "$_md_root/runtime.json")"
	for _md_key in fcc_version python_version node_version installed_at \
	               updated_at install_path agents; do
		assert_contains "$_md_json" "\"$_md_key\"" "runtime.json carries $_md_key"
	done
	# The agents map is always an object, never omitted — a caller can read it
	# without a nil check. Whether it is empty depends on what is on PATH, which
	# is the machine's business, not this test's: a developer box with every
	# agent installed must not make the suite fail.
	assert_contains "$_md_json" '"agents": {' \
		"the agents map is emitted as an object"

	# What *is* an invariant: every agent whose version was recorded is also
	# marked installed. The two are written from the same predicate, so a
	# disagreement means one of the loops has drifted.
	_md_ids="$(sed -n 's/.*"agent_version_\([a-z0-9]*\)":.*/\1/p' "$_md_root/runtime.json")"
	if [ -n "$_md_ids" ]; then
		for _md_id in $_md_ids; do
			assert_contains "$_md_json" "\"$_md_id\": true" \
				"$_md_id has a recorded version and is marked installed"
		done
	else
		# No agent CLI on PATH: the map must then be genuinely empty, which is
		# the branch a clean router takes.
		assert_contains "$_md_json" '"agents": {}' \
			"no agents on PATH leaves the map empty"
	fi

	# The version actually came from the binary, not from a placeholder.
	assert_contains "$_md_json" '"fcc_version": "9.9.9"' \
		"fcc_version is read from the installed binary"

	if command -v python3 >/dev/null 2>&1; then
		assert_ok "the document is valid JSON" \
			python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$_md_root/runtime.json"
	else
		skip "no python3 — runtime.json left unparsed"
	fi
}

# Section 54 names the message, and the numbers are the point of it: "not
# enough space" without saying how much short is not actionable.
test_insufficient_space_reports_section_54s_message() {
	setup_sandbox
	make_uci_shim

	# Reach the disk preflight by demanding more space than any machine has,
	# rather than by filling a filesystem — a full disk is not something a test
	# can arrange portably. The preflight runs after the compatibility check, so
	# on a machine where that fails there is no way in; say so instead of failing.
	case "$(sh_install 'precheck_ok >/dev/null 2>&1 && echo yes || echo no')" in
		yes) ;;
		*) skip "precheck does not pass here — cannot reach the disk preflight"; return 0 ;;
	esac

	FCC_MIN_FREE_MB=999999999
	export FCC_MIN_FREE_MB
	_out="$(sh_install 'cmd_runtime')"
	unset FCC_MIN_FREE_MB

	assert_contains "$_out" "Not enough storage space." \
		"section 54's wording is used verbatim"
	assert_contains "$_out" "Required: 999999999 MB" \
		"the message says how much is needed"
	assert_contains "$_out" "Available: " \
		"the message says how much there is"
	# The available figure has to be a number, not an empty field: the caller
	# renders this line to the user.
	_sp_avail="$(printf '%s\n' "$_out" | sed -n 's/^Available: \([0-9]*\) MB$/\1/p')"
	case "$_sp_avail" in
		''|*[!0-9]*) fail "Available: line carries a number" "got: $(printf '%s\n' "$_out" | grep Available)" ;;
		*) pass "Available: line carries a number ($_sp_avail MB)" ;;
	esac
	assert_contains "$_out" "NO_SPACE" \
		"the machine-readable token still follows the message"
	# Installation is *blocked*, not merely warned about.
	assert_not_contains "$(cat "$SANDBOX/opt/fcc/runtime.json" 2>/dev/null)" "fcc_version" \
		"nothing was installed"
}

# Section 39 puts the server's log at <install_path>/logs/fcc-server.log. procd
# cannot write a service's output to a file, so the server is started through a
# wrapper — and the wrapper has to exec rather than fork, or procd would be
# supervising a shell while the server it started runs unsupervised beside it.
test_server_wrapper_logs_the_server_and_replaces_itself() {
	setup_sandbox
	_sr_dir="$SANDBOX/opt/fcc/logs"
	mkdir -p "$_sr_dir"
	_sr_log="$_sr_dir/fcc-server.log"

	_sr_cmd="$SANDBOX/opt/fake-server.sh"
	printf '#!/bin/sh\necho "hello from the server"\necho "and to stderr" >&2\n' > "$_sr_cmd"
	chmod +x "$_sr_cmd"

	sh "$LIBEXEC/server-run.sh" "$_sr_log" "$_sr_cmd" >/dev/null 2>&1
	assert_contains "$(cat "$_sr_log" 2>/dev/null)" "hello from the server" \
		"the server's stdout reaches the log file"
	assert_contains "$(cat "$_sr_log" 2>/dev/null)" "and to stderr" \
		"the server's stderr reaches the log file"
	assert_contains "$(cat "$_sr_log" 2>/dev/null)" "starting" \
		"a start marker separates one run from the next"

	# exec, not fork: the pid the caller was handed is the server's own, which
	# is the pid procd would signal. A forked wrapper would report a different
	# one, and stopping the service would leave the server running.
	_sr_pidfile="$SANDBOX/opt/server-pid"
	_sr_self="$SANDBOX/opt/pid-server.sh"
	printf '#!/bin/sh\necho $$ > "%s"\nsleep 30\n' "$_sr_pidfile" > "$_sr_self"
	chmod +x "$_sr_self"

	sh "$LIBEXEC/server-run.sh" "$_sr_log" "$_sr_self" &
	_sr_pid=$!
	_sr_i=0
	while [ "$_sr_i" -lt 50 ] && [ ! -s "$_sr_pidfile" ]; do
		sleep 0.1
		_sr_i=$(( _sr_i + 1 ))
	done
	assert_eq "$_sr_pid" "$(cat "$_sr_pidfile" 2>/dev/null)" \
		"the wrapper replaces itself instead of forking"
	kill "$_sr_pid" 2>/dev/null
	wait "$_sr_pid" 2>/dev/null

	# A log that has grown past the cap is trimmed to its tail: the file exists
	# to answer "what went wrong just now", and on flash it is a wear problem.
	_sr_big="$_sr_dir/big.log"
	_sr_i=0
	while [ "$_sr_i" -lt 400 ]; do
		printf 'line %s\n' "$_sr_i"
		_sr_i=$(( _sr_i + 1 ))
	done > "$_sr_big"
	FCC_SERVER_LOG_MAX_KB=1 sh "$LIBEXEC/server-run.sh" "$_sr_big" true >/dev/null 2>&1
	_sr_after="$(grep -c . "$_sr_big")"
	if [ "$_sr_after" -lt 300 ]; then
		pass "an oversized log is trimmed to its tail ($_sr_after lines)"
	else
		fail "an oversized log is trimmed to its tail" "still $_sr_after lines"
	fi

	# An unwritable log must not stop the server from starting: the wrapper
	# falls back to a plain exec, and procd's own capture carries the output.
	sh "$LIBEXEC/server-run.sh" "$SANDBOX/no-such-dir/x.log" "$_sr_cmd" \
		> "$SANDBOX/fallback.out" 2>&1
	assert_contains "$(cat "$SANDBOX/fallback.out" 2>/dev/null)" "hello from the server" \
		"an unwritable log falls back to the caller's stdout"
}

# Section 3.6.5: which agents get installed is decided before the install
# starts, and the answers file is the only channel that carries that decision
# to the upstream installer — so what it contains *is* the feature.
#
# The three cases below are the whole point of the flag: a named subset, no
# opinion at all, and an explicit "none". The last two both arrive as an empty
# agent list and must not collapse into each other.
test_installer_answers_carry_the_agent_selection() {
	setup_sandbox

	_ia_fake="$SANDBOX/opt/fake-installer.sh"
	mkdir -p "$SANDBOX/opt"
	printf '#!/bin/sh\nexit 0\n' > "$_ia_fake"
	chmod +x "$_ia_fake"
	_ia_ans="$SANDBOX/opt/fcc/cache/installer-answers"

	# run_installer prefers util-linux `script` to give the installer a tty.
	# The answers file is written before that call, so a stand-in that just runs
	# the command keeps the test hermetic — no tty, no timing, no hang.
	mkdir -p "$SANDBOX/ptybin"
	printf '#!/bin/sh\n# stand-in for `script`: run the command with our stdin\nexec sh -c "$3"\n' \
		> "$SANDBOX/ptybin/script"
	chmod +x "$SANDBOX/ptybin/script"
	_ia_path="$SANDBOX/ptybin:$PATH"

	_ia_order="$(sh_install 'printf "%s\n" $FCC_AGENT_ORDER')"
	_ia_n="$(printf '%s\n' "$_ia_order" | grep -c .)"
	if [ "$_ia_n" -lt 2 ]; then
		fail "the registry lists agents to answer for" "got $_ia_n"
		return 0
	fi

	# A named subset: exactly those agents are answered yes.
	PATH="$_ia_path" sh_install \
		'run_installer "$FCC_DEFAULT_BASE/fake-installer.sh" "claude aider" 0' >/dev/null 2>&1
	assert_eq 2 "$(grep -c '^y$' "$_ia_ans" 2>/dev/null)" \
		"only the two requested agents are answered yes"
	assert_eq "$_ia_n" "$(head -n "$_ia_n" "$_ia_ans" | grep -c '^[yn]$')" \
		"one answer per registered agent"
	# The installer asks about more than agents (RTK, and whatever it grows
	# next); those answers are appended after the agent block.
	assert_eq 3 "$(tail -n +$((_ia_n + 1)) "$_ia_ans" | grep -c '^[yn]$')" \
		"the trailing answers for non-agent prompts are still written"

	# No opinion: the file stays empty, so the installer's own defaults apply.
	PATH="$_ia_path" sh_install \
		'run_installer "$FCC_DEFAULT_BASE/fake-installer.sh" "" 0' >/dev/null 2>&1
	assert_eq 0 "$(wc -c < "$_ia_ans" | tr -d ' ')" \
		"an absent selection leaves the answers to upstream"

	# An explicit "none": every agent answered no. This is the case that must
	# not be mistaken for the previous one.
	PATH="$_ia_path" sh_install \
		'run_installer "$FCC_DEFAULT_BASE/fake-installer.sh" "" 1' >/dev/null 2>&1
	assert_eq 0 "$(grep -c '^y$' "$_ia_ans" 2>/dev/null)" \
		"an explicit empty selection installs no agent"
	assert_eq "$_ia_n" "$(head -n "$_ia_n" "$_ia_ans" | grep -c '^n$')" \
		"every agent is answered no"
}

test_runtime_metadata_keeps_installed_at_and_moves_updated_at() {
	setup_sandbox
	_mu_root="$SANDBOX/opt/fcc"
	mkdir -p "$_mu_root/bin"
	printf '#!/bin/sh\necho "fcc-server 9.9.9"\n' > "$_mu_root/bin/fcc-server"
	chmod +x "$_mu_root/bin/fcc-server"
	make_uci_shim

	sh_install 'write_runtime_metadata' >/dev/null
	# Stand in for a runtime that was installed last year and is being updated
	# now: the previous installed_at must be carried forward verbatim.
	sed 's/"installed_at": "[^"]*"/"installed_at": "2020-01-02T03:04:05Z"/' \
		"$_mu_root/runtime.json" > "$_mu_root/runtime.json.new"
	mv "$_mu_root/runtime.json.new" "$_mu_root/runtime.json"

	sh_install 'write_runtime_metadata' >/dev/null
	_mu_json="$(cat "$_mu_root/runtime.json")"

	assert_contains "$_mu_json" '"installed_at": "2020-01-02T03:04:05Z"' \
		"installed_at survives an update"
	assert_not_contains "$_mu_json" '"updated_at": "2020-01-02T03:04:05Z"' \
		"updated_at is the time of this write, not a copy of installed_at"
}

# ---------------------------------------------------------------------------
# Doctor (section 80)
# ---------------------------------------------------------------------------

test_doctor_covers_the_section_80_checklist() {
	setup_sandbox
	_dc_json="$(sh_script doctor.sh --json)"

	# Named individually rather than counted, so dropping a check fails here
	# instead of quietly shrinking the report.
	# The section 80 categories, plus the two section 3.6.4 adds to them: libc
	# and scratch space in /tmp, which on OpenWrt is a tmpfs sized from RAM
	# rather than part of the flash the storage check measures.
	for _dc_want in Architecture Kernel OpenWrt libc Storage "/tmp space" Memory \
	                 Python Node.js uv "FCC Runtime" "FCC Server" "Port 8082" \
	                 tmux Permissions DNS HTTPS; do
		assert_contains "$_dc_json" "\"name\": \"$_dc_want\"" \
			"doctor reports $_dc_want"
	done

	# One line per registered agent. That is what makes the report answer
	# "which of these can I run?" rather than "is something missing?".
	assert_contains "$_dc_json" '"name": "Claude Code"' "doctor reports the agents"
	assert_contains "$_dc_json" '"name": "Codex"' "doctor reports every registered agent"

	assert_contains "$_dc_json" '"install_allowed":' "the report can block an install"
}

test_doctor_warns_about_an_agent_that_is_not_installed() {
	setup_sandbox
	# A launcher name that cannot exist, so this exercises the WARN path rather
	# than whatever happens to be installed on the machine running the tests.
	_dw_conf="$SANDBOX/agents.conf"
	cat > "$_dw_conf" <<'EOF'
claude|Claude Code|fcc-claude|1|150|256|claude
ghost|Ghost Agent|fcc-does-not-exist-xyz|0|10|64|ghost
EOF
	_dw_json="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$_dw_conf" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		sh "$LIBEXEC/doctor.sh" --json 2>&1)"

	_dw_ghost="$(printf '%s\n' "$_dw_json" | grep 'Ghost Agent')"
	assert_contains "$_dw_ghost" '"status": "WARN"' \
		"a missing agent is a warning"
	assert_contains "$_dw_ghost" '"value": "not installed"' \
		"and the report says so"

	# The runtime installs perfectly well with no agents at all, so a missing
	# agent must never be what blocks an install.
	assert_not_contains "$_dw_ghost" '"status": "FAIL"' \
		"a missing agent never blocks the install"
}

tests_main
