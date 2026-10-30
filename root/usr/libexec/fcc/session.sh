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
#   session.sh close-all
#   session.sh close-later <name> [grace-seconds]
#   session.sh reap
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
# Which machine the session's agent runs on: `local`, or `lan` for a pane that
# is an ssh client to the machine the Configuration tab points at. Written once
# when the session is created, because the target can change afterwards while
# the session keeps running where it started — the tab badge has to describe
# the session, not the page's current setting.
target_file() { printf '%s/%s.target' "$SESSDIR" "$1"; }
# A pending close armed by the standalone browser window, and the counter that
# tells a closed window apart from a reloaded one. See cmd_close_later().
closing_file() { printf '%s/%s.closing' "$SESSDIR" "$1"; }
gen_file()     { printf '%s/%s.gen'     "$SESSDIR" "$1"; }

session_exists() {
	tmux has-session -t "$1" 2>/dev/null
}

# A session whose pane process has exited. Sessions are created with
# remain-on-exit on, so tmux keeps the dead pane instead of destroying the
# session outright: that is the only way to answer section 74's "Exit code: N"
# after the agent has already gone. cmd_cleanup() is what eventually reaps them.
session_dead() {
	[ "$(tmux display-message -p -t "$1" '#{pane_dead}' 2>/dev/null)" = "1" ]
}

# The dead pane's exit status, or nothing when tmux cannot report one (an older
# tmux without pane_dead_status, or a session that is still alive). Reporting no
# code is better than reporting a wrong one.
session_exit_code() {
	_sxc_v="$(tmux display-message -p -t "$1" '#{pane_dead_status}' 2>/dev/null)"
	case "$_sxc_v" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s' "$_sxc_v"
}

# True while the pane's process is still running: the session exists and the
# pane is not dead.
session_live() {
	session_exists "$1" || return 1
	session_dead "$1" && return 1
	return 0
}

# Environment shared by every agent session so it matches the install layout.
#
# This is the runtime environment, and there is exactly one definition of it —
# fcc_runtime_env_exports() in common.sh, the same one install.sh hands to the
# installer's terminal. It used to be hand-written here, and the hand-written
# copy was wrong in two ways at once:
#
#   * PATH held only <root>/bin. That is where the fcc-* launchers live and
#     nowhere else — the CLI each launcher execs is installed under
#     <root>/data — and upstream resolves that CLI with a bare PATH lookup. So
#     every session started its launcher successfully and then died on
#     "Could not find Claude Code command: claude", exit code 127 (§104.21).
#   * HOME, UV_TOOL_DIR and UV_CACHE_DIR were set but UV_INSTALL_DIR,
#     UV_PYTHON_INSTALL_DIR and the four XDG_* variables were not, so a pane
#     that ran `uv` or the installer disagreed with the process that created
#     the runtime about where everything goes.
#
# Both are the same mistake — a second copy of a list that already had an
# owner — so the fix is to stop having a copy.
#
# The locale and TERM are not part of that environment and stay here: they are
# about the terminal rather than about where the runtime keeps its files, and
# the agent CLIs draw box-drawing and CJK glyphs that a C locale renders as
# question marks.
session_env_exports() {
	fcc_runtime_env_exports "$ROOT"
	printf 'export TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8\n'
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

	# Which machine the agent runs on is read from UCI here, not taken from the
	# caller. The Configuration tab's switch is the one place that decides it, a
	# page left open on the other side must not create a session on the wrong
	# machine, and the console's own label is a description of this value rather
	# than the value itself.
	_cr_target="$(fcc_uci_get main control_target local)"
	[ "$_cr_target" = "lan" ] || _cr_target=local

	# The address a browser reached this router on, as the controller worked it
	# out (SERVER_ADDR, or the page's own location.hostname). Only DeepSeek
	# Harness serves anything to a browser, so only it asks: dsh's own default is
	# the loopback of the machine it runs on, which the browser driving this
	# panel cannot open — see fcc_pane_bind_host() in common.sh, which checks
	# the candidate against this router's addresses and falls back to the lan
	# address rather than trusting it.
	_cr_bind=""
	if [ "$_cr_agent" = dsh ]; then
		_cr_bind="$(fcc_pane_bind_host "${4:-}" 2>/dev/null || true)"
	fi

	if [ "$_cr_target" = "lan" ]; then
		# The pane is an ssh client to the LAN machine, where fcc-env applies that
		# machine's runtime environment and execs the launcher. Everything the
		# transport does — pipe-pane, the offset, resize, close — is unchanged,
		# and this router never needs the runtime or the agent's CLI itself: the
		# checks below would answer about the wrong machine.
		#
		# remote.sh owns the connection (key, pinned host, fixed options) and
		# refuses with a reason code the page translates. The reason is passed
		# through untouched: the controller relays it as the create's answer.
		_cr_launcher="$(fcc_agent_command "$_cr_agent")"
		_cr_libdir="${FCC_LIBDIR:-/usr/libexec/fcc}"
		# FCC_PANE_HOST is how the bind address reaches remote.sh, which is what
		# turns it into the ssh -L that carries the harness to the browser.
		if _cr_launch="$(FCC_PANE_HOST="$_cr_bind" \
			"$_cr_libdir/remote.sh" session-command "$_cr_agent" 2>/dev/null)"; then
			[ -n "$_cr_launch" ] || {
				printf '{"ok":false,"reason":"no-ssh-command"}\n'; return 1; }
		else
			# remote.sh's own refusal document, relayed as it stands. Not
			# ${_cr_launch:-{...}}: an expansion ends at the first `}`, so the
			# default's brace would be printed as a stray character after a
			# document that was there all along.
			if [ -n "$_cr_launch" ]; then
				printf '%s\n' "$_cr_launch"
			else
				printf '{"ok":false,"reason":"lan-unavailable"}\n'
			fi
			return 1
		fi
		# The terminal's environment, not the runtime's: HOME, the XDG directories
		# and PATH belong to the machine the launcher runs on, and fcc-env applies
		# them there. Only what describes this pty travels over ssh.
		_cr_cmd="export TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8; exec $_cr_launch"
	else
		# Section 3.6.10: a session may only be created once the runtime is in
		# place, an agent is installed, and the server it talks to is up. Enforced
		# here rather than only in the UI because the launcher would otherwise
		# start, fail to reach the server, and leave the user looking at a dead
		# terminal with no explanation.
		#
		# The runtime is asked for first because it is the outer prerequisite:
		# with no runtime there is no launcher and no agent CLI either, so "agent
		# not installed" would name the wrong thing to install.
		if [ -z "$(fcc_find_server_exe 2>/dev/null || true)" ]; then
			fcc_die "the FCC runtime is not installed — install it first"; return 1
		fi

		# "Is this agent installed?" is asked of the agent's own CLI, never of the
		# launcher — see fcc_agent_installed() in common.sh for why the two are
		# not the same question.
		#
		# This used to be a bare `command -v "$_cr_launcher"`, and that is a
		# question about *this process's PATH*, not about the router. The launcher
		# lives in <root>/bin, which reaches only a shell that has applied
		# session_env_exports() below — that is, the agent's own shell inside
		# tmux. The shell rpcd forks to run this script has never applied it, so
		# the probe answered "not installed" for every agent on every router, and
		# no session could be created at all. It was the sixth copy of a question
		# common.sh already answers correctly (§104.17).
		fcc_agent_installed "$_cr_agent" "$ROOT" || {
			fcc_die "agent '$_cr_agent' is not installed — install it in Configuration → Agents"; return 1; }

		# The launcher is what the pane execs, so it is resolved to an absolute
		# path rather than looked up in PATH. _cr_launcher keeps the bare name: it
		# is what the reply reports and what the log records, and the name is the
		# contract.
		_cr_launcher="$(fcc_agent_command "$_cr_agent")"
		_cr_launcher_exe="$(fcc_agent_launcher_path "$_cr_agent")" || {
			fcc_die "the launcher for '$_cr_agent' ('$_cr_launcher') is missing from the runtime"; return 1; }

		if [ -z "$(fcc_server_pid 2>/dev/null || true)" ]; then
			fcc_die "the FCC server is not running — start it first"; return 1
		fi

		# The launcher itself connects to the FCC server. $_cr_launcher_exe and
		# $ROOT are both validated values, never user input, so the command string
		# cannot be injected into.
		#
		# The `;` is load-bearing and belongs here rather than at the end of
		# session_env_exports(). That function renders `export` lines for a shell
		# to read, and `$(...)` eats the newline after the last of them — so
		# without a separator of its own the concatenation below would end
		# `... LC_ALL=C.UTF-8 exec /opt/fcc/bin/fcc-claude`, and `exec` would be
		# one more word for `export`. That is not hypothetical: it is what the pane
		# reported the first time the exports became multi-line.
		# DeepSeek Harness is started on the address the browser reached this
		# router on, not on the loopback it would pick for itself: the pane's
		# address is the one the console's window then opens, and 127.0.0.1
		# answers only a browser running on this router. --no-open keeps the
		# router from trying to launch a desktop browser it does not have. A
		# router with no usable address keeps the bare launcher, which is also
		# what every other agent gets — they are terminals and take no arguments.
		_cr_args=""
		[ -n "$_cr_bind" ] && _cr_args=" web --host $_cr_bind --no-open"
		_cr_cmd="$(session_env_exports); exec $_cr_launcher_exe$_cr_args"
	fi

	_cr_name="$(next_session_name "$_cr_agent")" || { fcc_die "no free session slot"; return 1; }

	# The pane is created holding `cat`, which waits on stdin and prints nothing,
	# and the agent is started afterwards by respawning it. Passing the command to
	# new-session instead would race: an agent that exits at once — a launcher
	# that cannot reach its server, say — takes the session down with it before
	# remain-on-exit can be set, and section 74's exit code is gone. Respawning
	# cannot lose it, because the option is already in place before the command
	# exists. `cat` rather than a shell keeps the placeholder silent, so nothing
	# of it reaches the scrollback.
	if ! tmux new-session -d -s "$_cr_name" -x "$_cr_cols" -y "$_cr_rows" 'cat' 2>/dev/null; then
		fcc_die "failed to create tmux session"; return 1
	fi

	# Keep the pane (and its exit status) after the agent exits, so the console
	# can report section 74's exit code instead of a session that simply vanished.
	# Set on this session only — a global option would change the behaviour of
	# whatever else the user runs in tmux.
	tmux set-option -t "$_cr_name" remain-on-exit on 2>/dev/null

	# Start capturing pane output from the very beginning. Safe to attach before
	# the agent starts: the placeholder has written nothing.
	: > "$(out_file "$_cr_name")"
	printf '0' > "$(base_file "$_cr_name")"
	printf '%s' "$_cr_target" > "$(target_file "$_cr_name")"
	tmux pipe-pane -t "$_cr_name" -o "cat >> '$(out_file "$_cr_name")'" 2>/dev/null

	if ! tmux respawn-pane -k -t "$_cr_name" "$_cr_cmd" 2>/dev/null; then
		tmux kill-session -t "$_cr_name" 2>/dev/null
		fcc_die "failed to start the agent in its session"; return 1
	fi

	fcc_log "fcc-terminal.log" "session created: $_cr_name (agent=$_cr_agent target=$_cr_target ${_cr_cols}x${_cr_rows})"
	printf '{"name": %s, "agent": %s, "launcher": %s, "target": %s, "cols": %s, "rows": %s}\n' \
		"$(fcc_json_str "$_cr_name")" "$(fcc_json_str "$_cr_agent")" \
		"$(fcc_json_str "$_cr_launcher")" "$(fcc_json_str "$_cr_target")" \
		"$_cr_cols" "$_cr_rows"
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
		# A dead pane keeps its recorded pid, which may since have been reused by
		# an unrelated process; never measure a process we already know is gone.
		_ls_dead=false; session_dead "$_ls_sname" && _ls_dead=true
		_ls_up=""; _ls_rss=""
		if [ "$_ls_dead" = false ] && [ -n "$_ls_spid" ] && fcc_proc_alive "$_ls_spid"; then
			_ls_up="$(fcc_proc_uptime_secs "$_ls_spid")"
			_ls_rss="$(fcc_proc_rss_kb "$_ls_spid")"
		fi
		_ls_exit=""; [ "$_ls_dead" = true ] && _ls_exit="$(session_exit_code "$_ls_sname" 2>/dev/null || true)"
		# A session made before this sidecar existed has no file, and every one of
		# those was a local session: local is the only answer that cannot be
		# wrong about an unknown session.
		_ls_target="$(cat "$(target_file "$_ls_sname")" 2>/dev/null || true)"
		case "$_ls_target" in lan) : ;; *) _ls_target=local ;; esac
		[ "$_ls_first" -eq 1 ] || printf ','
		_ls_first=0
		printf '\n  {"name": %s, "agent": %s, "display_name": %s, "target": %s, "pid": %s, "created": %s, "uptime": %s, "memory_rss_kb": %s, "dead": %s, "exit_code": %s}' \
			"$(fcc_json_str "$_ls_sname")" "$(fcc_json_str "$_ls_agent")" \
			"$(fcc_json_str "$(fcc_agent_name "$_ls_agent")")" \
			"$(fcc_json_str "$_ls_target")" \
			"$(fcc_json_num_or_null "$_ls_spid")" \
			"$(fcc_json_num_or_null "$_ls_screated")" \
			"$(fcc_json_num_or_null "$_ls_up")" \
			"$(fcc_json_num_or_null "$_ls_rss")" \
			"$_ls_dead" \
			"$(fcc_json_num_or_null "${_ls_exit:-}")"
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

	# How often the wait looks for new bytes, in tenths of a second. The
	# browser learns that the pane wrote something only when this call
	# returns, so a one-second tick showed a typed character up to a second
	# after the key was pressed — the console felt slow to take input while
	# nothing on the machine was actually busy. BusyBox's sleep takes whole
	# seconds, but coreutils' timeout takes fractions; where one is there the
	# wait looks five times a second, and where it is not the one-second tick
	# stays. The price is one fork per tick while a console is open, which
	# the router can afford and a one-second echo it cannot.
	_ou_tick=2
	timeout 0.2 true >/dev/null 2>&1 || _ou_tick=10
	_ou_waited=0
	while :; do
		_ou_base="$(cat "$_ou_b" 2>/dev/null || echo 0)"
		case "$_ou_base" in ''|*[!0-9]*) _ou_base=0 ;; esac
		# The leading spaces wc pads with are stripped in the shell rather
		# than by a second fork per tick.
		_ou_sz="$(wc -c < "$_ou_f" 2>/dev/null)"
		_ou_sz="${_ou_sz##* }"
		case "$_ou_sz" in ''|*[!0-9]*) _ou_sz=0 ;; esac
		_ou_abs=$(( _ou_base + _ou_sz ))
		if [ "$_ou_abs" -gt "$_ou_off" ]; then
			break
		fi
		[ "$_ou_waited" -ge $(( _ou_wait * 10 )) ] && break
		# A pane that died ends the wait, but asking tmux five times a second
		# costs more than the freshness is worth: the first pass always asks,
		# and after that once a second is enough.
		if [ $(( _ou_waited % 10 )) -eq 0 ] && ! session_live "$_ou_name"; then
			break
		fi
		if [ "$_ou_tick" -eq 10 ]; then
			sleep 1
		else
			timeout 0.2 sleep 1 2>/dev/null
		fi
		_ou_waited=$(( _ou_waited + _ou_tick ))
	done

	_ou_reset=false
	if [ "$_ou_off" -lt "$_ou_base" ]; then _ou_reset=true; _ou_off="$_ou_base"; fi
	_ou_skip=$(( _ou_off - _ou_base ))
	_ou_alive=true; session_live "$_ou_name" || _ou_alive=false
	_ou_eof=false; [ "$_ou_alive" = false ] && _ou_eof=true

	# Section 74: when the pane is dead its exit status is the whole answer —
	# 0 means the agent finished, anything else means it died. Absent (null)
	# when tmux cannot report it.
	_ou_exit="$(session_exit_code "$_ou_name" 2>/dev/null || true)"

	# Header line (JSON), then the raw bytes.
	printf '{"name": %s, "offset": %s, "reset": %s, "alive": %s, "eof": %s, "exit_code": %s}\n' \
		"$(fcc_json_str "$_ou_name")" "$_ou_abs" "$_ou_reset" "$_ou_alive" "$_ou_eof" \
		"$(fcc_json_num_or_null "${_ou_exit:-}")"
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
	# A dead pane accepts no more input; saying so beats silently dropping keys.
	session_live "$_in_name" || { fcc_die "session not found"; return 1; }
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
	# Every attach starts with a capture, which is exactly the event that tells
	# a reloaded standalone window apart from a closed one (cmd_close_later).
	bump_generation "$_cp_name"
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
	rm -f "$(out_file "$_cl_name")" "$(base_file "$_cl_name")" \
		"$(target_file "$_cl_name")" \
		"$(closing_file "$_cl_name")" "$(gen_file "$_cl_name")"
	fcc_log "fcc-terminal.log" "session closed: $_cl_name"
}

# The generation counter exists for one question: is the page that armed a
# delayed close still the page that is looking at the session? A reload runs
# capture() again, which bumps the counter, and the reaper compares what it
# finds with what was recorded when the close was armed. A closed window never
# runs capture again, so the two stay equal and the close goes ahead. It is a
# counter rather than a timestamp because two clocks are involved — the browser
# sends the request, the router answers it — and the order the two requests
# arrive in must not decide the outcome.
bump_generation() {
	_bg_name="$1"
	_bg_f="$(gen_file "$_bg_name")"
	_bg_g="$(cat "$_bg_f" 2>/dev/null || echo 0)"
	case "$_bg_g" in ''|*[!0-9]*) _bg_g=0 ;; esac
	printf '%s' "$(( _bg_g + 1 ))" > "$_bg_f"
}

cmd_close_all() {
	require_tmux || return 1
	_ca_n=0
	# tmux lists every session on the box, including whatever the user runs by
	# hand; only the fcc-<agent>-NNN namespace is this console's to close.
	for _ca_s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
		fcc_valid_session "$_ca_s" || continue
		if tmux kill-session -t "$_ca_s" 2>/dev/null; then
			_ca_n=$(( _ca_n + 1 ))
		fi
		rm -f "$(out_file "$_ca_s")" "$(base_file "$_ca_s")" \
			"$(target_file "$_ca_s")" \
			"$(closing_file "$_ca_s")" "$(gen_file "$_ca_s")"
	done
	fcc_log "fcc-terminal.log" "session closed: all ($_ca_n)"
	printf '{"closed": %s}\n' "$_ca_n"
}

# Arm a close for `grace` seconds from now.
#
# This is what the standalone browser window asks for when it goes away. The
# close cannot be immediate: a reload also unloads the page, and the requirement
# is that closing the window ends the session, not that reloading it does. So
# the request leaves a marker with the generation it was armed at, and a
# detached `sleep` + reap performs the close if nothing has re-attached by then.
# capture() bumps the generation, so a reload within the grace period cancels
# the close whatever order the two requests reach the router in.
cmd_close_later() {
	require_tmux || return 1
	_cl_name="${1:-}"; _cl_grace="${2:-8}"
	fcc_valid_session "$_cl_name" || { fcc_die "invalid session"; return 2; }
	case "$_cl_grace" in ''|*[!0-9]*) _cl_grace=8 ;; esac
	[ "$_cl_grace" -le 120 ] || _cl_grace=120
	session_exists "$_cl_name" || return 1

	_cl_g="$(cat "$(gen_file "$_cl_name")" 2>/dev/null || echo 0)"
	case "$_cl_g" in ''|*[!0-9]*) _cl_g=0 ;; esac
	printf '%s' "$_cl_g" > "$(closing_file "$_cl_name")"

	# Detached, and detached properly: the usual detach helper is missing from
	# some BusyBox builds, so the child ignores SIGHUP itself. All three
	# descriptors are redirected, because the caller (rpcd) reads this script's
	# stdout until the pipe closes — a background child holding it would keep
	# the request open for the whole grace period.
	sh -c 'trap "" HUP; sleep "$1"; exec "$0" reap' "$0" "$_cl_grace" \
		</dev/null >/dev/null 2>&1 &
	fcc_log "fcc-terminal.log" "session close requested: $_cl_name (grace ${_cl_grace}s)"
}

cmd_reap() {
	for _rp_f in "$SESSDIR"/*.closing; do
		[ -e "$_rp_f" ] || continue
		_rp_name="$(basename "$_rp_f" .closing)"
		fcc_valid_session "$_rp_name" || { rm -f "$_rp_f"; continue; }

		# The session is already gone (closed from a tab, or the agent
		# exited and cleanup reaped it) — nothing to do but drop the marker.
		if ! session_exists "$_rp_name"; then
			rm -f "$_rp_f"
			continue
		fi

		_rp_g="$(cat "$(gen_file "$_rp_name")" 2>/dev/null || echo 0)"
		case "$_rp_g" in ''|*[!0-9]*) _rp_g=0 ;; esac
		_rp_armed="$(cat "$_rp_f" 2>/dev/null || echo 0)"
		case "$_rp_armed" in ''|*[!0-9]*) _rp_armed=0 ;; esac

		# Re-attached since the close was armed: this was a reload, not a
		# close. Cancel it, whoever got here first.
		if [ "$_rp_g" -ne "$_rp_armed" ]; then
			rm -f "$_rp_f"
			continue
		fi

		tmux kill-session -t "$_rp_name" 2>/dev/null
		rm -f "$(out_file "$_rp_name")" "$(base_file "$_rp_name")" \
			"$(target_file "$_rp_name")" "$_rp_f" "$(gen_file "$_rp_name")"
		fcc_log "fcc-terminal.log" "session closed: $_rp_name (its browser window was closed)"
	done
}

cmd_cleanup() {
	require_tmux || return 1
	# Remove dead sessions (the pane's process has exited) and stale files.
	_cu_dead="$(tmux list-panes -a -F '#{session_name} #{pane_dead}' 2>/dev/null \
		| awk '$1 ~ /^fcc-/ && $2==1 {print $1}')"
	for _cu_s in $_cu_dead; do
		fcc_valid_session "$_cu_s" || continue
		tmux kill-session -t "$_cu_s" 2>/dev/null
		rm -f "$(out_file "$_cu_s")" "$(base_file "$_cu_s")" "$(target_file "$_cu_s")"
	done
	# Remove orphaned capture files whose session no longer exists.
	for _cu_f in "$SESSDIR"/fcc-*.out; do
		[ -e "$_cu_f" ] || continue
		_cu_s="$(basename "$_cu_f" .out)"
		fcc_valid_session "$_cu_s" || { rm -f "$_cu_f"; continue; }
		session_exists "$_cu_s" \
			|| rm -f "$_cu_f" "$(base_file "$_cu_s")" "$(target_file "$_cu_s")"
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
	close-all)   cmd_close_all ;;
	close-later) shift; cmd_close_later "$@" ;;
	reap)    cmd_reap ;;
	cleanup) cmd_cleanup ;;
	*) echo "usage: session.sh {list|create|output|input|resize|capture|close|close-all|close-later|reap|cleanup}" >&2; exit 2 ;;
esac
