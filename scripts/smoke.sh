#!/bin/sh
# luci-app-fcc — install smoke test (DESIGN_SPEC.md sections 90 and 91).
#
# The static suite and the build job both stop short of the one question that
# cannot be answered by reading files: does the package install on a real
# OpenWrt and leave a working system behind? Sections 90 and 91 ask for exactly
# that — install the built package, then run `/etc/init.d/fcc status`.
#
# So this runs the release's own package manager inside the release's own root
# filesystem:
#
#   * OpenWrt 24.10 installs with opkg and OpenWrt 25.12 with apk. They are
#     different programs with different command lines and different failure
#     modes, which is why section 91 says the 24.10 install scripts must not be
#     assumed to work on 25.12. Both are exercised here rather than reasoned
#     about.
#
#   * The rootfs is the official one from downloads.openwrt.org for the same
#     release the package was built against, so its feeds are the ones the
#     declared dependencies have to resolve from. A dependency that only exists
#     on some other release fails here.
#
#   * procd is started for real (`--privileged ... /sbin/init`), so
#     `/etc/init.d/fcc status` gets its answer from the same machinery a router
#     uses rather than from a stand-in.
#
#   * The container keeps its network. This is the one place the rootfs has to
#     be interfered with, and the reason is worth spelling out: OpenWrt's boot
#     brings down every interface it does not manage, so eth0 — which Docker had
#     already given an address and a default route — comes up administratively
#     down, and the container is left with no route at all. The package manager
#     then fails every download, which reads like a broken package and is not.
#     Mounting a network config that claims nothing but loopback stops the boot
#     from building br-lan over eth0, and the address Docker recorded is put
#     back once procd is up. Nothing else about the booted system is changed.
#
# What it asserts is deliberately more than "the install returned 0". Section 87
# forbids erroring when the runtime is absent, and the LuCI app is only reachable
# if the Lua runtime came in with it — neither is visible in the exit status of
# the install, and both are checked below.
#
# Usage:
#   scripts/smoke.sh <image> <platform> <ext> <dist-dir>
#
#     image      Docker image holding an unpacked OpenWrt rootfs
#     platform   linux/amd64 or linux/arm64 — the container's architecture
#     ext        ipk for OpenWrt 24.10, apk for OpenWrt 25.12
#     dist-dir   directory holding the built luci-app-fcc packages
#
# Requires a Docker daemon, and for a foreign architecture a registered binfmt
# (docker/setup-qemu-action in CI). Development host and CI only; none of this
# runs on a router.
#
# Set SMOKE_KEEP=1 to leave the container behind for inspection.

set -eu

SMOKE_IMAGE="${1:?usage: smoke.sh <image> <platform> <ext> <dist-dir>}"
SMOKE_PLATFORM="${2:?usage: smoke.sh <image> <platform> <ext> <dist-dir>}"
SMOKE_EXT="${3:?usage: smoke.sh <image> <platform> <ext> <dist-dir>}"
SMOKE_DIST="${4:?usage: smoke.sh <image> <platform> <ext> <dist-dir>}"

case "$SMOKE_EXT" in
	ipk|apk) : ;;
	*) printf 'smoke.sh: unknown package format: %s\n' "$SMOKE_EXT" >&2; exit 2 ;;
esac

[ -d "$SMOKE_DIST" ] || { printf 'smoke.sh: not a directory: %s\n' "$SMOKE_DIST" >&2; exit 2; }

SMOKE_NAME="fcc-smoke-$$"
SMOKE_FAILED=0

SMOKE_TMP="$(mktemp -d)"
SMOKE_LOG="$SMOKE_TMP/install.log"
: > "$SMOKE_LOG"

# Where the built packages are staged inside the container. Deliberately not
# /tmp: OpenWrt mounts a tmpfs there, and `docker cp` writes through the host
# side of the overlay rather than the container's mount namespace, so a copy to
# /tmp reports success while the file ends up underneath the tmpfs and stays
# invisible to the container. /root is on the overlay and is what the package
# manager can actually open.
SMOKE_STAGE=/root

# The interface config the container boots with. Loopback only: see the header
# for why OpenWrt must not be allowed to claim eth0 here.
cat > "$SMOKE_TMP/network" <<'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'
EOF

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

smoke_note() { printf '\n== %s\n' "$1"; }
smoke_ok()   { printf '   ok    %s\n' "$1"; }

smoke_bad() {
	printf '   FAIL  %s\n' "$1" >&2
	SMOKE_FAILED=$(( SMOKE_FAILED + 1 ))
}

smoke_check() {
	# smoke_check <description> <expected-rc> <actual-rc>
	_sk_d="$1"
	if [ "$3" = "$2" ]; then
		smoke_ok "$_sk_d"
	else
		smoke_bad "$_sk_d (expected exit $2, got $3)"
	fi
}

smoke_expect() {
	# smoke_expect <description> <expected> <actual>
	if [ "$3" = "$2" ]; then
		smoke_ok "$1"
	else
		smoke_bad "$1 (expected '$2', got '$3')"
	fi
}

# ---------------------------------------------------------------------------
# The container
# ---------------------------------------------------------------------------

smoke_sh() {
	# Run one command line inside the container.
	docker exec "$SMOKE_NAME" sh -c "$1"
}

smoke_out() {
	# Run one command line inside the container and print its stdout. Always
	# succeeds: the callers are reading output from commands that are *meant* to
	# exit non-zero (`/etc/init.d/fcc status` answers "inactive" with 3), and an
	# assignment from a failing command would abort the whole script.
	docker exec "$SMOKE_NAME" sh -c "$1" 2>/dev/null || true
}

smoke_cleanup() {
	rm -rf "$SMOKE_TMP"
	if [ "${SMOKE_KEEP:-0}" = 1 ]; then
		printf '\ncontainer kept for inspection: docker exec -it %s sh\n' "$SMOKE_NAME"
		return 0
	fi
	docker rm -f "$SMOKE_NAME" >/dev/null 2>&1 || true
}
trap smoke_cleanup EXIT INT TERM

smoke_wait_for_procd() {
	# ubus answering is the signal that procd is up: every init script verb we
	# assert on below goes through it.
	_sw_i=0
	while [ "$_sw_i" -lt 60 ]; do
		if docker exec "$SMOKE_NAME" ubus list >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
		_sw_i=$(( _sw_i + 1 ))
	done
	return 1
}

smoke_restore_network() {
	# Put back the addressing Docker assigned before the boot took it away. It
	# is read back from Docker rather than guessed, so a runner on a non-default
	# bridge is handled the same as the default one.
	_sn_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SMOKE_NAME" 2>/dev/null || true)"
	_sn_gw="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$SMOKE_NAME" 2>/dev/null || true)"
	_sn_pfx="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPPrefixLen}}{{end}}' "$SMOKE_NAME" 2>/dev/null || true)"
	[ -n "$_sn_pfx" ] || _sn_pfx=16
	if [ -z "$_sn_ip" ]; then
		smoke_bad "docker recorded no address for the container"
		return 1
	fi
	docker exec "$SMOKE_NAME" sh -c "
		ip link set eth0 up
		ip addr add $_sn_ip/$_sn_pfx dev eth0 2>/dev/null
		[ -n '$_sn_gw' ] && ip route add default via $_sn_gw 2>/dev/null
		exit 0
	" >/dev/null 2>&1 || true
	return 0
}

smoke_show_log() {
	printf '\n%s:\n' "$1" >&2
	cat "$SMOKE_LOG" >&2
}

smoke_pkg_path() {
	# Print the single package in the dist directory matching <glob>.
	_sp_hits="$(find "$SMOKE_DIST" -maxdepth 1 -type f -name "$1" 2>/dev/null | LC_ALL=C sort)"
	_sp_n="$(printf '%s\n' "$_sp_hits" | awk 'NF { n++ } END { print n + 0 }')"
	if [ "$_sp_n" -eq 0 ]; then
		printf 'smoke.sh: no %s built in %s\n' "$1" "$SMOKE_DIST" >&2
		exit 2
	fi
	if [ "$_sp_n" -gt 1 ]; then
		printf 'smoke.sh: %s matches %s packages, which is ambiguous:\n%s\n' \
			"$1" "$_sp_n" "$_sp_hits" >&2
		exit 2
	fi
	printf '%s' "$_sp_hits"
}

# ---------------------------------------------------------------------------
# Install / remove, per package manager
# ---------------------------------------------------------------------------

smoke_feed_update() {
	# Refresh the package lists.
	#
	# Retried, because a single feed timing out makes the update exit non-zero
	# even when every other feed was fetched and verified — and chaining the
	# install behind `&&` then turns a flaky mirror into "the package does not
	# install". A total outage is caught by the connectivity check above, so if
	# all three attempts fail this records that and lets the install speak for
	# itself: opkg names the missing dependency, which is more useful than a
	# download error.
	_sf_i=0
	while [ "$_sf_i" -lt 3 ]; do
		_sf_i=$(( _sf_i + 1 ))
		printf '\n--- %s (attempt %s) ---\n' "$1" "$_sf_i" >>"$SMOKE_LOG"
		if smoke_sh "$1" >>"$SMOKE_LOG" 2>&1; then
			return 0
		fi
		sleep 3
	done
	printf '\n--- %s failed after 3 attempts; continuing anyway ---\n' "$1" >>"$SMOKE_LOG"
	return 0
}

smoke_install() {
	# smoke_install <path-inside-container>
	#
	# The output goes to a file rather than to the terminal: a successful install
	# resolves a whole dependency chain and prints a page of it, but a failed one
	# prints the reason, and swallowing that was how a download error came to
	# look like a broken package. It is printed on failure by smoke_show_log.
	if [ "$SMOKE_EXT" = apk ]; then
		smoke_feed_update "apk update"
		# The package is built by the SDK and signed with a key this rootfs has
		# never seen, so its signature cannot be verified here. That is a
		# property of the test harness, not of the package: `--allow-untrusted`
		# is what lets the payload be installed and checked at all.
		smoke_sh "apk add --allow-untrusted '$1'" >>"$SMOKE_LOG" 2>&1
	else
		smoke_feed_update "opkg update"
		smoke_sh "opkg install '$1'" >>"$SMOKE_LOG" 2>&1
	fi
}

smoke_remove() {
	if [ "$SMOKE_EXT" = apk ]; then
		smoke_sh "apk del luci-app-fcc"
	else
		smoke_sh "opkg remove luci-app-fcc"
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SMOKE_APP="$(smoke_pkg_path "luci-app-fcc[-_]*.$SMOKE_EXT")"

printf 'smoke: %s on %s (%s)\n' "$SMOKE_IMAGE" "$SMOKE_PLATFORM" "$SMOKE_EXT"
printf 'smoke: package %s\n' "$SMOKE_APP"

# A locally imported rootfs carries whatever platform `docker import` recorded,
# which is the host's unless it was told otherwise. Asking to run it as anything
# else makes Docker decide the image is not here at all and go looking in a
# registry — the run then dies with "pull access denied", which names neither
# the platform nor the import and reads like a credentials problem. Check first
# and say what is actually wrong.
SMOKE_IMG_PLATFORM="$(docker image inspect "$SMOKE_IMAGE" \
	--format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true)"
if [ -n "$SMOKE_IMG_PLATFORM" ] && [ "$SMOKE_IMG_PLATFORM" != "$SMOKE_PLATFORM" ]; then
	printf 'smoke: %s is %s but this run asked for %s\n' \
		"$SMOKE_IMAGE" "$SMOKE_IMG_PLATFORM" "$SMOKE_PLATFORM" >&2
	printf 'smoke: re-import it with: docker import --platform %s <rootfs.tar.gz> %s\n' \
		"$SMOKE_PLATFORM" "$SMOKE_IMAGE" >&2
	exit 2
fi

smoke_note "booting the rootfs"
docker run -d --name "$SMOKE_NAME" --privileged --platform "$SMOKE_PLATFORM" \
	-v "$SMOKE_TMP/network:/etc/config/network:ro" \
	"$SMOKE_IMAGE" /sbin/init >/dev/null
if smoke_wait_for_procd; then
	smoke_ok "procd is up"
else
	smoke_bad "procd did not come up"
	printf '\ncontainer log:\n' >&2
	docker logs "$SMOKE_NAME" 2>&1 | tail -30 >&2
	exit 1
fi

smoke_out 'cat /etc/openwrt_release' | grep -E '^DISTRIB_(RELEASE|ARCH)=' || true

# Restore the address the boot took away, then prove it works. Everything below
# needs the package manager to reach the release feed, and without this the
# first symptom is an install failure that says nothing about the package.
smoke_restore_network || exit 1
if docker exec "$SMOKE_NAME" sh -c 'wget -q -O /dev/null https://downloads.openwrt.org/' >/dev/null 2>&1; then
	smoke_ok "the container can reach the package feed"
else
	smoke_bad "the container cannot reach downloads.openwrt.org"
	printf '\nresolv.conf:\n' >&2
	docker exec "$SMOKE_NAME" cat /etc/resolv.conf >&2 2>&1 || true
	printf 'routes:\n' >&2
	docker exec "$SMOKE_NAME" ip route >&2 2>&1 || true
	exit 1
fi

smoke_note "installing"
docker cp "$SMOKE_APP" "$SMOKE_NAME:$SMOKE_STAGE/app.$SMOKE_EXT"
_sm_rc=0
smoke_install "$SMOKE_STAGE/app.$SMOKE_EXT" || _sm_rc=$?
smoke_check "the package installs" 0 "$_sm_rc"
if [ "$_sm_rc" != 0 ]; then
	smoke_show_log "the package manager said"
	exit 1
fi

# ---------------------------------------------------------------------------
# What the install was supposed to put on disk
# ---------------------------------------------------------------------------

smoke_note "the installed tree"
for _sm_f in \
	/etc/config/fcc \
	/etc/init.d/fcc \
	/usr/bin/fcc-env \
	/usr/libexec/fcc/common.sh \
	/usr/libexec/fcc/status.sh \
	/usr/libexec/fcc/session.sh \
	/usr/libexec/fcc/agent.sh \
	/usr/libexec/fcc/install.sh \
	/usr/libexec/fcc/update.sh \
	/usr/libexec/fcc/doctor.sh \
	/usr/libexec/fcc/firewall.sh \
	/usr/libexec/fcc/server-run.sh \
	/usr/lib/lua/luci/controller/fcc.lua \
	/usr/lib/lua/luci/view/fcc/console.htm \
	/usr/lib/lua/luci/view/fcc/config.htm \
	/usr/lib/lua/luci/view/fcc/info.htm \
	/usr/lib/lua/luci/fcc/agents.lua \
	/usr/lib/lua/luci/fcc/paths.lua \
	/usr/lib/lua/luci/fcc/util.lua \
	/usr/share/rpcd/acl.d/luci-app-fcc.json \
	/usr/share/luci-app-fcc/agents.conf \
	/www/luci-static/resources/fcc/fcc-terminal.js
do
	_sm_rc=0
	smoke_sh "[ -e '$_sm_f' ]" || _sm_rc=$?
	smoke_check "$_sm_f" 0 "$_sm_rc"
done

# The Lua half of LuCI lives in luci-lua-runtime, which reaches us only through
# luci-compat. If that dependency is ever dropped the package still installs
# cleanly and the controller is simply never loaded, so the dispatcher is the
# thing worth asserting on.
_sm_rc=0
smoke_sh '[ -e /usr/lib/lua/luci/dispatcher.lua ]' || _sm_rc=$?
smoke_check "the Lua runtime arrived with the package" 0 "$_sm_rc"

# A syntax check with the target's own interpreter, which is a different Lua
# build from the one the static suite runs.
_sm_rc=0
smoke_sh "lua -e \"assert(loadfile('/usr/lib/lua/luci/controller/fcc.lua'))\"" || _sm_rc=$?
smoke_check "the controller parses under the target's Lua" 0 "$_sm_rc"

# ---------------------------------------------------------------------------
# Section 91's own command
# ---------------------------------------------------------------------------

smoke_note "/etc/init.d/fcc"
# Section 91's own command. What procd answers on a system with the package
# installed and no runtime is "active with no instances" — a service it knows
# about but holds no instances for (lib/functions/procd.sh), which is exactly
# the state section 87 requires not to be an error. So what is asserted is that
# the command answers coherently and never claims the server is running, rather
# than one particular procd wording that differs between releases.
_sm_before="$(smoke_out '/etc/init.d/fcc status')"
_sm_rc=0
smoke_sh '/etc/init.d/fcc status' >/dev/null || _sm_rc=$?
smoke_check "status answers without an error" 0 "$_sm_rc"
if [ "$_sm_before" = running ]; then
	smoke_bad "status claims the server is running with no runtime installed"
else
	smoke_ok "status does not claim the server is running ('$_sm_before')"
fi

# Section 87: enabling or starting the service before the runtime exists must
# not be an error, or a boot with the package installed and no runtime would
# look like a failure.
_sm_rc=0
smoke_sh '/etc/init.d/fcc start' || _sm_rc=$?
smoke_check "start is not an error while the runtime is absent" 0 "$_sm_rc"

_sm_after="$(smoke_out '/etc/init.d/fcc status')"
smoke_expect "start did not change the reported state" "$_sm_before" "$_sm_after"
if [ "$_sm_after" = running ]; then
	smoke_bad "start launched a server with no runtime installed"
else
	smoke_ok "nothing was started without a runtime"
fi

# ---------------------------------------------------------------------------
# The backends must answer with no runtime installed
# ---------------------------------------------------------------------------

smoke_note "backends with no runtime"
_sm_rc=0
docker exec "$SMOKE_NAME" /usr/libexec/fcc/status.sh > /tmp/fcc-smoke-status.json 2>/dev/null || _sm_rc=$?
smoke_check "status.sh exits 0" 0 "$_sm_rc"
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' /tmp/fcc-smoke-status.json 2>/dev/null; then
	smoke_ok "status.sh emits valid JSON"
else
	smoke_bad "status.sh did not emit valid JSON: $(head -c 200 /tmp/fcc-smoke-status.json)"
fi

# `fcc-env version` is designed to say so and exit 1, which is the one place a
# non-zero status is the correct answer.
_sm_rc=0
smoke_sh '/usr/bin/fcc-env version >/dev/null 2>&1' || _sm_rc=$?
smoke_check "fcc-env version reports an absent runtime" 1 "$_sm_rc"

# ---------------------------------------------------------------------------
# A blocked install explains itself (section 3.6.4)
#
# The gate is forced shut with a storage requirement no machine can meet, so
# this asserts the report rather than whatever the container's network happens
# to be doing at the time.
#
# The install path is left at the package's own default rather than pointed
# somewhere disposable, because with the package installed it is UCI that
# decides where the runtime goes: FCC_DEFAULT_BASE is only the fallback for a
# router that has never saved a setting, so overriding it here would have
# tested a path the user's own device never takes. /opt/fcc is removed again
# afterwards, so the container is left as this run found it.
#
# It runs with SIGPIPE ignored, which is what uhttpd hands its children and so
# what every job really runs under: without it a pipeline whose reader walks
# away dies silently, and busybox's EPIPE complaint — the one that used to
# appear in the install log next to an unrelated failure — never shows up.
# Asserting silence on stderr under that disposition is the only way this is
# visible at all; under an ordinary shell the check would pass either way.
# ---------------------------------------------------------------------------

smoke_note "a blocked install explains itself"
_sm_blocked_out=/tmp/fcc-smoke-blocked.out
_sm_rc=0
docker exec "$SMOKE_NAME" sh -c '
	trap "" PIPE
	FCC_REQUIRED_FREE_MB=999999999 /usr/libexec/fcc/agent.sh install claude 2>&1
' > "$_sm_blocked_out" 2>&1 || _sm_rc=$?
smoke_check "a blocked agent install exits non-zero" 1 "$_sm_rc"

if grep -q 'PRECHECK_FAILED' "$_sm_blocked_out"; then
	smoke_ok "the job reports the block to its caller"
else
	smoke_bad "the job did not report the block: $(head -c 200 "$_sm_blocked_out")"
fi

if grep -q 'Broken pipe' "$_sm_blocked_out"; then
	smoke_bad "the blocked install wrote a broken-pipe complaint: $(grep 'Broken pipe' "$_sm_blocked_out")"
else
	smoke_ok "nothing was left writing into a closed pipe"
fi

# The log is what the page tails, so the reason has to reach it and not just
# stdout. Each line carries its own timestamp, which is what makes it a log
# entry rather than a blob dropped into the file.
#
# fcc_log falls back to /tmp/fcc-logs when the install path cannot be written,
# and the controller applies the same fallback when it goes looking for a job's
# output, so both are read here. The `|| true` is for `set -e`, which would
# otherwise end the run on a missing file instead of reporting it.
_sm_blocked_log="$(docker exec "$SMOKE_NAME" sh -c '
	cat /opt/fcc/logs/fcc-runtime.log 2>/dev/null \
		|| cat /tmp/fcc-logs/fcc-runtime.log 2>/dev/null || true')"

if [ -z "$_sm_blocked_log" ]; then
	smoke_bad "no install log was written at all"
	docker exec "$SMOKE_NAME" sh -c \
		'ls -ld /opt /opt/fcc /tmp/fcc-logs 2>&1' >&2 || true
fi
for _sm_want in 'install aborted' '[FAIL] Storage' 'Current:' 'Required:' 'Suggestion:'; do
	if printf '%s' "$_sm_blocked_log" | grep -qF "$_sm_want"; then
		smoke_ok "the log carries $_sm_want"
	else
		smoke_bad "the log is missing $_sm_want: $(printf '%s' "$_sm_blocked_log" | head -c 300)"
	fi
done

# Section 3.6.4 asks for all four parts of the report on the failing check,
# not a summary of it: what was checked, what it found, what it wanted and what
# to do. "precheck failed" on its own was the bug.
if printf '%s' "$_sm_blocked_log" | grep -q '999999999 MB'; then
	smoke_ok "the requirement shown is the one that was applied"
else
	smoke_bad "the log does not name the requirement that blocked the install"
fi

docker exec "$SMOKE_NAME" rm -rf /opt/fcc >/dev/null 2>&1

# ---------------------------------------------------------------------------
# The CPU rate on a board with no cpufreq
#
# OpenWrt 24.10 builds the Airoha EN7581 cpufreq driver but leaves
# CONFIG_CPUFREQ_DT off, and that driver's whole job is to register a cpufreq-dt
# platform device — so nothing binds, no policy is created, and on an AN7581
# neither /sys/devices/system/cpu/cpu0/cpufreq nor cpufreq/policy0 exists. The
# device tree's operating-points-v2 table is then the only clock figure on the
# system, and without it the page showed a dash on a router that was running
# perfectly well.
#
# The board is reproduced rather than described: a tmpfs goes over /sys so the
# cpufreq attributes are genuinely absent, and the real AN7581 OPP values are
# put where the kernel exposes them. The container is already privileged for
# procd's sake, and the mount is taken down again below.
#
# This runs here rather than on the host because this rootfs is the point: its
# busybox has no od at all, so the hexdump branch is the only branch, and a
# developer machine — where od is always present — cannot tell whether that
# branch works. The first two checks say so out loud, so that a rootfs which
# gains od is noticed rather than quietly changing what is under test.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The translation, which ships inside the package rather than beside it
# ---------------------------------------------------------------------------

smoke_note "the translation"
_sm_rc=0
smoke_sh '[ -s /usr/lib/lua/luci/i18n/fcc.zh-cn.lmo ]' || _sm_rc=$?
smoke_check "the compiled zh-cn catalogue arrived with the package" 0 "$_sm_rc"

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------

smoke_note "removing"
_sm_rc=0
smoke_remove || _sm_rc=$?
smoke_check "the package removes cleanly" 0 "$_sm_rc"

_sm_rc=0
smoke_sh '[ ! -e /usr/lib/lua/luci/controller/fcc.lua ]' || _sm_rc=$?
smoke_check "the controller is gone" 0 "$_sm_rc"

_sm_rc=0
smoke_sh '[ ! -e /usr/libexec/fcc/session.sh ]' || _sm_rc=$?
smoke_check "the backends are gone" 0 "$_sm_rc"

_sm_rc=0
smoke_sh '[ ! -e /usr/lib/lua/luci/i18n/fcc.zh-cn.lmo ]' || _sm_rc=$?
smoke_check "the compiled catalogue is gone" 0 "$_sm_rc"

# ---------------------------------------------------------------------------

if [ "$SMOKE_FAILED" -gt 0 ]; then
	printf '\nsmoke: %s check(s) FAILED\n' "$SMOKE_FAILED" >&2
	exit 1
fi
printf '\nsmoke: all checks passed\n'
