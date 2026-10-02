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

	if ! precheck_ok; then
		fcc_lock_release "$_cr_lock"
		fcc_log "$LOG" "install aborted: compatibility precheck failed"
		printf 'PRECHECK_FAILED\n'
		return 1
	fi

	# The upstream installer refuses to run while FCC processes are alive.
	/etc/init.d/fcc stop >/dev/null 2>&1

	_cr_script="$ROOT/cache/fcc-install-$$.sh"
	if ! download_installer "$_cr_script"; then
		fcc_lock_release "$_cr_lock"
		return 1
	fi
	_cr_hash="$(sha256_of "$_cr_script")"
	fcc_log "$LOG" "installer downloaded from $FCC_INSTALLER_URL sha256=$_cr_hash"
	printf '%s  %s\n' "$_cr_hash" "$FCC_INSTALLER_URL" >> "$ROOT/cache/installer-hashes.log" 2>/dev/null

	run_installer "$_cr_script" "$_cr_agents"
	_cr_rc=$?
	rm -f "$_cr_script"

	if [ "$_cr_rc" -ne 0 ]; then
		fcc_log "$LOG" "installer exited with status $_cr_rc; see logs/installer.out"
		fcc_lock_release "$_cr_lock"
		return "$_cr_rc"
	fi

	# Validate.
	if ! "$ROOT/bin/fcc-server" --version >/dev/null 2>&1; then
		fcc_log "$LOG" "validation failed: fcc-server --version did not succeed"
		fcc_lock_release "$_cr_lock"
		return 1
	fi

	write_runtime_metadata
	fcc_lock_release "$_cr_lock"
	fcc_log "$LOG" "FCC runtime installed successfully"
	# Auto-start if configured.
	if [ "$(fcc_uci_get main auto_start 1)" = "1" ]; then
		/etc/init.d/fcc enable >/dev/null 2>&1
		/etc/init.d/fcc start  >/dev/null 2>&1
	fi
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
