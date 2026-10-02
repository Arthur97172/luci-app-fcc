#!/bin/sh
# luci-app-fcc — Web Console session manager (tmux backed).
#
# DESIGN_SPEC.md sections 7/8: sessions are persistent, detachable and survive a
# browser refresh. tmux is the PTY host, so the terminal is a REAL interactive
# terminal (ANSI, colours, cursor movement, control keys, resize) without
# introducing a Node.js/Python WebSocket server (which section 87 forbids).
#
# Transport is a byte stream with an absolute offset:
#   * pane output is tee'd to <root>/sessions/<name>.out via `tmux pipe-pane`
#   * `output <name> <abs-offset>` returns the bytes after that offset
#   * `input <name> <hex>` writes raw bytes into the pane
#   * `resize`, `capture`, `close`, `cleanup`
#
# Every local variable is prefixed with its function's tag: POSIX sh functions
# share one global scope, so a bare `_name` here would collide with the `_name`
# a helper like fcc_log uses (see the note at the top of common.sh).
#
# Usage:
#   session.sh list
#   session.sh create <agent> [cols] [rows]
#   session.sh output <name> [abs-offset] [wait-seconds]
#   session.sh input  <name> <hex-bytes>
#   session.sh resize <name> <cols> <rows>
#   session.sh capture <name>
#   session.sh close  <name>
#   session.sh cleanup

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

ROOT="$(fcc_root)"
SESSDIR="$(fcc_dir_sessions)"
# Fall back to /tmp when the runtime path is not writable yet (runtime not
# installed) so the console degrades gracefully instead of erroring.
if ! mkdir -p "$SESSDIR" 2>/dev/null || [ ! -w "$SESSDIR" ]; then
	SESSDIR="/tmp/fcc-sessions"
	mkdir -p "$SESSDIR" 2>/dev/null
fi

MAX_OUT_BYTES="${FCC_MAX_OUT_BYTES:-4194304}"   # 4 MB per session scrollback file
TRIM_TO_BYTES="${FCC_TRIM_TO_BYTES:-1048576}"   # keep the newest 1 MB when trimming

require_tmux() {
	command -v tmux >/dev/null 2>&1 || { fcc_die "tmux is required for the Web Console"; return 1; }
}

out_file()  { printf '%s/%s.out'  "$SESSDIR" "$1"; }
base_file() { printf '%s/%s.base' "$SESSDIR" "$1"; }

session_exists() {
	tmux has-session -t "$1" 2>/dev/null
}

# Environment shared by every agent session so it matches the install layout.
session_env_exports() {
	printf 'export HOME=%s/data TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8;' "$ROOT"
	printf 'export PATH=%s/bin:$PATH;' "$ROOT"
	printf 'export UV_TOOL_BIN_DIR=%s/bin UV_TOOL_DIR=%s/runtime/uv-tools UV_CACHE_DIR=%s/cache/uv;' \
		"$ROOT" "$ROOT" "$ROOT"
}

next_session_name() {
	# next_session_name <agent> -> fcc-<agent>-NNN (lowest free 001..999)
	_nsn_agent="$1"
	_nsn_i=1
	while [ "$_nsn_i" -le 999 ]; do
		_nsn_n="$(printf 'fcc-%s-%03d' "$_nsn_agent" "$_nsn_i")"
		if ! session_exists "$_nsn_n"; then printf '%s' "$_nsn_n"; return 0; fi
		_nsn_i=$((_nsn_i + 1))
	done
	return 1
}

cmd_create() {
	require_tmux || return 1
	_cr_agent="${1:-}"
	_cr_cols="${2:-80}"; _cr_rows="${3:-24}"
	fcc_valid_agent "$_cr_agent" || { fcc_die "invalid agent"; return 2; }
	case "$_cr_cols" in *[!0-9]*|'') _cr_cols=80 ;; esac
	case "$_cr_rows" in *[!0-9]*|'') _cr_rows=24 ;; esac
	{ [ "$_cr_cols" -ge 20 ] && [ "$_cr_cols" -le 500 ]; } || _cr_cols=80
	{ [ "$_cr_rows" -ge 5 ]  && [ "$_cr_rows" -le 300 ]; } || _cr_rows=24

	_cr_launcher="$(fcc_agent_command "$_cr_agent")"
	command -v "$_cr_launcher" >/dev/null 2>&1 || {
		fcc_die "agent '$_cr_agent' is not installed (launcher '$_cr_launcher' not found)"; return 1; }

	_cr_name="$(next_session_name "$_cr_agent")" || { fcc_die "no free session slot"; return 1; }

	# The launcher itself connects to the FCC server. $_cr_launcher and $ROOT are
	# both validated values, never user input, so the command string cannot be
	# injected into.
	_cr_cmd="$(session_env_exports) exec $_cr_launcher"
	if ! tmux new-session -d -s "$_cr_name" -x "$_cr_cols" -y "$_cr_rows" "$_cr_cmd" 2>/dev/null; then
		fcc_die "failed to create tmux session"; return 1
	fi

	# Start capturing pane output from the very beginning.
	: > "$(out_file "$_cr_name")"
	printf '0' > "$(base_file "$_cr_name")"
	tmux pipe-pane -t "$_cr_name" -o "cat >> '$(out_file "$_cr_name")'" 2>/dev/null

	fcc_log "fcc-terminal.log" "session created: $_cr_name (agent=$_cr_agent ${_cr_cols}x${_cr_rows})"
	printf '{"name": %s, "agent": %s, "launcher": %s, "cols": %s, "rows": %s}\n' \
		"$(fcc_json_str "$_cr_name")" "$(fcc_json_str "$_cr_agent")" \
		"$(fcc_json_str "$_cr_launcher")" "$_cr_cols" "$_cr_rows"
}

cmd_list() {
	require_tmux || { printf '[]\n'; return 0; }
	_ls_raw="$(tmux list-panes -a -F '#{session_name}|#{pane_pid}|#{session_created}' 2>/dev/null)"
	printf '['
	_ls_first=1
	printf '%s\n' "$_ls_raw" | while IFS='|' read -r _ls_sname _ls_spid _ls_screated; do
		case "$_ls_sname" in fcc-*-[0-9][0-9][0-9]) : ;; *) continue ;; esac
		fcc_valid_session "$_ls_sname" || continue
		_ls_agent="$(printf '%s' "$_ls_sname" | sed -n 's/^fcc-\([a-z0-9]\{1,16\}\)-[0-9]\{3\}$/\1/p')"
		_ls_up=""; _ls_rss=""
		if [ -n "$_ls_spid" ] && fcc_proc_alive "$_ls_spid"; then
			_ls_up="$(fcc_proc_uptime_secs "$_ls_spid")"
			_ls_rss="$(fcc_proc_rss_kb "$_ls_spid")"
		fi
		[ "$_ls_first" -eq 1 ] || printf ','
		_ls_first=0
		printf '\n  {"name": %s, "agent": %s, "display_name": %s, "pid": %s, "created": %s, "uptime": %s, "memory_rss_kb": %s}' \
			"$(fcc_json_str "$_ls_sname")" "$(fcc_json_str "$_ls_agent")" \
			"$(fcc_json_str "$(fcc_agent_name "$_ls_agent")")" \
			"$(fcc_json_num_or_null "$_ls_spid")" \
			"$(fcc_json_num_or_null "$_ls_screated")" \
			"$(fcc_json_num_or_null "$_ls_up")" \
			"$(fcc_json_num_or_null "$_ls_rss")"
	done
	printf '\n]\n'
}

# Trim the scrollback file when it grows too large, advancing the base offset so
# absolute offsets stay meaningful for connected clients.
maybe_trim() {
	_mt_name="$1"
	_mt_f="$(out_file "$_mt_name")"; _mt_b="$(base_file "$_mt_name")"
	[ -r "$_mt_f" ] || return 0
	_mt_sz="$(wc -c < "$_mt_f" 2>/dev/null | tr -d ' ')"
	case "$_mt_sz" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_mt_sz" -le "$MAX_OUT_BYTES" ] && return 0
	_mt_base="$(cat "$_mt_b" 2>/dev/null || echo 0)"
	case "$_mt_base" in ''|*[!0-9]*) _mt_base=0 ;; esac
	_mt_drop=$(( _mt_sz - TRIM_TO_BYTES ))
	tail -c "$TRIM_TO_BYTES" "$_mt_f" > "$_mt_f.tmp" 2>/dev/null && mv "$_mt_f.tmp" "$_mt_f"
	printf '%s' "$(( _mt_base + _mt_drop ))" > "$_mt_b"
}

cmd_output() {
	# session.sh output <name> [abs-offset] [wait-seconds]
	require_tmux || return 1
	_ou_name="${1:-}"; _ou_off="${2:-0}"; _ou_wait="${3:-0}"
	fcc_valid_session "$_ou_name" || { fcc_die "invalid session"; return 2; }
	case "$_ou_off"  in *[!0-9]*|'') _ou_off=0 ;; esac
	case "$_ou_wait" in *[!0-9]*|'') _ou_wait=0 ;; esac
	[ "$_ou_wait" -le 25 ] || _ou_wait=25

	maybe_trim "$_ou_name"

	_ou_f="$(out_file "$_ou_name")"; _ou_b="$(base_file "$_ou_name")"
	[ -r "$_ou_f" ] || : > "$_ou_f"
	[ -r "$_ou_b" ] || printf '0' > "$_ou_b"

	_ou_waited=0
	while :; do
		_ou_base="$(cat "$_ou_b" 2>/dev/null || echo 0)"
		case "$_ou_base" in ''|*[!0-9]*) _ou_base=0 ;; esac
		_ou_sz="$(wc -c < "$_ou_f" 2>/dev/null | tr -d ' ')"
		case "$_ou_sz" in ''|*[!0-9]*) _ou_sz=0 ;; esac
		_ou_abs=$(( _ou_base + _ou_sz ))
		if [ "$_ou_abs" -gt "$_ou_off" ] || [ "$_ou_waited" -ge "$_ou_wait" ] || ! session_exists "$_ou_name"; then
			break
		fi
		sleep 1
		_ou_waited=$(( _ou_waited + 1 ))
	done

	_ou_reset=false
	if [ "$_ou_off" -lt "$_ou_base" ]; then _ou_reset=true; _ou_off="$_ou_base"; fi
	_ou_skip=$(( _ou_off - _ou_base ))
	_ou_alive=true; session_exists "$_ou_name" || _ou_alive=false
	_ou_eof=false; [ "$_ou_alive" = false ] && _ou_eof=true

	# Header line (JSON), then the raw bytes.
	printf '{"name": %s, "offset": %s, "reset": %s, "alive": %s, "eof": %s}\n' \
		"$(fcc_json_str "$_ou_name")" "$_ou_abs" "$_ou_reset" "$_ou_alive" "$_ou_eof"
	if [ "$_ou_abs" -gt "$_ou_off" ]; then
		tail -c "+$(( _ou_skip + 1 ))" "$_ou_f" 2>/dev/null
	fi
}

cmd_input() {
	# session.sh input <name> <hex-bytes>
	require_tmux || return 1
	_in_name="${1:-}"; shift 2>/dev/null || true   # drop just the session name
	# Accept the bytes either as one hex string ("68690a") or as separate argv
	# words ("68 69 0a"); both are joined back into one space-separated list.
	_in_hex="$*"
	fcc_valid_session "$_in_name" || { fcc_die "invalid session"; return 2; }
	session_exists "$_in_name" || { fcc_die "session not found"; return 1; }
	# Only hex digits and spaces are accepted.
	case "$_in_hex" in *[!0-9a-fA-F\ ]*) fcc_die "invalid input encoding"; return 2 ;; esac
	[ -n "$_in_hex" ] || return 0
	# send-keys -H takes one hex byte per argument.
	# shellcheck disable=SC2086
	tmux send-keys -t "$_in_name" -H $_in_hex 2>/dev/null
}

cmd_resize() {
	require_tmux || return 1
	_rs_name="${1:-}"; _rs_cols="${2:-80}"; _rs_rows="${3:-24}"
	fcc_valid_session "$_rs_name" || { fcc_die "invalid session"; return 2; }
	case "$_rs_cols" in *[!0-9]*|'') return 2 ;; esac
	case "$_rs_rows" in *[!0-9]*|'') return 2 ;; esac
	{ [ "$_rs_cols" -ge 20 ] && [ "$_rs_cols" -le 500 ]; } || return 2
	{ [ "$_rs_rows" -ge 5 ]  && [ "$_rs_rows" -le 300 ]; } || return 2
	session_exists "$_rs_name" || return 1
	tmux resize-window -t "$_rs_name" -x "$_rs_cols" -y "$_rs_rows" 2>/dev/null \
		|| tmux resize-pane -t "$_rs_name" -x "$_rs_cols" -y "$_rs_rows" 2>/dev/null
}

cmd_capture() {
	require_tmux || return 1
	_cp_name="${1:-}"
	fcc_valid_session "$_cp_name" || { fcc_die "invalid session"; return 2; }
	session_exists "$_cp_name" || return 1
	# Current visible screen WITH escape sequences, so a reconnecting client can
	# repaint faithfully.
	tmux capture-pane -p -e -t "$_cp_name" 2>/dev/null
}

cmd_close() {
	require_tmux || return 1
	_cl_name="${1:-}"
	fcc_valid_session "$_cl_name" || { fcc_die "invalid session"; return 2; }
	# Never touch anything outside the fcc-* namespace.
	tmux kill-session -t "$_cl_name" 2>/dev/null
	rm -f "$(out_file "$_cl_name")" "$(base_file "$_cl_name")"
	fcc_log "fcc-terminal.log" "session closed: $_cl_name"
}

cmd_cleanup() {
	require_tmux || return 1
	# Remove dead sessions (the pane's process has exited) and stale files.
	_cu_dead="$(tmux list-panes -a -F '#{session_name} #{pane_dead}' 2>/dev/null \
		| awk '$1 ~ /^fcc-/ && $2==1 {print $1}')"
	for _cu_s in $_cu_dead; do
		fcc_valid_session "$_cu_s" || continue
		tmux kill-session -t "$_cu_s" 2>/dev/null
		rm -f "$(out_file "$_cu_s")" "$(base_file "$_cu_s")"
	done
	# Remove orphaned capture files whose session no longer exists.
	for _cu_f in "$SESSDIR"/fcc-*.out; do
		[ -e "$_cu_f" ] || continue
		_cu_s="$(basename "$_cu_f" .out)"
		fcc_valid_session "$_cu_s" || { rm -f "$_cu_f"; continue; }
		session_exists "$_cu_s" || rm -f "$_cu_f" "$(base_file "$_cu_s")"
	done
}

case "${1:-}" in
	list)    cmd_list ;;
	create)  shift; cmd_create "$@" ;;
	output)  shift; cmd_output "$@" ;;
	input)   shift; cmd_input "$@" ;;
	resize)  shift; cmd_resize "$@" ;;
	capture) shift; cmd_capture "$@" ;;
	close)   shift; cmd_close "$@" ;;
	cleanup) cmd_cleanup ;;
	*) echo "usage: session.sh {list|create|output|input|resize|capture|close|cleanup}" >&2; exit 2 ;;
esac
