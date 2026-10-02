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

commit_backup() {
	# The update succeeded, so the moved-aside runtime tree is dead weight.
	# Section 78 asks for the last successful backup to be kept; the data copy
	# is what that means here — it is small, and it is the part that cannot be
	# reinstalled. Keeping the old runtime tree as well would cost a permanent
	# second copy for no benefit, since a successful update has no use for it.
	_cb_dir="$1"
	[ -n "$_cb_dir" ] && [ -d "$_cb_dir" ] || return 0
	rm -rf "$_cb_dir/runtime" "$_cb_dir/bin" 2>/dev/null
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
	run_installer "$_cr_script" "$_cr_agents"
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
