#!/bin/sh
# luci-app-fcc — control the FCC server on another machine over SSH.
#
# One remote host, one key, one pinned host key. There is deliberately no
# password path: the router generates an Ed25519 key, the user adds its public
# half to the remote account's authorized_keys, and every command below runs
# with BatchMode=yes, IdentitiesOnly=yes and StrictHostKeyChecking=yes. A
# failed authentication is an answer, not a prompt.
#
# What the caller gets is one JSON document per command. The controller relays
# it and the page renders it; nothing here invents prose for the UI.
#
# The service commands are fixed presets. The only value that reaches a remote
# command string is the service name, and it is validated against a grammar
# before it is used — the same grammar the Lua validator applies before the
# value is stored in UCI.
#
# Open FCC Admin needs a tunnel rather than a URL: the FCC server refuses every
# admin route to a non-loopback peer (free_claude_code/api/admin_security.py,
# require_loopback_admin()). `ssh -L 127.0.0.1:<local>:127.0.0.1:<admin>` makes
# the connection arrive from the remote machine's own loopback, and LuCI's
# reverse proxy talks to the local end of it. The tunnel is started on demand
# and stopped when the target changes.

set -u

. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

# Persistent state. /etc survives a reboot on OpenWrt; /tmp is the right place
# for the tunnel's pid and its log, which should not outlive one.
FCC_REMOTE_DIR="${FCC_REMOTE_DIR:-/etc/fcc/ssh}"
FCC_REMOTE_KEY="${FCC_REMOTE_KEY:-$FCC_REMOTE_DIR/id_ed25519}"
FCC_REMOTE_KNOWN="${FCC_REMOTE_KNOWN:-$FCC_REMOTE_DIR/known_hosts}"
FCC_REMOTE_TUNNEL_PID="${FCC_REMOTE_TUNNEL_PID:-/tmp/fcc-remote-tunnel.pid}"
FCC_REMOTE_TUNNEL_LOG="${FCC_REMOTE_TUNNEL_LOG:-/tmp/fcc-remote-tunnel.log}"
FCC_REMOTE_TUNNEL_PORT="${FCC_REMOTE_TUNNEL_PORT:-18082}"

# The connection options every operation shares. ConnectTimeout is short
# because a wrong address should answer quickly; ServerAlive* is what turns a
# remote that stops answering into an error instead of a stuck request.
FCC_REMOTE_SSH_OPTS="\
-o BatchMode=yes \
-o ConnectTimeout=8 \
-o ConnectionAttempts=1 \
-o IdentitiesOnly=yes \
-o PreferredAuthentications=publickey \
-o StrictHostKeyChecking=yes \
-o UserKnownHostsFile=$FCC_REMOTE_KNOWN"

# ---------------------------------------------------------------------------
# Validation
#
# The controller validates every value before storing it. These checks run
# again because UCI can be edited by hand, and because this script is what
# actually builds the remote command.
# ---------------------------------------------------------------------------

fcc_remote_valid_host() {
	# A private/LAN IPv4 literal and nothing else. A hostname could resolve to a
	# WAN address and turn "the computer on my desk" into "somewhere on the
	# internet"; loopback names this router, not the remote.
	_vh_ip="$1"
	case "$_vh_ip" in
		''|*[!0-9.]*) return 1 ;;
	esac
	_vh_ifs="$IFS"
	IFS=.
	set -- $_vh_ip
	IFS="$_vh_ifs"
	[ "$#" -eq 4 ] || return 1
	for _vh_o in "$@"; do
		case "$_vh_o" in
			''|*[!0-9]*) return 1 ;;
		esac
		[ "${#_vh_o}" -le 3 ] || return 1
		[ "$_vh_o" -le 255 ] || return 1
		# Leading zeroes are octal to some parsers and decimal to others.
		case "$_vh_o" in
			0?*) return 1 ;;
		esac
	done
	_vh_a="$1"
	_vh_b="$2"
	case "$_vh_a" in
		10) return 0 ;;
		192) [ "$_vh_b" = "168" ] && return 0 ;;
		172) [ "$_vh_b" -ge 16 ] && [ "$_vh_b" -le 31 ] && return 0 ;;
		169) [ "$_vh_b" = "254" ] && return 0 ;;
	esac
	return 1
}

fcc_remote_valid_user() {
	# No leading dash: it would become an option to ssh. The set is deliberately
	# narrow; Windows account names that need a domain can use the local
	# account form.
	_vu_u="$1"
	case "$_vu_u" in
		''|-*|*[!A-Za-z0-9_.@-]*) return 1 ;;
	esac
	[ "${#_vu_u}" -le 64 ]
}

fcc_remote_valid_service() {
	# systemd units, procd init scripts and Windows service names all accept
	# this set. No spaces, no shell metacharacters, no leading dash.
	_vs_s="$1"
	case "$_vs_s" in
		''|-*|*[!A-Za-z0-9_.@-]*) return 1 ;;
	esac
	[ "${#_vs_s}" -le 64 ]
}

fcc_remote_valid_platform() {
	case "$1" in
		linux|openwrt|windows) return 0 ;;
	esac
	return 1
}

fcc_remote_valid_port() {
	_vo_p="$1"
	case "$_vo_p" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$_vo_p" -ge 1 ] && [ "$_vo_p" -le 65535 ]
}

fcc_remote_valid_fingerprint() {
	_vf_f="$1"
	case "$_vf_f" in
		SHA256:*) _vf_rest="${_vf_f#SHA256:}" ;;
		*) return 1 ;;
	esac
	case "$_vf_rest" in
		''|*[!A-Za-z0-9+/=]*) return 1 ;;
	esac
	[ "${#_vf_rest}" -ge 40 ] && [ "${#_vf_rest}" -le 44 ]
}

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

fcc_remote_error() {
	printf '{"ok":false,"error":%s}\n' "$(fcc_json_str "$1")"
}

fcc_remote_openssh() {
	# Dropbear's dbclient also calls itself ssh but does not understand -o.
	_os_p="$1"
	_os_v="$("$_os_p" -V 2>&1)"
	case "$_os_v" in
		OpenSSH*) return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

fcc_remote_target() { fcc_uci_get main control_target local; }
fcc_remote_host()   { fcc_uci_get main remote_host ''; }
fcc_remote_user()   { fcc_uci_get main remote_user ''; }
fcc_remote_sport()  { fcc_uci_get main remote_ssh_port 22; }
fcc_remote_aport()  { fcc_uci_get main remote_admin_port 8082; }
fcc_remote_platform() { fcc_uci_get main remote_platform linux; }
fcc_remote_service() { fcc_uci_get main remote_service fcc; }
fcc_remote_fingerprint() { fcc_uci_get main remote_fingerprint ''; }

fcc_remote_config_ok() {
	# Everything a command needs except the key and host trust, which are
	# reported separately so the page can say which one is missing.
	_ck_host="$(fcc_remote_host)"
	_ck_user="$(fcc_remote_user)"
	_ck_sport="$(fcc_remote_sport)"
	_ck_aport="$(fcc_remote_aport)"
	_ck_plat="$(fcc_remote_platform)"
	_ck_svc="$(fcc_remote_service)"
	fcc_remote_valid_host "$_ck_host" || return 1
	fcc_remote_valid_user "$_ck_user" || return 1
	fcc_remote_valid_port "$_ck_sport" || return 1
	fcc_remote_valid_port "$_ck_aport" || return 1
	fcc_remote_valid_platform "$_ck_plat" || return 1
	fcc_remote_valid_service "$_ck_svc" || return 1
	return 0
}

fcc_remote_key_ready() {
	[ -s "$FCC_REMOTE_KEY" ] && [ -s "$FCC_REMOTE_KEY.pub" ]
}

# ---------------------------------------------------------------------------
# Tunnel process
# ---------------------------------------------------------------------------

fcc_remote_tunnel_pid() {
	# The pid in the file, but only when /proc says it is still *our* ssh
	# process. A stale file must not make us kill an unrelated process that
	# inherited the number, and an ssh process by that name is not enough: it
	# has to be the tunnel this package started, which is the one carrying -N
	# and the fixed local forward.
	_tp_pid=""
	if [ -r "$FCC_REMOTE_TUNNEL_PID" ]; then
		_tp_pid="$(tr -dc '0-9' < "$FCC_REMOTE_TUNNEL_PID" 2>/dev/null)"
	fi
	[ -n "$_tp_pid" ] || return 1
	[ -r "/proc/$_tp_pid/cmdline" ] || return 1
	_tp_cmd="$(tr '\0' ' ' < "/proc/$_tp_pid/cmdline" 2>/dev/null)"
	case " $_tp_cmd " in
		*" -N "*" -L 127.0.0.1:$FCC_REMOTE_TUNNEL_PORT:127.0.0.1:"*)
			printf '%s' "$_tp_pid"
			return 0 ;;
	esac
	return 1
}

fcc_remote_tunnel_listening() {
	# /proc/net/tcp is the portable listener check on OpenWrt. Port 18082 is
	# 0x46A2, and 127.0.0.1 is 0100007F in this table.
	_tl_hex="$(printf '%04X' "$FCC_REMOTE_TUNNEL_PORT")"
	_tl_want="0100007F:$_tl_hex"
	_tl_hit="$(awk -v want="$_tl_want" '$2 == want && $4 == "0A" { print "yes"; exit }' \
		/proc/net/tcp 2>/dev/null)"
	[ "$_tl_hit" = "yes" ]
}

fcc_remote_tunnel_stop() {
	# Stop only the pid this package recorded. Anything else with that number is
	# not ours to touch.
	_ts_pid="$(fcc_remote_tunnel_pid)" || _ts_pid=""
	if [ -n "$_ts_pid" ]; then
		kill "$_ts_pid" 2>/dev/null
		_ts_i=0
		while [ "$_ts_i" -lt 3 ] && [ -d "/proc/$_ts_pid" ]; do
			sleep 1
			_ts_i=$((_ts_i + 1))
		done
		[ -d "/proc/$_ts_pid" ] && kill -9 "$_ts_pid" 2>/dev/null
	fi
	rm -f "$FCC_REMOTE_TUNNEL_PID" "$FCC_REMOTE_TUNNEL_LOG" 2>/dev/null
	return 0
}

fcc_remote_tunnel_ensure() {
	[ "$(fcc_remote_target)" = "lan" ] \
		|| { fcc_remote_error "remote control is not enabled"; return 1; }
	fcc_remote_config_ok \
		|| { fcc_remote_error "the remote configuration is incomplete"; return 1; }
	fcc_remote_key_ready \
		|| { fcc_remote_error "the SSH key has not been generated"; return 1; }
	[ -s "$FCC_REMOTE_KNOWN" ] \
		|| { fcc_remote_error "the remote host key has not been trusted"; return 1; }

	_te_pid="$(fcc_remote_tunnel_pid)" || _te_pid=""
	if [ -n "$_te_pid" ] && fcc_remote_tunnel_listening; then
		printf '{"ok":true,"running":true,"port":%s}\n' "$FCC_REMOTE_TUNNEL_PORT"
		return 0
	fi
	[ -n "$_te_pid" ] && fcc_remote_tunnel_stop

	_te_ssh="$(command -v ssh 2>/dev/null)" \
		|| { fcc_remote_error "OpenSSH client is required (package openssh-client)"; return 1; }
	fcc_remote_openssh "$_te_ssh" \
		|| { fcc_remote_error "OpenSSH client is required (package openssh-client)"; return 1; }
	_te_setsid="$(command -v setsid 2>/dev/null)" \
		|| { fcc_remote_error "setsid is not available"; return 1; }

	_te_host="$(fcc_remote_host)"
	_te_user="$(fcc_remote_user)"
	_te_sport="$(fcc_remote_sport)"
	_te_aport="$(fcc_remote_aport)"
	_te_forward="127.0.0.1:$FCC_REMOTE_TUNNEL_PORT:127.0.0.1:$_te_aport"

	rm -f "$FCC_REMOTE_TUNNEL_PID" "$FCC_REMOTE_TUNNEL_LOG" 2>/dev/null
	umask 077
	# $FCC_REMOTE_SSH_OPTS is a set of fixed words, not user input, and it is
	# intentionally unquoted so the shell splits it into separate options.
	"$_te_setsid" "$_te_ssh" -N -T -o ExitOnForwardFailure=yes \
		-o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
		$FCC_REMOTE_SSH_OPTS \
		-i "$FCC_REMOTE_KEY" -p "$_te_sport" \
		-l "$_te_user" -L "$_te_forward" \
		"$_te_host" </dev/null >/dev/null 2>"$FCC_REMOTE_TUNNEL_LOG" &
	_te_started=$!

	_te_i=0
	while [ "$_te_i" -lt 12 ]; do
		if fcc_remote_tunnel_listening; then
			printf '%s\n' "$_te_started" > "$FCC_REMOTE_TUNNEL_PID"
			printf '{"ok":true,"running":true,"port":%s}\n' "$FCC_REMOTE_TUNNEL_PORT"
			return 0
		fi
		[ -d "/proc/$_te_started" ] || break
		sleep 1
		_te_i=$((_te_i + 1))
	done

	kill "$_te_started" 2>/dev/null
	_te_why="$(tail -n 3 "$FCC_REMOTE_TUNNEL_LOG" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
	[ -n "$_te_why" ] || _te_why="the tunnel did not start"
	fcc_remote_error "$(printf '%s' "$_te_why" | sed 's/^ //; s/ $//')"
	return 1
}

# ---------------------------------------------------------------------------
# Host key
# ---------------------------------------------------------------------------

fcc_remote_tmpdir() {
	_td_dir="${TMPDIR:-/tmp}/fcc-remote.$$"
	rm -rf "$_td_dir" 2>/dev/null
	(umask 077; mkdir "$_td_dir") 2>/dev/null || return 1
	printf '%s' "$_td_dir"
}

fcc_remote_scan_to() {
	# fcc_remote_scan_to <file> <host> <port> -> the SHA256 fingerprint, or
	# nothing. The file receives one known_hosts line.
	_sc_file="$1"
	_sc_host="$2"
	_sc_port="$3"
	_sc_scan="$(command -v ssh-keyscan 2>/dev/null)" || return 1
	_sc_keygen="$(command -v ssh-keygen 2>/dev/null)" || return 1
	_sc_all="$("$_sc_scan" -T 8 -p "$_sc_port" "$_sc_host" 2>/dev/null)" || return 1
	[ -n "$_sc_all" ] || return 1
	_sc_line="$(printf '%s\n' "$_sc_all" | grep ' ssh-ed25519 ' | head -n 1)"
	if [ -z "$_sc_line" ]; then
		_sc_line="$(printf '%s\n' "$_sc_all" \
			| grep -E ' (ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ' \
			| head -n 1)"
	fi
	[ -n "$_sc_line" ] || return 1
	printf '%s\n' "$_sc_line" > "$_sc_file" || return 1
	_sc_fp="$("$_sc_keygen" -lf "$_sc_file" -E sha256 2>/dev/null | awk 'NR == 1 { print $2 }')"
	[ -n "$_sc_fp" ] || return 1
	printf '%s' "$_sc_fp"
}

fcc_remote_trust() {
	_tr_fp="$2"
	fcc_remote_valid_fingerprint "$_tr_fp" \
		|| { fcc_remote_error "invalid fingerprint"; return 1; }
	fcc_remote_config_ok \
		|| { fcc_remote_error "the remote configuration is incomplete"; return 1; }
	_tr_host="$(fcc_remote_host)"
	_tr_sport="$(fcc_remote_sport)"
	_tr_dir="$(fcc_remote_tmpdir)" \
		|| { fcc_remote_error "could not create a temporary directory"; return 1; }
	_tr_line="$_tr_dir/known_hosts"
	_tr_new="$(fcc_remote_scan_to "$_tr_line" "$_tr_host" "$_tr_sport")" \
		|| { rm -rf "$_tr_dir"; fcc_remote_error "could not read the remote host key"; return 1; }

	if [ "$_tr_new" != "$_tr_fp" ]; then
		printf '{"ok":false,"fingerprint_changed":true,"fingerprint":%s,"expected":%s,"error":%s}\n' \
			"$(fcc_json_str "$_tr_new")" \
			"$(fcc_json_str "$_tr_fp")" \
			"$(fcc_json_str "the remote host key does not match the fingerprint you confirmed")"
		rm -rf "$_tr_dir"
		return 0
	fi

	(umask 077; mkdir -p "$FCC_REMOTE_DIR") 2>/dev/null || {
		rm -rf "$_tr_dir"
		fcc_remote_error "could not create $FCC_REMOTE_DIR"
		return 1
	}
	cp "$_tr_line" "$FCC_REMOTE_KNOWN.fcc-new" 2>/dev/null \
		&& chmod 600 "$FCC_REMOTE_KNOWN.fcc-new" 2>/dev/null \
		&& mv "$FCC_REMOTE_KNOWN.fcc-new" "$FCC_REMOTE_KNOWN" 2>/dev/null \
		|| {
			rm -f "$FCC_REMOTE_KNOWN.fcc-new" 2>/dev/null
			rm -rf "$_tr_dir"
			fcc_remote_error "could not store the remote host key"
			return 1
		}
	rm -rf "$_tr_dir"
	printf '{"ok":true,"fingerprint":%s}\n' "$(fcc_json_str "$_tr_new")"
	return 0
}

# ---------------------------------------------------------------------------
# Key generation
# ---------------------------------------------------------------------------

fcc_remote_keygen() {
	_kg_dir="$FCC_REMOTE_DIR"
	(umask 077; mkdir -p "$_kg_dir") 2>/dev/null \
		|| { fcc_remote_error "could not create $_kg_dir"; return 1; }

	if [ -s "$FCC_REMOTE_KEY" ]; then
		[ -s "$FCC_REMOTE_KEY.pub" ] || {
			_kg_keygen="$(command -v ssh-keygen 2>/dev/null)" || {
				fcc_remote_error "ssh-keygen is not installed"
				return 1
			}
			"$_kg_keygen" -y -f "$FCC_REMOTE_KEY" > "$FCC_REMOTE_KEY.pub" 2>/dev/null \
				|| { fcc_remote_error "could not read the existing SSH key"; return 1; }
			chmod 644 "$FCC_REMOTE_KEY.pub" 2>/dev/null
		}
		printf '{"ok":true,"existing":true,"public_key":%s}\n' \
			"$(fcc_json_str "$(head -n 1 "$FCC_REMOTE_KEY.pub")")"
		return 0
	fi

	_kg_keygen="$(command -v ssh-keygen 2>/dev/null)" \
		|| { fcc_remote_error "ssh-keygen is not installed"; return 1; }
	umask 077
	_kg_out="$("$_kg_keygen" -q -t ed25519 -N "" -C "luci-app-fcc" \
		-f "$FCC_REMOTE_KEY" 2>&1)" || {
		fcc_remote_error "could not generate the SSH key: $_kg_out"
		return 1
	}
	chmod 600 "$FCC_REMOTE_KEY" 2>/dev/null
	chmod 644 "$FCC_REMOTE_KEY.pub" 2>/dev/null
	printf '{"ok":true,"existing":false,"public_key":%s}\n' \
		"$(fcc_json_str "$(head -n 1 "$FCC_REMOTE_KEY.pub")")"
}

# ---------------------------------------------------------------------------
# Connection test and control
# ---------------------------------------------------------------------------

fcc_remote_ssh() {
	# Run one remote command with the shared options.
	# The caller supplies the remote command as one argument.
	_rs_ssh="$(command -v ssh 2>/dev/null)" || return 127
	fcc_remote_openssh "$_rs_ssh" || return 126
	_rs_user="$(fcc_remote_user)"
	_rs_host="$(fcc_remote_host)"
	_rs_sport="$(fcc_remote_sport)"
	# Fixed option words, intentionally split by the shell.
	"$_rs_ssh" $FCC_REMOTE_SSH_OPTS \
		-i "$FCC_REMOTE_KEY" -p "$_rs_sport" \
		-l "$_rs_user" "$_rs_host" "$1" 2>&1
}

fcc_remote_test() {
	fcc_remote_config_ok \
		|| { fcc_remote_error "the remote configuration is incomplete"; return 1; }
	fcc_remote_key_ready \
		|| { fcc_remote_error "the SSH key has not been generated"; return 1; }
	_tt_ssh="$(command -v ssh 2>/dev/null)" \
		|| { fcc_remote_error "OpenSSH client is required (package openssh-client)"; return 1; }
	fcc_remote_openssh "$_tt_ssh" \
		|| { fcc_remote_error "OpenSSH client is required (package openssh-client)"; return 1; }

	_tt_host="$(fcc_remote_host)"
	_tt_sport="$(fcc_remote_sport)"
	_tt_fp="$(fcc_remote_fingerprint)"

	# A host that has not been trusted yet is not a failure to report as one.
	# The page cannot pin a key it has never seen, so the first test scans the
	# host and answers with the fingerprint for the user to confirm; the trust
	# command then scans again and pins it only if it still matches.
	if ! fcc_remote_valid_fingerprint "$_tt_fp" || [ ! -s "$FCC_REMOTE_KNOWN" ]; then
		_tt_dir="$(fcc_remote_tmpdir)" \
			|| { fcc_remote_error "could not create a temporary directory"; return 1; }
		_tt_new="$(fcc_remote_scan_to "$_tt_dir/known_hosts" "$_tt_host" "$_tt_sport")" \
			|| _tt_new=""
		rm -rf "$_tt_dir"
		if [ -n "$_tt_new" ]; then
			printf '{"ok":false,"needs_trust":true,"fingerprint":%s,"error":%s}\n' \
				"$(fcc_json_str "$_tt_new")" \
				"$(fcc_json_str "the remote host key has not been trusted yet")"
			return 0
		fi
		fcc_remote_error "could not read the remote host key"
		return 1
	fi

	_tt_out="$(fcc_remote_ssh 'echo fcc-ok')"
	_tt_code=$?
	if [ "$_tt_code" -eq 0 ]; then
		case "$_tt_out" in
			*fcc-ok*)
				printf '{"ok":true,"output":%s}\n' "$(fcc_json_str "$(printf '%s' "$_tt_out" | tr '\n' ' ' | sed 's/  */ /g')")"
				return 0 ;;
		esac
	fi

	# A changed host key is the one failure that needs a different answer from
	# the page: it is not a typo in the address, and retrying will not help.
	_tt_dir="$(fcc_remote_tmpdir)" || _tt_dir=""
	if [ -n "$_tt_dir" ]; then
		_tt_new="$(fcc_remote_scan_to "$_tt_dir/known_hosts" \
			"$_tt_host" "$_tt_sport")" || _tt_new=""
		rm -rf "$_tt_dir"
		if [ -n "$_tt_new" ] && [ "$_tt_new" != "$_tt_fp" ]; then
			printf '{"ok":false,"fingerprint_changed":true,"fingerprint":%s,"expected":%s,"error":%s}\n' \
				"$(fcc_json_str "$_tt_new")" \
				"$(fcc_json_str "$_tt_fp")" \
				"$(fcc_json_str "the remote host key has changed")"
			return 0
		fi
	fi

	printf '{"ok":false,"output":%s,"exit":%s,"error":%s}\n' \
		"$(fcc_json_str "$(printf '%s' "$_tt_out" | tr '\n' ' ' | sed 's/  */ /g')")" \
		"$_tt_code" \
		"$(fcc_json_str "the connection failed")"
	return 0
}

fcc_remote_control() {
	_cc_op="$2"
	case "$_cc_op" in
		start|stop|restart) : ;;
		*) fcc_remote_error "invalid operation"; return 1 ;;
	esac
	[ "$(fcc_remote_target)" = "lan" ] \
		|| { fcc_remote_error "remote control is not enabled"; return 1; }
	fcc_remote_config_ok \
		|| { fcc_remote_error "the remote configuration is incomplete"; return 1; }
	fcc_remote_key_ready \
		|| { fcc_remote_error "the SSH key has not been generated"; return 1; }
	_cc_ssh="$(command -v ssh 2>/dev/null)" \
		|| { fcc_remote_error "OpenSSH client is required (package openssh-client)"; return 1; }
	fcc_remote_openssh "$_cc_ssh" \
		|| { fcc_remote_error "OpenSSH client is required (package openssh-client)"; return 1; }
	_cc_fp="$(fcc_remote_fingerprint)"
	fcc_remote_valid_fingerprint "$_cc_fp" \
		|| { fcc_remote_error "trust the remote host key first"; return 1; }
	[ -s "$FCC_REMOTE_KNOWN" ] \
		|| { fcc_remote_error "trust the remote host key first"; return 1; }

	_cc_platform="$(fcc_remote_platform)"
	_cc_service="$(fcc_remote_service)"
	case "$_cc_platform" in
		linux)
			_cc_remote="systemctl $_cc_op $_cc_service" ;;
		openwrt)
			_cc_remote="/etc/init.d/$_cc_service $_cc_op" ;;
		windows)
			case "$_cc_op" in
				start)   _cc_verb="Start-Service" ;;
				stop)    _cc_verb="Stop-Service" ;;
				restart) _cc_verb="Restart-Service" ;;
			esac
			_cc_remote="powershell.exe -NoProfile -NonInteractive -Command \"$_cc_verb -Name '$_cc_service'\"" ;;
		*)
			fcc_remote_error "invalid platform"; return 1 ;;
	esac

	_cc_out="$(fcc_remote_ssh "$_cc_remote")"
	_cc_code=$?
	if [ "$_cc_code" -eq 0 ]; then
		_cc_ok=true
	else
		_cc_ok=false
	fi
	printf '{"ok":%s,"op":%s,"output":%s,"exit":%s}\n' \
		"$_cc_ok" \
		"$(fcc_json_str "$_cc_op")" \
		"$(fcc_json_str "$(printf '%s' "$_cc_out" | tr '\n' ' ' | sed 's/  */ /g')")" \
		"$_cc_code"
	# The JSON document already says whether the operation worked; a failing
	# remote service should not also look like this script failed to answer.
	return 0
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

fcc_remote_status() {
	_st_target="$(fcc_remote_target)"
	_st_host="$(fcc_remote_host)"
	_st_user="$(fcc_remote_user)"
	_st_sport="$(fcc_remote_sport)"
	_st_aport="$(fcc_remote_aport)"
	_st_platform="$(fcc_remote_platform)"
	_st_service="$(fcc_remote_service)"
	_st_fp="$(fcc_remote_fingerprint)"

	_st_key=0
	fcc_remote_key_ready && _st_key=1
	_st_pub=""
	[ "$_st_key" = "1" ] && _st_pub="$(head -n 1 "$FCC_REMOTE_KEY.pub")"
	_st_trusted=0
	fcc_remote_valid_fingerprint "$_st_fp" && [ -s "$FCC_REMOTE_KNOWN" ] && _st_trusted=1

	# The client is part of readiness, not a separate footnote: without OpenSSH
	# (Dropbear's dbclient does not understand these options) none of the four
	# buttons can work, so the page disables them and says which package fixes
	# it rather than letting every click fail at the same place.
	_st_ssh=0
	_st_sshbin="$(command -v ssh 2>/dev/null)" || _st_sshbin=""
	if [ -n "$_st_sshbin" ] && fcc_remote_openssh "$_st_sshbin"; then _st_ssh=1; fi

	_st_ready=0
	if [ "$_st_key" = "1" ] && [ "$_st_trusted" = "1" ] \
		&& [ "$_st_ssh" = "1" ] && fcc_remote_config_ok; then
		_st_ready=1
	fi

	_st_tunnel=0
	if fcc_remote_tunnel_pid >/dev/null 2>&1 && fcc_remote_tunnel_listening; then
		_st_tunnel=1
	fi

	_st_keygen=0
	command -v ssh-keygen >/dev/null 2>&1 && _st_keygen=1
	_st_scan=0
	command -v ssh-keyscan >/dev/null 2>&1 && _st_scan=1

	printf '{"ok":true,"config":{'
	printf '"target":%s,"host":%s,"user":%s,"ssh_port":%s,"admin_port":%s,' \
		"$(fcc_json_str "$_st_target")" \
		"$(fcc_json_str "$_st_host")" \
		"$(fcc_json_str "$_st_user")" \
		"$(fcc_json_str "$_st_sport")" \
		"$(fcc_json_str "$_st_aport")"
	printf '"platform":%s,"service":%s,"fingerprint":%s},' \
		"$(fcc_json_str "$_st_platform")" \
		"$(fcc_json_str "$_st_service")" \
		"$(fcc_json_str "$_st_fp")"
	printf '"key_ready":%s,"public_key":%s,"trusted":%s,"ready":%s,' \
		"$(fcc_json_bool "$_st_key")" \
		"$(fcc_json_str "$_st_pub")" \
		"$(fcc_json_bool "$_st_trusted")" \
		"$(fcc_json_bool "$_st_ready")"
	printf '"tunnel_running":%s,"tunnel_port":%s,' \
		"$(fcc_json_bool "$_st_tunnel")" "$FCC_REMOTE_TUNNEL_PORT"
	printf '"ssh_available":%s,"keygen_available":%s,"scan_available":%s}\n' \
		"$(fcc_json_bool "$_st_ssh")" \
		"$(fcc_json_bool "$_st_keygen")" \
		"$(fcc_json_bool "$_st_scan")"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
	status)
		fcc_remote_status ;;
	keygen)
		fcc_remote_keygen ;;
	trust)
		fcc_remote_trust "$@" ;;
	test)
		fcc_remote_test ;;
	control)
		fcc_remote_control "$@" ;;
	tunnel-ensure)
		fcc_remote_tunnel_ensure ;;
	tunnel-stop)
		fcc_remote_tunnel_stop
		printf '{"ok":true}\n' ;;
	forget)
		fcc_remote_tunnel_stop
		rm -f "$FCC_REMOTE_KNOWN" "$FCC_REMOTE_KNOWN.fcc-new" 2>/dev/null
		printf '{"ok":true}\n' ;;
	*)
		fcc_remote_error "unknown remote command"
		exit 1 ;;
esac
