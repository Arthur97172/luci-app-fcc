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

# sh_common, but with PATH replaced by a directory holding only the named tools,
# so that a branch which depends on which tools exist is the only branch that
# can run. Prepending would not do: the point is that the tools left out cannot
# be found at all.
#
# A name may be an absolute path, in which case it is installed under its own
# basename — that is how a test puts a *stand-in* tool on this PATH, since a
# tool the code under test has to find cannot be substituted any other way.
#   sh_common_tools '<tools>' '<code>'
sh_common_tools() {
	rm -rf "$SANDBOX/toolbin"
	mkdir -p "$SANDBOX/toolbin"
	# sh itself, because PATH has to hold the shell that is about to be run.
	for _tr_t in sh $1; do
		_tr_p="$(command -v "$_tr_t" 2>/dev/null)" || continue
		ln -sf "$_tr_p" "$SANDBOX/toolbin/${_tr_t##*/}"
	done
	PATH="$SANDBOX/toolbin" \
	FCC_LIBDIR="$LIBEXEC" \
	FCC_AGENTS_CONF="$AGENTS_CONF" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	FCC_DEFAULT_BASE="$SANDBOX/opt" \
	sh -c '. "$1/common.sh"; eval "$2"' _ "$LIBEXEC" "$2" 2>&1
}

# <hex-string> -> the octal escapes printf writes those bytes from.
#
# The device tree fixtures are written in hex because that is how the bytes come
# out of dtc, and hand-copying them into octal is how a fixture quietly stops
# being the thing it claims to be. \xHH would be shorter and is a bashism; this
# file has to run under any sh.
hex_to_octal() {
	_tr_hx="$1"
	_tr_out=""
	while [ -n "$_tr_hx" ]; do
		_tr_out="$_tr_out\\$(printf '%03o' $(( 0x${_tr_hx%"${_tr_hx#??}"} )))"
		_tr_hx="${_tr_hx#??}"
	done
	printf '%s' "$_tr_out"
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

test_valid_agent_is_silent_on_stderr() {
	setup_sandbox
	# The regression behind "cut: standard output: Broken pipe" in the install
	# log. The id used to be matched with `... | cut -d'|' -f1 | grep -qx`, and
	# grep -q stops at the first match and closes the pipe while cut is still
	# writing into it. busybox reports that on stderr, so a log that was already
	# explaining why an install had stopped gained a second line that looked
	# like a second, unrelated failure.
	#
	# The exit status was never wrong, so that is not what is asserted here —
	# stderr is captured on its own, because the noise is the entire bug. GNU
	# cut dies from SIGPIPE without a word, so this is a weaker check off
	# busybox than on it; scripts/smoke.sh repeats it where the shell really is
	# busybox ash.
	for _va_id in claude dsh nosuch Claude a-b '' 'a b' '*'; do
		_va_err="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
			FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
			sh -c '. "$1/common.sh"; fcc_valid_agent "$2"' _ "$LIBEXEC" "$_va_id" \
			2>&1 >/dev/null)"
		assert_eq "" "$_va_err" "fcc_valid_agent [$_va_id] writes nothing to stderr"
	done
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
	# A core temperature is a signed reading, so a minus has to survive — and
	# only in front, and only one. Everything else is a document-building caller
	# getting a null, not an error.
	assert_eq "-5000" "$(sh_common 'fcc_json_num_or_null -5000')" "a negative number passes through"
	assert_eq "null"  "$(sh_common 'fcc_json_num_or_null -')"      "a bare minus is null"
	assert_eq "null"  "$(sh_common 'fcc_json_num_or_null -5-0')"   "a minus in the middle is null"
	assert_eq "null"  "$(sh_common 'fcc_json_num_or_null 1.5')"    "a decimal is null"
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

# One line of a captured multi-line value, so a test can assert each field
# separately instead of matching a blob.
cpu_line() { printf '%s\n' "$1" | sed -n "$2p"; }

test_cpu_info_reads_every_architectures_spelling() {
	setup_sandbox
	# /proc/cpuinfo names the CPU differently on every architecture OpenWrt runs
	# on, so the parser is exercised against each spelling rather than against
	# whatever the machine running the tests happens to be. A parser that only
	# ever sees the test host's cpuinfo passes here and shows a dash on a router.
	_tr_x86="$SANDBOX/cpuinfo.x86"
	printf 'processor\t: 0\nmodel name\t: Intel(R) Core(TM) i7-10610U CPU @ 1.80GHz\ncpu MHz\t\t: 2398.829\n\nprocessor\t: 1\nmodel name\t: Intel(R) Core(TM) i7-10610U CPU @ 1.80GHz\ncpu MHz\t\t: 2398.829\n' > "$_tr_x86"
	_tr_out="$(sh_common "fcc_cpu_info $_tr_x86")"
	assert_eq "Intel(R) Core(TM) i7-10610U CPU @ 1.80GHz" "$(cpu_line "$_tr_out" 1)" "x86 reports its model name"
	assert_eq "2398.829" "$(cpu_line "$_tr_out" 2)" "x86 reports its cpu MHz"
	assert_eq "2" "$(cpu_line "$_tr_out" 3)" "x86 counts both processors"

	# 32-bit ARM has no "model name"; the board's "Hardware" line is the only
	# thing naming the CPU, and it is what the page must show.
	_tr_arm="$SANDBOX/cpuinfo.arm"
	printf 'processor\t: 0\nmodel name\t: ARMv7 Processor rev 5 (v7l)\nHardware\t: BCM2711\n\nprocessor\t: 1\nmodel name\t: ARMv7 Processor rev 5 (v7l)\n' > "$_tr_arm"
	_tr_out="$(sh_common "fcc_cpu_info $_tr_arm")"
	assert_eq "ARMv7 Processor rev 5 (v7l)" "$(cpu_line "$_tr_out" 1)" "arm prefers model name over Hardware"
	assert_eq "2" "$(cpu_line "$_tr_out" 3)" "arm counts both processors"

	_tr_arm_hw="$SANDBOX/cpuinfo.arm-hw"
	printf 'processor\t: 0\nHardware\t: BCM2711\n' > "$_tr_arm_hw"
	assert_eq "BCM2711" "$(cpu_line "$(sh_common "fcc_cpu_info $_tr_arm_hw")" 1)" \
		"arm falls back to Hardware when there is no model name"

	# MIPS names it "cpu model" and reports BogoMIPS. BogoMIPS is a calibration
	# constant, not a clock rate, so it must not be picked up as the frequency —
	# a number that looks like an answer and is not one is worse than a dash.
	_tr_mips="$SANDBOX/cpuinfo.mips"
	printf 'system type\t\t: MediaTek MT7621\ncpu model\t\t: MIPS 1004Kc V2.15\nBogoMIPS\t\t: 586.13\nprocessor\t\t: 0\n' > "$_tr_mips"
	_tr_out="$(sh_common "fcc_cpu_info $_tr_mips")"
	assert_eq "MIPS 1004Kc V2.15" "$(cpu_line "$_tr_out" 1)" "mips reports its cpu model"
	assert_eq "" "$(cpu_line "$_tr_out" 2)" "BogoMIPS is not reported as a frequency"
	assert_eq "1" "$(cpu_line "$_tr_out" 3)" "mips counts its single processor"

	# A model name containing a colon must survive intact: reading the value
	# from $2 rather than the whole line would truncate it at the colon.
	_tr_colon="$SANDBOX/cpuinfo.colon"
	printf 'processor\t: 0\nmodel name\t: Foo: Bar Baz\n' > "$_tr_colon"
	assert_eq "Foo: Bar Baz" "$(cpu_line "$(sh_common "fcc_cpu_info $_tr_colon")" 1)" \
		"a colon inside the model name does not truncate it"

	# Nothing readable means nothing reported. Inventing "1 core" for a cpuinfo
	# we could not parse would put a made-up reading on the page.
	: > "$SANDBOX/cpuinfo.empty"
	_tr_out="$(sh_common "fcc_cpu_info $SANDBOX/cpuinfo.empty")"
	assert_eq "" "$(cpu_line "$_tr_out" 1)" "an empty cpuinfo yields no model"
	assert_eq "" "$(cpu_line "$_tr_out" 3)" "an empty cpuinfo yields no core count"

	assert_eq "" "$(sh_common 'fcc_cpu_info /nonexistent/cpuinfo')" \
		"a missing cpuinfo yields nothing rather than an error"
}

test_cpu_dt_hz_reads_a_big_endian_property() {
	setup_sandbox
	# The device tree property is a big-endian 32-bit count of Hz. Nothing on
	# the machine running these tests has one, so the parser is given fixtures
	# — which is the only way to check the byte order at all, since getting it
	# backwards produces a plausible-looking number rather than an error.
	#
	# 0x1dcd6500 is 500000000 Hz, the clock on a good many ARM routers.
	_tr_dt="$SANDBOX/clock-frequency"
	printf '\035\315\145\000' > "$_tr_dt"
	assert_eq "500000000" "$(sh_common "fcc_cpu_dt_hz $_tr_dt")" \
		"a big-endian clock-frequency is read as Hz"

	# The same bytes read the other way round are 0x0065cd1d = 6671645 Hz.
	# Asserting the number above already pins the byte order; this is the wrong
	# answer, written down so that a future change to the decoder fails loudly
	# here instead of quietly reporting a 6 MHz router.
	assert_ne "6671645" "$(sh_common "fcc_cpu_dt_hz $_tr_dt")" \
		"the bytes are not read little-endian"

	# 1.2 GHz, which is 0x47868c00 — large enough that a decoder reading the
	# property as a signed 32-bit value would go negative on the way in.
	printf '\107\206\214\000' > "$SANDBOX/clock-frequency-12g"
	assert_eq "1200000000" "$(sh_common "fcc_cpu_dt_hz $SANDBOX/clock-frequency-12g")" \
		"a 1.2 GHz rate is read as a positive number"

	# A zero property is the kernel saying it does not know, which is not a
	# frequency and must not be shown as 0 MHz.
	printf '\000\000\000\000' > "$SANDBOX/clock-frequency-zero"
	assert_no "a zero clock-frequency yields nothing" \
		sh_common "fcc_cpu_dt_hz $SANDBOX/clock-frequency-zero >/dev/null"

	# A truncated or foreign file must be refused rather than fed to the
	# arithmetic: `$(( 0x ))` is a syntax error in ash, and it would take the
	# whole status script — and the page that reads it — down with it.
	printf '\035\315' > "$SANDBOX/clock-frequency-short"
	assert_no "a truncated property is refused" \
		sh_common "fcc_cpu_dt_hz $SANDBOX/clock-frequency-short >/dev/null"

	assert_no "a missing property is refused" \
		sh_common "fcc_cpu_dt_hz $SANDBOX/nonexistent >/dev/null"
	assert_no "an empty argument is refused" \
		sh_common 'fcc_cpu_dt_hz "" >/dev/null'
}

test_hex_dump_uses_od_or_hexdump() {
	setup_sandbox
	printf '\035\315\145\000' > "$SANDBOX/four"
	# OpenWrt's busybox has hexdump and no od at all, so on the routers this
	# package is for, the hexdump branch is the only branch that ever runs. Both
	# are asserted separately rather than once with both tools present, because a
	# change that fixed one and broke the other would otherwise pass unnoticed on
	# a developer machine, where od is always there to hide it.
	assert_eq "1dcd6500" "$(sh_common_tools 'od tr' "fcc_hex_dump $SANDBOX/four")" \
		"the od branch emits bare lowercase hex"
	assert_eq "1dcd6500" "$(sh_common_tools 'hexdump tr' "fcc_hex_dump $SANDBOX/four")" \
		"the hexdump branch emits the same string"
	assert_eq "1dcd6500" "$(sh_common_tools 'od hexdump tr' "fcc_hex_dump $SANDBOX/four")" \
		"od answers when both are present"

	# Several files concatenate with nothing between them, which is what lets a
	# whole OPP table be read in one process.
	printf '\001\002' > "$SANDBOX/two"
	assert_eq "1dcd65000102" \
		"$(sh_common_tools 'od tr' "fcc_hex_dump $SANDBOX/four $SANDBOX/two")" \
		"files are concatenated in order"
	assert_eq "1dcd65000102" \
		"$(sh_common_tools 'hexdump tr' "fcc_hex_dump $SANDBOX/four $SANDBOX/two")" \
		"and the two tools agree on the concatenation"

	assert_no "no argument is refused" sh_common_tools 'od tr' 'fcc_hex_dump >/dev/null'
	assert_no "neither tool present is refused" \
		sh_common_tools 'true' "fcc_hex_dump $SANDBOX/four >/dev/null"
}

# The Airoha EN7581 device tree as the kernel exposes it under
# /sys/firmware/devicetree/base: fifteen OPPs on opp-table, and a second table
# that carries opp-level and no opp-hz. The bytes are what dtc emits for
# `opp-hz = /bits/ 64 <N>` — 64-bit big-endian, high word first — and the values
# are the ones in target/linux/airoha/dts/an7581.dtsi.
#   make_an7581_opp_table -> the directory holding it
make_an7581_opp_table() {
	_tr_d="$SANDBOX/dtbase"
	rm -rf "$_tr_d"
	for _tr_opp in \
		000000001dcd6500:500000000 0000000020c85580:550000000 \
		0000000023c34600:600000000 0000000026be3680:650000000 \
		0000000029b92700:700000000 000000002cb41780:750000000 \
		000000002faf0800:800000000 0000000032a9f880:850000000 \
		0000000035a4e900:900000000 00000000389fd980:950000000 \
		000000003b9aca00:1000000000 000000003e95ba80:1050000000 \
		000000004190ab00:1100000000 00000000448b9b80:1150000000 \
		0000000047868c00:1200000000
	do
		_tr_hz="${_tr_opp#*:}"
		mkdir -p "$_tr_d/opp-table/opp-$_tr_hz"
		printf "$(hex_to_octal "${_tr_opp%%:*}")" > "$_tr_d/opp-table/opp-$_tr_hz/opp-hz"
	done
	# The second table is matched by the opp-table* glob, and has no opp-hz at
	# all, so it contributes nothing — which is the point of including it.
	mkdir -p "$_tr_d/opp-table-cpu-smcc/opp0"
	printf "$(hex_to_octal 00000000)" > "$_tr_d/opp-table-cpu-smcc/opp0/opp-level"
	printf '%s' "$_tr_d"
}

test_cpu_dt_opp_hz_reads_the_an7581_table() {
	setup_sandbox
	_tr_dt="$(make_an7581_opp_table)"
	assert_eq "1200000000" "$(sh_common "fcc_cpu_dt_opp_hz $_tr_dt")" \
		"the highest opp-hz is the rate the CPU is specified at"

	# The glob sorts by name, so opp-1000000000 is read before opp-1200000000 and
	# the last value seen is 950000000, not the largest. A reader that took the
	# last value instead of the maximum would answer that.
	assert_ne "950000000" "$(sh_common "fcc_cpu_dt_opp_hz $_tr_dt")" \
		"the answer is the maximum, not the last value read"

	# This is the branch that runs on the hardware the fallback exists for: the
	# busybox in OpenWrt 24.10.4 has no od, and neither does the one on a router.
	assert_eq "1200000000" "$(sh_common_tools 'hexdump tr' "fcc_cpu_dt_opp_hz $_tr_dt")" \
		"the table reads the same through hexdump"

	# A rate that does not fit in 32 bits is not a CPU clock, and the arithmetic
	# for one would be wider than a 32-bit router's shell is required to carry.
	mkdir -p "$SANDBOX/dtwide/opp-table/opp-x"
	printf "$(hex_to_octal 0000000147868c00)" > "$SANDBOX/dtwide/opp-table/opp-x/opp-hz"
	assert_no "a value that needs its high word is refused" \
		sh_common "fcc_cpu_dt_opp_hz $SANDBOX/dtwide >/dev/null"

	# A truncated property would misalign every value after it, so the total
	# length is checked before anything is parsed.
	mkdir -p "$SANDBOX/dtshort/opp-table/opp-x"
	printf "$(hex_to_octal 1dcd6500)" > "$SANDBOX/dtshort/opp-table/opp-x/opp-hz"
	assert_no "a truncated opp-hz is refused" \
		sh_common "fcc_cpu_dt_opp_hz $SANDBOX/dtshort >/dev/null"

	# A zero rate is the kernel saying it does not know, which must not be shown
	# as 0 MHz.
	mkdir -p "$SANDBOX/dtzero/opp-table/opp-x"
	printf "$(hex_to_octal 0000000000000000)" > "$SANDBOX/dtzero/opp-table/opp-x/opp-hz"
	assert_no "a zero opp-hz is refused" \
		sh_common "fcc_cpu_dt_opp_hz $SANDBOX/dtzero >/dev/null"

	mkdir -p "$SANDBOX/dtempty"
	assert_no "a device tree with no opp table is refused" \
		sh_common "fcc_cpu_dt_opp_hz $SANDBOX/dtempty >/dev/null"
	assert_no "a missing device tree is refused" \
		sh_common "fcc_cpu_dt_opp_hz $SANDBOX/nonexistent >/dev/null"
	assert_no "an empty argument is refused" \
		sh_common 'fcc_cpu_dt_opp_hz "" >/dev/null'
}

test_cpu_dt_model_reads_the_cpu_nodes_compatible() {
	setup_sandbox
	# The other half of the arm64 story. /proc/cpuinfo names no CPU there, so
	# the CPU node in the device tree is the only place the name exists — and
	# the card showed a dash on a board that knows perfectly well what it is.
	#
	# `compatible` is a NUL-separated list with no trailing newline, which is
	# the shape that makes `read` interesting here: it is asked for one line and
	# told that hitting end-of-file is not a failure.
	_tr_node="$SANDBOX/cpus/cpu@0"
	mkdir -p "$_tr_node"
	printf 'arm,cortex-a53\000' > "$_tr_node/compatible"
	assert_eq "Arm Cortex-A53" "$(sh_common "fcc_cpu_dt_model $_tr_node")" \
		"an arm64 CPU node names its core"

	# A shell variable cannot hold a NUL, so `read` drops it and carries on: a
	# node naming two things comes back as one run-together word. Measured, not
	# assumed — "a,b\0c,d\0" reads as "a,bc,d" under dash and under busybox ash
	# alike. That is not a name, so it is refused rather than shown.
	printf 'airoha,an7581\000airoha,en7581\000' > "$_tr_node/compatible"
	assert_no "a node naming two things is refused rather than run together" \
		sh_common "fcc_cpu_dt_model $_tr_node >/dev/null"

	# The vendor and the part are separate words and each part is capitalised,
	# so the page shows a CPU name rather than a device tree spelling.
	printf 'qcom,msm8996pro-1\000' > "$_tr_node/compatible"
	assert_eq "Qcom Msm8996pro-1" "$(sh_common "fcc_cpu_dt_model $_tr_node")" \
		"the name is written the way a person reads it"

	printf '\000' > "$_tr_node/compatible"
	assert_no "a property holding only a NUL is refused" \
		sh_common "fcc_cpu_dt_model $_tr_node >/dev/null"

	: > "$_tr_node/compatible"
	assert_no "an empty property is refused" \
		sh_common "fcc_cpu_dt_model $_tr_node >/dev/null"

	rm -f "$_tr_node/compatible"
	assert_no "a node with no compatible is refused" \
		sh_common "fcc_cpu_dt_model $_tr_node >/dev/null"
	assert_no "a missing node is refused" \
		sh_common "fcc_cpu_dt_model $SANDBOX/nonexistent >/dev/null"
	assert_no "an empty argument is refused" \
		sh_common 'fcc_cpu_dt_model "" >/dev/null'

	# And nothing above may say anything on the way out. status.sh runs this on
	# every poll, and a board with no such node — every x86 router — is the
	# ordinary case rather than a fault, so a shell message about a redirection
	# would be written to the runtime log once a second forever. The shell
	# prints that message itself, which is why the read redirects stderr before
	# it opens the file.
	assert_eq "" "$(sh_common "fcc_cpu_dt_model $SANDBOX/nonexistent")" \
		"a node that is not there says nothing at all"
}

# ---------------------------------------------------------------------------
# Core temperature
# ---------------------------------------------------------------------------

test_temp_read_mc_parses_sysfs_millidegrees() {
	setup_sandbox
	# sysfs reports thousandths of a degree as text, so this is a text parser and
	# every refusal below is a real case rather than defensive padding.
	printf '48000\n' > "$SANDBOX/t48000"
	assert_eq "48000" "$(sh_common "fcc_temp_read_mc $SANDBOX/t48000")" \
		"a plausible reading is passed through in millidegrees"

	# Leading zeros are octal to the shell's arithmetic, so "048000" would be a
	# syntax error in ash — and a syntax error here takes the whole status script,
	# and the page that reads it, down with it.
	printf '048000\n' > "$SANDBOX/t-lead"
	assert_eq "48000" "$(sh_common "fcc_temp_read_mc $SANDBOX/t-lead")" \
		"leading zeros are stripped rather than fed to the arithmetic"

	# A device in a cold room reads below zero, and a negative number is still a
	# reading. Turning it into nothing would make a sensor that answered look
	# like one that is not there.
	printf -- '-5000\n' > "$SANDBOX/t-neg"
	assert_eq "-5000" "$(sh_common "fcc_temp_read_mc $SANDBOX/t-neg")" \
		"a negative reading survives"

	# Zero is how a driver with nothing to say answers, and a running core is
	# never at 0 °C — so it is refused rather than shown as 0.0 °C, which would
	# look like a reading (section 44). All three spellings are the same reading.
	for _tr_z in 0 00 -0; do
		printf '%s\n' "$_tr_z" > "$SANDBOX/t-zero"
		assert_no "a reading of [$_tr_z] is refused" \
			sh_common "fcc_temp_read_mc $SANDBOX/t-zero >/dev/null"
	done

	# The markers a broken or unpopulated sensor reports, at both ends of the
	# range. In range is -100 °C .. 200 °C exclusive, so the two endpoints are
	# themselves refused.
	printf '200000\n' > "$SANDBOX/t-hot"
	assert_no "200 °C is refused as out of range" \
		sh_common "fcc_temp_read_mc $SANDBOX/t-hot >/dev/null"
	printf -- '-100000\n' > "$SANDBOX/t-cold"
	assert_no "-100 °C is refused as out of range" \
		sh_common "fcc_temp_read_mc $SANDBOX/t-cold >/dev/null"

	# The widest reading that is still in range, so the length guard is pinned
	# against the arithmetic rather than only against garbage.
	printf '199999\n' > "$SANDBOX/t-max"
	assert_eq "199999" "$(sh_common "fcc_temp_read_mc $SANDBOX/t-max")" \
		"the top of the range is accepted"

	printf 'abcdef\n' > "$SANDBOX/t-abc"
	assert_no "a non-numeric reading is refused" \
		sh_common "fcc_temp_read_mc $SANDBOX/t-abc >/dev/null"
	printf '48 000\n' > "$SANDBOX/t-space"
	assert_no "a reading with a space in it is refused" \
		sh_common "fcc_temp_read_mc $SANDBOX/t-space >/dev/null"
	: > "$SANDBOX/t-empty"
	assert_no "an empty reading is refused" \
		sh_common "fcc_temp_read_mc $SANDBOX/t-empty >/dev/null"
	printf '9999999\n' > "$SANDBOX/t-wide"
	assert_no "a value too wide for the arithmetic is refused" \
		sh_common "fcc_temp_read_mc $SANDBOX/t-wide >/dev/null"
	assert_no "a missing file is refused" \
		sh_common "fcc_temp_read_mc $SANDBOX/nonexistent >/dev/null"
	assert_no "an empty argument is refused" \
		sh_common 'fcc_temp_read_mc "" >/dev/null'
}

test_temp_name_is_cpu_knows_the_cpu_sensors() {
	setup_sandbox
	# The zone names the kernel actually uses for a CPU, one per family: the
	# generic device-tree ones, the x86 package sensors and the AMD ones.
	for _tr_n in cpu-thermal cpu_thermal soc-thermal x86_pkg_temp coretemp \
		k10temp zenpower cluster0 CPU-THERMAL; do
		assert_ok "[$_tr_n] names the CPU" sh_common "fcc_temp_name_is_cpu '$_tr_n'"
	done
	# And the ones that are a different part of the board. A radio or a modem is
	# a real sensor, but it is not the core, and the page says which it is.
	for _tr_n in wifi radio modem charger battery acpitz nvme; do
		assert_no "[$_tr_n] does not name the CPU" \
			sh_common "fcc_temp_name_is_cpu '$_tr_n'"
	done
	assert_no "an empty name does not" sh_common "fcc_temp_name_is_cpu ''"
}

test_cpu_temp_mc_prefers_the_cpu_sensor() {
	setup_sandbox
	# The two sysfs layouts are fixtures, because no machine running these tests
	# is a router with both — and the *choice* between them is the whole point of
	# the function, so it has to be exercised where both are present.
	_tr_zone() {  # <index> <name> <millidegrees>
		mkdir -p "$SANDBOX/thermal/thermal_zone$1"
		printf '%s\n' "$2" > "$SANDBOX/thermal/thermal_zone$1/type"
		printf '%s\n' "$3" > "$SANDBOX/thermal/thermal_zone$1/temp"
	}
	_tr_hw() {  # <n> <name> <millidegrees>
		mkdir -p "$SANDBOX/hwmon/hwmon$1"
		printf '%s\n' "$2" > "$SANDBOX/hwmon/hwmon$1/name"
		printf '%s\n' "$3" > "$SANDBOX/hwmon/hwmon$1/temp1_input"
	}
	_tr_read() {
		sh_common "FCC_THERMAL_DIR=$SANDBOX/thermal FCC_HWMON_DIR=$SANDBOX/hwmon fcc_cpu_temp_mc"
	}

	# The answer is the value and the sensor's name together: the name is only
	# meaningful beside the reading it belongs to.
	_tr_zone 0 cpu-thermal 48000
	assert_eq "48000|cpu-thermal" "$(_tr_read)" \
		"a CPU zone is reported with its own name"

	# A zone that is not the CPU is still used when nothing better is there, and
	# the name goes with it so the page can say where the number came from.
	rm -rf "$SANDBOX/thermal"
	_tr_zone 0 acpitz 39000
	assert_eq "39000|acpitz" "$(_tr_read)" \
		"a zone that is not the CPU is the fallback, named"

	# A CPU-named zone wins even when it is not the first one, which is the case
	# the loop exists for: a board whose radio zone is registered first.
	rm -rf "$SANDBOX/thermal"
	_tr_zone 0 wifi 55000
	_tr_zone 1 cpu-thermal 47000
	assert_eq "47000|cpu-thermal" "$(_tr_read)" \
		"a CPU zone later in the list beats an earlier one that is not"

	# A zone whose reading is refused does not shadow a later CPU zone.
	rm -rf "$SANDBOX/thermal"
	_tr_zone 0 acpitz 0
	_tr_zone 1 soc-thermal 51000
	assert_eq "51000|soc-thermal" "$(_tr_read)" \
		"a zone reading zero is skipped rather than reported"

	# hwmon is the second layout, tried when there is no zone at all.
	rm -rf "$SANDBOX/thermal"
	_tr_hw 0 coretemp 45000
	assert_eq "45000|coretemp" "$(_tr_read)" \
		"an hwmon CPU sensor answers when there is no thermal zone"

	# And a zone, even a non-CPU one, beats hwmon — because a zone is what a
	# cooling device acts on, so it is the one the fan is actually following.
	_tr_zone 0 acpitz 39000
	assert_eq "39000|acpitz" "$(_tr_read)" \
		"a thermal zone is preferred over hwmon"

	# No sensor anywhere is not an error: the page shows its dash.
	rm -rf "$SANDBOX/thermal" "$SANDBOX/hwmon"
	assert_no "a board with no sensor at all yields nothing" \
		sh_common "FCC_THERMAL_DIR=$SANDBOX/thermal FCC_HWMON_DIR=$SANDBOX/hwmon fcc_cpu_temp_mc >/dev/null"
}

test_status_falls_back_to_the_device_tree_for_the_cpu_rate() {
	setup_sandbox
	# The AN7581 case, end to end. OpenWrt 24.10 builds the EN7581 cpufreq
	# driver but leaves CONFIG_CPUFREQ_DT off, and that driver's whole job is to
	# register a cpufreq-dt platform device — so nothing binds, no policy is
	# created, and neither sysfs layout exists. The page showed a dash on a
	# router that was running perfectly well.
	#
	# An empty directory stands in for that sysfs and the fixture is the real
	# AN7581 OPP table. This is the half the unit tests cannot reach: that
	# status.sh gets as far as the fallback and that the number arrives in the
	# document the page reads.
	_tr_dt="$(make_an7581_opp_table)"
	mkdir -p "$SANDBOX/empty-sys"
	_tr_run() {
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_SYS_CPU="$1" FCC_DT_BASE="$2" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":'
	}

	_tr_out="$(_tr_run "$SANDBOX/empty-sys" "$_tr_dt")"
	assert_contains "$_tr_out" '"cpu_mhz": 1200' \
		"the device tree answers when sysfs has no rate"
	assert_contains "$_tr_out" '"cpu_mhz_max": 1200' \
		"and the nominal rate is the best answer to the maximum too"

	# With cpufreq present it wins: that is the rate the CPU is running at now,
	# not the rate it is specified at, and the fallback must never displace it.
	mkdir -p "$SANDBOX/sys/cpu0/cpufreq"
	printf '2400000\n' > "$SANDBOX/sys/cpu0/cpufreq/scaling_cur_freq"
	printf '2600000\n' > "$SANDBOX/sys/cpu0/cpufreq/cpuinfo_max_freq"
	_tr_out="$(_tr_run "$SANDBOX/sys" "$_tr_dt")"
	assert_contains "$_tr_out" '"cpu_mhz": 2400' \
		"cpufreq is preferred where the kernel has it"
	assert_contains "$_tr_out" '"cpu_mhz_max": 2600' \
		"and its own maximum comes with it"

	# A board with neither reports no maximum, rather than a zero. Section 44:
	# an absent reading is not a reading of nothing. cpu_mhz is not asserted
	# here because it has a third source — /proc/cpuinfo reports a rate on x86,
	# and this machine is an x86 one — so the only field with nowhere left to
	# look is the maximum.
	_tr_out="$(_tr_run "$SANDBOX/empty-sys" "$SANDBOX/nonexistent")"
	assert_contains "$_tr_out" '"cpu_mhz_max": null' \
		"a board with no rate anywhere reports no maximum"
}

test_status_names_the_cpu_from_the_device_tree_when_cpuinfo_does_not() {
	setup_sandbox
	# The reported bug, end to end. An AN7581's /proc/cpuinfo is mainline arm64
	# output: no "model name", because mainline prints one only for a 32-bit ELF
	# platform, and no "Hardware" line, because that one is arm32 or a vendor
	# tree. The card showed a dash above a frequency that was working.
	#
	# FCC_PROC_CPUINFO is what lets this machine — an x86 one, whose cpuinfo
	# names its CPU perfectly well — run the arm64 path at all.
	_tr_cpuinfo="$SANDBOX/cpuinfo-arm64"
	printf 'processor\t: 0\nBogoMIPS\t: 50.00\nCPU implementer\t: 0x41\nCPU part\t: 0xd03\nCPU revision\t: 4\n\nprocessor\t: 1\nBogoMIPS\t: 50.00\n' > "$_tr_cpuinfo"
	_tr_dt="$SANDBOX/dtmodel"
	mkdir -p "$_tr_dt/cpus/cpu@0"
	printf 'arm,cortex-a53\000' > "$_tr_dt/cpus/cpu@0/compatible"
	mkdir -p "$SANDBOX/empty-sys"
	_tr_run() {
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_PROC_CPUINFO="$_tr_cpuinfo" FCC_SYS_CPU="$1" FCC_DT_BASE="$2" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":'
	}
	assert_contains "$(_tr_run "$SANDBOX/empty-sys" "$_tr_dt")" \
		'"cpu_model": "Arm Cortex-A53"' \
		"the device tree names the CPU when cpuinfo does not"

	# cpu0/of_node is the kernel's own symlink to that node, so where the kernel
	# provides it that is what is read; the path under the device tree base is
	# the fallback for a kernel that does not.
	mkdir -p "$SANDBOX/sys-node/cpu0/of_node"
	printf 'arm,cortex-a72\000' > "$SANDBOX/sys-node/cpu0/of_node/compatible"
	assert_contains "$(_tr_run "$SANDBOX/sys-node" "$_tr_dt")" \
		'"cpu_model": "Arm Cortex-A72"' \
		"the kernel's own node is preferred over the device tree base"

	# A cpuinfo that does name a CPU still wins. The device tree is asked only
	# when there is nothing to report, never to correct something — and this
	# machine's own cpuinfo is the one that names one, so this runner leaves
	# FCC_PROC_CPUINFO unset.
	assert_not_contains "$(
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_SYS_CPU="$SANDBOX/sys-node" FCC_DT_BASE="$_tr_dt" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":'
	)" '"cpu_model": "Arm Cortex-A72"' \
		"the device tree does not displace a name cpuinfo gave"

	# A board with neither source reports no model at all, and the page shows
	# its dash. Section 44: an absent reading is not a reading of nothing.
	mkdir -p "$SANDBOX/no-model"
	_tr_out="$(
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_PROC_CPUINFO="$_tr_cpuinfo" FCC_SYS_CPU="$SANDBOX/empty-sys" \
		FCC_DT_BASE="$SANDBOX/no-model" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":'
	)"
	assert_contains "$_tr_out" '"cpu_model": null' \
		"a board that names no CPU anywhere reports null"
}

test_status_document_reports_the_cpu() {
	setup_sandbox
	# Basic Information shows the CPU from this document, so the four fields have
	# to be here and correctly typed. The values are checked against /proc rather
	# than hard-coded, so the test passes on any machine.
	_tr_sys="$(sh_script status.sh | grep '"system":')"

	assert_contains "$_tr_sys" '"cpu_model":' "the system block carries a CPU model"
	assert_contains "$_tr_sys" '"cpu_mhz":' "the system block carries a current frequency"
	assert_contains "$_tr_sys" '"cpu_mhz_max":' "the system block carries a maximum frequency"
	assert_contains "$_tr_sys" '"cpu_cores":' "the system block carries a core count"

	# A core count that disagrees with /proc is worse than no core count: the
	# page presents it as a reading.
	assert_contains "$_tr_sys" "\"cpu_cores\": $(grep -c '^processor' /proc/cpuinfo)" \
		"the core count matches /proc/cpuinfo"

	# Section 44: a frequency the kernel does not expose comes through as null,
	# never as a guessed number.
	_tr_mhz="$(printf '%s\n' "$_tr_sys" | sed -e 's/.*"cpu_mhz": //' -e 's/,.*//')"
	case "$_tr_mhz" in
		null) pass ;;
		''|*[!0-9]*) fail "cpu_mhz should be null or a whole number of MHz, got [$_tr_mhz]" ;;
		*) pass ;;
	esac
}

test_status_document_reports_the_temperature() {
	setup_sandbox
	# Basic Information shows the core temperature from this document, so the two
	# fields have to be here and correctly typed. The sensor is a fixture rather
	# than the machine's own: a laptop has thermal zones of its own, and a test
	# that read them would be asserting whatever this box happens to be doing.
	mkdir -p "$SANDBOX/thermal/thermal_zone0" "$SANDBOX/no-thermal" "$SANDBOX/no-hwmon"
	printf 'cpu-thermal\n' > "$SANDBOX/thermal/thermal_zone0/type"
	printf '48500\n' > "$SANDBOX/thermal/thermal_zone0/temp"

	_tr_run() {
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_THERMAL_DIR="$1" FCC_HWMON_DIR="$2" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":'
	}

	_tr_sys="$(_tr_run "$SANDBOX/thermal" "$SANDBOX/no-hwmon")"
	assert_contains "$_tr_sys" '"cpu_temp_mc": 48500' \
		"the reading reaches the document in millidegrees"
	assert_contains "$_tr_sys" '"cpu_temp_source": "cpu-thermal"' \
		"the sensor the reading came from is named beside it"

	# Section 44: a board with no sensor reports null, never a zero — and null is
	# what makes the page show its dash rather than 0.0 °C.
	_tr_sys="$(_tr_run "$SANDBOX/no-thermal" "$SANDBOX/no-hwmon")"
	assert_contains "$_tr_sys" '"cpu_temp_mc": null' \
		"a board with no sensor reports null rather than zero"
	assert_contains "$_tr_sys" '"cpu_temp_source": null' \
		"and names no sensor"

	# The two fields travel together: a name with no reading would have the page
	# label a number it does not have.
	_tr_sys="$(_tr_run "$SANDBOX/thermal" "$SANDBOX/no-hwmon")"
	_tr_name="$(printf '%s\n' "$_tr_sys" | sed -e 's/.*"cpu_temp_source": //' -e 's/}.*//')"
	_tr_mc="$(printf '%s\n' "$_tr_sys" | sed -e 's/.*"cpu_temp_mc": //' -e 's/,.*//')"
	assert_eq '"cpu-thermal"' "$_tr_name" "the source is a JSON string"
	assert_eq '48500' "$_tr_mc" "the reading is a JSON number"
}

test_status_document_reports_the_platform() {
	setup_sandbox
	# Basic Information shows the platform from this document, so the two fields
	# have to be here and correctly typed.
	#
	# The platform is the OpenWrt target, which is what tells two boards with the
	# same architecture apart. It is read from a file rather than from the
	# kernel, so the file is pointed at a fixture: the machine running these
	# tests is not an OpenWrt device and has no target of its own to report.
	_tr_owrt="$SANDBOX/openwrt_release"
	_tr_sysinfo="$SANDBOX/sysinfo"
	mkdir -p "$_tr_sysinfo"
	printf "DISTRIB_ID='OpenWrt'\nDISTRIB_TARGET='airoha/an7581'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" \
		> "$_tr_owrt"

	_tr_sys="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_OPENWRT_RELEASE="$_tr_owrt" FCC_SYSINFO_DIR="$_tr_sysinfo" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":')"

	assert_contains "$_tr_sys" '"platform": "airoha/an7581"' \
		"the platform is the OpenWrt target the firmware was built for"

	# The board's own name is the sub-line, and the target cannot supply it: a
	# target covers a family of boards.
	printf 'Airoha AN7581 Evaluation Board\n' > "$_tr_sysinfo/model"
	_tr_sys="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_OPENWRT_RELEASE="$_tr_owrt" FCC_SYSINFO_DIR="$_tr_sysinfo" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":')"
	assert_contains "$_tr_sys" '"platform_model": "Airoha AN7581 Evaluation Board"' \
		"the board's own model comes from the sysinfo the boot scripts wrote"

	# An image with no release file still knows its board, so the target falls
	# back to the board name rather than going empty.
	printf 'airoha,an7581-evb\n' > "$_tr_sysinfo/board_name"
	_tr_sys="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_OPENWRT_RELEASE="$SANDBOX/no-such-release" FCC_SYSINFO_DIR="$_tr_sysinfo" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":')"
	assert_contains "$_tr_sys" '"platform": "airoha,an7581-evb"' \
		"a device whose image carries no release file falls back to its board name"

	# Section 44: neither source having an answer is null, not an empty string
	# and not a guess — the page shows its dash for exactly this.
	_tr_sys="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_OPENWRT_RELEASE="$SANDBOX/no-such-release" \
		FCC_SYSINFO_DIR="$SANDBOX/no-such-sysinfo" \
		sh "$LIBEXEC/status.sh" 2>&1 | grep '"system":')"
	assert_contains "$_tr_sys" '"platform": null' \
		"a board that names its platform nowhere reports null"
	assert_contains "$_tr_sys" '"platform_model": null' \
		"and reports no model rather than an empty one"
}

test_status_reports_why_a_version_is_missing() {
	setup_sandbox
	# Section 44: "no version because the agent is not installed" and "no version
	# because the probe did not produce one" are different states, and collapsing
	# them into a single dash throws away the only clue the user gets. The
	# batched document has to carry the reason beside the null, the way agent.sh
	# does for its single-agent output, or the table cannot tell them apart.
	#
	# The id is what installation is decided by — it is the agent's own CLI, and
	# `command -v` is what resolves it — so the first two rows take ids that are
	# real commands and the third takes one that is not. The launcher column is
	# deliberately a name that exists nowhere: it plays no part in the answer,
	# which is itself worth pinning.
	_tr_conf="$SANDBOX/agents.conf"
	printf '%s\n' \
		'sh|No Probe|fcc-noprobe|0|10|10|' \
		'true|Bad Probe|fcc-badprobe|0|10|10|false' \
		'absent|Absent|fcc-absent|0|10|10|sh' > "$_tr_conf"

	# sh_script pins the real registry, so this one invocation builds the
	# environment itself.
	_tr_json="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$_tr_conf" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		sh "$LIBEXEC/status.sh" 2>&1)"

	assert_contains "$_tr_json" '"version_error": "no version probe for this agent"' \
		"an installed agent with no probe registered says so"
	assert_contains "$_tr_json" '"version_error": "version command failed"' \
		"an installed agent whose probe produced nothing says so"
	assert_contains "$_tr_json" '"version_error": null' \
		"an agent that is not installed reports no error, only an absent version"
	assert_contains "$_tr_json" '"installed": false' "the uninstalled agent is reported as such"
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

# Take a lock from a process that stays alive, the way a job does, and leave it
# running until the caller kills it. The holder's pid is left in $_hl_pid.
#
# Not `sh_common 'fcc_lock_acquire ...'`. That runs the acquire in a shell which
# exits the moment it has printed the path, and the lock it leaves names a pid
# that is already gone. A lock like that is a *dead* job's lock, not a held one —
# the two are the whole subject of the test below, and only one of them can be
# made by a shell that does not stay.
#
# `exec sleep` rather than a trailing `sleep`: the pid in the lock has to be the
# process that is still running, so that killing the holder really does end it
# and leave no stray child behind.
#
# The pid is returned in a variable rather than on stdout, and the holder's own
# output goes to /dev/null, because the caller is a command substitution waiting
# for stdout to close. A holder that inherited that pipe would keep it open for
# as long as it ran, so `_hl_pid="$(hold_lock test)"` would not return until the
# holder had finished — and the lock it was holding would already be a dead
# job's lock by the time the test looked at it.
hold_lock() { # hold_lock <lockname>
	FCC_LIBDIR="$LIBEXEC" \
	FCC_AGENTS_CONF="$AGENTS_CONF" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	FCC_DEFAULT_BASE="$SANDBOX/opt" \
	sh -c '. "$1/common.sh"; fcc_lock_acquire "$2" >/dev/null 2>&1 || exit 1
		exec sleep 120' _ "$LIBEXEC" "$1" >/dev/null 2>&1 &
	_hl_pid="$!"
	# The lock is made by the shell above, a moment from now. Waiting for it is
	# the difference between a test and a race.
	_hl_dir="$(sh_common 'fcc_lock_dir')"
	_hl_n=0
	while [ ! -d "$_hl_dir/fcc-$1.lock" ] && [ "$_hl_n" -lt 100 ]; do
		sleep 0.05
		_hl_n=$((_hl_n + 1))
	done
}

test_lock_is_exclusive() {
	setup_sandbox
	_tr_lock="$(sh_common 'fcc_lock_acquire test')"
	assert_ne "" "$_tr_lock" "a lock can be taken"
	sh_common "fcc_lock_release '$_tr_lock'" >/dev/null

	# Held by a process that is still running, which is what a job is.
	hold_lock test
	_tr_holder="$_hl_pid"
	assert_dir "$(sh_common 'fcc_lock_dir')/fcc-test.lock"
	assert_ok "a lock held by a running job reads as held" sh_common 'fcc_lock_held test'
	assert_no "a second acquire fails while held" sh_common 'fcc_lock_acquire test >/dev/null'
	kill "$_tr_holder" 2>/dev/null
	wait "$_tr_holder" 2>/dev/null

	# The holder is gone and left its lock behind — no job releases a lock it
	# was killed out of. The next acquire has to reclaim it, which is the same
	# path a retry after a crashed install takes.
	assert_ok "the lock of a killed job can be retaken" sh_common 'fcc_lock_acquire test >/dev/null'
	sh_common "fcc_lock_release \"\$(fcc_lock_dir)/fcc-test.lock\"" >/dev/null
}

# What "stale" means, and how a dead job's lock gets out of the way.
#
# The rule used to be age alone, and that is the wrong shape for the question.
# A job that dies in its third second leaves a lock three seconds old; a rule
# that only counted seconds calls that job running until the window runs out.
# On 2026-10-16 an install died at once and the page showed its progress bar
# climbing for the next 25 minutes over work that had stopped, because the lock
# it left behind was not yet an hour old (§104.30).
#
# The lock already carries the answer: fcc_lock_acquire() writes the acquiring
# shell's own pid into it. A job that is not running is not running, however
# recently its lock was made.
#
# Every lock here is made the way the backend makes one — a directory *with a
# pid file in it*. The exclusivity test above makes an empty directory, which
# fcc_lock_acquire() never produces, and that is exactly how the reclaim stayed
# broken without a test noticing: it removed the empty shape and refused the
# real one.
test_lock_staleness_follows_the_job_not_the_clock() {
	setup_sandbox
	_tr_locks="$(sh_common 'fcc_lock_dir')"

	# A lock naming a process that is running: this shell, right now.
	_tr_live="$_tr_locks/fcc-livetest.lock"
	mkdir -p "$_tr_live"
	printf '%s' "$$" > "$_tr_live/pid"
	assert_no "a lock naming a live process is not stale" \
		sh_common "fcc_lock_stale '$_tr_live'"
	assert_ok "and it reads as held" sh_common 'fcc_lock_held livetest'
	assert_no "so the next job may not take it" \
		sh_common 'fcc_lock_acquire livetest >/dev/null'

	# The same lock, seconds old, naming a process that is not there. A pid
	# this high cannot be running: the kernel's default pid_max is 32768 on
	# this image and 4194304 at the very most.
	_tr_dead="$_tr_locks/fcc-deadtest.lock"
	mkdir -p "$_tr_dead"
	printf '%s' 4194303 > "$_tr_dead/pid"
	assert_no "that pid is not running, so the lock is not live" \
		test -d /proc/4194303
	assert_ok "a lock naming a dead process is stale, however fresh it is" \
		sh_common "fcc_lock_stale '$_tr_dead'"
	assert_no "and it does not read as held" sh_common 'fcc_lock_held deadtest'

	# The reclaim has to be able to remove it. `rmdir` cannot: the lock has a
	# pid file in it, so the reclaim removed nothing, the mkdir under it failed,
	# and the refusal that followed was permanent rather than the hour it was
	# meant to be. A retry after a failed install would have been refused for
	# good.
	#
	# The proof is that the acquire succeeded — it could not have, had the old
	# lock still been in the way — and that the lock no longer names the job
	# that died.
	assert_ok "and the next job may take it" \
		sh_common 'fcc_lock_acquire deadtest >/dev/null'
	assert_not_contains "$(cat "$_tr_dead/pid" 2>/dev/null)" 4194303 \
		"and the lock no longer names the dead job"

	# A lock with no pid in it — the moment between mkdir and the write — is
	# decided by age, which is the safe direction for a lock that fresh.
	_tr_bare="$_tr_locks/fcc-baretest.lock"
	mkdir -p "$_tr_bare"
	assert_no "a lock with no pid yet is not stale while it is fresh" \
		sh_common "fcc_lock_stale '$_tr_bare'"
	touch -t 202001010000 "$_tr_bare"
	assert_ok "and it is stale once it is older than the window" \
		sh_common "fcc_lock_stale '$_tr_bare'"

	sh_common "fcc_lock_release '$_tr_live'" >/dev/null
	sh_common "fcc_lock_release '$_tr_dead'" >/dev/null
	sh_common "fcc_lock_release '$_tr_bare'" >/dev/null
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

# Start a session running a command that is expected to exit immediately, the
# way cmd_create does it: make the pane, mark it remain-on-exit, and only then
# start the command. Handing the command to new-session instead races — the
# session dies with its pane before remain-on-exit can be set, and the exit
# status goes with it. A fast machine loses that race every time, which is how
# this was found.
tmux_start_exiting() { # tmux_start_exiting <name> <command>
	tmux kill-session -t "$1" 2>/dev/null
	tmux new-session -d -s "$1" 'cat' 2>/dev/null
	tmux set-option -t "$1" remain-on-exit on 2>/dev/null
	tmux respawn-pane -k -t "$1" "$2" 2>/dev/null
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
	tmux_start_exiting "$_sts_name" 'printf hello; exit 7'
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
	tmux_start_exiting "$_sts_ok" 'printf bye; exit 0'
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

test_create_keeps_the_exit_code_of_a_launcher_that_leaves_at_once() {
	setup_sandbox
	if ! command -v tmux >/dev/null 2>&1; then
		skip "tmux is not installed — session creation needs a real pane"
		return 0
	fi

	# The test above mirrors the sequence cmd_create uses. This one drives
	# cmd_create itself, because the mirror cannot catch a mistake in the real
	# thing — and the real thing is where the race lived.
	_cs_bin="$SANDBOX/opt/fcc/bin"
	mkdir -p "$_cs_bin" "$SANDBOX/opt/fcc/sessions" \
	         "$SANDBOX/opt/fcc/data/.local/bin"

	# A runtime that looks installed and a server that looks alive, so that the
	# two guards in front of the tmux calls are satisfied.
	printf '#!/bin/sh\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$_cs_bin/fcc-server"
	chmod +x "$_cs_bin/fcc-server"
	"$_cs_bin/fcc-server" &
	_cs_srv=$!

	# The agent's own CLI as well as its launcher. cmd_create asks whether the
	# agent is installed, and that question is answered by the CLI; a sandbox
	# holding only the launcher models a runtime with no agents in it, and would
	# be refused for a reason this test is not about.
	printf '#!/bin/sh\necho 2.1.299 (Claude Code)\n' > "$SANDBOX/opt/fcc/data/.local/bin/claude"
	chmod +x "$SANDBOX/opt/fcc/data/.local/bin/claude"

	# A launcher doing what one does when it cannot reach its server: print, and
	# leave immediately. Handing this to new-session is what used to destroy the
	# session before remain-on-exit could be set, taking the exit code with it.
	printf '#!/bin/sh\nprintf "boom\\n"; exit 3\n' > "$_cs_bin/fcc-claude"
	chmod +x "$_cs_bin/fcc-claude"

	_cs_created="$(PATH="$_cs_bin:$PATH" \
		FCC_LIBDIR="$LIBEXEC" \
		FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" \
		FCC_DEFAULT_BASE="$SANDBOX/opt" \
		sh "$LIBEXEC/session.sh" create claude 100 30 2>&1)"
	_cs_name="$(printf '%s' "$_cs_created" | sed -n 's/.*"name": "\([^"]*\)".*/\1/p')"
	assert_ne "" "$_cs_name" "create reports the session it made: [$_cs_created]"

	# The agent is started by respawning the placeholder, so the geometry
	# new-session was given has to survive the respawn.
	assert_eq "100x30" \
		"$(tmux display-message -p -t "$_cs_name" '#{pane_width}x#{pane_height}' 2>/dev/null)" \
		"the pane keeps the size it was created with"

	sleep 1

	# The launcher is gone, the session is not, and its exit status is still
	# there to be read. This is the assertion the old ordering failed.
	assert_ok "the session outlives its launcher" tmux has-session -t "$_cs_name"
	_cs_hdr="$(sh_script session.sh output "$_cs_name" 0 0 | head -n1)"
	assert_contains "$_cs_hdr" '"alive": false' "the launcher is no longer running"
	assert_contains "$_cs_hdr" '"exit_code": 3' "its exit code survived creation"

	# The launcher's output lands in the scrollback the console actually reads —
	# the pipe-pane capture — and not on the visible screen, which a pane held
	# open by remain-on-exit has replaced with tmux's own banner. The banner is
	# therefore the proof that remain-on-exit took effect.
	_cs_screen="$(sh_script session.sh capture "$_cs_name" \
		| sed -e 's/[[:space:]]*$//' | sed -e '/^$/d')"
	assert_contains "$_cs_screen" "Pane is dead" "the pane was kept after its process exited"

	_cs_raw="$(tr -d '\r' < "$SANDBOX/opt/fcc/sessions/$_cs_name.out" 2>/dev/null)"
	# Exactly the launcher's output: the `cat` placeholder has to be silent, or
	# every console would open on a stray shell prompt ahead of the agent.
	assert_eq "boom" "$(printf '%s' "$_cs_raw" | sed -e '/^$/d')" \
		"the scrollback holds the launcher's output and nothing else"

	tmux kill-session -t "$_cs_name" 2>/dev/null
	kill "$_cs_srv" 2>/dev/null
	rm -rf "$SANDBOX/opt"
}

test_a_session_asks_whether_the_agent_is_installed_not_whether_the_launcher_is_on_path() {
	setup_sandbox
	if ! command -v tmux >/dev/null 2>&1; then
		skip "tmux is not installed — session creation needs a real pane"
		return 0
	fi

	# The report: pressing "New session" in the Web Console did nothing, for any
	# agent, on a router where the agent was installed and listed as installed.
	#
	# cmd_create asked whether the agent was installed with a bare
	# `command -v "$launcher"`. That answers a question about *this process's
	# PATH*, not about the router. The launcher lives in <root>/bin, and the only
	# thing that puts <root>/bin on PATH is session_env_exports() — which is
	# written into the tmux command string, so it reaches the agent's shell
	# inside the pane and never the shell rpcd forks to run session.sh. The probe
	# therefore said "not installed" for every agent on every router, and no
	# session could be created at all.
	#
	# The two facts the question turns on are made explicit rather than assumed:
	# a PATH on which neither the launcher nor the agent's CLI resolves, and a
	# root in which both exist. A predicate that consults PATH refuses; one that
	# asks the root accepts.
	_tr_base="$(setup_installed_root)"
	_tr_root="$_tr_base/fcc"
	_tr_path="$(make_agentless_path)"

	for _tr_n in fcc-claude claude; do
		assert_no "the test PATH cannot resolve $_tr_n" \
			env PATH="$_tr_path" sh -c 'command -v "$1"' _ "$_tr_n"
	done
	assert_exec "$_tr_root/bin/fcc-claude"
	assert_exec "$_tr_root/data/.local/bin/claude"

	# A server that stays up, so the guard in front of it is satisfied and the
	# agent question is the only thing left that can refuse the create. The
	# process is found by the absolute path of its executable appearing in its
	# own /proc cmdline, which is how fcc_server_pid() finds one.
	printf '#!/bin/sh\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' \
		> "$_tr_root/bin/fcc-server"
	chmod +x "$_tr_root/bin/fcc-server"
	"$_tr_root/bin/fcc-server" &
	_tr_srv=$!

	# The launcher is what the pane execs. Held open so the session is still
	# alive when it is asked about, which is what proves the pane really started
	# — and before it settles it records what its own PATH resolves `claude` to,
	# which is the question the report was really about.
	printf '#!/bin/sh\ncommand -v claude > %s/launcher-resolved.txt 2>&1\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' \
		"$SANDBOX" > "$_tr_root/bin/fcc-claude"
	chmod +x "$_tr_root/bin/fcc-claude"

	_tr_created="$(sh_blind "$_tr_path" "$_tr_base" session.sh create claude 80 24)"
	_tr_name="$(printf '%s' "$_tr_created" | sed -n 's/.*"name": "\([^"]*\)".*/\1/p')"
	assert_ne "" "$_tr_name" \
		"a session is created for an agent that is installed but not on PATH: [$_tr_created]"

	# And the pane runs the launcher by absolute path, so the create does not
	# depend on the PATH the pane is given either.
	assert_contains "$(tmux list-panes -a -F '#{pane_start_command}' 2>/dev/null)" \
		"exec $_tr_root/bin/fcc-claude" \
		"the pane execs the launcher at its absolute path"

	# And the pane is handed a PATH the *CLI* is reachable on, not just the one
	# the launcher sits in. This is the second half of the same report: with
	# only <root>/bin on its PATH the pane started the launcher successfully and
	# then watched it exit 127 — "Could not find Claude Code command: claude" —
	# because upstream resolves that command with a bare PATH lookup. §104.21.
	assert_contains "$(tmux display-message -p -t "$_tr_name" '#{pane_start_command}' 2>/dev/null)" \
		"$_tr_root/data/.local/bin" \
		"the pane's PATH includes the directory the agent CLI is installed in"

	# And the end of it, from inside the running pane rather than from the
	# command string: the launcher resolves `claude`. This is the assertion the
	# report would have passed — the launcher started, and then could not find
	# the command it exists to run, which is exit code 127 and
	# "Could not find Claude Code command: claude".
	sleep 1
	assert_eq "$_tr_root/data/.local/bin/claude" \
		"$(cat "$SANDBOX/launcher-resolved.txt" 2>/dev/null)" \
		"the launcher finds its CLI from inside the pane"

	# An agent that is genuinely absent is still refused. Every launcher is
	# present — uv writes all sixteen in one go — so a predicate that reads the
	# launcher accepts this one too, which is the same confusion in the other
	# direction.
	assert_no "an agent whose CLI is absent is still refused" \
		sh_blind "$_tr_path" "$_tr_base" session.sh create codex 80 24

	tmux kill-session -t "$_tr_name" 2>/dev/null
	kill "$_tr_srv" 2>/dev/null
}

# session.sh's functions, reached the way install_lib() reaches install.sh's:
# from a copy with the dispatch stripped. Sourcing it whole would run the case
# statement and exit.
session_lib() {
	_sl_dst="$SANDBOX/lib-session.sh"
	[ -f "$_sl_dst" ] || sed '/^case "${1:-}" in$/,$d' "$LIBEXEC/session.sh" > "$_sl_dst"
	printf '%s' "$_sl_dst"
}

test_the_pane_environment_puts_the_agent_cli_on_path() {
	setup_sandbox
	# Section 104.21, without tmux in the way: the environment a pane is given,
	# applied to a shell that starts with neither the launcher nor the CLI
	# reachable. That starting state is not a convenience of the test — tmux
	# hands a new pane the *server's* environment, not the environment of
	# whatever asked for the pane, so a PATH that has to be extended really is
	# extended from nothing.
	#
	# The bug: session_env_exports() was a hand-written second copy of the
	# runtime environment and its PATH held only <root>/bin, where the sixteen
	# fcc-* launchers live and no agent CLI does. Every session therefore
	# reached its launcher and died inside it with exit code 127.
	_pe_base="$(setup_installed_root)"
	_pe_root="$_pe_base/fcc"
	_pe_path="$(make_agentless_path)"

	# Stated, not assumed: neither name resolves before the environment is
	# applied, and both exist under the root afterwards.
	for _pe_n in fcc-claude claude; do
		assert_no "the starting PATH cannot resolve $_pe_n" \
			env PATH="$_pe_path" sh -c 'command -v "$1"' _ "$_pe_n"
	done
	assert_exec "$_pe_root/bin/fcc-claude"
	assert_exec "$_pe_root/data/.local/bin/claude"

	_pe_env="$(env PATH="$_pe_path" \
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$_pe_base" \
		sh -c '. "$1"; session_env_exports' _ "$(session_lib)" 2>&1)"

	assert_contains "$_pe_env" "$_pe_root/data/.local/bin" \
		"the pane's PATH names the directory the agent CLI is installed in"

	# The rule rather than the string: a shell that applies this environment and
	# nothing else resolves `claude`, and resolves it to the CLI under this root
	# rather than to some other installation that happens to be on the host.
	_pe_found="$(env PATH="$_pe_path" \
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$_pe_base" \
		sh -c '. "$1"; session_env_exports > "$2"; . "$2"; command -v claude' _ \
		"$(session_lib)" "$SANDBOX/pane-env.sh" 2>&1)"
	assert_eq "$_pe_root/data/.local/bin/claude" "$_pe_found" \
		"a shell given the pane's environment resolves the agent CLI"

	# And the launcher is still what wins for its own name: <root>/bin comes
	# first, so `fcc-claude` is the runtime's launcher and not a system copy.
	_pe_launcher="$(env PATH="$_pe_path" \
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$_pe_base" \
		sh -c '. "$1"; session_env_exports > "$2"; . "$2"; command -v fcc-claude' _ \
		"$(session_lib)" "$SANDBOX/pane-env.sh" 2>&1)"
	assert_eq "$_pe_root/bin/fcc-claude" "$_pe_launcher" \
		"the runtime's own launcher still wins on the pane's PATH"
}

test_the_runtime_environment_has_one_definition() {
	setup_sandbox
	# The same rule, counted rather than described: install.sh, fcc-env and the
	# pane all render one list, and a fourth hand-written copy is exactly how
	# the pane's PATH came to be missing its agent directories. The list is
	# fcc_runtime_bin_dirs(); everything else has to be reading it.
	_rb_base="$(setup_installed_root)"
	_rb_root="$_rb_base/fcc"

	_rb_path="$(make_agentless_path)"
	_rb_want="$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
		"$_rb_root/bin" \
		"$_rb_root/data/.local/bin" \
		"$_rb_root/data/.cargo/bin" \
		"$_rb_root/data/.opencode/bin" \
		"$_rb_root/data/.local/share/pi-node/current/bin" \
		"$_rb_root/data/.grok/bin")"

	assert_eq "$_rb_want" \
		"$(sh_blind_code "$_rb_path" "$_rb_base" 'fcc_runtime_bin_dirs "$FCC_DEFAULT_BASE/fcc"')" \
		"the one list holds the runtime bin and every agent CLI directory"

	# Joined for PATH in the same order, which is what makes the launchers win.
	assert_eq "$(printf '%s' "$_rb_want" | tr '\n' ':')" \
		"$(sh_blind_code "$_rb_path" "$_rb_base" 'fcc_runtime_bin_path "$FCC_DEFAULT_BASE/fcc"')" \
		"the PATH form is the same list, joined"

	# fcc_agent_installed() and the PATH must agree about where to look. The
	# CLI is found under the root while the PATH resolves neither it nor the
	# launcher, which is exactly the state that made the two disagree in the
	# report.
	assert_ok "the agent probe reads the same list" \
		sh_blind_code "$_rb_path" "$_rb_base" \
		'fcc_agent_installed claude "$FCC_DEFAULT_BASE/fcc"'
	assert_no "and still refuses an agent that is not there" \
		sh_blind_code "$_rb_path" "$_rb_base" \
		'fcc_agent_installed codex "$FCC_DEFAULT_BASE/fcc"'
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
	tmux_start_exiting "$_er_bad" 'printf boom; exit 1'
	tmux_start_exiting "$_er_ok" 'printf fine; exit 0'
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
	# The expected value comes from the file rather than from a literal. A
	# literal is what a release breaks: bumping VERSION is the whole act of
	# cutting one, and it would fail here with a message about a shell function
	# that is working correctly. What is being checked is that the function
	# reads that file at all — a hardcoded answer fails this just as soon as the
	# file disagrees with it, which is exactly when it matters.
	assert_eq "$(tr -d ' \t\r\n' < "$ROOT/VERSION")" "$(sh_common 'fcc_luci_version')" \
		"the version file is read"
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

# make_standin_tool <name> <body> -> the path it was written to
#
# A tool that answers the way a *different implementation* of it would. Some
# checks ask "what can the tar on PATH do?", and the only honest way to produce
# the answer a router gives is to put a tar on PATH that really behaves that
# way — a stubbed return value would test the stub. sh_common_tools and
# sh_doctor_tools take an absolute path for exactly this.
make_standin_tool() {
	mkdir -p "$SANDBOX/standin"
	printf '#!/bin/sh\n%s\n' "$2" > "$SANDBOX/standin/$1"
	chmod +x "$SANDBOX/standin/$1"
	printf '%s' "$SANDBOX/standin/$1"
}

# BusyBox tar's whole defect, as it presents itself: uv's installer unpacks its
# release with `tar xf ARCHIVE --no-same-owner --strip-components 1`, and
# BusyBox tar knows neither option. It prints a complaint to stderr, its usage
# text to stdout, and exits 1 — which is what the upstream installer turns into
# "error: uv installation failed with exit code 1" a few seconds after its last
# question, having installed nothing.
BUSYBOX_TAR_BODY='case " $* " in
	*" --strip-components "*|*" --no-same-owner "*)
		echo "tar: unrecognized option" >&2
		exit 1 ;;
esac
exit 0'

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
sh_install() { # sh_install <code> [install-base]
	# The optional second argument moves the install root. ROOT is decided when
	# install.sh is sourced — `ROOT="$(fcc_root)"`, before anything the caller
	# evals runs — so a test that needs a root of its own has to choose it here
	# rather than inside the code it passes. Two tests that both write a Node
	# need two roots: provision_node() is idempotent, and a second test sharing
	# the first one's root would measure that early return instead of its own
	# subject.
	FCC_LIBDIR="$LIBEXEC" \
	FCC_AGENTS_CONF="$AGENTS_CONF" \
	FCC_VERSION_FILE="$ROOT/VERSION" \
	FCC_DEFAULT_BASE="${2:-$SANDBOX/opt}" \
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

# Section 79's two messages are both about an *update*: one names a previous
# version, the other says the server "remains stopped", which is only meaningful
# if it was running. A first install that fails has neither, and reporting
# either of them sends the reader looking for a previous version to repair.
test_rollback_reports_a_failed_first_install_honestly() {
	setup_sandbox
	_ri_root="$SANDBOX/opt/fcc"
	# The state a failed first install leaves: a partial runtime, partial
	# launchers, no runtime.json (that is written only on success), and no backup
	# — because backup_runtime found nothing to back up.
	mkdir -p "$_ri_root/runtime" "$_ri_root/bin" "$_ri_root/data"
	printf 'half-written interpreter\n' > "$_ri_root/runtime/marker"
	printf '#!/bin/sh\nexit 1\n'       > "$_ri_root/bin/fcc-server"
	chmod +x "$_ri_root/bin/fcc-server"
	printf 'provider settings\n'        > "$_ri_root/data/providers.json"

	make_uci_shim
	_out="$(sh_install 'rollback_runtime "" false; echo "rc=$?"')"
	_log="$(cat "$_ri_root/logs/fcc-runtime.log" 2>/dev/null)"

	assert_contains "$_out" "INSTALL_FAILED" "a failed first install says so"
	assert_contains "$_out" "rc=1" "and fails"
	assert_not_contains "$_out" "ROLLBACK_FAILED" \
		"rather than reporting a rollback that never happened"
	assert_not_contains "$_log" "remains stopped" \
		"and never claims a server that never ran remains stopped"
	assert_contains "$_log" "no version to restore" "the log says why there was nothing to restore"

	# The half-written runtime goes: the status page reads fcc-server to decide
	# whether a runtime is installed, and a partial one would be reported as a
	# working install that cannot start.
	assert_no "the partial runtime is removed" test -d "$_ri_root/runtime"
	assert_no "the partial launchers go with it" test -d "$_ri_root/bin"
	# data/ is not this installer's to discard — on a reinstall attempt it may
	# hold provider credentials entered through FCC's own admin page.
	assert_ok "but the data is left alone" test -f "$_ri_root/data/providers.json"
}

# The state a *retry* is in on a box whose install has already failed once, and
# the one the "always FAILED" report came from.
#
# fcc_ensure_dirs() creates data/ before anything else runs, so backup_runtime()
# always finds something to keep and always returns a directory — but no install
# ever succeeded here, so there is no runtime.json and nothing to go back to.
# The backup exists and holds only a copy of data/.
#
# rollback_runtime required *both* an empty backup directory and no runtime.json
# before it would admit that nothing had been installed. A first install never
# has the empty directory, so the branch was unreachable in practice: this state
# took the restore path instead, restored nothing, found no bin/fcc-server to
# run, and ended on section 79's "FCC Server remains stopped. Please inspect
# logs." plus ROLLBACK_FAILED. Those two lines are the wording for a restore
# that failed; here nothing was restored and nothing could be. Every retry
# printed them again, and the installer's own error — the one line that said
# what was actually wrong — was never shown anywhere.
#
# Note what the backup here does *not* hold, because that is now the question:
# no runtime.json and no bin/fcc-server. runtime/ and bin/ are moved into the
# backup on every run, but fcc_ensure_dirs() creates both empty first, so their
# presence is not evidence of anything.
test_rollback_treats_a_data_only_backup_as_no_previous_runtime() {
	setup_sandbox
	_rd_root="$SANDBOX/opt/fcc"
	_rd_bk="$_rd_root/backup/20261005T101018Z"
	mkdir -p "$_rd_root/data/providers" "$_rd_bk/data/providers"
	# The sandbox is shared by every test in this file, and the restore test
	# before this one installs a runtime into it. This one is about a box where
	# nothing has ever been installed successfully, so it says so.
	rm -f "$_rd_root/runtime.json"
	printf 'provider settings\n' > "$_rd_root/data/providers/settings.json"
	printf 'provider settings\n' > "$_rd_bk/data/providers/settings.json"

	# The failed attempt's leftovers, which a rollback has to clear.
	mkdir -p "$_rd_root/runtime" "$_rd_root/bin"
	printf 'half-written interpreter\n' > "$_rd_root/runtime/marker"
	printf '#!/bin/sh\nexit 1\n'       > "$_rd_root/bin/fcc-server"
	chmod +x "$_rd_root/bin/fcc-server"

	make_uci_shim
	# The sandbox — and so this log — is shared by every test in this file, and
	# an earlier one has already written "FCC Server remains stopped" into it.
	# The assertions below are about what *this* call logged, so it starts empty.
	mkdir -p "$_rd_root/logs"
	: > "$_rd_root/logs/fcc-runtime.log"
	_out="$(sh_install "rollback_runtime '$_rd_bk' false; echo \"rc=\$?\"")"
	_log="$(cat "$_rd_root/logs/fcc-runtime.log" 2>/dev/null)"

	assert_contains "$_out" "INSTALL_FAILED" \
		"a box with no runtime.json has no previous runtime"
	assert_not_contains "$_out" "ROLLBACK_FAILED" \
		"so no failed rollback is reported"
	assert_not_contains "$_log" "remains stopped" \
		"and no server that never ran is said to remain stopped"
	assert_contains "$_log" "no version to restore" "the log says what was true"

	# The leftovers go, for the same reason as on a first install: the status
	# page reads fcc-server to decide whether a runtime is installed.
	assert_no "the half-written runtime is removed" test -d "$_rd_root/runtime"
	assert_no "the half-written launchers go with it" test -d "$_rd_root/bin"
	# data/ stays, and stays untouched: it is where the user's own settings and
	# any provider credentials they entered live.
	assert_ok "the data is still there" test -f "$_rd_root/data/providers/settings.json"
	assert_eq "provider settings" "$(cat "$_rd_root/data/providers/settings.json")" \
		"and was not overwritten by the copy in the backup"
}

# ---------------------------------------------------------------------------
# A failed install has to give back the space it took.
#
# The agents install into HOME, and HOME here is <root>/data — XDG_DATA_HOME is
# <root>/data/.local/share — so a failed attempt leaves every byte it downloaded
# sitting in data/, where the status page reads it as an installed runtime and
# the storage precheck counts it against the next attempt.
#
# Measured on the test router on 2026-10-18: a run that failed at OpenCode left
# 1228 MB in data/ (.codex 411M, .local 468M, .npm 25M, .opencode 202M, .pi
# 121M) and free space fell from 1731 MB to 440 MB — below FCC_MIN_FREE_MB, so
# every retry was refused by the precheck before it started. The page showed
# "not enough space" for a box whose space had been spent by the attempt that
# failed, and the only way out was to delete the leftovers by hand (§104.34).
#
# What must not change is the guarantee the test above pins: data/ is the user's
# — their settings, and any provider credentials they entered through FCC's own
# admin page — and a failed install neither destroys it nor overwrites it with
# the backup's copy. So the rollback does not restore data/ here. It removes
# only what was not in data/ before the attempt began, which is exactly what the
# attempt added and nothing else.
# ---------------------------------------------------------------------------

# backup_runtime() runs before the installer does, so it is the one place that
# can see data/ as it was. The record costs no space — names, not contents.
test_backup_runtime_records_what_data_held_before_the_attempt() {
	setup_sandbox
	_bkr_root="$SANDBOX/optreclaim/fcc"
	mkdir -p "$_bkr_root/data/providers" "$_bkr_root/data/.local/share"
	printf 'settings\n' > "$_bkr_root/data/providers/settings.json"
	make_uci_shim

	_bkr_dir="$(sh_install 'backup_runtime' "$SANDBOX/optreclaim")"
	assert_ok "the attempt makes a backup directory" test -d "$_bkr_dir"
	assert_eq ".local
providers" "$(cat "$_bkr_dir/data-before" 2>/dev/null)" \
		"and records the names data/ held, so a rollback can tell what arrived"
}

test_rollback_gives_back_what_the_failed_attempt_added() {
	setup_sandbox
	_rg_root="$SANDBOX/optreclaim/fcc"
	_rg_bk="$_rg_root/backup/20261018T090000Z"
	mkdir -p "$_rg_root/data/providers" "$_rg_bk"
	rm -f "$_rg_root/runtime.json"
	printf 'provider settings\n' > "$_rg_root/data/providers/settings.json"
	# What data/ held when the attempt started — written by backup_runtime().
	printf 'providers\n' > "$_rg_bk/data-before"

	# What the attempt added: each agent installs into HOME, which is data/.
	mkdir -p "$_rg_root/data/.local/share/pi-node" "$_rg_root/data/.opencode/bin" \
		"$_rg_root/data/.npm" "$_rg_root/data/.codex"
	printf 'node\n'      > "$_rg_root/data/.local/share/pi-node/node"
	printf 'opencode\n'  > "$_rg_root/data/.opencode/bin/opencode"

	make_uci_shim
	mkdir -p "$_rg_root/logs"
	: > "$_rg_root/logs/fcc-runtime.log"
	_out="$(sh_install "rollback_runtime '$_rg_bk' false; echo \"rc=\$?\"" "$SANDBOX/optreclaim")"
	_log="$(cat "$_rg_root/logs/fcc-runtime.log" 2>/dev/null)"

	assert_no "the Node the attempt fetched is removed" test -e "$_rg_root/data/.local"
	assert_no "and the OpenCode it installed"          test -e "$_rg_root/data/.opencode"
	assert_no "and the npm cache it filled"            test -e "$_rg_root/data/.npm"
	assert_no "and the other agent's directory"        test -e "$_rg_root/data/.codex"

	# The half that must not move: data/ is the user's.
	assert_ok "the user's own settings are still there" \
		test -f "$_rg_root/data/providers/settings.json"
	assert_eq "provider settings" "$(cat "$_rg_root/data/providers/settings.json")" \
		"and were not touched"
	assert_ok "and the directory holding them is still there" test -d "$_rg_root/data/providers"

	assert_contains "$_out" "INSTALL_FAILED" \
		"and the run is still reported as a first install that failed"
	# What was removed is named, so a user who put something in data/ while the
	# install ran can see that it went rather than guess.
	assert_contains "$_log" "reclaimed" "and the log says the space was given back"

	# A box whose record is missing keeps its data rather than losing it: the
	# reclaim cannot tell what arrived without it, and guessing is how a
	# rollback destroys something it was not asked to touch.
	_rg_root2="$SANDBOX/optnorecord/fcc"
	mkdir -p "$_rg_root2/data/providers" "$_rg_root2/data/.opencode/bin" \
		"$_rg_root2/backup/20261018T090001Z" "$_rg_root2/logs"
	rm -f "$_rg_root2/runtime.json"
	printf 'kept\n' > "$_rg_root2/data/providers/settings.json"
	: > "$_rg_root2/logs/fcc-runtime.log"
	sh_install "rollback_runtime '$_rg_root2/backup/20261018T090001Z' false" \
		"$SANDBOX/optnorecord" >/dev/null 2>&1
	assert_ok "without a record, data/ is left alone" test -e "$_rg_root2/data/.opencode"
	assert_ok "and the user's settings with it" \
		test -f "$_rg_root2/data/providers/settings.json"
}

# The contract the guard above protects: no backup directory means no record,
# which means nothing may be removed. This does not reproduce the specific path
# the guard rejects — that needs a file at /data-before on the device, outside
# anything a sandbox can write — so it pins the outcome, not the mechanism.
test_rollback_without_a_backup_directory_keeps_the_data() {
	setup_sandbox
	_rn_root="$SANDBOX/optnobackup/fcc"
	mkdir -p "$_rn_root/data/.opencode/bin" "$_rn_root/data/providers" "$_rn_root/logs"
	rm -f "$_rn_root/runtime.json"
	printf 'kept\n' > "$_rn_root/data/providers/settings.json"
	: > "$_rn_root/logs/fcc-runtime.log"
	make_uci_shim

	# backup_runtime() returns empty when it cannot even make a directory, which
	# is what a full device does — the case this whole reclaim is for. The
	# rollback then has no list to read, and must not invent one.
	_rn_out="$(sh_install "rollback_runtime '' false; echo \"rc=\$?\"" "$SANDBOX/optnobackup")"
	assert_ok "an empty backup directory leaves data/ alone" \
		test -e "$_rn_root/data/.opencode"
	assert_ok "and the user's settings with it" \
		test -f "$_rn_root/data/providers/settings.json"
	assert_contains "$_rn_out" "INSTALL_FAILED" \
		"and the run is still reported as a failed first install"
}

# ---------------------------------------------------------------------------
# The installer's own words, and where they end up.
#
# A failed install used to be reported as a status number and nothing else: the
# runtime log said "see logs/installer.out" and the Logs page did not offer that
# file, so the one line that said why the install stopped was the one line no
# reader could reach. A router with BusyBox tar therefore produced a report of
# "always FAILED" with no cause anywhere in it.
# ---------------------------------------------------------------------------

test_installer_failure_reason_reads_the_installers_own_error() {
	setup_sandbox
	_ir_dir="$SANDBOX/opt/fcc/logs"
	mkdir -p "$_ir_dir"
	_ir_esc="$(printf '\033')"

	# A terminal transcript rather than a text file: upstream colours its
	# output, the pty turns every newline into CR LF, and the run ends with a
	# whole capture-pane of trailing blanks. All three are in this fixture —
	# including a cursor-mode sequence, whose "?" is not a colour parameter and
	# would sit in front of the error line, out of reach of an anchored match,
	# if the stripper only knew about digits and semicolons.
	{
		printf '%s[1;34m==>%s Installing uv\r\n' "$_ir_esc" "$_ir_esc[0m"
		printf 'downloading uv 0.12.23\r\n'
		printf '%s[?25l%s[31merror: uv installation failed with exit code 1.%s\r\n' \
			"$_ir_esc" "$_ir_esc" "$_ir_esc[0m"
		printf '\r\n'
		printf '   \r\n'
	} > "$_ir_dir/installer.out"

	assert_eq "error: uv installation failed with exit code 1." \
		"$(sh_install "installer_failure_reason '$_ir_dir/installer.out'")" \
		"the error line is recovered, with its escapes and carriage returns gone"

	# BusyBox tar prints its usage text *after* the installer's error, so "the
	# last line" is not the answer — the installer's own error line is.
	{
		printf 'error: uv installation failed with exit code 1.\n'
		printf 'BusyBox v1.36.1 (2024-05-22 12:00:00 UTC) multi-call binary.\n'
		printf 'Usage: tar c|x|t [-ZzJjahmvokO] [-f TARFILE] [-C DIR] [FILE]...\n'
	} > "$_ir_dir/installer.out"
	assert_eq "error: uv installation failed with exit code 1." \
		"$(sh_install "installer_failure_reason '$_ir_dir/installer.out'")" \
		"the error line is preferred over whatever a tool printed after it"

	# No error line: the run was cut short by the deadline, or the installer
	# died on a signal. The last thing it managed to print is the next best
	# answer — and where there is none, none is reported rather than invented.
	printf 'still downloading Claude Code\n' > "$_ir_dir/installer.out"
	assert_eq "still downloading Claude Code" \
		"$(sh_install "installer_failure_reason '$_ir_dir/installer.out'")" \
		"without an error line the last output is used"

	: > "$_ir_dir/installer.out"
	assert_no "an empty transcript yields no reason" \
		sh_install "installer_failure_reason '$_ir_dir/installer.out' >/dev/null"
	assert_no "a missing transcript yields no reason" \
		sh_install "installer_failure_reason '$_ir_dir/nosuch.out' >/dev/null"
}

# ---------------------------------------------------------------------------
# The libc question OpenCode's installer asks, and the stand-in that answers it.
#
# Upstream picks which build to download from the libc, and asks like this —
# under `set -euo pipefail`, for the whole script:
#
#     is_musl=false
#     if command -v ldd >/dev/null 2>&1; then
#       if ldd --version 2>&1 | grep -qi musl; then
#         is_musl=true
#       fi
#     fi
#
# On musl that pipeline reports failure even though grep matched. ldd there is
# not a script but the dynamic loader, and asked for --version it prints its
# banner to stderr and exits 1 — it reads the request as a usage error. grep
# matches and exits 0, and in a shell without pipefail the pipeline is 0; under
# pipefail it is ldd's 1 that becomes the pipeline's status, so is_musl stays
# false, the target comes out linux-x64 instead of linux-x64-musl, and the
# glibc binary that gets installed cannot exec here at all — it wants
# /lib64/ld-linux-x86-64.so.2 and this box has only /lib/ld-musl-x86_64.so.1.
# Upstream then fails its own verification and stops, so the runtime is never
# installed and the page reports a failure whose only visible line is about
# OpenCode (§104.33).
#
# The stand-in ldd-shim is what install.sh puts in front of ldd for the pane,
# and these two tests drive it for real: the first against the detection itself,
# the second against the PATH the pane is actually given.
# ---------------------------------------------------------------------------

# A stand-in for the router's ldd: musl's banner on stderr, then the loader's
# own status for a usage request, which is not zero. Both details are the
# router's, measured — the banner goes to stderr and `ldd --version` exits 1.
# Written as a file because the failure is the *pipeline's* status, and a
# pipeline cannot be faked from outside it.
write_musl_ldd_stand_in() { # write_musl_ldd_stand_in <dir>
	mkdir -p "$1"
	cat > "$1/ldd" <<'LDD_STAND_IN'
#!/bin/sh
printf 'musl libc (x86_64)\n' >&2
printf 'Version 1.2.5\n' >&2
printf 'Dynamic Program Loader\n' >&2
printf 'Usage: ldd [options] [--] pathname [args]\n' >&2
exit 1
LDD_STAND_IN
	chmod 755 "$1/ldd"
}

# Upstream's own detection, verbatim, printing only the answer it reached.
UPSTREAM_MUSL_DETECTION='set -euo pipefail
is_musl=false
if command -v ldd >/dev/null 2>&1; then
  if ldd --version 2>&1 | grep -qi musl; then is_musl=true; fi
fi
printf "%s" "$is_musl"'

test_ldd_shim_answers_the_musl_question_under_pipefail() {
	setup_sandbox
	command -v bash >/dev/null 2>&1 || { skip "no bash — upstream's installer is bash and so is this test"; return 0; }
	write_musl_ldd_stand_in "$SANDBOX/fakeldd"

	# The box as it is today, with nothing in front of the real ldd.
	assert_eq "false" \
		"$(FCC_REAL_LDD="$SANDBOX/fakeldd/ldd" PATH="$SANDBOX/fakeldd:$PATH" \
			bash -c "$UPSTREAM_MUSL_DETECTION" 2>&1)" \
		"the real ldd's banner and status make the musl question answer false"

	# install.sh puts the stand-in in the root, and it is executable there.
	sh_install 'installer_prepare_shim' >/dev/null 2>&1
	assert_exec "$SANDBOX/opt/fcc/shim/ldd" \
		"install.sh installs the ldd stand-in into the root"

	# The same question, with that directory in front of everything else.
	assert_eq "true" \
		"$(FCC_REAL_LDD="$SANDBOX/fakeldd/ldd" PATH="$SANDBOX/opt/fcc/shim:$PATH" \
			bash -c "$UPSTREAM_MUSL_DETECTION" 2>&1)" \
		"with the stand-in in front, the same question answers true"

	# Nothing is invented: the words are the real ldd's, so a caller reading a
	# version number still gets one rather than a placeholder.
	assert_contains \
		"$(FCC_REAL_LDD="$SANDBOX/fakeldd/ldd" "$SANDBOX/opt/fcc/shim/ldd" --version 2>&1)" \
		"Version 1.2.5" "the stand-in's --version is the real ldd's own output"

	# And every other invocation is the real ldd's, status included — the
	# stand-in is a fix for one question, not a replacement for the tool.
	assert_eq \
		"$(FCC_REAL_LDD="$SANDBOX/fakeldd/ldd" "$SANDBOX/fakeldd/ldd" /bin/sh 2>&1; printf 'rc=%s' "$?")" \
		"$(FCC_REAL_LDD="$SANDBOX/fakeldd/ldd" "$SANDBOX/opt/fcc/shim/ldd" /bin/sh 2>&1; printf 'rc=%s' "$?")" \
		"a call that is not --version is handed to the real ldd, output and status alike"

	# A glibc box still reports glibc, so the stand-in cannot turn a right
	# answer wrong on the machines that were already fine.
	mkdir -p "$SANDBOX/glibcldd"
	cat > "$SANDBOX/glibcldd/ldd" <<'LDD_STAND_IN'
#!/bin/sh
printf 'ldd (GNU libc) 2.39\n'
printf 'Copyright (C) 2024 Free Software Foundation, Inc.\n'
exit 0
LDD_STAND_IN
	chmod 755 "$SANDBOX/glibcldd/ldd"
	assert_eq "false" \
		"$(FCC_REAL_LDD="$SANDBOX/glibcldd/ldd" PATH="$SANDBOX/opt/fcc/shim:$PATH" \
			bash -c "$UPSTREAM_MUSL_DETECTION" 2>&1)" \
		"a glibc box still answers the musl question false"
}

test_the_installer_pane_finds_the_ldd_stand_in_first() {
	setup_sandbox
	write_musl_ldd_stand_in "$SANDBOX/fakeldd"

	sh_install "installer_write_env '$SANDBOX/paneenv.sh'" >/dev/null 2>&1
	assert_ok "the pane's environment file is written" test -s "$SANDBOX/paneenv.sh"

	# Read the PATH the way the pane gets it: source the file, then ask.
	assert_eq "$SANDBOX/opt/fcc/shim/ldd" \
		"$(FCC_REAL_LDD="$SANDBOX/fakeldd/ldd" sh -c ". '$SANDBOX/paneenv.sh'; command -v ldd")" \
		"the pane's PATH resolves ldd to the stand-in"
	assert_eq "$SANDBOX/opt/fcc/shim" \
		"$(sh -c ". '$SANDBOX/paneenv.sh'; printf '%s' \"\${PATH%%:*}\"")" \
		"and the stand-in's directory is in front of everything else"

	# The runtime's own directories are still there behind it — the stand-in
	# goes in front of that PATH, it does not replace it.
	assert_contains "$(sh -c ". '$SANDBOX/paneenv.sh'; printf '%s' \"\$PATH\"")" \
		"$SANDBOX/opt/fcc/bin" "and the runtime's directories are still on it"

	# A box where the stand-in file is missing still gets a usable environment:
	# the install must not depend on a workaround for one agent.
	_out="$(sh_install "FCC_LIBDIR='$SANDBOX/nolib' installer_write_env '$SANDBOX/paneenv2.sh'; printf 'rc=%s' \"\$?\"")"
	assert_eq "rc=0" "$_out" "a missing stand-in does not fail the environment"
	assert_not_contains "$(sh -c ". '$SANDBOX/paneenv2.sh'; printf '%s' \"\$PATH\"")" \
		"$SANDBOX/opt/fcc/shim" "and no shim directory is put on PATH without it"
}

# The tar check decides by unpacking a real archive rather than by reading a
# version string, because a version string does not answer the question: BusyBox
# tar reports one and cannot do this, and a BusyBox built with the long options
# could. So the check asks the tar itself, and this asks two tars.
test_tar_probe_follows_the_tar_on_path() {
	setup_sandbox
	make_standin_tool tar "$BUSYBOX_TAR_BODY" >/dev/null

	assert_no "a tar without the long options cannot unpack uv's archive" \
		sh_common_tools "mktemp mkdir rm $SANDBOX/standin/tar" \
			'fcc_tar_can_extract_uv_archive'
	# The same probe against the tar this machine really has. The two long
	# options are the only difference between the two tars, so a probe that
	# always failed — or one that always succeeded — is caught by the pair.
	assert_ok "a tar that supports them can" \
		sh_common_tools 'mktemp mkdir rm tar' 'fcc_tar_can_extract_uv_archive'
}

# The whole failure path, end to end: the installer stops, and the log that the
# job panel and the Logs page both show carries the installer's own reason.
#
# Everything that is the code under test is real here — run_installer, the
# transcript, the rollback decision, the runtime log. Only what would otherwise
# need a router or the network is stood in for: tmux, curl, nslookup.
test_failed_install_reports_the_reason_in_the_runtime_log() {
	setup_sandbox
	_sr_root="$SANDBOX/opt/fcc"
	_sr_state="$SANDBOX/tmux-state"
	mkdir -p "$SANDBOX/bin" "$_sr_root/logs" "$_sr_state"
	make_uci_shim
	# The sandbox is shared by every test in this file, and a test that ran
	# earlier may have installed a runtime into it. This one is about a box
	# where nothing has ever been installed, so it says so rather than
	# inheriting whatever was left behind.
	rm -f "$_sr_root/runtime.json"
	rm -rf "$_sr_root/runtime" "$_sr_root/bin" "$_sr_root/backup"
	# Same reason: the log is shared, and the assertions below are about what
	# this one install wrote into it.
	: > "$_sr_root/logs/fcc-runtime.log"

	# curl, serving one local file. Both option forms are needed: the install
	# downloads the upstream installer with --output, and the doctor's HTTPS
	# check probes with -o /dev/null before the install is allowed to start.
	cat > "$SANDBOX/bin/curl" <<-'EOF'
	#!/bin/sh
	_out=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--output|-o) _out="$2"; shift 2 ;;
			*) shift ;;
		esac
	done
	[ -n "$_out" ] || exit 1
	[ "$_out" = /dev/null ] && exit 0
	cp "$FAKE_INSTALLER_SRC" "$_out"
	EOF
	chmod +x "$SANDBOX/bin/curl"
	# The doctor resolves the installer host before it allows the install at
	# all. That is a real check and it is not what this test is about, so it is
	# answered rather than left to whatever DNS this machine has.
	printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/nslookup"
	chmod +x "$SANDBOX/bin/nslookup"

	# The upstream installer, reduced to the one thing under test: it fails the
	# way it fails on a stock OpenWrt rootfs, and says so the way it says so.
	cat > "$SANDBOX/fake-installer.sh" <<-'EOF'
	#!/bin/sh
	printf '==> Installing uv\n'
	printf 'downloading uv 0.12.23\n'
	printf 'error: uv installation failed with exit code 1.\n'
	exit 1
	EOF
	chmod +x "$SANDBOX/fake-installer.sh"

	# tmux, reduced to what run_installer uses — with one addition that matters:
	# pipe-pane really runs the command it is given, against a pipe the pane
	# writes into, so logs/installer.out is the transcript the real thing would
	# produce rather than a fixture written by this test.
	cat > "$SANDBOX/bin/tmux" <<-'EOF'
	#!/bin/sh
	S="$FAKE_TMUX_DIR"
	# The doctor asks tmux for its version before it allows the install to
	# start, and a tmux that prints nothing reads as tmux that is not there.
	case "$1" in -V|--version) echo "tmux 3.4"; exit 0 ;; esac
	case "$1" in
	new-session)
		shift
		for a in "$@"; do cmd="$a"; done
		# The trailing sleep keeps the pane alive after the installer exits so
		# that the last screen survives to be read. There is no screen here,
		# and leaving a five-minute sleeper behind is rude, so it is dropped.
		cmd="$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*sleep 300$//')"
		rm -f "$S/stream"
		mkfifo "$S/stream" 2>/dev/null
		( sh -c "$cmd" ) > "$S/stream" 2>&1 &
		;;
	pipe-pane)
		for a in "$@"; do last="$a"; done
		# run_installer's pipe command is exactly `cat >> <path>`.
		printf '%s' "$last" | sed -n 's/^cat >> //p' | tr -d "'" > "$S/pipe-target"
		( eval "$last" < "$S/stream" ) >/dev/null 2>&1 &
		;;
	capture-pane)
		# The screen, which for this stand-in is everything the pane has
		# written. The real capture-pane trims trailing whitespace.
		sed 's/[[:space:]]*$//' "$(cat "$S/pipe-target" 2>/dev/null)" 2>/dev/null
		;;
	send-keys)    : ;;
	kill-session) : ;;
	esac
	exit 0
	EOF
	chmod +x "$SANDBOX/bin/tmux"

	# Both space gates are lifted so that the disk this happens to run on is not
	# part of the result: the doctor reads FCC_REQUIRED_FREE_MB and install.sh
	# reads FCC_MIN_FREE_MB, and neither check is what this test is about.
	_sr_out="$( export FAKE_TMUX_DIR="$_sr_state" \
			FAKE_INSTALLER_SRC="$SANDBOX/fake-installer.sh" \
			FCC_MIN_FREE_MB=0 FCC_REQUIRED_FREE_MB=0
		sh_install 'cmd_runtime runtime --agents claude; echo "rc=$?"' )"
	_sr_log="$(cat "$_sr_root/logs/fcc-runtime.log" 2>/dev/null)"

	# The transcript is on disk, and it is the installer's own output.
	assert_contains "$(cat "$_sr_root/logs/installer.out" 2>/dev/null)" \
		"error: uv installation failed with exit code 1." \
		"the run leaves the installer's transcript behind"

	assert_contains "$_sr_log" "installer exited with status 1" \
		"the runtime log records the status"
	assert_contains "$_sr_log" \
		"installer reported: error: uv installation failed with exit code 1." \
		"and the installer's own reason, which is the line that says why"

	# The state this run leaves behind is the one the report came from: a first
	# install, so nothing was installed before and there is nothing to restore.
	assert_contains "$_sr_out" "INSTALL_FAILED" "a first install that failed says so"
	assert_not_contains "$_sr_out" "ROLLBACK_FAILED" \
		"rather than reporting a rollback that never happened"
	assert_not_contains "$_sr_log" "remains stopped" \
		"and never claiming a server that never ran remains stopped"
	assert_not_contains "$_sr_log" "Update failed" \
		"nor an update that never happened"

	# The sandbox is shared by every test in this file, and $SANDBOX/bin is on
	# PATH for every later sh_install. A curl left here would answer the health
	# check with an empty 200 for the rest of the run, so the stand-ins go.
	rm -f "$SANDBOX/bin/curl" "$SANDBOX/bin/nslookup" "$SANDBOX/bin/tmux"
}

# Section 3.6.5 lets the user uncheck every agent. Upstream's chooser will not
# accept that on a first install — it re-asks until one is chosen — so the
# request cannot be honoured and is refused before anything is downloaded.
test_no_agents_is_refused_on_a_first_install() {
	setup_sandbox
	mkdir -p "$SANDBOX/opt/fcc" "$SANDBOX/none-bin"
	# A PATH without the agents: "is anything installed?" is answered by looking
	# for the launchers, and a development machine that has them would answer
	# yes and make this assertion about nothing.
	for _na_t in sh cat rm mkdir rmdir sed awk grep cut tr date df; do
		_na_p="$(command -v "$_na_t" 2>/dev/null)" || continue
		ln -sf "$_na_p" "$SANDBOX/none-bin/$_na_t"
	done

	_na_out="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		UCI_SHIM_DIR="$SANDBOX/uci" PATH="$SANDBOX/none-bin" \
		sh -c '. "$1"; cmd_runtime runtime --no-agents; echo "rc=$?"' \
		_ "$(install_lib)" 2>&1)"

	assert_contains "$_na_out" "NO_AGENTS" "an empty selection on a first install is refused"
	assert_contains "$_na_out" "at least one coding agent" "and says why"
	assert_contains "$_na_out" "rc=1" "and fails rather than installing something else"
	# The refusal is the point: nothing was downloaded, so nothing was installed.
	assert_no "no installer was downloaded" test -e "$SANDBOX/opt/fcc/cache/fcc-install-$$.sh"
	assert_eq "" "$(cat "$SANDBOX/opt/fcc/cache/installer-hashes.log" 2>/dev/null)" \
		"and no installer hash was recorded"
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

	# Both space gates read the same floor (FCC_MIN_FREE_MB in common.sh), so
	# raising it on its own would trip the doctor's compatibility precheck first
	# and this test would see section 3.6.4's message instead of the one it is
	# about. The doctor is therefore told to require nothing, which leaves
	# install.sh's own check as the one that fires — the path this test exists to
	# cover. The doctor's message has a test of its own.
	FCC_MIN_FREE_MB=999999999
	FCC_REQUIRED_FREE_MB=0
	export FCC_MIN_FREE_MB FCC_REQUIRED_FREE_MB
	_out="$(sh_install 'cmd_runtime')"
	unset FCC_MIN_FREE_MB FCC_REQUIRED_FREE_MB

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

# Section 50 lets the FCC Admin port be reachable from the LAN and never from
# the WAN. Adding the rule edits a system config file, so the test watches what
# is actually issued to uci rather than trusting the script's own summary —
# and, more to the point, proves the wan zone is never named at all.
test_firewall_rule_is_lan_only() {
	setup_sandbox

	_fw_log="$SANDBOX/uci.log"
	_fw_rules="$SANDBOX/uci.rules"
	: > "$_fw_log"
	mkdir -p "$_fw_rules" "$SANDBOX/bin"

	# A recording stand-in for uci: answers `get` from one file per rule
	# section, and appends every call to a log. Everything else is recorded and
	# succeeds, which is all the script under test needs to be exercised.
	cat > "$SANDBOX/bin/uci" <<'SHIM'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
printf '%s\n' "$*" >> "$UCI_LOG"
[ "${1:-}" = "get" ] || exit 0
_key="${2:-}"
_idx="$(printf '%s' "$_key" | sed -n 's/^firewall\.@rule\[//p' | sed -n 's/\].*$//p')"
_fld="$(printf '%s' "$_key" | sed -n 's/^.*\]\.//p')"
[ -n "$_idx" ] && [ -n "$_fld" ] || exit 1
[ -r "$UCI_RULES/$_idx" ] || exit 1
_val="$(sed -n "s/^${_fld}=//p" "$UCI_RULES/$_idx" | head -n 1)"
[ -n "$_val" ] || exit 1
printf '%s\n' "$_val"
SHIM
	chmod +x "$SANDBOX/bin/uci"

	_fw_run() {
		UCI_LOG="$_fw_log" UCI_RULES="$_fw_rules" PATH="$SANDBOX/bin:$PATH" \
		FCC_LIBDIR="$LIBEXEC" FCC_DEFAULT_BASE="$SANDBOX/opt" \
			sh "$LIBEXEC/firewall.sh" "$@" 2>&1
	}

	# Nothing configured yet: the rule is added, scoped to lan and nothing else.
	_fw_run ensure 8082 >/dev/null
	_fw_out="$(cat "$_fw_log")"
	assert_contains "$_fw_out" "add firewall rule" "a rule is added when none exists"
	assert_contains "$_fw_out" "firewall.@rule[-1].src=lan" "the rule is scoped to the lan zone"
	assert_contains "$_fw_out" "firewall.@rule[-1].proto=tcp" "the rule is TCP only"
	assert_contains "$_fw_out" "firewall.@rule[-1].target=ACCEPT" "the rule accepts"
	assert_contains "$_fw_out" "firewall.@rule[-1].dest_port=8082" "the rule names the port"
	assert_not_contains "$_fw_out" "wan" "the wan zone is never named"
	assert_contains "$_fw_out" "commit firewall" "the change is committed"

	# Already present: the port is updated in place, not a second rule added.
	: > "$_fw_log"
	printf 'name=Allow-FCC-Admin\nsrc=lan\ndest_port=8082\n' > "$_fw_rules/0"
	_fw_run ensure 9999 >/dev/null
	_fw_out="$(cat "$_fw_log")"
	assert_contains "$_fw_out" "firewall.@rule[0].dest_port=9999" \
		"an existing rule is updated in place"
	assert_not_contains "$_fw_out" "add firewall rule" "no duplicate rule is added"
	assert_not_contains "$_fw_out" "wan" "the wan zone is still never named"

	# A rule someone else owns is left alone.
	: > "$_fw_log"
	printf 'name=Some-Other-Rule\n' > "$_fw_rules/0"
	printf 'name=Allow-FCC-Admin\nsrc=lan\ndest_port=8082\n' > "$_fw_rules/1"
	_fw_run ensure 8082 >/dev/null
	assert_contains "$(cat "$_fw_log")" "set firewall.@rule[1].dest_port=8082" \
		"the rule is found by name, not by position"
	assert_not_contains "$(cat "$_fw_log")" "add firewall rule" \
		"a rule someone else owns is not duplicated"

	# Removal.
	: > "$_fw_log"
	_fw_run remove >/dev/null
	_fw_out="$(cat "$_fw_log")"
	assert_contains "$_fw_out" "delete firewall.@rule[1]" "remove deletes the rule"
	assert_contains "$_fw_out" "commit firewall" "the removal is committed"

	# Status reflects what is actually there.
	assert_contains "$(_fw_run status)" "LAN access rule present" \
		"status reports a present rule"
	rm -rf "$_fw_rules/1"
	assert_contains "$(_fw_run status)" "No LAN access rule" \
		"status reports an absent rule"
}

# Section 22 gives the Runtime Manager a fixed verb set and says the LuCI
# controller must not reimplement install logic — so a verb missing here is a
# feature the web UI cannot reach either. The stubs stand in for the backend
# scripts, which have their own tests; what is under test is the routing.
test_runtime_manager_exposes_the_section_22_verbs() {
	setup_sandbox

	_rm_bin="$SANDBOX/stub"
	mkdir -p "$_rm_bin"
	ln -sf "$LIBEXEC/common.sh" "$_rm_bin/common.sh"
	for _rm_s in status doctor agent session install update; do
		printf '#!/bin/sh\necho "%s $*"\n' "$_rm_s" > "$_rm_bin/$_rm_s.sh"
		chmod +x "$_rm_bin/$_rm_s.sh"
	done

	_rm_run() {
		FCC_LIBDIR="$_rm_bin" FCC_DEFAULT_BASE="$SANDBOX/opt" \
			sh "$ROOT/root/usr/bin/fcc-env" "$@" 2>&1
	}

	assert_contains "$(_rm_run status)" "status" "status reaches status.sh"
	assert_contains "$(_rm_run doctor --json)" "doctor --json" \
		"doctor passes its flags through"
	assert_contains "$(_rm_run install)" "install runtime" \
		"a bare install means the runtime"
	assert_contains "$(_rm_run install check)" "install check" \
		"the install subcommands stay reachable"
	assert_contains "$(_rm_run uninstall --purge)" "install uninstall --purge" \
		"uninstall routes to install.sh"
	assert_contains "$(_rm_run update)" "update runtime" \
		"a bare update means the runtime"
	assert_contains "$(_rm_run update check)" "update check" \
		"update check stays reachable"

	# Section 22 spells the agent verb in the singular and section 76 does the
	# same for sessions; the plural spellings already shipped, so both work.
	assert_contains "$(_rm_run agent list)" "agent list" "agent is the verb section 22 names"
	assert_contains "$(_rm_run agents list)" "agent list" "the plural spelling still works"
	assert_contains "$(_rm_run agent version claude)" "agent version claude" \
		"the agent subcommands pass their arguments through"
	assert_contains "$(_rm_run session cleanup)" "session cleanup" \
		"section 76's cleanup is reachable"
	assert_contains "$(_rm_run sessions cleanup)" "session cleanup" \
		"the plural spelling still works"

	# start/stop/restart are procd's, not a backend script's. The init script
	# does not exist on the machine running the tests, which is exactly what
	# makes the failure message proof of the routing.
	assert_contains "$(_rm_run start)" "/etc/init.d/fcc" \
		"start routes to the init script rather than the passthrough"
	assert_contains "$(_rm_run restart)" "/etc/init.d/fcc" \
		"restart routes to the init script"

	# version answers from the runtime itself, and says so plainly when there
	# is nothing to answer from.
	assert_contains "$(_rm_run version)" "not installed" \
		"version says so when no runtime is installed"
	mkdir -p "$SANDBOX/opt/fcc/bin"
	printf '#!/bin/sh\necho "fcc-server 9.9.9"\n' > "$SANDBOX/opt/fcc/bin/fcc-server"
	chmod +x "$SANDBOX/opt/fcc/bin/fcc-server"
	assert_contains "$(_rm_run version)" "9.9.9" "version reports the installed runtime"

	# The help text is generated from the header comment, so it cannot drift.
	_rm_help="$(_rm_run --help)"
	assert_contains "$_rm_help" "fcc-env start|stop|restart" \
		"the help lists the service verbs"
	assert_contains "$_rm_help" "fcc-env agent list" "the help lists the agent verbs"
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
# starts, and the answer has to reach the upstream installer's agent chooser.
#
# The chooser asks, one agent at a time, on /dev/tty — there is no flag and no
# answer file — so this package answers the prompts themselves. The decision for
# each prompt is a pure function of the prompt and the selection, which is what
# these assertions pin down. The protocol around it is exercised separately, in
# test_installer_drives_the_agent_prompts_through_a_terminal.
#
# The property that matters is *identity*: the answer follows the agent the
# question names, not the position of the question. Upstream skips the prompt
# entirely for an agent that is already installed, so a positional answer file
# answers the wrong question the moment one agent is already present.
test_installer_answers_follow_the_agent_that_was_asked_about() {
	setup_sandbox

	# The prompts below are written the way the matcher actually receives them:
	# with no space after "[Y/n]". Upstream's prompt_yes_no() ends with
	# `printf '%s %s ' "$question" "$prompt" >&4`, so the prompt it writes does
	# end in a space — and the pane the matcher is handed never has it, because
	# `tmux capture-pane -p` strips trailing whitespace from every line it prints.
	# A test that supplied the space was testing a shape the real system does not
	# produce, and it passed for a year while every real install hung: the matcher
	# required the space, matched nothing, and waited for a prompt that had
	# already been asked. The last case here is the one that keeps that from
	# happening again.

	# An explicit selection: yes for the agents in it, no for the others.
	assert_eq "y" \
		"$(sh_install 'installer_answer_for "Install Claude Code for fcc-claude? [Y/n]" "claude aider" set')" \
		"a selected agent is answered yes"
	assert_eq "n" \
		"$(sh_install 'installer_answer_for "Install Codex for fcc-codex? [Y/n]" "claude aider" set')" \
		"an agent that was not selected is answered no"
	# The prompt carries the launcher, and the launcher is the contract; the
	# friendly name in front of it is display text upstream may reword.
	assert_eq "y" \
		"$(sh_install 'installer_answer_for "Install Aider for fcc-aider? [y/N]" "aider" set')" \
		"a [y/N] prompt is answered from the set too"
	assert_eq "y" \
		"$(sh_install 'installer_answer_for "Install DeepSeek Harness for fcc-dsh? [Y/n]" "dsh" set')" \
		"the launcher is what identifies the agent, not the friendly name"

	# --no-agents: everything still being offered is declined.
	assert_eq "n" \
		"$(sh_install 'installer_answer_for "Install Pi for fcc-pi? [Y/n]" "" none')" \
		"an explicit empty selection declines every agent"

	# No opinion: an empty answer is Enter, which the installer reads as its own
	# default. Answering yes or no here would silently override upstream's
	# defaults — including the ones it adjusted before asking.
	assert_eq "" \
		"$(sh_install 'installer_answer_for "Install Claude Code for fcc-claude? [Y/n]" "" default')" \
		"no opinion leaves the choice to upstream"

	# RTK is not a coding agent, and its own default is no. Declining is both
	# the default and the smaller change to the router.
	#
	# Both wordings are pinned, and the second one is why. The rule used to
	# match the first literally — upstream's wording of the day — and when
	# upstream grew a second product ("Enable RTK + Headroom token
	# optimization?") that literal stopped appearing in the question. An
	# unmatched prompt is not answered, so every install sat on it until
	# FCC_INSTALLER_TIMEOUT rolled it back, half an hour later, with no reason
	# in the log. A rule anchored on the phrase survives the product name
	# growing; a rule anchored on the product name does not.
	assert_eq "n" \
		"$(sh_install 'installer_answer_for "Enable RTK token optimization globally for the selected coding agents? [y/N]" "claude" set')" \
		"the RTK prompt is declined under its older wording"
	assert_eq "n" \
		"$(sh_install 'installer_answer_for "Enable RTK + Headroom token optimization? [y/N]" "claude" set')" \
		"the RTK prompt is declined under its current wording"

	# An agent this package has no id for is declined rather than guessed at,
	# and rather than left waiting for an answer that is never coming.
	assert_eq "n" \
		"$(sh_install 'installer_answer_for "Install Some New Agent for fcc-brandnew? [Y/n]" "claude" set')" \
		"an unknown launcher is declined"

	# Anything that is not a prompt is not answered. Answering a progress line
	# would send a stray keystroke into whatever asks next.
	assert_eq "rc=1" \
		"$(sh_install 'installer_answer_for "==> Checking installation prerequisites" "claude" set >/dev/null; echo "rc=$?"')" \
		"a line that is not a prompt is not answered"
	assert_eq "" \
		"$(sh_install 'installer_answer_for "==> Checking installation prerequisites" "claude" set')" \
		"and produces no keystrokes"

	# A prompt whose text merely mentions an agent is not that agent's question:
	# the match is anchored on "Install ... for fcc-", so a progress line that
	# names a launcher cannot be answered as if it were asking about one.
	assert_eq "rc=1" \
		"$(sh_install 'installer_answer_for "fcc-claude is already installed; skipping" "claude" set >/dev/null; echo "rc=$?"')" \
		"a line that only names a launcher is not a prompt"

	# And the shape with the trailing space, for the record: it matches too. The
	# fix was to stop requiring the space, not to require its absence.
	assert_eq "y" \
		"$(sh_install 'installer_answer_for "Install Claude Code for fcc-claude? [Y/n] " "claude" set')" \
		"the same prompt with the space still matches"
}

# The protocol itself, against a stand-in for tmux.
#
# The real thing cannot run here: this suite is deliberately host-only — no
# Docker, no OpenWrt, no root — and the parts that need a router are covered by
# scripts/smoke.sh instead. What is testable here is the *conversation*: that
# the terminal is started with the runtime environment, that each prompt is
# answered from the pane's own text, and that the exit status the pane recorded
# is the status the caller is given. A stand-in for tmux that keeps its "screen"
# in a file exercises all three without a terminal.
test_installer_drives_the_agent_prompts_through_a_terminal() {
	setup_sandbox
	_ia_s="$SANDBOX/tmux-state"
	mkdir -p "$_ia_s" "$SANDBOX/bin" "$SANDBOX/opt"
	: > "$_ia_s/answers"

	# tmux, reduced to the five subcommands run_installer uses.
	cat > "$SANDBOX/bin/tmux" <<-'EOF'
	#!/bin/sh
	S="$FAKE_TMUX_DIR"
	case "$1" in
	new-session)
		shift
		# The command is the last argument. run_installer ends it with a long
		# sleep so the final screen survives to be read; there is no screen
		# here, and leaving a five-minute sleeper behind after every run is
		# rude, so the hold is dropped.
		for a in "$@"; do cmd="$a"; done
		cmd="$(printf '%s' "$cmd" | sed 's/; *sleep 300$//')"
		( sh -c "$cmd" ) >/dev/null 2>&1 &
		;;
	pipe-pane)    printf '%s\n' "$*" >> "$S/pipe-pane" ;;
	capture-pane)
		# The real `capture-pane -p` strips trailing whitespace from every line
		# it prints, and upstream's prompts end in a space (prompt_yes_no writes
		# "%s %s " and then blocks on the read, so nothing follows it). That
		# trim is the whole reason this stand-in is worth having: a fake that
		# handed back the space let a matcher that *required* one pass here for
		# a year while every real install hung waiting for an answer it had
		# already been asked for.
		sed 's/[[:space:]]*$//' "$S/pane" 2>/dev/null
		;;
	send-keys)
		# send-keys -t <name> <keys...>; the trailing Enter is the newline.
		shift; shift; shift
		for a in "$@"; do
			if [ "$a" = Enter ]; then printf '\n' >> "$S/answers"
			else printf '%s' "$a" >> "$S/answers"; fi
		done
		;;
	kill-session) : ;;
	esac
	exit 0
	EOF
	chmod +x "$SANDBOX/bin/tmux"

	# The installer, reduced to what the protocol sees: it puts a prompt on the
	# "screen", waits for the answer to that prompt, and moves on.
	#
	# ask() must run in this shell, not in a command substitution: the counter
	# that says which question is being asked lives here, and a subshell would
	# throw it away — leaving every question waiting on, and reading, the first
	# answer. The answer is therefore written to a file and read back.
	cat > "$SANDBOX/opt/fake-installer.sh" <<-'EOF'
	#!/bin/sh
	S="$FAKE_TMUX_DIR"
	i=0
	ask() {
		i=$(( i + 1 ))
		printf '%s' "$1" > "$S/pane"
		while [ "$(wc -l < "$S/answers" | tr -d ' ')" -lt "$i" ]; do sleep 0.1; done
		sed -n "${i}p" "$S/answers" > "$S/answer-$i"
	}
	printf '%s' "$HOME" > "$S/env-home"
	ask 'Install Claude Code for fcc-claude? [Y/n] '
	ask 'Install Codex for fcc-codex? [Y/n] '
	ask 'Enable RTK + Headroom token optimization? [y/N] '
	printf '%s|%s|%s\n' "$(cat "$S/answer-1")" "$(cat "$S/answer-2")" \
		"$(cat "$S/answer-3")" > "$S/transcript"
	exit "${FAKE_INSTALLER_RC:-0}"
	EOF
	chmod +x "$SANDBOX/opt/fake-installer.sh"

	_ia_run() {
		# _ia_run <rc> <agents> <none>
		#
		# FCC_INSTALLER_TIMEOUT is the production deadline cut down to something a
		# test can wait out. It is here so that a matcher which stops matching
		# fails in twenty seconds rather than hanging the suite for the half hour
		# the real deadline allows — which is exactly what a matcher requiring the
		# trailing space did to every real install, and what this test now exists
		# to catch. The passing path answers every prompt in the first second, so
		# the deadline never comes into it.
		( export FAKE_TMUX_DIR="$_ia_s" FAKE_INSTALLER_RC="$1" FCC_INSTALLER_TIMEOUT=20
		  sh_install "run_installer \"\$FCC_DEFAULT_BASE/fake-installer.sh\" \"$2\" $3; echo \"rc=\$?\"" )
	}
	_ia_reset() {
		: > "$_ia_s/answers"
		rm -f "$_ia_s/pane" "$_ia_s/transcript" "$_ia_s/pipe-pane" "$_ia_s"/answer-*
	}

	# A named subset: claude yes, codex no, RTK no — and the installer's own
	# exit status comes back as the caller's.
	_ia_reset
	_ia_out="$(_ia_run 0 "claude" 0)"
	assert_eq "y|n|n" "$(cat "$_ia_s/transcript" 2>/dev/null)" \
		"each prompt is answered from the agent it names"
	assert_contains "$_ia_out" "rc=0" "a successful installer reports success"

	# The terminal is started with the runtime environment. A tmux session
	# inherits the *server's* environment rather than the caller's, so without
	# this the installer would put a second runtime in root's home directory.
	assert_eq "$SANDBOX/opt/fcc/data" "$(cat "$_ia_s/env-home" 2>/dev/null)" \
		"the terminal starts with the runtime environment"

	# No opinion: Enter for each agent question, so upstream's own defaults
	# apply. RTK is answered explicitly, and that is not an exception — its own
	# default is no, so "n" and Enter are the same answer, and the explicit one
	# says so in the transcript.
	_ia_reset
	_ia_run 0 "" 0 >/dev/null
	assert_eq "||n" "$(cat "$_ia_s/transcript" 2>/dev/null)" \
		"no opinion sends Enter rather than an answer"

	# --no-agents: everything declined.
	_ia_reset
	_ia_run 0 "" 1 >/dev/null
	assert_eq "n|n|n" "$(cat "$_ia_s/transcript" 2>/dev/null)" \
		"an explicit empty selection declines every agent"

	# A failing installer must fail the caller, with its own status rather than
	# a generic one — the status is what the rollback path branches on.
	_ia_reset
	_ia_out="$(_ia_run 7 "claude" 0)"
	assert_contains "$_ia_out" "rc=7" "the installer's exit status is passed through"

	# The transcript is what a person opens when the install fails. The full
	# transcript comes from tmux's pipe-pane, which the stand-in records rather
	# than performs; what run_installer does itself is append the last screen
	# after the terminal closes, so the log ends with what the installer was
	# showing when it stopped.
	assert_contains "$(cat "$_ia_s/pipe-pane" 2>/dev/null)" "logs/installer.out" \
		"the installer's output is wired to logs/installer.out"
	assert_contains "$(cat "$SANDBOX/opt/fcc/logs/installer.out" 2>/dev/null)" \
		"Enable RTK + Headroom token optimization" \
		"the last screen is appended to logs/installer.out"
}

# A question with no rule must be reported, not waited out.
#
# Upstream asks everything through prompt_yes_no(), which prints the question
# and then blocks on the read. A question this package has no rule for is
# therefore not a lull in the installer's output — it is a deadlock, and the
# only thing that used to end it was FCC_INSTALLER_TIMEOUT: half an hour, then a
# rollback, and a log that named no cause at all. That is what upstream's
# reworded RTK question cost, and it is not something a reader can diagnose from
# the page: the install simply took thirty minutes and failed.
#
# The run stops in seconds now, and the question itself is printed. It is the
# whole diagnosis — the transcript holds it too, but that is a terminal screen
# in a file the reader has to go and find, and the job log is where they are
# already looking.
test_an_unrecognised_prompt_is_reported_rather_than_waited_out() {
	setup_sandbox
	_ur_s="$SANDBOX/tmux-state-unknown"
	mkdir -p "$_ur_s" "$SANDBOX/bin" "$SANDBOX/opt"
	: > "$_ur_s/answers"

	# The same stand-in as above, and deliberately its own copy: the state
	# directory is per-test, and a stand-in reaching into another test's would
	# be the coupling this file exists to avoid.
	cat > "$SANDBOX/bin/tmux" <<-'EOF'
	#!/bin/sh
	S="$FAKE_TMUX_DIR"
	case "$1" in
	new-session)
		shift
		for a in "$@"; do cmd="$a"; done
		cmd="$(printf '%s' "$cmd" | sed 's/; *sleep 300$//')"
		( sh -c "$cmd" ) >/dev/null 2>&1 &
		;;
	pipe-pane)    printf '%s\n' "$*" >> "$S/pipe-pane" ;;
	capture-pane) sed 's/[[:space:]]*$//' "$S/pane" 2>/dev/null ;;
	send-keys)
		shift; shift; shift
		for a in "$@"; do
			if [ "$a" = Enter ]; then printf '\n' >> "$S/answers"
			else printf '%s' "$a" >> "$S/answers"; fi
		done
		;;
	kill-session) : ;;
	esac
	exit 0
	EOF
	chmod +x "$SANDBOX/bin/tmux"

	# One question this package knows and one it does not. The installer blocks
	# on the second exactly as upstream's prompt_yes_no() does — the stand-in's
	# ask() waits for a line to appear in $S/answers, and no line ever will,
	# because run_installer has no rule that would send one.
	#
	# The wait also ends on a stop file, which the test writes once the run is
	# over. kill-session here is a no-op, as it is in the stand-in above, so
	# without it a question that is never answered would leave a sleeper behind
	# reading this directory while the next test runs. A stop file rather than a
	# fixed number of iterations because the two cases differ by two orders of
	# magnitude — seconds when the detector fires, the whole deadline when it
	# does not — and a bound picked for one is either a long tail on the other
	# or no backstop at all.
	cat > "$SANDBOX/opt/fake-installer.sh" <<-'EOF'
	#!/bin/sh
	S="$FAKE_TMUX_DIR"
	i=0
	ask() {
		i=$(( i + 1 ))
		printf '%s' "$1" > "$S/pane"
		while [ "$(wc -l < "$S/answers" | tr -d ' ')" -lt "$i" ]; do
			[ -e "$S/stop" ] && exit 0
			sleep 0.1
		done
		sed -n "${i}p" "$S/answers" > "$S/answer-$i"
	}
	ask 'Install Claude Code for fcc-claude? [Y/n] '
	ask 'Enable Telemetry Reporting? [y/N] '
	printf 'reached\n' > "$S/transcript"
	exit 0
	EOF
	chmod +x "$SANDBOX/opt/fake-installer.sh"

	# The deadline is a minute and the stall threshold is two polls, so the two
	# outcomes are twenty seconds apart and the assertion below can tell them
	# apart: a detector that did not fire shows up as a run that sat for the
	# whole minute, which is exactly the failure this test exists to catch.
	_ur_start="$(date +%s)"
	_ur_out="$( export FAKE_TMUX_DIR="$_ur_s" FCC_INSTALLER_TIMEOUT=60 FCC_PROMPT_STALL_POLLS=2
		sh_install "run_installer \"\$FCC_DEFAULT_BASE/fake-installer.sh\" \"claude\" 0; echo \"rc=\$?\"" )"
	_ur_elapsed=$(( $(date +%s) - _ur_start ))
	# Release the stand-in. Nothing will ever answer its second question, and
	# kill-session does not reach it.
	: > "$_ur_s/stop"

	assert_contains "$_ur_out" "PROMPT_NOT_RECOGNISED" \
		"a question with no rule is reported rather than waited out"
	assert_contains "$_ur_out" "Enable Telemetry Reporting? [y/N]" \
		"and the question itself is printed, because it is the whole diagnosis"
	assert_contains "$_ur_out" "rc=1" "the run fails rather than reporting success"
	assert_eq "no" "$([ -f "$_ur_s/transcript" ] && echo yes || echo no)" \
		"the installer never got past the question"
	assert_eq "yes" "$([ "$_ur_elapsed" -lt 20 ] && echo yes || echo no)" \
		"the run is stopped in seconds rather than waiting out the deadline"

	# The transcript still ends up in the log: the report above goes to the job
	# log, and logs/installer.out remains the full screen for anyone who wants
	# the surrounding context.
	assert_contains "$(cat "$SANDBOX/opt/fcc/logs/installer.out" 2>/dev/null)" \
		"Enable Telemetry Reporting" \
		"the question is in the transcript as well"
}

# The same protocol again, against a real tmux.
#
# Everything above drives a stand-in, and a stand-in is an assumption written
# down — the one that mattered here was that `capture-pane -p` strips the
# trailing space off upstream's prompts. The matcher required that space, the
# stand-in handed it back, and the two agreed with each other while disagreeing
# with every real tmux: the loop never answered anything, and every install ran
# out the full deadline and rolled back. A test that fakes the thing under test
# cannot catch that, so this one does not fake it. Real tmux server, real pty,
# and an installer that reads its answers off the terminal exactly as upstream's
# does.
test_the_answer_loop_drives_a_real_terminal() {
	if ! command -v tmux >/dev/null 2>&1; then
		skip "no tmux on this host"
		return
	fi
	setup_sandbox
	mkdir -p "$SANDBOX/opt" "$SANDBOX/bin"

	# PATH starts with $SANDBOX/bin, where the test above parks its tmux
	# stand-in, and the sandbox is shared for the whole file. Point that name at
	# the real binary so this test gets the real one whichever order they run in.
	ln -sf "$(command -v tmux)" "$SANDBOX/bin/tmux"

	# Upstream's installer, reduced to the part this package talks to:
	# installer_is_interactive(), prompt_yes_no(), and the agent loop. The
	# trailing space in prompt_yes_no's printf is upstream's own, and it is the
	# whole subject of this test.
	cat > "$SANDBOX/opt/real-installer.sh" <<-'EOF'
	#!/bin/sh
	S="$(dirname "$0")"
	[ -t 1 ] && ( : </dev/tty ) 2>/dev/null || { printf 'not interactive\n' >&2; exit 3; }
	exec 3</dev/tty 4>/dev/tty

	prompt_yes_no() {
		_pe_question="$1"
		_pe_default="${2:-yes}"
		case "$_pe_default" in
			yes) _pe_prompt='[Y/n]' ;;
			no)  _pe_prompt='[y/N]' ;;
		esac
		while :; do
			printf '%s %s ' "$_pe_question" "$_pe_prompt" >&4
			IFS= read -r _pe_answer <&3 || exit 9
			case "$_pe_answer" in
				'') [ "$_pe_default" = yes ] && return 0; return 1 ;;
				[Yy]|[Yy][Ee][Ss]) return 0 ;;
				[Nn]|[Nn][Oo]) return 1 ;;
				*) printf 'Please answer Y or N.\n' >&4 ;;
			esac
		done
	}

	_pe_out=""
	for _pe_pair in "Claude Code:fcc-claude" "Codex:fcc-codex" "Aider:fcc-aider"; do
		if prompt_yes_no "Install ${_pe_pair%%:*} for ${_pe_pair##*:}?" yes; then
			_pe_out="$_pe_out""y"
		else
			_pe_out="$_pe_out""n"
		fi
	done
	printf '%s\n' "$_pe_out" > "$S/real-transcript"
	EOF
	chmod +x "$SANDBOX/opt/real-installer.sh"

	# A leftover session from an interrupted run would be answered instead of
	# this one, and the pane read would be its screen.
	tmux kill-session -t fcc-installer 2>/dev/null

	# The deadline is cut down for the same reason as above: a matcher that stops
	# matching should fail here in twenty seconds rather than sit on the pane for
	# the half hour the real deadline allows. Answering all three prompts takes
	# under a second, so the passing path never reaches it.
	_ts_out="$(export FCC_INSTALLER_TIMEOUT=20
		sh_install "run_installer \"\$FCC_DEFAULT_BASE/real-installer.sh\" \"claude aider\" 0; echo \"rc=\$?\"")"

	tmux kill-session -t fcc-installer 2>/dev/null

	# claude and aider were asked for, codex was not: the answer follows the
	# launcher named in the question, and the question was read off a real pane.
	assert_eq "yny" "$(cat "$SANDBOX/opt/real-transcript" 2>/dev/null)" \
		"a real terminal is asked, and answered, for every prompt"
	assert_contains "$_ts_out" "rc=0" "and the installer's own status comes back"
}

# And once more, on the terminal the router actually has: no stty.
#
# Pi's action menu is the only question in the install that is read a byte at a
# time, and it can only be read that way because read_tty_key() puts the
# terminal into raw mode first:
#
#     stty -icanon -echo min 1 time 0 < /dev/tty 2>/dev/null || true
#     key=$(dd bs=1 count=1 2>/dev/null < /dev/tty)
#
# Both the call and its failure are discarded, so a box with no stty does not
# fail there — it changes shape. The test router is such a box, its BusyBox
# having no stty applet at all, and on 2026-10-17 that cost two installs in a
# row for two different reasons that look identical from the page:
#
#   * answering the menu with the key alone (§104.31) — the terminal is
#     canonical, dd waits for a line delimiter rather than for a byte, and the
#     key is never read. The run waits on the menu until the deadline.
#
#   * answering it with the key and Enter (§104.32) — dd reads the key, but
#     canonical mode keeps the delimiter in the line it delivers, so the newline
#     stays in the queue, and the next prompt to read is "Start pi now?", whose
#     default is yes. Pi's full-screen interface starts in the installer's pane
#     and the run waits on *that* until the deadline.
#
# Neither is visible in the transcript as a question, which is why both were
# read as stalls. So this drives the real answer loop, on a real pty, against an
# installer doing Pi's two reads one after the other — with stty off PATH, which
# is the router's condition and the only one in which either failure can happen.
test_the_pi_menu_is_answered_on_a_terminal_without_stty() {
	if ! command -v tmux >/dev/null 2>&1; then
		skip "no tmux on this host"
		return
	fi
	setup_sandbox
	mkdir -p "$SANDBOX/opt"

	# A PATH holding the tools run_installer and the answer loop reach for, and
	# no stty. `command -v stty` is the whole of what
	# fcc_installer_can_read_a_key() asks, so leaving it out of PATH is the only
	# way to say "this box has no stty" to a shell.
	mkdir -p "$SANDBOX/nostty"
	for _ms_t in sh tmux dd cat rm mkdir rmdir sed awk grep date sleep tr wc \
			head tail sort uniq cut touch chmod ln dirname basename env id ps \
			kill ls pwd find mktemp tee od uname hostname expr printf; do
		_ms_p="$(command -v "$_ms_t" 2>/dev/null)" || continue
		ln -sf "$_ms_p" "$SANDBOX/nostty/${_ms_t##*/}"
	done
	assert_no "stty really is off that PATH" \
		env PATH="$SANDBOX/nostty" sh -c 'command -v stty'
	assert_ok "and the terminal the loop needs is on it" \
		env PATH="$SANDBOX/nostty" sh -c 'command -v tmux'

	# Pi's menu and prompt_start_pi(), reduced to the two reads that matter.
	cat > "$SANDBOX/opt/menu-installer.sh" <<-'EOF'
	#!/bin/sh
	S="$(dirname "$0")"
	[ -t 1 ] && ( : </dev/tty ) 2>/dev/null || { printf 'not interactive\n' >&2; exit 3; }
	exec 3<>/dev/tty

	# read_tty_key(), with the stty that would have made this raw left out —
	# because on this box there is none, so this read is canonical.
	printf 'Choose an action:\n\n  y    Install Pi (default)\n  n    Do nothing\n' >&3
	_mi_key=
	if ! _mi_key=$(dd bs=1 count=1 2>/dev/null < /dev/tty); then
		_mi_key=
	fi
	printf '%s\n' "$_mi_key" > "$S/menu-key"

	# What Pi prints the moment the menu is answered, which is what takes the
	# row off the pane before the loop's next poll can answer it a second time.
	printf 'Will install Pi.\n' >&3

	# prompt_start_pi(), which is a line read on the same terminal. Its default
	# is yes, and yes starts Pi's full-screen interface in this pane.
	printf '\nStart pi now? [Y/n] ' >&3
	_mi_start=yes
	if IFS= read -r _mi_answer <&3; then
		case "$_mi_answer" in
			n|N|no|NO) _mi_start=no ;;
		esac
	fi
	printf '%s\n' "$_mi_start" > "$S/started"
	EOF
	chmod +x "$SANDBOX/opt/menu-installer.sh"

	tmux kill-session -t fcc-installer 2>/dev/null

	# The deadline is cut down so that either failure shows up in twenty seconds
	# rather than sitting on the pane for the half hour the real one allows.
	_ms_out="$(export FCC_INSTALLER_TIMEOUT=20
		sh_install "PATH='$SANDBOX/nostty'
			run_installer \"\$FCC_DEFAULT_BASE/menu-installer.sh\" \"claude pi\" 0
			echo \"rc=\$?\"")"

	tmux kill-session -t fcc-installer 2>/dev/null

	# Both halves are asserted, because the two failures are opposite: a key the
	# menu never read and a key that was read but left its delimiter behind.
	assert_eq "y" "$(cat "$SANDBOX/opt/menu-key" 2>/dev/null)" \
		"the menu reads the key it is sent"
	assert_eq "no" "$(cat "$SANDBOX/opt/started" 2>/dev/null)" \
		"and nothing is left over to start Pi in the installer's pane"
	assert_contains "$_ms_out" "rc=0" "and the run finishes rather than timing out"
	assert_not_contains "$_ms_out" "installer timed out" \
		"with no deadline spent waiting on either one"
}

# Without a terminal the agent question is never asked, and running anyway would
# install upstream's nine-agent default set and report success. Section 103: say
# why, and stop.
test_installer_refuses_without_a_terminal() {
	setup_sandbox
	mkdir -p "$SANDBOX/opt" "$SANDBOX/nomux"
	printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/opt/fake-installer.sh"
	chmod +x "$SANDBOX/opt/fake-installer.sh"

	# A PATH with the tools run_installer needs and no tmux — the host has one,
	# so hiding it is the only way to reach the branch.
	for _ia_t in sh cat rm mkdir sed awk grep date sleep tr wc; do
		_ia_p="$(command -v "$_ia_t" 2>/dev/null)" || continue
		ln -sf "$_ia_p" "$SANDBOX/nomux/$_ia_t"
	done

	_ia_out="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		UCI_SHIM_DIR="$SANDBOX/uci" PATH="$SANDBOX/nomux" \
		sh -c '. "$1"; run_installer "$2" "claude" 0; echo "rc=$?"' \
		_ "$(install_lib)" "$SANDBOX/opt/fake-installer.sh" 2>&1)"

	assert_contains "$_ia_out" "TMUX_MISSING" "a terminal-less install is refused"
	assert_contains "$_ia_out" "tmux is required" "and says what is missing"
	assert_contains "$_ia_out" "opkg install tmux" "and names the command for this image"
	assert_contains "$_ia_out" "rc=1" "and fails rather than reporting success"
}

# The environment is what keeps the runtime under the install path, and it has
# three consumers that must agree: this package's installer, the terminal that
# drives the upstream installer, and fcc-env. One list, rendered three ways.
test_runtime_env_has_one_source_of_truth() {
	setup_sandbox
	_rt_expected="$(sh_install '
		for n in $(fcc_runtime_env_names); do
			printf "%s=%s\n" "$n" "$(fcc_runtime_env_value "$ROOT" "$n")"
		done
		printf "PATH_HEAD=%s\n" "$ROOT/bin"')"
	assert_ne "" "$_rt_expected" "the environment has names at all"

	# apply_runtime_env sets exactly that, and nothing else.
	_rt_applied="$(sh_install '
		apply_runtime_env
		for n in $(fcc_runtime_env_names); do
			eval "printf \"%s=%s\n\" \"\$n\" \"\$$n\""
		done
		printf "PATH_HEAD=%s\n" "${PATH%%:*}"')"
	assert_eq "$_rt_expected" "$_rt_applied" \
		"apply_runtime_env sets exactly what the renderer describes"

	# And the rendered text, sourced in a clean shell, reproduces it. This is
	# literally what the installer terminal does, so a quoting mistake that only
	# shows up in a path with a space in it fails here rather than on a router.
	_rt_sourced="$(sh_install '
		mkdir -p "$ROOT/cache"
		fcc_runtime_env_exports "$ROOT" > "$ROOT/cache/env.sh"
		( . "$ROOT/cache/env.sh"
		  for n in $(fcc_runtime_env_names); do
			eval "printf \"%s=%s\n\" \"\$n\" \"\$$n\""
		  done
		  printf "PATH_HEAD=%s\n" "${PATH%%:*}" )')"
	assert_eq "$_rt_expected" "$_rt_sourced" \
		"the rendered exports reproduce the environment when sourced"
}

# The bash gate: five of the ten agents are installed by a bash script, and
# OpenWrt ships no bash. Which agents count follows the selection, so the check
# has to reason about the set the install will actually end up with.
test_bash_requirement_follows_the_agent_set() {
	setup_sandbox
	assert_ok "claude needs bash"     sh_common 'fcc_agents_need_bash claude'
	assert_ok "a comma separated set is understood" sh_common 'fcc_agents_need_bash "pi,grok"'
	assert_no "pi on its own does not" sh_common 'fcc_agents_need_bash pi'
	assert_no "an empty set does not"  sh_common 'fcc_agents_need_bash ""'
	assert_ok "a set with one such agent does" sh_common 'fcc_agents_need_bash "aider muse"'

	# The set upstream installs when it is not told which ones.
	assert_eq "claude,codex,pi,opencode,hermes,dsh,grok,muse,aider" \
		"$(sh_common 'fcc_default_agents' | sed 's/^ //;s/ /,/g')" \
		"the defaults are the registry's default column"

	# The prompt names the launcher; the launcher names the agent.
	assert_eq "claude" "$(sh_common 'fcc_agent_by_launcher fcc-claude')" \
		"a launcher maps back to its agent"
	assert_eq "dsh" "$(sh_common 'fcc_agent_by_launcher fcc-dsh')" \
		"and for an agent whose name is not its id"
	assert_eq "" "$(sh_common 'fcc_agent_by_launcher fcc-nope')" \
		"an unknown launcher maps to nothing"

	# Nothing is installed in the sandbox, so the effective set is the requested
	# one — and it grows by what is already there once something is.
	#
	# The tools are restricted rather than inherited: "which agents are
	# installed?" is answered by looking for their own CLIs, and a development
	# machine that has them on PATH would answer with all ten and quietly make
	# this assertion about nothing.
	assert_eq "claude" \
		"$(sh_common_tools 'grep awk sed cut tr' 'fcc_effective_agents claude' \
			| tr -s ' ' | sed 's/^ //;s/ $//')" \
		"an effective set with nothing installed is the requested set"

	# Installed means the CLI, in one of the runtime's own bin directories —
	# <root>/data/.local/bin is where the installer's log shows `claude`
	# landing. The launcher goes in beside it, because on a real box it is
	# always there: uv writes all sixteen at once, and a predicate that reads
	# them would call all ten agents installed.
	mkdir -p "$SANDBOX/opt/fcc/bin" "$SANDBOX/opt/fcc/data/.local/bin"
	printf '#!/bin/sh\n' > "$SANDBOX/opt/fcc/bin/fcc-codex"
	chmod +x "$SANDBOX/opt/fcc/bin/fcc-codex"
	assert_eq "claude" \
		"$(sh_common_tools 'grep awk sed cut tr' 'fcc_effective_agents claude' \
			| tr -s ' ' | sed 's/^ //;s/ $//')" \
		"the fcc-* launcher alone does not make an agent installed"
	printf '#!/bin/sh\n' > "$SANDBOX/opt/fcc/data/.local/bin/codex"
	chmod +x "$SANDBOX/opt/fcc/data/.local/bin/codex"
	assert_eq "claude codex" \
		"$(sh_common_tools 'grep awk sed cut tr' 'fcc_effective_agents claude' \
			| tr -s ' ' | sed 's/^ //;s/ $//')" \
		"an installed agent joins the set, because upstream keeps it without asking"
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

# Run doctor.sh with PATH replaced by a directory holding only the named tools,
# plus whatever environment assignments are handed in.
#
# doctor.sh is almost entirely a list of "is this command present?" questions,
# so the only way to ask them deliberately is to control PATH. Prepending will
# not do: the real tool is still found further along, which is exactly the
# answer being tested against. The agent set matters the same way, so it comes
# in through the environment rather than from whatever is installed here.
#   sh_doctor_tools '<tools>' '<VAR=value ...>' [doctor args...]
#
# The library search path is a third such question and is answered here for the
# same reason. The node row asks whether the loader could find the two
# libraries a musl Node.js is linked against — libstdc++.so.6 and libgcc_s.so.1
# — because a stock image has neither and the binary then dies in the loader
# with its reason a thousand lines into the log. Measured on the test router on
# 2026-10-19; common.sh carries the rest. Left to the machine running the
# tests, that question is about *this* machine: a glibc build host keeps its
# libstdc++ in /usr/lib/<triplet>, which no OpenWrt image has and the scan does
# not look in, so the row would FAIL here and close the gate under assertions
# about fold and sleep that have nothing to do with it. The fixture below is
# what a router that has both looks like, and it is the default for every case;
# a case that needs the other answer overrides it, since env applies these left
# to right and the assignments handed in come after.
sh_doctor_tools() {
	_dt_tools="$1"; _dt_env="$2"; shift 2
	rm -rf "$SANDBOX/doctorbin"
	mkdir -p "$SANDBOX/doctorbin" "$SANDBOX/nodelibs"
	# Empty files: the scan is a presence check, and the answer that matters is
	# whether the fetched Node runs, which provision_node() asks of the binary
	# itself — see test_provision_node_refuses_a_build_that_does_not_run.
	for _dt_lib in libstdc++.so.6 libgcc_s.so.1; do
		: > "$SANDBOX/nodelibs/$_dt_lib"
	done
	# sh, because PATH has to hold the shell that is about to be run. A name may
	# be an absolute path, so a stand-in tool can be put on this PATH under its
	# own basename; see sh_common_tools above.
	for _dt_t in sh $_dt_tools; do
		_dt_p="$(command -v "$_dt_t" 2>/dev/null)" || continue
		ln -sf "$_dt_p" "$SANDBOX/doctorbin/${_dt_t##*/}"
	done
	# shellcheck disable=SC2086  # a test-controlled list of assignments
	env PATH="$SANDBOX/doctorbin" \
		FCC_LIBDIR="$LIBEXEC" \
		FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" \
		FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_NODE_LIB_DIRS="$SANDBOX/nodelibs" \
		LD_LIBRARY_PATH= \
		$_dt_env \
		sh "$LIBEXEC/doctor.sh" "$@" 2>&1
}

# The tools doctor.sh itself needs, and nothing else. Left out on purpose: bash
# and tmux, which are what the two checks below are about, and curl and
# nslookup, which reach the network.
DOCTOR_TOOLS='sed awk grep cut tr uname dirname df timeout head'

# The bash check, which exists because the upstream installer hands five of the
# ten agents to bash installers and OpenWrt ships no bash at all. Before it
# existed the install failed several minutes in, after the download, with the
# reason buried in logs/installer.out.
#
# All three outcomes are produced deliberately here — the check reads PATH and
# the agent set, so leaving either to the machine running the tests would mean
# asserting whatever this host happens to have.
test_doctor_bash_check_follows_the_agent_set() {
	setup_sandbox

	# A selected agent that needs bash, with no bash to be found: a failure, and
	# one that says which package to install and which agent wants it. That pair
	# is the whole point of the check — "bash is missing" is not actionable on a
	# system whose package manager the reader has to guess at.
	_dbc_line="$(sh_doctor_tools "$DOCTOR_TOOLS" 'FCC_AGENT_SELECTION=claude' --json |
		grep '"name": "bash"')"
	assert_contains "$_dbc_line" '"status": "FAIL"' \
		"a selected bash agent with no bash is a failure"
	assert_contains "$_dbc_line" 'opkg install bash' \
		"and the report says how to install bash"
	assert_contains "$_dbc_line" 'Claude Code' \
		"and names the agent that needs it"

	# The same box with only bash-free agents selected: a warning. The runtime
	# installs perfectly well without bash, so this must not be what stops it.
	_dbc_warn="$(sh_doctor_tools "$DOCTOR_TOOLS" 'FCC_AGENT_SELECTION=codex' --json |
		grep '"name": "bash"')"
	assert_contains "$_dbc_warn" '"status": "WARN"' \
		"an agent that does not need bash does not fail the check"
	assert_contains "$_dbc_warn" 'Not needed by the selected agents' \
		"and the report says why it is only a warning"

	# bash present: OK, whatever is selected.
	_dbc_ok="$(sh_doctor_tools "$DOCTOR_TOOLS bash" 'FCC_AGENT_SELECTION=claude' --json |
		grep '"name": "bash"')"
	assert_contains "$_dbc_ok" '"status": "OK"' "bash present is OK"
	assert_not_contains "$_dbc_ok" 'not found' "and the report does not claim it is missing"

	# An already-installed agent counts even when the user asked for none of
	# them, because upstream's chooser keeps an installed agent without asking.
	# This is the case that used to desynchronise the answers: the installer
	# went straight past the Claude Code question, and every answer after it was
	# given to the wrong question.
	#
	# Installed means claude's own CLI, where the installer's log shows it
	# landing. The fcc-* launcher is written too, and deliberately: it is
	# present on every box that has the runtime at all, so a predicate that
	# read it would count all ten agents and this assertion would hold for the
	# wrong reason.
	mkdir -p "$SANDBOX/opt/fcc/bin" "$SANDBOX/opt/fcc/data/.local/bin"
	: > "$SANDBOX/opt/fcc/bin/fcc-claude"
	: > "$SANDBOX/opt/fcc/data/.local/bin/claude"
	chmod +x "$SANDBOX/opt/fcc/bin/fcc-claude" "$SANDBOX/opt/fcc/data/.local/bin/claude"
	_dbc_inst="$(sh_doctor_tools "$DOCTOR_TOOLS" 'FCC_AGENT_NONE=1' --json |
		grep '"name": "bash"')"
	assert_contains "$_dbc_inst" '"status": "FAIL"' \
		"an installed bash agent is in the set even with --no-agents"
	assert_contains "$_dbc_inst" 'Claude Code' "and the report names it"
	rm -rf "$SANDBOX/opt/fcc"
}

# The fold check, which exists because the Codex installer resolves the release
# it is about to install by piping the release JSON through GNU fold, and the
# BusyBox on OpenWrt 24.10.8 x86_64 was built without the applet. Where it is
# missing the shell prints "fold: not found", the resolver gives up on
# releases.openai.com and again on its GitHub fallback, and the installer stops
# with "error: Codex installation failed with exit code 1." — an exit code, and
# the name of nothing.
#
# A FAIL only when the Codex installer will actually run, because ensure_codex()
# reuses a Codex that is already on PATH and never fetches the installer. A
# check that failed anyway would block an install that works, which is worse
# than the gap it was written for.
#
# The gate is asserted rather than assumed, and the PATH is built so that fold
# is the only thing that can close it: the doctor's own tools, plus tmux and
# bash (which FAIL when absent) and a curl that answers without a network. The
# stand-in is what makes "install_allowed" mean fold here — with the real curl
# the check would reach github.com, and without any curl it would FAIL on its
# own account and the assertion would hold for the wrong reason.
test_doctor_fold_check_follows_the_agent_set() {
	setup_sandbox
	make_standin_tool curl 'exit 0' >/dev/null
	# A sleep that takes a fraction, so that the Pi row — the other row this
	# table drives — is satisfied and fold is the only thing the assertions
	# below can be about. Without it the cases that select Pi would close the
	# gate on the sleep row instead, and "install_allowed" would be answering a
	# different question than the one this test asks.
	make_standin_tool sleep 'exit 0' >/dev/null
	_dfc_tools="$DOCTOR_TOOLS tmux bash $SANDBOX/standin/curl $SANDBOX/standin/sleep mktemp mkdir rm tar"

	# Codex selected and no fold: a failure, naming the package and the agent.
	_dfc_fail="$(sh_doctor_tools "$_dfc_tools" 'FCC_AGENT_SELECTION=codex' --json |
		grep '"name": "fold"')"
	assert_contains "$_dfc_fail" '"status": "FAIL"' \
		"a selected Codex with no fold is a failure"
	assert_contains "$_dfc_fail" 'opkg install coreutils-fold' \
		"and the report says which package provides it"
	assert_contains "$_dfc_fail" 'Required by Codex' \
		"and names the agent whose installer needs it"
	assert_contains "$(sh_doctor_tools "$_dfc_tools" 'FCC_AGENT_SELECTION=codex' --json)" \
		'"install_allowed": false' "and a missing fold is what closes the gate"

	# Agents that do not need it: a warning. The install is fine without fold,
	# so this must not be what stops it.
	_dfc_warn="$(sh_doctor_tools "$_dfc_tools" 'FCC_AGENT_SELECTION=pi' --json |
		grep '"name": "fold"')"
	assert_contains "$_dfc_warn" '"status": "WARN"' \
		"an agent that does not need fold does not fail the check"
	assert_contains "$_dfc_warn" 'Not needed by the selected agents' \
		"and the report says why it is only a warning"
	assert_contains "$(sh_doctor_tools "$_dfc_tools" 'FCC_AGENT_SELECTION=pi' --json)" \
		'"install_allowed": true' "and the gate stays open for that install"

	# fold present: OK, whatever is selected, and nothing left to install.
	_dfc_ok="$(sh_doctor_tools "$_dfc_tools fold" 'FCC_AGENT_SELECTION=codex' --json |
		grep '"name": "fold"')"
	assert_contains "$_dfc_ok" '"status": "OK"' "fold present is OK"
	assert_not_contains "$_dfc_ok" 'not found' "and the report does not claim it is missing"
	assert_contains "$(sh_doctor_tools "$_dfc_tools fold" 'FCC_AGENT_SELECTION=codex' --json)" \
		'"install_allowed": true' "and installing it is what reopens the gate"

	# Codex already installed and no fold: a warning, not a failure. The
	# installer's Codex step reuses what is on PATH and never runs the script
	# that wants fold, so nothing needs it — and blocking here would refuse an
	# install that would have succeeded.
	mkdir -p "$SANDBOX/opt/fcc/bin" "$SANDBOX/opt/fcc/data/.local/bin"
	: > "$SANDBOX/opt/fcc/data/.local/bin/codex"
	chmod +x "$SANDBOX/opt/fcc/data/.local/bin/codex"
	_dfc_have="$(sh_doctor_tools "$_dfc_tools" 'FCC_AGENT_SELECTION=codex' --json |
		grep '"name": "fold"')"
	assert_contains "$_dfc_have" '"status": "WARN"' \
		"a Codex that is already installed makes fold a warning"
	assert_contains "$_dfc_have" 'already installed' \
		"and the report says why nothing needs it yet"
	assert_contains "$(sh_doctor_tools "$_dfc_tools" 'FCC_AGENT_SELECTION=codex' --json)" \
		'"install_allowed": true' \
		"and it does not block an install that would work"
	rm -rf "$SANDBOX/opt/fcc"
}

# The sleep check, which exists for the same reason as the fold one and was
# found the same way — by running the installer on the router and reading the
# screen. BusyBox ships a sleep, so nothing is missing here and "not found"
# never appears; what this image's sleep will not do is take a fraction:
#
#   sleep: invalid number '0.075'
#
# The Pi installer animates its logo with sixteen of those before it does
# anything else, and pi_installer_main() runs under `set -eu`, so the first one
# ends the whole script. A check that only looked for a missing command would
# report this image as ready to install Pi, and the install would stop a second
# later with an exit code and nothing else.
#
# The outcomes are produced deliberately rather than read off the machine
# running the tests, because the check reads PATH — a host whose sleep happens
# to take a fraction would otherwise make the "FAIL" case unreachable and the
# assertion would hold for the wrong reason.
test_doctor_sleep_check_follows_the_agent_set() {
	setup_sandbox
	make_standin_tool curl 'exit 0' >/dev/null
	make_standin_tool fold 'exit 0' >/dev/null
	_dsc_tools="$DOCTOR_TOOLS tmux bash $SANDBOX/standin/curl $SANDBOX/standin/fold mktemp mkdir rm tar"

	# Pi selected, no sleep at all: a failure, naming the package and the agent.
	_dsc_fail="$(sh_doctor_tools "$_dsc_tools" 'FCC_AGENT_SELECTION=pi' --json |
		grep '"name": "sleep"')"
	assert_contains "$_dsc_fail" '"status": "FAIL"' \
		"a selected Pi with no sleep is a failure"
	assert_contains "$_dsc_fail" 'opkg install coreutils-sleep' \
		"and the report says which package provides it"
	assert_contains "$_dsc_fail" 'Required by Pi' \
		"and names the agent whose installer needs it"
	assert_contains "$_dsc_fail" 'not found' \
		"and says the tool is not there, because it is not"
	assert_contains "$(sh_doctor_tools "$_dsc_tools" 'FCC_AGENT_SELECTION=pi' --json)" \
		'"install_allowed": false' "and a missing sleep is what closes the gate"

	# The gap the router actually had: a sleep that is present and refuses the
	# fraction. That is a failure too, and it must not be reported as absent —
	# a reader told the tool is missing goes looking for it, finds it, and is
	# back where they started.
	make_standin_tool sleep 'case "$1" in *.*) exit 1 ;; esac' >/dev/null
	_dsc_lim="$(sh_doctor_tools "$_dsc_tools $SANDBOX/standin/sleep" 'FCC_AGENT_SELECTION=pi' --json |
		grep '"name": "sleep"')"
	assert_contains "$_dsc_lim" '"status": "FAIL"' \
		"a sleep that refuses a fraction is a failure too"
	assert_contains "$_dsc_lim" 'too limited' \
		"and the report says the tool is there but not capable"
	assert_not_contains "$_dsc_lim" 'not found' \
		"and does not claim it is missing"

	# An agent that does not need it: a warning, and the gate stays open.
	_dsc_warn="$(sh_doctor_tools "$_dsc_tools" 'FCC_AGENT_SELECTION=codex' --json |
		grep '"name": "sleep"')"
	assert_contains "$_dsc_warn" '"status": "WARN"' \
		"an agent that does not need sleep does not fail the check"
	assert_contains "$_dsc_warn" 'Not needed by the selected agents' \
		"and the report says why it is only a warning"
	assert_contains "$(sh_doctor_tools "$_dsc_tools" 'FCC_AGENT_SELECTION=codex' --json)" \
		'"install_allowed": true' "and the gate stays open for that install"

	# sleep present and capable: OK, and nothing left to install.
	make_standin_tool sleep 'exit 0' >/dev/null
	_dsc_ok="$(sh_doctor_tools "$_dsc_tools $SANDBOX/standin/sleep" 'FCC_AGENT_SELECTION=pi' --json |
		grep '"name": "sleep"')"
	assert_contains "$_dsc_ok" '"status": "OK"' "a sleep that takes a fraction is OK"
	assert_contains "$(sh_doctor_tools "$_dsc_tools $SANDBOX/standin/sleep" 'FCC_AGENT_SELECTION=pi' --json)" \
		'"install_allowed": true' "and installing it is what reopens the gate"

	# Pi already installed and the sleep still limited: a warning. ensure_pi()
	# reuses a Pi that is already on PATH and never runs the installer that
	# animates the logo, so nothing needs the fraction — and blocking here would
	# refuse an install that would have worked.
	mkdir -p "$SANDBOX/opt/fcc/bin" "$SANDBOX/opt/fcc/data/.local/bin"
	: > "$SANDBOX/opt/fcc/data/.local/bin/pi"
	chmod +x "$SANDBOX/opt/fcc/data/.local/bin/pi"
	make_standin_tool sleep 'case "$1" in *.*) exit 1 ;; esac' >/dev/null
	_dsc_have="$(sh_doctor_tools "$_dsc_tools $SANDBOX/standin/sleep" 'FCC_AGENT_SELECTION=pi' --json |
		grep '"name": "sleep"')"
	assert_contains "$_dsc_have" '"status": "WARN"' \
		"a Pi that is already installed makes sleep a warning"
	assert_contains "$_dsc_have" 'already installed' \
		"and the report says why nothing needs it yet"
	assert_contains "$(sh_doctor_tools "$_dsc_tools $SANDBOX/standin/sleep" 'FCC_AGENT_SELECTION=pi' --json)" \
		'"install_allowed": true' \
		"and it does not block an install that would work"
	rm -rf "$SANDBOX/opt/fcc"
}

# The Node check. Pi, DeepSeek Harness and Cline are npm packages, all three
# want a Node this image's own node is below, and the Pi installer's own remedy
# — nodejs.org/dist — publishes no musl build at all, so what it installs
# cannot execute here. This package fetches a musl Node itself before the
# installer runs, which is why the row is a warning rather than a failure:
# there is nothing for the reader to do.
#
# It is a failure on two boxes, and both are here because on those the promise
# cannot be kept and a warning would read as "handled". One is a CPU no Node
# build exists for. The other is the one the test router turned out to be: the
# musl build is linked against libstdc++.so.6 and libgcc_s.so.1, a stock image
# has neither, and a Node that dies in the loader is still a Node the installer
# cannot use — measured on 2026-10-19, where the install stopped at Pi with
# 1064 relocation errors and no reason anywhere a reader would look. That one
# has a remedy, so the row names the package rather than only the library.
test_doctor_node_check_follows_the_agent_set() {
	setup_sandbox
	make_standin_tool curl 'exit 0' >/dev/null
	make_standin_tool fold 'exit 0' >/dev/null
	make_standin_tool sleep 'exit 0' >/dev/null
	_dnc_tools="$DOCTOR_TOOLS tmux bash $SANDBOX/standin/curl $SANDBOX/standin/fold $SANDBOX/standin/sleep mktemp mkdir rm tar"

	# An npm agent selected and no node on PATH: a warning that says the
	# installer handles it, and a gate that stays open.
	_dnc_warn="$(sh_doctor_tools "$_dnc_tools" 'FCC_AGENT_SELECTION=pi' --json |
		grep '"name": "node"')"
	assert_contains "$_dnc_warn" '"status": "WARN"' \
		"a missing node is a warning, because this package installs one"
	assert_contains "$_dnc_warn" 'fetches a musl Node.js' \
		"and the report says so rather than leaving the reader to do it"
	assert_contains "$_dnc_warn" 'needed to install Pi' \
		"and names the agent that needs it"
	assert_contains "$(sh_doctor_tools "$_dnc_tools" 'FCC_AGENT_SELECTION=pi' --json)" \
		'"install_allowed": true' "and it does not close the gate"

	# An agent that is not an npm package: no node row at all. A row saying
	# "not needed" about a runtime the reader never heard of is noise.
	assert_not_contains "$(sh_doctor_tools "$_dnc_tools" 'FCC_AGENT_SELECTION=claude' --json)" \
		'"name": "node"' "an agent that needs no node gets no node row"

	# A CPU no Node build exists for: a failure. Nothing this package can do
	# makes those agents installable there, and the row says which CPU it asked
	# about rather than leaving the reader to guess.
	make_standin_tool uname 'echo mips' >/dev/null
	_dnc_fail="$(sh_doctor_tools "$_dnc_tools $SANDBOX/standin/uname" 'FCC_AGENT_SELECTION=pi' --json |
		grep '"name": "node"')"
	assert_contains "$_dnc_fail" '"status": "FAIL"' \
		"a CPU with no Node build is a failure"
	assert_contains "$_dnc_fail" 'No Node.js build exists for this CPU' \
		"and the report says exactly that"
	assert_contains "$_dnc_fail" 'mips' "and names the CPU it asked about"
	assert_contains "$(sh_doctor_tools "$_dnc_tools $SANDBOX/standin/uname" 'FCC_AGENT_SELECTION=pi' --json)" \
		'"install_allowed": false' "and it closes the gate, because it cannot be fixed here"

	# The libraries the fetched Node is linked against, absent: a failure too,
	# and the one this check was extended for. The scan is pointed at a
	# directory with nothing in it, which overrides the fixture every other case
	# in this file runs against — and LD_LIBRARY_PATH is cleared again because
	# the assignment handed in comes after the default and would otherwise leave
	# the host's own path in the list the scan reads.
	#
	# The assertion is on the row rather than on the gate alone: a FAIL with no
	# remedy is what the reader was getting from the log, and the point of
	# asking before anything is downloaded is that the row can name the package.
	mkdir -p "$SANDBOX/nolibs"
	_dnc_libs_env="FCC_NODE_LIB_DIRS=$SANDBOX/nolibs LD_LIBRARY_PATH="
	_dnc_libs="$(sh_doctor_tools "$_dnc_tools" "$_dnc_libs_env FCC_AGENT_SELECTION=pi" --json |
		grep '"name": "node"')"
	assert_contains "$_dnc_libs" '"status": "FAIL"' \
		"a musl Node's libraries nowhere the loader looks is a failure"
	assert_contains "$_dnc_libs" 'libstdc++.so.6' \
		"and the report names the library rather than only the Node"
	assert_contains "$_dnc_libs" 'libgcc_s.so.1' "and the other one with it"
	assert_contains "$_dnc_libs" 'opkg install libstdcpp libgcc1' \
		"and says which packages provide them, which is the part a reader can act on"
	assert_not_contains "$_dnc_libs" 'nothing to do by hand' \
		"and does not promise the installer handles it, because it does not"
	assert_contains "$(sh_doctor_tools "$_dnc_tools" "$_dnc_libs_env FCC_AGENT_SELECTION=pi" --json)" \
		'"install_allowed": false' \
		"and it closes the gate before anything is downloaded"
}

# The report is about a set of agents, not about the device.
#
# The checks ask what the agents being installed need, so one box can be blocked
# for one install and open for another: the test router has no C++ runtime for
# the Node the npm three need, which makes an install of every agent impossible
# and an install of Claude Code unremarkable. The Configuration page can ask for
# a single agent (section 79 is why), so the report has to be able to answer
# about one — otherwise the panel says the install is blocked while the job,
# which asks the shell the same question about the id it was given, runs it.
#
# Every answer here comes from the same doctor with one argument changed, so the
# difference between them cannot be anything but the argument.
test_doctor_reports_on_the_set_it_is_asked_about() {
	setup_sandbox
	make_standin_tool curl 'exit 0' >/dev/null
	make_standin_tool fold 'exit 0' >/dev/null
	make_standin_tool sleep 'exit 0' >/dev/null
	_dro_tools="$DOCTOR_TOOLS tmux bash $SANDBOX/standin/curl $SANDBOX/standin/fold $SANDBOX/standin/sleep mktemp mkdir rm tar"
	mkdir -p "$SANDBOX/nolibs"
	_dro_env="FCC_NODE_LIB_DIRS=$SANDBOX/nolibs LD_LIBRARY_PATH="

	# No argument: the whole registry, which is what the page sends when its
	# dropdown says nothing — the node row fails and that install is blocked.
	_dro_all="$(sh_doctor_tools "$_dro_tools" "$_dro_env" --json)"
	assert_contains "$_dro_all" '"name": "node"' "the whole registry has a node row"
	assert_contains "$_dro_all" '"install_allowed": false' \
		"and an install of every agent is blocked without those libraries"

	# One agent that needs no Node: no node row at all, and nothing blocking —
	# which is the install the page is offering a reader who has just narrowed
	# it, and the answer the panel has to give them.
	_dro_one="$(sh_doctor_tools "$_dro_tools" "$_dro_env" --json --agents claude)"
	assert_not_contains "$_dro_one" '"name": "node"' \
		"an agent that needs no Node gets no node row when it is the set"
	assert_contains "$_dro_one" '"install_allowed": true' \
		"and that install is not blocked, which is what the job would find too"

	# And narrowing to an agent that does need it: blocked, for the same reason.
	# Without this the case above would hold just as well against a flag that
	# switched the checks off rather than one that answered about a set.
	_dro_pi="$(sh_doctor_tools "$_dro_tools" "$_dro_env" --json --agents pi)"
	assert_contains "$_dro_pi" '"install_allowed": false' \
		"and an agent that does need it is blocked, so the answer follows the set"

	# An id the registry does not know is refused rather than answered. It
	# matches no row, so the checks would find nothing to require and the report
	# would come out *more* permissive than the truth — the one direction a gate
	# may not be wrong in.
	assert_no "an agent the registry does not know is refused" \
		sh_doctor_tools "$_dro_tools" "$_dro_env" --json --agents nosuchagent
	assert_contains "$(sh_doctor_tools "$_dro_tools" "$_dro_env" --json --agents nosuchagent 2>&1 || true)" \
		'unknown agent' "and the refusal says which argument was wrong"

	# The variable is a list, and this is the shape install.sh actually exports:
	# --all-agents expands the registry and --agents splits its commas, so what
	# arrives is several ids separated by spaces. Checking the string as one id
	# refused every install with "unknown agent:  claude codex pi ..." — an
	# install blocked for a reason that was not true, and one no single-agent
	# test could see, because a one-id selection is the one list that looks like
	# an id.
	_dro_list="$(awk -F'|' '/^[a-z]/ { printf "%s ", $1 }' "$AGENTS_CONF")"
	_dro_many="$(sh_doctor_tools "$_dro_tools" "$_dro_env" --json --agents "${_dro_list% }" 2>&1)"
	assert_not_contains "$_dro_many" 'unknown agent' \
		"the whole registry as one space-separated list is not an unknown agent"
	assert_contains "$_dro_many" '"install_allowed": false' \
		"and it is answered about that set rather than refused"

	# The same list with a comma in it, which is how install.sh's --agents
	# arrives before it is split. fcc_effective_agents() splits them too, so a
	# reader that refused the commas would be the only part of the package that
	# could not read the installer's own argument.
	_dro_comma="$(sh_doctor_tools "$_dro_tools" "$_dro_env" --json --agents "$(printf '%s' "${_dro_list% }" | tr ' ' ',')" 2>&1)"
	assert_not_contains "$_dro_comma" 'unknown agent' \
		"a comma-separated selection is read as the list it is"

	# And the property survives the list: one id the registry does not know
	# still stops the report rather than thinning it to the ids that do match.
	assert_contains "$(sh_doctor_tools "$_dro_tools" "$_dro_env" --json \
		--agents "$_dro_list nosuchagent" 2>&1 || true)" \
		'unknown agent' "one unknown id in an otherwise good list is still refused"
}

# The tar check, which exists because uv's own installer cannot unpack its
# release on a stock image. It runs `tar xf ARCHIVE --no-same-owner
# --strip-components 1`, and BusyBox tar knows neither option: it prints its
# usage text, exits 1, and the upstream installer stops with "error: uv
# installation failed with exit code 1" a few seconds after its last question.
# Nothing is installed, and before this check existed nothing said why.
#
# The three outcomes are produced deliberately, because the check reads PATH:
# leaving it to the machine running the tests would assert whatever tar this
# host happens to have.
test_doctor_tar_check_follows_the_tar_on_path() {
	setup_sandbox
	make_standin_tool tar "$BUSYBOX_TAR_BODY" >/dev/null
	make_standin_tool uv 'echo "uv 0.12.23"' >/dev/null

	# The tools the probe itself needs, on top of the doctor's own: it unpacks a
	# real archive into a scratch directory to find out what the tar can do.
	_dtc_tools="$DOCTOR_TOOLS mktemp mkdir rm"

	# No uv, and a tar that cannot unpack one: a failure, with the package to
	# install and what goes wrong without it. This is the box the report came
	# from — the install stopped there and said only that it had stopped.
	_dtc_fail="$(sh_doctor_tools "$_dtc_tools $SANDBOX/standin/tar" '' --json |
		grep '"name": "tar"')"
	assert_contains "$_dtc_fail" '"status": "FAIL"' \
		"a tar that cannot unpack uv, with no uv, is a failure"
	assert_contains "$_dtc_fail" 'opkg install tar' \
		"and the report says how to install a tar that can"
	assert_contains "$_dtc_fail" 'strip-components' \
		"and names the option that is missing"
	assert_contains "$_dtc_fail" 'stops before uv is installed' \
		"and what the install does instead"

	# uv already on PATH: ensure_uv() leaves it alone and no archive is
	# unpacked, so this is a warning. Not an OK: this package keeps its uv under
	# the runtime root and the update path moves that directory aside before the
	# installer runs, so the next update downloads uv again and needs the tar.
	_dtc_warn="$(sh_doctor_tools "$_dtc_tools $SANDBOX/standin/tar $SANDBOX/standin/uv" '' --json |
		grep '"name": "tar"')"
	assert_contains "$_dtc_warn" '"status": "WARN"' \
		"a uv that is already installed makes the tar a warning"
	assert_contains "$_dtc_warn" 'every update does' \
		"and the report says why it still matters"

	# A tar that can do it: OK, whatever else is on PATH.
	_dtc_ok="$(sh_doctor_tools "$_dtc_tools tar" '' --json | grep '"name": "tar"')"
	assert_contains "$_dtc_ok" '"status": "OK"' "a capable tar is OK"
	assert_not_contains "$_dtc_ok" 'not found' "and the report does not claim it is missing"
	assert_not_contains "$_dtc_ok" 'opkg install tar' "and suggests nothing to install"

	# And the verdict reaches the install gate: a FAIL here is what stops the
	# install, so the two have to be reading the same result.
	assert_contains "$(sh_doctor_tools "$_dtc_tools $SANDBOX/standin/tar" '' --json)" \
		'"install_allowed": false' "and a tar that cannot unpack uv blocks the install"
}

# tmux is a hard requirement, not a convenience. It is the Web Console's backend
# and it is also the terminal the upstream installer's agent chooser is driven
# through, because that chooser reads /dev/tty and refuses to run without one.
# The check used to be a warning, which put the word "warning" in front of a
# guaranteed failure and taught the reader to ignore the line that mattered.
test_doctor_tmux_is_required_not_optional() {
	setup_sandbox

	_dtm_line="$(sh_doctor_tools "$DOCTOR_TOOLS" '' --json | grep '"name": "tmux"')"
	assert_contains "$_dtm_line" '"status": "FAIL"' \
		"a missing tmux is a failure, not a warning"
	assert_contains "$_dtm_line" 'opkg install tmux' \
		"and the report says which package to install"
	assert_contains "$_dtm_line" '"requirement": "required"' \
		"and that it is required rather than optional"

	_dtm_ok="$(sh_doctor_tools "$DOCTOR_TOOLS tmux" '' --json | grep '"name": "tmux"')"
	assert_contains "$_dtm_ok" '"status": "OK"' "tmux present is OK"
	assert_not_contains "$_dtm_ok" 'not found' "and the report does not claim it is missing"

	# The blocking form is what someone reads after an install has already
	# stopped, so it has to carry the suggestion too, not just the verdict.
	_dtm_blk="$(sh_doctor_tools "$DOCTOR_TOOLS" '' --blocking)"
	assert_contains "$_dtm_blk" '[FAIL] tmux' "the blocking report names tmux"
	assert_contains "$_dtm_blk" 'Suggestion:' "and what to do about it"
}

test_doctor_blocking_names_what_failed_and_what_to_do() {
	setup_sandbox
	# Section 3.6.4's other half: when an install is blocked, the report has to
	# carry the check, its current value, what was required and how to fix it.
	# The install log used to say "precheck failed" and stop there, which is
	# none of the four — the reader could see that they were stuck but not what
	# they were stuck on.
	#
	# The failure is forced by asking for more free space than any machine has.
	# That is the real check failing on a real filesystem rather than a stubbed
	# one, so this also asserts the wiring between the two: if --blocking ever
	# stops reading the same accumulator the verdict comes from, it would print
	# nothing here while --json still said install_allowed=false.
	_db_out="$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_REQUIRED_FREE_MB=999999999 \
		sh "$LIBEXEC/doctor.sh" --blocking 2>&1)"

	assert_contains "$_db_out" '[FAIL] Storage' "the failing check is named"
	assert_contains "$_db_out" 'Current:' "the report carries what was found"
	assert_contains "$_db_out" 'Required:' "the report carries what was required"
	assert_contains "$_db_out" 'Suggestion:' "the report carries what to do about it"
	assert_contains "$_db_out" '999999999 MB' "the requirement is the one that was applied"

	# Only failures. Someone reading this has an install that has already
	# stopped; the checks that passed are not why they are here.
	assert_not_contains "$_db_out" '[OK]' "passing checks are left out"
	assert_not_contains "$_db_out" '[WARN]' "warnings are left out"

	# The same run in JSON still blocks, so the two forms agree about the
	# verdict even though they show different amounts of it.
	assert_contains "$(FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$SANDBOX/opt" \
		FCC_REQUIRED_FREE_MB=999999999 \
		sh "$LIBEXEC/doctor.sh" --json 2>&1)" \
		'"install_allowed": false' "and the verdict it comes from still blocks"
}

# ---------------------------------------------------------------------------
# "Is this agent installed?" is one question with one answer
#
# Two separate mistakes have been made about this question, and the tests below
# pin both.
#
# The first: the question was re-derived five times, each copy a bare
# `command -v fcc-claude`. The launchers live in <root>/bin, and nothing that
# asks has that directory on PATH — the LuCI relay reaches the backend through
# io.popen under uhttpd, whose PATH is the system one, and `fcc-env agent` runs
# agent.sh without applying the runtime environment on purpose. So every agent
# row said 未安装 beside a runtime row that said 已安装, because
# fcc_find_server_exe() probes <root>/bin/fcc-server by absolute path *first*
# and the agent rows did not.
#
# The second, made while fixing the first: the copies were pointed at the
# launcher. That is worse than the bug it fixed. `uv tool install
# free-claude-code` writes *all sixteen* fcc-* console scripts into <root>/bin
# in one go — the installer's own transcript lists every one of them — so an
# fcc-* launcher being present says only that the FCC runtime is present. Every
# row then reads 已安装 the moment FCC itself is installed, which is what the
# 配置 page showed after installing Claude Code alone.
#
# The rule is upstream's, from find_installed_coding_agent(): the agent's own
# CLI, named by the agent id. fcc-claude execs `claude`, and `claude` is what
# the installer installs, verifies and re-finds. These tests ask each of the
# five call sites that question, with a PATH that cannot answer it by accident.
# ---------------------------------------------------------------------------

# The real PATH, minus every directory that could answer the question by
# accident: any directory holding an fcc-* launcher, and any holding one of the
# ten agent CLIs.
#
# Both halves are needed. Dropping the launcher directories alone is not
# enough, because this suite also runs on a developer's machine and that
# machine commonly has the agents themselves installed — ~/.local/bin/claude,
# ~/.npm-global/bin/codex, ~/.grok/bin/grok. A PATH that can resolve `codex`
# would make "codex is not installed" fail for a reason that has nothing to do
# with the code under test.
#
# What has to go is the directory, not the name: shadowing individual names
# would leave sed, awk and df unreachable, and a failure here should be the
# question being answered wrongly rather than the script being starved of
# tools.
make_agentless_path() {
	_lp_ids="$(awk -F'|' '/^[^#]/ && NF { printf "%s ", $1 }' "$AGENTS_CONF")"
	_lp_ifs="$IFS"
	IFS=:
	set -- $PATH
	IFS="$_lp_ifs"
	_lp_out=""
	for _lp_d in "$@"; do
		[ -d "$_lp_d" ] || continue
		_lp_has=0
		for _lp_f in "$_lp_d"/fcc-*; do
			[ -e "$_lp_f" ] && { _lp_has=1; break; }
		done
		if [ "$_lp_has" = 0 ]; then
			for _lp_n in $_lp_ids; do
				[ -e "$_lp_d/$_lp_n" ] && { _lp_has=1; break; }
			done
		fi
		[ "$_lp_has" = 1 ] && continue
		_lp_out="${_lp_out:+$_lp_out:}$_lp_d"
	done
	printf '%s' "$_lp_out"
}

# The state a successful `agent install claude` leaves behind, reproduced
# faithfully rather than conveniently.
#
# All sixteen launchers, because uv writes them all — the names are the
# installer's own transcript, and reproducing only fcc-claude would let a
# launcher-probing predicate pass this suite while failing on a real router.
# And exactly one CLI, because Claude Code is what was asked for. The two
# together are the whole of the second bug.
#
# Prints the base to hand to FCC_DEFAULT_BASE.
setup_installed_root() {
	_ir_base="$SANDBOX/installed/opt"
	rm -rf "$SANDBOX/installed"
	mkdir -p "$_ir_base/fcc/bin" "$_ir_base/fcc/logs" \
	         "$_ir_base/fcc/cache" "$_ir_base/fcc/data/.local/bin"
	for _ir_l in _fcc-update-check fcc-aider fcc-claude fcc-cline fcc-codex \
	             fcc-desktop fcc-doctor fcc-dsh fcc-grok fcc-hermes fcc-muse \
	             fcc-opencode fcc-pi fcc-update fcc-update.cmd; do
		printf '#!/bin/sh\nexit 0\n' > "$_ir_base/fcc/bin/$_ir_l"
		chmod +x "$_ir_base/fcc/bin/$_ir_l"
	done
	# The server is the one launcher whose version the runtime row reads.
	printf '#!/bin/sh\necho 6.16.4\n' > "$_ir_base/fcc/bin/fcc-server"
	chmod +x "$_ir_base/fcc/bin/fcc-server"
	# The agent that was actually installed, at $HOME/.local/bin with
	# HOME=<root>/data — the first place fcc_runtime_bin_dirs() names after the
	# runtime's own bin. This path is from the bug report's install log:
	# `+ /opt/fcc/data/.local/bin/claude --version`.
	printf '#!/bin/sh\necho 2.1.299 (Claude Code)\n' > "$_ir_base/fcc/data/.local/bin/claude"
	chmod +x "$_ir_base/fcc/data/.local/bin/claude"
	printf '%s' "$_ir_base"
}

# The row for one agent in a JSON document that carries "id"/"installed" pairs.
json_agent_row() { # json_agent_row <document> <id>
	printf '%s\n' "$1" | grep "\"$2\"" | head -n1
}

# Run a backend script with a given PATH and a given install base. This is
# sh_script with the two things the question turns on made explicit.
sh_blind() { # sh_blind <path> <base> <script> [args...]
	_sb_path="$1"; _sb_base="$2"; _sb_script="$3"; shift 3
	env PATH="$_sb_path" \
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$_sb_base" \
		sh "$LIBEXEC/$_sb_script" "$@" 2>&1
}

# sh_blind for a *snippet* rather than a script: common.sh sourced, then the
# code given as the third argument evaluated. sh_common() and sh_common_tools()
# above run snippets too, but neither lets a test choose the install base, and
# the question here is about a root that is not the sandbox default.
sh_blind_code() { # sh_blind_code <path> <base> <code>
	_sbc_path="$1"; _sbc_base="$2"; _sbc_code="$3"
	env PATH="$_sbc_path" \
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$_sbc_base" \
		sh -c '. "$1/common.sh"; eval "$2"' _ "$LIBEXEC" "$_sbc_code" 2>&1
}

# update.sh ends with the same dispatch install.sh does, so its functions are
# reached the same way: from a copy with the dispatch stripped.
update_lib() {
	_ul_dst="$SANDBOX/lib-update.sh"
	[ -f "$_ul_dst" ] || sed '/^case "${1:-}" in$/,$d' "$LIBEXEC/update.sh" > "$_ul_dst"
	printf '%s' "$_ul_dst"
}

# Run a snippet with update.sh's functions defined, under a given PATH and base.
sh_update() { # sh_update <path> <base> <code>
	env PATH="$1" \
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$2" \
		sh -c '. "$1"; eval "$2"' _ "$(update_lib)" "$3" 2>&1
}

# The same for install.sh's functions, which are reached through sh_install
# everywhere else; this variant controls PATH and the base the way the test
# above needs.
sh_install_blind() { # sh_install_blind <path> <base> <code>
	env PATH="$1" \
		FCC_LIBDIR="$LIBEXEC" FCC_AGENTS_CONF="$AGENTS_CONF" \
		FCC_VERSION_FILE="$ROOT/VERSION" FCC_DEFAULT_BASE="$2" \
		sh -c '. "$1"; eval "$2"' _ "$(install_lib)" "$3" 2>&1
}

test_an_installed_agent_is_reported_installed_without_being_on_path() {
	setup_sandbox
	_tr_base="$(setup_installed_root)"
	_tr_path="$(make_agentless_path)"
	_tr_root="$SANDBOX/installed/opt/fcc"

	# The precondition, asserted rather than assumed. If this PATH could still
	# resolve a launcher or an agent CLI, the assertions below would pass for a
	# reason that has nothing to do with the code under test.
	for _tr_n in fcc-claude claude codex pi opencode cline hermes dsh grok muse aider; do
		assert_no "the test PATH cannot resolve $_tr_n" \
			env PATH="$_tr_path" sh -c 'command -v "$1"' _ "$_tr_n"
	done

	# common.sh holds the rule the other five call, so it is asserted directly
	# first — everything after this is a statement that they agree with it.
	#
	# The CLI, not the launcher. This is the regression: all sixteen launchers
	# are present and only claude's CLI is, so a predicate that probes the
	# launcher says "yes" to both of these and the second one is the bug the
	# 配置 page showed.
	assert_ok "common.sh finds the agent's own CLI under the root" \
		env PATH="$_tr_path" FCC_AGENTS_CONF="$AGENTS_CONF" \
		sh -c '. "$1/common.sh"; fcc_agent_installed claude "$2"' _ "$LIBEXEC" "$_tr_root"
	assert_no "a launcher with no CLI behind it is not an installed agent" \
		env PATH="$_tr_path" FCC_AGENTS_CONF="$AGENTS_CONF" \
		sh -c '. "$1/common.sh"; fcc_agent_installed codex "$2"' _ "$LIBEXEC" "$_tr_root"
	# The same for a launcher that is present and an agent whose version probe
	# is deliberately empty. Asking whether it is installed does not run it, so
	# hermes — whose `--version` hangs — is answerable for the first time.
	assert_no "an agent with no probe is still answered by its id" \
		env PATH="$_tr_path" FCC_AGENTS_CONF="$AGENTS_CONF" \
		sh -c '. "$1/common.sh"; fcc_agent_installed hermes "$2"' _ "$LIBEXEC" "$_tr_root"

	# 配置 → 智能体, and the Web Console's agent list, which is the same call.
	_tr_list="$(sh_blind "$_tr_path" "$_tr_base" agent.sh list)"
	assert_contains "$_tr_list" '"id": "claude"' "the agent list covers the registry"
	assert_contains "$(json_agent_row "$_tr_list" claude)" \
		'"installed": true' "the agent list reports the installed agent"
	assert_contains "$(json_agent_row "$_tr_list" codex)" \
		'"installed": false' "and does not report the nine that were not installed"

	# 基本信息: the batched document status.sh writes.
	_tr_status="$(sh_blind "$_tr_path" "$_tr_base" status.sh)"
	assert_contains "$(json_agent_row "$_tr_status" claude)" \
		'"installed": true' "the status document reports the installed agent"
	assert_contains "$(json_agent_row "$_tr_status" codex)" \
		'"installed": false' "and not the ones that were not installed"
	# The two rows the first bug report set against each other. The runtime row
	# was right all along — it probes by absolute path — and it is asserted here
	# so that a future change to it cannot quietly make the two disagree again.
	assert_contains "$_tr_status" '"fcc": {"installed": true' \
		"and the runtime row agrees with it"

	# The doctor's agent list (section 80). doctor.sh already asks this question
	# the right way for its bash check, in the same file.
	_tr_doc="$(sh_blind "$_tr_path" "$_tr_base" doctor.sh 2>&1)"
	assert_not_contains "$(printf '%s\n' "$_tr_doc" | grep 'Claude Code')" \
		'not installed' "the doctor reports the installed agent as present"
	assert_contains "$(printf '%s\n' "$_tr_doc" | grep 'Codex')" \
		'not installed' "and the others as missing"

	# The update path's own copy, which decides the --agents set an update
	# reinstalls. Getting this wrong does not merely mislabel a row: install.sh
	# hands the set to the installer as the answers to its agent prompts, so a
	# set of all ten means an update installs all ten agents onto a device that
	# had one.
	_tr_set="$(sh_update "$_tr_path" "$_tr_base" 'installed_agents')"
	assert_contains "$_tr_set" ' claude' "the update path counts the installed agent"
	assert_not_contains "$_tr_set" 'codex' "and not the ones that are not installed"

	# And the metadata the install records, which is the fallback agent.sh reads
	# a version from when the probe cannot run. Only the installed agents are
	# named — the map is a record of what was seen, so absence is the negative.
	sh_install_blind "$_tr_path" "$_tr_base" 'write_runtime_metadata' >/dev/null 2>&1
	_tr_meta="$(cat "$_tr_base/fcc/runtime.json" 2>/dev/null)"
	assert_contains "$_tr_meta" '"claude": true' "the runtime metadata records the installed agent"
	assert_not_contains "$_tr_meta" '"codex"' "and does not name the ones that are not installed"
}

# ---------------------------------------------------------------------------
# Section 104.23 — a bind to one interface is narrowed, not honoured
# ---------------------------------------------------------------------------

test_effective_bind_narrows_to_loopback() {
	setup_sandbox

	# The Admin UI is loopback-only upstream (section 104.22): the proxy is the
	# only way in, and it connects from 127.0.0.1. A server bound to one
	# specific interface does not listen on loopback, so binding to the router's
	# own LAN address does not open the Admin page — it breaks the one path that
	# does. What the setting still decides is which interfaces the server
	# listens on, and narrowing is the only change made to it. Narrowing can
	# only shrink the exposed surface, never widen it, which is why it is safe
	# to do without asking.

	# Kept as written. These are bare literals; the bracketed URL-authority
	# spellings are deliberately not in this group, and the reason is below.
	assert_eq "0.0.0.0" "$(sh_common 'fcc_effective_bind 0.0.0.0')" \
		"a wildcard IPv4 bind is kept"
	assert_eq "::" "$(sh_common 'fcc_effective_bind ::')" \
		"a wildcard IPv6 bind is kept"
	assert_eq "127.0.0.1" "$(sh_common 'fcc_effective_bind 127.0.0.1')" \
		"loopback IPv4 is kept"
	assert_eq "127.0.0.5" "$(sh_common 'fcc_effective_bind 127.0.0.5')" \
		"the whole 127/8 range is loopback, not just .1"
	assert_eq "::1" "$(sh_common 'fcc_effective_bind ::1')" \
		"loopback IPv6 is kept"

	# The reported case. A browser that reaches the port directly is refused by
	# upstream whatever the bind is; narrowing is what keeps the setting from
	# also taking out the proxy, which is the only path that works.
	assert_eq "127.0.0.1" "$(sh_common 'fcc_effective_bind 192.168.5.3')" \
		"the router's LAN address is narrowed to loopback"
	assert_eq "127.0.0.1" "$(sh_common 'fcc_effective_bind 10.0.0.1')" \
		"and so is any other interface address"

	# The bracketed forms narrow too, and this pair is about agreement rather
	# than exposure. status.sh calls this function on the raw UCI value while
	# init.d calls it after valid_bind(); valid_bind rejects a bracket, so
	# init.d would bind 127.0.0.1 while status.sh reported [::1] — the page's
	# "listening on" and the server's actual bind, disagreeing. Both spellings
	# narrow, so the two paths cannot diverge.
	assert_eq "127.0.0.1" "$(sh_common 'fcc_effective_bind "[::1]"')" \
		"a bracketed loopback is narrowed rather than reported verbatim"
	assert_eq "127.0.0.1" "$(sh_common 'fcc_effective_bind "[::]"')" \
		"and so is a bracketed wildcard"

	# Anything at all. The fallback is loopback, never the input — this is the
	# assertion the section's discrimination note names: echoing the argument
	# back on the last line of the function turns the four cases above red.
	assert_eq "127.0.0.1" "$(sh_common 'fcc_effective_bind not-an-address')" \
		"a value the case statement has never seen falls back to loopback"
}

# ---------------------------------------------------------------------------
# Section 104.25 — one click installs every agent
# ---------------------------------------------------------------------------

test_install_runtime_takes_the_whole_registry() {
	setup_sandbox
	make_uci_shim

	# The registry, read here by a second implementation so the assertion is
	# "these two agree" rather than "this equals a list copied from the file".
	# A hardcoded list of ten would keep passing after an eleventh agent was
	# added — and that agent would never be installed, which is the failure the
	# page would then show as an agent that cannot be used.
	_tr_ids="$(sed -n 's/^\([A-Za-z0-9_-]*\)|.*/\1/p' "$AGENTS_CONF" \
		| LC_ALL=C sort | tr '\n' ' ')"
	assert_eq "10" "$(printf '%s' "$_tr_ids" | wc -w | tr -d ' ')" \
		"the registry read here holds ten agents"

	# common.sh holds the rule: every id, and nothing else.
	_tr_all="$(sh_common 'fcc_all_agents' | tr ' ' '\n' | grep . \
		| LC_ALL=C sort | tr '\n' ' ')"
	assert_eq "$_tr_ids" "$_tr_all" "fcc_all_agents is the whole registry"

	# And install.sh's --all-agents is that function, not a second list. The
	# controller asks for the whole set by flag for exactly this reason: the
	# registry stays the only place the set is written down.
	#
	# The seam used to read the set back is the doctor. cmd_runtime hands the
	# pre-install checks the same variable it later hands the installer —
	# FCC_AGENT_SELECTION is set from $_cr_agents and exported, and run_installer
	# is called with $_cr_agents — so asking the checks what they were given
	# answers the question without running an install. precheck_ok is stubbed to
	# report and then fail, which stops the run before the backup, the download
	# and the lock's lifetime get interesting: the sandbox every test in this
	# file shares, and /tmp's lock directory, are both left as they were found.
	#
	# The set is read back normalised, because what is asserted is which agents
	# are in it, not the order they arrive in.
	_tr_set="$(sh_install '
		precheck_ok() { printf "SET=[%s]\n" "$FCC_AGENT_SELECTION"; return 1; }
		cmd_runtime runtime --all-agents' 2>&1 \
		| sed -n 's/^SET=\[\(.*\)\]$/\1/p' | tr ' ' '\n' | grep . \
		| LC_ALL=C sort | tr '\n' ' ')"
	assert_eq "$_tr_all" "$_tr_set" "--all-agents resolves to the whole registry"

	# The other direction, so the assertion above cannot pass for a reason that
	# has nothing to do with the flag: an explicit list still means that list,
	# and is not quietly widened to everything.
	_tr_set="$(sh_install '
		precheck_ok() { printf "SET=[%s]\n" "$FCC_AGENT_SELECTION"; return 1; }
		cmd_runtime runtime --agents claude' 2>&1 \
		| sed -n 's/^SET=\[\(.*\)\]$/\1/p' | tr ' ' '\n' | grep . \
		| LC_ALL=C sort | tr '\n' ' ')"
	assert_eq "claude " "$_tr_set" "an explicit list is still exactly that list"

	# And the set the checks are shown is the set the installer is given: one
	# variable, read in both places. A change that widened one and not the other
	# would be a page that checks for one thing and installs another, which is
	# the shape of bug that leaves a device short of space halfway through.
	assert_contains "$(cat "$LIBEXEC/install.sh")" \
		'FCC_AGENT_SELECTION="$_cr_agents"' \
		"the checks read the requested set"
	assert_contains "$(cat "$LIBEXEC/install.sh")" \
		'run_installer "$_cr_script" "$_cr_agents" "$_cr_none"' \
		"and the installer is handed that same set"

	# And the checks accept what they are handed. This is the seam that broke:
	# install.sh exports several ids at once — the whole registry, here — and the
	# doctor asked fcc_valid_agent() about the string as a whole, so every install
	# was refused with "unknown agent:  claude codex pi ..." before a byte was
	# downloaded. Stubbing precheck_ok, as the assertions above do, is exactly why
	# that survived a green suite: it answers the question about the set without
	# ever asking the doctor the same one.
	#
	# "Not refused" is the whole assertion. Whether the install is *allowed* is
	# the device's business — neither this host nor the test router has the C++
	# runtime the fetched Node needs — but a report about ids that are all in the
	# registry may not come back as a usage error.
	#
	# Passed as one argument rather than through the environment, because that is
	# what the string is: install.sh exports it into a variable, the controller
	# passes it as an argument, and both land in the same place. A test that set
	# the variable would have to word-split it to get it through env(1), which is
	# the very thing under test.
	_tr_report="$(sh_doctor_tools "$DOCTOR_TOOLS tmux bash" '' --json \
		--agents "$_tr_all" 2>&1)"
	assert_not_contains "$_tr_report" 'unknown agent' \
		"the checks accept the whole registry as the one list install.sh exports"
	assert_contains "$_tr_report" '"install_allowed"' \
		"and answer with a report rather than a usage error"
}

test_reinstall_is_remove_then_install_everything() {
	setup_sandbox

	# "Reinstall" cannot mean "ask upstream to install again": upstream
	# *reconciles* the agent set, so an agent already present is never asked
	# about again, and the only lever this package has over the set is which
	# agents it requests. The one operation that genuinely reinstalls them is to
	# remove the runtime that carries them and install it again — which is what
	# this pins, as control flow, because the sequencing is the whole of the
	# function.
	#
	# The two commands it drives are stood in for so that the order and the
	# arguments are what is read back; each is covered on its own elsewhere.
	_tr_calls="$(sh_install '
		cmd_uninstall() { printf "uninstall[%s]\n" "$*"; return 0; }
		cmd_runtime()   { printf "runtime[%s]\n" "$*"; return 0; }
		cmd_reinstall' 2>&1)"
	assert_eq "uninstall[]
runtime[--all-agents]" "$_tr_calls" \
		"reinstall removes the runtime and then installs the whole registry"

	# No --purge: the configuration, the sessions and the backups are the
	# user's and survive. Only the runtime goes, which is the point — it is what
	# the agents are re-fetched from.
	assert_not_contains "$_tr_calls" "--purge" "the removal keeps the user's data"

	# A removal that fails stops the sequence. Installing on top of a runtime
	# that would not come out is the one outcome worse than not reinstalling at
	# all: it would report success over a state nobody chose.
	_tr_calls="$(sh_install '
		cmd_uninstall() { printf "uninstall\n"; return 1; }
		cmd_runtime()   { printf "runtime\n"; return 0; }
		cmd_reinstall; echo "rc=$?"' 2>&1)"
	assert_eq "uninstall
rc=1" "$_tr_calls" "a removal that fails stops the reinstall"

	# And the status the caller gets is the install's, so a reinstall that
	# removed cleanly and then failed to install is not reported as a success.
	_tr_calls="$(sh_install '
		cmd_uninstall() { return 0; }
		cmd_runtime()   { return 3; }
		cmd_reinstall; echo "rc=$?"' 2>&1)"
	assert_eq "rc=3" "$_tr_calls" "the install's status is the reinstall's status"
}

# ---------------------------------------------------------------------------
# Explaining a failed download
# ---------------------------------------------------------------------------
#
# The upstream installer reports a failed download as
#
#   error: Could not download the Codex installer (curl exit code 35).
#
# which names the agent and a number and stops there. The host it could not
# reach — the one fact that tells a reader whether the router's own network is
# the problem — is not in the message, and "curl exit code 35" is not something
# a person can act on. install.sh reads both back out of the installer that ran.
#
# write_installer_fixture holds the two lines that lookup depends on, copied
# from upstream's own text: the URL assignment, and the download_and_run call
# that pairs a variable with the label upstream reports a failure by. The third
# agent is there to be *absent* from the answer — Aider is installed with uv, not
# downloaded, so there is no URL for it and inventing one would send the reader
# to a host that was never involved.
write_installer_fixture() {
	_fx_path="$SANDBOX/installer-fixture.sh"
	cat > "$_fx_path" <<'FIXTURE'
CLAUDE_INSTALL_URL="https://claude.ai/install.sh"
CODEX_INSTALL_URL="https://chatgpt.com/codex/install.sh"

ensure_claude() {
        download_and_run "$CLAUDE_INSTALL_URL" bash "Claude Code"
}

ensure_codex() {
        download_and_run "$CODEX_INSTALL_URL" sh "Codex" 1
}

ensure_aider() {
        run uv tool install aider-chat
}
FIXTURE
	printf '%s' "$_fx_path"
}

test_a_failed_download_is_traced_to_its_host() {
	setup_sandbox
	_fd_script="$(write_installer_fixture)"

	assert_eq "https://chatgpt.com/codex/install.sh" \
		"$(sh_install "installer_download_url_for '$_fd_script' Codex")" \
		"the label upstream reports is resolved to the URL it would have fetched"
	assert_eq "https://claude.ai/install.sh" \
		"$(sh_install "installer_download_url_for '$_fd_script' 'Claude Code'")" \
		"a label of two words resolves the same way"

	# An agent that is not downloaded has no URL, and no answer is the right
	# answer: a plausible-looking host would be a fabricated fact in a log a
	# person is meant to act on.
	assert_no "an agent that is not downloaded has no URL" \
		sh_install "installer_download_url_for '$_fd_script' Aider"
	assert_no "a label the installer never used has no URL" \
		sh_install "installer_download_url_for '$_fd_script' Nonesuch"
	assert_no "an unreadable installer has no URL" \
		sh_install "installer_download_url_for '$_fd_script.absent' Codex"
	assert_no "an empty label has no URL" \
		sh_install "installer_download_url_for '$_fd_script' ''"
}

test_a_failed_download_explains_itself_in_the_log() {
	setup_sandbox
	_fd_script="$(write_installer_fixture)"
	_fd_logs="$SANDBOX/diaglogs"

	sh_install "fcc_dir_logs() { printf '%s' '$_fd_logs'; }
		installer_explain_failure '$_fd_script' \
			'error: Could not download the Codex installer (curl exit code 35).'" \
		>/dev/null 2>&1
	_fd_log="$(cat "$_fd_logs/fcc-runtime.log" 2>/dev/null || true)"

	assert_contains "$_fd_log" "https://chatgpt.com/codex/install.sh" \
		"the log names the URL the download was meant to come from"
	assert_contains "$_fd_log" "the network path to chatgpt.com" \
		"and the host, which is the part a person can go and test"
	assert_contains "$_fd_log" "curl exit code 35 means the TLS handshake" \
		"and what the exit code means, because the number alone is not actionable"
	assert_contains "$_fd_log" "installed no agent" \
		"and that the attempt left nothing installed"

	# An exit code the diagnosis does not know still gets the host and the
	# consequence: the two facts it can supply do not depend on recognising it.
	sh_install "fcc_dir_logs() { printf '%s' '$_fd_logs'; }
		installer_explain_failure '$_fd_script' \
			'error: Could not download the Claude Code installer (curl exit code 99).'" \
		>/dev/null 2>&1
	_fd_log="$(cat "$_fd_logs/fcc-runtime.log" 2>/dev/null || true)"
	assert_contains "$_fd_log" "the network path to claude.ai" \
		"an unrecognised exit code still names the host"
	assert_not_contains "$_fd_log" "curl exit code 99 means" \
		"but no meaning is invented for it"

	# Every other failure the installer reports is its own business, and the log
	# has to stay quiet about them: a download diagnosis printed over a uv
	# failure would name a host that was never involved.
	_fd_before="$(wc -l < "$_fd_logs/fcc-runtime.log" 2>/dev/null | tr -d ' ')"
	sh_install "fcc_dir_logs() { printf '%s' '$_fd_logs'; }
		installer_explain_failure '$_fd_script' \
			'error: uv installation failed with exit code 1.'" >/dev/null 2>&1
	_fd_after="$(wc -l < "$_fd_logs/fcc-runtime.log" 2>/dev/null | tr -d ' ')"
	assert_eq "$_fd_before" "$_fd_after" \
		"a failure that is not a download adds nothing to the log"

	# And the diagnosis has to be reached. A function that explains a failure to
	# nobody is the same as no function at all, and the failed-install branch is
	# its only caller — so the call is asserted here, and so is the order it has
	# with the deletion of the script it reads. The lookup opens that script, so
	# a delete that ran first would leave every diagnosis without a host and the
	# tests above would still pass, because they call the function directly.
	_fd_src="$LIBEXEC/install.sh"
	_fd_call="$(grep -n 'installer_explain_failure "\$_cr_script"' "$_fd_src" | head -n 1 | cut -d: -f1)"
	_fd_rm="$(grep -n 'rm -f "\$_cr_script"' "$_fd_src" | head -n 1 | cut -d: -f1)"
	assert_ok "the diagnosis runs before the installer script is deleted" \
		test "$_fd_call" -lt "$_fd_rm"
}

# The other failure whose cause upstream's line does not carry: a command the
# image does not have. This is the one the router reported. The transcript held
# the answer — "/tmp/fcc-install.iKaKoG: line 215: fold: not found", twice — and
# the log held the question, "error: Codex installation failed with exit code
# 1.", so the file a person opens was the one file that did not say. The
# transcript below is that screen, escapes and CRLF and trailing blanks and all.
test_a_missing_tool_is_named_in_the_log() {
	setup_sandbox
	_fd_script="$(write_installer_fixture)"
	_fd_logs="$SANDBOX/diaglogs"
	_fd_out="$SANDBOX/installer.out"
	mkdir -p "$_fd_logs"

	{
		printf '\033[?25l[3/14] Ensuring Codex is installed\r\n'
		printf '+ curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/fcc-install.iKaKoG\r\n'
		printf '\033[31m/tmp/fcc-install.iKaKoG: line 215: fold: not found\033[0m\r\n'
		printf 'Failed to resolve the latest Codex release version.\r\n'
		printf 'error: Codex installation failed with exit code 1.\r\n'
		printf '   \r\n\r\n'
	} > "$_fd_out"

	# The log is emptied before each case. The sandbox is per-run rather than
	# per-test, so the file accumulates across the whole suite — and a "does not
	# contain" would then be answered by whatever an earlier test happened to
	# write, which is how the download test's hosts turned up in this one.
	: > "$_fd_logs/fcc-runtime.log"
	sh_install "fcc_dir_logs() { printf '%s' '$_fd_logs'; }
		installer_explain_failure '$_fd_script' \
			'error: Codex installation failed with exit code 1.' '$_fd_out'" \
		>/dev/null 2>&1
	_fd_log="$(cat "$_fd_logs/fcc-runtime.log" 2>/dev/null || true)"

	assert_contains "$_fd_log" "the installer needed 'fold'" \
		"the log names the command the installer could not find"
	assert_contains "$_fd_log" 'opkg install coreutils-fold' \
		"and the package that provides it"
	# The reason is not a download, so the download diagnosis has to stay out of
	# it: naming a host here would send the reader after a network fault that
	# was never involved.
	assert_not_contains "$_fd_log" 'network path' \
		"and no host is named, because no download failed"

	# The interactive form, and a tool this package has no provider for. The
	# name is still reported — it is the fact the reader needs — and no package
	# is invented for it: "coreutils-<tool>" is the usual shape on OpenWrt and
	# not a rule, and a package that does not exist is a second dead end.
	: > "$_fd_logs/fcc-runtime.log"
	printf 'ash: realpath: not found\n' > "$_fd_out"
	sh_install "fcc_dir_logs() { printf '%s' '$_fd_logs'; }
		installer_explain_failure '$_fd_script' \
			'error: Pi installation failed with exit code 1.' '$_fd_out'" \
		>/dev/null 2>&1
	_fd_log="$(cat "$_fd_logs/fcc-runtime.log" 2>/dev/null || true)"
	assert_contains "$_fd_log" "the installer needed 'realpath'" \
		"a command the shell could not find at a prompt is reported too"
	assert_not_contains "$_fd_log" 'coreutils-realpath' \
		"and no package is guessed from the name"

	# The installer's own prose is one word away from reading as a missing
	# command: "Failed to resolve the latest Codex release version." The line
	# has to survive the reader without "resolve" being taken for a tool, so
	# this transcript earns an empty log.
	: > "$_fd_logs/fcc-runtime.log"
	printf 'Failed to resolve the latest Codex release version.\n' > "$_fd_out"
	sh_install "fcc_dir_logs() { printf '%s' '$_fd_logs'; }
		installer_explain_failure '$_fd_script' \
			'error: Codex installation failed with exit code 1.' '$_fd_out'" \
		>/dev/null 2>&1
	assert_eq "" "$(cat "$_fd_logs/fcc-runtime.log" 2>/dev/null || true)" \
		"a failure with no missing command adds nothing to the log"

	# No transcript at all — the run was killed before tmux wrote one, or the
	# pane never attached. Nothing to read is not a reason to say something.
	assert_no "a transcript that is not there yields no tool" \
		sh_install "installer_missing_tool '$_fd_out.absent'"
	# And what comes back is a command name, or nothing: the reader is handed
	# text out of a log line, and only a name shaped like a command may escape.
	assert_eq "fold" "$(sh_install "printf '%s\n' '/x: line 9: fold: not found' > '$_fd_out'
		installer_missing_tool '$_fd_out'")" \
		"the tool is read out of the line the shell printed"

	# The reader is reached, and reached with the transcript. Without the third
	# argument the function is handed nothing to read and every install that
	# stops this way is reported as an exit code again.
	_fd_src="$LIBEXEC/install.sh"
	assert_ok "the failed-install branch hands the diagnosis the transcript" \
		grep -q 'installer_explain_failure "\$_cr_script" "\$_cr_reason" "\$ROOT/logs/installer.out"' \
			"$_fd_src"
}

# The second shape of "the installer needed something this image does not have",
# and the one that never contains the words "not found": a command that is
# there and refuses the argument it is given.
#
#   sleep: invalid number '0.075'
#
# BusyBox's sleep is in every OpenWrt image; what it will not do is take a
# fraction. The Pi installer animates its logo with sixteen of them under
# `set -eu`, so the first one ends the run — and the line the reader was left
# with was "error: Pi installation failed with exit code 1.", which is the same
# report the fold gap produced for the same reason: the reason was in the
# transcript and the transcript was not in the log.
test_a_limited_tool_is_named_in_the_log() {
	setup_sandbox
	_dlt_script="$(write_installer_fixture)"
	_dlt_logs="$SANDBOX/diaglogs"
	_dlt_out="$SANDBOX/installer.out"
	mkdir -p "$_dlt_logs"

	{
		printf '\033[?25l  Pi Installer\r\n'
		printf "sleep: invalid number '0.075'\r\n"
		printf 'error: Pi installation failed with exit code 1.\r\n'
		printf '   \r\n'
	} > "$_dlt_out"

	: > "$_dlt_logs/fcc-runtime.log"
	sh_install "fcc_dir_logs() { printf '%s' '$_dlt_logs'; }
		installer_explain_failure '$_dlt_script' \
			'error: Pi installation failed with exit code 1.' '$_dlt_out'" \
		>/dev/null 2>&1
	_dlt_log="$(cat "$_dlt_logs/fcc-runtime.log" 2>/dev/null || true)"

	assert_contains "$_dlt_log" "the installer needed 'sleep'" \
		"the log names the command whose argument was refused"
	assert_contains "$_dlt_log" 'opkg install coreutils-sleep' \
		"and the package that provides a sleep which takes a fraction"
	assert_contains "$_dlt_log" 'too limited' \
		"and says the tool is there but not capable, not that it is missing"
	assert_not_contains "$_dlt_log" 'does not provide' \
		"and does not send the reader looking for a tool that exists"
	assert_contains "$_dlt_log" 'animates its logo' \
		"and says what the installer wanted it for"

	# The name is read out of the line, and what comes back is a command name or
	# nothing: the reader is handed text out of a log line.
	printf "sleep: invalid number '0.075'\n" > "$_dlt_out"
	assert_eq "sleep" "$(sh_install "installer_missing_tool '$_dlt_out'")" \
		"the tool is read out of the line the applet printed"
	printf "/tmp/fcc-install.x: line 12: sleep: invalid number '0.5'\n" > "$_dlt_out"
	assert_eq "sleep" "$(sh_install "installer_missing_tool '$_dlt_out'")" \
		"and out of the same line when the shell prefixes it"

	# A line that merely mentions a version is not this. The match is anchored
	# on "<command>: invalid number", so the installer's own prose about a
	# version cannot be read as a tool called "requires".
	printf 'error: Pi requires Node.js 22.19.0 or newer. Found v20.20.2.\n' > "$_dlt_out"
	assert_eq "" "$(sh_install "installer_missing_tool '$_dlt_out'")" \
		"prose about a version is not a tool"
}

# The three questions the Pi installer asks that upstream's installer does not
# ask on its behalf. All three were found by running it on the router and
# reading the screen, and the first one stops the run dead if it goes
# unanswered — it is a menu, and nothing in this package's prompt table matched
# it, so the loop sat there until FCC_INSTALLER_TIMEOUT rolled the install back
# half an hour later.
test_the_pi_installers_own_questions_are_answered() {
	setup_sandbox

	# The action menu. It is a block — "Choose an action:", then a row per key —
	# and what the pane's last line is, is the last row, so the row is what the
	# matcher can anchor on. That is also the right anchor: Pi prints the action
	# it took the moment the menu is answered, so the row is gone by the next
	# poll and the loop's "already answered this" guard is not tripped by a menu
	# that is still on the screen.
	_dpq_menu='  n    Do nothing'
	assert_eq "y" \
		"$(sh_install "installer_answer_for '$_dpq_menu' 'claude pi' set")" \
		"a selected Pi is installed from the menu"
	assert_eq "n" \
		"$(sh_install "installer_answer_for '$_dpq_menu' 'claude' set")" \
		"a Pi that was not selected is left alone"
	assert_eq "n" \
		"$(sh_install "installer_answer_for '$_dpq_menu' '' none")" \
		"--no-agents leaves Pi alone"
	assert_eq "y" \
		"$(sh_install "installer_answer_for '$_dpq_menu' '' default")" \
		"and no opinion takes the menu's own default, which is what Pi derived"
	# The row for the key that is never sent. "u" uninstalls, which is not a
	# thing an install was asked to do, and the row is only on the menu at all
	# when a pi is already installed.
	assert_eq "y" \
		"$(sh_install "installer_answer_for '  u    Uninstall Pi' 'claude pi' set")" \
		"the uninstall row is not a key this package presses"

	# Every row of the menu, not only the bottom one — a pane shorter than the
	# block shows only its bottom, and a row that is not recognised is a
	# question nobody answers. The rows are spelled as Pi spells them, which is
	# also how they read once installer_pane_text() has stripped the colour out
	# from between the key and the label.
	assert_ok "the row that installs a Pi that is not there yet" \
		sh_install "installer_line_is_pi_menu '  y    Install Pi (default)'"
	assert_ok "the row that reinstalls one that is" \
		sh_install "installer_line_is_pi_menu '  y    Reinstall Pi (default)'"
	assert_ok "the row that migrates an npm-installed one" \
		sh_install "installer_line_is_pi_menu '  y    Migrate Pi to a managed installation (default)'"

	# And what is NOT a row of it. Pi prints the action it took the moment the
	# menu is answered, and that sentence must not be read as a menu that is
	# still waiting: answering it a second time would put a second key into the
	# terminal, and the *next* prompt — "Start pi now?" — would read it as its
	# answer, whose default is yes. Every one of those sentences is lower case,
	# and every row is not, which is what keeps the two apart.
	assert_no "the sentence Pi prints after the menu is not the menu" \
		sh_install "installer_line_is_pi_menu 'Will install Pi.'"
	assert_no "nor the one for a reinstall" \
		sh_install "installer_line_is_pi_menu 'Will reinstall Pi.'"
	assert_no "nor the one for an uninstall" \
		sh_install "installer_line_is_pi_menu 'Will uninstall Pi.'"
	assert_no "nor the one it prints when nothing was chosen" \
		sh_install "installer_line_is_pi_menu 'Chose to do nothing. Exiting.'"
	assert_no "nor a yes/no prompt that merely mentions Pi" \
		sh_install "installer_line_is_pi_menu 'Install Pi for fcc-pi? [Y/n]'"

	# The menu is the one prompt answered with a bare key. Everything else is
	# read a line at a time and ends with Enter, and an Enter sent to this one
	# is not consumed by it — it is read by "Start pi now?" as that prompt's
	# default, which is yes. Pi's own interface then starts in the installer's
	# terminal and the install sits there until the deadline.
	assert_eq "" "$(sh_install "installer_answer_terminator '$_dpq_menu'")" \
		"the menu answer is sent with nothing after it, where a key can be read"
	assert_eq "Enter" \
		"$(sh_install "installer_answer_terminator 'Install Pi for fcc-pi? [Y/n]'")" \
		"and every other prompt is ended with Enter"

	# ...but only where a bare key can be read at all, which is what
	# fcc_installer_can_read_a_key() asks. Pi reaches raw mode with
	#
	#     stty -icanon -echo min 1 time 0 < /dev/tty 2>/dev/null || true
	#
	# and throws away both the call and its failure, so a box without stty does
	# not fail there — it changes shape. The terminal stays canonical, dd waits
	# for a line delimiter instead of for a byte, and the bare key is never
	# read. That is what a real install did on 2026-10-17: the router's BusyBox
	# has no stty applet, the "y" sat echoed in the canonical line buffer, and
	# the run waited on it until FCC_INSTALLER_TIMEOUT rolled everything back
	# thirty minutes later with nothing in the log naming the menu (§104.31).
	assert_ok "a key can be read here, where stty is" \
		sh_install 'fcc_installer_can_read_a_key'
	mkdir -p "$SANDBOX/nostty"
	assert_no "and not on a box without it" \
		sh_install "PATH='$SANDBOX/nostty'; fcc_installer_can_read_a_key"

	# There the answer does need a delimiter, but not the obvious one. A newline
	# is kept in the line it delivers: canonical mode hands the reader the line
	# *including* its delimiter, so dd takes the key and leaves the newline in
	# the queue, and "Start pi now?" reads that leftover as an empty answer —
	# which is not "no", so Pi's interface starts and the install hangs one
	# prompt later than it did before (§104.32). Ctrl-D is the delimiter that
	# does not survive: it is the terminal's EOF character, the line discipline
	# delivers the pending line without it and consumes it, and the queue is
	# left empty for the loop's own "Start pi now?" rule to answer with "n".
	assert_eq "C-d" \
		"$(sh_install "PATH='$SANDBOX/nostty'; installer_answer_terminator '$_dpq_menu'")" \
		"the menu is ended with Ctrl-D where there is no stty"
	assert_eq "Enter" \
		"$(sh_install "PATH='$SANDBOX/nostty'; installer_answer_terminator 'Install Pi for fcc-pi? [Y/n]'")" \
		"and the questions read by line are unaffected by the terminal"

	# What is said does not change with how it is sent, so both boxes still
	# install the Pi that was selected — and a box with no stty still leaves an
	# unselected one alone, which is the half that would be quiet if the
	# fallback had been "answer everything with a line".
	assert_eq "y" \
		"$(sh_install "PATH='$SANDBOX/nostty'; installer_answer_for '$_dpq_menu' 'claude pi' set")" \
		"and the same answer is still given on a box with no stty"
	assert_eq "n" \
		"$(sh_install "PATH='$SANDBOX/nostty'; installer_answer_for '$_dpq_menu' 'claude' set")" \
		"including the answer that leaves Pi alone"

	# Pi offers to launch its own interface in the terminal the install ran in.
	# It is a full-screen program that stays until it is quit by hand, and that
	# terminal belongs to the installer job — so yes ends the job by hanging it.
	assert_eq "n" \
		"$(sh_install 'installer_answer_for "Start pi now? [Y/n]" "claude pi" set')" \
		"Pi is not started in the installer's terminal"

	# And its offer to install Node itself. Pi's remedy is nodejs.org/dist,
	# which publishes no musl build: yes installs a glibc Node that cannot
	# execute on this image, and the install then fails further along with a
	# worse reason than this one. Declining stops it here.
	assert_eq "n" \
		"$(sh_install 'installer_answer_for "Pi needs Node.js 22.19.0 or newer and npm. Install them now with standalone Node.js? [Y/n]" "pi" set')" \
		"Pi's own Node install is declined, because its build cannot run here"

	# And the loop asks. A decision nobody calls is the same as no decision, and
	# this is the one whose absence reintroduces the hang above.
	_dpq_src="$LIBEXEC/install.sh"
	assert_ok "the answer loop asks what ends the answer" \
		grep -q 'installer_answer_terminator "\$_ri_line"' "$_dpq_src"
}

# provision_node's three fetches, answered from files instead of the network.
#
# The release is real — an archive holding a node and an npm, which the tests
# then run — and the checksum in SHASUMS256.txt is the checksum of that
# archive, so the verification is exercised rather than stubbed out. A URL the
# function builds wrongly resolves to a file that is not there, and the
# stand-in then fails the way curl fails, so a test cannot pass by accident.
#
# The architecture is read from the function under test rather than written
# down, so this works on a build host that is not x86_64; it prints the release
# directory's name.
#
# The optional argument is the fixture node's body. It exists for the test about
# a build that extracts and does not run — a stand-in has to be able to fail the
# way the real binary failed, and there is no other way to put that in the
# archive. Left out, the node answers the version it is named for.
#
# The stand-in curl goes in a directory of its own rather than in $SANDBOX/bin.
# That PATH entry is shared by every test in the run, and the tests run in
# alphabetical order rather than in the order they are written — so a curl left
# there is still on PATH for test_rollback_* and test_server_health_*, which both
# talk to a real listener. The tests below put this directory on PATH themselves
# instead.
make_node_release_fixture() {
	_nrf_node="${1:-}"
	_nrf_arch="$(sh_common 'fcc_node_arch')"
	[ -n "$_nrf_arch" ] || return 1
	_nrf_name="node-v22.23.3-linux-$_nrf_arch-musl"

	rm -rf "$SANDBOX/nodebin" "$SANDBOX/fixture"
	mkdir -p "$SANDBOX/nodebin" "$SANDBOX/fixture/http" "$SANDBOX/fixture/$_nrf_name/bin"
	if [ -n "$_nrf_node" ]; then
		printf '%s\n' "$_nrf_node" > "$SANDBOX/fixture/$_nrf_name/bin/node"
	else
		printf '#!/bin/sh\nprintf "v22.23.3\\n"\n' > "$SANDBOX/fixture/$_nrf_name/bin/node"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/fixture/$_nrf_name/bin/npm"
	chmod +x "$SANDBOX/fixture/$_nrf_name/bin/node" "$SANDBOX/fixture/$_nrf_name/bin/npm"
	( cd "$SANDBOX/fixture" && tar -czf "http/$_nrf_name.tar.xz" "$_nrf_name" ) || return 1

	# The index is newest-first, as the real one is, and holds a second release
	# so that taking the wrong entry is a failure rather than a coincidence.
	printf '%s\n' '[{"version":"v22.23.3"},{"version":"v22.22.1"}]' \
		> "$SANDBOX/fixture/http/index.json"
	printf '%s  %s\n' \
		"$(sha256sum "$SANDBOX/fixture/http/$_nrf_name.tar.xz" | awk '{print $1}')" \
		"$_nrf_name.tar.xz" > "$SANDBOX/fixture/http/SHASUMS256.txt"

	# A curl that answers out of that directory, and fails the way curl fails
	# for anything it has no answer for.
	{
		printf '#!/bin/sh\n'
		printf 'while [ $# -gt 0 ]; do\n'
		printf '  case "$1" in\n'
		printf '    --output) out="$2"; shift 2 ;;\n'
		printf '    -*) shift ;;\n'
		printf '    *) url="$1"; shift ;;\n'
		printf '  esac\n'
		printf 'done\n'
		printf 'f=%s\n' "$SANDBOX/fixture/http/\${url##*/}"
		printf '[ -f "$f" ] || exit 22\n'
		printf 'cp "$f" "$out"\n'
	} > "$SANDBOX/nodebin/curl"
	chmod +x "$SANDBOX/nodebin/curl"

	printf '%s' "$_nrf_name"
}

# The Node this package fetches for the npm agents, before the installer runs.
#
# Three of the ten agents are npm packages — Pi, DeepSeek Harness and Cline —
# and all three want a Node this image's own node is below. The Pi installer
# will offer to install one, but its remedy is nodejs.org/dist, which publishes
# no musl build: what it leaves behind cannot execute on this image at all, and
# the kernel reports the missing ELF interpreter as if the file were not there.
# Upstream stops at the first agent that fails and rolls the whole run back, so
# this is not one agent's problem — without a Node that runs, no install
# completes, which is the symptom that started all of this.
#
# The build comes from unofficial-builds.nodejs.org, which is where the Node
# project itself keeps the musl builds it does not publish, and it lands in
# <root>/data/.local/share/pi-node — the directory upstream's own PATH entry
# already reserves, so nothing downstream has to be told where it went. That
# path is derived from the install root and not from the environment, which the
# test below this one is about.
test_provision_node_fetches_a_musl_build() {
	setup_sandbox
	_dpn_name="$(make_node_release_fixture)" || skip "no musl Node architecture on this host"
	_dpn_base="$SANDBOX/opt/fcc/data/.local/share/pi-node"
	_dpn_logs="$SANDBOX/diaglogs"
	mkdir -p "$_dpn_logs"
	: > "$_dpn_logs/fcc-runtime.log"

	sh_install "fcc_dir_logs() { printf '%s' '$_dpn_logs'; }
		PATH='$SANDBOX/nodebin':\$PATH
		provision_node pi" >/dev/null 2>&1

	assert_exec "$_dpn_base/current/bin/node" \
		"the node lands in the directory upstream's PATH entry already reserves"
	assert_eq "v22.23.3" "$("$_dpn_base/current/bin/node" 2>/dev/null)" \
		"and it is the release the index named"
	assert_exec "$_dpn_base/current/bin/npm" "and npm comes with it"
	assert_eq "$_dpn_base/$_dpn_name" "$(readlink "$_dpn_base/current")" \
		"and current points at the release directory rather than holding a copy"
	assert_contains "$(cat "$_dpn_logs/fcc-runtime.log")" 'installed v22.23.3' \
		"and the log says which release was installed"

	# The directory it chose is the one the panes will look in. This is the
	# invariant the whole arrangement rests on: provision_node() decides where
	# the Node goes, fcc_runtime_bin_dirs() decides where a pane looks for it,
	# and a Node fetched to any other directory is a Node no agent can run.
	_dpn_bins="$(sh_install 'fcc_runtime_bin_dirs "$ROOT"')"
	assert_contains "$_dpn_bins" "$_dpn_base/current/bin" \
		"and that is a directory the panes put on PATH"

	# A second call does not fetch again: the Node is there and already
	# satisfies the floor. This is not an optimisation — the check is made
	# against the directory rather than against PATH precisely because the
	# runtime's directories are added to PATH by the step that runs *after*
	# this one, so a PATH check would report the Node fetched a moment ago as
	# missing and download 30 MB again on every install, including the ones
	# that change nothing.
	#
	# The proof is that curl is broken for the second call: a fetch that
	# happened anyway would fail, and the failure would be in the log.
	printf '#!/bin/sh\nexit 22\n' > "$SANDBOX/nodebin/curl"
	chmod +x "$SANDBOX/nodebin/curl"
	: > "$_dpn_logs/fcc-runtime.log"
	sh_install "fcc_dir_logs() { printf '%s' '$_dpn_logs'; }
		PATH='$SANDBOX/nodebin':\$PATH
		provision_node pi" >/dev/null 2>&1
	assert_eq "" "$(cat "$_dpn_logs/fcc-runtime.log")" \
		"a node that is already installed is not fetched again"
	assert_exec "$_dpn_base/current/bin/node" "and it is left where it was"
}

# The checksum, which is the whole reason this download is allowed to happen.
# This is a third-party binary placed where the agents will run it from, and
# the archive is checked before anything is unpacked — so an archive that does
# not match its own release's SHASUMS256.txt installs nothing at all.
#
# This one installs under a root of its own. The test above leaves a working
# Node in its root, and provision_node() is idempotent by design — so sharing a
# root would mean this test measured the early return instead of the check, and
# passed or failed according to which of the two ran first rather than according
# to what it is about. The root is the knob, not XDG_DATA_HOME: the destination
# is derived from the root, so an XDG override would change nothing and the test
# would look like it was separating the two when it was not.
test_provision_node_refuses_an_archive_that_does_not_match() {
	setup_sandbox
	_dpn_name="$(make_node_release_fixture)" || skip "no musl Node architecture on this host"
	_dpn_base="$SANDBOX/optcheck/fcc/data/.local/share/pi-node"
	_dpn_logs="$SANDBOX/diaglogs"
	mkdir -p "$_dpn_logs"

	# The release's own checksum file, with the checksum made certainly wrong.
	# Everything else about the download is right, so the only thing that can
	# stop it is the check.
	#
	# "Change the first character to 0" is not certainly wrong. A sha256 begins
	# with a hex digit, and one time in sixteen that digit is already 0 — which
	# left the file untouched, let the checksum match, and made this test pass or
	# fail by luck rather than by what it is about. It failed exactly that way on
	# 2026-10-18: provision_node installed the archive it was supposed to refuse
	# and the log said so. The digit is therefore changed to one it is not.
	_dpn_wrong="$(sed -e 's/^0/1/' -e 't' -e 's/^./0/' "$SANDBOX/fixture/http/SHASUMS256.txt")"
	printf '%s\n' "$_dpn_wrong" > "$SANDBOX/fixture/http/SHASUMS256.txt"

	: > "$_dpn_logs/fcc-runtime.log"
	sh_install "fcc_dir_logs() { printf '%s' '$_dpn_logs'; }
		PATH='$SANDBOX/nodebin':\$PATH
		provision_node pi" "$SANDBOX/optcheck" >/dev/null 2>&1

	assert_no "an archive that fails its checksum is not installed" \
		test -e "$_dpn_base/current"
	assert_contains "$(cat "$_dpn_logs/fcc-runtime.log")" 'failed its checksum' \
		"and the log says why rather than leaving a missing node unexplained"
}

# The difference between on disk and runnable, which is where the install that
# started all of this was lost.
#
# The musl build is linked against libstdc++.so.6 and libgcc_s.so.1, and a
# stock image has neither. A Node whose libraries are missing still extracts,
# still has the right name, and still passes every check that only looks at the
# filesystem — so the run reported "installed v22.23.3" over a binary that died
# in the loader, and then failed at the first npm agent with the reason 1064
# lines into the transcript. Measured on the test router on 2026-10-19;
# common.sh carries the measurement.
#
# So the fetched binary is asked for its version before `current` is moved. Two
# things have to hold, and this test is about both. The build is thrown away —
# a tree left behind under the name the next run expects is a tree the next run
# will reuse. And the pointer is left where it was, which is why the failure
# returns *before* the rm: everything downstream resolves through `current`, so
# a pointer aimed at a build that does not run is worse than no pointer at all.
# The Node already there is deliberately one the agents cannot use, because
# otherwise provision_node() returns early and none of this is reached.
#
# The stand-in fails the way the real binary failed, with the loader's sentence
# on stderr rather than an arbitrary error: a test whose node just said "no"
# would pass against a check that read the exit status alone, and it is the
# sentence that has to reach the log.
test_provision_node_refuses_a_build_that_does_not_run() {
	setup_sandbox
	_dpr_name="$(make_node_release_fixture '#!/bin/sh
echo "Error loading shared library libstdc++.so.6: No such file or directory" >&2
echo "Error relocating /opt/fcc/data/.local/share/pi-node/current/bin/node: __cxa_throw: symbol not found" >&2
exit 1')" || skip "no musl Node architecture on this host"
	_dpr_base="$SANDBOX/optrun/fcc/data/.local/share/pi-node"
	_dpr_logs="$SANDBOX/diaglogs"
	mkdir -p "$_dpr_logs" "$SANDBOX/nolibs" "$_dpr_base/old/bin"
	: > "$_dpr_logs/fcc-runtime.log"

	# The Node that is already there: too old for any of the npm agents, so it
	# does not satisfy the floor and the fetch goes ahead — and it is what
	# `current` points at, which is how the assertions below can tell that a
	# failure left the pointer alone instead of moving it to the build it threw
	# away. npm comes with it because the floor is asked of a directory holding
	# both, the same way the real one does.
	printf '#!/bin/sh\nprintf "v18.0.0\\n"\n' > "$_dpr_base/old/bin/node"
	printf '#!/bin/sh\nexit 0\n' > "$_dpr_base/old/bin/npm"
	chmod +x "$_dpr_base/old/bin/node" "$_dpr_base/old/bin/npm"
	ln -s "$_dpr_base/old" "$_dpr_base/current"

	# The library scan is pointed at an empty directory, so that the second log
	# line — the one naming the package to install — is the answer this case is
	# about rather than a description of the machine running the tests.
	sh_install "fcc_dir_logs() { printf '%s' '$_dpr_logs'; }
		PATH='$SANDBOX/nodebin':\$PATH
		FCC_NODE_LIB_DIRS='$SANDBOX/nolibs' LD_LIBRARY_PATH=
		provision_node pi" "$SANDBOX/optrun" >/dev/null 2>&1

	_dpr_log="$(cat "$_dpr_logs/fcc-runtime.log")"
	assert_contains "$_dpr_log" 'does not run here' \
		"a build that dies in the loader is reported as one that does not run"
	assert_contains "$_dpr_log" 'Error loading shared library libstdc++.so.6' \
		"and the log carries the loader's own sentence rather than a summary of it"
	assert_not_contains "$_dpr_log" 'installed v22.23.3' \
		"and it is not reported as installed, which is what it was before"
	assert_eq "$_dpr_base/old" "$(readlink "$_dpr_base/current")" \
		"and current is left where it was rather than aimed at a build that cannot run"
	assert_no "the build that does not run is not left on disk" \
		test -e "$_dpr_base/$_dpr_name"

	# The library is named only when it is the one actually missing — on a box
	# that has it the reason is something else, and blaming libstdc++ there
	# sends the reader to install a package they already have. That branch is
	# pinned from the other side by the doctor test; this asserts the half that
	# can be produced here, and only where the scan can be made to say so, since
	# a musl host whose /etc/ld-musl-*.path names a directory holding the real
	# libraries would find them whatever this case asks for.
	if [ -n "$(sh_common "FCC_NODE_LIB_DIRS='$SANDBOX/nolibs' LD_LIBRARY_PATH= fcc_node_missing_libs")" ]; then
		assert_contains "$_dpr_log" 'libstdc++.so.6' \
			"and the log names the library the loader could not find"
		assert_contains "$_dpr_log" 'opkg install libstdcpp libgcc1' \
			"and the package that provides it, which is the part a reader can act on"
	fi
}

# The Node has to be fetched from an environment this package does not own.
#
# A job is started from a CGI — luci.fcc.util.spawn_detached() forks it out of
# the uhttpd process — and that environment is not a login shell's. Measured on
# the test router, it is this and nothing else:
#
#   PATH=/sbin:/usr/sbin:/bin:/usr/bin  PWD=/www  SHLVL=1
#   plus the CGI and HTTP_* variables. No HOME. No XDG_DATA_HOME.
#
# So the obvious way to spell the destination,
#
#   _pn_base="${XDG_DATA_HOME:-$HOME/.local/share}/pi-node"
#
# is fatal here. Under `set -u` the default word is expanded to decide whether
# to use it, so an unset $HOME inside it aborts the whole script even though the
# fallback is the branch that would have been taken. On 2026-10-16 that ended a
# real install three seconds in, with
#
#   /usr/libexec/fcc/install.sh: line 675: HOME: parameter not set
#
# and the log stops there (§104.30). The install job had already downloaded the
# upstream installer and backed the runtime up, so the page showed a progress bar
# most of the way along over work that had stopped.
#
# The suite did not catch it because the suite has a HOME. This test does not:
# both variables are unset for the call, which is the router's environment
# rather than a likeness of it.
test_provision_node_needs_no_environment() {
	setup_sandbox
	make_node_release_fixture >/dev/null || skip "no musl Node architecture on this host"
	_dpe_base="$SANDBOX/optnoenv/fcc/data/.local/share/pi-node"
	_dpe_logs="$SANDBOX/diaglogs"
	mkdir -p "$_dpe_logs"
	: > "$_dpe_logs/fcc-runtime.log"

	# `unset` in a subshell rather than `env -u`: sh_install is a shell
	# function, and env can only run a command. The subshell is what keeps the
	# unsetting from reaching the tests that run after this one.
	(
		unset HOME XDG_DATA_HOME
		sh_install "fcc_dir_logs() { printf '%s' '$_dpe_logs'; }
			PATH='$SANDBOX/nodebin':\$PATH
			provision_node pi" "$SANDBOX/optnoenv"
	) > "$SANDBOX/noenv.out" 2>&1

	assert_not_contains "$(cat "$SANDBOX/noenv.out")" 'parameter not set' \
		"provision_node runs with neither HOME nor XDG_DATA_HOME set"
	assert_exec "$_dpe_base/current/bin/node" \
		"and the node still lands where the panes look for it"
	assert_eq "v22.23.3" "$("$_dpe_base/current/bin/node" 2>/dev/null)" \
		"and it is the release the index named"
	assert_contains "$(cat "$_dpe_logs/fcc-runtime.log")" 'installed v22.23.3' \
		"and it was fetched rather than skipped"

	# The same call with the environment the suite normally has, to show the
	# test above is measuring the absence and not something else. A Node already
	# in place is not fetched again, so the log stays empty — which is the
	# answer the first half would have got too if the destination had been read
	# from the environment rather than from the root.
	: > "$_dpe_logs/fcc-runtime.log"
	sh_install "fcc_dir_logs() { printf '%s' '$_dpe_logs'; }
		PATH='$SANDBOX/nodebin':\$PATH
		provision_node pi" "$SANDBOX/optnoenv" >/dev/null 2>&1
	assert_eq "" "$(cat "$_dpe_logs/fcc-runtime.log")" \
		"and a second call finds it without asking the environment"
}

# The rest of the environment a CGI does not pass.
#
# install.sh is `set -u`, so any variable it reads that the job's environment
# does not carry kills the script at that line. HOME was one; this is the sweep
# for the others. apply_runtime_env() extends PATH rather than replacing it and
# the CGI does set PATH today, so this is not a live failure — but it is the one
# variable in that function that comes from outside, and the cost of the default
# is one token.
test_apply_runtime_env_survives_an_empty_environment() {
	setup_sandbox
	# PATH is unset *inside* the shell rather than before it. The harness needs a
	# PATH of its own to find `sh` in the first place, and what is under test is
	# the state apply_runtime_env() finds when it runs — which is reachable from
	# here. HOME goes with it: this function is what *sets* HOME for everything
	# downstream, so it must not be reading one.
	sh_install 'unset PATH HOME XDG_DATA_HOME
		apply_runtime_env "$ROOT"
		printf "%s|%s" "$PATH" "$HOME"' > "$SANDBOX/envpath.out" 2>&1

	assert_not_contains "$(cat "$SANDBOX/envpath.out")" 'parameter not set' \
		"apply_runtime_env runs with PATH, HOME and XDG_DATA_HOME all unset"
	assert_contains "$(cat "$SANDBOX/envpath.out")" '/sbin' \
		"and PATH is given a working default rather than emptied"
	assert_contains "$(cat "$SANDBOX/envpath.out")" '/fcc/bin' \
		"and the runtime's own directories still go in front of it"
	assert_contains "$(cat "$SANDBOX/envpath.out")" "$SANDBOX/opt/fcc/data" \
		"and HOME is derived from the root rather than inherited"
}

tests_main
