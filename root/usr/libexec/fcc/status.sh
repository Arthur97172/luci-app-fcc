#!/bin/sh
# luci-app-fcc — batched status collector.
#
# Emits a single JSON document describing LuCI-FCC, the FCC runtime, the FCC
# server, every coding agent, and system memory/storage. This is the ONE place
# the UI polls (DESIGN_SPEC.md section 3.8) so a refresh costs a single process
# rather than one `ps|grep|df` pipeline per agent.
#
# Usage:
#   status.sh                     fast status
#   status.sh --refresh-versions  also (re)detect the FCC/server version
#
# The output is always valid JSON, even when the FCC runtime is absent.
#
# Version policy (DESIGN_SPEC.md section 44/45): the FCC server version is read
# with `fcc-server --version` (documented as safe by upstream). Coding-agent
# versions are NEVER probed by running the launcher — `fcc-claude` & friends are
# *launchers* that would start the agent. Agent versions come from the runtime
# metadata written at install time, or show as null.
#
# Locals are per-function prefixed — see the note at the top of common.sh.

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

REFRESH_VERSIONS=0
[ "${1:-}" = "--refresh-versions" ] && REFRESH_VERSIONS=1

ROOT="$(fcc_root)"

# ---------------------------------------------------------------------------
# /proc helpers
# ---------------------------------------------------------------------------
# Build a "comm pid" map for every process, in one pass with builtin reads.
build_comm_map() {
	for _bc_d in /proc/[0-9]*; do
		[ -r "$_bc_d/comm" ] || continue
		IFS= read -r _bc_c < "$_bc_d/comm" 2>/dev/null || continue
		printf '%s %s\n' "$_bc_c" "${_bc_d#/proc/}"
	done
}

# ---------------------------------------------------------------------------
# Locate the FCC runtime and its process
#
# Both live in common.sh: the update path needs the same two answers for its
# health check, and two copies of "where is fcc-server / which PID is it" would
# eventually disagree about a box that has more than one FCC install.
# ---------------------------------------------------------------------------
FCC_SERVER_EXE="$(fcc_find_server_exe 2>/dev/null || true)"
fcc_installed=false
[ -n "$FCC_SERVER_EXE" ] && fcc_installed=true

server_pid="$(fcc_server_pid 2>/dev/null || true)"
server_running=false
server_uptime=""
server_rss=""
if [ -n "$server_pid" ] && fcc_proc_alive "$server_pid"; then
	server_running=true
	server_uptime="$(fcc_proc_uptime_secs "$server_pid")"
	server_rss="$(fcc_proc_rss_kb "$server_pid")"
fi

# ---------------------------------------------------------------------------
# Reachability (DESIGN_SPEC.md section 49)
#
# The same three signals an update is judged on, reported live so the page can
# show them without waiting for an update to fail. The HTTP probe only runs
# when something is actually listening: with nothing there the connection is
# refused instantly anyway, and with a hung server it would otherwise add its
# full timeout to every status refresh.
# ---------------------------------------------------------------------------
server_port="$(fcc_uci_get main port 8082)"
case "$server_port" in ''|*[!0-9]*) server_port=8082 ;; esac

server_listening=false
fcc_port_listening "$server_port" && server_listening=true

server_http=""
if [ "$server_listening" = true ]; then
	server_http="$(fcc_http_status "http://127.0.0.1:$server_port/admin" 2 2>/dev/null || true)"
fi

server_healthy=false
if [ "$server_running" = true ] && [ "$server_listening" = true ]; then
	# Without curl the HTTP leg cannot be tested at all, so the documented
	# minimum (process + port) stands rather than failing on a missing tool.
	if [ -n "$server_http" ] || ! command -v curl >/dev/null 2>&1; then
		server_healthy=true
	fi
fi

# ---------------------------------------------------------------------------
# Versions (bounded, cached)
# ---------------------------------------------------------------------------
fcc_version="$(fcc_cache_get fcc_version 2>/dev/null || true)"
if [ "$REFRESH_VERSIONS" -eq 1 ] || ! fcc_cache_fresh; then
	if [ "$fcc_installed" = true ]; then
		if _vv="$(fcc_detect_version "$FCC_SERVER_EXE" --version 2>/dev/null)"; then
			fcc_version="$_vv"
			fcc_cache_set fcc_version "$_vv"
		fi
	fi
	# Mark the cache fresh even if detection failed, so we do not retry-storm.
	fcc_cache_set refreshed_at "$(date +%s)"
fi

server_version="${fcc_version:-}"   # same executable reports both

# ---------------------------------------------------------------------------
# System memory / storage / arch
# ---------------------------------------------------------------------------
mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
[ -n "$mem_avail" ] || mem_avail="$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)"

storage_path="$ROOT"
[ -d "$storage_path" ] || storage_path="$(dirname "$ROOT")"
[ -d "$storage_path" ] || storage_path="/"
_df="$(df -P -k "$storage_path" 2>/dev/null | awk 'NR==2{print $2" "$3" "$4}')"
st_total_k="$(printf '%s' "$_df" | cut -d' ' -f1)"
st_used_k="$(printf '%s' "$_df" | cut -d' ' -f2)"
st_free_k="$(printf '%s' "$_df" | cut -d' ' -f3)"
case "$st_total_k" in ''|*[!0-9]*) st_total_k=0 ;; esac
case "$st_used_k"  in ''|*[!0-9]*) st_used_k=0  ;; esac
case "$st_free_k"  in ''|*[!0-9]*) st_free_k=0  ;; esac
st_total_b=$(( st_total_k * 1024 ))
st_free_b=$(( st_free_k * 1024 ))
st_used_b=$(( st_used_k * 1024 ))

arch="$(uname -m 2>/dev/null)"

# Build the process maps ONCE (no per-agent forks).
TMUX_MAP=""
command -v tmux >/dev/null 2>&1 && \
	TMUX_MAP="$(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null)"
COMM_MAP="$(build_comm_map)"

# ---------------------------------------------------------------------------
# Emit JSON
# ---------------------------------------------------------------------------
{
	printf '{\n'
	printf '  "luci_fcc": {"version": %s},\n' "$(fcc_json_str "$(fcc_luci_version)")"
	printf '  "fcc": {"installed": %s, "version": %s},\n' \
		"$fcc_installed" "$(fcc_json_str_or_null "${fcc_version:-}")"
	printf '  "server": {"running": %s, "pid": %s, "version": %s, "uptime": %s, "memory_rss_kb": %s, "port": %s, "bind": %s, "listening": %s, "http_status": %s, "healthy": %s},\n' \
		"$server_running" \
		"$(fcc_json_num_or_null "$server_pid")" \
		"$(fcc_json_str_or_null "${server_version:-}")" \
		"$(fcc_json_num_or_null "$server_uptime")" \
		"$(fcc_json_num_or_null "$server_rss")" \
		"$server_port" \
		"$(fcc_json_str "$(fcc_uci_get main bind 127.0.0.1)")" \
		"$server_listening" \
		"$(fcc_json_num_or_null "${server_http:-}")" \
		"$server_healthy"
	printf '  "system": {"memory_total_kb": %s, "memory_available_kb": %s, "storage_total_bytes": %s, "storage_free_bytes": %s, "storage_used_bytes": %s, "storage_path": %s, "arch": %s},\n' \
		"$(fcc_json_num_or_null "$mem_total")" \
		"$(fcc_json_num_or_null "$mem_avail")" \
		"$st_total_b" "$st_free_b" "$st_used_b" \
		"$(fcc_json_str "$storage_path")" \
		"$(fcc_json_str "$arch")"

	printf '  "agents": {'
	_ag_first=1
	while IFS='|' read -r aid aname acmd adef asize aram aprobe; do
		case "$aid" in ''|\#*) continue ;; esac
		[ -n "$aid" ] || continue

		ag_installed=false
		command -v "$acmd" >/dev/null 2>&1 && ag_installed=true

		ag_pid=""
		if [ -n "$TMUX_MAP" ]; then
			ag_pid="$(printf '%s\n' "$TMUX_MAP" | awk -v p="fcc-$aid-" 'index($1,p)==1{print $2; exit}')"
		fi
		if [ -z "$ag_pid" ]; then
			ag_pid="$(printf '%s\n' "$COMM_MAP" | awk -v c="$acmd" '$1==c{print $2; exit}')"
		fi
		ag_running=false
		if [ -n "$ag_pid" ] && fcc_proc_alive "$ag_pid"; then
			ag_running=true
		else
			ag_pid=""
		fi

		ag_rss=""; ag_up=""
		if [ -n "$ag_pid" ]; then
			ag_rss="$(fcc_proc_rss_kb "$ag_pid")"
			ag_up="$(fcc_proc_uptime_secs "$ag_pid")"
		fi
		ag_ver="$(fcc_cache_get "agent_$aid" 2>/dev/null || true)"

		[ "$_ag_first" -eq 1 ] || printf ','
		_ag_first=0
		printf '\n    %s: {"name": %s, "command": %s, "installed": %s, "running": %s, "pid": %s, "uptime": %s, "memory_rss_kb": %s, "version": %s, "default": %s, "approx_size_mb": %s, "min_ram_mb": %s}' \
			"$(fcc_json_str "$aid")" \
			"$(fcc_json_str "$aname")" \
			"$(fcc_json_str "$acmd")" \
			"$ag_installed" "$ag_running" \
			"$(fcc_json_num_or_null "$ag_pid")" \
			"$(fcc_json_num_or_null "$ag_up")" \
			"$(fcc_json_num_or_null "$ag_rss")" \
			"$(fcc_json_str_or_null "${ag_ver:-}")" \
			"$(fcc_json_bool "$adef")" \
			"$(fcc_json_num_or_null "$asize")" \
			"$(fcc_json_num_or_null "$aram")"
	done <<-EOF
	$(fcc_agents_each)
	EOF
	printf '\n  }\n'
	printf '}\n'
}
