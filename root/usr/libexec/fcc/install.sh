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
FCC_AGENT_ORDER="claude codex pi opencode cline hermes dsh grok muse aider"

# DESIGN_SPEC.md section 23 step 3: refuse to start an update that cannot
# finish. A Python toolchain plus the runtime is a few hundred MB; running out
# of space midway leaves a half-written runtime, which is worse than not
# starting. Overridable so a test or a deliberately tight box can adjust it.
FCC_MIN_FREE_MB="${FCC_MIN_FREE_MB:-300}"

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
	# runtime root. Called in this process, which then execs the installer as a
	# child, so the variables are inherited (and discarded when we exit).
	HOME="$ROOT/data"
	UV_INSTALL_DIR="$ROOT/bin"
	UV_TOOL_DIR="$ROOT/runtime/uv-tools"
	UV_TOOL_BIN_DIR="$ROOT/bin"
	UV_CACHE_DIR="$ROOT/cache/uv"
	UV_PYTHON_INSTALL_DIR="$ROOT/runtime/python"
	XDG_DATA_HOME="$ROOT/data/.local/share"
	XDG_CACHE_HOME="$ROOT/cache"
	XDG_BIN_HOME="$ROOT/bin"
	XDG_CONFIG_HOME="$ROOT/data/.config"
	PATH="$ROOT/bin:$PATH"
	export HOME UV_INSTALL_DIR UV_TOOL_DIR UV_TOOL_BIN_DIR UV_CACHE_DIR \
	       UV_PYTHON_INSTALL_DIR XDG_DATA_HOME XDG_CACHE_HOME XDG_BIN_HOME \
	       XDG_CONFIG_HOME PATH
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

# ---------------------------------------------------------------------------
# Run the installer, honouring a requested agent set when possible.
# ---------------------------------------------------------------------------
run_installer() {
	_ri_script="$1"
	_ri_agents="$2"      # space separated, empty => upstream defaults
	_ri_use_pty=0
	command -v script >/dev/null 2>&1 && _ri_use_pty=1

	mkdir -p "$ROOT/cache" "$ROOT/logs" 2>/dev/null
	_ri_ansfile="$ROOT/cache/installer-answers"
	: > "$_ri_ansfile" 2>/dev/null
	if [ -n "$_ri_agents" ]; then
		for _ri_a in $FCC_AGENT_ORDER; do
			case " $_ri_agents " in
				*" $_ri_a "*) printf 'y\n' >> "$_ri_ansfile" ;;
				*)            printf 'n\n' >> "$_ri_ansfile" ;;
			esac
		done
		# Trailing answers for any extra prompt (e.g. RTK); "n" is the safe default.
		printf 'n\nn\nn\n' >> "$_ri_ansfile"
	fi

	fcc_log "$LOG" "running upstream installer (agents='${_ri_agents:-<defaults>}', pty=$_ri_use_pty)"
	apply_runtime_env

	if [ "$_ri_use_pty" -eq 1 ]; then
		# `script` gives the installer a controlling tty so its prompts are read
		# from /dev/tty; our answers are fed through script's stdin.
		script -q -c "sh '$_ri_script'" /dev/null < "$_ri_ansfile" >> "$ROOT/logs/installer.out" 2>&1
		_ri_rc=$?
	else
		[ -n "$_ri_agents" ] && fcc_log "$LOG" "WARN: no 'script' helper; installer runs non-interactively with upstream default agents"
		sh "$_ri_script" >> "$ROOT/logs/installer.out" 2>&1
		_ri_rc=$?
	fi
	return "$_ri_rc"
}

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------
write_runtime_metadata() {
	_wm_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	_wm_ver="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	_wm_py="$(fcc_detect_version "$ROOT/runtime/python/bin/python3" --version 2>/dev/null || true)"
	[ -n "$_wm_py" ] || _wm_py="$(fcc_detect_version python3 --version 2>/dev/null || true)"
	{
		printf '{\n'
		printf '  "fcc_version": %s,\n' "$(fcc_json_str_or_null "${_wm_ver:-}")"
		printf '  "python_version": %s,\n' "$(fcc_json_str_or_null "${_wm_py:-}")"
		printf '  "installed_at": %s,\n' "$(fcc_json_str_or_null "$_wm_now")"
		printf '  "install_path": %s' "$(fcc_json_str "$ROOT")"
		# Per-agent versions, so a later status refresh has a fallback when the
		# underlying CLI cannot be probed (see agent.sh detect_agent_version).
		# The comma leads each entry rather than trailing the one before it:
		# install_path is always emitted, but the agent list can be empty, and a
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
	# backup_runtime -> path to the archive, or empty when there was nothing
	# worth keeping (which is the normal case on a first install).
	#
	# Only data/ and runtime.json are archived. The runtime tree itself is not:
	# it is large, the installer rebuilds it, and archiving it would double the
	# disk the preflight just checked for. What cannot be rebuilt is the user's
	# FCC configuration and agent state, and that is what this keeps.
	_bk_dir="$(fcc_dir_backup)"
	mkdir -p "$_bk_dir" 2>/dev/null || return 1
	[ -d "$ROOT/data" ] || [ -f "$ROOT/runtime.json" ] || return 1

	_bk_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
	_bk_out="$_bk_dir/runtime-$_bk_stamp.tar"
	_bk_list=""
	[ -d "$ROOT/data" ] && _bk_list="$_bk_list data"
	[ -f "$ROOT/runtime.json" ] && _bk_list="$_bk_list runtime.json"
	[ -n "$_bk_list" ] || return 1

	# The list is built from fixed names above, never from user input, so the
	# unquoted expansion is the intended word splitting.
	# shellcheck disable=SC2086
	( cd "$ROOT" && tar -cf "$_bk_out" $_bk_list ) >/dev/null 2>&1 || return 1
	printf '%s' "$_bk_out"
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

recover_after_failure() {
	# recover_after_failure <backup-archive> <was-running>
	#
	# Section 23 step 13: leave the box in a usable state. If the server was
	# running before the update, start it again so the user is not left with
	# nothing; the backup is reported so the data can be restored by hand.
	#
	# Section 23 step 14 asks for a rollback to the previous version. That is
	# NOT done here, and cannot be: upstream's installer takes no version
	# argument — it always installs the newest release from PyPI — so there is
	# no older build to return to. Section 103 requires saying so rather than
	# reporting a rollback that did not happen.
	_rc_bk="$1"
	_rc_was="$2"
	if [ "$_rc_was" = true ]; then
		/etc/init.d/fcc start >/dev/null 2>&1
		fcc_log "$LOG" "restarted the FCC server after the failed update"
	fi
	[ -n "$_rc_bk" ] && fcc_log "$LOG" "the pre-update backup is at $_rc_bk (restore it by hand if needed)"
	fcc_log "$LOG" "NOTE: rollback to the previous FCC version is not possible — the upstream installer accepts no version argument and always installs the latest release"
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_runtime() {
	_cr_agents=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--agents)   _cr_agents="$(printf '%s' "${2:-}" | tr ',' ' ')"; shift 2 ;;
			--agents=*) _cr_agents="$(printf '%s' "${1#--agents=}" | tr ',' ' ')"; shift ;;
			*) shift ;;
		esac
	done

	fcc_ensure_dirs
	_cr_lock="$(fcc_lock_acquire install)" || { fcc_die "another install/update is already running"; return 1; }

	# --- section 23 step 1: what is being replaced ------------------------
	_cr_before="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"

	if ! precheck_ok; then
		fcc_lock_release "$_cr_lock"
		fcc_log "$LOG" "install aborted: compatibility precheck failed"
		printf 'PRECHECK_FAILED\n'
		return 1
	fi

	# --- section 23 step 3: disk space ------------------------------------
	_cr_free="$(fcc_disk_free_kb "$ROOT" 2>/dev/null || true)"
	case "$_cr_free" in ''|*[!0-9]*) _cr_free=0 ;; esac
	if [ "$_cr_free" -gt 0 ] && [ "$_cr_free" -lt $(( FCC_MIN_FREE_MB * 1024 )) ]; then
		fcc_lock_release "$_cr_lock"
		fcc_log "$LOG" "aborted: $(( _cr_free / 1024 ))MB free under $ROOT, need ${FCC_MIN_FREE_MB}MB"
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
	[ -n "$_cr_backup" ] && fcc_log "$LOG" "backed up data/ and runtime.json to $_cr_backup"

	# --- sections 23 steps 7-8: stop --------------------------------------
	# The upstream installer refuses to run while FCC processes are alive.
	/etc/init.d/fcc stop >/dev/null 2>&1

	_cr_script="$ROOT/cache/fcc-install-$$.sh"
	if ! download_installer "$_cr_script"; then
		recover_after_failure "$_cr_backup" "$_cr_was_running"
		fcc_lock_release "$_cr_lock"
		return 1
	fi
	_cr_hash="$(sha256_of "$_cr_script")"
	fcc_log "$LOG" "installer downloaded from $FCC_INSTALLER_URL sha256=$_cr_hash"
	printf '%s  %s\n' "$_cr_hash" "$FCC_INSTALLER_URL" >> "$ROOT/cache/installer-hashes.log" 2>/dev/null

	# --- section 23 step 9: update ----------------------------------------
	run_installer "$_cr_script" "$_cr_agents"
	_cr_rc=$?
	rm -f "$_cr_script"

	if [ "$_cr_rc" -ne 0 ]; then
		fcc_log "$LOG" "installer exited with status $_cr_rc; see logs/installer.out"
		recover_after_failure "$_cr_backup" "$_cr_was_running"
		fcc_lock_release "$_cr_lock"
		return "$_cr_rc"
	fi

	# --- section 23 step 10: verify ---------------------------------------
	if ! "$ROOT/bin/fcc-server" --version >/dev/null 2>&1; then
		fcc_log "$LOG" "validation failed: fcc-server --version did not succeed"
		recover_after_failure "$_cr_backup" "$_cr_was_running"
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
			recover_after_failure "$_cr_backup" "$_cr_was_running"
			fcc_lock_release "$_cr_lock"
			printf 'HEALTH_FAILED\n'
			return 1
		fi
	fi

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
