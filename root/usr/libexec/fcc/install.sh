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
#   install.sh cleanbackups               Delete the saved backups (keeps everything else)
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

precheck_packages() {
	# Section 3.6.4's fourth answer, made actionable: the checks that a package
	# would satisfy name the package, and this is the list. Empty unless
	# installing packages is the whole of what stands between this box and a
	# passing report — on a box whose storage is short, adding tar would not
	# unblock anything, and changing the system to no purpose is not a kindness.
	"${FCC_LIBDIR:-/usr/libexec/fcc}/doctor.sh" --packages 2>/dev/null
}

install_prerequisite_packages() {
	# Add the missing prerequisites before the gate is asked a second time.
	#
	# The gate used to be the end of the road: a FAIL meant an install stopped
	# before anything was downloaded, with a suggestion the user had to go and
	# type into a shell and then start the install again. Every one of those
	# packages — tar, bash, the Coreutils applets, the C++ runtime — is an
	# ordinary feed package, so the install can simply add it. Measured on the
	# test router: an install of every agent stopped at four of these at once
	# and installed nothing.
	#
	# The report is asked again afterwards rather than trusted to have been
	# fixed: a package manager that fails has its own reasons (no network, no
	# room, a package the feed does not carry), and the check that is still
	# failing is what names them to the user. It is also what keeps this from
	# being a second veto — the gate below is still the only thing that decides.
	#
	# Returns 2 when there was nothing to install, so the caller can tell that
	# from an install that succeeded: the report would come back identical and
	# asking it again would only repeat its HTTPS probe.
	_ipr_pkgs="$(precheck_packages)"
	[ -n "$_ipr_pkgs" ] || return 2

	_ipr_list="$(printf '%s ' $_ipr_pkgs)"
	fcc_log "$LOG" "preflight: installing prerequisites:${_ipr_list% }"
	if _ipr_out="$(fcc_pkg_install $_ipr_pkgs 2>&1 </dev/null)"; then
		fcc_log "$LOG" "preflight: installed${_ipr_list% }"
		return 0
	fi
	# The package manager's own last words, so a package that could not be
	# fetched or unpacked says why. The failing check below still names the
	# missing tool and the package; this is the evidence underneath it.
	printf '%s\n' "$_ipr_out" | tail -n 20 | while IFS= read -r _ipr_line; do
		[ -n "$_ipr_line" ] && fcc_log "$LOG" "  $_ipr_line"
	done
	return 1
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

precheck_blocked() {
	# The install is not going to start. Say what stopped it, in the log, and
	# answer the caller with the single machine-readable token it matches on.
	#
	# The report goes into the log and nowhere else. When this runs as a job its
	# stdout *is* that same file, so echoing it here as well would print the
	# whole thing twice; and the log is where both readers look — the job panel
	# tails it, and it is what a person opens when the install stops. One
	# fcc_log call per line, so each keeps its own timestamp and gets redacted
	# like every other entry.
	fcc_lock_release "$_cr_lock"
	fcc_log "$LOG" "install aborted: compatibility precheck failed"
	_cr_blocked="$(precheck_failures)"
	if [ -n "$_cr_blocked" ]; then
		printf '%s\n' "$_cr_blocked" | while IFS= read -r _cr_line; do
			fcc_log "$LOG" "$_cr_line"
		done
	fi
	printf 'PRECHECK_FAILED\n'
	return 1
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

# Can a single key be read on this box at all?
#
# Pi's action menu is the one question in the install that is read a byte at a
# time, and it can only be read that way because read_tty_key() first puts the
# terminal into raw mode:
#
#     stty -icanon -echo min 1 time 0 < /dev/tty 2>/dev/null || true
#     key=$(dd bs=1 count=1 2>/dev/null < /dev/tty)
#
# Both the stty call and its failure are discarded, so a box without stty does
# not fail here — it changes shape. The terminal stays canonical, dd waits for
# a line delimiter instead of for a byte, and a key sent on its own is never
# read.
#
# That is not hypothetical. The test router's BusyBox is built without the stty
# applet — `busybox --list` has no stty and `busybox stty` answers "applet not
# found" — so on 2026-10-17 the menu was answered with a bare "y", the "y" sat
# echoed in the canonical line buffer, and the install waited on it until
# FCC_INSTALLER_TIMEOUT rolled the whole run back: thirty minutes of nothing,
# the page's progress bar parked, and nothing in the log that named the menu.
# Every other question is line-based already — upstream's prompt_yes_no() is
# `IFS= read -r answer <&3` and the upstream installer never calls stty at all
# — which is why the menu was the only one that hung (§104.31).
fcc_installer_can_read_a_key() {
	command -v stty >/dev/null 2>&1
}

# What ends an answer, when the answer is a bare key.
#
# Every other question here is read a line at a time, and Enter is what ends it.
# Pi's action menu is not: where it can reach raw mode it reads exactly one byte
# (dd bs=1 count=1), and an Enter sent after the key is not consumed by the menu
# at all. It stays in the terminal's input queue and is read by the *next*
# prompt — "Start pi now? [Y/n]", whose default is yes. Pi's own interface then
# starts in the pane, never exits, and the install sits there until the deadline
# and rolls back. Sending the key alone is what keeps that Enter from existing.
#
# Where raw mode is not reached, though, the key alone is never read, and the
# answer has to be terminated. Which delimiter terminates it is the whole
# question, and the obvious one is the wrong one:
#
#   * A newline is kept in the line it delivers. Canonical mode hands the reader
#     the line *including* its delimiter, so `dd bs=1 count=1` takes the key and
#     leaves the newline sitting in the queue — and the next prompt to read is
#     "Start pi now?", which gets the empty answer that leftover makes. Empty is
#     not "no", so Pi's interface starts and the install hangs exactly as it did
#     before, only one prompt later (§104.32).
#
#   * Ctrl-D is discarded. It is the terminal's EOF character, and the line
#     discipline delivers the pending line *without* it and consumes it, so the
#     menu gets its key and the input queue is left empty. The loop's own rule
#     for "Start pi now?" then gets its turn and answers "n".
#
# Measured against a pty in canonical mode, which is what the router's pane is
# (no stty there, so Pi never leaves canonical mode):
#
#     bare y        dd exits 124, reads nothing    -> the menu waits forever
#     y + Enter     dd reads "y", next read is ""  -> Pi's interface starts
#     y + Ctrl-D    dd reads "y", next read blocks -> the loop answers it
installer_answer_terminator() {
	# installer_answer_terminator <line> -> the key to press after the answer,
	# or nothing when the answer is complete on its own.
	installer_line_is_pi_menu "$1" || { printf 'Enter'; return 0; }
	fcc_installer_can_read_a_key || printf 'C-d'
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
		# y installs, u uninstalls, n does nothing. What is sent after the key
		# is the terminal's business, not the answer's; see
		# installer_answer_terminator().
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
			# An agent this system cannot install is declined even in "no
			# opinion" mode, where every other question gets upstream's own
			# answer (yes for an agent that is not already there). cmd_runtime
			# has already removed it from an explicit set; this is the other
			# half, for the set nobody wrote down.
			if [ -n "$_iaf_id" ]; then
				case " ${FCC_AGENT_SKIP:-} " in
					*" $_iaf_id "*) printf 'n'; return 0 ;;
				esac
			fi
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
# The destination is the directory upstream's own PATH entry already names —
# <root>/data/.local/share/pi-node — and `current` is what that entry points
# through, the same shape the Pi installer leaves when it works. Nothing
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

	# Derived from the install root, never from the environment.
	#
	# This function is called by cmd_runtime *before* run_installer, and
	# run_installer is what applies the runtime environment — so at this point
	# on a router neither XDG_DATA_HOME nor HOME has been set yet. The obvious
	# spelling of this line, ${XDG_DATA_HOME:-$HOME/.local/share}/pi-node, is
	# therefore fatal under `set -u`: the default word is expanded to decide
	# whether to use it, so an unset $HOME inside it aborts the whole script
	# even though the fallback is the branch that would have been taken. It
	# ended a real install at this line on 2026-10-16 with "HOME: parameter not
	# set", after the installer had been downloaded (§104.30).
	#
	# fcc_runtime_env_value is the same mapping apply_runtime_env exports, so
	# the Node lands where the PATH entry in fcc_runtime_bin_dirs() already
	# looks for it, whether or not the environment is set at the time.
	_pn_base="$(fcc_runtime_env_value "$ROOT" XDG_DATA_HOME)/pi-node"

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

	# On disk is not the same as runnable, and this is where the difference was
	# being lost. The musl build is linked against libstdc++.so.6 and
	# libgcc_s.so.1, a stock image has neither, and a Node that cannot load
	# still extracts, still has the right name, and still passes every check
	# that only looks at the filesystem — so the run reported "installed
	# v22.23.3" over a binary that died in the loader, and the install then
	# failed at the first npm agent with the reason 1064 lines into the
	# transcript. Measured on the test router on 2026-10-19; common.sh carries
	# the rest.
	#
	# Asked *before* `current` is moved, so a build that does not run leaves the
	# pointer where it was rather than aiming it at a broken tree. The answer is
	# the binary's own, not a guess from the file list: the loader writes its
	# reason to stderr and this is that sentence.
	_pn_run=""
	if ! _pn_run="$("$_pn_dir/bin/node" --version 2>&1)"; then
		_pn_why="$(printf '%s\n' "$_pn_run" | awk 'NR == 1 { print; exit }')"
		fcc_log "$LOG" "node: the build fetched for $_pn_names does not run here: ${_pn_why:-no output}"
		# The library is named only when it is actually the one missing. On a
		# box that has it, the reason is something else — a CPU whose musl build
		# was mislabelled, a truncated download that still matched nothing — and
		# a log that blamed libstdc++ there would send the reader to install a
		# package they already have.
		_pn_missing="$(fcc_node_missing_libs)"
		if [ -n "$_pn_missing" ]; then
			fcc_log "$LOG" "node: this image has no $_pn_missing where the loader looks; $(fcc_pkg_install_hint "$(fcc_node_lib_packages $_pn_missing)") provides it"
		fi
		rm -rf "$_pn_tmp" "$_pn_dir" 2>/dev/null
		return 1
	fi

	rm -f "$_pn_base/current" 2>/dev/null
	if ! ln -s "$_pn_dir" "$_pn_base/current" 2>/dev/null; then
		fcc_log "$LOG" "node: could not point $_pn_base/current at $_pn_dir"
		rm -rf "$_pn_tmp" "$_pn_dir"
		return 1
	fi
	rm -rf "$_pn_tmp" 2>/dev/null
	fcc_log "$LOG" "node: installed $_pn_v (musl, $_pn_arch) at $_pn_dir, and it runs"
	return 0
}

# Where the installer's ldd stand-in lives.
installer_shim_dir() { printf '%s' "$ROOT/shim"; }

# Put the ldd stand-in where the pane will find it, and say whether it is there.
#
# OpenCode's installer decides which build to download by asking `ldd --version`
# whether the libc is musl, and it asks under `set -o pipefail`:
#
#     if ldd --version 2>&1 | grep -qi musl; then is_musl=true; fi
#
# On musl that pipeline reports failure even though grep matched, and not for
# the reason it looks like: /usr/bin/ldd is a symlink to ../../lib/libc.so — it
# *is* the dynamic loader — and asked for --version it prints its banner to
# stderr and exits 1, reading the request as a usage error. grep does match and
# does exit 0; pipefail is what turns ldd's 1 into the pipeline's status. So
# is_musl stays false, the target comes out linux-x64 instead of linux-x64-musl,
# and the glibc binary that gets installed cannot even exec here: it wants
# /lib64/ld-linux-x86-64.so.2 and this box has only /lib/ld-musl-x86_64.so.1.
#
# Upstream stops at the first agent it cannot verify, so that one wrong answer
# ends the whole run — the runtime is never installed and the page reports a
# failure whose only visible line is about OpenCode. Section 104.33 has the
# measurement; ldd-shim has the fix, and this puts it on the pane's PATH.
installer_prepare_shim() {
	_ip_src="${FCC_LIBDIR:-/usr/libexec/fcc}/ldd-shim"
	_ip_dst="$(installer_shim_dir)/ldd"
	[ -f "$_ip_src" ] || return 1
	mkdir -p "$(installer_shim_dir)" 2>/dev/null || return 1
	# Copied rather than symlinked: the pane's PATH is what decides which ldd is
	# found, and a symlink would leave the answer depending on the package still
	# being installed at that path.
	cp "$_ip_src" "$_ip_dst" 2>/dev/null || return 1
	chmod 755 "$_ip_dst" 2>/dev/null || return 1
	[ -x "$_ip_dst" ]
}

# A launcher that runs nothing is worse than no launcher at all.
#
# Upstream's chooser asks `command -v <id>` and reads a hit as "already
# installed": it skips the question, then verifies the command and aborts the
# whole run if it cannot start. So one broken launcher fails *every* later
# install, whatever was selected. That is what happened on 2026-10-22 — the
# user asked for Grok Build and the run died with
#
#   error: Command failed with exit code 127: /opt/fcc/data/.local/bin/hermes
#
# — because a Hermes install interrupted after publishing its ~/.local/bin
# wrapper (a disk-full update is in the same log minutes earlier) left a
# two-line shell script pointing at a tree that is not there. Neither Uninstall
# nor Reinstall helped: both keep data/, which is where the wrapper lives.
#
# So before the installer starts, any launcher in this runtime's bin
# directories that provably cannot run is moved aside. Upstream then sees the
# agent as absent and asks about it like any other, which is what lets this
# package's answer loop skip an agent nobody selected. The file is renamed
# rather than deleted: it is the only trace of the interrupted install, and
# "broken" here is decided structurally, never by running the agent — Hermes'
# own --version hangs, which is why its probe column is empty.
installer_launcher_target() {
	# installer_launcher_target <launcher> -> the absolute path its exec
	# line runs, when the launcher is a shell script that runs one.
	_ilt_head="$(head -n 1 "$1" 2>/dev/null)"
	case "$_ilt_head" in
		'#!/bin/sh'|'#!/bin/ash'|'#!/bin/bash'|\
		'#!/usr/bin/env sh'|'#!/usr/bin/env ash'|'#!/usr/bin/env bash') ;;
		*) return 1 ;;
	esac
	_ilt_t="$(sed -n 's/^[[:space:]]*exec[[:space:]][[:space:]]*\([^[:space:]]*\).*/\1/p' "$1" 2>/dev/null | head -n 1)"
	# A bare word ("exec node ...") is not judged: it may resolve anywhere, and
	# deciding otherwise would need a PATH that a future shell may not share.
	case "$_ilt_t" in
		/*) printf '%s' "$_ilt_t"; return 0 ;;
	esac
	return 1
}

installer_quarantine_broken_launchers() {
	while IFS= read -r _iql_d; do
		[ -d "$_iql_d" ] || continue
		while IFS= read -r _iql_line; do
			_iql_id="${_iql_line%%|*}"
			[ -n "$_iql_id" ] || continue
			_iql_f="$_iql_d/$_iql_id"
			# A dangling symlink fails -f, and is exactly as broken as the
			# wrapper below; both are handled here, and neither is followed
			# into a directory that does not exist.
			if [ -L "$_iql_f" ]; then
				[ -e "$_iql_f" ] && continue
				_iql_why="it is a symlink to $(readlink "$_iql_f" 2>/dev/null), which does not exist"
			elif [ -f "$_iql_f" ]; then
				_iql_t="$(installer_launcher_target "$_iql_f")" || continue
				[ -n "$_iql_t" ] || continue
				[ -x "$_iql_t" ] && continue
				_iql_why="it runs $_iql_t, which is missing"
			else
				continue
			fi
			_iql_new="${_iql_f}.broken-$(date +%Y%m%dT%H%M%SZ)"
			[ -e "$_iql_new" ] && _iql_new="$_iql_new.$$"
			if mv -f "$_iql_f" "$_iql_new" 2>/dev/null; then
				fcc_log "$LOG" "installer: moved a broken launcher aside: $_iql_f ($_iql_why), so the agent counts as not installed and the installer asks about it again"
			fi
		done <<EOF
$(fcc_agents_each)
EOF
	done <<EOF
$(fcc_runtime_bin_dirs "$ROOT")
EOF
}

# Which Codex download the installer should try first.
#
# Codex's own installer starts at releases.openai.com. Its asset download is
# capped at 300 seconds and the asset is 159 MB; when the host delivers a few
# KB/s the cap fires after a couple of megabytes, and the retry is the same
# file from GitHub Releases. That retry has no timeout at all: on a 24.10.8
# box it transferred 2.8 MB in five minutes from the first host and then sat
# on the second until this package's own 30-minute deadline rolled the install
# back; a second run installed in five minutes. The source is an environment
# variable inside Codex's own installer, so the pane's environment can choose
# it.
#
# The choice is measured, not assumed. Both hosts are asked for the first
# three megabytes of the same asset for five seconds, and GitHub is chosen
# only when it is both fast enough to finish on its own (at least 1 MB in
# those five seconds) and at least twice what releases.openai.com delivered.
# Anything else — an unresolvable version, an unknown architecture, a slow or
# missing host — leaves upstream's first choice exactly where it was, so a
# box whose Codex download already worked cannot be sent somewhere worse.
#
# -f and -L are both load-bearing. GitHub does not serve release assets itself:
# /releases/download/ answers 302 and the bytes come from a second host, so a
# probe that does not follow the redirect measures 0 there on every box and
# would report GitHub as dead on exactly the routers that need it. Measured on
# the test router: without -L, 0 bytes; with -L, the whole 3 MB range in under
# five seconds. That is what Codex's own downloader does (it uses curl -fL), so
# the probe follows the same path the real download will.
installer_codex_probe_bytes() {
	# installer_codex_probe_bytes <url> -> bytes fetched in five seconds
	curl -fsSL -o /dev/null --range 0-3145727 \
		--connect-timeout 5 --max-time 5 -w '%{size_download}' "$1" 2>/dev/null || :
}

installer_codex_prefers_github() {
	# installer_codex_prefers_github <agents> <mode>
	_icpg_agents="$1"
	_icpg_mode="$2"
	case "$_icpg_mode" in
		default) : ;;
		set)
			case " $_icpg_agents " in
				*" codex "*) : ;;
				*) return 1 ;;
			esac
			;;
		*) return 1 ;;
	esac
	command -v curl >/dev/null 2>&1 || return 1
	# Codex supports these two targets and exits on anything else, so there is
	# nothing to choose for an architecture it will refuse to install on.
	_icpg_arch="$(uname -m 2>/dev/null)"
	case "$_icpg_arch" in
		x86_64|amd64) _icpg_target=x86_64-unknown-linux-musl ;;
		arm64|aarch64) _icpg_target=aarch64-unknown-linux-musl ;;
		*) return 1 ;;
	esac
	# The tag names the version both hosts publish under. No tag, no opinion.
	_icpg_tag="$(curl -fsS --connect-timeout 5 --max-time 15 \
		"https://api.github.com/repos/openai/codex/releases/latest" 2>/dev/null \
		| grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
		| sed 's/.*"\([^"]*\)"$/\1/')"
	case "$_icpg_tag" in
		rust-v*) _icpg_ver="${_icpg_tag#rust-v}" ;;
		*) return 1 ;;
	esac
	_icpg_asset="codex-package-$_icpg_target.tar.gz"
	_icpg_ob="$(installer_codex_probe_bytes \
		"https://releases.openai.com/codex/releases/$_icpg_ver/$_icpg_asset")"
	_icpg_gb="$(installer_codex_probe_bytes \
		"https://github.com/openai/codex/releases/download/$_icpg_tag/$_icpg_asset")"
	case "$_icpg_ob" in ''|*[!0-9]*) _icpg_ob=0 ;; esac
	case "$_icpg_gb" in ''|*[!0-9]*) _icpg_gb=0 ;; esac
	# 1 MB in five seconds is 200 KB/s, which finishes 159 MB inside this
	# package's own 30-minute deadline. Below that GitHub cannot do the job
	# either, so the default is left alone rather than made slower.
	[ "$_icpg_gb" -ge 1048576 ] || return 1
	# And it has to beat the first choice clearly. Equal or merely similar
	# speeds keep upstream's order; this only reroutes a box whose first host
	# has already shown it is the slow one.
	[ "$_icpg_gb" -gt $((_icpg_ob * 2)) ] || return 1
	fcc_log "$LOG" "installer: starting Codex at GitHub Releases (five-second probe: ${_icpg_ob} bytes from releases.openai.com, ${_icpg_gb} from GitHub)"
}

# The environment the installer pane sources, in one place so that the PATH the
# pane gets can be read and tested without starting a terminal.
installer_write_env() {
	# installer_write_env <path> [<agents> <mode>]
	fcc_runtime_env_exports "$ROOT" > "$1" 2>/dev/null || return 1
	# Appended, so that the shim directory is prepended to the PATH those
	# exports already built — and so that a box without the shim file is left
	# with exactly the environment it had before.
	if installer_prepare_shim; then
		printf 'export PATH=%s:"$PATH"\n' \
			"$(fcc_shquote "$(installer_shim_dir)")" >> "$1" 2>/dev/null || return 1
	fi
	if installer_codex_prefers_github "${2:-}" "${3:-}"; then
		printf 'export CODEX_INSTALLER_USE_RELEASES_OPENAI_COM=false\n' \
			>> "$1" 2>/dev/null || return 1
	fi
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
	# Before anything asks upstream what is installed: a launcher that cannot
	# run is a false "already installed", and upstream aborts the run on it.
	installer_quarantine_broken_launchers

	# Section 103: the one question in the install that cannot be asked the same
	# way on every box is Pi's action menu, and when it is asked the other way
	# the run looks like nothing but a stall. Say which way it went, so that a
	# log read afterwards names the terminal instead of leaving the reader to
	# guess at a menu that is not in the transcript.
	#
	# The probe sits after apply_runtime_env() rather than before it on purpose:
	# installer_answer_terminator() is called from the answer loop further down,
	# which runs with the PATH that call has just set, so this asks the question
	# of the same PATH the decision will be made with.
	if fcc_installer_can_read_a_key; then
		fcc_log "$LOG" "installer: stty is present, so Pi's action menu is answered by the key alone"
	else
		fcc_log "$LOG" "installer: no stty on this box, so Pi's action menu is answered by a key and Ctrl-D"
	fi

	# The terminal must start with this environment, and a tmux session inherits
	# the *server's* environment rather than the environment of whatever asked
	# for the session — so a session created against a server that is already
	# running for the Web Console would start with the console's HOME, not this
	# one, and install a second runtime into it. Sourcing a file is what makes
	# the environment certain rather than likely.
	installer_write_env "$_ri_env" "$_ri_agents" "$_ri_mode" || {
		fcc_log "$LOG" "failed to write the installer environment"
		return 1
	}

	# Section 103: the shim decides whether OpenCode installs at all on musl, so
	# which way it went is worth a line. A run that fails on OpenCode is then
	# readable afterwards as either "the shim was not there" or "it was, and
	# something else went wrong".
	if [ -x "$(installer_shim_dir)/ldd" ]; then
		fcc_log "$LOG" "installer: ldd --version is answered from $(installer_shim_dir)/ldd, so a musl box is detected as musl"
	else
		fcc_log "$LOG" "installer: no ldd shim on this box, so an installer that asks ldd whether the libc is musl will read the answer wrong"
	fi

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
			# What ends the answer is part of the answer, not a detail of
			# sending it: see installer_answer_terminator().
			_ri_term="$(installer_answer_terminator "$_ri_line")"
			if [ -n "$_ri_term" ]; then
				tmux send-keys -t "$(installer_session)" "$_ri_ans" "$_ri_term" 2>/dev/null
			else
				tmux send-keys -t "$(installer_session)" "$_ri_ans" 2>/dev/null
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

	# Seed the version cache with what was just detected. The callers below clear
	# the cache when a runtime changes, and a cleared entry used to leave the
	# Configuration page showing "—" until the next cache TTL: writing the empty
	# value refreshes the cache file's mtime, so status.sh read it as fresh and
	# skipped the detection that would have filled it in. Status now repairs an
	# empty entry on its own; writing the right value here means it is never
	# empty in the first place, and the page shows the version the moment the
	# install's last poll paints.
	[ -n "$_wm_ver" ] && fcc_cache_set fcc_version "$_wm_ver"
	[ -n "$_wm_ver" ] && fcc_cache_set version_probed_at 0
}

# ---------------------------------------------------------------------------
# Update safety net (DESIGN_SPEC.md section 23 steps 6, 12 and 13)
# The names directly inside a directory, one per line, or nothing if it is not
# there at all. Used to record what an install started with, so that a rollback
# can give back exactly what the attempt added and nothing more.
fcc_dir_children() {
	[ -d "$1" ] || return 0
	for _fdc_e in "$1"/.[!.]* "$1"/*; do
		[ -e "$_fdc_e" ] || [ -L "$_fdc_e" ] || continue
		printf '%s\n' "${_fdc_e##*/}"
	done
}

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

	# What data/ held before the installer runs, by name. A rollback needs this
	# to tell what the attempt added from what the user already had — and names
	# cost no space, which matters because this is written on the device whose
	# free space is the reason an install can fail in the first place (§104.34).
	# Written before the copy below, and independently of whether it succeeds:
	# on a full device the copy of data/ is the part that fails.
	fcc_dir_children "$ROOT/data" > "$_bk_dir/data-before" 2>/dev/null

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

# The runtime tree holds things that are not the runtime.
#
# `uv tool install` puts a tool under UV_TOOL_DIR and the interpreter it runs
# on under UV_PYTHON_INSTALL_DIR, and this package points both at <root>/
# runtime (common.sh, fcc_runtime_env_value). Aider is installed that way, so
# it lives in the tree every install renames aside and, once the install has
# succeeded, deletes. An install that names some other agent then deletes it
# without ever asking: on 2026-10-22 Aider was installed at 07:27 and the
# Configuration page said "Install it from the Configuration page to use it" at
# 07:29, because a Grok install had committed its backup in between. The same
# commit deleted the cpython-3.12 Aider's venv runs on, so the tool and its
# interpreter have to be brought back together.
#
# So what the new runtime does not own is moved out of the backup before the
# backup's copy is deleted: every uv tool except the FCC package itself (that
# one *is* the runtime, and the new one replaced it), every interpreter
# version the new runtime does not have, and every launcher in bin/ the new
# install did not write. A move within one filesystem is a rename, so this
# costs no space the box did not already hold — the space it keeps is an
# installed agent, which is the point.
#
# Called only after the health check. Until then the backup is the rollback
# source, and taking a tool out of it would lose that tool whenever a rollback
# ran.
keep_previous_agent_tools() {
	# keep_previous_agent_tools <backup-dir> -> 0 when something was kept
	_kp_bk="$1"
	_kp_kept=""
	[ -n "$_kp_bk" ] && [ -d "$_kp_bk" ] || return 2
	_kp_rt="$(fcc_dir_runtime)"
	_kp_bin="$(fcc_dir_bin)"
	mkdir -p "$_kp_rt/uv-tools" "$_kp_rt/python" "$_kp_bin" 2>/dev/null

	for _kp_sub in uv-tools python; do
		_kp_src="$_kp_bk/runtime/$_kp_sub"
		[ -d "$_kp_src" ] || continue
		for _kp_e in "$_kp_src"/*; do
			# -L as well as -e: uv keeps a version-less name next to each
			# interpreter as a symlink to the versioned one, and here that
			# symlink is dangling — it points into the live tree, where this
			# install's own Python exists and the one the old tool runs on does
			# not. Skipping it would leave the restored tool with no
			# interpreter name uv knows.
			[ -e "$_kp_e" ] || [ -L "$_kp_e" ] || continue
			_kp_n="${_kp_e##*/}"
			# The FCC package is the runtime this install just replaced.
			if [ "$_kp_sub" = uv-tools ] && [ "$_kp_n" = free-claude-code ]; then
				continue
			fi
			[ -e "$_kp_rt/$_kp_sub/$_kp_n" ] || [ -L "$_kp_rt/$_kp_sub/$_kp_n" ] && continue
			if mv "$_kp_e" "$_kp_rt/$_kp_sub/$_kp_n" 2>/dev/null; then
				_kp_kept="$_kp_kept $_kp_sub/$_kp_n"
			fi
		done
	done

	_kp_src="$_kp_bk/bin"
	if [ -d "$_kp_src" ]; then
		for _kp_e in "$_kp_src"/* "$_kp_src"/.[!.]*; do
			[ -e "$_kp_e" ] || [ -L "$_kp_e" ] || continue
			_kp_n="${_kp_e##*/}"
			[ -e "$_kp_bin/$_kp_n" ] || [ -L "$_kp_bin/$_kp_n" ] && continue
			if mv "$_kp_e" "$_kp_bin/$_kp_n" 2>/dev/null; then
				_kp_kept="$_kp_kept bin/$_kp_n"
			fi
		done
	fi

	[ -n "$_kp_kept" ] || return 1
	fcc_log "$LOG" "kept the tools this install did not replace:$_kp_kept"
	return 0
}

commit_backup() {
	# The update succeeded, so the whole backup is dead weight: the runtime tree
	# was carried forward by keep_previous_agent_tools() where it was the only
	# copy of something, the data copy is no longer needed (the run wrote data/
	# in place and it is what the user is now using), and nothing reads any of it
	# between runs. It goes, rather than being kept and pruned.
	#
	# This is the largest thing an install writes — the copy of data/ measured
	# 273 MB on the test router on 2026-10-21 — and with the backup path being a
	# setting of its own (default /tmp/fcc) the user chose where it would go, not
	# how long it would stay.
	_cb_dir="$1"
	[ -n "$_cb_dir" ] && [ -d "$_cb_dir" ] || return 0
	rm -rf "$_cb_dir" 2>/dev/null \
		&& fcc_log "$LOG" "removed the backup made by this install (${_cb_dir##*/})"
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

close_fcc_sessions() {
	# close_fcc_sessions <root> -> the closed session names on stdout.
	#
	# A Web Console pane execs <root>/bin/fcc-claude, so an open session is one
	# of the processes the upstream installer refuses to run beside — and the
	# installer replaces the launcher that pane is executing, so leaving it
	# running is not an option either. Closing the session is how the console
	# already ends one.
	#
	# The pane's own command line decides. The naming convention
	# (fcc-<agent>-<number>) is this package's, but the tmux server is shared,
	# so a session whose pane is not running something from <root> is not
	# this install's and is left alone.
	_cs_root="$1"
	case "$_cs_root" in */) _cs_root="${_cs_root%/}" ;; esac
	command -v tmux >/dev/null 2>&1 || return 0
	tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null \
		| grep '^fcc-[a-z0-9]\{1,16\}-[0-9]\{3\} ' \
		| while read -r _cs_s _cs_pid; do
			_cs_cmd="$(tr '\0' ' ' < "/proc/$_cs_pid/cmdline" 2>/dev/null)" || continue
			case "$_cs_cmd" in
				*"$_cs_root"/*) : ;;
				*) continue ;;
			esac
			tmux kill-session -t "$_cs_s" 2>/dev/null && printf '%s ' "$_cs_s"
		done
	return 0
}

stop_fcc_processes() {
	# stop_fcc_processes -> 0 when nothing named in FCC_PROCESS_NAMES is left.
	#
	# /etc/init.d/fcc stop ends procd's instance, and now also the detached
	# server the launchers start. What it does not know about is an agent in a
	# console session, which the installer counts as running FCC too. Anything
	# still alive here would make upstream abort the run a moment later, and the
	# rollback that followed would be the only thing the user saw — so the check
	# runs before the installer is executed, and its result is the install's.
	#
	# Both scans are scoped to $ROOT. The processes that block an install are
	# this tree's: procd's server, the one a launcher detached from bin/, and
	# an agent a console pane is running from the same place. A process that
	# merely shares a name — another FCC tree, a developer's own launcher — is
	# not the installer's business and is not signalled.
	_st_closed="$(close_fcc_sessions "$ROOT" 2>/dev/null || true)"
	[ -n "$_st_closed" ] && fcc_log "$LOG" "closed console session(s) for the install: $_st_closed"

	_st_found=""
	for _st_n in $FCC_PROCESS_NAMES; do
		_st_p="$(fcc_process_ids "$_st_n" "$ROOT" 2>/dev/null || true)"
		[ -n "$_st_p" ] || continue
		_st_found="$_st_found $_st_n(PID $(printf '%s' "$_st_p" | tr '\n' ',' | sed 's/,$//'))"
	done
	[ -n "$_st_found" ] || return 0

	fcc_log "$LOG" "stopping FCC process(es) the installer will not run beside:$_st_found"
	if fcc_stop_processes 15 "$ROOT" $FCC_PROCESS_NAMES; then
		fcc_log "$LOG" "stopped them; the installer can run"
		return 0
	fi
	fcc_log "$LOG" "could not stop every FCC process; the installer would abort on them, so it was not started"
	return 1
}

# Remove the entries a failed attempt added to a directory, and nothing else.
#
# <before-file> holds the names the directory had when the attempt started,
# written by backup_runtime(). Anything in the directory now that is not in that
# list arrived during the attempt, so it is the attempt's to give back.
#
# A missing list means the two cannot be told apart, and then nothing is
# removed. That is the deliberate direction to fail in: the reclaim exists to
# give back space, and a reclaim that guessed would be trading a user's data for
# space — the wrong way round on a device where the data is the part that cannot
# be downloaded again.
rollback_reclaim_added() {
	# rollback_reclaim_added <before-file> <dir>
	_rra_before="$1"
	_rra_dir="$2"
	[ -f "$_rra_before" ] || return 0
	[ -d "$_rra_dir" ] || return 0

	_rra_gone=""
	for _rra_e in "$_rra_dir"/.[!.]* "$_rra_dir"/*; do
		[ -e "$_rra_e" ] || [ -L "$_rra_e" ] || continue
		_rra_name="${_rra_e##*/}"
		# The name goes after -e because it is data: one beginning with a dash
		# would otherwise be read by grep as an option.
		grep -Fxq -e "$_rra_name" "$_rra_before" 2>/dev/null && continue
		rm -rf "$_rra_e" 2>/dev/null && _rra_gone="$_rra_gone $_rra_name"
	done

	# Named, not silent: the install runs while the user is looking at the page,
	# and anything they put in data/ in the meantime went with this.
	[ -n "$_rra_gone" ] && fcc_log "$LOG" \
		"reclaimed what the failed attempt added to ${_rra_dir##*/}:$_rra_gone"
	return 0
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
	# Whether the data this function puts back is in place. A restore that could
	# not copy it (a full device is exactly the case this path runs on) leaves
	# the backup's copy as the only one, so the cleanup below must not delete it.
	_rb_data_ok=1

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
		# destructive surface is unchanged.
		rm -rf "$ROOT/runtime" "$ROOT/bin" 2>/dev/null
		# data/ itself is not this installer's to discard, and the backup's copy
		# is not put over it: it may hold provider credentials the user entered
		# through FCC's own admin page, and the copy in the backup is older than
		# those. But the agents install into HOME, which *is* data/ — so leaving
		# all of data/ alone leaves the whole download behind. Measured on the
		# test router on 2026-10-18: a run that failed at OpenCode left 1228 MB
		# in data/, and free space fell from 1731 MB to 440 MB — under
		# FCC_MIN_FREE_MB, so the storage precheck refused every retry on a box
		# whose space the failed attempt was holding. Only what was not there
		# when the attempt began goes (§104.34).
		# Only with a backup directory. backup_runtime() returns empty when it
		# could not even make one — which is what a full device does, the very
		# case this reclaim exists for — and an empty $_rb_dir would make the
		# argument below "/data-before": a path outside this package's root, read
		# as though it were this attempt's record. Nothing was recorded in that
		# case anyway, so there is nothing to reclaim from.
		if [ -n "$_rb_dir" ]; then
			rollback_reclaim_added "$_rb_dir/data-before" "$ROOT/data"
		fi
		fcc_cache_set fcc_version ""
		fcc_cache_set version_probed_at 0
		# The copy this attempt made has been consumed — the reclaim above has
		# already read the one thing in it that was wanted — and there is no
		# previous runtime to put back, so it goes rather than waiting for
		# section 25's retention: a device that keeps failing and keeps being
		# retried would otherwise keep a fresh copy of data/ per attempt, on the
		# very device whose free space is the reason the install stopped.
		if [ -n "$_rb_dir" ] && [ -d "$_rb_dir" ]; then
			rm -rf "$_rb_dir" 2>/dev/null && fcc_log "$LOG" \
				"removed the backup this failed install made (${_rb_dir##*/})"
		fi
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
			cp -a "$_rb_dir/data" "$ROOT/data" 2>/dev/null || _rb_data_ok=0
		fi
		[ -f "$_rb_dir/runtime.json" ] && cp "$_rb_dir/runtime.json" "$ROOT/runtime.json" 2>/dev/null
	fi

	# Section 25's retention applies to failed updates too, and the directory
	# this rollback consumed is the newest, so it is the one an over-full
	# backlog keeps. What it is kept *for* is the restore just above, and once
	# that restore has succeeded there is nothing in it but a second copy of the
	# live tree — see the cleanup on the success path below.
	prune_backups

	# Whatever version is on disk now is the truth; drop the cached one so the
	# status page cannot keep reporting the version that failed to install. The
	# probe stamp is reset with it so status.sh re-detects at once instead of
	# treating the empty entry as an answer — see the version paragraph in
	# status.sh.
	fcc_cache_set fcc_version ""
	fcc_cache_set version_probed_at 0

	[ "$_rb_was" = true ] && /etc/init.d/fcc start >/dev/null 2>&1

	if [ -x "$ROOT/bin/fcc-server" ] && wait_for_health "$FCC_HEALTH_TIMEOUT"; then
		# The previous tree is live again — runtime/ and bin/ were moved back,
		# and data/ was restored from this directory — so what is left here is a
		# duplicate of the device's own state, and by far the largest thing a
		# failed attempt leaves behind: the copy of data/ was 273 MB per attempt,
		# measured on the test router on 2026-10-21. Section 25's retention kept
		# three of them, 820 MB in all, and that backlog is what pushed free
		# space under FCC_MIN_FREE_MB and made every later attempt fail the
		# storage precheck before it could start. Deleting a directory that has
		# just been consumed is safe for exactly that reason; a restore that did
		# not happen — the tree is still in the backup, or the copy of data/
		# failed — leaves it in place, and so does a rollback that ends below
		# with ROLLBACK_FAILED.
		if [ "$_rb_data_ok" -eq 1 ] && [ -n "$_rb_dir" ] && [ -d "$_rb_dir" ] \
				&& [ ! -e "$_rb_dir/runtime" ] && [ ! -e "$_rb_dir/bin" ]; then
			rm -rf "$_rb_dir" 2>/dev/null \
				&& fcc_log "$LOG" "removed the consumed backup ${_rb_dir##*/}"
		fi
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
	_cr_from_update=0
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
			# update.sh runs this sequence under its own lock, so the update
			# lock it holds is its own, not another update's. Without this the
			# guard below refuses every update FCC the UI starts — the parent
			# is still alive while the child runs.
			--from-update) _cr_from_update=1; shift ;;
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
	if [ "$_cr_from_update" != 1 ] && fcc_lock_held update; then
		fcc_lock_release "$_cr_lock"
		fcc_die "an update is already running"
		return 1
	fi

	# --- section 23 step 1: what is being replaced ------------------------
	_cr_before="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	_cr_installed="$(fcc_installed_agents "$ROOT")"

	# --- agents this system cannot install --------------------------------
	# Cline is one: its npm package carries a glibc-only binary and there is no
	# musl build, so `cline --version` dies in the loader on every OpenWrt image
	# (common.sh has the measurement). Upstream stops at the first agent that
	# fails, which would take the FCC package and the PATH setup with it. The
	# agent therefore leaves the set before the installer is driven — in "no
	# opinion" mode too, where the set is upstream's defaults rather than a list
	# the caller gave — and the answerer declines its question as well, because
	# in that mode every other agent is answered yes.
	#
	# The whole run is refused when every agent that was asked for is
	# unavailable: upstream would re-ask "Select at least one coding agent."
	# until the deadline, and an install that installs nothing is not a better
	# answer than the reason.
	_cr_requested="$_cr_agents"
	if [ "$_cr_none" = 1 ]; then
		_cr_considered=""
	elif [ -n "$_cr_requested" ]; then
		_cr_considered="$_cr_requested"
	else
		_cr_considered="$(fcc_default_agents) $_cr_installed"
	fi
	FCC_AGENT_SKIP="$(fcc_unsupported_agents_in "$_cr_considered")"
	if [ -n "$FCC_AGENT_SKIP" ]; then
		_cr_kept=""
		for _cr_id in $_cr_agents; do
			case " $FCC_AGENT_SKIP " in
				*" $_cr_id "*) ;;
				*) _cr_kept="$_cr_kept $_cr_id" ;;
			esac
		done
		_cr_agents="${_cr_kept# }"
		for _cr_id in $FCC_AGENT_SKIP; do
			_cr_why="$(fcc_agent_unsupported_reason "$_cr_id")"
			_cr_name="$(fcc_agent_name "$_cr_id")"
			[ -n "$_cr_name" ] || _cr_name="$_cr_id"
			fcc_log "$LOG" "installer: not installing $_cr_name: $_cr_why"
			printf '%s is not installed: %s\n' "$_cr_name" "$_cr_why"
		done
	fi
	if [ -n "$_cr_requested" ] && [ -z "$_cr_agents" ]; then
		fcc_lock_release "$_cr_lock"
		fcc_log "$LOG" "aborted: none of the requested agents can be installed on this system"
		printf 'None of the agents you selected can be installed on this system.\n'
		printf 'Choose a different agent and install again.\n'
		printf 'AGENT_UNSUPPORTED\n'
		return 1
	fi

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
	# bash requirement in particular, which applies to six of the eleven agents.
	FCC_AGENT_SELECTION="$_cr_agents"
	FCC_AGENT_NONE="$_cr_none"
	export FCC_AGENT_SELECTION FCC_AGENT_NONE

	if ! precheck_ok; then
		# The gate named something. When what it named is a package — tar, bash,
		# an applet, the C++ runtime the fetched Node loads against — add it and
		# ask again, rather than stopping an install the user already asked for
		# so they can go and type the suggestion into a terminal. Anything else
		# (storage, DNS, an unsupported CPU) is not something this script can
		# change, and the report goes straight to the log.
		install_prerequisite_packages
		_cr_prc=$?
		if [ "$_cr_prc" -eq 2 ] || ! precheck_ok; then
			precheck_blocked || return 1
		fi
		fcc_log "$LOG" "preflight: compatibility checks now pass"
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
	# And the init script cannot know about every one of them: the agents in
	# open console sessions and any server a launcher detached with
	# --auto-started are not procd's children. If they survive this, upstream
	# aborts the run and the user sees only the rollback, so stop here instead,
	# with the reason in the log and the previous runtime put back.
	if ! stop_fcc_processes; then
		rollback_runtime "$_cr_backup" "$_cr_was_running"
		fcc_lock_release "$_cr_lock"
		return 1
	fi

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
	# An agent that is not being installed needs no Node. Cline on musl is the
	# case, and a Cline-only install would otherwise download 30 MB for an
	# agent that was just left out.
	if [ -n "$FCC_AGENT_SKIP" ]; then
		_cr_node_kept=""
		for _cr_node_id in $_cr_node_wanted; do
			case " $FCC_AGENT_SKIP " in
				*" $_cr_node_id "*) ;;
				*) _cr_node_kept="$_cr_node_kept $_cr_node_id" ;;
			esac
		done
		_cr_node_wanted="${_cr_node_kept# }"
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
	# write_runtime_metadata() has just written the version it detected into the
	# cache as well, so there is no stale entry left to drop here. Clearing it —
	# which is what this line used to do — refreshed the cache file's mtime with
	# an empty value, and the page then showed "—" for the version until the
	# entry expired.

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
	# is no longer needed (section 78 keeps the data copy). First carry forward
	# the tools that belong to an agent rather than to the runtime — this is
	# the first moment that is safe, since before the health check the backup
	# is what a rollback restores, and a tool moved out of it would be lost
	# with the new tree.
	if keep_previous_agent_tools "$_cr_backup"; then
		# runtime.json was written before the health check, and the agents
		# carried over were not installed by this run, so it has to be told
		# about them now.
		write_runtime_metadata
	fi
	commit_backup "$_cr_backup"

	_cr_after="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	fcc_lock_release "$_cr_lock"
	fcc_log "$LOG" "FCC runtime installed successfully (${_cr_before:-none} -> ${_cr_after:-unknown})"
	printf 'OK\n'
	return 0
}

# Delete the saved backups, and nothing else.
#
# backup/ holds what rollback_runtime() restores from: the data as it was when
# an install started and, for an update, the previous runtime. They are kept on
# purpose (section 25) and pruned to the newest few, but they are also the one
# part of the install path nothing uses between runs, and on a box where an
# install has failed a few times they are the largest thing there. This is the
# operation that reclaims that space without touching the runtime, the agents,
# the configuration or the data.
#
# It takes the install lock before deleting anything. The backup is the rollback
# source of a job that is still running, so removing it mid-install would turn a
# recoverable failure into an unrecoverable one. An update holds its own lock,
# and is refused the same way; the two checks mirror cmd_runtime().
cmd_cleanbackups() {
	_cc_lock="$(fcc_lock_acquire install)" || {
		fcc_log "$LOG" "delete backups refused: another install/update is running"
		printf 'another install or update is running\n'
		return 1
	}
	if fcc_lock_held update; then
		fcc_lock_release "$_cc_lock"
		fcc_log "$LOG" "delete backups refused: an update is running"
		printf 'another install or update is running\n'
		return 1
	fi
	_cc_root="$(fcc_dir_backup)"
	_cc_count=0
	if [ -d "$_cc_root" ]; then
		# Only the directories this package stamped, never the directory itself
		# and never what else may live in it: the backup path is a setting, so it
		# can be a directory the user made for other reasons — the install base
		# is one they are explicitly allowed to pick.
		_cc_count="$(fcc_backup_clear)"
	fi
	fcc_lock_release "$_cc_lock"
	fcc_log "$LOG" "removed $_cc_count saved backup(s)"
	printf 'OK\n'
	return 0
}

cmd_uninstall() {
	_cu_purge=0
	[ "${1:-}" = "--purge" ] && _cu_purge=1
	/etc/init.d/fcc stop >/dev/null 2>&1
	# Everything below deletes the tree those processes are executing from.
	# Leaving a detached server or an agent behind would keep the files alive
	# with no name left to stop them by, and the next install would find them.
	stop_fcc_processes || true
	# Remove everything except data/ and backup/ unless --purge.
	for _cu_d in runtime bin cache sessions; do
		[ -d "$ROOT/$_cu_d" ] && rm -rf "$ROOT/$_cu_d"
	done
	rm -f "$ROOT/runtime.json"
	if [ "$_cu_purge" -eq 1 ]; then
		rm -rf "$ROOT/data" 2>/dev/null
		# The backups live where the backup path says, which is not necessarily
		# under the root any more. Both places are cleared: the configured one
		# through fcc_backup_clear(), which removes only our own stamped
		# directories, and <root>/backup, where every version before this one
		# kept them — that one is inside the root and so is ours whatever is in
		# it.
		if [ "$(fcc_dir_backup)" != "$ROOT/backup" ]; then
			rm -rf "$ROOT/backup" 2>/dev/null
		fi
		fcc_backup_clear >/dev/null
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
	cleanbackups) cmd_cleanbackups ;;
	check)     check_report ;;
	*) echo "usage: install.sh {runtime [--agents a,b] [--all-agents] | reinstall | uninstall [--purge] | cleanbackups | check}" >&2; exit 2 ;;
esac
