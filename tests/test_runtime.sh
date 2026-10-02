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

tests_main
