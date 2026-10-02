#!/bin/sh
# luci-app-fcc — pre-install / troubleshooting diagnostics.
#
# Usage:
#   doctor.sh            Human-readable report ([OK]/[WARN]/[FAIL] lines)
#   doctor.sh --json     Machine-readable report (used by the LuCI UI)
#
# The JSON form always contains "install_allowed": true|false. A FAIL on a
# critical check blocks installation (DESIGN_SPEC.md section 3.6.4).

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

ROOT="$(fcc_root)"
REQUIRED_FREE_MB="${FCC_REQUIRED_FREE_MB:-400}"
MIN_RAM_MB="${FCC_MIN_RAM_MB:-256}"

# Result accumulators (space separated "status|name|value|requirement|hint").
RESULTS=""
fail_count=0
warn_count=0

add_result() {
	# add_result <OK|WARN|FAIL> <name> <value> <requirement> [hint]
	RESULTS="${RESULTS}${1}|${2}|${3}|${4}|${5:-}
"
	case "$1" in
		FAIL) fail_count=$((fail_count + 1)) ;;
		WARN) warn_count=$((warn_count + 1)) ;;
	esac
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
arch="$(uname -m 2>/dev/null)"
case "$arch" in
	x86_64|aarch64|arm64)
		add_result OK "Architecture" "$arch" "x86_64 / aarch64" "" ;;
	*)
		add_result WARN "Architecture" "$arch" "x86_64 / aarch64" \
			"Untested architecture; installation may still work." ;;
esac

kernel="$(uname -r 2>/dev/null)"
add_result OK "Kernel" "$kernel" "Linux" ""

if [ -r /etc/openwrt_release ]; then
	. /etc/openwrt_release 2>/dev/null
	owrt="${DISTRIB_ID:-OpenWrt} ${DISTRIB_RELEASE:-?}"
	add_result OK "OpenWrt" "$owrt" "24.10 / 25.12 / ImmortalWrt" ""
else
	add_result WARN "OpenWrt" "unknown" "OpenWrt / ImmortalWrt" \
		"/etc/openwrt_release not found."
fi

# Storage at the install path's filesystem.
_stpath="$ROOT"
[ -d "$_stpath" ] || _stpath="$(dirname "$ROOT")"
[ -d "$_stpath" ] || _stpath="/"
_free_mb="$(df -P -k "$_stpath" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')"
if [ -n "$_free_mb" ] && [ "$_free_mb" -ge "$REQUIRED_FREE_MB" ]; then
	add_result OK "Storage" "${_free_mb} MB free" ">= ${REQUIRED_FREE_MB} MB" "$_stpath"
else
	add_result FAIL "Storage" "${_free_mb:-?} MB free" ">= ${REQUIRED_FREE_MB} MB" \
		"Free space at $_stpath is insufficient for the FCC runtime."
fi

# Memory.
_mem_mb="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
if [ -n "$_mem_mb" ] && [ "$_mem_mb" -ge "$MIN_RAM_MB" ]; then
	add_result OK "Memory" "${_mem_mb} MB" ">= ${MIN_RAM_MB} MB" ""
else
	add_result WARN "Memory" "${_mem_mb:-?} MB" ">= ${MIN_RAM_MB} MB" \
		"Low memory; prefer fewer coding agents."
fi

# Python (uv can supply its own, so this is informational).
_py="$(fcc_detect_version python3 --version 2>/dev/null || true)"
if [ -n "$_py" ]; then
	add_result OK "Python" "$_py" "provided by uv if absent" ""
else
	add_result WARN "Python" "not found" "provided by uv if absent" \
		"uv will install a private Python runtime."
fi

# uv.
_uv="$(fcc_detect_version uv --version 2>/dev/null || true)"
if [ -n "$_uv" ]; then add_result OK "uv" "$_uv" ">= 0.12.13" ""
else add_result WARN "uv" "not found" ">= 0.12.13" "The installer will fetch uv."; fi

# Node (needed by some agents).
_node="$(fcc_detect_version node --version 2>/dev/null || true)"
if [ -n "$_node" ]; then add_result OK "Node.js" "$_node" "if required by agents" ""
else add_result WARN "Node.js" "not found" "if required by agents" "Some agents need Node.js."; fi

# tmux — required for the Web Console session backend.
_tmux="$(fcc_detect_version tmux -V 2>/dev/null || true)"
if [ -n "$_tmux" ]; then add_result OK "tmux" "$_tmux" "required for Web Console" ""
else add_result WARN "tmux" "not found" "required for Web Console" "Install the tmux package for the terminal."; fi

# FCC runtime present?
if [ -x "$ROOT/bin/fcc-server" ]; then
	_fv="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	add_result OK "FCC Runtime" "${_fv:-present}" "any" ""
else
	add_result WARN "FCC Runtime" "not installed" "any" "Use Install FCC Runtime."
fi

# Port availability.
_port="$(fcc_uci_get main port 8082)"
if command -v netstat >/dev/null 2>&1; then
	if netstat -ltn 2>/dev/null | grep -q ":$_port[[:space:]]"; then
		add_result WARN "Port $_port" "in use" "free" "Another process is listening."
	else
		add_result OK "Port $_port" "free" "free" ""
	fi
else
	add_result OK "Port $_port" "unchecked" "free" "netstat unavailable."
fi

# DNS + HTTPS reachability to the installer host.
if command -v curl >/dev/null 2>&1; then
	if timeout 30 curl -fsS -o /dev/null --retry 2 --retry-delay 2 \
			--proto '=https' --tlsv1.2 \
			"https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/install.sh"; then
		add_result OK "HTTPS" "reachable" "github.com" ""
	else
		add_result FAIL "HTTPS" "unreachable" "github.com" \
			"Cannot reach the FCC installer host."
	fi
else
	add_result FAIL "curl" "not found" "required" "Install the curl package."
fi

# Permissions.
if [ -w "$(dirname "$ROOT")" ] || [ -w "$ROOT" ]; then
	add_result OK "Permissions" "writable" "$ROOT" ""
else
	add_result WARN "Permissions" "not writable" "$ROOT" "Will be created on install."
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
install_allowed=true
[ "$fail_count" -gt 0 ] && install_allowed=false

if [ "$JSON" -eq 1 ]; then
	printf '{\n'
	printf '  "install_allowed": %s,\n' "$install_allowed"
	printf '  "fail_count": %s,\n' "$fail_count"
	printf '  "warn_count": %s,\n' "$warn_count"
	printf '  "checks": ['
	_first=1
	printf '%s' "$RESULTS" | while IFS='|' read -r st name val req hint; do
		[ -n "$st" ] || continue
		[ "$_first" -eq 1 ] || printf ','
		_first=0
		printf '\n    {"status": %s, "name": %s, "value": %s, "requirement": %s, "hint": %s}' \
			"$(fcc_json_str "$st")" "$(fcc_json_str "$name")" \
			"$(fcc_json_str "$val")" "$(fcc_json_str "$req")" "$(fcc_json_str "$hint")"
	done
	printf '\n  ]\n'
	printf '}\n'
else
	printf '%s' "$RESULTS" | while IFS='|' read -r st name val req hint; do
		[ -n "$st" ] || continue
		printf '[%s] %-16s %s\n' "$st" "$name" "$val"
		[ -n "$hint" ] && printf '        %s\n' "$hint"
	done
	printf '\n'
	if [ "$install_allowed" = true ]; then
		printf 'Result: OK (%s warnings)\n' "$warn_count"
	else
		printf 'Result: BLOCKED (%s failures, %s warnings)\n' "$fail_count" "$warn_count"
	fi
fi
