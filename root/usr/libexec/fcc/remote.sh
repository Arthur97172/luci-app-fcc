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
		linux|macos|openwrt|windows) return 0 ;;
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

fcc_remote_client() {
	# What `ssh` on *this* router is: openssh, dropbear, other or none.
	#
	# The distinction is what the page needs to say, because "OpenSSH is
	# required" alone sends people to install it on the remote machine — the one
	# place it does not help. On OpenWrt, dropbear offers /usr/bin/ssh through
	# the alternatives mechanism, so `command -v ssh` succeeds long before an
	# OpenSSH client exists.
	_cl_p="$(command -v ssh 2>/dev/null)" || { printf 'none'; return 0; }
	_cl_v="$("$_cl_p" -V 2>&1)"
	case "$_cl_v" in
		OpenSSH*)      printf 'openssh' ;;
		*[Dd]ropbear*) printf 'dropbear' ;;
		*)             printf 'other' ;;
	esac
}

fcc_remote_client_message() {
	# One sentence, naming the side that has to change. openssh-client-utils is
	# the package that pulls in ssh (openssh-client), ssh-keygen
	# (openssh-keygen) and ssh-keyscan, which is the whole set this feature uses.
	# It is a function of its own because two answers carry it: the error the
	# Configuration page shows, and the reason code the Web Console turns into a
	# sentence in the interface language.
	case "$(fcc_remote_client)" in
		dropbear)
			printf '%s' "ssh on this router is Dropbear, which cannot use these options; install the OpenSSH client (package openssh-client-utils) on the router" ;;
		none)
			printf '%s' "this router has no SSH client; install the OpenSSH client (package openssh-client-utils) on the router" ;;
		*)
			printf '%s' "ssh on this router is not OpenSSH; install the OpenSSH client (package openssh-client-utils) on the router" ;;
	esac
}

fcc_remote_client_error() {
	fcc_remote_error "$(fcc_remote_client_message)"
}

fcc_remote_has() {
	# Is one helper binary present? Used where its absence deserves its own
	# sentence rather than the generic "could not read the remote host key".
	command -v "$1" >/dev/null 2>&1
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
fcc_remote_service() {
	_sv_name="$(fcc_uci_get main remote_service fcc)"
	# The platform name in the service field is a mistyped form, not a service:
	# no init script is called linux, macOS, OpenWrt or Windows. Stored UCI from
	# before the page guarded the write is corrected here too, so an already
	# misconfigured router starts working without another save.
	case "$(printf '%s' "$_sv_name" | tr 'A-Z' 'a-z')" in
		linux|macos|openwrt|windows) _sv_name=fcc ;;
	esac
	printf '%s' "$_sv_name"
}
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

	[ "$(fcc_remote_client)" = "openssh" ] \
		|| { fcc_remote_client_error; return 1; }
	_te_ssh="$(command -v ssh 2>/dev/null)" \
		|| { fcc_remote_client_error; return 1; }
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
	_te_why="$(tail -n 3 "$FCC_REMOTE_TUNNEL_LOG" 2>/dev/null \
		| fcc_remote_output_filter | tr '\n' ' ' | sed 's/  */ /g')"
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
	fcc_remote_has ssh-keyscan \
		|| { fcc_remote_error "ssh-keyscan is required on this router to read the remote host key (package openssh-client-utils)"; return 1; }
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
				fcc_remote_error "ssh-keygen is required on this router to create the key (package openssh-keygen)"
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
		|| { fcc_remote_error "ssh-keygen is required on this router to create the key (package openssh-keygen)"; return 1; }
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
	# Fixed option words, intentionally split by the shell. ServerAlive* is only
	# on this path, not in the shared set: the tunnel adds its own, and a request
	# that waits on a host that stopped answering must end while the HTTP
	# request it belongs to is still alive.
	"$_rs_ssh" $FCC_REMOTE_SSH_OPTS \
		-o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
		-i "$FCC_REMOTE_KEY" -p "$_rs_sport" \
		-l "$_rs_user" "$_rs_host" "$1" 2>&1
}

# Drop the lines the local ssh client writes about itself.
#
# OpenSSH 9.9 and later print a three-line warning on every connection whose
# server does not offer a post-quantum key exchange. Every line starts with
# "**". It is about the client on this router and the version on the other
# machine, not about the operation that was asked for — left in, it is the
# first thing a failure shows and it buries the one line that matters.
fcc_remote_output_filter() {
	sed '/^\*\*/d'
}

# Why the answer was not usable, as one word the page can translate.
#
# The page is translated and the script is not, so a sentence that reaches it
# from here arrives in English. The reason travels as a code and the page says
# what it means in the interface language — and, for the two cases that are a
# misconfiguration rather than a fault, which setting to change.
fcc_remote_reason() {
	case "$1" in
		*"systemctl: not found"*)          printf 'no-systemctl' ;;
		*"/etc/init.d/$2"*"not found"*)    printf 'no-init-script' ;;
		# systemd's own words for a name that is not one of its units. On a
		# Linux machine running only free-claude-code there is no fcc.service
		# to start, and "check the service name" would send the user looking
		# for a setting that does not exist.
		*"could not be found"*)            printf 'no-service' ;;
		# Windows' own words for the same thing: Get-Service's sentence, cmd's
		# "is not recognized", and PowerShell's "The term ... is not recognized".
		# All three mean nothing by that name is installed over there, which is
		# what no-service tells the page to say.
		*"Cannot find any service"*)       printf 'no-service' ;;
		*"is not recognized"*)             printf 'no-service' ;;
		*"No such file or directory"*)     printf 'no-init-script' ;;
		*)                                 printf 'unreadable' ;;
	esac
}

# ---------------------------------------------------------------------------
# The Web Console on the LAN machine
# ---------------------------------------------------------------------------
#
# The console is one terminal in both modes: a tmux session on *this* router, a
# pipe-pane capture, an absolute offset. What differs is the process in the
# pane. Locally it is the launcher; here it is an ssh client that runs the
# launcher on the other machine with the same runtime environment (`fcc-env
# <launcher>`), so the entire transport — offsets, scrollback trimming, resize,
# close, the standalone window — is reused unchanged, and nothing new listens on
# any port.
#
# Two questions have to be answered before a pane can be made. Which agents can
# a session start over there (fcc_remote_console), and what exactly does one
# session run (fcc_remote_session_command). Both answer with a reason code
# rather than a sentence when they refuse, because the page is translated and
# this script is not: the page says what a code means in the interface
# language.
#
# The machine over there is one of three kinds. OpenWrt runs this same package,
# so it answers with its own status document and runs the launcher through
# fcc-env. A Linux or macOS machine is usually nothing but the upstream install
# — `curl -fsSL .../install.sh | sh` — which has no status.sh, no fcc-env and
# no service unit; its own shell is asked instead. A Windows machine is the
# same story in PowerShell: install.ps1 writes the launchers into the account's
# bin directories and registers no service, so its process list and its PATH
# are asked the same questions (see the Windows section below).

fcc_remote_console_error() {
	# fcc_remote_console_error <reason> <message>
	printf '{"ok":false,"reason":%s,"error":%s}\n' \
		"$(fcc_json_str "$1")" "$(fcc_json_str "$2")"
}

# The remote's own status document, guarded so a machine that never had the
# package answers with an empty line instead of an error. It is the same
# document the LAN server panel renders, and it is the only honest source of
# "which agents are installed over there": whether an agent's CLI resolves
# depends on that machine's runtime environment, which nothing here can see.
FCC_REMOTE_CONSOLE_CMD='[ -x /usr/libexec/fcc/status.sh ] && /usr/libexec/fcc/status.sh'

# ---------------------------------------------------------------------------
# A Linux or macOS machine that runs only the upstream install
# ---------------------------------------------------------------------------
#
# Upstream installs free-claude-code with `uv tool install`, which writes the
# launchers into the account's own bin directory, and lets each agent's own
# installer put its CLI somewhere else under $HOME. It installs no service
# unit. Nothing from this package is on such a machine, so there is no
# status.sh to ask and no fcc-env to apply: the remote's own shell answers.
#
# Everything below is one POSIX script run through `sh -c`, because the
# account's login shell may be zsh or fish and only `sh -c` is the same
# everywhere. The one thing the script must add is PATH — sshd gives a
# non-interactive command none of the directories the installers wrote to, and
# a launcher that is not on PATH exits 127 before the agent starts. The list
# is fcc_runtime_bin_dirs() seen from the far side, plus what npm and Homebrew
# use, in the form that side's shell expands: $HOME there, not here.

FCC_REMOTE_BARE_PATH='$HOME/.local/bin:${XDG_BIN_HOME:-$HOME/.local/bin}:$HOME/.cargo/bin:$HOME/.opencode/bin:$HOME/.local/share/pi-node/current/bin:$HOME/.grok/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin'

fcc_remote_bare_agents() {
	# id:launcher pairs from the registry — the two names the far side has to
	# resolve before a pane there can start anything.
	fcc_agents_each | awk -F'|' 'NF >= 3 && $1 != "" { printf "%s:%s\n", $1, $3 }'
}

fcc_remote_bare_server_script() {
	# One line of POSIX sh that prints "server running" or "server stopped".
	#
	# The process list is the only way to see a server a person started by hand,
	# and on these platforms that is how it is started — the upstream install
	# has no unit, and a systemd unit that does not exist reads "inactive"
	# while the server is up. pgrep is on both Linux and macOS; ps is the
	# fallback for a minimal image. The brackets keep the pattern from matching
	# this very command line, which sshd hands to the shell as an argument:
	# written plainly, every probe would answer "running".
	printf '%s' 'if command -v pgrep >/dev/null 2>&1; then if pgrep -f "[f]cc-server" >/dev/null 2>&1; then echo server running; else echo server stopped; fi; else if ps -ef 2>/dev/null | grep "[f]cc-server" >/dev/null 2>&1; then echo server running; else echo server stopped; fi; fi'
}

fcc_remote_bare_server_cmd() {
	printf 'sh -c %s' "$(fcc_shquote "$(fcc_remote_bare_server_script)")"
}

fcc_remote_bare_probe_script() {
	# The server state and every agent in the registry, one answer per line. An
	# agent counts as installed only when both its launcher and the CLI behind
	# it resolve: the launcher alone says the FCC runtime is there, and the CLI
	# alone says the launcher would have nothing to exec.
	_bp_pairs="$(fcc_remote_bare_agents | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
	printf '%s' "PATH=\"$FCC_REMOTE_BARE_PATH:\$PATH\"; export PATH; $(fcc_remote_bare_server_script); for p in $_bp_pairs; do a=\${p%%:*}; l=\${p#*:}; if command -v \"\$a\" >/dev/null 2>&1 && command -v \"\$l\" >/dev/null 2>&1; then echo \"agent \$a installed\"; else echo \"agent \$a missing\"; fi; done"
}

fcc_remote_bare_probe_cmd() {
	printf 'sh -c %s' "$(fcc_shquote "$(fcc_remote_bare_probe_script)")"
}

# ---------------------------------------------------------------------------
# A Windows machine that runs only the upstream install
# ---------------------------------------------------------------------------
#
# install.ps1 does what install.sh does, in PowerShell: `uv tool install`
# writes fcc-server, fcc-claude and the other launchers into the account's bin
# directory, each agent's installer puts its CLI in a directory of its own, and
# a desktop shortcut starts fcc-desktop. It registers no Windows service, so a
# machine that only ran the installer has nothing to ask Get-Service about, and
# the account's PATH is where the launchers are found.
#
# Windows has no `sh`, and OpenSSH hands the command to cmd.exe — the default
# shell of the Windows OpenSSH server. So every question is one
# `powershell.exe -NoProfile -NonInteractive -Command` line, and the script
# inside it is wrapped in double quotes, the only quoting cmd.exe honours. That
# makes one rule for everything below: no double quote inside the script.
# PowerShell strings are written with single quotes — those are ordinary
# characters to cmd.exe, which only sees the one quoted argument — and paths
# are built with Join-Path so no backslash has to be guessed at.

# The directories install.ps1 arranged, in the form PowerShell expands. The uv
# tool bin comes first — that is where fcc-server and the launchers are — and
# the variables that are not set contribute nothing. This is
# Add-KnownBinDirectories() seen from the far side, the way
# FCC_REMOTE_BARE_PATH is fcc_runtime_bin_dirs() seen from a POSIX shell.
FCC_REMOTE_WIN_PATH_PARTS="\$env:UV_TOOL_BIN_DIR,\$env:XDG_BIN_HOME,(Join-Path \$env:USERPROFILE '.local\bin'),(Join-Path \$env:USERPROFILE '.opencode\bin'),(Join-Path \$env:LOCALAPPDATA 'hermes\hermes-agent\bin'),(Join-Path \$env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin'),(Join-Path \$env:LOCALAPPDATA 'pi-node\current'),(Join-Path \$env:LOCALAPPDATA 'Programs\Muse Code\bin'),(Join-Path \$env:APPDATA 'npm'),\$env:GROK_BIN_DIR,(Join-Path \$env:USERPROFILE '.grok\bin')"

fcc_remote_win_path_script() {
	# One statement to run before anything is looked for. sshd gives a
	# non-interactive command the logon environment, and the installer only
	# added its directories to the shell it ran in — so the launchers are not
	# on PATH until this line runs. The empty entries left by variables that are
	# not set are dropped: an empty PATH element means "the current directory",
	# and this has no reason to put that on the search path.
	printf '%s' "\$p = @($FCC_REMOTE_WIN_PATH_PARTS) | Where-Object { \$_ }; \$env:Path = (\$p -join ';') + ';' + \$env:Path"
}

fcc_remote_win_server_script() {
	# One statement that prints "server running" or "server stopped".
	#
	# A Windows service runs fcc-server.exe too — the upstream install has no
	# service, but a user who wrapped it with NSSM or winsw gets a process of
	# the same name — and fcc-desktop is the other way the server is up. So the
	# process list answers for both the plain install and a service, which is
	# why it is also the fallback in fcc_remote_running().
	printf '%s' "if (@(Get-Process -Name 'fcc-server','fcc-desktop' -ErrorAction SilentlyContinue).Count -gt 0) { Write-Output 'server running' } else { Write-Output 'server stopped' }"
}

fcc_remote_win_agents_script() {
	# One `if` per registry pair, so the answer has the same two words the
	# POSIX probe uses. An agent counts as installed only when both its
	# launcher and the CLI behind it resolve.
	_bw_out=""
	_bw_pairs="$(fcc_remote_bare_agents)"
	while IFS=: read -r _bw_id _bw_launcher; do
		[ -n "$_bw_id" ] || continue
		_bw_out="$_bw_out if ((Get-Command '$_bw_id' -ErrorAction SilentlyContinue) -and (Get-Command '$_bw_launcher' -ErrorAction SilentlyContinue)) { Write-Output 'agent $_bw_id installed' } else { Write-Output 'agent $_bw_id missing' };"
	done <<EOF
$_bw_pairs
EOF
	printf '%s' "$_bw_out"
}

fcc_remote_win_probe_script() {
	printf '%s' "$(fcc_remote_win_path_script); $(fcc_remote_win_server_script);$(fcc_remote_win_agents_script)"
}

fcc_remote_win_cmd() {
	# fcc_remote_win_cmd <script> -> the remote command, one line.
	#
	# The script carries no double quote of its own, so this pair around it is
	# the only quoting cmd.exe has to understand.
	printf 'powershell.exe -NoProfile -NonInteractive -Command "%s"' "$1"
}

fcc_remote_win_probe_cmd() {
	fcc_remote_win_cmd "$(fcc_remote_win_probe_script)"
}

fcc_remote_win_server_cmd() {
	# The process list needs no PATH, so the running check pays for one
	# statement rather than the whole probe.
	fcc_remote_win_cmd "$(fcc_remote_win_server_script)"
}

fcc_remote_win_control_script() {
	# fcc_remote_win_control_script <op> <service> -> Start/Stop/Restart-Service
	# when the machine has a service of that name, and the upstream install's
	# process otherwise. Both branches are in the answer because which one
	# applies is a property of the machine, not of a setting this router can
	# see. -ErrorAction Stop turns a failure into a non-zero exit, which is what
	# the control verb reports.
	_wc_op="$1"
	_wc_service="$2"
	_wc_path="$(fcc_remote_win_path_script)"
	_wc_start="Start-Process -WindowStyle Hidden -FilePath (Get-Command 'fcc-server' -ErrorAction Stop).Source"
	_wc_stop="Stop-Process -Name 'fcc-server','fcc-desktop' -ErrorAction SilentlyContinue"
	case "$_wc_op" in
		start)   _wc_proc="$_wc_start" ;;
		stop)    _wc_proc="$_wc_stop" ;;
		restart) _wc_proc="$_wc_stop; Start-Sleep -Milliseconds 500; $_wc_start" ;;
	esac
	case "$_wc_op" in
		start)   _wc_verb="Start-Service" ;;
		stop)    _wc_verb="Stop-Service" ;;
		restart) _wc_verb="Restart-Service" ;;
	esac
	printf '%s' "$_wc_path; if (Get-Service -Name '$_wc_service' -ErrorAction SilentlyContinue) { $_wc_verb -Name '$_wc_service' -ErrorAction Stop } else { $_wc_proc }"
}

fcc_remote_win_session_script() {
	# The pane's command on the far side: the same PATH the probe used, then the
	# launcher. Starting the server is not this command's job — the launcher is
	# what the terminal is for. The launcher is a registry name, never anything
	# a user typed, so quoting it with PowerShell's single quotes is enough.
	printf '%s' "$(fcc_remote_win_path_script); & '$1'"
}

fcc_remote_console_cmd() {
	# What the console asks the remote for. OpenWrt answers with this package's
	# own status document, and nothing else exists there. A Linux or macOS
	# machine is asked for the same document first — a Linux host carrying the
	# package answers with it — and falls through to the bare probe when it
	# does not, in one connection either way.
	case "$(fcc_remote_platform)" in
		linux|macos)
			printf 'sh -c %s' "$(fcc_shquote "if [ -x /usr/libexec/fcc/status.sh ]; then /usr/libexec/fcc/status.sh; else $(fcc_remote_bare_probe_script); fi")" ;;
		windows)
			# There is no status.sh to ask for and no `sh` to ask with: the
			# PowerShell probe is the only answer, and it prints the same lines
			# the POSIX one does.
			fcc_remote_win_probe_cmd ;;
		*)
			printf '%s' "$FCC_REMOTE_CONSOLE_CMD" ;;
	esac
}

fcc_remote_console_bare() {
	# fcc_remote_console_bare <host> <lines> -> the document the controller
	# lifts from, or 1 when the lines held no answer at all.
	#
	# The agent names come from this router's registry, not from the far side,
	# and an id that is not in it is dropped: the remote's words are used as
	# the answer to a question, never as JSON.
	_cbb_host="$1"
	_cbb_run=false
	_cbb_agents=""
	_cbb_seen=0
	while IFS=' ' read -r _cbb_kind _cbb_id _cbb_state; do
		case "$_cbb_kind" in
			server)
				_cbb_seen=1
				[ "$_cbb_id" = "running" ] && _cbb_run=true ;;
			agent)
				fcc_valid_agent "$_cbb_id" || continue
				_cbb_seen=1
				_cbb_inst=false
				[ "$_cbb_state" = "installed" ] && _cbb_inst=true
				_cbb_agents="$_cbb_agents${_cbb_agents:+,}\"$_cbb_id\":{\"name\":$(fcc_json_str "$(fcc_agent_name "$_cbb_id")"),\"installed\":$_cbb_inst}" ;;
		esac
	done <<EOF
$2
EOF
	[ "$_cbb_seen" = "1" ] || return 1
	printf '{"ok":true,"host":%s,"status":{"server":{"running":%s},"agents":{%s}}}\n' \
		"$(fcc_json_str "$_cbb_host")" "$_cbb_run" "$_cbb_agents"
}

# The four checks every ssh verb makes, in the order that names the setting a
# user has to change first. Each one prints its refusal and returns; the caller
# only has to `return 1`.
fcc_remote_console_ready() {
	[ "$(fcc_remote_target)" = "lan" ] \
		|| { fcc_remote_console_error "not-configured" "remote control is not enabled"; return 1; }
	fcc_remote_config_ok \
		|| { fcc_remote_console_error "not-configured" "the remote configuration is incomplete"; return 1; }
	fcc_remote_key_ready \
		|| { fcc_remote_console_error "no-key" "the SSH key has not been generated"; return 1; }
	[ -s "$FCC_REMOTE_KNOWN" ] \
		|| { fcc_remote_console_error "no-host-key" "the remote host key has not been trusted"; return 1; }
	[ "$(fcc_remote_client)" = "openssh" ] \
		|| { fcc_remote_console_error "no-ssh-client" "$(fcc_remote_client_message)"; return 1; }
	return 0
}

fcc_remote_console() {
	fcc_remote_console_ready || return 1

	_cn_host="$(fcc_remote_host)"
	_cn_out="$(fcc_remote_ssh "$(fcc_remote_console_cmd)")"
	_cn_code=$?
	# Blank lines and trailing spaces are not meaningful in JSON, and dropping
	# them here keeps the `{` test below honest. A Windows answer arrives with
	# CRLF line endings, and the CR is not part of the word it ends — the bare
	# parser reads "running\r" as neither state. The document itself is passed
	# through untouched: the controller decodes it and lifts the two fields the
	# console needs, so no part of it is ever re-assembled by a shell.
	_cn_doc="$(printf '%s\n' "$_cn_out" | fcc_remote_output_filter | tr -d '\r' \
		| sed -e 's/[[:space:]]*$//' -e '/^$/d')"

	case "$_cn_doc" in
		'{'*)
			printf '{"ok":true,"host":%s,"status":%s}\n' \
				"$(fcc_json_str "$_cn_host")" "$_cn_doc"
			return 0 ;;
	esac

	# 255 is ssh's own "I could not get there": a refused connection, a wrong
	# key, a host key that no longer matches. The text that came with it names
	# which, and it is carried as the error for the log.
	if [ "$_cn_code" -eq 255 ]; then
		_cn_why="$(printf '%s' "$_cn_doc" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
		[ -n "$_cn_why" ] || _cn_why="the LAN machine could not be reached"
		fcc_remote_console_error "unreachable" "$_cn_why"
		return 1
	fi
	# A machine without the package answers in lines rather than a document.
	case "$(fcc_remote_platform)" in
		linux|macos|windows)
			fcc_remote_console_bare "$_cn_host" "$_cn_doc" && return 0 ;;
	esac
	# ssh answered, and the guard printed nothing: the remote has no status.sh,
	# which is what a machine without this package looks like.
	if [ -z "$_cn_doc" ]; then
		fcc_remote_console_error "no-agent-tools" \
			"the LAN machine does not answer with an agent list"
		return 1
	fi
	fcc_remote_console_error "unreadable" \
		"the LAN machine answered with something that is not a status document"
	return 1
}

fcc_remote_session_command() {
	# fcc_remote_session_command <agent> -> the command a pane runs, one line.
	#
	# On stdout: nothing the user typed. The agent id is checked against the
	# registry, the host and user are validated before they are stored, and the
	# key path and ssh binary are this package's own — so the line is several
	# validated words, not a string that needs escaping to be safe.
	_sc_agent="${1:-}"
	fcc_valid_agent "$_sc_agent" \
		|| { fcc_remote_console_error "invalid-agent" "unknown agent"; return 2; }
	fcc_remote_console_ready || return 1

	_sc_ssh="$(command -v ssh 2>/dev/null)" \
		|| { fcc_remote_console_error "no-ssh-client" "$(fcc_remote_client_message)"; return 1; }
	fcc_remote_openssh "$_sc_ssh" \
		|| { fcc_remote_console_error "no-ssh-client" "$(fcc_remote_client_message)"; return 1; }

	_sc_launcher="$(fcc_agent_command "$_sc_agent")"
	# What the far side runs. OpenWrt carries this package, so its runtime
	# environment is applied there by fcc-env. A Linux, macOS or Windows machine
	# carries only the upstream install: the launcher is resolved from the same
	# PATH the probe uses, and the pane gets a shell command rather than two
	# words — `export ...; exec ...` (or a PowerShell `& ...`) is passed quoted,
	# so ssh receives it as one argument and the far side expands $HOME, $PATH or
	# %USERPROFILE% there.
	_sc_probe=""
	case "$(fcc_remote_platform)" in
		linux|macos)
			_sc_probe="$(fcc_remote_bare_probe_cmd)"
			_sc_remote="$(fcc_shquote "export PATH=\"$FCC_REMOTE_BARE_PATH:\$PATH\"; exec $_sc_launcher")" ;;
		windows)
			_sc_probe="$(fcc_remote_win_probe_cmd)"
			# cmd.exe parses the one double-quoted argument and hands the script
			# to PowerShell untouched; fcc_shquote keeps the whole thing one word
			# on this side, so ssh sends it as one command.
			_sc_remote="$(fcc_shquote "$(fcc_remote_win_cmd "$(fcc_remote_win_session_script "$_sc_launcher")")")" ;;
		*)
			_sc_remote="/usr/bin/fcc-env $_sc_launcher" ;;
	esac
	if [ -n "$_sc_probe" ]; then
		# Asked before the pane starts: a session whose launcher is gone would
		# open a terminal that dies on its first word. The answer is the same
		# probe the console read, so the two cannot disagree.
		_sc_out="$(fcc_remote_ssh "$_sc_probe")"
		_sc_code=$?
		if [ "$_sc_code" -eq 255 ]; then
			_sc_why="$(printf '%s' "$_sc_out" | fcc_remote_output_filter \
				| tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
			[ -n "$_sc_why" ] || _sc_why="the LAN machine could not be reached"
			fcc_remote_console_error "unreachable" "$_sc_why"
			return 1
		fi
		case "$_sc_out" in
			*"agent $_sc_agent installed"*) : ;;
			*)
				fcc_remote_console_error "no-agent-tools" \
					"the LAN machine does not have $_sc_launcher with its client"
				return 1 ;;
		esac
	fi

	# -tt: the pane already has a pty, and forcing the allocation makes ssh hand
	#     one to the far side too — an agent draws a full-screen interface and
	#     behaves differently without it.
	# ServerAlive*: an interactive session outlives the network it started on.
	#     These end it, rather than leaving it holding an offset nobody reads.
	# LogLevel=ERROR: the post-quantum warning OpenSSH 9.9 prints on every
	#     connection would otherwise be painted into the scrollback above the
	#     agent's opening screen. remote.sh's own verbs filter that line; a
	#     terminal cannot.
	printf '%s %s -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o LogLevel=ERROR -tt -i %s -p %s -l %s %s %s\n' \
		"$(fcc_shquote "$_sc_ssh")" "$FCC_REMOTE_SSH_OPTS" \
		"$(fcc_shquote "$FCC_REMOTE_KEY")" "$(fcc_remote_sport)" \
		"$(fcc_remote_user)" "$(fcc_remote_host)" \
		"$_sc_remote"
}

fcc_remote_test() {
	fcc_remote_config_ok \
		|| { fcc_remote_error "the remote configuration is incomplete"; return 1; }
	fcc_remote_key_ready \
		|| { fcc_remote_error "the SSH key has not been generated"; return 1; }
	[ "$(fcc_remote_client)" = "openssh" ] \
		|| { fcc_remote_client_error; return 1; }

	_tt_host="$(fcc_remote_host)"
	_tt_sport="$(fcc_remote_sport)"
	_tt_fp="$(fcc_remote_fingerprint)"

	# A host that has not been trusted yet is not a failure to report as one.
	# The page cannot pin a key it has never seen, so the first test scans the
	# host and answers with the fingerprint for the user to confirm; the trust
	# command then scans again and pins it only if it still matches.
	if ! fcc_remote_valid_fingerprint "$_tt_fp" || [ ! -s "$FCC_REMOTE_KNOWN" ]; then
		fcc_remote_has ssh-keyscan \
			|| { fcc_remote_error "ssh-keyscan is required on this router to read the remote host key (package openssh-client-utils)"; return 1; }
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
				printf '{"ok":true,"output":%s}\n' "$(fcc_json_str "$(printf '%s' "$_tt_out" | fcc_remote_output_filter | tr '\n' ' ' | sed 's/  */ /g')")"
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
		"$(fcc_json_str "$(printf '%s' "$_tt_out" | fcc_remote_output_filter | tr '\n' ' ' | sed 's/  */ /g')")" \
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
	# Only start and restart belong to the LAN target. Stop is allowed whatever
	# the control target is: it is the one operation that leaves fewer servers
	# running, and the controller asks for it whenever this router's server is
	# started or this side is selected — both of which can happen while the
	# stored target still says "local", with a LAN server left over from an
	# earlier session. Refusing the stop on that ground would leave that server
	# running beside this router's own.
	if [ "$_cc_op" != "stop" ]; then
		[ "$(fcc_remote_target)" = "lan" ] \
			|| { fcc_remote_error "remote control is not enabled"; return 1; }
	fi
	fcc_remote_config_ok \
		|| { fcc_remote_error "the remote configuration is incomplete"; return 1; }
	fcc_remote_key_ready \
		|| { fcc_remote_error "the SSH key has not been generated"; return 1; }
	[ "$(fcc_remote_client)" = "openssh" ] \
		|| { fcc_remote_client_error; return 1; }
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
		macos)
			# No preset exists to run. The upstream install has no launchd job,
			# and inventing one here would start a server this router cannot
			# supervise. The answer is the reason code the page translates.
			printf '{"ok":false,"op":%s,"reason":"no-service","output":"","exit":0}\n' \
				"$(fcc_json_str "$_cc_op")"
			return 0 ;;
		openwrt)
			_cc_remote="/etc/init.d/$_cc_service $_cc_op" ;;
		windows)
			_cc_remote="$(fcc_remote_win_cmd "$(fcc_remote_win_control_script "$_cc_op" "$_cc_service")")" ;;
		*)
			fcc_remote_error "invalid platform"; return 1 ;;
	esac

	_cc_out="$(fcc_remote_ssh "$_cc_remote")"
	_cc_code=$?
	if [ "$_cc_code" -eq 0 ]; then
		_cc_ok=true
		_cc_reason=""
	else
		_cc_ok=false
		_cc_reason="$(fcc_remote_reason "$_cc_out" "$_cc_service")"
	fi
	printf '{"ok":%s,"op":%s,"reason":%s,"output":%s,"exit":%s}\n' \
		"$_cc_ok" \
		"$(fcc_json_str "$_cc_op")" \
		"$(fcc_json_str "$_cc_reason")" \
		"$(fcc_json_str "$(printf '%s' "$_cc_out" | fcc_remote_output_filter | tr '\n' ' ' | sed 's/  */ /g')")" \
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
	_st_client="$(fcc_remote_client)"
	_st_ssh=0
	[ "$_st_client" = "openssh" ] && _st_ssh=1

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
	fcc_remote_has ssh-keygen && _st_keygen=1
	_st_scan=0
	fcc_remote_has ssh-keyscan && _st_scan=1

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
	printf '"ssh_available":%s,"ssh_client":%s,"keygen_available":%s,"scan_available":%s}\n' \
		"$(fcc_json_bool "$_st_ssh")" \
		"$(fcc_json_str "$_st_client")" \
		"$(fcc_json_bool "$_st_keygen")" \
		"$(fcc_json_bool "$_st_scan")"
}

# ---------------------------------------------------------------------------
# What the LAN machine says about the server it runs
# ---------------------------------------------------------------------------

# status.sh is installed by this same package, and its JSON is the document the
# local panel already renders. So a machine that runs luci-app-fcc can describe
# its server with the same six lines this router shows for its own, and the LAN
# panel reads like the local one instead of a single sentence. A machine
# without it — a plain Linux host running only the FCC runtime, or an OpenWrt
# carrying an older package — sends nothing here, and the page keeps the
# one-line state rather than a table of dashes.
FCC_REMOTE_DETAIL_DOC=""

fcc_remote_detail_field() {
	printf '%s' "$FCC_REMOTE_DETAIL_DOC" | jsonfilter -e "$1" 2>/dev/null
}

fcc_remote_details() {
	case "$(fcc_remote_platform)" in
		openwrt|linux) : ;;
		*) return 0 ;;
	esac
	# jsonfilter is libubox's, and every OpenWrt image has it. Where it is
	# missing the state answer stands alone, which is still the truth.
	fcc_remote_has jsonfilter || return 0

	# The helper is asked for only if it is there: test -x is the whole of the
	# remote side of this, so a machine that never had the package installed
	# answers with an empty line and no error worth showing.
	_dt_doc="$(fcc_remote_ssh \
		'[ -x /usr/libexec/fcc/status.sh ] && /usr/libexec/fcc/status.sh' \
		2>/dev/null | fcc_remote_output_filter)"
	case "$_dt_doc" in
		'{'*) : ;;
		*) return 0 ;;
	esac
	FCC_REMOTE_DETAIL_DOC="$_dt_doc"
	printf ',"details":{"version":%s,"pid":%s,"uptime":%s,"memory_rss_kb":%s,"bind":%s,"port":%s}' \
		"$(fcc_json_str_or_null "$(fcc_remote_detail_field '@.fcc.version')")" \
		"$(fcc_json_num_or_null "$(fcc_remote_detail_field '@.server.pid')")" \
		"$(fcc_json_num_or_null "$(fcc_remote_detail_field '@.server.uptime')")" \
		"$(fcc_json_num_or_null "$(fcc_remote_detail_field '@.server.memory_rss_kb')")" \
		"$(fcc_json_str_or_null "$(fcc_remote_detail_field '@.server.bind')")" \
		"$(fcc_json_num_or_null "$(fcc_remote_detail_field '@.server.port')")"
}

# ---------------------------------------------------------------------------
# Is the remote server running?
# ---------------------------------------------------------------------------
#
# The page has to show the LAN server's state after a reload, the way the local
# panel already shows its own from status.sh. Nothing on this router can see a
# process on another machine, so the only honest answer is to ask: one SSH
# command, through the same checks every control verb uses.
#
# The answer is three-valued — running, stopped, or could not ask. A host that
# is switched off is not the same thing as a server that was stopped, and
# calling both "stopped" would make the one-server rule look satisfied when
# nothing had been checked.

fcc_remote_running() {
	fcc_remote_config_ok \
		|| { fcc_remote_error "the remote configuration is incomplete"; return 1; }
	fcc_remote_key_ready \
		|| { fcc_remote_error "the SSH key has not been generated"; return 1; }
	[ "$(fcc_remote_client)" = "openssh" ] \
		|| { fcc_remote_client_error; return 1; }
	_rn_fp="$(fcc_remote_fingerprint)"
	fcc_remote_valid_fingerprint "$_rn_fp" \
		|| { fcc_remote_error "trust the remote host key first"; return 1; }
	[ -s "$FCC_REMOTE_KNOWN" ] \
		|| { fcc_remote_error "trust the remote host key first"; return 1; }

	_rn_platform="$(fcc_remote_platform)"
	_rn_service="$(fcc_remote_service)"
	case "$_rn_platform" in
		linux)
			# is-active prints one word and exits 0 only for "active".
			_rn_cmd="systemctl is-active $_rn_service" ;;
		macos)
			# macOS has no unit to ask about: the server is whatever the
			# account started.
			_rn_cmd="$(fcc_remote_bare_server_cmd)" ;;
		openwrt)
			# rc.common is procd's init framework; its status verb answers with
			# the exit code (0 running, 3 not) rather than a word.
			_rn_cmd="/etc/init.d/$_rn_service status" ;;
		windows)
			_rn_cmd="powershell.exe -NoProfile -NonInteractive -Command \"(Get-Service -Name '$_rn_service').Status\"" ;;
		*)
			fcc_remote_error "invalid platform"; return 1 ;;
	esac

	_rn_out="$(fcc_remote_ssh "$_rn_cmd")"
	_rn_code=$?
	# One line, lower case, without the CR a Windows answer can leave behind —
	# the same CR that made a start's answer unparsable before fcc_json_str
	# escaped control characters.
	_rn_word="$(printf '%s' "$_rn_out" | fcc_remote_output_filter | tr -d '\r' | tr 'A-Z' 'a-z' | head -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

	_rn_known=0
	_rn_running=false
	case "$_rn_platform" in
		linux)
			# Exit 4 is systemd's "no such unit", and the word that comes with
			# it is "inactive" — which must not be read as a stopped server,
			# because on a machine that runs only the upstream install there is
			# no unit and the server may well be up. That case is answered
			# from the process list below.
			if [ "$_rn_code" -ne 4 ]; then
				case "$_rn_word" in
					active) _rn_running=true; _rn_known=1 ;;
					inactive|failed|activating|deactivating|reloading|unknown) _rn_known=1 ;;
				esac
			fi ;;
		macos)
			# The probe answers with the kind and the state together.
			case "$_rn_word" in
				'server running') _rn_running=true; _rn_known=1 ;;
				'server stopped') _rn_known=1 ;;
			esac ;;
		windows)
			case "$_rn_word" in
				running) _rn_running=true; _rn_known=1 ;;
				stopped|startpending|stoppending|paused|pausepending) _rn_known=1 ;;
			esac ;;
		openwrt)
			case "$_rn_code" in
				0) _rn_running=true; _rn_known=1 ;;
				3) _rn_known=1 ;;
			esac ;;
	esac

	# A machine running only free-claude-code has no unit to ask about — Linux
	# and Windows included, where the upstream install leaves the server as a
	# process the account started. The process list is then the honest answer —
	# the same question macOS asked from the start — and the service check's own
	# words stay in the answer for the case where neither can tell.
	if [ "$_rn_known" = "0" ] && [ "$_rn_code" -ne 255 ]; then
		_rn_probe_cmd=""
		case "$_rn_platform" in
			linux)   _rn_probe_cmd="$(fcc_remote_bare_server_cmd)" ;;
			windows) _rn_probe_cmd="$(fcc_remote_win_server_cmd)" ;;
		esac
		if [ -n "$_rn_probe_cmd" ]; then
			_rn_probe="$(fcc_remote_ssh "$_rn_probe_cmd")"
			_rn_pword="$(printf '%s' "$_rn_probe" | fcc_remote_output_filter | tr -d '\r' | tr 'A-Z' 'a-z' | head -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
			# The probe is the same one the console reads, so it says "server
			# running" rather than one word: the console needs the kind and the
			# state, and this is that line.
			case "$_rn_pword" in
				'server running') _rn_running=true; _rn_known=1 ;;
				'server stopped') _rn_known=1 ;;
			esac
		fi
	fi

	if [ "$_rn_known" = "0" ]; then
		# Say why, without saying it in English. The page turns the reason into
		# a sentence in the interface language and into the setting that has to
		# change; the raw output is only there for a person who asks for it.
		_rn_reason="$(fcc_remote_reason "$_rn_out" "$_rn_service")"
		printf '{"ok":false,"checked":false,"reason":%s,"error":%s,"output":%s}\n' \
			"$(fcc_json_str "$_rn_reason")" \
			"$(fcc_json_str "the state of the remote server could not be read")" \
			"$(fcc_json_str "$(printf '%s' "$_rn_out" | fcc_remote_output_filter | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g')")"
		return 0
	fi
	# The details are asked for only once the answer is "running": a stopped
	# machine has no pid or uptime to describe, and a check that already failed
	# should not cost a second connection.
	_rn_details=""
	[ "$_rn_running" = "true" ] && _rn_details="$(fcc_remote_details)"
	printf '{"ok":true,"checked":true,"running":%s,"output":%s%s}\n' \
		"$_rn_running" \
		"$(fcc_json_str "$(printf '%s' "$_rn_out" | fcc_remote_output_filter | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g')")" \
		"$_rn_details"
	return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
	status)
		fcc_remote_status ;;
	running)
		fcc_remote_running ;;
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
	console)
		fcc_remote_console ;;
	session-command)
		shift
		fcc_remote_session_command "${1:-}" ;;
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
