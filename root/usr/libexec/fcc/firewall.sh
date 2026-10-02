#!/bin/sh
# luci-app-fcc — section 50's LAN-only firewall rule for the FCC Admin port.
#
# Section 50 allows two answers for reaching the FCC Admin page from a browser:
# bind the server to a wildcard address and add a LAN-only firewall rule, or
# stay on loopback and reach it some other way. This package ships loopback by
# default, and manages the rule only for the case that needs one.
#
# The rule is scoped to the `lan` zone and nothing else. No rule is ever written
# for the wan zone, and none is needed: OpenWrt's wan zone drops input by
# default, so the port is unreachable from outside unless the administrator has
# already changed that policy — a decision that belongs in their firewall, not
# in this package making it for them.
#
# A bind to a specific address needs no rule at all: the server then listens on
# that one interface, so the WAN cannot reach it whatever the firewall says.
# That is why the controller removes the rule when the bind is not a wildcard
# rather than leaving a stale allowance behind.
#
# Usage:
#   firewall.sh status          report whether the rule is present
#   firewall.sh ensure [port]   add or update the rule (default: the UCI port)
#   firewall.sh remove          remove it

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

RULE_NAME="Allow-FCC-Admin"

# uci is the only way to change the firewall on OpenWrt; without it there is
# nothing to change and nothing to report but that.
fw_have_uci() {
	command -v uci >/dev/null 2>&1
}

fw_rule_index() {
	# Print the index of our rule in the firewall config, or fail if absent.
	_fi_i=0
	while [ "$_fi_i" -lt 512 ]; do
		_fi_n="$(uci -q get "firewall.@rule[$_fi_i].name" 2>/dev/null || true)"
		if [ -z "$_fi_n" ]; then
			# Either the section has no name or the index is past the end;
			# uci cannot tell us which, so keep walking. The cap above is what
			# stops a config with unnamed rules from looping forever.
			_fi_i=$(( _fi_i + 1 ))
			continue
		fi
		if [ "$_fi_n" = "$RULE_NAME" ]; then
			printf '%s' "$_fi_i"
			return 0
		fi
		_fi_i=$(( _fi_i + 1 ))
	done
	return 1
}

fw_reload() {
	# A firewall reload is not fatal to the caller: the rule is committed and
	# will take effect on the next reload regardless.
	[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload >/dev/null 2>&1
	return 0
}

cmd_status() {
	if ! fw_have_uci; then
		printf 'uci is unavailable; the firewall is not managed here.\n'
		return 1
	fi
	if _fs_i="$(fw_rule_index)"; then
		printf 'LAN access rule present (index %s, port %s)\n' "$_fs_i" \
			"$(uci -q get "firewall.@rule[$_fs_i].dest_port" 2>/dev/null || true)"
		return 0
	fi
	printf 'No LAN access rule.\n'
	return 1
}

cmd_ensure() {
	_fe_port="${1:-$(fcc_uci_get main port 8082)}"
	case "$_fe_port" in
		''|*[!0-9]*) printf 'invalid port: %s\n' "$_fe_port" >&2; return 2 ;;
	esac
	if ! fw_have_uci; then
		printf 'uci is unavailable; cannot add the firewall rule.\n' >&2
		return 1
	fi

	if _fe_i="$(fw_rule_index)"; then
		# Keep the port current rather than adding a second rule.
		uci -q set "firewall.@rule[$_fe_i].dest_port=$_fe_port"
	else
		uci -q add firewall rule
		uci -q set "firewall.@rule[-1].name=$RULE_NAME"
		uci -q set "firewall.@rule[-1].src=lan"
		uci -q set "firewall.@rule[-1].proto=tcp"
		uci -q set "firewall.@rule[-1].dest_port=$_fe_port"
		uci -q set "firewall.@rule[-1].target=ACCEPT"
	fi
	uci -q commit firewall
	fw_reload

	printf 'LAN access to TCP/%s allowed; the wan zone was not touched.\n' "$_fe_port"
}

cmd_remove() {
	if ! fw_have_uci; then
		printf 'uci is unavailable; nothing to remove.\n' >&2
		return 1
	fi
	if _fr_i="$(fw_rule_index)"; then
		uci -q delete "firewall.@rule[$_fr_i]"
		uci -q commit firewall
		fw_reload
		printf 'LAN access rule removed.\n'
		return 0
	fi
	printf 'No LAN access rule to remove.\n'
	return 0
}

case "${1:-}" in
	status) cmd_status ;;
	ensure) shift; cmd_ensure "$@" ;;
	remove) cmd_remove ;;
	*) echo "usage: firewall.sh {status | ensure [port] | remove}" >&2; exit 2 ;;
esac
