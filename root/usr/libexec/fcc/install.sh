#!/bin/sh
# luci-app-fcc — FCC Runtime installer adapter (OpenWrt).
#
# DESIGN_SPEC.md section 40: the upstream installer may be used as a *reference*
# but the OpenWrt runtime must have its own adapter. We therefore:
#
#   Download -> Verify (HTTPS + record SHA-256) -> Execute (never curl|sh)
#            -> Validate -> Record metadata
#
# We never pipe a remote script into a shell. The script is written to a file in
# the runtime cache, its SHA-256 is computed and logged, and only then executed.
#
# Usage:
#   install.sh runtime [--agents a,b,c]   Install/refresh the FCC runtime
#   install.sh uninstall [--purge]        Remove the runtime (keeps data unless --purge)
#   install.sh check                      Pre-install compatibility report (JSON)
#
# Locals are per-function prefixed — see the note at the top of common.sh.

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

FCC_INSTALLER_URL="${FCC_INSTALLER_URL:-https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/install.sh}"

# DESIGN_SPEC.md section 23 step 3: refuse to start an update that cannot
# finish. A Python toolchain plus the runtime is a few hundred MB; running out
# of space midway leaves a half-written runtime, which is worse than not
# starting. The floor is FCC_MIN_FREE_MB from common.sh, shared with the doctor
# so the two gates agree on what "enough room" means; it is overridable there
# for a test or a deliberately tight box.

# Section 49: how long to wait for the server to answer after a restart before
# calling the update unhealthy. Generous, because the first start after an
# update compiles bytecode and the box may be a slow router.
FCC_HEALTH_TIMEOUT="${FCC_HEALTH_TIMEOUT:-30}"

ROOT="$(fcc_root)"
LOG="fcc-runtime.log"

# ---------------------------------------------------------------------------
# Environment that redirects every upstream artefact under the runtime root.
# Without this, uv and the agents would scatter into $HOME/.local and $HOME/.fcc.
# ---------------------------------------------------------------------------
apply_runtime_env() {
	# Export the environment that redirects every upstream artefact under the
	# runtime root. Called in this process, which then runs the installer as a
	# child, so the variables are inherited (and discarded when we exit).
	#
	# The names and the values both come from common.sh rather than being
	# written out here. There is a second consumer — the terminal that drives
	# the installer's agent chooser — and it has to export exactly this set: a
	# terminal that starts with a different HOME installs a second runtime into
	# root's home directory, silently, and nothing notices until the flash chip
	# fills up. Two hand-maintained lists would drift; one cannot.
	#
	# `export "$name=$value"` performs the assignment itself, so no shell text
	# is ever built and nothing is passed to eval — the name is one of a fixed
	# list and the value is a path this package derived.
	for _ae_n in $(fcc_runtime_env_names); do
		export "$_ae_n=$(fcc_runtime_env_value "$ROOT" "$_ae_n")"
	done
	# PATH is handled apart because it extends rather than replaces: the
	# runtime's bin goes first so its launchers win, but the system tools have
	# to stay reachable — the installer needs curl, tar and a compiler.
	PATH="$ROOT/bin:$PATH"
	export PATH
}

# ---------------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------------
download_installer() {
	_di_dest="$1"
	_di_url="$FCC_INSTALLER_URL"
	# Only ever fetch over HTTPS.
	case "$_di_url" in https://*) : ;; *) fcc_die "refusing non-HTTPS installer URL"; return 1 ;; esac
	if ! command -v curl >/dev/null 2>&1; then
		fcc_die "curl is required to download the FCC runtime installer"
		return 1
	fi
	if ! curl --fail --silent --show-error --location \
			--proto '=https' --tlsv1.2 --max-time 120 --retry 2 --retry-delay 2 \
			--output "$_di_dest" "$_di_url"; then
		fcc_die "failed to download installer from $_di_url"
		return 1
	fi
	[ -s "$_di_dest" ] || { fcc_die "downloaded installer is empty"; return 1; }
	# Sanity check: it must look like a shell script.
	head -n1 "$_di_dest" | grep -q '^#!' || { fcc_die "downloaded installer is not a shell script"; return 1; }
	return 0
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
	else echo ""; fi
}

# ---------------------------------------------------------------------------
# Compatibility gate
# ---------------------------------------------------------------------------
check_report() {
	"${FCC_LIBDIR:-/usr/libexec/fcc}/doctor.sh" --json
}

precheck_ok() {
	_po_rep="$(check_report)"
	# Extract the overall verdict without a JSON parser dependency.
	printf '%s' "$_po_rep" | grep -q '"install_allowed":[[:space:]]*true'
}

precheck_failures() {
	# Section 3.6.4: a blocked install has to say which check failed, what it
	# found, what it needed and what to do — "precheck failed" is none of those.
	#
	# This runs the doctor a second time, which repeats its DNS and HTTPS probes.
	# That is deliberate and it is affordable: it happens only on the failure
	# path, after the install has already stopped, where the answer is the entire
	# point of the message. Caching the first report would mean either parsing
	# JSON in shell or keeping a temp file alive across the check, and both cost
	# more than the few seconds this takes on a router that is about to refuse
	# the install anyway.
	"${FCC_LIBDIR:-/usr/libexec/fcc}/doctor.sh" --blocking 2>/dev/null
}

# ---------------------------------------------------------------------------
# Run the installer, honouring a requested agent set when possible.
#
# The upstream installer chooses its coding agents by *asking*, and only when it
# has a terminal:
#
#     if installer_is_interactive; then choose_coding_agents /dev/tty /dev/tty; fi
#
# With no terminal it skips the question and installs its own defaults — nine
# agents, including the largest ones. That is not a wrong answer to "which
# agents?" so much as a refusal to hear the question, and on a router it is the
# difference between one agent and nine.
#
# There is no flag, no environment variable and no answer file: the prompts are
# written to fd4 and the answers read from fd3, both /dev/tty, and the installer
# is `set -eu` POSIX sh. So the only way to be asked is to *be* a terminal, and
# the only way to answer is to be the thing on the other end of it.
#
# This package already depends on tmux — it is the Web Console's backend — so
# tmux is the terminal. It is a better one than the `script(1)` this used to
# reach for, and not only because OpenWrt has no `script`:
#
#   * An answer file is positional. Upstream's select_coding_agent() returns 0
#     *without prompting* when the agent is already installed, so on a box that
#     already has Claude Code the first answer is consumed by Codex and every
#     agent after it is installed as its neighbour. Feeding answers by identity
#     — read the prompt, decide from the launcher it names — cannot desync,
#     because it never assumes a question was asked.
#   * The transcript is the installer's own output rather than a replay of it,
#     so logs/installer.out is the evidence a person needs when it fails.
#
# What this does not do is decide *for* the installer. It answers the question
# that was asked, and everything else about the run — which agents exist, what
# they are called, what order they come in — stays upstream's business.
# ---------------------------------------------------------------------------
FCC_INSTALLER_TIMEOUT="${FCC_INSTALLER_TIMEOUT:-1800}"

installer_session() { printf 'fcc-installer'; }

# Kill a leftover installer session from a run that was interrupted.
installer_session_cleanup() {
	command -v tmux >/dev/null 2>&1 || return 0
	tmux kill-session -t "$(installer_session)" 2>/dev/null
	return 0
}

installer_pane_text() {
	tmux capture-pane -p -t "$(installer_session)" 2>/dev/null
}

installer_last_line() {
	# The last line with anything on it. The prompt is written without a
	# trailing newline, so it is the last thing on the pane — but a redraw can
	# leave blank rows under it, and "the last line" would then be empty.
	installer_pane_text | awk 'NF { l = $0 } END { print l }'
}

installer_finished() {
	[ -e "$1" ]
}

installer_exit_status() {
	# The status the pane recorded. Read from a file rather than from tmux's
	# #{pane_dead_status}, which does not exist in every tmux OpenWrt ships and
	# reports nothing at all when the pane is still alive.
	_ies_rc="$(cat "$1" 2>/dev/null)"
	case "$_ies_rc" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s' "$_ies_rc"
}

# Answer one prompt. Prints the keys to send, or nothing when the line is not a
# prompt we recognise.
installer_answer_for() {
	# installer_answer_for <line> <requested-set> <mode>
	#
	# mode is one of:
	#   set      an explicit selection — answer from the set
	#   none     --no-agents — decline everything that is still being offered
	#   default  no opinion — take upstream's own default for each question
	_iaf_line="$1"
	_iaf_set=" $2 "
	_iaf_mode="$3"
	case "$_iaf_line" in
		*'Install '*' for fcc-'*'? [Y/n] '*|*'Install '*' for fcc-'*'? [y/N] '*)
			# "Install Claude Code for fcc-claude? [Y/n] "
			# Strip through " for " to reach the launcher, then up to the "?".
			_iaf_launcher="${_iaf_line##* for }"
			_iaf_launcher="${_iaf_launcher%%\?*}"
			_iaf_id="$(fcc_agent_by_launcher "$_iaf_launcher")"
			case "$_iaf_mode" in
				default)
					# An empty answer is Enter, and prompt_yes_no() reads that
					# as "the default" — which is upstream's own decision for
					# this agent, including the ones it adjusted before asking
					# (Cline when npm is present, Hermes on a platform that
					# cannot have it). Reproducing the default is the only way
					# "no opinion" can mean what it says.
					printf ''
					;;
				set)
					if [ -n "$_iaf_id" ]; then
						case "$_iaf_set" in
							*" $_iaf_id "*) printf 'y' ;;
							*)               printf 'n' ;;
						esac
					else
						# An agent this package has no id for: decline it rather
						# than guess, and rather than leave the installer waiting
						# for an answer that is never coming.
						printf 'n'
					fi
					;;
				*)
					printf 'n'
					;;
			esac
			return 0
			;;
		*'Enable RTK token optimization'*)
			# Section 3.6.5 is about coding agents; RTK is a token-saving proxy
			# the user did not ask for, and its own default is no. Declining is
			# both the default and the smaller change to the router.
			printf 'n'
			return 0
			;;
	esac
	return 1
}

run_installer() {
	_ri_script="$1"
	_ri_agents="$2"      # space separated, empty => upstream defaults
	# Section 3.6.5: the user may uncheck every agent. That is a decision,
	# not the absence of one, and it must not silently become "defaults".
	_ri_none="${3:-0}"

	mkdir -p "$ROOT/cache" "$ROOT/logs" 2>/dev/null
	_ri_env="$ROOT/cache/installer-env.sh"
	_ri_out="$ROOT/logs/installer.out"
	_ri_rc="$ROOT/cache/installer-rc"
	_ri_gate="$ROOT/cache/installer-go"

	if [ "$_ri_none" = 1 ]; then
		_ri_mode=none
		_ri_label="<none>"
	elif [ -n "$_ri_agents" ]; then
		_ri_mode=set
		_ri_label="$_ri_agents"
	else
		_ri_mode=default
		_ri_label="<defaults>"
	fi

	if ! command -v tmux >/dev/null 2>&1; then
		# Without tmux there is no terminal, and without a terminal the agent
		# question is never asked. Running anyway would install upstream's
		# nine-agent default set and report success — a wrong result presented
		# as a right one, on a box whose free space is the reason the set was
		# chosen in the first place. Section 103: say why, and stop.
		fcc_log "$LOG" "installer cannot run: tmux is not installed, so the agent selection cannot be answered"
		printf 'tmux is required to install the FCC runtime.\n'
		printf 'The upstream installer only asks which coding agents to install when it has a terminal,\n'
		printf 'and this package drives that question through tmux. Without it the install would\n'
		printf 'silently install every default agent instead of the ones selected.\n'
		printf '%s\n' "$(fcc_pkg_install_hint tmux)"
		printf 'TMUX_MISSING\n'
		return 1
	fi

	fcc_log "$LOG" "running upstream installer (agents='$_ri_label', terminal=tmux)"
	apply_runtime_env

	# The terminal must start with this environment, and a tmux session inherits
	# the *server's* environment rather than the environment of whatever asked
	# for the session — so a session created against a server that is already
	# running for the Web Console would start with the console's HOME, not this
	# one, and install a second runtime into it. Sourcing a file is what makes
	# the environment certain rather than likely.
	fcc_runtime_env_exports "$ROOT" > "$_ri_env" 2>/dev/null || {
		fcc_log "$LOG" "failed to write the installer environment"
		return 1
	}

	: > "$_ri_out" 2>/dev/null
	rm -f "$_ri_rc" "$_ri_gate" 2>/dev/null
	installer_session_cleanup

	# The pane runs the installer directly — no pipeline, no wrapper — so that
	# stdout is the terminal itself. That is not cosmetic: installer_is_interactive()
	# tests `[ -t 1 ]`, and anything between the installer and the pane (a pipe
	# to tee, say) would make it false and take the question away again.
	#
	# The gate file is the one piece of sequencing here. pipe-pane attaches to a
	# session that must already exist, so the transcript cannot be set up before
	# the session — and a session created running the installer could finish and
	# exit before pipe-pane ever attached, losing exactly the output a fast
	# failure produces. The pane therefore waits for a file this process creates
	# only after the transcript is attached. The trailing sleep keeps the pane
	# alive after the installer exits so the last screen can be read; the session
	# is killed below, and if this process dies instead the sleep ends and the
	# session goes with it.
	_ri_cmd=". $(fcc_shquote "$_ri_env"); \
		while [ ! -e $(fcc_shquote "$_ri_gate") ]; do sleep 1; done; \
		sh $(fcc_shquote "$_ri_script"); printf '%s\n' \"\$?\" > $(fcc_shquote "$_ri_rc"); \
		sleep 300"

	tmux new-session -d -s "$(installer_session)" -x 200 -y 50 "$_ri_cmd" 2>/dev/null || {
		fcc_log "$LOG" "failed to start the installer terminal"
		installer_session_cleanup
		return 1
	}
	tmux pipe-pane -o -t "$(installer_session)" "cat >> $(fcc_shquote "$_ri_out")" 2>/dev/null
	: > "$_ri_gate" 2>/dev/null

	# --- answer the agent prompts -----------------------------------------
	#
	# Identity, not position: the question names the launcher, and the answer
	# follows from whether that agent was asked for. A question we have already
	# answered coming round again means the installer rejected every answer and
	# looped — upstream prints "Select at least one coding agent." and asks the
	# whole list again — which happens when nothing selected is installable, so
	# it is reported rather than answered a second time.
	_ri_answered=""
	_ri_deadline=$(( $(date +%s) + FCC_INSTALLER_TIMEOUT ))
	_ri_stuck=0
	while :; do
		installer_finished "$_ri_rc" && break
		if [ "$(date +%s)" -ge "$_ri_deadline" ]; then
			fcc_log "$LOG" "installer timed out after ${FCC_INSTALLER_TIMEOUT}s"
			break
		fi
		_ri_line="$(installer_last_line)"
		if _ri_ans="$(installer_answer_for "$_ri_line" "$_ri_agents" "$_ri_mode")"; then
			case "$_ri_answered" in
				*"|$_ri_line|"*)
					_ri_stuck=1
					fcc_log "$LOG" "installer re-asked a question already answered; no selected agent can be installed"
					break
					;;
			esac
			_ri_answered="$_ri_answered|$_ri_line|"
			fcc_log "$LOG" "installer prompt answered: $_ri_line -> $_ri_ans"
			tmux send-keys -t "$(installer_session)" "$_ri_ans" Enter 2>/dev/null
		fi
		sleep 1
	done

	# One more capture so the log ends with the installer's final screen rather
	# than one line short of it.
	tmux capture-pane -p -S - -t "$(installer_session)" 2>/dev/null >> "$_ri_out"
	installer_session_cleanup

	if _ri_status="$(installer_exit_status "$_ri_rc")"; then
		return "$_ri_status"
	fi
	# No status file: the pane never got as far as running the installer (it
	# could not source the environment, or tmux refused the session), or the
	# run was cut short by the timeout above.
	[ "$_ri_stuck" = 1 ] && printf 'AGENT_SELECTION_REJECTED\n'
	fcc_log "$LOG" "installer did not report an exit status; see logs/installer.out"
	return 1
}

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------
write_runtime_metadata() {
	_wm_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	_wm_ver="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	_wm_py="$(fcc_detect_version "$ROOT/runtime/python/bin/python3" --version 2>/dev/null || true)"
	[ -n "$_wm_py" ] || _wm_py="$(fcc_detect_version python3 --version 2>/dev/null || true)"

	# Section 42: the runtime manager reports what Node is present. This package
	# never installs Node — the upstream installer decides whether the system one
	# will do — but recording it means the page can say "system node 22.x"
	# instead of leaving the question open when an agent needs it.
	_wm_node="$(fcc_detect_version node --version 2>/dev/null || true)"
	_wm_npm="$(fcc_detect_version npm --version 2>/dev/null || true)"

	# installed_at is when this runtime was first put down; updated_at moves on
	# every write. Overwriting installed_at each update would throw away the one
	# piece of history the file exists to keep.
	_wm_first="$_wm_now"
	if [ -r "$ROOT/runtime.json" ]; then
		_wm_prev="$(sed -n 's/.*"installed_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
			"$ROOT/runtime.json" | head -n 1)"
		[ -n "$_wm_prev" ] && _wm_first="$_wm_prev"
	fi

	{
		printf '{\n'
		printf '  "fcc_version": %s,\n' "$(fcc_json_str_or_null "${_wm_ver:-}")"
		printf '  "python_version": %s,\n' "$(fcc_json_str_or_null "${_wm_py:-}")"
		printf '  "node_version": %s,\n' "$(fcc_json_str_or_null "${_wm_node:-}")"
		printf '  "npm_version": %s,\n' "$(fcc_json_str_or_null "${_wm_npm:-}")"
		printf '  "installed_at": %s,\n' "$(fcc_json_str_or_null "$_wm_first")"
		printf '  "updated_at": %s,\n' "$(fcc_json_str_or_null "$_wm_now")"
		printf '  "install_path": %s' "$(fcc_json_str "$ROOT")"

		# Section 81's agents map: which agents are installed, keyed by id. The
		# executable check is what decides membership — this file is a record of
		# what was seen, never the source of truth for what exists.
		printf ',\n  "agents": {'
		_wm_sep=""
		while IFS='|' read -r _wm_id _wm_rest; do
			case "$_wm_id" in ''|\#*) continue ;; esac
			command -v "$(fcc_agent_command "$_wm_id")" >/dev/null 2>&1 || continue
			printf '%s"%s": true' "$_wm_sep" "$_wm_id"
			_wm_sep=", "
		done <<-EOF
		$(fcc_agents_each)
		EOF
		printf '}'

		# Per-agent versions, so a later status refresh has a fallback when the
		# underlying CLI cannot be probed (see agent.sh detect_agent_version).
		# The comma leads each entry rather than trailing the one before it:
		# the agents map is always emitted, but this list can be empty, and a
		# trailing comma would make the whole document unparseable.
		while IFS='|' read -r _wm_id _wm_rest; do
			case "$_wm_id" in ''|\#*) continue ;; esac
			command -v "$(fcc_agent_command "$_wm_id")" >/dev/null 2>&1 || continue
			_wm_av="$(fcc_detect_version "$(fcc_agent_probe "$_wm_id")" --version 2>/dev/null || true)"
			[ -n "$_wm_av" ] || continue
			printf ',\n  "agent_version_%s": %s' "$_wm_id" "$(fcc_json_str "$_wm_av")"
		done <<-EOF
		$(fcc_agents_each)
		EOF
		printf '\n}\n'
	} > "$ROOT/runtime.json" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Update safety net (DESIGN_SPEC.md section 23 steps 6, 12 and 13)
# ---------------------------------------------------------------------------
backup_runtime() {
	# backup_runtime -> the backup directory, or empty when there was nothing
	# worth keeping (the normal case on a first install).
	#
	# Two different things are being protected, and they want opposite
	# treatments (sections 25, 78 and 79):
	#
	#   data/ + runtime.json  small, and must survive a *successful* update in
	#                         place, so they are copied
	#   runtime/ + bin/       large — a Python interpreter and the uv tools —
	#                         and only needed if the update *fails*, so they are
	#                         renamed aside. Within one filesystem a rename is
	#                         instant and costs no extra space, which is what
	#                         makes section 79's rollback affordable on a router
	#                         that could never hold two copies of the runtime.
	_bk_root="$(fcc_dir_backup)"
	_bk_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
	_bk_dir="$_bk_root/$_bk_stamp"
	mkdir -p "$_bk_dir" 2>/dev/null || return 1

	_bk_any=0
	if [ -d "$ROOT/data" ]; then
		cp -a "$ROOT/data" "$_bk_dir/data" 2>/dev/null && _bk_any=1
	fi
	if [ -f "$ROOT/runtime.json" ]; then
		cp "$ROOT/runtime.json" "$_bk_dir/runtime.json" 2>/dev/null && _bk_any=1
	fi
	for _bk_d in runtime bin; do
		[ -d "$ROOT/$_bk_d" ] || continue
		mv "$ROOT/$_bk_d" "$_bk_dir/$_bk_d" 2>/dev/null && _bk_any=1
	done

	if [ "$_bk_any" -eq 0 ]; then
		rmdir "$_bk_dir" 2>/dev/null
		return 1
	fi
	printf '%s' "$_bk_dir"
}

prune_backups() {
	# Section 25: keep the most recent N backups.
	#
	# Without this a router that is updated monthly accumulates a data copy per
	# update for the life of the device. Each one is small, but the flash it
	# lives on is smaller, and nothing else ever removes them.
	#
	# The directories are named YYYYMMDDTHHMMSSZ in UTC, so a reverse
	# lexicographic sort is a newest-first sort and no mtime is involved — mtimes
	# are the first thing a flash restore or a tar round-trip gets wrong.
	#
	# Only names matching our own stamp are counted or removed. Anything else in
	# backup/ is left exactly where it is: guessing wrong about a directory here
	# destroys the only copy of a user's data.
	_pb_keep="$(fcc_uci_get main backup_keep 3)"
	case "$_pb_keep" in ''|*[!0-9]*) _pb_keep=3 ;; esac
	[ "$_pb_keep" -ge 1 ] || _pb_keep=1

	_pb_root="$(fcc_dir_backup)"
	[ -d "$_pb_root" ] || return 0

	_pb_n=0
	for _pb_d in $(ls -1 "$_pb_root" 2>/dev/null | LC_ALL=C sort -r); do
		case "$_pb_d" in
			[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
			*) continue ;;
		esac
		[ -d "$_pb_root/$_pb_d" ] || continue
		_pb_n=$(( _pb_n + 1 ))
		[ "$_pb_n" -le "$_pb_keep" ] && continue
		rm -rf "$_pb_root/$_pb_d" 2>/dev/null && \
			fcc_log "$LOG" "pruned old backup $_pb_d (keeping the most recent $_pb_keep)"
	done
	return 0
}

commit_backup() {
	# The update succeeded, so the moved-aside runtime tree is dead weight.
	# Section 78 asks for the last successful backup to be kept; the data copy
	# is what that means here — it is small, and it is the part that cannot be
	# reinstalled. Keeping the old runtime tree as well would cost a permanent
	# second copy for no benefit, since a successful update has no use for it.
	_cb_dir="$1"
	[ -n "$_cb_dir" ] && [ -d "$_cb_dir" ] || return 0
	rm -rf "$_cb_dir/runtime" "$_cb_dir/bin" 2>/dev/null
	prune_backups
	return 0
}

wait_for_health() {
	# wait_for_health <seconds> -> 0 once fcc_server_health() reports healthy.
	#
	# Polls rather than sleeping the full timeout: a server that comes up in two
	# seconds should not make the user wait thirty.
	_wh_limit="$1"
	case "$_wh_limit" in ''|*[!0-9]*) _wh_limit=30 ;; esac
	_wh_i=0
	while [ "$_wh_i" -lt "$_wh_limit" ]; do
		case "$(fcc_server_health 2>/dev/null)" in
			*'"healthy": true'*) return 0 ;;
		esac
		sleep 1
		_wh_i=$(( _wh_i + 1 ))
	done
	return 1
}

rollback_runtime() {
	# rollback_runtime <backup-dir> <was-running>
	#
	# Section 79: stop, restore the previous runtime, restore the config, start,
	# health check. The messages are the ones section 79 specifies, because the
	# user is being told what state their router is in and that is not a place
	# for improvisation.
	#
	# The previous runtime is not downloaded again — upstream's installer takes
	# no version argument, so the only copy of it is the one this function
	# renamed aside before the update started.
	_rb_dir="$1"
	_rb_was="$2"

	# A first install is not an update, and section 79's two messages are both
	# about an update: "FCC Server remains stopped" says the server was running
	# and now is not, and "Previous FCC version restored" names a version that
	# never existed here. Reporting either of them for a first install sends the
	# reader looking for a previous version to repair, and hides the actual
	# question, which is whether anything was written at all.
	#
	# runtime.json is the discriminator: it is written only after a successful
	# install, and an update copies it into the backup before touching anything,
	# so it is absent exactly when nothing has ever been installed here.
	if [ -z "$_rb_dir" ] && [ ! -f "$ROOT/runtime.json" ]; then
		# runtime/ and bin/ are what the installer writes, and a partial one is
		# worse than none: the status page would report an install that cannot
		# run. They are the same two directories the update path removes, so the
		# destructive surface is unchanged. data/ is left alone — it is not this
		# installer's to discard, and on a reinstall attempt it may hold provider
		# credentials the user entered through FCC's own admin page.
		rm -rf "$ROOT/runtime" "$ROOT/bin" 2>/dev/null
		fcc_cache_set fcc_version ""
		fcc_log "$LOG" "Install failed. Nothing was installed before, so there was no version to restore."
		printf 'INSTALL_FAILED\n'
		return 1
	fi

	if [ -n "$_rb_dir" ] && [ -d "$_rb_dir" ]; then
		# Discard whatever the failed install left, then put the previous tree
		# back exactly where it was.
		rm -rf "$ROOT/runtime" "$ROOT/bin" 2>/dev/null
		for _rb_d in runtime bin; do
			[ -d "$_rb_dir/$_rb_d" ] || continue
			mv "$_rb_dir/$_rb_d" "$ROOT/$_rb_d" 2>/dev/null
		done
		if [ -d "$_rb_dir/data" ]; then
			rm -rf "$ROOT/data" 2>/dev/null
			cp -a "$_rb_dir/data" "$ROOT/data" 2>/dev/null
		fi
		[ -f "$_rb_dir/runtime.json" ] && cp "$_rb_dir/runtime.json" "$ROOT/runtime.json" 2>/dev/null
	fi

	# Section 25's retention applies to failed updates too. The directory this
	# rollback just consumed is the newest, so it is the one that survives —
	# which is right, since it is the state the router was in when the update
	# was attempted.
	prune_backups

	# Whatever version is on disk now is the truth; drop the cached one so the
	# status page cannot keep reporting the version that failed to install.
	fcc_cache_set fcc_version ""

	[ "$_rb_was" = true ] && /etc/init.d/fcc start >/dev/null 2>&1

	if [ -x "$ROOT/bin/fcc-server" ] && wait_for_health "$FCC_HEALTH_TIMEOUT"; then
		fcc_log "$LOG" "Update failed. Previous FCC version restored."
		printf 'ROLLED_BACK\n'
		return 0
	fi
	fcc_log "$LOG" "FCC Server remains stopped. Please inspect logs."
	printf 'ROLLBACK_FAILED\n'
	return 1
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_runtime() {
	_cr_agents=""
	_cr_none=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--agents)   _cr_agents="$(printf '%s' "${2:-}" | tr ',' ' ')"; shift 2 ;;
			--agents=*) _cr_agents="$(printf '%s' "${1#--agents=}" | tr ',' ' ')"; shift ;;
			# Section 3.6.5 lets the user uncheck every agent. That is a
			# different request from "no opinion, use the defaults", and an
			# empty --agents cannot express it, so it gets its own flag.
			--no-agents) _cr_none=1; shift ;;
			*) shift ;;
		esac
	done

	fcc_ensure_dirs
	_cr_lock="$(fcc_lock_acquire install)" || { fcc_die "another install/update is already running"; return 1; }
	# Section 48's lock only excludes other installs. An update is a different
	# operation with its own lock (section 47) but it rewrites the same runtime,
	# so the two still have to exclude each other.
	if fcc_lock_held update; then
		fcc_lock_release "$_cr_lock"
		fcc_die "an update is already running"
		return 1
	fi

	# --- section 23 step 1: what is being replaced ------------------------
	_cr_before="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	_cr_installed="$(fcc_installed_agents "$ROOT")"

	# Section 3.6.5 lets the user uncheck every agent, and the flag that says so
	# is honoured below. But upstream's chooser refuses to accept an empty set —
	# it prints "Select at least one coding agent." and asks the whole list
	# again, forever — so on a box with no agents installed there is no answer
	# that produces the requested result. Saying so is the whole of section 103:
	# the alternative is to start, install something nobody asked for, and let
	# the user discover it from the agent list.
	if [ "$_cr_none" = 1 ] && [ -z "$_cr_installed" ]; then
		fcc_lock_release "$_cr_lock"
		fcc_log "$LOG" "aborted: no agents requested and none installed; upstream requires at least one"
		printf 'The FCC runtime needs at least one coding agent.\n'
		printf 'The upstream installer will not accept an empty selection — it re-asks until one is chosen —\n'
		printf 'and this is a first install, so there is nothing already present to keep.\n'
		printf 'Select one agent and install again.\n'
		printf 'NO_AGENTS\n'
		return 1
	fi

	# The pre-install checks reason about a set of agents, and which set depends
	# on what was asked for here: an explicit list, all of them declined, or no
	# opinion. Handing the doctor the same three-way answer it would get from
	# the UI is what keeps the report and the install from disagreeing — the
	# bash requirement in particular, which applies to five of the ten agents.
	FCC_AGENT_SELECTION="$_cr_agents"
	FCC_AGENT_NONE="$_cr_none"
	export FCC_AGENT_SELECTION FCC_AGENT_NONE

	if ! precheck_ok; then
		fcc_lock_release "$_cr_lock"
		fcc_log "$LOG" "install aborted: compatibility precheck failed"
		_cr_blocked="$(precheck_failures)"
		# The report goes into the log and nowhere else. When this runs as a job
		# its stdout *is* that same file, so echoing it here as well would print
		# the whole thing twice; and the log is where both readers look — the job
		# panel tails it, and it is what a person opens when the install stops.
		# One fcc_log call per line, so each keeps its own timestamp and gets
		# redacted like every other entry.
		if [ -n "$_cr_blocked" ]; then
			printf '%s\n' "$_cr_blocked" | while IFS= read -r _cr_line; do
				fcc_log "$LOG" "$_cr_line"
			done
		fi
		# stdout keeps the single machine-readable token the callers match on.
		printf 'PRECHECK_FAILED\n'
		return 1
	fi

	# --- section 23 step 3: disk space ------------------------------------
	_cr_free="$(fcc_disk_free_kb "$ROOT" 2>/dev/null || true)"
	case "$_cr_free" in ''|*[!0-9]*) _cr_free=0 ;; esac
	if [ "$_cr_free" -gt 0 ] && [ "$_cr_free" -lt $(( FCC_MIN_FREE_MB * 1024 )) ]; then
		fcc_lock_release "$_cr_lock"
		fcc_log "$LOG" "aborted: $(( _cr_free / 1024 ))MB free under $ROOT, need ${FCC_MIN_FREE_MB}MB"
		# Section 54's wording. How short the box is matters more than the fact
		# that it failed: it is the number the user has to act on.
		printf 'Not enough storage space.\nRequired: %s MB\nAvailable: %s MB\n' \
			"$FCC_MIN_FREE_MB" "$(( _cr_free / 1024 ))"
		printf 'NO_SPACE\n'
		return 1
	fi
	[ "$_cr_free" -gt 0 ] && fcc_log "$LOG" "preflight: $(( _cr_free / 1024 ))MB free under $ROOT"

	# --- sections 23 steps 4-5: open sessions -----------------------------
	# An update restarts the server; the tmux sessions themselves survive, but
	# an agent mid-task can be interrupted, so the count is logged. This is a
	# warning and not a veto — the UI asks for confirmation before calling this.
	_cr_sessions="$(fcc_active_sessions 2>/dev/null || true)"
	case "$_cr_sessions" in ''|*[!0-9]*) _cr_sessions=0 ;; esac
	if [ "$_cr_sessions" -gt 0 ]; then
		fcc_log "$LOG" "WARN: $_cr_sessions console session(s) are open and may be interrupted"
	fi

	# --- section 23 step 6: back up ---------------------------------------
	_cr_was_running=false
	[ -n "$(fcc_server_pid 2>/dev/null || true)" ] && _cr_was_running=true
	_cr_backup="$(backup_runtime 2>/dev/null || true)"
	[ -n "$_cr_backup" ] && fcc_log "$LOG" "backed up to $_cr_backup (data copied, previous runtime renamed aside)"

	# --- sections 23 steps 7-8: stop --------------------------------------
	# The upstream installer refuses to run while FCC processes are alive.
	/etc/init.d/fcc stop >/dev/null 2>&1

	_cr_script="$ROOT/cache/fcc-install-$$.sh"
	if ! download_installer "$_cr_script"; then
		rollback_runtime "$_cr_backup" "$_cr_was_running"
		fcc_lock_release "$_cr_lock"
		return 1
	fi
	_cr_hash="$(sha256_of "$_cr_script")"
	fcc_log "$LOG" "installer downloaded from $FCC_INSTALLER_URL sha256=$_cr_hash"
	printf '%s  %s\n' "$_cr_hash" "$FCC_INSTALLER_URL" >> "$ROOT/cache/installer-hashes.log" 2>/dev/null

	# --- section 23 step 9: update ----------------------------------------
	run_installer "$_cr_script" "$_cr_agents" "$_cr_none"
	_cr_rc=$?
	rm -f "$_cr_script"

	if [ "$_cr_rc" -ne 0 ]; then
		fcc_log "$LOG" "installer exited with status $_cr_rc; see logs/installer.out"
		rollback_runtime "$_cr_backup" "$_cr_was_running"
		fcc_lock_release "$_cr_lock"
		return "$_cr_rc"
	fi

	# --- section 23 step 10: verify ---------------------------------------
	if ! "$ROOT/bin/fcc-server" --version >/dev/null 2>&1; then
		fcc_log "$LOG" "validation failed: fcc-server --version did not succeed"
		rollback_runtime "$_cr_backup" "$_cr_was_running"
		fcc_lock_release "$_cr_lock"
		return 1
	fi

	write_runtime_metadata
	# The cached version is now stale; drop it so the status page does not show
	# the pre-update version for the rest of its TTL.
	fcc_cache_set fcc_version ""

	# --- sections 23 steps 11-12: start, then check -----------------------
	_cr_autostart="$(fcc_uci_get main auto_start 1)"
	if [ "$_cr_autostart" = "1" ]; then
		/etc/init.d/fcc enable >/dev/null 2>&1
		/etc/init.d/fcc start  >/dev/null 2>&1
	fi

	# Section 49: the update is not finished until the server answers. Only
	# checked when something is supposed to be listening, so an install with
	# auto_start off (and nothing running before) is not reported as a failure.
	if [ "$_cr_autostart" = "1" ] || [ "$_cr_was_running" = true ]; then
		if wait_for_health "$FCC_HEALTH_TIMEOUT"; then
			fcc_log "$LOG" "health check passed: $(fcc_server_health)"
		else
			fcc_log "$LOG" "health check FAILED after ${FCC_HEALTH_TIMEOUT}s: $(fcc_server_health)"
			# rollback_runtime prints the outcome itself — ROLLED_BACK or
			# ROLLBACK_FAILED — so this path does not add a second, vaguer word
			# for the same thing.
			rollback_runtime "$_cr_backup" "$_cr_was_running"
			fcc_lock_release "$_cr_lock"
			return 1
		fi
	fi

	# The update is verified and the server is answering; the previous runtime
	# is no longer needed (section 78 keeps the data copy).
	commit_backup "$_cr_backup"

	_cr_after="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	fcc_lock_release "$_cr_lock"
	fcc_log "$LOG" "FCC runtime installed successfully (${_cr_before:-none} -> ${_cr_after:-unknown})"
	printf 'OK\n'
	return 0
}

cmd_uninstall() {
	_cu_purge=0
	[ "${1:-}" = "--purge" ] && _cu_purge=1
	/etc/init.d/fcc stop >/dev/null 2>&1
	# Remove everything except data/ and backup/ unless --purge.
	for _cu_d in runtime bin cache sessions; do
		[ -d "$ROOT/$_cu_d" ] && rm -rf "$ROOT/$_cu_d"
	done
	rm -f "$ROOT/runtime.json"
	if [ "$_cu_purge" -eq 1 ]; then
		rm -rf "$ROOT/data" "$ROOT/backup"
		fcc_log "$LOG" "FCC runtime uninstalled (data purged)"
	else
		fcc_log "$LOG" "FCC runtime uninstalled (data preserved)"
	fi
	printf 'OK\n'
	return 0
}

case "${1:-}" in
	runtime)   shift; cmd_runtime "$@" ;;
	uninstall) shift; cmd_uninstall "$@" ;;
	check)     check_report ;;
	*) echo "usage: install.sh {runtime [--agents a,b] | uninstall [--purge] | check}" >&2; exit 2 ;;
esac
