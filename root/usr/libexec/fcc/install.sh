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
#   install.sh runtime [--agents a,b,c] [--all-agents]
#                                         Install/refresh the FCC runtime. With
#                                         --all-agents the whole registry is
#                                         requested, which is what the
#                                         Configuration page installs.
#   install.sh reinstall                  Remove the runtime and install it
#                                         again with every agent (keeps data)
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
	# The list, the values and the PATH are all in common.sh — see
	# fcc_runtime_env_apply() — because the Web Console's agent pane and
	# `fcc-env shell` have to export exactly this set too, and a second copy
	# here is how the pane's PATH came to be missing its agent directories.
	fcc_runtime_env_apply "$ROOT"
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
# How many consecutive one-second polls an unrecognised question may hold the
# screen before the run is stopped and the question named. Five is far longer
# than any real prompt needs — a recognised one is answered on the first poll —
# and far shorter than the deadline above, which is the point: see the answer
# loop in run_installer().
FCC_PROMPT_STALL_POLLS="${FCC_PROMPT_STALL_POLLS:-5}"

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

installer_transcript() {
	# installer_transcript <transcript> -> the screen's text, one line per line
	#
	# The transcript is a terminal screen rather than a text file: the installer
	# colours its output, tmux writes into the same stream, and the final
	# capture-pane adds a whole screen of trailing blanks. Carriage returns and
	# escape sequences are stripped and blank lines dropped before any line is
	# chosen from it. The escape is built with printf because BusyBox sed has no
	# \x escape of its own.
	#
	# The parameter bytes are matched with the bracket written last inside its
	# class, so this line holds no double open-bracket: the shell suite rejects
	# that pair anywhere in the tree, and an escaped bracket followed by the
	# class would spell it. Cursor-mode sequences carry a "?" among those bytes,
	# and one left standing in front of an "error:" line would hide it from the
	# anchored match in installer_failure_reason — which is why they are removed
	# here, once, for every reader of the screen.
	_it_file="$1"
	[ -r "$_it_file" ] || return 1
	_it_esc="$(printf '\033')"
	tr -d '\r' < "$_it_file" 2>/dev/null \
		| sed -e "s/${_it_esc}[0-9;?<>=[]*[A-Za-z]//g" \
		| grep -v '^[[:space:]]*$'
}

installer_failure_reason() {
	# installer_failure_reason <transcript> -> the installer's own last word
	#
	# The upstream installer is `set -eu` and routes every failure through
	# fail(), which writes "error: <what happened>" to stderr. stderr is the
	# terminal, so that line lands in the transcript and nowhere else — and
	# while the runtime log said "see logs/installer.out", the Logs panel
	# offered no such file. The one line that says why the install stopped was
	# therefore the one line no reader could reach, which is how a box with
	# BusyBox tar produced a report of "always FAILED" with no reason in it.
	# The line is copied into the runtime log now, which is the file the job
	# panel and the Logs panel both show.
	_ifr_file="$1"
	_ifr_txt="$(installer_transcript "$_ifr_file")" || return 1
	_ifr_line="$(printf '%s\n' "$_ifr_txt" | grep '^error: ' | tail -n 1)"
	# No fail() line — the run was cut short by the timeout, or the installer
	# died on a signal. The last thing it managed to print is the next best
	# answer, and an empty one is not an answer at all.
	[ -n "$_ifr_line" ] || _ifr_line="$(printf '%s\n' "$_ifr_txt" | tail -n 1)"
	[ -n "$_ifr_line" ] || return 1
	printf '%s' "$_ifr_line"
}

installer_missing_tool() {
	# installer_missing_tool <transcript> -> the command name, or nothing
	#
	# The installer's own last word names an exit code and nothing else —
	# "error: Codex installation failed with exit code 1." The line that says
	# what was actually missing is one the shell printed a moment earlier and
	# upstream never repeated:
	#
	#   /tmp/fcc-install.iKaKoG: line 215: fold: not found
	#
	# BusyBox ash writes that form for a command inside a script it is running,
	# and "ash: fold: not found" for one it cannot find at a prompt, so both are
	# matched. The last match wins, because it is the one nearest the failure.
	#
	# The prefix is anchored to those two shapes rather than to "anything ending
	# in ': not found'", because the loose form matches prose: the installer's
	# own "Failed to resolve the latest Codex release version." is one word away
	# from reading as a missing command called "resolve".
	#
	# The name is checked before it is handed back: it is text out of a log
	# line, and the only thing this function is allowed to return is something
	# shaped like a command.
	#
	# A command can also be present and still not do the job, and the line then
	# looks nothing like the one above. BusyBox's sleep is the case this package
	# knows: it exists, so "not found" never appears, and it rejects the
	# fractional argument the Pi installer animates its logo with —
	#
	#   sleep: invalid number '0.075'
	#
	# Both forms name the command in the same place, so both are read here and
	# the caller gets a tool name either way. Only the measured wording is
	# matched: a broader "invalid argument" would be a guess at what some other
	# applet prints, and a guess here names the wrong package.
	_imt_txt="$(installer_transcript "$1")" || return 1
	_imt_flat="$(printf '%s\n' "$_imt_txt" | sed -e 's/^[[:space:]]*//')"

	_imt_line="$(printf '%s\n' "$_imt_flat" \
		| grep -E '(^|: line [0-9]+: |^[A-Za-z0-9_.+-]+: )[A-Za-z0-9_.+-]+: not found$' \
		| tail -n 1)"
	if [ -n "$_imt_line" ]; then
		_imt_tool="${_imt_line%: not found}"
		_imt_tool="${_imt_tool##*: }"
	else
		_imt_line="$(printf '%s\n' "$_imt_flat" \
			| grep -E '(^|: line [0-9]+: )[A-Za-z0-9_.+-]+: invalid number ' \
			| tail -n 1)"
		[ -n "$_imt_line" ] || return 1
		_imt_tool="${_imt_line%%: invalid number *}"
		_imt_tool="${_imt_tool##*: }"
	fi
	case "$_imt_tool" in
		''|*[!A-Za-z0-9_.+-]*) return 1 ;;
	esac
	printf '%s' "$_imt_tool"
}

installer_explain_missing_tool() {
	# installer_explain_missing_tool <transcript>
	#
	# Section 104.12: the reason has to reach whoever reads the log. This
	# failure had the answer in the transcript — "fold: not found", twice — and
	# the question in the log — "exit code 1" — so the one file a person opens
	# was the one file that did not say.
	# "does not provide" is true of a command that is not there and false of one
	# that is: BusyBox ships a sleep, and the Pi installer's failure is that this
	# image's sleep refuses the fraction it is handed. A reader who is told the
	# tool is missing goes looking for it, finds it, and is back where they
	# started — so the wording follows whether the command exists.
	_iem_tool="$(installer_missing_tool "$1" 2>/dev/null || true)"
	[ -n "$_iem_tool" ] || return 0

	_iem_lack="which this image does not provide"
	command -v "$_iem_tool" >/dev/null 2>&1 && _iem_lack="but this image's version of it is too limited"
	fcc_log "$LOG" "installer: the installer needed '$_iem_tool', $_iem_lack"

	# The package, for the tools whose provider has been verified. A short table
	# rather than a guess from the name: "coreutils-<tool>" is the usual shape
	# on OpenWrt and not a rule, and a package that does not exist is a second
	# dead end after the first. The table is the same one the Configuration
	# page's check reads, so the two cannot name different packages.
	_iem_pkg="$(fcc_tool_package "$_iem_tool")"
	[ -n "$_iem_pkg" ] && fcc_log "$LOG" "installer: $_iem_tool is packaged separately here: $(fcc_pkg_install_hint "$_iem_pkg")"
	_iem_why="$(fcc_tool_purpose "$_iem_tool")"
	[ -n "$_iem_why" ] && fcc_log "$LOG" "installer: $_iem_why"
	fcc_log "$LOG" "installer: the Configuration page's check reports this before an install; the line itself is in logs/installer.out"
}

installer_download_url_for() {
	# installer_download_url_for <installer-script> <label> -> URL, or nothing.
	#
	# The upstream installer names a failed download by the label it was handed
	# — "Could not download the Codex installer (curl exit code 35)." — and that
	# label is the only handle on which *host* could not be reached. The host is
	# the fact a reader needs and the one the message does not carry: it is what
	# says whether the router's own network is the problem, and it is what a
	# person has to be able to test.
	#
	# Both halves of the answer are read out of the installer that was actually
	# run rather than kept in a table here. Those URLs belong to upstream and
	# change without telling anyone; a copy of them in this package would go
	# stale silently, and a stale table names the wrong host — which is worse
	# than naming none at all. At every call site the variable and the label sit
	# on one line, `download_and_run "$CODEX_INSTALL_URL" sh "Codex"`, so the
	# pair can be recovered from that line and the assignment above it.
	#
	# The label is matched literally (grep -F), because it is text out of a log
	# line and not a pattern: "Codex" must not also match "Codex Something".
	_idu_script="$1"
	_idu_label="$2"
	[ -r "$_idu_script" ] || return 1
	[ -n "$_idu_label" ] || return 1

	_idu_line="$(grep -o 'download_and_run "\$[A-Za-z_][A-Za-z_0-9]*"[^"]*"[^"]*"' \
			"$_idu_script" 2>/dev/null \
		| grep -F "\"$_idu_label\"" | head -n 1)"
	[ -n "$_idu_line" ] || return 1

	_idu_var="${_idu_line#download_and_run \"\$}"
	_idu_var="${_idu_var%%\"*}"
	[ -n "$_idu_var" ] || return 1

	_idu_url="$(grep -m 1 "^${_idu_var}=\"https://" "$_idu_script" 2>/dev/null || true)"
	[ -n "$_idu_url" ] || return 1
	_idu_url="${_idu_url#*=}"
	_idu_url="${_idu_url#\"}"
	_idu_url="${_idu_url%\"}"
	printf '%s' "$_idu_url"
}

installer_explain_failure() {
	# installer_explain_failure <installer-script> <reason> <transcript>
	#
	# Section 103: when something cannot work, say exactly why instead of leaving
	# the reader with a number. "curl exit code 35" is not something a person can
	# act on, and the host it happened to is not in the installer's message at
	# all — so the two facts that turn a failed install into a diagnosable one
	# are added here, to the log the job panel shows. This is what the router
	# reported before the change, and it is why the question had to be asked:
	#
	#   installer reported: error: Could not download the Codex installer
	#   (curl exit code 35).
	#
	# Two failures have a cause upstream's line does not carry: a download that
	# could not reach a host, and a command this image does not have. The second
	# is read out of the transcript and reported whatever the reason says,
	# because the reason is the same exit-code line for every cause — that is
	# how "fold: not found" came to be reported as "exit code 1".
	#
	# The transcript is optional rather than required, and the default is not
	# politeness: this runs on the failure path, under `set -u`, where a missing
	# argument is a hard error. A diagnosis that cannot crash the thing it is
	# diagnosing matters more than one that refuses to run without its input.
	# The one caller passes it — a test asserts that — so an empty one here
	# means a caller that forgot, not a transcript that does not exist.
	_ief_script="$1"
	_ief_reason="$2"
	_ief_transcript="${3:-}"

	installer_explain_missing_tool "$_ief_transcript"

	case "$_ief_reason" in
		*'Could not download the '*) : ;;
		*) return 0 ;;
	esac

	# "…download the Codex installer (curl exit code 35)." -> "Codex".
	# The label is the whole of what upstream gives, and it is the same string it
	# passed to download_and_run, which is what makes the lookup above possible.
	_ief_label="${_ief_reason#*Could not download the }"
	_ief_label="${_ief_label%% installer*}"

	_ief_code=""
	case "$_ief_reason" in
		*'(curl exit code '*)
			_ief_code="${_ief_reason#*(curl exit code }"
			_ief_code="${_ief_code%%)*}"
			;;
	esac
	case "$_ief_code" in
		''|*[!0-9]*) _ief_code="" ;;
	esac

	_ief_url="$(installer_download_url_for "$_ief_script" "$_ief_label" 2>/dev/null || true)"
	_ief_host=""
	if [ -n "$_ief_url" ]; then
		_ief_host="${_ief_url#https://}"
		_ief_host="${_ief_host%%/*}"
	fi

	# Only the codes a download can actually produce, and only the ones whose
	# meaning is not the message itself. 22 (an HTTP error status) and 23 (a
	# write failure) say what they are; 35 does not, and it is the one this
	# package has been asked about.
	_ief_why=""
	case "$_ief_code" in
		6)  _ief_why="the host name could not be resolved" ;;
		7)  _ief_why="the connection was refused" ;;
		28) _ief_why="the request timed out" ;;
		35) _ief_why="the TLS handshake with the server did not complete" ;;
		56) _ief_why="the connection was closed while the response was being read" ;;
		60) _ief_why="the server's certificate was not accepted" ;;
		*)  _ief_why="" ;;
	esac

	[ -n "$_ief_host" ] && fcc_log "$LOG" "installer: $_ief_label is downloaded from $_ief_url"
	[ -n "$_ief_why" ] && fcc_log "$LOG" "installer: curl exit code $_ief_code means $_ief_why"
	[ -n "$_ief_host" ] && fcc_log "$LOG" "installer: that is the network path to $_ief_host, not an FCC failure; check it with: curl -v -o /dev/null $_ief_url"
	# The consequence, stated rather than implied. Upstream's fail() exits, and
	# section 79's rollback then puts the box back where it started, so "the
	# install failed" is not the same as "some agents were installed".
	fcc_log "$LOG" "installer: upstream stops at the first agent it cannot download, so this attempt installed no agent"
}

# Pi's action menu, as its rows reach the pane. The menu is drawn as a block —
# "Choose an action:", then a row per key — and installer_last_line() returns the
# last row, so a row is what has to be anchored on rather than the heading. It is
# also the right anchor for a second reason: Pi prints the action it took the
# moment the menu is answered, so the row is gone by the next poll and the loop's
# "this question has already been answered" guard is not tripped by a menu that is
# still on the screen.
#
# Every row is listed rather than the bottom one alone, which is the one that
# actually arrives. A pane shorter than the block shows only its bottom, and a row
# this function does not recognise is a question nobody answers: the installer sits
# on the menu until the deadline and the run rolls back.
#
# The label is what is matched, not the key column in front of it, because that
# column is colour: print_pi_action_menu() writes the key through a %-4s and wraps
# it in cyan, so until installer_pane_text() strips the escapes what sits between
# the key and the label is an escape sequence. The labels survive, and each is the
# row's own text — "Uninstall Pi" is a row, and "Will uninstall Pi." is the
# sentence Pi prints after it, in lower case, so it cannot be read as one. A
# fragment like "Install Pi" could be: it opens "Will install Pi.", the line Pi
# prints the moment the menu is answered, and answering *that* a second time would
# put the key into the next prompt instead — "Start pi now?", whose default is yes.
installer_line_is_pi_menu() {
	# installer_line_is_pi_menu <line> -> 0 when the line is a row of the menu
	case "$1" in
		*'Do nothing'*|*'Uninstall Pi'*|*'Reinstall Pi (default)'*|\
		*'Install Pi (default)'*|*'Migrate Pi to a managed installation'*)
			return 0
			;;
	esac
	return 1
}

installer_answer_is_keypress() {
	# installer_answer_is_keypress <line> -> 0 when the answer is a bare key
	#
	# Every other question here is read a line at a time, so its answer is sent
	# with Enter. Pi's action menu is not: choose_pi_action() puts the terminal
	# in -icanon and reads exactly one byte (dd bs=1 count=1), so an Enter sent
	# after the key is not consumed by the menu at all. It stays in the
	# terminal's input queue and is read by the *next* prompt — which is
	# "Start pi now? [Y/n]", whose default is yes. Pi's own interface would then
	# start in the pane, never exit, and the install would sit there until the
	# deadline and roll back. Sending the key alone is what keeps that Enter
	# from existing.
	installer_line_is_pi_menu "$1"
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

	# Pi's action menu is asked before the case rather than inside it, because
	# recognising it is a question about several lines — see
	# installer_line_is_pi_menu() — and a case pattern cannot ask one.
	if installer_line_is_pi_menu "$_iaf_line"; then
		# y installs, u uninstalls, n does nothing. The key is sent on its own;
		# see installer_answer_is_keypress().
		#
		# "u" is never sent, whichever row was read. Uninstalling an agent is
		# not a thing an install was asked to do, and the row only exists on the
		# menu at all when a pi is already installed.
		case "$_iaf_mode" in
			none)
				# --no-agents is a decision, and installing Pi anyway would be
				# the opposite of it. "n" leaves Pi alone.
				printf 'n'
				;;
			set)
				case "$_iaf_set" in
					*" pi "*) printf 'y' ;;
					*)        printf 'n' ;;
				esac
				;;
			*)
				# No opinion: take the menu's own default, which is the action
				# Pi derived from what it found on disk — install when there is
				# none, reinstall when there is.
				printf 'y'
				;;
		esac
		return 0
	fi

	case "$_iaf_line" in
		# "Install Claude Code for fcc-claude? [Y/n]"
		#
		# The trailing space after [Y/n] is upstream's — prompt_yes_no() ends
		# with `printf '%s %s ' "$question" "$prompt" >&4`, and nothing follows
		# it because the installer is blocked on the read. It is NOT here,
		# because the line being matched came through `tmux capture-pane -p`,
		# which strips trailing whitespace from every line it prints. Requiring
		# that space therefore matched nothing, ever: the loop below never
		# answered a question, never saw the exit status file appear, and sat
		# there until the deadline — so every runtime install took the full
		# ${FCC_INSTALLER_TIMEOUT}s, rolled back, and left the page's progress
		# bar parked at 95%. Matching up to "[Y/n]" and letting the rest of the
		# line be anything is what the pane can actually be asked for.
		*'Install '*' for fcc-'*'? [Y/n]'*|*'Install '*' for fcc-'*'? [y/N]'*)
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
		*'Start pi now?'*)
			# Pi offers to launch its own interface in the terminal the install
			# ran in. It is a full-screen program that stays until it is quit by
			# hand, and that terminal belongs to the installer job — so yes ends
			# the job by hanging it, and the deadline then rolls the install
			# back. Declining is also what the Admin UI wants: it starts the
			# agents itself, in their own sessions.
			printf 'n'
			return 0
			;;
		*'Pi needs Node.js'*)
			# Only reached when the Node this package provisions is not there —
			# provision_node() runs before the installer, and this question does
			# not appear when it worked. Pi's own remedy is nodejs.org/dist,
			# which publishes no musl build: answering yes installs a glibc Node
			# that cannot execute on this image, and the install then fails
			# further along with a worse reason than this one. Declining stops
			# it here, with Pi's own sentence about what is missing.
			printf 'n'
			return 0
			;;
		*'token optimization'*)
			# Section 3.6.5 is about coding agents; RTK and Headroom are a
			# token-saving pair the user did not ask for, and upstream's own
			# default for them is no. Declining is both the default and the
			# smaller change to the router.
			#
			# The anchor is the phrase, not the product. This rule used to read
			# `*'Enable RTK token optimization'*` — upstream's wording of the
			# day, matched exactly — and it worked until upstream grew a second
			# product: "Enable RTK + Headroom token optimization?". The literal
			# no longer appeared in the question, the rule stopped matching, and
			# because an unmatched prompt is simply not answered, every install
			# then sat on that question until FCC_INSTALLER_TIMEOUT rolled it
			# back. "token optimization" is the part that names what is being
			# offered, and it is the part upstream has kept through the reword.
			printf 'n'
			return 0
			;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# Node.js — fetch the musl build the npm-based agents are installed with
# ---------------------------------------------------------------------------
# common.sh carries the measurements: Pi, DeepSeek Harness and Cline are npm
# packages, their floor is Node ^22.19.0 or >=24.0.0, this image's own node is
# below it, and the Pi installer's remedy — nodejs.org/dist — has no musl build,
# so what it leaves behind cannot execute at all.
#
# The destination is the directory upstream's own PATH entry already names,
# ${XDG_DATA_HOME:-$HOME/.local/share}/pi-node, and `current` is what that entry
# points through — the same shape the Pi installer leaves when it works. Nothing
# downstream has to be told where the Node went.
#
# Every failure here returns instead of dying: the install is not this step's to
# abandon, and the agent that needed Node will fail a moment later with the
# reason already in the log — which is the part that was missing before.
provision_node() {
	_pn_agents="$1"    # space separated ids needing a Node this image lacks

	[ -n "$_pn_agents" ] || return 0

	_pn_arch="$(fcc_node_arch)"
	if [ -z "$_pn_arch" ]; then
		fcc_log "$LOG" "node: no musl build exists for $(uname -m 2>/dev/null), so $_pn_agents cannot be installed here"
		return 1
	fi

	_pn_base="${XDG_DATA_HOME:-$HOME/.local/share}/pi-node"

	# A Node this function installed on an earlier run is already the answer.
	# The check is made against the directory rather than against PATH, because
	# the runtime's directories are added to PATH by run_installer() — which
	# runs after this — so PATH would report the Node fetched a moment ago as
	# missing and fetch it again, on every install, including the ones that
	# change nothing.
	_pn_still=""
	for _pn_id in $_pn_agents; do
		fcc_node_dir_ok_for "$_pn_base/current/bin" "$_pn_id" || _pn_still="$_pn_still $_pn_id"
	done
	_pn_agents="${_pn_still# }"
	[ -n "$_pn_agents" ] || return 0

	_pn_names=""
	for _pn_id in $_pn_agents; do
		_pn_name="$(fcc_agent_name "$_pn_id")"
		[ -n "$_pn_name" ] || _pn_name="$_pn_id"
		_pn_names="$_pn_names, $_pn_name"
	done
	_pn_names="${_pn_names#, }"

	_pn_tmp="$ROOT/cache/node.$$"
	mkdir -p "$_pn_tmp" "$_pn_base" 2>/dev/null || {
		fcc_log "$LOG" "node: cannot write under $_pn_base"
		return 1
	}

	fcc_log "$LOG" "node: $_pn_names need Node.js and this image has none that can run; fetching a musl build"

	# The newest v22.x, read from the index rather than written down here. A
	# pinned number goes stale without saying so, and a Node that is merely old
	# is the exact failure this function exists to end.
	_pn_index="$_pn_tmp/index.json"
	if ! curl --fail --silent --show-error --location \
			--proto '=https' --tlsv1.2 --max-time 120 --retry 2 --retry-delay 2 \
			--output "$_pn_index" "$FCC_NODE_DIST_BASE/index.json"; then
		fcc_log "$LOG" "node: could not reach $FCC_NODE_DIST_BASE"
		rm -rf "$_pn_tmp"
		return 1
	fi
	_pn_v="$(grep -o '"version":"v22\.[0-9.]*"' "$_pn_index" 2>/dev/null \
		| head -n 1 | sed 's/.*"v/v/; s/"$//')"
	if [ -z "$_pn_v" ]; then
		fcc_log "$LOG" "node: no v22 build is listed at $FCC_NODE_DIST_BASE"
		rm -rf "$_pn_tmp"
		return 1
	fi

	# The checksum comes from the same release directory as the tarball, and is
	# checked before anything is unpacked: this is a 30 MB binary from a third
	# party being placed where the agents will run it from.
	_pn_file="node-${_pn_v}-linux-${_pn_arch}-musl.tar.xz"
	_pn_shas="$_pn_tmp/SHASUMS256.txt"
	if ! curl --fail --silent --show-error --location \
			--proto '=https' --tlsv1.2 --max-time 120 --retry 2 --retry-delay 2 \
			--output "$_pn_shas" "$FCC_NODE_DIST_BASE/$_pn_v/SHASUMS256.txt"; then
		fcc_log "$LOG" "node: could not fetch the checksums for $_pn_v"
		rm -rf "$_pn_tmp"
		return 1
	fi
	_pn_want="$(awk -v f="$_pn_file" '$2 == f { print $1; exit }' "$_pn_shas" 2>/dev/null)"
	if [ -z "$_pn_want" ]; then
		fcc_log "$LOG" "node: $_pn_v has no $_pn_file"
		rm -rf "$_pn_tmp"
		return 1
	fi

	_pn_tar="$_pn_tmp/$_pn_file"
	if ! curl --fail --silent --show-error --location \
			--proto '=https' --tlsv1.2 --max-time 600 --retry 2 --retry-delay 2 \
			--output "$_pn_tar" "$FCC_NODE_DIST_BASE/$_pn_v/$_pn_file"; then
		fcc_log "$LOG" "node: could not download $_pn_file"
		rm -rf "$_pn_tmp"
		return 1
	fi
	_pn_got="$(sha256_of "$_pn_tar")"
	if [ "$_pn_got" != "$_pn_want" ]; then
		fcc_log "$LOG" "node: $_pn_file failed its checksum (expected $_pn_want, got ${_pn_got:-nothing})"
		rm -rf "$_pn_tmp"
		return 1
	fi

	# Extracted beside the previous one rather than over it, so a failure here
	# leaves whatever was working alone; `current` moves only once the tree is
	# on disk. The tarball's own top-level directory is what the name expects.
	_pn_dir="$_pn_base/node-${_pn_v}-linux-${_pn_arch}-musl"
	rm -rf "$_pn_dir" 2>/dev/null
	if ! tar -xf "$_pn_tar" -C "$_pn_base" 2>/dev/null; then
		fcc_log "$LOG" "node: could not extract $_pn_file"
		rm -rf "$_pn_tmp" "$_pn_dir"
		return 1
	fi
	rm -f "$_pn_base/current" 2>/dev/null
	if ! ln -s "$_pn_dir" "$_pn_base/current" 2>/dev/null; then
		fcc_log "$LOG" "node: could not point $_pn_base/current at $_pn_dir"
		rm -rf "$_pn_tmp" "$_pn_dir"
		return 1
	fi
	rm -rf "$_pn_tmp" 2>/dev/null
	fcc_log "$LOG" "node: installed $_pn_v (musl, $_pn_arch) at $_pn_dir"
	return 0
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
	# The unrecognised question currently on screen, and how many polls in a row
	# it has been there. See the else branch below.
	_ri_unknown=""
	_ri_unknown_polls=0
	_ri_unanswered=""
	while :; do
		installer_finished "$_ri_rc" && break
		if [ "$(date +%s)" -ge "$_ri_deadline" ]; then
			fcc_log "$LOG" "installer timed out after ${FCC_INSTALLER_TIMEOUT}s"
			break
		fi
		_ri_line="$(installer_last_line)"
		if _ri_ans="$(installer_answer_for "$_ri_line" "$_ri_agents" "$_ri_mode")"; then
			_ri_unknown=""
			_ri_unknown_polls=0
			case "$_ri_answered" in
				*"|$_ri_line|"*)
					_ri_stuck=1
					fcc_log "$LOG" "installer re-asked a question already answered; no selected agent can be installed"
					break
					;;
			esac
			_ri_answered="$_ri_answered|$_ri_line|"
			fcc_log "$LOG" "installer prompt answered: $_ri_line -> $_ri_ans"
			# Enter or not is part of the answer, not a detail of sending it:
			# see installer_answer_is_keypress().
			if installer_answer_is_keypress "$_ri_line"; then
				tmux send-keys -t "$(installer_session)" "$_ri_ans" 2>/dev/null
			else
				tmux send-keys -t "$(installer_session)" "$_ri_ans" Enter 2>/dev/null
			fi
		else
			# Nothing in the table matches this line. Most of what the installer
			# prints has no rule and should have none — step banners, progress
			# lines — and those are gone by the next poll, so their staying is
			# not a signal.
			#
			# A question is different. Upstream asks all of its questions
			# through prompt_yes_no(), which prints "<question> [y/N] " (or
			# [Y/n]) and then blocks on the read; the question therefore holds
			# the bottom of the pane until somebody answers it. An unrecognised
			# question is not a lull — it is a deadlock, and the only thing that
			# ends it is the deadline above: half an hour later, with the
			# rollback and no reason recorded. That is exactly what upstream's
			# RTK reword cost, so an unrecognised question is now counted and
			# reported in seconds instead. See DESIGN_SPEC.md section 104.16.
			#
			# The marker is upstream's own prompt, and it is the whole marker
			# set: the installer has exactly two places that ask anything
			# (select_coding_agent and the RTK question) and both go through
			# prompt_yes_no(). A line that ends in one of these is a question
			# waiting for an answer, whatever it is about.
			case "$_ri_line" in
				*'[y/N]'*|*'[Y/n]'*)
					if [ "$_ri_line" = "$_ri_unknown" ]; then
						_ri_unknown_polls=$(( _ri_unknown_polls + 1 ))
					else
						_ri_unknown="$_ri_line"
						_ri_unknown_polls=1
					fi
					if [ "$_ri_unknown_polls" -ge "$FCC_PROMPT_STALL_POLLS" ]; then
						_ri_unanswered="$_ri_line"
						fcc_log "$LOG" "installer is waiting on a question this package does not recognise: $_ri_line"
						break
					fi
					;;
			esac
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
	# A question we could not answer. The question is printed in full because it
	# is the only thing that says which rule is missing — upstream's own
	# transcript has it, but that is a terminal screen in a file the reader has
	# to go find, and the job log is where they are already looking. The line
	# that ends this output is the marker, matching the shape of the others.
	[ -n "$_ri_unanswered" ] && {
		printf 'The installer asked a question this package does not know how to answer:\n'
		printf '  %s\n' "$_ri_unanswered"
		printf 'Nothing was installed. Please report this — the question above is the whole diagnosis.\n'
		printf 'PROMPT_NOT_RECOGNISED\n'
	}
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
		#
		# fcc_agent_installed with the root, not a bare `command -v`. This
		# function happens to run with the runtime environment applied, so the
		# agent's CLI is on PATH here — but that is a property of the caller,
		# not of the question, and the answer must not depend on which of the
		# two a future caller is.
		printf ',\n  "agents": {'
		_wm_sep=""
		while IFS='|' read -r _wm_id _wm_rest; do
			case "$_wm_id" in ''|\#*) continue ;; esac
			fcc_agent_installed "$_wm_id" "$ROOT" || continue
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
			fcc_agent_installed "$_wm_id" "$ROOT" || continue
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
	# Whether there is a previous runtime to put back — a question about the
	# backup's *contents*, not about whether a backup directory exists.
	#
	# The condition used to be `[ -z "$_rb_dir" ] && [ ! -f runtime.json ]`, and
	# the first half is what made the report wrong. It asked for an *empty*
	# backup directory, which a first install never has: fcc_ensure_dirs()
	# creates data/ before anything else runs, so backup_runtime() always finds
	# something to keep and always returns a directory. A retry on a box whose
	# first install had already failed therefore skipped this branch, took the
	# restore path below, restored nothing, found no bin/fcc-server to run, and
	# ended on "FCC Server remains stopped. Please inspect logs." +
	# ROLLBACK_FAILED — section 79's wording for a restore that failed, printed
	# when there was nothing to restore. Every retry repeated it, and the
	# installer's own error stayed hidden behind it.
	#
	# So: is there anything in the backup that could be a runtime? Two files say
	# so, and both are written only by an install that got all the way through.
	#
	#   runtime.json    written by write_runtime_metadata() once the new runtime
	#                   has been verified, so it exists only where an install
	#                   succeeded — and it is the version section 79's message
	#                   names, which is why the backup copies it at all.
	#   bin/fcc-server  the launcher the upstream tool install produces. Nothing
	#                   else in this package writes it.
	#
	# What cannot be used is the mere presence of runtime/ or bin/ in the
	# backup, however much it looks like it should be: fcc_ensure_dirs() creates
	# both empty on every run, so they are always there, and a first install
	# that got part-way leaves a non-empty pair that cannot be told from a
	# working one by looking. The empty pair is exactly what a retry on the
	# reported box had, and reading it as a previous runtime is the bug.
	#
	# The trade this makes: a first install that failed *after* the tool install
	# leaves a bin/fcc-server behind, and is then treated as a previous runtime.
	# Its restore is attempted and, if that launcher turns out to run, reported
	# as one. The wording is then generous, but the alternative — discarding a
	# runtime that may well work, on a device where reinstalling it costs
	# several hundred megabytes and ten minutes — is the worse error.
	_rb_had=0
	if [ -n "$_rb_dir" ] && [ -d "$_rb_dir" ]; then
		[ -f "$_rb_dir/runtime.json" ] && _rb_had=1
		[ -x "$_rb_dir/bin/fcc-server" ] && _rb_had=1
	fi
	# A runtime.json still in place says the same thing about the box itself: an
	# update copies it into the backup rather than moving it, so it outlives the
	# failed attempt that followed.
	[ -f "$ROOT/runtime.json" ] && _rb_had=1

	if [ "$_rb_had" -eq 0 ]; then
		# runtime/ and bin/ are what the installer writes, and a partial one is
		# worse than none: the status page would report an install that cannot
		# run. They are the same two directories the update path removes, so the
		# destructive surface is unchanged. data/ is left alone — it is not this
		# installer's to discard, and on a reinstall attempt it may hold provider
		# credentials the user entered through FCC's own admin page.
		rm -rf "$ROOT/runtime" "$ROOT/bin" 2>/dev/null
		fcc_cache_set fcc_version ""
		# The backup directory this attempt created is not consumed by anything
		# below, so without this it would never be reached by section 25's
		# retention: a device that keeps failing and keeps being retried would
		# keep a fresh copy of data/ per attempt, on the very device whose free
		# space is the reason the install stopped.
		prune_backups
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
	_cr_all=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--agents)   _cr_agents="$(printf '%s' "${2:-}" | tr ',' ' ')"; shift 2 ;;
			--agents=*) _cr_agents="$(printf '%s' "${1#--agents=}" | tr ',' ' ')"; shift ;;
			# Every agent in the registry. The Configuration page installs the
			# whole set (section 104.25), and it asks for that by name rather
			# than by listing the ids, so the registry stays the one place the
			# set is written down.
			--all-agents) _cr_all=1; shift ;;
			# Section 3.6.5 lets the user uncheck every agent. That is a
			# different request from "no opinion, use the defaults", and an
			# empty --agents cannot express it, so it gets its own flag.
			--no-agents) _cr_none=1; shift ;;
			*) shift ;;
		esac
	done

	# After the loop, so an explicit --agents wins over it whatever order the
	# two arrive in.
	[ "$_cr_all" = 1 ] && _cr_agents="$(fcc_all_agents)"

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

	# --- Node.js, for the agents that are npm packages ---------------------
	# Pi, DeepSeek Harness and Cline are all npm packages, all of them want a
	# Node this image's own node is below, and the Pi installer's remedy —
	# nodejs.org/dist — publishes no musl build, so what it leaves behind cannot
	# execute here at all. Section 104.29 has the measurements. Upstream stops
	# at the first agent that fails and rolls the whole run back, so this is not
	# one agent's problem: without a Node that runs, no install completes.
	#
	# Fetching one first is skipped entirely when the box already has what they
	# need, which is what happens on every run after the first.
	#
	# A failure here does not stop the install. The agents that needed it will
	# fail a moment later with upstream's own reason in the transcript, and that
	# is a better report than one this function could write — it names the agent
	# and what it was doing. See the comment on provision_node().
	_cr_node_wanted=""
	if [ "$_cr_none" = 1 ]; then
		: # --no-agents: nothing is being installed, so nothing needs a Node
	elif [ -n "$_cr_agents" ]; then
		_cr_node_wanted="$(fcc_node_agents_in "$_cr_agents")"
	else
		# No selection means upstream's own answers, and upstream's default for
		# every agent it does not already find is yes — so all of them.
		_cr_node_wanted="$(fcc_node_agents_in "$FCC_NODE_AGENTS")"
	fi
	_cr_node_missing=""
	for _cr_node_id in $_cr_node_wanted; do
		fcc_node_ok_for "$_cr_node_id" || _cr_node_missing="$_cr_node_missing $_cr_node_id"
	done
	if [ -n "${_cr_node_missing# }" ]; then
		provision_node "${_cr_node_missing# }"
	fi

	# --- section 23 step 9: update ----------------------------------------
	run_installer "$_cr_script" "$_cr_agents" "$_cr_none"
	_cr_rc=$?

	if [ "$_cr_rc" -ne 0 ]; then
		fcc_log "$LOG" "installer exited with status $_cr_rc; see logs/installer.out"
		# And what the installer said about it. The transcript is the only place
		# the reason exists, and until now nothing copied it anywhere a reader
		# could reach: the log named a file the Logs panel did not offer, so a
		# failed install was reported as a status number and no cause. The
		# installer writes "error: ..." for every failure it knows about, and
		# that line is quoted here verbatim so the panel shows it.
		_cr_reason="$(installer_failure_reason "$ROOT/logs/installer.out" 2>/dev/null || true)"
		[ -n "$_cr_reason" ] && fcc_log "$LOG" "installer reported: $_cr_reason"
		# The installer's line names the agent and an exit code and stops there.
		# The host it could not reach is read out of the script that just ran, so
		# this has to happen before the script is deleted — hence the rm below,
		# in both paths rather than once above the branch.
		installer_explain_failure "$_cr_script" "$_cr_reason" "$ROOT/logs/installer.out"
		rm -f "$_cr_script"
		rollback_runtime "$_cr_backup" "$_cr_was_running"
		fcc_lock_release "$_cr_lock"
		return "$_cr_rc"
	fi
	rm -f "$_cr_script"

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

# Reinstall: remove the runtime and put it back with every agent.
#
# Why this is not simply "install again". The upstream installer *reconciles*
# the agent set rather than reinstalling it: an agent that is already present is
# not asked about again, and the only lever this package has over the set is
# which agents it requests — that is how agent.sh remove works, by re-running
# the installer with a smaller set. So there is no way to ask upstream to
# reinstall an agent that is already there, and the only operation that
# genuinely reinstalls them is to remove the runtime that carries them and
# install it again.
#
# The configuration and the user data are kept: this is the same no-purge
# uninstall the page's Uninstall button performs, so sessions, configuration and
# backups survive. What it costs is the runtime itself — if the download then
# fails there is nothing left to fall back to, which is why this is a separate
# button rather than what "Install" does. Section 103: what this cannot do is
# reinstall one agent on its own, and it does not claim to.
cmd_reinstall() {
	fcc_log "$LOG" "reinstall requested: removing the runtime, keeping data"
	cmd_uninstall || return 1
	cmd_runtime --all-agents
}

case "${1:-}" in
	runtime)   shift; cmd_runtime "$@" ;;
	reinstall) cmd_reinstall ;;
	uninstall) shift; cmd_uninstall "$@" ;;
	check)     check_report ;;
	*) echo "usage: install.sh {runtime [--agents a,b] [--all-agents] | reinstall | uninstall [--purge] | check}" >&2; exit 2 ;;
esac
