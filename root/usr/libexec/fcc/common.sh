#!/bin/sh
# luci-app-fcc — common shell helpers.
#
# POSIX sh (busybox ash). This file is *sourced*, never executed directly.
# It provides path canonicalisation, UCI access, agent-registry parsing, JSON
# emission, logging with secret redaction and a few /proc readers.
#
# Security contract (DESIGN_SPEC.md section 30):
#   * No function here ever passes user input to `eval` or to a shell string.
#   * Agent ids and session ids are validated against fixed grammars.
#   * Filesystem paths are canonicalised and rejected if they point at system
#     directories.
#   * All command execution goes through explicit argv, never through a
#     concatenated command string.
#
# Variable-naming contract: POSIX sh has ONE global scope shared by every
# function, and callers run with `set -u`. A helper that assigns a bare name
# like `_name` therefore clobbers its caller's `_name`, and a helper that
# `unset`s it makes the caller die with "parameter not set". Every local in
# this file is therefore prefixed with a per-function tag (`_ug_`, `_lg_`, ...)
# and helpers never unset anything they did not create.

# ---------------------------------------------------------------------------
# Constants / defaults
# ---------------------------------------------------------------------------
FCC_AGENTS_CONF="${FCC_AGENTS_CONF:-/usr/share/luci-app-fcc/agents.conf}"
FCC_VERSION_FILE="${FCC_VERSION_FILE:-/usr/share/luci-app-fcc/VERSION}"
FCC_DEFAULT_BASE="${FCC_DEFAULT_BASE:-/opt}"
FCC_HZ="${FCC_HZ:-100}"                 # clock ticks per second (OpenWrt default)
FCC_VERSION_CACHE_TTL="${FCC_VERSION_CACHE_TTL:-60}"
FCC_SESSION_PREFIX="fcc-"

# The free space, in MB, that an install must have. Two gates apply it and they
# are two views of one requirement — is there room for the FCC runtime and the
# agents on top of it — so the number lives in one place rather than being typed
# into each of them, where the two would eventually disagree. doctor.sh applies
# it before an install is allowed to start (section 3.6.4); install.sh applies
# it again immediately before it writes (section 23 step 3).
#
# TEMPORARY, at the project owner's request: relaxed so the runtime can be
# exercised on a device with 233 MB free. The enforced floor is to become
# 512 MB once that testing is done — this is the one number to change.
FCC_MIN_FREE_MB="${FCC_MIN_FREE_MB:-64}"

fcc_die() { printf '%s\n' "fcc: $*" >&2; return 1; }

# ---------------------------------------------------------------------------
# LuCI-FCC's own version
# ---------------------------------------------------------------------------
fcc_luci_version() {
	if [ -r "$FCC_VERSION_FILE" ]; then
		tr -d ' \t\r\n' < "$FCC_VERSION_FILE"
	else
		echo "0.0.0"
	fi
}

# ---------------------------------------------------------------------------
# UCI access (never fails the caller)
# ---------------------------------------------------------------------------
fcc_uci_get() {
	# fcc_uci_get <section> <option> [default]
	_ug_v="$(uci -q get "fcc.$1.$2" 2>/dev/null)"
	if [ -z "$_ug_v" ]; then
		printf '%s' "${3:-}"
	else
		printf '%s' "$_ug_v"
	fi
}

# ---------------------------------------------------------------------------
# Install-path canonicalisation
#
# UCI `install_path` is treated as a *base* directory. The FCC root is
# <base>/fcc, unless <base> already ends in /fcc. This lets a user type
# /mnt/sda and get /mnt/sda/fcc, while the shipped default /opt/fcc stays
# /opt/fcc. See DESIGN_SPEC.md section 27.
# ---------------------------------------------------------------------------
fcc_canon_base() {
	# fcc_canon_base <raw> -> canonical base path on stdout, or fail.
	_cb_raw="$1"
	# Trim surrounding whitespace.
	_cb_raw="$(printf '%s' "$_cb_raw" | tr -d ' \t\r\n')"
	[ -n "$_cb_raw" ] || _cb_raw="$FCC_DEFAULT_BASE"

	# Reject anything with shell/quote metacharacters outright.
	case "$_cb_raw" in
		*[\ \'\"\`\$\;\&\|\<\>\(\)\{\}\*\!\?\~]*) return 1 ;;
	esac
	# Must be absolute.
	case "$_cb_raw" in
		/*) : ;;
		*) return 1 ;;
	esac
	# Collapse duplicate slashes and drop a trailing slash.
	_cb_raw="$(printf '%s' "$_cb_raw" | sed -e 's#//*#/#g' -e 's#/$##')"
	[ -n "$_cb_raw" ] || _cb_raw="/"

	# Reject paths that live inside system directories.
	case "$_cb_raw" in
		/|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/tmp|/tmp/*|/var|/var/*|\
		/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|\
		/lib64|/lib64/*|/rom|/rom/*|/overlay|/overlay/*|/root|/root/*)
			return 1 ;;
	esac
	# Reject path traversal segments.
	case "$_cb_raw" in
		*/../*|*/..|../*|..) return 1 ;;
	esac

	printf '%s' "$_cb_raw"
	return 0
}

fcc_root() {
	# fcc_root -> canonical FCC root (<base>/fcc) on stdout.
	#
	# Two fallbacks, not one: a rejected install_path must not fall through to an
	# equally rejected default. Each candidate is canonicalised on its own, and
	# only if both fail does the hard-coded /opt apply.
	_rt_base="$(fcc_canon_base "$(fcc_uci_get main install_path "$FCC_DEFAULT_BASE")")" \
		|| _rt_base="$(fcc_canon_base "$FCC_DEFAULT_BASE")" \
		|| _rt_base=/opt
	case "$_rt_base" in
		*/fcc) printf '%s' "$_rt_base" ;;
		*)     printf '%s/fcc' "$_rt_base" ;;
	esac
}

# Convenience accessors for the standard subdirectories.
fcc_dir_runtime() { printf '%s/runtime' "$(fcc_root)"; }
fcc_dir_bin()     { printf '%s/bin'     "$(fcc_root)"; }
fcc_dir_data()    { printf '%s/data'    "$(fcc_root)"; }
fcc_dir_cache()   { printf '%s/cache'   "$(fcc_root)"; }
fcc_dir_logs()    { printf '%s/logs'    "$(fcc_root)"; }
fcc_dir_sessions(){ printf '%s/sessions' "$(fcc_root)"; }
fcc_dir_backup()  { printf '%s/backup'  "$(fcc_root)"; }

fcc_ensure_dirs() {
	for _ed_d in "$(fcc_dir_runtime)" "$(fcc_dir_bin)" "$(fcc_dir_data)" \
	              "$(fcc_dir_cache)" "$(fcc_dir_logs)" "$(fcc_dir_sessions)" \
	              "$(fcc_dir_backup)"; do
		[ -d "$_ed_d" ] || mkdir -p "$_ed_d" 2>/dev/null
	done
}

# ---------------------------------------------------------------------------
# Logging (with secret redaction)
# ---------------------------------------------------------------------------
fcc_redact() {
	# Strip obvious secrets from a log line. Best-effort, defence in depth.
	sed -e 's/\(sk-[A-Za-z0-9_-]\{6\}\)[A-Za-z0-9_-]*/\1***REDACTED***/g' \
	    -e 's/\(gh[pousr]_[A-Za-z0-9]\{4\}\)[A-Za-z0-9]*/\1***REDACTED***/g' \
	    -e 's/\([Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]\+\)[^[:space:]]\+/\1***REDACTED***/g' \
	    -e 's/\([Aa]pi[_-]\?[Kk]ey[=:][[:space:]]*\)[^[:space:]]\+/\1***REDACTED***/g' \
	    -e 's/\([Tt]oken[=:][[:space:]]*\)[^[:space:]]\+/\1***REDACTED***/g'
}

fcc_log() {
	# fcc_log <logfile-name> <message...>
	_lg_name="$1"; shift
	_lg_dir="$(fcc_dir_logs)"
	if ! mkdir -p "$_lg_dir" 2>/dev/null || [ ! -w "$_lg_dir" ]; then
		_lg_dir="/tmp/fcc-logs"
		mkdir -p "$_lg_dir" 2>/dev/null
	fi
	_lg_msg="$(printf '%s' "$*" | fcc_redact)"
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_lg_msg" >> "$_lg_dir/$_lg_name" 2>/dev/null
}

# ---------------------------------------------------------------------------
# JSON emission helpers
# ---------------------------------------------------------------------------
fcc_json_str() {
	# Emit a quoted JSON string for the given value (handles ", \ and controls).
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | \
		awk 'BEGIN{printf "\""} {if(NR>1)printf "\\n"; printf "%s",$0} END{printf "\""}'
}

fcc_json_bool() {
	case "$1" in
		1|true|yes|on) printf 'true' ;;
		*)             printf 'false' ;;
	esac
}

fcc_json_num_or_null() {
	case "$1" in
		''|*[!0-9]*) printf 'null' ;;
		*)           printf '%s' "$1" ;;
	esac
}

fcc_json_str_or_null() {
	if [ -n "$1" ]; then fcc_json_str "$1"; else printf 'null'; fi
}

# ---------------------------------------------------------------------------
# Agent registry
# ---------------------------------------------------------------------------
fcc_agents_each() {
	# Iterate the registry. Prints the raw lines (id|name|cmd|default|size|ram|probe).
	[ -r "$FCC_AGENTS_CONF" ] || return 0
	grep -v '^[[:space:]]*#' "$FCC_AGENTS_CONF" | grep -v '^[[:space:]]*$'
}

fcc_valid_agent() {
	# fcc_valid_agent <id> -> 0 if the id is a known agent.
	[ -n "$1" ] || return 1
	case "$1" in
		*[!a-z0-9]*) return 1 ;;   # ids are lowercase alphanumeric only
	esac
	# Not `fcc_agents_each | cut -d'|' -f1 | grep -qx`.
	#
	# That shape is the only way in this backend to produce busybox's "cut:
	# standard output: Broken pipe": cut writes, grep -q stops at the first
	# match and closes the pipe, and cut is left writing into it. It stays
	# quiet under a normal shell only because SIGPIPE kills the writer before
	# it can report anything — LuCI runs its children with SIGPIPE ignored
	# (uhttpd sets it so a disconnected browser cannot kill the server), and
	# then the same write returns EPIPE and busybox prints the complaint. In a
	# job, stderr is the install log, so it lands next to whatever really went
	# wrong and reads like a second, unrelated problem.
	#
	# Measured on the smoke container: the message appears with SIGPIPE
	# ignored and disappears without it. Whether it appears for this pipeline
	# depends on whether cut has anything left to write when grep exits, and
	# that is a race rather than a property: the shipped ten-line registry fits
	# in the pipe buffer and stayed silent, while the same pipeline over a
	# registry larger than the buffer prints it every time — which is the
	# reproduction scripts/smoke.sh now asserts, both ways round. It was
	# reported from a router, where the race goes the other way: grep is a
	# process on a slow CPU and can finish before cut is scheduled to write at
	# all. Nothing here is large enough to be worth short-circuiting, so awk
	# reads the registry to the end and decides then, and no stage is ever cut
	# off mid-write. The id is already known to be lowercase alphanumeric, so
	# it is safe to hand to awk as a value.
	fcc_agents_each | awk -F'|' -v id="$1" '$1 == id { found = 1 } END { exit !found }'
}

fcc_agent_field() {
	# fcc_agent_field <id> <field-no 1..7> -> value or empty
	_af_line="$(fcc_agents_each | awk -F'|' -v id="$1" '$1==id{print; exit}')"
	[ -n "$_af_line" ] || return 1
	printf '%s' "$_af_line" | cut -d'|' -f"$2"
}

fcc_agent_command() { fcc_agent_field "$1" 3; }
fcc_agent_name()    { fcc_agent_field "$1" 2; }
fcc_agent_probe()   { fcc_agent_field "$1" 7; }

# ---------------------------------------------------------------------------
# Version detection
#
# NEVER call an fcc-* launcher to read a version: those launchers START the
# agent. Only probe the underlying CLI recorded in the registry's `probe`
# column, and only when it actually resolves. Bounded by a hard timeout so a
# hanging CLI (e.g. `hermes --version`) cannot wedge a status refresh.
# ---------------------------------------------------------------------------
fcc_detect_version() {
	# fcc_detect_version <executable> [args...] -> version string, or fail
	_dv_exe="$1"; shift
	command -v "$_dv_exe" >/dev/null 2>&1 || return 1
	_dv_out="$(timeout 5 "$_dv_exe" "$@" 2>/dev/null | head -n 20)" || return 1
	_dv_v="$(printf '%s\n' "$_dv_out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+.][A-Za-z0-9.]+)?' | head -n1)"
	if [ -z "$_dv_v" ]; then
		_dv_v="$(printf '%s\n' "$_dv_out" | grep -v '^[[:space:]]*$' | head -n1 | cut -c1-40)"
	fi
	[ -n "$_dv_v" ] || return 1
	printf '%s' "$_dv_v"
	return 0
}

# ---------------------------------------------------------------------------
# Session id grammar:  fcc-<agent>-<NNN>
# ---------------------------------------------------------------------------
fcc_valid_session() {
	# Reject anything that is not exactly fcc-<known-agent>-<3 digits>.
	[ -n "$1" ] || return 1
	case "$1" in
		fcc-*-[0-9][0-9][0-9]) : ;;
		*) return 1 ;;
	esac
	_vs_agent="$(printf '%s' "$1" | sed -n 's/^fcc-\([a-z0-9]\{1,16\}\)-[0-9]\{3\}$/\1/p')"
	[ -n "$_vs_agent" ] || return 1
	fcc_valid_agent "$_vs_agent"
}

# ---------------------------------------------------------------------------
# Locks (update / install). Stale locks older than 1h are reclaimed.
# ---------------------------------------------------------------------------
fcc_lock_dir() {
	if [ -d /var/lock ] && [ -w /var/lock ]; then printf '/var/lock'; else printf '/tmp'; fi
}

fcc_lock_acquire() {
	# fcc_lock_acquire <name> -> 0 on success; prints the lock path
	_la_lock="$(fcc_lock_dir)/fcc-$1.lock"
	if [ -d "$_la_lock" ]; then
		# Reclaim a stale lock (older than 3600s).
		_la_age=$(( $(date +%s) - $(date -r "$_la_lock" +%s 2>/dev/null || echo 0) ))
		if [ "$_la_age" -gt 3600 ]; then
			rmdir "$_la_lock" 2>/dev/null
		fi
	fi
	if mkdir "$_la_lock" 2>/dev/null; then
		printf '%s' "$$" > "$_la_lock/pid" 2>/dev/null
		printf '%s' "$_la_lock"
		return 0
	fi
	return 1
}

fcc_lock_release() {
	[ -n "$1" ] && rm -rf "$1" 2>/dev/null
	return 0
}

fcc_lock_held() {
	_lh_lock="$(fcc_lock_dir)/fcc-$1.lock"
	[ -d "$_lh_lock" ]
}

# ---------------------------------------------------------------------------
# Version cache — "key<TAB>value" lines in one file under the runtime cache.
# Falls back to /tmp when the install path is not writable yet, so the UI still
# works (just uncached) before the runtime has been installed.
# ---------------------------------------------------------------------------
fcc_cache_dir() {
	_cd_d="$(fcc_dir_cache)"
	if ! mkdir -p "$_cd_d" 2>/dev/null || [ ! -w "$_cd_d" ]; then
		_cd_d="/tmp/fcc-cache"
		mkdir -p "$_cd_d" 2>/dev/null
	fi
	printf '%s' "$_cd_d"
}

fcc_cache_get() {
	_cg_c="$(fcc_cache_dir)/versions.cache"
	[ -r "$_cg_c" ] || return 1
	awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$_cg_c"
}

fcc_cache_set() {
	_cs_dir="$(fcc_cache_dir)"
	[ -w "$_cs_dir" ] || return 0
	_cs_c="$_cs_dir/versions.cache"
	_cs_tmp="$_cs_c.$$"
	{ [ -r "$_cs_c" ] && awk -F'\t' -v k="$1" '$1!=k' "$_cs_c"; } > "$_cs_tmp" 2>/dev/null
	printf '%s\t%s\n' "$1" "$2" >> "$_cs_tmp"
	mv "$_cs_tmp" "$_cs_c" 2>/dev/null
}

fcc_cache_fresh() {
	_cf_c="$(fcc_cache_dir)/versions.cache"
	[ -r "$_cf_c" ] || return 1
	_cf_now=$(date +%s)
	_cf_mt=$(date -r "$_cf_c" +%s 2>/dev/null || echo 0)
	[ $(( _cf_now - _cf_mt )) -lt "$FCC_VERSION_CACHE_TTL" ]
}

# ---------------------------------------------------------------------------
# /proc readers (single pass, no per-agent forks)
# ---------------------------------------------------------------------------
fcc_proc_rss_kb() {
	# fcc_proc_rss_kb <pid> -> VmRSS in kB, or empty.
	[ -n "$1" ] || return 1
	awk '/^VmRSS:/{print $2; exit}' "/proc/$1/status" 2>/dev/null
}

fcc_proc_starttime_ticks() {
	# fcc_proc_starttime_ticks <pid> -> field 22 of /proc/<pid>/stat.
	[ -n "$1" ] || return 1
	[ -r "/proc/$1/stat" ] || return 1
	# Strip everything up to and including the last ')' so a comm containing
	# spaces or parentheses cannot shift the field positions.
	_ps_rest="$(sed -e 's/^[^)]*) //' "/proc/$1/stat" 2>/dev/null)"
	# Field 3 of stat is the first token of _ps_rest, so field 22 is token 20.
	printf '%s' "$_ps_rest" | awk '{print $20}'
}

fcc_proc_uptime_secs() {
	# fcc_proc_uptime_secs <pid> -> seconds since process start, or empty.
	_pu_st="$(fcc_proc_starttime_ticks "$1")"
	case "$_pu_st" in ''|*[!0-9]*) return 1 ;; esac
	_pu_now="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
	case "$_pu_now" in ''|*[!0-9.]*) return 1 ;; esac
	# uptime is seconds (float); starttime is ticks.
	awk -v up="$_pu_now" -v st="$_pu_st" -v hz="$FCC_HZ" \
		'BEGIN{v=up-(st/hz); if(v<0)v=0; printf "%d", v}'
}

fcc_proc_alive() {
	[ -n "$1" ] && [ -d "/proc/$1" ]
}

fcc_cpu_info() {
	# fcc_cpu_info [cpuinfo-file] -> three lines: model, MHz, cores.
	#
	# /proc/cpuinfo names the CPU differently on every architecture OpenWrt runs
	# on: x86 has "model name", 32-bit ARM has "Hardware", MIPS has "cpu model".
	# The first of those present wins. When none is present the model line comes
	# back empty — and that is the arm64 case rather than a broken board:
	# mainline prints "model name" only for a 32-bit ELF platform and has no
	# "Hardware" line at all, because that one is arm32 or a vendor tree. The
	# caller then asks the device tree, which is the only other place the answer
	# lives, and only when that has nothing either does the page show a dash
	# rather than a board name passed off as a CPU. The core count is empty too
	# when no "processor" line was seen — the caller reports null rather than
	# inventing a 1.
	#
	# BogoMIPS is deliberately not consulted. It is a calibration constant, not a
	# clock rate, and printing it as MHz would be a number that looks like an
	# answer and is not one. The MHz here is what x86 reports; a kernel with
	# cpufreq answers better, and the caller prefers that.
	#
	# The file is a parameter so this can be tested against the cpuinfo of every
	# architecture rather than the one the test machine happens to have.
	# FCC_PROC_CPUINFO does the same for the no-argument call, which is how
	# status.sh is run in the tests as a board whose cpuinfo names no CPU.
	#
	# The value is taken from $0 rather than $2 because a model name may itself
	# contain a colon and $2 would stop at it.
	_fc_file="${1:-${FCC_PROC_CPUINFO:-/proc/cpuinfo}}"
	awk -F: '
		{
			k = $1
			sub(/^[ \t]+/, "", k); sub(/[ \t]+$/, "", k)
			v = $0
			sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
		}
		k == "processor"  { cores++ }
		k == "model name" { if (model  == "") model  = v }
		k == "Hardware"   { if (hw     == "") hw     = v }
		k == "cpu model"  { if (cmodel == "") cmodel = v }
		k == "cpu MHz"    { if (mhz    == "") mhz    = v }
		END {
			if (model == "") model = cmodel
			if (model == "") model = hw
			printf "%s\n%s\n%s\n", model, mhz, cores
		}
	' "$_fc_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Where the kernel keeps its CPU facts
#
# Both are single directories that can be pointed elsewhere, for the same reason
# FCC_LIBDIR and FCC_DEFAULT_BASE can: the machine running the tests is not an
# ARM router. It has cpufreq of its own, which would answer every question here
# before the fallbacks were reached, and it has no device tree at all — so
# without these the code path that ARM routers depend on could not be run.
# ---------------------------------------------------------------------------
fcc_sys_cpu() {
	# fcc_sys_cpu -> the kernel's per-CPU sysfs root.
	printf '%s' "${FCC_SYS_CPU:-/sys/devices/system/cpu}"
}

fcc_dt_base() {
	# fcc_dt_base -> where the kernel exposes the device tree. A path that is
	# not there is not an error: every reader of it refuses a directory it
	# cannot read, and the caller ends up with no rate — which is what happens
	# on every x86 router.
	printf '%s' "${FCC_DT_BASE:-/sys/firmware/devicetree/base}"
}

fcc_openwrt_release() {
	# fcc_openwrt_release -> the release file that names the OpenWrt target.
	# Overridable for the same reason as the paths above: the platform reading
	# is the target in that file, and a machine that is not OpenWrt has no such
	# file to read.
	printf '%s' "${FCC_OPENWRT_RELEASE:-/etc/openwrt_release}"
}

fcc_sysinfo_dir() {
	# fcc_sysinfo_dir -> where the boot scripts leave the board's own name.
	# Written at boot, so it exists on a running device and not in an image that
	# has never been started.
	printf '%s' "${FCC_SYSINFO_DIR:-/tmp/sysinfo}"
}

fcc_hex_dump() {
	# fcc_hex_dump <file>... -> those files' bytes as lowercase hex, or empty.
	#
	# Reading a device tree property means reading bytes, and OpenWrt's busybox
	# has no od: hexdump is the applet it ships instead. Both are asked for the
	# same bare byte stream — od -An -tx1, hexdump -v -e '1/1 "%02x"' — and the
	# caller cannot tell which answered. Where neither exists the answer is
	# empty, which every caller here already treats as "the property is not
	# there".
	#
	# -v is load-bearing for hexdump: without it a run of repeated lines
	# collapses to `*`, and an OPP table is fifteen lines that differ in one or
	# two digits, so the table would be silently cut down to its first entries.
	#
	# Several files concatenate, with nothing between them, which is what lets a
	# whole OPP table be read in one process rather than one per OPP.
	[ -n "${1:-}" ] || return 1
	if command -v od >/dev/null 2>&1; then
		od -An -tx1 "$@" 2>/dev/null | tr -d ' \n'
		return 0
	fi
	if command -v hexdump >/dev/null 2>&1; then
		hexdump -v -e '1/1 "%02x"' "$@" 2>/dev/null | tr -d ' \n'
		return 0
	fi
	return 1
}

fcc_cpu_dt_hz() {
	# fcc_cpu_dt_hz <clock-frequency-file> -> the rate in Hz, or empty.
	#
	# The device tree's clock-frequency is a big-endian 32-bit count of Hz, so
	# it is read as bytes: `read` would hand back four unprintable characters
	# and any arithmetic on those would be nonsense.
	#
	# It lives here rather than inline in status.sh so it can be tested against
	# a fixture, for the same reason fcc_cpu_info does: the machine running the
	# tests is not an ARM router and has no device tree to read.
	#
	# The length is checked before the bytes reach the arithmetic, because
	# `$(( 0x ))` is a syntax error in ash and a short read — a truncated
	# property, a file that is not the one we thought it was — would otherwise
	# take the whole status script, and the page reading it, down with it.
	# There is no character check to go with it: fcc_hex_dump emits nothing but
	# hex digits, so one would never fire.
	[ -n "${1:-}" ] && [ -r "$1" ] || return 1

	_cd_hex="$(fcc_hex_dump "$1")" || return 1
	case "$_cd_hex" in
		????????*) ;;
		*) return 1 ;;
	esac
	# The first four bytes, whatever else the file holds.
	_cd_hex="${_cd_hex%"${_cd_hex#????????}"}"

	_cd_hz=$(( 0x$_cd_hex ))
	[ "$_cd_hz" -gt 0 ] || return 1
	printf '%s' "$_cd_hz"
}

fcc_cpu_dt_opp_hz() {
	# fcc_cpu_dt_opp_hz <devicetree-base-dir> -> the highest opp-hz, in Hz, or
	# empty.
	#
	# This is the other way a device tree states a CPU clock, and on arm64 it is
	# the usual one: the cpu nodes carry an operating-points-v2 table instead of
	# a clock-frequency. The Airoha EN7581 — the SoC in the AN7581 routers — is
	# exactly that shape, so on those boards the property fcc_cpu_dt_hz reads is
	# not there at all and this is the only clock figure the device tree holds.
	#
	# Why this matters at all, rather than being a second way to ask a question
	# sysfs already answers: OpenWrt 24.10 builds the EN7581 cpufreq driver
	# (CONFIG_ARM_AIROHA_SOC_CPUFREQ) but leaves CONFIG_CPUFREQ_DT off. That
	# driver's whole job is to register a cpufreq-dt platform device, so with the
	# generic driver absent nothing binds, no policy is created, and *neither*
	# /sys/devices/system/cpu/cpu0/cpufreq nor cpufreq/policy0 exists. The board
	# is running fine; sysfs simply has no rate to report, and the page shows a
	# dash on hardware that is working.
	#
	# The table is found by name rather than by following the phandle the cpu
	# node points at. Following it would mean reading a phandle out of every node
	# at the device tree root, which is a process per node on every status poll —
	# section 3.8 keeps this script to one process — and the walk is not needed
	# for the answer: what is wanted is the highest rate the CPU is specified at,
	# and the highest opp-hz in any CPU table is that rate whether the board has
	# one cluster or a big.LITTLE pair.
	#
	# Each value is 64-bit big-endian and lives on its own opp node, so the glob
	# ends in opp-*/opp-hz rather than opp-table*/opp-hz — the table node itself
	# carries only compatible and opp-shared. Every one of those files is exactly
	# one cell pair, which is what lets them all go to a single fcc_hex_dump:
	# their bytes concatenate into a string that divides evenly into
	# 16-hex-digit values, and the whole table costs one process rather than one
	# per OPP.
	_dt_base="${1:-}"
	[ -n "$_dt_base" ] && [ -d "$_dt_base" ] || return 1

	_dt_hex="$(fcc_hex_dump "$_dt_base"/opp-table*/opp-*/opp-hz)" || return 1
	[ -n "$_dt_hex" ] || return 1
	[ $(( ${#_dt_hex} % 16 )) -eq 0 ] || return 1

	_dt_best=""
	while [ ${#_dt_hex} -ge 16 ]; do
		_dt_one="${_dt_hex%"${_dt_hex#????????????????}"}"
		_dt_hex="${_dt_hex#????????????????}"
		# The high word of a CPU clock is zero. A rate that needs it is not one
		# this is being asked about, and the arithmetic for one would be wider
		# than a 32-bit router's shell is required to carry.
		case "$_dt_one" in
			00000000*) ;;
			*) continue ;;
		esac
		_dt_hz=$(( 0x${_dt_one#00000000} ))
		[ "$_dt_hz" -gt 0 ] || continue
		if [ -z "$_dt_best" ] || [ "$_dt_hz" -gt "$_dt_best" ]; then
			_dt_best="$_dt_hz"
		fi
	done
	[ -n "$_dt_best" ] || return 1
	printf '%s' "$_dt_best"
}

fcc_cpu_dt_model() {
	# fcc_cpu_dt_model <cpu-node-dir> -> the CPU model that node names, or
	# empty.
	#
	# The companion to fcc_cpu_dt_opp_hz: the same nodes, a different property.
	# The clock comes from the operating-points-v2 table and the name from
	# `compatible`, and on the boards that need either — arm64, whose cpuinfo
	# names no CPU at all — the device tree is the only place the name exists.
	#
	# `compatible` is a NUL-separated list of strings, most specific first, and
	# it is written without a trailing newline. Two consequences, both of them
	# about not reporting a name that is not there (section 44):
	#
	#   * `read` is asked for one line and told that end-of-file is not an
	#     error, because that is how every one of these files ends.
	#   * a shell variable cannot hold a NUL, so `read` drops it and carries on:
	#     a node naming two things comes back as one run-together word.
	#     Measured on the smoke rootfs, "a,b\0c,d\0" reads as "a,bc,d". The byte
	#     count is therefore compared with what was read — one string is exactly
	#     one byte longer than the string — and anything else is refused. A CPU
	#     node names one core, so this refuses nothing real; it is here so that a
	#     node that did name two cannot produce a name that is neither.
	#
	# What is left is written the way a person reads it: the vendor and the part
	# are separate words and each part is capitalised, so "arm,cortex-a53" is
	# "Arm Cortex-A53" rather than a device tree spelling on a web page.
	[ -r "$1/compatible" ] || return 1
	# stderr is redirected before the file is opened, not after: the shell
	# prints its own "cannot open" message when a redirection fails, and the
	# redirections are applied left to right, so the other order leaves that
	# message on the log. The -r test above is what keeps a board without the
	# node quiet at all.
	_fcm_v=""
	IFS= read -r _fcm_v 2>/dev/null < "$1/compatible" || :
	[ -n "$_fcm_v" ] || return 1
	_fcm_n="$(wc -c 2>/dev/null < "$1/compatible")" || return 1
	_fcm_n="${_fcm_n##* }"
	[ "$_fcm_n" = "$(( ${#_fcm_v} + 1 ))" ] || return 1
	awk '{
		out = ""
		up = 1
		for (i = 1; i <= length($0); i++) {
			c = substr($0, i, 1)
			if (c == ",") { out = out " "; up = 1; continue }
			if (up) { c = toupper(c); up = 0 }
			out = out c
			if (c == "-") up = 1
		}
		print out
	}' <<-EOF
	$_fcm_v
	EOF
}

# ---------------------------------------------------------------------------
# FCC server health (DESIGN_SPEC.md section 49)
#
# Section 49 asks for a post-update check on three levels: the process exists,
# the port is listening, and the admin endpoint answers. They are kept as three
# separate answers rather than one boolean because they fail differently — a
# process with no listener is a crash loop, a listener that never answers is a
# hung server — and an update that reports "unhealthy" without saying which of
# the three broke is not much better than no check at all.
# ---------------------------------------------------------------------------
fcc_find_server_exe() {
	# fcc_find_server_exe -> absolute path of fcc-server, or empty.
	# Ordered most-specific first: the runtime we manage, then a PATH lookup.
	for _fx_c in "$(fcc_dir_bin)/fcc-server" \
	             "$(fcc_dir_runtime)/bin/fcc-server" \
	             "$(fcc_dir_runtime)/venv/bin/fcc-server" \
	             "$(fcc_root)/venv/bin/fcc-server"; do
		[ -x "$_fx_c" ] && { printf '%s' "$_fx_c"; return 0; }
	done
	_fx_c="$(command -v fcc-server 2>/dev/null)"
	[ -n "$_fx_c" ] && { printf '%s' "$_fx_c"; return 0; }
	return 1
}

fcc_server_pid() {
	# fcc_server_pid -> PID of the FCC server, or empty.
	#
	# procd is authoritative when it can answer, because it knows which process
	# it supervises. The /proc scan is the fallback for a server started outside
	# the init script (a manual run, or a runtime from before this package).
	_sp_pid=""
	if command -v ubus >/dev/null 2>&1; then
		_sp_pid="$(ubus call service list '{"name":"fcc"}' 2>/dev/null \
			| sed -n 's/.*"pid":[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -n1)"
		if [ -n "$_sp_pid" ] && [ ! -d "/proc/$_sp_pid" ]; then _sp_pid=""; fi
	fi
	if [ -z "$_sp_pid" ]; then
		_sp_exe="$(fcc_find_server_exe 2>/dev/null || true)"
		[ -n "$_sp_exe" ] || return 1
		# The pattern is a path we resolved ourselves, never user input, so it
		# cannot be read as an option or a regex metacharacter.
		_sp_pid="$(grep -la -- "$_sp_exe" /proc/[0-9]*/cmdline 2>/dev/null \
			| sed -e 's#^/proc/##' -e 's#/cmdline$##' | head -n1)"
	fi
	[ -n "$_sp_pid" ] || return 1
	printf '%s' "$_sp_pid"
}

fcc_port_listening() {
	# fcc_port_listening <port> -> 0 when something holds the TCP port in LISTEN.
	#
	# /proc/net/tcp is read directly rather than shelling out to netstat or ss:
	# neither is guaranteed present on OpenWrt, and this is one file read instead
	# of a fork. Field 2 is "ADDR:PORT" with the port in uppercase hex; field 4
	# is the socket state, where 0A is TCP_LISTEN.
	_pl_p="$1"
	case "$_pl_p" in ''|*[!0-9]*) return 1 ;; esac
	_pl_hex="$(printf '%04X' "$_pl_p")"
	for _pl_f in /proc/net/tcp /proc/net/tcp6; do
		[ -r "$_pl_f" ] || continue
		awk -v want="$_pl_hex" '
			NR > 1 {
				n = split($2, a, ":")
				if (toupper(a[n]) == want && $4 == "0A") found = 1
			}
			END { exit !found }
		' "$_pl_f" && return 0
	done
	return 1
}

fcc_http_status() {
	# fcc_http_status <url> [timeout] -> the HTTP status code, or empty when
	# nothing answered. Any code at all proves the server is talking; which
	# codes count as healthy is the caller's decision, not this function's.
	#
	# The timeout is a parameter because the two callers want different things:
	# an update can afford to wait, a status page cannot.
	command -v curl >/dev/null 2>&1 || return 1
	_hs_t="${2:-5}"
	case "$_hs_t" in ''|*[!0-9]*) _hs_t=5 ;; esac
	_hs_code="$(curl --silent --output /dev/null --max-time "$_hs_t" --proto '=http' \
		--write-out '%{http_code}' "$1" 2>/dev/null)"
	case "$_hs_code" in
		''|000|*[!0-9]*) return 1 ;;
	esac
	printf '%s' "$_hs_code"
}

fcc_server_health() {
	# fcc_server_health -> JSON describing reachability.
	#
	# "healthy" is the documented minimum from section 49: the process exists,
	# the port is listening, and the admin endpoint answers. When curl is not
	# installed the HTTP leg cannot be tested at all, so the check degrades to
	# the process+port pair rather than failing the update on a missing tool.
	_sh_pid="$(fcc_server_pid 2>/dev/null || true)"
	_sh_proc=false
	[ -n "$_sh_pid" ] && _sh_proc=true

	_sh_port="$(fcc_uci_get main port 8082)"
	case "$_sh_port" in ''|*[!0-9]*) _sh_port=8082 ;; esac

	_sh_listen=false
	fcc_port_listening "$_sh_port" && _sh_listen=true

	# Probe loopback regardless of the configured bind address: a health check
	# run on the router should not depend on the server also being reachable
	# from the LAN.
	_sh_code="$(fcc_http_status "http://127.0.0.1:$_sh_port/admin" 2>/dev/null || true)"

	_sh_ok=false
	if [ "$_sh_proc" = true ] && [ "$_sh_listen" = true ]; then
		if [ -n "$_sh_code" ]; then
			_sh_ok=true
		elif ! command -v curl >/dev/null 2>&1; then
			_sh_ok=true
		fi
	fi

	printf '{"process": %s, "pid": %s, "port": %s, "listening": %s, "http_status": %s, "healthy": %s}' \
		"$_sh_proc" \
		"$(fcc_json_num_or_null "${_sh_pid:-}")" \
		"$_sh_port" \
		"$_sh_listen" \
		"$(fcc_json_num_or_null "${_sh_code:-}")" \
		"$_sh_ok"
}

# ---------------------------------------------------------------------------
# Preflight measurements (DESIGN_SPEC.md section 23 steps 3-4)
# ---------------------------------------------------------------------------
fcc_disk_free_kb() {
	# fcc_disk_free_kb <path> -> free kB on the filesystem holding <path>.
	# Walks up to the nearest existing ancestor so a not-yet-created install
	# path still reports the space that will hold it.
	_df_p="$1"
	[ -n "$_df_p" ] || _df_p=/
	while [ ! -d "$_df_p" ] && [ "$_df_p" != "/" ]; do
		_df_p="$(dirname "$_df_p")"
	done
	df -k -P "$_df_p" 2>/dev/null | awk 'NR==2 { print $4 }'
}

fcc_active_sessions() {
	# fcc_active_sessions -> count of live fcc-* tmux sessions.
	# An update restarts the server; sessions survive it, but the user should be
	# told they are there (section 23 step 5). Absent tmux means zero, not an
	# error — the console is the only thing that needs it.
	command -v tmux >/dev/null 2>&1 || { printf '0'; return 0; }
	tmux list-panes -a -F '#{session_name}' 2>/dev/null \
		| grep -c '^fcc-[a-z0-9]\{1,16\}-[0-9]\{3\}$' || true
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
fcc_command_path() {
	# fcc_command_path <name> -> absolute path of the executable, or empty.
	command -v "$1" 2>/dev/null
}

fcc_which_fcc_env() {
	# Resolve the FCC launcher directory inside the runtime, if present.
	_we_bin="$(fcc_dir_bin)"
	if [ -d "$_we_bin" ]; then printf '%s' "$_we_bin"; fi
}

fcc_human_bytes() {
	# fcc_human_bytes <bytes> -> e.g. "1.2 GB" (used only for logs)
	awk -v b="$1" 'BEGIN{
		split("B KB MB GB TB",u," "); i=1;
		while (b>=1024 && i<5){b/=1024;i++}
		printf "%.2f %s", b, u[i]
	}'
}
