#!/bin/sh
# luci-app-fcc — coding-agent operations.
#
# Usage:
#   agent.sh list                    JSON map of every agent + state
#   agent.sh status <id>             JSON object for one agent
#   agent.sh version <id>            JSON object incl. detected version
#   agent.sh versions [--refresh]    (re)detect versions into the cache
#   agent.sh install <id>            add an agent to the runtime
#   agent.sh remove  <id>            remove an agent from the runtime
#
# Version detection never invokes an fcc-* launcher (they would START the
# agent). It probes the safe underlying CLI recorded in the registry, falling
# back to the runtime metadata written at install time.
#
# Locals are per-function prefixed — see the note at the top of common.sh.

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

ROOT="$(fcc_root)"

agent_installed() {
	_ai_cmd="$(fcc_agent_command "$1")" || return 1
	[ -n "$_ai_cmd" ] || return 1
	command -v "$_ai_cmd" >/dev/null 2>&1
}

agent_running() {
	_ar_cmd="$(fcc_agent_command "$1")" || return 1
	[ -n "$_ar_cmd" ] || return 1
	command -v tmux >/dev/null 2>&1 || return 1
	tmux list-panes -a -F '#{session_name}' 2>/dev/null | grep -q "^fcc-$1-[0-9][0-9][0-9]$"
}

# The pid of the first live session belonging to an agent, or empty.
agent_session_pid() {
	command -v tmux >/dev/null 2>&1 || return 1
	tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null \
		| awk -v p="fcc-$1-" 'index($1,p)==1{print $2; exit}'
}

# Detect a single agent's version. Prints the version or nothing.
detect_agent_version() {
	_dav_id="$1"
	_dav_probe="$(fcc_agent_probe "$_dav_id" 2>/dev/null || true)"
	if [ -n "$_dav_probe" ]; then
		_dav_v="$(fcc_detect_version "$_dav_probe" --version 2>/dev/null || true)"
		if [ -n "$_dav_v" ]; then printf '%s' "$_dav_v"; return 0; fi
	fi
	# Fall back to the runtime metadata recorded at install time.
	if [ -r "$ROOT/runtime.json" ]; then
		_dav_v="$(sed -n "s/.*\"agent_version_$_dav_id\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
			"$ROOT/runtime.json" | head -n1)"
		[ -n "$_dav_v" ] && { printf '%s' "$_dav_v"; return 0; }
	fi
	return 1
}

emit_agent_json() {
	# emit_agent_json <id>
	_ea_id="$1"
	_ea_name="$(fcc_agent_name "$_ea_id")"
	_ea_cmd="$(fcc_agent_command "$_ea_id")"
	_ea_inst=false; agent_installed "$_ea_id" && _ea_inst=true
	_ea_run=false;  agent_running  "$_ea_id" && _ea_run=true
	_ea_pid=""
	if [ "$_ea_run" = true ]; then
		_ea_pid="$(agent_session_pid "$_ea_id")"
	fi
	_ea_rss=""; _ea_up=""
	if [ -n "$_ea_pid" ]; then
		_ea_rss="$(fcc_proc_rss_kb "$_ea_pid")"
		_ea_up="$(fcc_proc_uptime_secs "$_ea_pid")"
	fi
	_ea_ver="$(fcc_cache_get "agent_$_ea_id" 2>/dev/null || true)"

	printf '{"id": %s, "name": %s, "command": %s, "installed": %s, "running": %s, "pid": %s, "uptime": %s, "memory_rss_kb": %s, "version": %s}' \
		"$(fcc_json_str "$_ea_id")" "$(fcc_json_str "$_ea_name")" "$(fcc_json_str "$_ea_cmd")" \
		"$_ea_inst" "$_ea_run" \
		"$(fcc_json_num_or_null "$_ea_pid")" "$(fcc_json_num_or_null "$_ea_up")" \
		"$(fcc_json_num_or_null "$_ea_rss")" "$(fcc_json_str_or_null "${_ea_ver:-}")"
}

cmd_list() {
	printf '{'
	_cl_first=1
	while IFS='|' read -r _cl_aid _cl_rest; do
		case "$_cl_aid" in ''|\#*) continue ;; esac
		[ -n "$_cl_aid" ] || continue
		[ "$_cl_first" -eq 1 ] || printf ','
		_cl_first=0
		printf '\n  %s: %s' "$(fcc_json_str "$_cl_aid")" "$(emit_agent_json "$_cl_aid")"
	done <<-EOF
	$(fcc_agents_each)
	EOF
	printf '\n}\n'
}

cmd_versions() {
	_cv_refresh=0
	[ "${1:-}" = "--refresh" ] && _cv_refresh=1
	while IFS='|' read -r _cv_aid _cv_rest; do
		case "$_cv_aid" in ''|\#*) continue ;; esac
		[ -n "$_cv_aid" ] || continue
		agent_installed "$_cv_aid" || continue
		if [ "$_cv_refresh" -eq 1 ]; then
			_cv_v="$(detect_agent_version "$_cv_aid" || true)"
			[ -n "$_cv_v" ] && fcc_cache_set "agent_$_cv_aid" "$_cv_v"
		fi
	done <<-EOF
	$(fcc_agents_each)
	EOF
	cmd_list
}

# Build the space-separated set of currently installed agents.
installed_set() {
	_is_out=""
	while IFS='|' read -r _is_aid _is_rest; do
		case "$_is_aid" in ''|\#*) continue ;; esac
		agent_installed "$_is_aid" && _is_out="$_is_out $_is_aid"
	done <<-EOF
	$(fcc_agents_each)
	EOF
	printf '%s' "$_is_out"
}

cmd_install() {
	_ci_id="$1"
	fcc_valid_agent "$_ci_id" || { fcc_die "unknown agent: $_ci_id"; return 2; }
	_ci_set="$(installed_set) $_ci_id"
	# De-duplicate.
	_ci_set="$(printf '%s' "$_ci_set" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ',' | sed 's/,$//')"
	fcc_log "fcc-runtime.log" "agent install requested: $_ci_id (target set: $_ci_set)"
	"${FCC_LIBDIR:-/usr/libexec/fcc}/install.sh" runtime --agents "$_ci_set"
}

cmd_remove() {
	_cr_id="$1"
	fcc_valid_agent "$_cr_id" || { fcc_die "unknown agent: $_cr_id"; return 2; }
	# Refuse while a session is live.
	if agent_running "$_cr_id"; then
		fcc_die "agent $_cr_id has a running session; close it first"
		return 1
	fi
	_cr_set="$(installed_set | tr ' ' '\n' | grep -vx "$_cr_id" | tr '\n' ',' | sed 's/,$//')"
	fcc_log "fcc-runtime.log" "agent remove requested: $_cr_id (target set: ${_cr_set:-<none>})"
	"${FCC_LIBDIR:-/usr/libexec/fcc}/install.sh" runtime --agents "$_cr_set"
}

case "${1:-}" in
	list)     cmd_list ;;
	status)   _id="${2:-}"; fcc_valid_agent "$_id" || { echo '{"error":"invalid agent"}'; exit 2; }; emit_agent_json "$_id"; echo ;;
	version)  _id="${2:-}"; fcc_valid_agent "$_id" || { echo '{"error":"invalid agent"}'; exit 2; }; emit_agent_json "$_id"; echo ;;
	versions) shift; cmd_versions "$@" ;;
	install)  cmd_install "${2:-}" ;;
	remove)   cmd_remove  "${2:-}" ;;
	*) echo "usage: agent.sh {list|status <id>|version <id>|versions [--refresh]|install <id>|remove <id>}" >&2; exit 2 ;;
esac
