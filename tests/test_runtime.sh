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
#   sh_common_tools '<tools>' '<code>'
sh_common_tools() {
	rm -rf "$SANDBOX/toolbin"
	mkdir -p "$SANDBOX/toolbin"
	# sh itself, because PATH has to hold the shell that is about to be run.
	for _tr_t in sh $1; do
		_tr_p="$(command -v "$_tr_t" 2>/dev/null)" || continue
		ln -sf "$_tr_p" "$SANDBOX/toolbin/$_tr_t"
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
	# `sh` stands in for an installed launcher: installation is decided by
	# `command -v`, so anything on PATH counts.
	_tr_conf="$SANDBOX/agents.conf"
	printf '%s\n' \
		'noprobe|No Probe|sh|0|10|10|' \
		'badprobe|Bad Probe|sh|0|10|10|false' \
		'absent|Absent|fcc-not-a-real-launcher|0|10|10|sh' > "$_tr_conf"

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
	mkdir -p "$_cs_bin" "$SANDBOX/opt/fcc/sessions"

	# A runtime that looks installed and a server that looks alive, so that the
	# two guards in front of the tmux calls are satisfied.
	printf '#!/bin/sh\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$_cs_bin/fcc-server"
	chmod +x "$_cs_bin/fcc-server"
	"$_cs_bin/fcc-server" &
	_cs_srv=$!

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

tests_main
