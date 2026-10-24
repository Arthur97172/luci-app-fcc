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
printf 'CALL\n' >> "$SSH_LOG"
printf 'ARG %s\n' "$@" >> "$SSH_LOG"
# Two different questions arrive over the same client: the state check and
# the details fetch that asks the remote status.sh for its document. The last
# argument is the remote command, so the answer is chosen by whether it names
# status.sh; tests that never set SSH_DETAIL_OUT are answered as before.
#
# A bare Linux or macOS machine is asked with a different command — one that
# tries status.sh first and falls through to a process-list probe — and its
# answer is the probe's lines, which SSH_PROBE_OUT stands in for. The order
# matters: the console command for those platforms contains both words.
for last in "$@"; do :; done
case "${last:-}" in
	*status.sh*)
		if [ -n "${SSH_DETAIL_OUT+x}" ]; then
			printf '%s\n' "$SSH_DETAIL_OUT"
			exit 0
		fi ;;
	*pgrep*)
		if [ -n "${SSH_PROBE_OUT+x}" ]; then
			printf '%s\n' "$SSH_PROBE_OUT"
			exit 0
		fi ;;
	# A Windows probe is PowerShell rather than a shell, and the process list and
	# the launcher checks are the same two questions. Matching Get-Process and
	# Get-Command sends them to the probe's fixture too.
	*Get-Process*|*Get-Command*)
		if [ -n "${SSH_PROBE_OUT+x}" ]; then
			printf '%s\n' "$SSH_PROBE_OUT"
			exit 0
		fi ;;
esac
# A real ssh writes its last words before it exits with the failure code, so
# the canned one does too: the tests of the unreadable-answer path need both.
if [ -n "${SSH_OUT+x}" ]; then
	printf '%s\n' "$SSH_OUT"
elif [ -z "${SSH_EXIT:-}" ]; then
	printf 'fcc-ok\n'
fi
if [ -n "${SSH_EXIT:-}" ]; then exit "$SSH_EXIT"; fi
EOF

	# jsonfilter: libubox's field extractor, which remote.sh uses to read the
	# status document. The stand-in understands the expressions the script
	# writes — @.<object>.<field> — over a document whose objects are flat,
	# which is what status.sh produces. A path that names nothing prints
	# nothing and exits 1, as the real tool does.
	cat > "$BIN/jsonfilter" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
	case "$1" in
		-e) expr="$2"; shift 2 ;;
		*) shift ;;
	esac
done
doc="$(cat)"
doc="$(printf '%s' "$doc" | tr -d '\n')"
path="${expr#@.}"
section="${path%%.*}"
field="${path#*.}"
obj="$(printf '%s' "$doc" | sed -n "s/.*\"$section\"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p")"
[ -n "$obj" ] || exit 1
val="$(printf '%s' "$obj" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p")"
[ -n "$val" ] || exit 1
printf '%s\n' "$val"
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

	chmod +x "$BIN/uci" "$BIN/ssh" "$BIN/ssh-keyscan" "$BIN/ssh-keygen" "$BIN/jsonfilter"
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

# The remote command of one ssh call in the current test. The fake client
# writes a CALL line before each call's arguments, so the last argument of
# call $1 is what was asked — which stays true when a later call (the details
# fetch that follows a running answer) is made as well.
ssh_command() {
	awk -v want="${1:-1}" '
		/^CALL$/ { n++; next }
		n == want { cmd = substr($0, 5) }
		END { if (cmd != "") print cmd }
	' "$TMP/ssh.log"
}

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
	FCC_AGENTS_CONF="${AGENTS_CONF:-$ROOT/root/usr/share/luci-app-fcc/agents.conf}" \
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
	assert_eq "systemctl is-active fcc" "$(ssh_command 1)" \
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
	assert_eq "/etc/init.d/fcc status" "$(ssh_command 1)" \
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

test_running_reports_the_lan_servers_details() {
	# The LAN panel shows the same six lines the local one does: status.sh is
	# installed on that machine by this same package, so its document is the
	# answer and the page keeps one renderer for both sides.
	fresh
	ready_lan
	uci_set remote_platform openwrt
	out="$(SSH_DETAIL_OUT='{"luci_fcc": {"version": "1.0.3"}, "fcc": {"installed": true, "version": "6.16.17"}, "server": {"running": true, "pid": 28483, "uptime": 151, "memory_rss_kb": 188000, "port": 8082, "bind": "127.0.0.1"}}' \
		run_remote running)" || true
	assert_contains "$out" '"running":true' "the state is still answered"
	assert_contains "$out" '"details":{' "with the document's fields beside it"
	assert_contains "$out" '"version":"6.16.17"' "the runtime version is the remote's own"
	assert_contains "$out" '"pid":28483' "the pid is a number, not a string"
	assert_contains "$out" '"uptime":151' "uptime arrives in seconds"
	assert_contains "$out" '"memory_rss_kb":188000' "with the RSS the local panel shows"
	assert_contains "$out" '"bind":"127.0.0.1"' "and the address it listens on"
	assert_contains "$out" '"port":8082' "on the port it was asked to use"
	drop_sandbox
}

test_running_without_the_helper_keeps_the_one_line_answer() {
	# A Linux host running only the FCC runtime has no status.sh. The state is
	# still known; the six lines are not, and an object full of nulls would
	# render as a table of dashes that says less than the sentence.
	fresh
	ready_lan
	out="$(SSH_OUT='active' SSH_DETAIL_OUT='' run_remote running)" || true
	assert_contains "$out" '"running":true' "the state is still answered"
	assert_not_contains "$out" '"details"' "and nothing is invented for it"
	drop_sandbox
}

test_a_stopped_server_is_not_asked_for_details() {
	# One connection is enough to know a server is down, and there is no pid or
	# uptime to describe. The second command must not be sent.
	fresh
	ready_lan
	uci_set remote_platform openwrt
	SSH_EXIT=3 run_remote running >/dev/null 2>&1 || true
	assert_not_contains "$(cat "$TMP/ssh.log")" 'status.sh' \
		"a stopped machine is not asked for its status document"
	drop_sandbox
}

test_the_platform_name_in_the_service_field_is_corrected() {
	# The service field sits under the platform select, and the platform name
	# had been typed into it. No init script is called OpenWrt; a stored value
	# like that is the mistake, and the script has to read the default instead
	# of asking the remote machine for /etc/init.d/OpenWrt.
	fresh
	ready_lan
	uci_set remote_platform openwrt
	uci_set remote_service OpenWrt
	out="$(SSH_OUT='' SSH_EXIT=0 run_remote running)" || true
	assert_contains "$out" '"running":true' "the check uses the real service"
	assert_eq "/etc/init.d/fcc status" "$(ssh_command 1)" \
		"not /etc/init.d/OpenWrt"
	assert_contains "$(run_remote status)" '"service":"fcc"' \
		"and the page is told the name that is actually used"

	uci_set remote_platform linux
	uci_set remote_service Windows
	: > "$TMP/ssh.log"
	run_remote running >/dev/null 2>&1 || true
	assert_eq "systemctl is-active fcc" "$(ssh_command 1)" \
		"the same rule applies to every platform word"

	# macOS is a platform word too, and the lower-case comparison is what makes
	# the spelling of the option ("macOS") match.
	uci_set remote_platform macos
	uci_set remote_service macOS
	assert_contains "$(run_remote status)" '"service":"fcc"' \
		"macOS is corrected the same way"
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
	cmd="$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')"
	assert_contains "$cmd" "if (Get-Service -Name 'fcc' -ErrorAction SilentlyContinue)" \
		"Windows asks whether a service of that name exists"
	assert_contains "$cmd" "Start-Service -Name 'fcc'" "and starts it when it does"
	assert_contains "$cmd" "Start-Process -WindowStyle Hidden" \
		"falling back to the upstream install's fcc-server when it does not"
	assert_contains "$cmd" '$env:Path' "with the installer's directories on PATH"
	# cmd.exe is the shell on the far side, and it only understands double
	# quotes. The script inside them must therefore contain none of its own:
	# anything but the wrapping pair would be parsed by cmd rather than by
	# PowerShell.
	assert_eq 2 "$(printf '%s' "$cmd" | tr -cd '"' | wc -c | tr -d ' ')" \
		"the script carries no double quote of its own"
	drop_sandbox
}

test_control_on_windows_stops_and_restarts_the_process_without_a_service() {
	fresh
	ready_lan
	uci_set remote_platform windows
	run_remote control stop >/dev/null
	cmd="$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')"
	assert_contains "$cmd" "Stop-Service -Name 'fcc'" "a service is stopped when there is one"
	assert_contains "$cmd" "Stop-Process -Name 'fcc-server','fcc-desktop'" \
		"and the processes otherwise"

	run_remote control restart >/dev/null
	cmd="$(tail -n 1 "$TMP/ssh.log" | sed 's/^ARG //')"
	assert_contains "$cmd" "Restart-Service -Name 'fcc'" "restart restarts the service"
	assert_contains "$cmd" "Start-Sleep -Milliseconds 500" \
		"or stops the processes, waits, and starts the proxy again"
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

# ---------------------------------------------------------------------------
# The Web Console
#
# The console does not keep a second copy of the LAN settings or a second way
# to reach the machine: it asks this script for the remote's own status
# document (which is what lists that machine's agents) and for the ssh command
# a tmux pane should run. Both answers are JSON because the controller runs
# them through util.exec_argv, which throws stderr away — a refusal that only
# reached stderr would look like silence.
# ---------------------------------------------------------------------------

# A status document of the shape status.sh prints on the LAN machine.
LAN_DOC='{"luci_fcc": {"version": "1.0.4"}, "fcc": {"installed": true, "version": "6.16.17"}, "server": {"running": true, "pid": 28483, "port": 8082, "bind": "127.0.0.1"}, "agents": {"claude": {"name": "Claude Code", "installed": true, "running": false}, "dsh": {"name": "DeepSeek Harness", "installed": false, "running": false}}}'

test_console_answers_with_the_lan_agents() {
	fresh
	ready_lan
	out="$(SSH_DETAIL_OUT="$LAN_DOC" run_remote console)" || true
	assert_contains "$out" '"ok":true' "the console open is answered, not refused"
	assert_contains "$out" '"host":"192.168.5.20"' "the answer names the machine it describes"
	assert_contains "$out" '"agents": {' "the remote's agent map is passed through"
	assert_contains "$out" '"name": "Claude Code"' \
		"with the entries that machine reported"
	assert_contains "$out" '"running": true' "and the server state the page warns about"
	assert_contains "$(ssh_command 1)" '[ -x /usr/libexec/fcc/status.sh ]' \
		"asked for the remote's own status document first"
	assert_contains "$(ssh_command 1)" 'pgrep -f "[f]cc-server"' \
		"with the bare-host probe as the fallback in the same command"
	drop_sandbox
}

test_console_refuses_a_target_that_is_not_configured() {
	# Nothing ready: the page has to be told which step is missing rather than
	# be handed an empty agent list, which would read as "nothing installed".
	fresh
	out="$(run_remote console)" || true
	assert_contains "$out" '"ok":false' "opening the console on a bare target fails"
	assert_contains "$out" '"reason":"not-configured"' "naming the missing configuration"
	assert_not_contains "$(cat "$TMP/ssh.log" 2>/dev/null)" 'CALL' \
		"and no connection is attempted"
	drop_sandbox
}

test_console_names_each_missing_piece() {
	# Each refusal is a different repair, so each has its own reason code: key,
	# pinned host, and the client on this router.
	fresh
	ready_lan
	rm -f "$SSH_DIR/id_ed25519"
	out="$(run_remote console)" || true
	assert_contains "$out" '"reason":"no-key"' "a missing key is its own reason"

	fresh
	ready_lan
	: > "$SSH_DIR/known_hosts"
	out="$(run_remote console)" || true
	assert_contains "$out" '"reason":"no-host-key"' \
		"an untrusted host key is its own reason"

	fresh
	ready_lan
	hide_tool ssh
	out="$(run_remote console)" || true
	assert_contains "$out" '"reason":"no-ssh-client"' \
		"a missing client is its own reason"
	assert_contains "$out" 'openssh-client-utils' \
		"and still names the package that provides it"
	drop_sandbox
}

test_console_does_not_take_an_unreachable_answer_for_a_state() {
	fresh
	ready_lan
	out="$(SSH_OUT='ssh: connect to host 192.168.5.20 port 22: Connection refused' \
		SSH_EXIT=255 run_remote console)" || true
	assert_contains "$out" '"reason":"unreachable"' "ssh's own failure is named as such"
	assert_contains "$out" 'Connection refused' "with the words that say why"
	drop_sandbox
}

test_console_reports_a_machine_without_the_helper() {
	# ssh answered and the guard printed nothing: that machine has no
	# status.sh, which is what a host without this package looks like.
	fresh
	ready_lan
	out="$(SSH_DETAIL_OUT='' run_remote console)" || true
	assert_contains "$out" '"reason":"no-agent-tools"' \
		"a machine without the package is named"
	drop_sandbox

	# And an answer that is not a document at all is not read as one.
	fresh
	ready_lan
	out="$(SSH_OUT='hello' run_remote console)" || true
	assert_contains "$out" '"reason":"unreadable"' \
		"anything else is unreadable, not a status"
	drop_sandbox
}

test_console_drops_the_clients_own_warnings() {
	# OpenSSH 9.9 prints a post-quantum note on every connection. The document
	# follows it, and the page's decoder must still see a document.
	fresh
	ready_lan
	out="$(SSH_DETAIL_OUT='** WARNING: connection is not using a post-quantum key exchange
** The server may need to be upgraded. See https://openssh.com/pq.html
'"$LAN_DOC" run_remote console)" || true
	assert_contains "$out" '"ok":true' "the document after the warning is read"
	assert_not_contains "$out" 'post-quantum' "and the warning itself is not relayed"
	drop_sandbox
}

test_session_command_is_one_line_a_pane_can_run() {
	# The pane runs this exact line, so the test pins it word by word: the
	# shared options, the two interactive-only ones, a forced pty, the key, the
	# port, the user, the host, and the launcher reached through fcc-env.
	# OpenWrt is the platform that carries this package, so it is the one whose
	# pane goes through fcc-env.
	fresh
	ready_lan
	uci_set remote_platform openwrt
	out="$(run_remote session-command claude)" || true
	assert_eq "'$BIN/ssh' \
-o BatchMode=yes \
-o ConnectTimeout=8 \
-o ConnectionAttempts=1 \
-o IdentitiesOnly=yes \
-o PreferredAuthentications=publickey \
-o StrictHostKeyChecking=yes \
-o UserKnownHostsFile=$SSH_DIR/known_hosts \
-o ServerAliveInterval=15 \
-o ServerAliveCountMax=3 \
-o LogLevel=ERROR \
-tt \
-i '$SSH_DIR/id_ed25519' \
-p 22 \
-l fcc \
192.168.5.20 \
/usr/bin/fcc-env fcc-claude" "$out" \
		"the pane command is the key-only ssh call that runs the agent"

	out="$(run_remote session-command dsh)" || true
	assert_contains "$out" 'fcc-env fcc-dsh' \
		"the launcher comes from this package's agent registry"
	assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" \
		"and the whole command is one line"
	drop_sandbox
}

test_session_command_refuses_what_it_cannot_safely_run() {
	# The line is executed by a shell, so the agent id is checked against the
	# registry before anything is printed.
	fresh
	ready_lan
	out="$(run_remote session-command 'x; rm -rf /')" || true
	assert_contains "$out" '"ok":false' "an unknown id is refused"
	assert_contains "$out" '"reason":"invalid-agent"' "as an unknown agent"

	fresh
	out="$(run_remote session-command claude)" || true
	assert_contains "$out" '"reason":"not-configured"' \
		"and a bare target is refused before the ssh line is built"
	drop_sandbox
}

# ---------------------------------------------------------------------------
# A Linux or macOS machine that runs only the upstream install
#
# `curl -fsSL .../install.sh | sh` writes the launchers into the account's bin
# directory and installs no service unit. There is no status.sh to ask and no
# fcc-env to run, so the answers come from the far side's own shell: one probe
# whose lines say which agents resolve and whether a server is up.
# ---------------------------------------------------------------------------

# What the probe prints: the server state, then one line per registry agent.
BARE_PROBE='server stopped
agent claude installed
agent codex missing
agent dsh missing'

test_console_reads_a_bare_machine_from_the_probe() {
	fresh
	ready_lan
	# The command asks for status.sh first and falls through; the answer here is
	# what the fallback prints on a machine that has none.
	out="$(SSH_DETAIL_OUT="$BARE_PROBE" run_remote console)" || true
	assert_contains "$out" '"ok":true' "the console open is answered"
	assert_contains "$out" '"host":"192.168.5.20"' "naming the machine"
	assert_contains "$out" '"running":false' "a stopped server is reported as such"
	assert_contains "$out" '"claude":{"name":"Claude Code","installed":true}' \
		"an installed agent carries the registry's display name"
	assert_contains "$out" '"codex":{"name":"Codex","installed":false}' \
		"and a missing one is marked not installed"
	drop_sandbox
}

test_console_drops_an_agent_the_registry_does_not_have() {
	# The remote's words are the answer to a question, never JSON: an id this
	# router does not know must not reach the document it is pasted into.
	fresh
	ready_lan
	out="$(SSH_DETAIL_OUT='server stopped
agent ../../etc installed' run_remote console)" || true
	assert_contains "$out" '"ok":true' "the answer is still a document"
	assert_not_contains "$out" '../../etc' "the unknown id never reaches it"
	assert_contains "$out" '"agents":{}' "and the map it would have joined is empty"
	drop_sandbox
}

test_console_calls_an_answer_it_cannot_read_unreadable() {
	# Lines that are not the probe's are not guessed at.
	fresh
	ready_lan
	out="$(SSH_DETAIL_OUT='hello there' run_remote console)" || true
	assert_contains "$out" '"reason":"unreadable"' \
		"anything else is unreadable, not a status"
	drop_sandbox
}

test_session_command_on_a_bare_machine_runs_the_launcher_through_its_shell() {
	# No fcc-env exists there, so the pane gets the far side's shell: the PATH
	# the probe used, then the launcher. The whole thing is one quoted argument,
	# which ssh hands to that shell unchanged.
	fresh
	ready_lan
	out="$(SSH_PROBE_OUT='server running
agent claude installed' run_remote session-command claude)" || true
	assert_contains "$out" 'exec fcc-claude'"'"'' \
		"the pane execs the launcher by name from the exported PATH"
	assert_contains "$out" "'export PATH=" \
		"after exporting it, in one quoted word"
	assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" \
		"and the whole command is one line"
	assert_contains "$(ssh_command 1)" 'pgrep -f "[f]cc-server"' \
		"the agent is checked on that machine before the pane opens"

	# A launcher the probe did not find is refused, because the pane would open
	# a terminal that dies on its first word.
	fresh
	ready_lan
	out="$(SSH_PROBE_OUT='server running
agent claude missing' run_remote session-command claude)" || true
	assert_contains "$out" '"ok":false' "a missing agent is refused"
	assert_contains "$out" '"reason":"no-agent-tools"' "as a machine without it"
	drop_sandbox
}

test_session_command_names_a_bare_machine_that_cannot_be_reached() {
	fresh
	ready_lan
	out="$(SSH_OUT='ssh: connect to host 192.168.5.20 port 22: Network is unreachable' \
		SSH_EXIT=255 run_remote session-command claude)" || true
	assert_contains "$out" '"reason":"unreachable"' "ssh's failure is named as such"
	assert_contains "$out" 'Network is unreachable' "with the words that say why"
	drop_sandbox
}

test_console_reads_a_windows_machine_from_the_powershell_probe() {
	# A Windows machine that only ran install.ps1 has no sh, no status.sh and no
	# fcc-env, so the console cannot ask it the POSIX way. It is asked with one
	# PowerShell line, and the lines it prints are the same two kinds the POSIX
	# probe prints — so the document the page renders is identical.
	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_PROBE_OUT='server running
agent claude installed
agent codex missing' run_remote console)" || true
	assert_contains "$out" '"ok":true' "the console open is answered"
	assert_contains "$out" '"running":true' "the process list decides the server state"
	assert_contains "$out" '"claude":{"name":"Claude Code","installed":true}' \
		"an installed agent is reported"
	assert_contains "$out" '"codex":{"name":"Codex","installed":false}' \
		"and a missing one is not"
	assert_contains "$(ssh_command 1)" \
		'powershell.exe -NoProfile -NonInteractive -Command "$p = @(' \
		"Windows is asked with one PowerShell line, starting at the PATH setup"
	assert_contains "$(ssh_command 1)" 'Get-Process -Name' \
		"which puts the process list in the same answer"
	assert_not_contains "$(ssh_command 1)" 'status.sh' \
		"and never with the POSIX helper it does not have"
	assert_contains "$(ssh_command 1)" "Get-Command 'claude'" \
		"the launcher check is PowerShell's own"
	drop_sandbox
}

test_console_reads_a_windows_answer_that_arrived_with_crlf() {
	# PowerShell writes CRLF, and the CR belongs to the line ending, not to the
	# word: "running\r" is not either state, and the server would read stopped.
	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_PROBE_OUT="$(printf 'server running\r\nagent claude installed\r')" \
		run_remote console)" || true
	assert_contains "$out" '"running":true' "the CR is not part of the state word"
	assert_contains "$out" '"claude":{"name":"Claude Code","installed":true}' \
		"nor of the agent's"
	drop_sandbox
}

test_session_command_on_windows_runs_the_launcher_through_powershell() {
	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_PROBE_OUT='server running
agent claude installed' run_remote session-command claude)" || true
	assert_contains "$out" 'powershell.exe -NoProfile' "the pane runs PowerShell"
	assert_contains "$out" '$env:Path' "with the installer's directories on PATH"
	assert_contains "$out" 'fcc-claude' "and starts the launcher"
	assert_contains "$out" '& ' "through PowerShell's call operator"
	assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" \
		"the whole command is one line"
	# The line is a local shell word, so the quotes ssh must receive are still
	# there — the pane's shell hands the whole command over as one argument.
	assert_contains "$out" '-Command "' "the -Command argument survives quoting"
	assert_contains "$(ssh_command 1)" 'Get-Process' \
		"the agent is checked on that machine before the pane opens"

	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_PROBE_OUT='server running
agent claude missing' run_remote session-command claude)" || true
	assert_contains "$out" '"reason":"no-agent-tools"' \
		"and a launcher the probe did not find is refused"
	drop_sandbox
}

test_running_falls_back_to_the_process_list_on_windows() {
	# Get-Service's own words for a name it does not know are not a state: a
	# machine that only ran install.ps1 has no service, and its server may well
	# be up. The process list is asked second, and it is the honest answer.
	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_OUT="Get-Service : Cannot find any service with service name 'fcc'." \
		SSH_PROBE_OUT='server running' run_remote running)" || true
	assert_contains "$out" '"running":true' "the process list decides"
	assert_contains "$(ssh_command 1)" 'Get-Service' "Get-Service is still asked first"
	assert_contains "$(ssh_command 2)" 'Get-Process' "and the process list second"
	drop_sandbox
}

test_windows_errors_are_named_as_a_missing_service() {
	# The page translates a reason code, so Windows' own wording for "nothing by
	# that name is here" has to reach it as one.
	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_OUT="'fcc-server' is not recognized as an internal or external command" \
		SSH_EXIT=1 run_remote control start)" || true
	assert_contains "$out" '"reason":"no-service"' \
		"cmd's not-recognized is the same answer as a missing service"
	drop_sandbox
}

test_macos_is_a_platform_the_backend_accepts() {
	fresh
	ready_lan
	uci_set remote_platform macos
	out="$(run_remote status)"
	assert_contains "$out" '"platform":"macos"' "status reports it back"
	assert_contains "$out" '"ready":true' "and the target stays usable"
	drop_sandbox
}

test_running_falls_back_to_the_process_list_without_a_unit() {
	# systemd answers "inactive" with exit 4 for a unit it does not know, and a
	# machine running only the upstream install has no unit while its server may
	# well be up. The word alone would report a stopped server that is running.
	fresh
	ready_lan
	out="$(SSH_OUT='inactive' SSH_EXIT=4 SSH_PROBE_OUT='server running' \
		run_remote running)" || true
	assert_contains "$out" '"running":true' "the process list decides"
	assert_eq 'systemctl is-active fcc' "$(ssh_command 1)" \
		"systemd is still asked first"
	assert_contains "$(ssh_command 2)" 'pgrep -f "[f]cc-server"' \
		"and the process list second"

	fresh
	ready_lan
	out="$(SSH_OUT='inactive' SSH_EXIT=4 SSH_PROBE_OUT='server stopped' \
		run_remote running)" || true
	assert_contains "$out" '"running":false' "a server the list does not show is stopped"
	drop_sandbox
}

test_running_on_macos_asks_only_the_process_list() {
	# There is no unit to ask about on macOS, so the check is the process list
	# from the start — one connection, not two.
	fresh
	ready_lan
	uci_set remote_platform macos
	out="$(SSH_PROBE_OUT='server running' run_remote running)" || true
	assert_contains "$out" '"running":true' "the process list is the answer"
	assert_contains "$(ssh_command 1)" 'pgrep -f "[f]cc-server"' \
		"and it is the first thing asked"
	drop_sandbox
}

test_control_on_macos_refuses_without_inventing_a_unit() {
	# The upstream install writes no launchd job. A preset here would start a
	# server this router could not supervise, so the click is answered with the
	# reason the page translates instead.
	fresh
	ready_lan
	uci_set remote_platform macos
	out="$(run_remote control start)" || true
	assert_contains "$out" '"ok":false' "a start is refused"
	assert_contains "$out" '"reason":"no-service"' "as a machine with no service"
	assert_not_contains "$(cat "$TMP/ssh.log" 2>/dev/null)" 'CALL' \
		"and nothing is sent, because nothing could run"
	drop_sandbox
}

test_control_names_a_unit_systemd_does_not_have() {
	fresh
	ready_lan
	out="$(SSH_OUT='Unit fcc.service could not be found.' SSH_EXIT=4 \
		run_remote control restart)" || true
	assert_contains "$out" '"ok":false' "a restart that found no unit failed"
	assert_contains "$out" '"reason":"no-service"' \
		"and the page is told it is a missing service, not a missing service name"
	drop_sandbox
}

tests_main
