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
	fcc_agents_each | cut -d'|' -f1 | grep -qx -- "$1"
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
