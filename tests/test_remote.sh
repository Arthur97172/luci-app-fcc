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
#
# The details fetch that follows a "running" answer is its own script, and it
# reads the process list too — so it is recognised by the process-list question
# only it asks (etimes/etime) and answered from SSH_DETAILS_OUT, before the
# state probe's fixture can claim it.
for last in "$@"; do :; done
case "${last:-}" in
	# The sshd drop-in a Linux start, stop or restart carries is its own
	# connection, and it is the only command that names the configuration file.
	# Without a fixture it answers nothing, which reads as "no word came back".
	*sshd_config*)
		if [ -n "${SSH_FW_OUT+x}" ]; then
			printf '%s\n' "$SSH_FW_OUT"
			exit "${SSH_FW_EXIT:-0}"
		fi ;;
	*status.sh*)
		if [ -n "${SSH_DETAIL_OUT+x}" ]; then
			printf '%s\n' "$SSH_DETAIL_OUT"
			exit 0
		fi ;;
	*etime*)
		if [ -n "${SSH_DETAILS_OUT+x}" ]; then
			printf '%s\n' "$SSH_DETAILS_OUT"
			exit "${SSH_DETAILS_EXIT:-0}"
		fi ;;
	# The Windows details script is the process-list question asked in
	# PowerShell, and it also names Get-Process — so it is recognised by the
	# memory it reads, before the probe's own case can claim it.
	*WorkingSet64*)
		if [ -n "${SSH_DETAILS_OUT+x}" ]; then
			printf '%s\n' "$SSH_DETAILS_OUT"
			exit "${SSH_DETAILS_EXIT:-0}"
		fi ;;
	*pgrep*)
		if [ -n "${SSH_PROBE_OUT+x}" ]; then
			printf '%s\n' "$SSH_PROBE_OUT"
			exit "${SSH_PROBE_EXIT:-0}"
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
# Whether a unit exists at all is asked separately, after a control command
# failed in a way that could be either a missing unit or missing rights. That
# question is not the last argument, so it is matched across the whole argv.
case "$*" in
	*list-unit-files*)
		if [ -n "${SSH_UNIT_OUT+x}" ]; then
			printf '%s\n' "$SSH_UNIT_OUT"
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

	# ssh-keygen: -lf answers with $REMOTE_FP, -y prints the public half of a
	# file that parses the way the real tool's does, and the generation form
	# writes the pair to the -f path.
	#
	# The -y fake refuses anything but the OpenSSH container the generation
	# form writes, with the real tool's sentence and exit code. That is what a
	# key in another format — Dropbear's 83-byte blob is the one this package
	# met — produces, and the tests for an unusable key depend on it.
	cat > "$BIN/ssh-keygen" <<'EOF'
#!/bin/sh
case "${1:-}" in
	-lf)
		printf '256 %s luci-app-fcc (ED25519)\n' "$REMOTE_FP"
		exit 0 ;;
	-y)
		file=""
		while [ $# -gt 0 ]; do
			case "$1" in
				-f) file="$2"; shift 2 ;;
				*) shift ;;
			esac
		done
		case "$(cat "$file" 2>/dev/null)" in
			'PRIVATE KEY'*) : ;;
			*) printf 'Load key "%s": invalid format\n' "$file" >&2; exit 255 ;;
		esac
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
	# The remote command is one argv word, and a script it carries may run to
	# several lines: the log writes one line per word, so a line without the
	# ARG prefix continues the word before it.
	awk -v want="${1:-1}" '
		/^CALL$/ { if (n == want && cmd != "") print cmd; n++; next }
		n == want {
			if (substr($0, 1, 4) == "ARG ") cmd = substr($0, 5)
			else if (cmd != "") cmd = cmd "\n" $0
		}
		END { if (n == want && cmd != "") print cmd }
	' "$TMP/ssh.log"
}

# The remote command of the last ssh call. An operation reaches the service
# command last — a Linux start, stop or restart sends the sshd drop-in first —
# so this is the one assertion that does not depend on how many calls came
# before it.
ssh_last_command() {
	ssh_command "$(awk '/^CALL$/ { n++ } END { print n + 0 }' "$TMP/ssh.log" 2>/dev/null)"
}

# A key pair the fake ssh-keygen agrees is a pair: "PRIVATE KEY" parses, and
# its derived public half is the same line the .pub holds. Written by one
# helper so a fixture cannot half-disagree and turn another test's failure into
# a key-mismatch refusal.
fake_key() {
	printf 'PRIVATE KEY\n' > "$SSH_DIR/id_ed25519"
	printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY luci-app-fcc\n' \
		> "$SSH_DIR/id_ed25519.pub"
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
	fake_key
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
	fake_key

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
	# The stop itself is the first connection on Linux; the sshd drop-in it
	# leaves behind a stopped server follows it.
	assert_contains "$(ssh_command 1)" 'then systemctl stop fcc' \
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
	assert_contains "$(ssh_command 1)" 'then systemctl is-active fcc' \
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
	assert_contains "$out" '"reason":"unreachable"' \
		"and the reason is the machine, not an answer in the wrong form"
	drop_sandbox
}

test_running_names_a_refused_key() {
	# The far side answered and refused the key: a fresh key whose public half
	# has not been added to the account's authorized_keys yet.
	fresh
	ready_lan
	out="$(SSH_OUT='arthur@192.168.5.20: Permission denied (publickey,password).' \
		SSH_EXIT=255 run_remote running)" || true
	assert_contains "$out" '"reason":"auth"' \
		"a refused key is named as the authentication it is"
	drop_sandbox
}

test_running_names_a_changed_host_key() {
	fresh
	ready_lan
	out="$(SSH_OUT='@@@@@@@ WARNING @@@@@@@ Host key verification failed.' \
		SSH_EXIT=255 run_remote running)" || true
	assert_contains "$out" '"reason":"host-key"' \
		"a host key that no longer matches is its own answer"
	drop_sandbox
}

test_test_names_a_refused_key() {
	# A key in the router's own format that the far side refuses — the state a
	# first setup is in before its public half is added over there.
	fresh
	ready_lan
	out="$(SSH_OUT='arthur@192.168.5.20: Permission denied (publickey,password).' \
		SSH_EXIT=255 run_remote test)" || true
	assert_contains "$out" '"ok":false' "the test failed"
	assert_contains "$out" '"reason":"auth"' \
		"and says the key was refused rather than that the connection failed"
	drop_sandbox
}

test_test_names_an_unreachable_machine() {
	fresh
	ready_lan
	out="$(SSH_OUT='ssh: connect to host 192.168.5.20 port 22: Connection refused' \
		SSH_EXIT=255 run_remote test)" || true
	assert_contains "$out" '"reason":"unreachable"' \
		"a machine that did not answer is named as such"
	drop_sandbox
}

test_running_uses_the_openwrt_and_windows_presets() {
	fresh
	ready_lan
	uci_set remote_platform openwrt
	out="$(SSH_OUT='running' SSH_EXIT=0 run_remote running)" || true
	assert_contains "$out" '"running":true' "procd's running word is a running server"
	assert_contains "$(ssh_command 1)" 'then /etc/init.d/fcc status' \
		"OpenWrt is asked through its init script"

	uci_set remote_platform windows
	: > "$TMP/ssh.log"
	out="$(SSH_OUT='Running' run_remote running)" || true
	assert_contains "$out" '"running":true' "PowerShell prints Running"
	assert_contains "$(ssh_command 1)" 'Get-Service' \
		"Windows is asked through PowerShell"
	drop_sandbox
}

test_running_on_openwrt_reads_procds_words_not_its_exit_code() {
	# rc.common's status verb answers with a word, and the exit code does not
	# carry the same news: "active with no instances" exits 0 for a service
	# that never opened one — what this package's init script leaves behind
	# when the runtime is absent. The word decides, and the process list has
	# the last word when the word settles nothing.
	fresh
	ready_lan
	uci_set remote_platform openwrt
	out="$(SSH_OUT='active with no instances' SSH_EXIT=0 \
		SSH_PROBE_OUT='server stopped' run_remote running)" || true
	assert_contains "$out" '"running":false' \
		"a service with no instance is not a running server"
	out="$(SSH_OUT='not running' SSH_EXIT=5 run_remote running)" || true
	assert_contains "$out" '"running":false' "procd's own stopped word is read"
	assert_not_contains "$out" '"checked":false' "and it is an answer, not a failure"
	out="$(SSH_OUT='running (1/2)' SSH_EXIT=0 run_remote running)" || true
	assert_contains "$out" '"running":true' \
		"a partly running service is running"
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

test_running_on_openwrt_without_its_init_script_asks_the_process_list() {
	# A machine carrying only the upstream install has no /etc/init.d/fcc, so
	# the status verb would answer "not found". The init script is tested for
	# first, in the same command, and the process list answers when it is
	# absent — the same question a Linux machine without its unit is asked.
	fresh
	ready_lan
	uci_set remote_platform openwrt
	out="$(SSH_PROBE_OUT='server running' run_remote running)" || true
	assert_contains "$out" '"running":true' "the process list decides"
	assert_contains "$(ssh_command 1)" '[ -x /etc/init.d/fcc ]' \
		"the init script is looked for first"
	assert_contains "$(ssh_command 1)" 'then /etc/init.d/fcc status' \
		"and used when it is there"
	assert_contains "$(ssh_command 1)" 'pgrep -f "[f]cc-server"' \
		"with the process list as the fallback in the same command"
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
	out="$(SSH_OUT='running' \
		SSH_DETAIL_OUT='{"luci_fcc": {"version": "1.0.3"}, "fcc": {"installed": true, "version": "6.16.17"}, "server": {"running": true, "pid": 28483, "uptime": 151, "memory_rss_kb": 188000, "port": 8082, "bind": "127.0.0.1"}}' \
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

test_running_describes_a_bare_machine_from_its_process_list() {
	# A machine that ran only the upstream install has no status.sh to ask, but
	# it does have the six facts the local panel shows, and its own process list
	# and launcher answer them. The pid is the anchor: the document is built from
	# the lines that came back, and a field the machine did not fill stays null
	# so the page draws a dash there rather than a guess.
	fresh
	ready_lan
	out="$(SSH_OUT='active' SSH_DETAILS_OUT='pid=332012
uptime=151
rss_kb=188000
version=6.18.3
bind=0.0.0.0
port=8082' run_remote running)" || true
	assert_contains "$out" '"running":true' "the state is still answered"
	assert_contains "$out" '"details":{' "and the bare machine is described"
	assert_contains "$out" '"version":"6.18.3"' "with the launcher's own version"
	assert_contains "$out" '"pid":332012' "as a number, not a string"
	assert_contains "$out" '"uptime":151' "the seconds it has been up"
	assert_contains "$out" '"memory_rss_kb":188000' "its RSS"
	assert_contains "$out" '"bind":"0.0.0.0"' "the address it listens on"
	assert_contains "$out" '"port":8082' "and that address's port"

	# One POSIX script on the far side, and it must not spell the launcher's
	# name: sshd hands the script to sh as an argument, so the probe would find
	# that shell instead of the server. The status.sh question is the second
	# connection, so the process-list script is the third.
	assert_not_contains "$(ssh_command 3)" 'fcc-server' \
		"the launcher name is never spelled out in the script"
	assert_contains "$(ssh_command 3)" 'ps -o etimes=' \
		"uptime comes from the process list"
	assert_contains "$(ssh_command 3)" 'ss -ltnp' \
		"and the listening socket from ss"
	drop_sandbox
}

test_running_keeps_the_one_line_when_the_bare_answer_names_no_process() {
	# The state check said "running" and the process list then named no pid —
	# a server that stopped between the two connections. There is nothing to
	# describe, and the answer must not be a document full of nulls.
	fresh
	ready_lan
	out="$(SSH_OUT='active' SSH_DETAILS_OUT='version=6.18.3' run_remote running)" || true
	assert_contains "$out" '"running":true' "the state answer stands"
	assert_not_contains "$out" '"details"' "with nothing invented beside it"
	drop_sandbox
}

test_running_on_macos_asks_the_process_list_for_details() {
	# This package is not installed on macOS, so there is no status.sh there
	# either; the machine answers the same six questions about its own process.
	fresh
	ready_lan
	uci_set remote_platform macos
	out="$(SSH_OUT='server running' SSH_DETAILS_OUT='pid=901
uptime=4
rss_kb=120000
version=6.18.3' run_remote running)" || true
	assert_contains "$out" '"details":{' "macOS gets the same six lines"
	assert_contains "$out" '"pid":901' "from its own process list"
	assert_contains "$out" '"uptime":4' "and its own uptime"
	assert_not_contains "$(ssh_command 1)" 'status.sh' \
		"without asking a helper it does not have"
	drop_sandbox
}

test_running_describes_a_windows_machine_from_its_process_list() {
	# Windows has no status.sh either — this package does not install there — so
	# the same six questions are asked of the process and of the socket it owns,
	# in PowerShell. The answer is the same key=value lines, which is what lets
	# the page keep one parser and one renderer for all four platforms.
	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_OUT='Running' SSH_DETAILS_OUT='pid=4242
uptime=95
rss_kb=210000
version=6.18.3
bind=127.0.0.1
port=8082' run_remote running)" || true
	assert_contains "$out" '"running":true' "the state is still answered"
	assert_contains "$out" '"details":{' "and Windows gets the same six lines"
	assert_contains "$out" '"pid":4242' "from its own process list"
	assert_contains "$out" '"uptime":95' "its own uptime"
	assert_contains "$out" '"memory_rss_kb":210000' "its working set"
	assert_contains "$out" '"version":"6.18.3"' "the launcher's version"
	assert_contains "$out" '"bind":"127.0.0.1"' "the address it listens on"
	assert_contains "$out" '"port":8082' "and that address's port"

	_dt="$(ssh_command 2)"
	assert_contains "$_dt" 'powershell.exe -NoProfile -NonInteractive -Command' \
		"the questions are asked in PowerShell, not in a shell Windows lacks"
	assert_contains "$_dt" 'WorkingSet64' "memory comes from the process itself"
	assert_contains "$_dt" 'Get-NetTCPConnection' "and the socket from its owner"
	assert_contains "$_dt" 'netstat -ano' "with netstat where that cmdlet is absent"
	assert_not_contains "$_dt" 'sh -c' "no POSIX shell is assumed"

	# cmd.exe is handed the script as one argument, so the pair around it must be
	# the only double quotes in the command: a second pair would end the argument
	# there and leave cmd to parse the rest.
	assert_eq 2 "$(printf '%s' "$_dt" | tr -cd '"' | wc -c | tr -d ' ')" \
		"the only double quotes are the pair around the script"
	drop_sandbox
}

test_a_windows_machine_without_a_process_is_not_described() {
	# The state check said "running" and the process list then named nothing.
	# There is no pid to anchor the six lines to, and an object full of nulls
	# would render as a table of dashes that says less than the sentence.
	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_OUT='Running' SSH_DETAILS_OUT='' run_remote running)" || true
	assert_contains "$out" '"running":true' "the state answer stands"
	assert_not_contains "$out" '"details"' "with nothing invented beside it"
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
	out="$(SSH_OUT='running' SSH_EXIT=0 run_remote running)" || true
	assert_contains "$out" '"running":true' "the check uses the real service"
	assert_contains "$(ssh_command 1)" 'then /etc/init.d/fcc status' \
		"not /etc/init.d/OpenWrt"
	assert_contains "$(run_remote status)" '"service":"fcc"' \
		"and the page is told the name that is actually used"

	uci_set remote_platform linux
	uci_set remote_service Windows
	: > "$TMP/ssh.log"
	run_remote running >/dev/null 2>&1 || true
	assert_contains "$(ssh_command 1)" 'then systemctl is-active fcc' \
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
	# Calls one and two are the sshd drop-in a restart takes away and puts back;
	# the service command is the third.
	_cmd="$(ssh_command 3)"
	# The unit is looked for first, in the same connection: on a machine that
	# carries only the upstream install there is none, and starting the
	# launcher is what a person would do there by hand.
	assert_contains "$_cmd" 'systemctl cat fcc.service' \
		"the unit is looked for before it is used"
	assert_contains "$_cmd" 'then systemctl restart fcc' \
		"and systemd takes systemctl <op> <service> when it exists"
	assert_contains "$_cmd" 'else' \
		"with the launcher as the alternative in the same command"
	assert_contains "$_cmd" 'nohup "$s"' \
		"which is started detached"
	assert_not_contains "$_cmd" 'fcc-server' \
		"and the launcher name is never spelled out in the script"
	drop_sandbox
}

test_control_uses_the_openwrt_preset() {
	fresh
	ready_lan
	uci_set remote_platform openwrt
	run_remote control stop >/dev/null
	assert_contains "$(ssh_command 1)" '[ -x /etc/init.d/fcc ]' \
		"OpenWrt is asked whether it has the init script"
	assert_contains "$(ssh_command 1)" 'then /etc/init.d/fcc stop' \
		"and its init script is run directly when it does"
	assert_contains "$(ssh_command 1)" 'kill $_bcs_p' \
		"with the launcher as the alternative"
	drop_sandbox
}

test_control_checks_that_an_openwrt_start_really_started() {
	# The init script this package installs returns 0 for a server it did not
	# start: start_service() stops early when the runtime is absent. Left at
	# its word, the page would say "Done." for a server that is not there, so
	# the process list is asked afterwards — in the same connection, with the
	# same 15 seconds and the same probe the launcher route uses — and the
	# package's own log is tailed when the server did not appear.
	fresh
	ready_lan
	uci_set remote_platform openwrt
	out="$(SSH_OUT='server running' SSH_EXIT=0 run_remote control start)" || true
	assert_contains "$out" '"ok":true' "a start that came up is a success"
	_oc_cmd="$(ssh_command 1)"
	assert_contains "$_oc_cmd" 'then /etc/init.d/fcc start' \
		"the init script is still what starts it"
	assert_contains "$_oc_cmd" 'the FCC Server did not start' \
		"and the process list is asked before the answer is given"
	assert_contains "$_oc_cmd" 'pgrep -f "[f]cc-server"' \
		"the same probe the launcher route uses"
	assert_contains "$_oc_cmd" 'logs/$s.log' \
		"the package's log is where the tail is taken from"
	# A start that failed because nothing is installed there is not a start that
	# failed: the log file does not exist yet, so the page must not send anyone
	# to read it. The init script's own "runtime not installed" line goes to
	# syslog, which this connection cannot read, so the install path is checked.
	assert_contains "$_oc_cmd" 'the FCC Server is not installed on this machine' \
		"a machine with no runtime is told apart from a server that died"
	assert_contains "$_oc_cmd" 'bin/$s' \
		"by looking for the launcher where the init script looks for it"
	assert_not_contains "$_oc_cmd" 'fcc-server' \
		"and the launcher's name is still never spelled out"

	out="$(SSH_OUT='the FCC Server did not start' SSH_EXIT=1 \
		run_remote control start)" || true
	assert_contains "$out" '"ok":false' \
		"a server that did not come up is reported as a failure"
	assert_contains "$out" '"reason":"start-failed"' \
		"with the reason the page turns into a sentence"

	out="$(SSH_OUT='the FCC Server is not installed on this machine' SSH_EXIT=1 \
		run_remote control start)" || true
	assert_contains "$out" '"reason":"no-launcher"' \
		"a missing runtime is the page's install-it-there sentence"

	: > "$TMP/ssh.log"
	run_remote control stop >/dev/null 2>&1 || true
	assert_not_contains "$(ssh_command 1)" 'the FCC Server did not start' \
		"stop is not checked: the init script already waits for procd"
	drop_sandbox
}

# ---------------------------------------------------------------------------
# The sshd setting the Admin tunnel needs
# ---------------------------------------------------------------------------
#
# "Open FCC Admin" is an ssh -L forward, so that machine's sshd has to allow
# local forwarding. The button that starts the server is where the requirement
# becomes visible, so it is the button that meets it: start puts a drop-in in
# place before the server is started, stop takes it away again, and a restart
# does both in that order. None of it applies outside Linux, where sshd_config.d
# is not a thing.

test_control_on_linux_puts_the_tunnel_setting_in_place_on_start() {
	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=on' run_remote control start)"
	assert_contains "$out" '"ok":true' "the start is made"
	assert_contains "$out" '"forwarding":"on"' \
		"and what became of the setting is reported beside the result"
	_fw="$(ssh_command 1)"
	assert_contains "$_fw" '/etc/ssh/sshd_config.d/00-fcc-local-forwarding.conf' \
		"the drop-in is named"
	assert_contains "$_fw" 'AllowTcpForwarding local' \
		"and it carries the one setting the tunnel needs"
	assert_contains "$_fw" 'sshd -t' \
		"the configuration is validated before sshd is reloaded"
	# The same hazard as the launcher scripts: sshd hands this whole script to
	# sh as one argv word, so a literal launcher name in it would be matched by
	# the process-list probes and by a stop.
	assert_not_contains "$_fw" 'fcc-server' \
		"and the launcher's name is not spelled out in a script run over there"
	assert_contains "$(ssh_command 2)" 'then systemctl start fcc' \
		"the server itself is started after that"
	drop_sandbox
}

test_stop_takes_the_tunnel_setting_away() {
	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=off' run_remote control stop)"
	assert_contains "$out" '"ok":true' "the stop is made"
	assert_contains "$out" '"forwarding":"off"' "the setting went with it"
	# The server goes first: a stop that did not happen must leave the route to
	# the Admin page alone, because the server it leads to is still running.
	assert_contains "$(ssh_command 1)" 'then systemctl stop fcc' "the server is stopped"
	_fw="$(ssh_command 2)"
	assert_contains "$_fw" 'rm -f "$f"' "and then the drop-in is removed"
	assert_contains "$_fw" 'forwarding=absent' \
		"with a machine that never had one saying so instead of failing"
	drop_sandbox
}

test_a_stop_that_did_not_happen_leaves_the_tunnel_setting_alone() {
	fresh
	ready_lan
	out="$(SSH_OUT='Failed to stop fcc.service: Interactive authentication required.' \
		SSH_EXIT=1 SSH_UNIT_OUT='fcc.service enabled enabled' \
		run_remote control stop)" || true
	assert_contains "$out" '"ok":false' "the stop did not happen"
	assert_contains "$out" '"forwarding":null' "so the setting was not touched"
	assert_not_contains "$(cat "$TMP/ssh.log")" 'sshd_config' \
		"and that machine was asked nothing about its SSH daemon"
	drop_sandbox
}

test_restart_takes_the_tunnel_setting_away_and_puts_it_back() {
	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=on' run_remote control restart)"
	assert_contains "$out" '"forwarding":"on"' \
		"the setting is reported in its final state"
	assert_contains "$(ssh_command 1)" 'rm -f "$f"' \
		"a restart removes it first"
	assert_contains "$(ssh_command 2)" 'AllowTcpForwarding local' \
		"then writes it again"
	assert_contains "$(ssh_command 3)" 'then systemctl restart fcc' \
		"and the server is restarted last"
	drop_sandbox
}

test_a_tunnel_setting_already_in_place_needs_no_privilege() {
	# The file's state is read before the account is asked whether it may write
	# one: on a machine where the drop-in is already right, starting the server
	# must not need root at all — which is the ordinary case after the first
	# start, and the only case that works for an account without sudo.
	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=already' run_remote control start)"
	assert_contains "$out" '"forwarding":"already"' "the answer is passed through"
	_fw="$(ssh_command 1)"
	_al="$(printf '%s\n' "$_fw" | grep -n 'forwarding=already' | head -n 1 | cut -d: -f1)"
	_pr="$(printf '%s\n' "$_fw" | grep -n 'id -u' | head -n 1 | cut -d: -f1)"
	assert_eq "1" "$([ -n "$_al" ] && [ -n "$_pr" ] && [ "$_al" -lt "$_pr" ] && echo 1 || echo 0)" \
		"and the file is looked at before any privilege is asked for"
	drop_sandbox
}

test_a_narrowed_sudo_rule_is_enough_to_place_the_tunnel_setting() {
	# A sudoers rule that allows only the commands this needs — mkdir, tee,
	# sshd -t and the reload — is the sensible way to grant it on a shared
	# machine. `sudo -n true` is not among them, so probing with it would report
	# "denied" on a machine where every command it guards would have worked.
	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=on' run_remote control start)"
	assert_contains "$out" '"forwarding":"on"' "the setting was placed"
	_fw="$(ssh_command 1)"
	assert_contains "$_fw" '_fw_as="sudo -n"' \
		"the commands themselves carry sudo -n"
	assert_not_contains "$_fw" 'sudo -n true' \
		"and nothing is asked of sudo beyond the work it was allowed for"
	drop_sandbox
}

test_a_tunnel_setting_that_cannot_be_changed_does_not_fail_the_start() {
	# The SSH daemon over there is a separate thing from the FCC server: an
	# account that may not write /etc/ssh still gets its server started, and the
	# page gets a word it can turn into one sentence about what to do instead.
	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=denied' run_remote control start)"
	assert_contains "$out" '"ok":true' "the start still happened"
	assert_contains "$out" '"forwarding":"denied"' "and the refusal is reported"

	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=foreign' run_remote control start)"
	assert_contains "$out" '"ok":true' "a file of that name that is not ours"
	assert_contains "$out" '"forwarding":"foreign"' \
		"is reported and left alone rather than overwritten"
	drop_sandbox
}

test_the_tunnel_setting_is_left_alone_outside_linux() {
	# macOS reads no sshd_config.d directory, and an OpenWrt machine's SSH
	# server is dropbear: there is nothing there for this file to say, so
	# neither is sent looking for it.
	fresh
	ready_lan
	uci_set remote_platform macos
	out="$(run_remote control start)"
	assert_contains "$out" '"forwarding":null' "macOS reports no setting"
	assert_not_contains "$(ssh_command 1)" 'sshd_config' \
		"and is asked nothing about one"

	fresh
	ready_lan
	uci_set remote_platform openwrt
	out="$(run_remote control stop)"
	assert_contains "$out" '"forwarding":null' "OpenWrt reports no setting"
	assert_not_contains "$(ssh_command 1)" 'sshd_config' \
		"and is asked nothing about one either"
	drop_sandbox
}

test_a_machine_that_already_allows_forwarding_needs_nothing_written() {
	# OpenSSH's own default is AllowTcpForwarding yes, and a machine that says
	# yes, all or local needs no drop-in at all. The answer is worked out from
	# the world-readable configuration by the account itself, so stock Linux —
	# no sudo, no helper — opens the tunnel as it is.
	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=allowed' run_remote control start)"
	assert_contains "$out" '"ok":true' "the start is made"
	assert_contains "$out" '"forwarding":"allowed"' \
		"and a machine that already allows the tunnel says so"
	_fw="$(ssh_command 1)"
	_al="$(printf '%s\n' "$_fw" | grep -n 'echo forwarding=allowed' | head -n 1 | cut -d: -f1)"
	_wr="$(printf '%s\n' "$_fw" | grep -n 'mkdir -p' | head -n 1 | cut -d: -f1)"
	_pr="$(printf '%s\n' "$_fw" | grep -n 'id -u' | head -n 1 | cut -d: -f1)"
	assert_eq "1" "$([ -n "$_al" ] && [ -n "$_wr" ] && [ -n "$_pr" ] && \
		[ "$_al" -lt "$_wr" ] && [ "$_al" -lt "$_pr" ] && echo 1 || echo 0)" \
		"the answer is reached without writing a file or asking for privilege"
	assert_contains "$_fw" 'AllowTcpForwarding' "the setting it looks for is named"
	assert_contains "$_fw" 'Include' \
		"and the files sshd's Include lines splice in are followed too"
	drop_sandbox
}

test_the_root_owned_helper_is_used_before_the_individual_commands() {
	# Where an administrator has installed the helper, the account runs one
	# program that accepts only on or off. The individual sudo commands stay
	# below it for a machine that has no helper, so an old helper lying around
	# cannot stop a full-sudo account from working.
	fresh
	ready_lan
	out="$(SSH_FW_OUT='forwarding=on' run_remote control start)"
	assert_contains "$out" '"forwarding":"on"' "the setting was placed"
	_fw="$(ssh_command 1)"
	assert_contains "$_fw" 'if [ -x "$h" ]; then _fw_hp=$h; fi' \
		"an installed helper is looked for"
	_hp="$(printf '%s\n' "$_fw" | grep -n '"\$_fw_hp" on' | head -n 1 | cut -d: -f1)"
	_wr="$(printf '%s\n' "$_fw" | grep -n 'mkdir -p' | head -n 1 | cut -d: -f1)"
	assert_eq "1" "$([ -n "$_hp" ] && [ -n "$_wr" ] && [ "$_hp" -lt "$_wr" ] && echo 1 || echo 0)" \
		"and it is tried before the individual commands"
	assert_contains "$_fw" '3) echo forwarding=invalid' \
		"while the helper's exit codes still become the words the page knows"
	drop_sandbox
}

test_the_one_time_setup_names_the_account_and_the_program() {
	# The block the page offers is what an administrator pastes once on a
	# machine that really does block forwarding: the helper, and a sudoers rule
	# naming exactly this router's account and exactly the helper's two words.
	fresh
	ready_lan
	uci_set remote_user arthur
	out="$(run_remote helper)"
	assert_contains "$out" '"ok":true' "the block is produced"
	assert_contains "$out" '"user":"arthur"' "for the account this router uses"
	assert_contains "$out" '"path":"/usr/local/sbin/fcc-local-forwarding"' \
		"installed at the path the start looks for"
	assert_contains "$out" '"installed":false' \
		"and the machine is asked whether it is already there"
	assert_contains "$out" 'sudo sh -s' \
		"the paste asks that machine's administrator for their own password"
	assert_contains "$out" 'arthur ALL=(root) NOPASSWD: /usr/local/sbin/fcc-local-forwarding on, /usr/local/sbin/fcc-local-forwarding off' \
		"the rule names only the helper and only its two words"
	assert_not_contains "$out" 'tee' \
		"nothing that could write an arbitrary file is handed over"
	# A sudoers file that does not parse can take sudo away from everyone on
	# that machine, so the rule is written somewhere sudo ignores, checked, and
	# only then moved into place.
	_vs="$(printf '%s\n' "$out" | grep -o 'visudo -cf[^\\]*' | head -n 1)"
	assert_contains "$out" '/etc/sudoers.d/.50-fcc-local-forwarding.tmp' \
		"the rule is first put in a file sudo's includedir skips"
	assert_contains "$_vs" 'visudo -cf' "and parsed before it counts"
	_vl="$(printf '%s' "$out" | sed 's/\\n/\n/g; s/\\"/"/g' | grep -n 'visudo -cf' | head -n 1 | cut -d: -f1)"
	_mv="$(printf '%s' "$out" | sed 's/\\n/\n/g; s/\\"/"/g' | grep -n 'mv "\$_sd_tmp" "\$_sd_rule"' | head -n 1 | cut -d: -f1)"
	assert_eq "1" "$([ -n "$_vl" ] && [ -n "$_mv" ] && [ "$_vl" -lt "$_mv" ] && echo 1 || echo 0)" \
		"and it is moved into place only after that check"

	fresh
	ready_lan
	uci_set remote_user arthur
	out="$(SSH_OUT='helper=installed' run_remote helper)"
	assert_contains "$out" '"installed":true' \
		"a machine that already has the helper says so"
	drop_sandbox
}

test_the_one_time_setup_needs_a_configured_target() {
	# The block writes a sudoers rule naming the account this router uses. With
	# no target configured there is no account to name, and an empty one is not
	# a rule sudo accepts — so there is no block to paste.
	fresh
	out="$(run_remote helper)" || true
	assert_contains "$out" '"ok":false' "an unconfigured target gets no block"
	assert_not_contains "$out" 'ALL=(root)' "and no half-written rule"
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
	fake_key
	out="$(run_remote keygen)"
	assert_contains "$out" '"existing":true' \
		"a second visit shows the key rather than rotating it"
	assert_eq "PRIVATE KEY" "$(cat "$SSH_DIR/id_ed25519")" \
		"the private half is untouched"
	drop_sandbox
}

# --- A key that is present but unusable --------------------------------
#
# The report that started this: the router held a private key in Dropbear's
# format, so status said the key was configured, Test connection said
# "Load key ...: invalid format ... Permission denied", and Start said the LAN
# machine's answer could not be parsed. The file existing is not the question;
# whether OpenSSH can read it is.

# The 83 bytes dropbearkey writes for an ed25519 key: a length-prefixed
# "ssh-ed25519" and 64 raw key bytes. OpenSSH cannot read it, and this is
# deliberately not written as a readable string.
write_dropbear_key() {
	awk 'BEGIN {
		printf "%c%c%c%c", 0, 0, 0, 11
		printf "ssh-ed25519"
		printf "%c%c%c%c", 0, 0, 0, 64
		for (i = 0; i < 64; i++) { printf "%c", 7 }
	}' > "$SSH_DIR/id_ed25519"
	chmod 600 "$SSH_DIR/id_ed25519"
	printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY luci-app-fcc\n' \
		> "$SSH_DIR/id_ed25519.pub"
}

test_status_reports_an_unusable_key() {
	fresh
	ready_lan
	write_dropbear_key
	out="$(run_remote status)"
	assert_contains "$out" '"key_state":"invalid"' \
		"the key that is there is reported as unusable"
	assert_contains "$out" '"key_ready":false' \
		"so the key is not called configured"
	assert_contains "$out" '"public_key":""' \
		"and no public key is offered for a key that authenticates nothing"
	assert_contains "$out" '"ready":false' \
		"which leaves the controls disabled"
	drop_sandbox
}

test_status_reports_a_key_pair_that_disagrees() {
	fresh
	ready_lan
	printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHERKEY luci-app-fcc\n' \
		> "$SSH_DIR/id_ed25519.pub"
	out="$(run_remote status)"
	assert_contains "$out" '"key_state":"mismatch"' \
		"a public half that is not this key's is named as such"
	assert_contains "$out" '"key_ready":false' \
		"and is not called configured"
	drop_sandbox
}

test_test_names_an_unusable_key_without_calling_the_machine() {
	fresh
	ready_lan
	write_dropbear_key
	out="$(run_remote test)"
	assert_contains "$out" '"reason":"key-invalid"' \
		"testing says the key itself cannot be read"
	assert_contains "$out" 'not a key OpenSSH can read' \
		"in the script's own words"
	assert_not_contains "$(cat "$TMP/ssh.log" 2>/dev/null)" 'CALL' \
		"and nothing is sent, because the failure is here, not over there"
	drop_sandbox
}

test_running_names_an_unusable_key() {
	fresh
	ready_lan
	write_dropbear_key
	out="$(run_remote running)" || true
	assert_contains "$out" '"ok":false' "the state is not read"
	assert_contains "$out" '"reason":"key-invalid"' \
		"and the reason is the key, not an answer that could not be parsed"
	drop_sandbox
}

test_keygen_replaces_an_unusable_key() {
	# The repair the page offers: Generate is visible while key_ready is false,
	# and it must actually replace the key rather than report the old one.
	fresh
	ready_lan
	write_dropbear_key
	out="$(run_remote keygen)"
	assert_contains "$out" '"ok":true' "the key is generated"
	assert_contains "$out" '"existing":false' "and not reported as the one already there"
	assert_contains "$out" '"replaced":true' "the unusable key is named as replaced"
	assert_eq "PRIVATE KEY" "$(cat "$SSH_DIR/id_ed25519")" \
		"the file is now a key ssh-keygen can read"
	assert_file "$SSH_DIR/id_ed25519.unusable"
	out="$(run_remote status)"
	assert_contains "$out" '"key_ready":true' "and the pair is usable afterwards"
	drop_sandbox
}

test_keygen_repairs_a_mismatched_public_half() {
	# The private half is fine; only the .pub is not its partner. Rotating the
	# key would make the user re-add it on the LAN machine for no reason.
	fresh
	printf 'PRIVATE KEY\n' > "$SSH_DIR/id_ed25519"
	printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHERKEY stale\n' \
		> "$SSH_DIR/id_ed25519.pub"
	out="$(run_remote keygen)"
	assert_contains "$out" '"existing":true' \
		"the private key that works is kept"
	assert_contains "$out" '"repaired":true' \
		"and the answer says the public half was rewritten"
	assert_contains "$(cat "$SSH_DIR/id_ed25519.pub")" 'AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY' \
		"with the half derived from the private key"
	assert_eq "PRIVATE KEY" "$(cat "$SSH_DIR/id_ed25519")" \
		"and the private half untouched"
	drop_sandbox
}

test_keygen_recreates_a_missing_public_half() {
	fresh
	printf 'PRIVATE KEY\n' > "$SSH_DIR/id_ed25519"
	out="$(run_remote keygen)"
	assert_contains "$out" '"existing":true' \
		"the private key is not rotated to recover its public half"
	assert_file "$SSH_DIR/id_ed25519.pub"
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

test_windows_errors_are_named_as_a_missing_launcher() {
	# The page translates a reason code, so Windows' own wording for "nothing by
	# that name is here" has to reach it as one. A machine that only ran
	# install.ps1 has no service, and the start goes to the launcher — so a
	# name that does not resolve there means the launcher is not installed.
	fresh
	ready_lan
	uci_set remote_platform windows
	out="$(SSH_OUT="'fcc-server' is not recognized as an internal or external command" \
		SSH_EXIT=1 run_remote control start)" || true
	assert_contains "$out" '"reason":"no-launcher"' \
		"cmd's not-recognized is the same answer as a missing launcher"
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
	assert_contains "$(ssh_command 1)" 'then systemctl is-active fcc' \
		"systemd is still asked first"
	assert_contains "$(ssh_command 1)" 'pgrep -f "[f]cc-server"' \
		"and the process list is the same command's fallback"

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

test_control_on_macos_runs_the_launcher() {
	# The upstream install writes no launchd job, so the launcher is the
	# service there too: the click starts it detached, and stops it by the pid
	# the process list yields — the same two things a person would type.
	fresh
	ready_lan
	uci_set remote_platform macos
	out="$(run_remote control start)" || true
	assert_contains "$out" '"ok":true' "the start is made"
	assert_contains "$(ssh_command 1)" 'nohup "$s"' "through the launcher"
	assert_contains "$(ssh_command 1)" 'pgrep -f "[f]cc-server"' \
		"with the process list deciding whether it is up"
	assert_not_contains "$(ssh_command 1)" 'fcc-server' \
		"and the name assembled rather than spelled out"

	: > "$TMP/ssh.log"
	run_remote control stop >/dev/null 2>&1 || true
	assert_contains "$(ssh_command 1)" 'kill $_bcs_p' "a stop kills the launcher's pid"
	drop_sandbox
}

test_control_never_sends_systemctl_to_a_bare_machine() {
	# systemctl asks polkit for a password before it checks the unit's name, so
	# a machine running only the upstream install would answer with a password
	# prompt. The unit is looked for first, in the same connection, and a
	# machine that has none is answered from its process list instead — so a
	# bare target is never sent looking for sudo.
	fresh
	ready_lan
	out="$(SSH_PROBE_OUT='the FCC Server is not installed on this machine' \
		SSH_PROBE_EXIT=1 run_remote control start)" || true
	assert_contains "$out" '"ok":false' "the start did not happen"
	assert_contains "$out" '"reason":"no-launcher"' \
		"and the page is told there is no launcher to start"
	_cmd="$(ssh_command 2)"
	assert_contains "$_cmd" 'systemctl cat fcc.service' \
		"the unit is asked about without privilege"
	assert_contains "$_cmd" 'else' \
		"and the launcher, not systemctl, is what a machine without it runs"
	assert_contains "$_cmd" 'nohup "$s"' \
		"which is started the way a person would start it"
	drop_sandbox
}

test_control_names_a_service_only_an_administrator_may_touch() {
	fresh
	ready_lan
	out="$(SSH_OUT='Failed to start fcc.service: Interactive authentication required.' \
		SSH_EXIT=1 SSH_UNIT_OUT='fcc.service enabled enabled' \
		run_remote control start)" || true
	assert_contains "$out" '"ok":false' "the start did not happen"
	assert_contains "$out" '"reason":"needs-root"' \
		"and a unit that exists is named as one this account may not control"
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

test_restart_stops_before_it_starts() {
	# A launcher has no restart verb, so a restart is a stop followed by a
	# start. Each half has exits of its own, so each runs in a subshell: a
	# successful stop must not end the command before the start runs.
	fresh
	ready_lan
	uci_set remote_platform macos
	run_remote control restart >/dev/null 2>&1 || true
	cmd="$(ssh_command 1)"
	assert_contains "$cmd" '( ' "the stop runs in a subshell"
	assert_contains "$cmd" ') && ( ' "and the start follows it only on success"
	assert_contains "$cmd" 'kill $_bcs_p' "the stop is there"
	assert_contains "$cmd" 'nohup "$s"' "and so is the start"
	drop_sandbox
}

test_every_platform_can_start_a_machine_without_a_service() {
	# Linux, OpenWrt, macOS and Windows are asked the same way: use the service
	# when there is one, the launcher when there is not, so the Start button
	# works on a machine that only ran the upstream installer.
	for _p in linux openwrt macos windows; do
		fresh
		ready_lan
		uci_set remote_platform "$_p"
		run_remote control start >/dev/null 2>&1 || true
		cmd="$(ssh_last_command)"
		case "$_p" in
			windows)
				assert_contains "$cmd" 'Start-Process -WindowStyle Hidden' \
					"windows starts the launcher" ;;
			*)
				assert_contains "$cmd" 'nohup "$s"' \
					"$_p starts the launcher" ;;
		esac
	done
	drop_sandbox
}

test_the_launcher_scripts_never_spell_their_own_name() {
	# sshd hands the whole script to sh as one argument, so a plain occurrence
	# of the launcher's name would put it on the command line of the shell
	# running the script — and the process probe, and the stop, would find that
	# shell instead of the server. The name is assembled at run time and the
	# pgrep pattern keeps its brackets, so the literal never appears. (Windows
	# matches on process names, not command lines, so it is not in this list.)
	# The whole log is checked rather than one call: every word sent to that
	# machine is a candidate, including the sshd drop-in a Linux operation
	# carries.
	for _p in linux openwrt macos; do
		fresh
		ready_lan
		uci_set remote_platform "$_p"
		for _op in start stop restart; do
			: > "$TMP/ssh.log"
			run_remote control "$_op" >/dev/null 2>&1 || true
			assert_not_contains "$(cat "$TMP/ssh.log")" 'fcc-server' \
				"$_p $_op names the launcher without spelling it out"
		done
	done
	drop_sandbox
}

tests_main
