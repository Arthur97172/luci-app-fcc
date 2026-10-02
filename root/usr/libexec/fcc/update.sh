#!/bin/sh
# luci-app-fcc — update checks and runtime upgrade.
#
# Two independent things can be out of date, and they are updated by different
# mechanisms, so this script never conflates them:
#
#   1. luci-app-fcc itself — a normal OpenWrt package. We can only *report* the
#      available version and the correct upgrade command for the detected
#      package manager (opkg on 24.10, apk on 25.12). A package must not
#      upgrade itself (DESIGN_SPEC.md section 87).
#
#   2. The FCC runtime under /opt/fcc — installed by our own adapter. Upgrading
#      it means re-running the installer, which `update.sh runtime` does.
#
# Usage:
#   update.sh check [--json]     Version report (JSON by default)
#   update.sh runtime [--agents a,b]
#   update.sh luci               Print the package upgrade command
#
# Nothing here is fabricated: a check that cannot reach the network reports
# "checked": false and a null version rather than guessing.
#
# Locals are per-function prefixed — see the note at the top of common.sh.

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

ROOT="$(fcc_root)"
LOG="fcc-update.log"

LUCI_VERSION_URL="${FCC_LUCI_VERSION_URL:-https://raw.githubusercontent.com/Arthur97172/luci-app-fcc/main/VERSION}"
PYPI_JSON_URL="${FCC_PYPI_JSON_URL:-https://pypi.org/pypi/free-claude-code/json}"
PKG_NAME="luci-app-fcc"

CURL_OPTS="--fail --silent --show-error --location --proto =https --tlsv1.2 --max-time 30 --retry 2 --retry-delay 2"

have_curl() { command -v curl >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Package manager (opkg on 24.10, apk on 25.12)
# ---------------------------------------------------------------------------
package_manager() {
	if command -v apk >/dev/null 2>&1; then printf 'apk'
	elif command -v opkg >/dev/null 2>&1; then printf 'opkg'
	else printf 'unknown'; fi
}

upgrade_command() {
	case "$(package_manager)" in
		apk)  printf 'apk update && apk add --upgrade %s' "$PKG_NAME" ;;
		opkg) printf 'opkg update && opkg install %s' "$PKG_NAME" ;;
		*)    printf 'Install the %s package with your package manager.' "$PKG_NAME" ;;
	esac
}

# ---------------------------------------------------------------------------
# Latest luci-app-fcc version (the repo's VERSION file)
# ---------------------------------------------------------------------------
latest_luci_version() {
	have_curl || return 1
	_llv_v="$(curl $CURL_OPTS "$LUCI_VERSION_URL" 2>/dev/null | tr -d ' \t\r\n')" || return 1
	# Must look like a version, otherwise the fetch returned an error page.
	case "$_llv_v" in
		''|*[!0-9A-Za-z.+-]*) return 1 ;;
	esac
	printf '%s' "$_llv_v"
}

# ---------------------------------------------------------------------------
# Latest FCC runtime version (PyPI JSON API — the same source uv installs from)
# ---------------------------------------------------------------------------
latest_fcc_version() {
	have_curl || return 1
	_lfv_v="$(curl $CURL_OPTS "$PYPI_JSON_URL" 2>/dev/null \
		| sed -n 's/.*"info"[^{]*{[^}]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
		| head -n1)"
	# sed over a single-line JSON blob: fall back to a targeted grep if the
	# "info" object is not the first thing in the document.
	if [ -z "$_lfv_v" ]; then
		_lfv_v="$(curl $CURL_OPTS "$PYPI_JSON_URL" 2>/dev/null \
			| tr ',' '\n' | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	fi
	case "$_lfv_v" in
		''|*[!0-9A-Za-z.+-]*) return 1 ;;
	esac
	printf '%s' "$_lfv_v"
}

installed_fcc_version() {
	_ifv_v="$(fcc_cache_get fcc_version 2>/dev/null || true)"
	if [ -z "$_ifv_v" ]; then
		_ifv_v="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	fi
	[ -n "$_ifv_v" ] || return 1
	printf '%s' "$_ifv_v"
}

runtime_installed_at() {
	[ -r "$ROOT/runtime.json" ] || return 1
	_ria_d="$(sed -n 's/.*"installed_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/runtime.json" | head -n1)"
	[ -n "$_ria_d" ] || return 1
	printf '%s' "$_ria_d"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_check() {
	_luci_installed="$(fcc_luci_version)"
	_luci_latest="$(latest_luci_version 2>/dev/null || true)"
	_fcc_installed="$(installed_fcc_version 2>/dev/null || true)"
	_fcc_latest="$(latest_fcc_version 2>/dev/null || true)"
	_fcc_at="$(runtime_installed_at 2>/dev/null || true)"

	_luci_checked=false; _luci_update=null
	if [ -n "$_luci_latest" ]; then
		_luci_checked=true
		if [ "$_luci_latest" = "$_luci_installed" ]; then _luci_update=false; else _luci_update=true; fi
	fi
	_fcc_checked=false; _fcc_update=null
	if [ -n "$_fcc_latest" ] && [ -n "$_fcc_installed" ]; then
		_fcc_checked=true
		if [ "$_fcc_latest" = "$_fcc_installed" ]; then _fcc_update=false; else _fcc_update=true; fi
	fi

	printf '{\n'
	printf '  "luci_fcc": {"installed": %s, "latest": %s, "checked": %s, "update_available": %s, "source": %s},\n' \
		"$(fcc_json_str "$_luci_installed")" \
		"$(fcc_json_str_or_null "${_luci_latest:-}")" \
		"$_luci_checked" "$_luci_update" \
		"$(fcc_json_str "$LUCI_VERSION_URL")"
	printf '  "fcc_runtime": {"installed": %s, "latest": %s, "checked": %s, "update_available": %s, "installed_at": %s, "source": %s},\n' \
		"$(fcc_json_str_or_null "${_fcc_installed:-}")" \
		"$(fcc_json_str_or_null "${_fcc_latest:-}")" \
		"$_fcc_checked" "$_fcc_update" \
		"$(fcc_json_str_or_null "${_fcc_at:-}")" \
		"$(fcc_json_str "$PYPI_JSON_URL")"
	printf '  "package_manager": %s,\n' "$(fcc_json_str "$(package_manager)")"
	printf '  "upgrade_command": %s\n' "$(fcc_json_str "$(upgrade_command)")"
	printf '}\n'
}

cmd_runtime() {
	# DESIGN_SPEC.md section 23 describes an update as a sequence — preflight,
	# back up, stop, install, verify, start, health check, recover. That
	# sequence lives in install.sh, which is also the install path, so both
	# entry points get it and there is one copy to keep correct.
	#
	# What belongs here is the part specific to *updating*: recording what is
	# being replaced, and preserving the agent set the user actually has so an
	# upgrade does not silently drop agents they added.
	_cru_before="$(installed_fcc_version 2>/dev/null || true)"
	_cru_set="$(installed_agents | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ',' | sed 's/,$//')"
	fcc_log "$LOG" "runtime update requested (installed=${_cru_before:-unknown}, agents='${_cru_set:-<defaults>}')"

	if [ -n "$_cru_set" ]; then
		"${FCC_LIBDIR:-/usr/libexec/fcc}/install.sh" runtime --agents "$_cru_set"
	else
		"${FCC_LIBDIR:-/usr/libexec/fcc}/install.sh" runtime
	fi
	_cru_rc=$?

	# Read the version straight from the binary rather than through
	# installed_fcc_version(), whose cache entry was invalidated by the install
	# and would otherwise report the pre-update value.
	_cru_after="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	fcc_log "$LOG" "runtime update finished rc=$_cru_rc (${_cru_before:-unknown} -> ${_cru_after:-unknown})"
	return "$_cru_rc"
}

installed_agents() {
	_ia_out=""
	while IFS='|' read -r _ia_id _ia_rest; do
		case "$_ia_id" in ''|\#*) continue ;; esac
		_ia_cmd="$(fcc_agent_command "$_ia_id")"
		[ -n "$_ia_cmd" ] || continue
		command -v "$_ia_cmd" >/dev/null 2>&1 && _ia_out="$_ia_out $_ia_id"
	done <<-EOF
	$(fcc_agents_each)
	EOF
	printf '%s' "$_ia_out"
}

cmd_luci() {
	printf 'Installed: %s\n' "$(fcc_luci_version)"
	_clu_l="$(latest_luci_version 2>/dev/null || true)"
	[ -n "$_clu_l" ] && printf 'Latest:    %s\n' "$_clu_l"
	printf 'Upgrade with:\n  %s\n' "$(upgrade_command)"
}

case "${1:-}" in
	check)   shift; cmd_check "$@" ;;
	runtime) shift; cmd_runtime "$@" ;;
	luci)    cmd_luci ;;
	*) echo "usage: update.sh {check [--json] | runtime [--agents a,b] | luci}" >&2; exit 2 ;;
esac
