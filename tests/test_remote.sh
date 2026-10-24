#!/bin/sh
# luci-app-fcc — controlling the FCC server on one other machine.
#
# The Configuration page's FCC Server section has a [This router] [LAN] switch.
# LAN mode is one remote host, reached over SSH with a key the router generated
# itself: no password is stored or prompted for, the host key is pinned on first
# use, and the service command is a fixed preset chosen by the remote platform.
#
# root/usr/libexec/fcc/remote.sh is the whole backend, and everything below runs
# it for real against a fake uci, a fake OpenSSH client and a fake ssh-keygen —
# the same way tests/test_runtime.sh exercises common.sh. What is checked is the
# contract the page renders: the JSON answers, the exact remote command a click
# sends, and the refusals that keep a half-configured target from being used.

TESTS_NAME="remote"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

SCRIPT="$ROOT/root/usr/libexec/fcc/remote.sh"
LIBDIR="$ROOT/root/usr/libexec/fcc"
MOD="$ROOT/luasrc/fcc/adminproxy.lua"

TMP=""
BIN=""
SYSBIN=""
UCI=""
SSH_DIR=""

# A well-formed SHA256 fingerprint: 43 base64 characters is what ssh-keygen
# prints for an Ed25519 key.
FP="SHA256:$(printf '%43s' '' | tr ' ' 'A')"
FP_OTHER="SHA256:$(printf '%43s' '' | tr ' ' 'B')"

# ---------------------------------------------------------------------------
# The fake environment
# ---------------------------------------------------------------------------

make_sandbox() {
	TMP="$(mktemp -d)"
	BIN="$TMP/bin"
	SYSBIN="$TMP/sysbin"
	UCI="$TMP/uci"
	SSH_DIR="$TMP/ssh"
	mkdir -p "$BIN" "$SYSBIN" "$UCI" "$SSH_DIR"

	# A PATH with the ordinary tools remote.sh needs but without any SSH
	# binary. The host this suite runs on has a real ssh/ssh-keygen/ssh-keyscan,
	# which would otherwise be found the moment a fake one is hidden, so the
	# "package is missing" tests would silently test the host instead.
	for _tool in awk cat chmod cp cut date dirname expr find grep head id kill \
		mkdir mktemp mv ps rm sed setsid sh sleep stat tail tr wc; do
		_toolpath="$(command -v "$_tool" 2>/dev/null)" \
			&& ln -s "$_toolpath" "$SYSBIN/$_tool"
	done

	# uci -q get fcc.main.<option>, answered from a file named after the option.
	cat > "$BIN/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
[ "${1:-}" = "get" ] || exit 1
key="${2:-}"
case "$key" in
	fcc.main.*) opt="${key#fcc.main.}" ;;
	*) exit 1 ;;
esac
[ -r "$UCI_DIR/$opt" ] || exit 1
printf '%s' "$(cat "$UCI_DIR/$opt")"
EOF

	# The OpenSSH client. -V is what fcc_remote_openssh() asks; every other
	# call records its argv and answers with the canned output. Each argument
	# is written on its own line, so the last line is the remote command
	# exactly as it was passed — spaces and quotes included.
	cat > "$BIN/ssh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-V" ]; then
	printf '%s\n' "${SSH_VERSION:-OpenSSH_9.6p1, OpenSSL 3.1}" >&2
	exit 0
fi
printf 'ARG %s\n' "$@" >> "$SSH_LOG"
# A real ssh writes its last words before it exits with the failure code, so
# the canned one does too: the tests of the unreadable-answer path need both.
if [ -n "${SSH_OUT+x}" ]; then
	printf '%s\n' "$SSH_OUT"
elif [ -z "${SSH_EXIT:-}" ]; then
	printf 'fcc-ok\n'
fi
if [ -n "${SSH_EXIT:-}" ]; then exit "$SSH_EXIT"; fi
EOF

	# ssh-keyscan: one ed25519 host key line, which is all scan_to keeps.
	cat > "$BIN/ssh-keyscan" <<'EOF'
#!/bin/sh
host=""
port="22"
while [ $# -gt 0 ]; do
	case "$1" in
		-p) port="$2"; shift 2 ;;
		-T) shift 2 ;;
		*) host="$1"; shift ;;
	esac
done
printf '[%s]:%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY luci-app-fcc-test\n' "$host" "$port"
EOF

	# ssh-keygen: -lf answers with $REMOTE_FP, -y prints the public half, and
	# the generation form writes the pair to the -f path.
	cat > "$BIN/ssh-keygen" <<'EOF'
#!/bin/sh
case "${1:-}" in
	-lf)
		printf '256 %s luci-app-fcc (ED25519)\n' "$REMOTE_FP"
		exit 0 ;;
	-y)
		printf '%s\n' "${KEYGEN_PUB:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY luci-app-fcc}"
		exit 0 ;;
esac
file=""
while [ $# -gt 0 ]; do
	case "$1" in
		-f) file="$2"; shift 2 ;;
		*) shift ;;
	esac
done
[ -n "$file" ] || exit 1
printf 'PRIVATE KEY\n' > "$file"
printf '%s\n' "${KEYGEN_PUB:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY luci-app-fcc}" > "$file.pub"
EOF

	chmod +x "$BIN/uci" "$BIN/ssh" "$BIN/ssh-keyscan" "$BIN/ssh-keygen"
}

drop_sandbox() {
	if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
	TMP=""
}

# A fresh target: no UCI values beyond the defaults, no key, no pinned host.
fresh() {
	drop_sandbox
	make_sandbox
}

uci_set() { printf '%s' "$2" > "$UCI/$1"; }

# Make one helper unreachable the way a router without the package would be:
# the binary is moved out of $BIN instead of deleted, so the sandbox still
# cleans up and a later test can put it back if it needs to.
hide_tool() { mv "$BIN/$1" "$TMP/$1.off"; }

# Everything remote.sh reads, in one place. FCC_REMOTE_DIR is redirected out of
# /etc so nothing here can touch the machine the tests run on.
run_remote() {
	PATH="$BIN:$SYSBIN" \
	UCI_DIR="$UCI" \
	FCC_LIBDIR="$LIBDIR" \
	FCC_REMOTE_DIR="$SSH_DIR" \
	FCC_REMOTE_KEY="$SSH_DIR/id_ed25519" \
	FCC_REMOTE_KNOWN="$SSH_DIR/known_hosts" \
	FCC_REMOTE_TUNNEL_PID="$TMP/tunnel.pid" \
	FCC_REMOTE_TUNNEL_LOG="$TMP/tunnel.log" \
	SSH_LOG="$TMP/ssh.log" \
	REMOTE_FP="$FP" \
	sh "$SCRIPT" "$@"
}

# A configured, trusted LAN target with its key pair in place — the state the
# four buttons require.
ready_lan() {
	uci_set control_target lan
	uci_set remote_host 192.168.5.20
	uci_set remote_user fcc
	uci_set remote_ssh_port 22
	uci_set remote_admin_port 8082
	uci_set remote_platform linux
	uci_set remote_service fcc
	uci_set remote_fingerprint "$FP"
	printf '%s\n' "[192.168.5.20]:22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY x" \
		> "$SSH_DIR/known_hosts"
	printf 'PRIVATE KEY\n' > "$SSH_DIR/id_ed25519"
	printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY luci-app-fcc\n' \
		> "$SSH_DIR/id_ed25519.pub"
}

# ---------------------------------------------------------------------------
# What the page is told
# ---------------------------------------------------------------------------

test_status_reports_an_unconfigured_remote() {
	fresh
	out="$(run_remote status)"
	assert_contains "$out" '"target":"local"' \
		"the default control target is this router"
	assert_contains "$out" '"ready":false' \
		"and nothing remote is ready"
	assert_contains "$out" '"key_ready":false' \
		"there is no key yet"
	assert_contains "$out" '"trusted":false' \
		"and no pinned host key"
	assert_contains "$out" '"ssh_available":true' \
		"the fake client is OpenSSH, so the page would not warn about it"
	assert_contains "$out" '"ssh_client":"openssh"' \
		"and the exact client is named for the page's message"
	assert_contains "$out" '"keygen_available":true' \
		"ssh-keygen is present"
	assert_contains "$out" '"scan_available":true' \
		"and so is ssh-keyscan"
	drop_sandbox
}

test_a_dropbear_client_is_named_not_just_refused() {
	# On OpenWrt, Dropbear answers /usr/bin/ssh through alternatives, so
	# `command -v ssh` succeeds while none of the options this feature passes
	# exist. The page has to say Dropbear and point at this router, not at the
	# remote machine.
	fresh
	ready_lan
	out="$(SSH_VERSION='Dropbear v2022.83' run_remote status)"
	assert_contains "$out" '"ssh_client":"dropbear"' \
		"status names the Dropbear client"
	assert_contains "$out" '"ssh_available":false' \
		"and marks ssh as unusable"
	assert_contains "$out" '"ready":false' \
		"so the buttons stay disabled even with key and host pinned"
	out="$(SSH_VERSION='Dropbear v2022.83' run_remote control start)"
	assert_contains "$out" 'Dropbear' \
		"a control click explains that the client is Dropbear"
	assert_contains "$out" 'on the router' \
		"and that the package belongs on this router"
	assert_contains "$out" 'openssh-client-utils' \
		"naming the package that provides the whole tool set"
	drop_sandbox
}

test_another_ssh_client_is_also_named() {
	fresh
	ready_lan
	out="$(SSH_VERSION='Bitvise SSH Client 8.0' run_remote status)"
	assert_contains "$out" '"ssh_client":"other"' \
		"a client that is neither OpenSSH nor Dropbear is reported as other"
	out="$(SSH_VERSION='Bitvise SSH Client 8.0' run_remote control restart)"
	assert_contains "$out" 'not OpenSSH' \
		"and the refusal says it is not OpenSSH"
	assert_contains "$out" 'on the router' \
		"naming the side that has to change"
	drop_sandbox
}

test_no_ssh_client_at_all_is_reported() {
	fresh
	ready_lan
	hide_tool ssh
	out="$(run_remote status)"
	assert_contains "$out" '"ssh_client":"none"' \
		"without an ssh binary the client is none"
	assert_contains "$out" '"ssh_available":false' \
		"and ssh is not available"
	out="$(run_remote tunnel-ensure)"
	assert_contains "$out" 'no SSH client' \
		"opening the admin tunnel says there is no client"
	assert_contains "$out" 'on the router' \
		"and where to install it"
	drop_sandbox
}

test_a_missing_ssh_keygen_names_its_own_package() {
	fresh
	hide_tool ssh-keygen
	out="$(run_remote status)"
	assert_contains "$out" '"keygen_available":false' \
		"status reports the missing generator"
	out="$(run_remote keygen)"
	assert_contains "$out" 'ssh-keygen is required on this router' \
		"generating the key says ssh-keygen is missing here"
	assert_contains "$out" 'openssh-keygen' \
		"and names the package that provides it"
	drop_sandbox
}

test_a_missing_ssh_keyscan_names_its_own_package() {
	fresh
	hide_tool ssh-keyscan
	uci_set remote_host 192.168.5.20
	uci_set remote_user fcc
	printf 'PRIVATE KEY\n' > "$SSH_DIR/id_ed25519"
	printf 'ssh-ed25519 AAAA fake\n' > "$SSH_DIR/id_ed25519.pub"
	out="$(run_remote status)"
	assert_contains "$out" '"scan_available":false' \
		"status reports the missing scanner"
	out="$(run_remote test)"
	assert_contains "$out" 'ssh-keyscan is required on this router' \
		"testing says the host key cannot be read here"
	assert_contains "$out" 'openssh-client-utils' \
		"and names the package that provides it"
	drop_sandbox
}

test_status_reports_a_ready_lan_target() {
	fresh
	ready_lan
	out="$(run_remote status)"
	assert_contains "$out" '"target":"lan"' \
		"the stored target is reported"
	assert_contains "$out" '"host":"192.168.5.20"' \
		"with the address"
	assert_contains "$out" '"key_ready":true' \
		"the key exists"
	assert_contains "$out" '"trusted":true' \
		"and the host key is pinned"
	assert_contains "$out" '"ready":true' \
		"so the four buttons are enabled"
	assert_contains "$out" '"fingerprint":"'"$FP"'"' \
		"the pinned fingerprint is echoed back for the advanced panel"
	drop_sandbox
}

test_a_public_address_is_not_a_lan_target() {
	fresh
	uci_set control_target lan
	uci_set remote_host 8.8.8.8
	uci_set remote_user fcc
	out="$(run_remote status)"
	assert_contains "$out" '"ready":false' \
		"a public address does not make a usable target"
	out="$(run_remote test)"
	assert_contains "$out" 'the remote configuration is incomplete' \
		"and the test says why rather than trying it"
	drop_sandbox
}

test_a_hostname_is_refused() {
	# A name can resolve to a WAN address, which would turn "the computer on my
	# desk" into somewhere on the internet.
	fresh
	uci_set remote_host nas.lan
	uci_set remote_user fcc
	out="$(run_remote status)"
	assert_contains "$out" '"ready":false' "a hostname is not accepted"
	drop_sandbox
}

# ---------------------------------------------------------------------------
# First use: the host key is confirmed before it is pinned
# ---------------------------------------------------------------------------

test_test_scans_and_asks_for_trust_first() {
	fresh
	uci_set remote_host 192.168.5.20
	uci_set remote_user fcc
	# A key is needed before the connection is attempted.
	printf 'PRIVATE KEY\n' > "$SSH_DIR/id_ed25519"
	printf 'ssh-ed25519 AAAA fake\n' > "$SSH_DIR/id_ed25519.pub"

	out="$(run_remote test)"
	assert_contains "$out" '"needs_trust":true' \
		"the first test asks the user to confirm the host key"
	assert_contains "$out" '"fingerprint":"'"$FP"'"' \
		"and answers with the fingerprint to confirm"
	assert_contains "$out" 'not been trusted' \
		"the reason is in the same document"
	drop_sandbox
}

test_trust_pins_a_matching_fingerprint() {
	fresh
	ready_lan
	rm -f "$SSH_DIR/known_hosts"
	out="$(run_remote trust "$FP")"
	assert_contains "$out" '"ok":true' "a matching fingerprint is pinned"
	assert_contains "$out" "$FP" "and the stored value is the one that was scanned"
	assert_file "$SSH_DIR/known_hosts"
	drop_sandbox
}

test_trust_refuses_a_changed_fingerprint() {
	# The page shows one fingerprint; the machine now answers with another. That
	# is exactly the case a one-click "trust" must not paper over.
	fresh
	ready_lan
	out="$(run_remote trust "$FP_OTHER")"
	assert_contains "$out" '"fingerprint_changed":true' \
		"a host key that changed since the page read it is refused"
	assert_contains "$out" "$FP" "the fingerprint actually found is reported"
	drop_sandbox
}

# ---------------------------------------------------------------------------
# The service commands are fixed presets
# ---------------------------------------------------------------------------

test_control_refuses_outside_lan_mode() {
	fresh
	ready_lan
	uci_set control_target local
	rc=0
	out="$(run_remote control start)" || rc=$?
	assert_eq "1" "$rc" "a refusal is a failed command"
	assert_contains "$out" 'remote control is not enabled' \
		"and says the target is not the LAN"
	[ -f "$TMP/ssh.log" ] && rc=1 || rc=0
	assert_eq "0" "$rc" "no ssh process is started"
	drop_sandbox
}

test_stop_is_allowed_outside_lan_mode() {
	# The one-server rule makes the controller stop the remote server while
	# leaving LAN mode, and by then the stored target is already "local". A stop
	# refused on that ground would leave the remote server running beside this
	# router's own, so stop is the one verb the target does not gate.
	fresh
	ready_lan
	uci_set control_target local
	rc=0
	out="$(run_remote control stop)" || rc=$?
	assert_eq "0" "$rc" "a stop is accepted while the target is this router"
	assert_contains "$out" '"ok":true' "and it reports what the remote said"
	assert_eq "systemctl stop fcc" "$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')" \
		"the command is the same preset a LAN stop sends"
	drop_sandbox
}

test_running_reports_an_active_linux_service() {
	# The LAN panel has to say what the other machine is doing after a reload,
	# not only which side the switch was left on. systemctl is-active answers
	# with one word and exits 0 only for "active".
	fresh
	ready_lan
	out="$(SSH_OUT=active run_remote running)" || true
	assert_contains "$out" '"ok":true' "the check answered"
	assert_contains "$out" '"checked":true' "and it is an answer rather than a guess"
	assert_contains "$out" '"running":true' "an active service is running"
	assert_eq "systemctl is-active fcc" "$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')" \
		"systemd is asked with is-active"
	drop_sandbox
}

test_running_reports_a_stopped_linux_service() {
	fresh
	ready_lan
	out="$(SSH_OUT=inactive run_remote running)" || true
	assert_contains "$out" '"ok":true' "a stopped service is still a successful check"
	assert_contains "$out" '"running":false' "and it is reported as not running"
	drop_sandbox
}

test_running_does_not_call_an_unreachable_host_stopped() {
	# ssh's own failure (255) is not a service state. Reporting it as "not
	# running" would make the one-server rule look satisfied when nothing was
	# checked at all, so it gets its own answer.
	fresh
	ready_lan
	out="$(SSH_OUT='ssh: connect to host 192.168.5.20 port 22: Network is unreachable' \
		SSH_EXIT=255 run_remote running)" || true
	assert_contains "$out" '"ok":false' "an unreachable host is not a state answer"
	assert_contains "$out" '"checked":false' "and the page is told the check failed"
	assert_contains "$out" 'could not be read' "in words rather than as a false"
	drop_sandbox
}

test_running_uses_the_openwrt_and_windows_presets() {
	fresh
	ready_lan
	uci_set remote_platform openwrt
	out="$(SSH_OUT='' SSH_EXIT=0 run_remote running)" || true
	assert_contains "$out" '"running":true' "rc.common exits 0 when the service runs"
	assert_eq "/etc/init.d/fcc status" "$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')" \
		"OpenWrt is asked through its init script"

	uci_set remote_platform windows
	out="$(SSH_OUT='Running' run_remote running)" || true
	assert_contains "$out" '"running":true' "PowerShell prints Running"
	assert_contains "$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')" 'Get-Service' \
		"Windows is asked through PowerShell"
	drop_sandbox
}

test_running_names_a_missing_systemctl() {
	# The remote machine can be OpenWrt while the platform says Linux. Then
	# systemctl does not exist, the answer is a shell error, and the page has
	# to say which setting is wrong — in its own language. The reason travels
	# as a code; the test is that the code is there to translate.
	fresh
	ready_lan
	out="$(SSH_OUT='ash: systemctl: not found' SSH_EXIT=127 run_remote running)" || true
	assert_contains "$out" '"checked":false' "a shell error is not a state answer"
	assert_contains "$out" '"reason":"no-systemctl"' \
		"and the page is told that systemctl is missing"
	drop_sandbox
}

test_running_names_a_missing_init_script() {
	fresh
	ready_lan
	out="$(SSH_OUT='/etc/init.d/fcc: not found' SSH_EXIT=127 run_remote running)" || true
	assert_contains "$out" '"reason":"no-init-script"' \
		"a service that does not exist is named as the problem"
	drop_sandbox
}

test_running_drops_the_ssh_clients_own_warnings() {
	# OpenSSH 9.9 and later warn about post-quantum key exchange on every
	# connection. Left in, the warning is the first line of every failure and
	# the answer that matters is buried — and it is not about the operation.
	fresh
	ready_lan
	out="$(SSH_OUT="$(printf '%s\n' \
		'** WARNING: connection is not using a post-quantum key exchange algorithm.' \
		'** This session may be vulnerable to "store now, decrypt later" attacks.' \
		'** The server may need to be upgraded. See https://openssh.com/pq.html' \
		'inactive')" run_remote running)" || true
	assert_contains "$out" '"running":false' "the answer after the warning is still read"
	assert_not_contains "$out" 'post-quantum' "the warning itself is not relayed"
	assert_not_contains "$out" 'WARNING' "not even its first word"
	drop_sandbox
}

test_control_names_a_missing_systemctl() {
	fresh
	ready_lan
	out="$(SSH_OUT='ash: systemctl: not found' SSH_EXIT=127 run_remote control start)" || true
	assert_contains "$out" '"ok":false' "a failed start is reported"
	assert_contains "$out" '"reason":"no-systemctl"' \
		"and the reason is a code the page can translate"
	drop_sandbox
}

test_running_requires_a_trusted_host() {
	fresh
	ready_lan
	rm -f "$SSH_DIR/known_hosts"
	: > "$UCI/remote_fingerprint"
	out="$(run_remote running)" || true
	assert_contains "$out" 'trust the remote host key first' \
		"the check is not made before the host key is pinned"
	assert_eq "0" "$([ -f "$TMP/ssh.log" ] && echo 1 || echo 0)" "no ssh process is started"
	drop_sandbox
}

test_control_refuses_an_unknown_operation() {
	fresh
	ready_lan
	out="$(run_remote control reboot)"
	assert_contains "$out" 'invalid operation' \
		"only start, stop and restart exist"
	drop_sandbox
}

test_control_requires_a_trusted_host() {
	fresh
	ready_lan
	rm -f "$SSH_DIR/known_hosts"
	: > "$UCI/remote_fingerprint"
	out="$(run_remote control start)"
	assert_contains "$out" 'trust the remote host key first' \
		"control is refused until the host key is pinned"
	drop_sandbox
}

test_control_uses_the_linux_preset() {
	fresh
	ready_lan
	out="$(run_remote control restart)"
	assert_contains "$out" '"ok":true' "the operation reports success"
	assert_eq "systemctl restart fcc" "$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')" \
		"systemd takes systemctl <op> <service>"
	drop_sandbox
}

test_control_uses_the_openwrt_preset() {
	fresh
	ready_lan
	uci_set remote_platform openwrt
	run_remote control stop >/dev/null
	assert_eq "/etc/init.d/fcc stop" "$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')" \
		"OpenWrt runs its init script directly"
	drop_sandbox
}

test_control_uses_the_windows_preset() {
	fresh
	ready_lan
	uci_set remote_platform windows
	run_remote control start >/dev/null
	assert_eq 'powershell.exe -NoProfile -NonInteractive -Command "Start-Service -Name '"'"'fcc'"'"'"' \
		"$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')" \
		"Windows goes through PowerShell's Start-Service"
	drop_sandbox
}

test_a_hand_edited_service_name_cannot_become_a_command() {
	# UCI can be edited by hand, and this script is what builds the command.
	# Anything outside the service grammar is refused before ssh is reached.
	fresh
	ready_lan
	uci_set remote_service 'fcc;reboot'
	out="$(run_remote control start)"
	assert_contains "$out" 'the remote configuration is incomplete' \
		"a service name outside the grammar never becomes a command"
	drop_sandbox
}

# ---------------------------------------------------------------------------
# The key
# ---------------------------------------------------------------------------

test_keygen_creates_the_pair() {
	fresh
	out="$(run_remote keygen)"
	assert_contains "$out" '"ok":true' "the key is generated"
	assert_contains "$out" '"existing":false' "and reported as new"
	assert_contains "$out" 'ssh-ed25519' "the public half is returned for the page"
	assert_file "$SSH_DIR/id_ed25519"
	assert_file "$SSH_DIR/id_ed25519.pub"
	drop_sandbox
}

test_keygen_returns_an_existing_key_without_replacing_it() {
	fresh
	printf 'PRIVATE KEY\n' > "$SSH_DIR/id_ed25519"
	printf 'ssh-ed25519 AAAA existing\n' > "$SSH_DIR/id_ed25519.pub"
	out="$(run_remote keygen)"
	assert_contains "$out" '"existing":true' \
		"a second visit shows the key rather than rotating it"
	assert_eq "PRIVATE KEY" "$(cat "$SSH_DIR/id_ed25519")" \
		"the private half is untouched"
	drop_sandbox
}

# ---------------------------------------------------------------------------
# The tunnel
# ---------------------------------------------------------------------------

test_tunnel_ensure_refuses_outside_lan_mode() {
	fresh
	rc=0
	out="$(run_remote tunnel-ensure)" || rc=$?
	assert_eq "1" "$rc" "no tunnel is opened for the local target"
	assert_contains "$out" 'remote control is not enabled' "and the answer says why"
	drop_sandbox
}

test_a_stale_tunnel_pid_is_not_ours() {
	# A pid file whose number now belongs to something else must not be read as
	# a running tunnel: killing it later would kill an unrelated process.
	fresh
	sleep 30 &
	stale=$!
	printf '%s\n' "$stale" > "$TMP/tunnel.pid"
	out="$(run_remote status)"
	assert_contains "$out" '"tunnel_running":false' \
		"a pid that is not this package's ssh is not a tunnel"
	kill "$stale" 2>/dev/null
	drop_sandbox
}

test_the_tunnel_port_matches_the_proxy() {
	# Two files have to agree on the port: remote.sh forwards it and the LuCI
	# proxy dials it. A drift is a 502 that names a port nobody forwards.
	lua_port="$(grep -o 'TUNNEL_PORT = [0-9]*' "$MOD" | grep -o '[0-9]*')"
	sh_port="$(grep -o 'FCC_REMOTE_TUNNEL_PORT:-[0-9]*' "$SCRIPT" | grep -o '[0-9]*$')"
	assert_eq "18082" "$lua_port" "the proxy dials the documented tunnel port"
	assert_eq "$lua_port" "$sh_port" "and remote.sh forwards the same one"
}

# ---------------------------------------------------------------------------
# No credentials, ever
# ---------------------------------------------------------------------------

test_the_connection_is_key_only_and_pinned() {
	opts="$(sed -n '/^FCC_REMOTE_SSH_OPTS=/,/UserKnownHostsFile/p' "$SCRIPT")"
	assert_contains "$opts" 'BatchMode=yes' \
		"a failed authentication is an answer, not a prompt"
	assert_contains "$opts" 'PreferredAuthentications=publickey' \
		"only the key is offered"
	assert_contains "$opts" 'StrictHostKeyChecking=yes' \
		"an unknown host is refused, not trusted silently"
	assert_contains "$opts" 'IdentitiesOnly=yes' \
		"and only the key this package made is tried"
	assert_not_contains "$(cat "$SCRIPT")" 'sshpass' \
		"passwords are not part of the path"
	assert_not_contains "$(cat "$SCRIPT")" 'StrictHostKeyChecking=no' \
		"and host checking is never turned off"
}

test_no_password_is_stored_in_uci() {
	conf="$ROOT/root/etc/config/fcc"
	seed="$ROOT/root/etc/uci-defaults/99-fcc"
	# The file's comments explain that no password is stored, so the check looks
	# at the option lines themselves rather than at every word in the file.
	assert_eq "" "$(grep -E "^[[:space:]]*option[[:space:]]+[a-z_]*password" "$conf")" \
		"the stored configuration has no password field"
	assert_eq "" "$(grep -E "^[[:space:]]*option[[:space:]]+[a-z_]*password" "$seed")" \
		"and the seed does not add one"
	assert_eq "" "$(grep -E "^[[:space:]]*option[[:space:]]+remote_key" "$conf")" \
		"nor any private-key path: the key lives under /etc/fcc/ssh"
}

# ---------------------------------------------------------------------------
# The stored defaults agree with the script's
# ---------------------------------------------------------------------------

test_the_uci_defaults_match_the_script_defaults() {
	conf="$ROOT/root/etc/config/fcc"
	seed="$ROOT/root/etc/uci-defaults/99-fcc"
	for f in "$conf" "$seed"; do
		assert_contains "$(cat "$f")" "option control_target 'local'" \
			"$(basename "$f") defaults to this router"
		assert_contains "$(cat "$f")" "option remote_ssh_port '22'" \
			"$(basename "$f") defaults to port 22"
		assert_contains "$(cat "$f")" "option remote_admin_port '8082'" \
			"$(basename "$f") defaults to the Admin port"
		assert_contains "$(cat "$f")" "option remote_platform 'linux'" \
			"$(basename "$f") defaults to Linux"
		assert_contains "$(cat "$f")" "option remote_service 'fcc'" \
			"$(basename "$f") defaults to the fcc service"
	done
	assert_contains "$(sed -n '/fcc_remote_sport()/,+1p' "$SCRIPT")" '22' \
		"the script agrees on the SSH port"
	assert_contains "$(sed -n '/fcc_remote_aport()/,+1p' "$SCRIPT")" '8082' \
		"and on the Admin port"
}

tests_main
