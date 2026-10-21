#!/bin/sh
# luci-app-fcc — pre-install / troubleshooting diagnostics.
#
# Usage:
#   doctor.sh            Human-readable report ([OK]/[WARN]/[FAIL] lines)
#   doctor.sh --json     Machine-readable report (used by the LuCI UI)
#   doctor.sh --blocking Only what failed, and what to do about it
#   doctor.sh --packages The packages whose installation would clear the whole
#                        report, one per line — and nothing when even one of the
#                        failures is something no package can fix
#   doctor.sh --agents <id>   Report on one agent rather than on the whole set
#
# The JSON form always contains "install_allowed": true|false. A FAIL on a
# critical check blocks installation (DESIGN_SPEC.md section 3.6.4).
#
# --blocking exists because of the second half of that section: a blocked
# install MUST show the check, its current value, what was required and how to
# fix it. The install log used to carry the words "precheck failed" and nothing
# else, which satisfies none of the four — the person reading it could see that
# they were stuck but not what they were stuck on. It reads the same accumulator
# the other two forms do, so there is no second opinion about what failed.
#
# --agents exists because the Configuration page can ask for a single agent, and
# the checks are about a set of agents rather than about the device: on a box
# with no C++ runtime for the Node the npm three need, an install of every agent
# is correctly blocked while an install of Claude Code is not. Without this the
# page would report the whole-registry verdict over a narrowed selection and
# tell the reader their install was blocked when the install job — which asks
# the same question of the set it was given — would have run it. The flag names
# one agent; the variable it sets also arrives from install.sh carrying several,
# which is why what is checked below is every id in it rather than the string.

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

JSON=0
BLOCKING=0
LIST_PACKAGES=0
while [ $# -gt 0 ]; do
	# ${1:-} rather than $1: the guard above already makes $1 safe here, but
	# every other script in this directory reads its argument the same way, and
	# tests/test_shell.sh holds them all to it.
	case "${1:-}" in
		--json)     JSON=1 ;;
		--blocking) BLOCKING=1 ;;
		--packages) LIST_PACKAGES=1 ;;
		--agents)   FCC_AGENT_SELECTION="${2:-}"; shift ;;
		--agents=*) FCC_AGENT_SELECTION="${1#--agents=}" ;;
	esac
	shift
done

# Checked here rather than trusted, because the answer decides how much of the
# report exists at all: an id the registry does not know matches no row, so the
# checks would find nothing to require and the report would come out *more*
# permissive than the truth. Refusing is the only safe direction — the same
# grammar-and-registry test the controller applies before it gets here
# (luci.fcc.util.valid_agent, luci.fcc.agents.exists).
#
# A list, not one id, and that is not a detail. --agents carries one agent, but
# this variable is also how install.sh hands the doctor the set it is about to
# install: it exports the whole registry for --all-agents and a comma-separated
# set for --agents, both of them space-separated by the time they arrive. Asking
# fcc_valid_agent() about the string as a whole therefore refused every real
# install with "unknown agent:  claude codex pi opencode cline hermes dsh grok
# muse aider" — an install blocked for a reason that was not true, which is
# worse than the permissive report this guard exists to prevent. Each id is
# checked on its own instead, so the list is honoured and the property holds:
# one id the registry does not know still stops the report rather than thinning
# it.
for _arg_id in $(printf '%s' "${FCC_AGENT_SELECTION:-}" | tr ',' ' '); do
	if ! fcc_valid_agent "$_arg_id"; then
		printf 'doctor.sh: unknown agent: %s\n' "$_arg_id" >&2
		printf 'usage: doctor.sh [--json] [--blocking] [--packages] [--agents <id>]\n' >&2
		exit 2
	fi
done

ROOT="$(fcc_root)"
# The floor comes from common.sh, shared with install.sh: the report this script
# prints and the gate install.sh applies are then the same number, so the report
# can never describe a requirement the installer does not enforce.
# FCC_REQUIRED_FREE_MB remains as the override the tests and the smoke test use
# to force this check to fail.
REQUIRED_FREE_MB="${FCC_REQUIRED_FREE_MB:-$FCC_MIN_FREE_MB}"
MIN_RAM_MB="${FCC_MIN_RAM_MB:-256}"
# Scratch space in /tmp, which on OpenWrt is a tmpfs carved out of RAM rather
# than part of the flash the storage check above measures.
MIN_TMP_MB="${FCC_MIN_TMP_MB:-64}"

# Result accumulators (space separated "status|name|value|requirement|hint").
RESULTS=""
fail_count=0
warn_count=0
# The packages a failed check named, and how many of the failures named one.
# The two are compared by --packages: installing packages can only clear the
# report when there is no failure left that no package can fix.
FIX_PACKAGES=""
FIXABLE_FAIL_COUNT=0

add_result() {
	# add_result <OK|WARN|FAIL> <name> <value> <requirement> [hint] [package]
	#
	# The optional sixth argument names the package that would satisfy a FAIL.
	# It is given only where a package is the whole remedy — tar, bash, the
	# missing applets, a C++ runtime — and is what makes the installer able to
	# add the dependency before it runs rather than stop and ask for one. A
	# failure with no package (storage, DNS, an unsupported CPU) stays a plain
	# FAIL and keeps --packages silent, because installing things would not
	# unblock it.
	RESULTS="${RESULTS}${1}|${2}|${3}|${4}|${5:-}
"
	case "$1" in
		FAIL) fail_count=$((fail_count + 1)) ;;
		WARN) warn_count=$((warn_count + 1)) ;;
	esac
	# Counted separately from fail_count so the two can be compared: a report
	# is fixable by package only when every failure named one.
	if [ "$1" = FAIL ] && [ -n "${6:-}" ]; then
		FIX_PACKAGES="$FIX_PACKAGES $6"
		FIXABLE_FAIL_COUNT=$((FIXABLE_FAIL_COUNT + 1))
	fi
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

# libc (section 3.6.4). The runtime's private Python comes from uv, which
# fetches a build matched to the libc it finds; a musl router and a glibc host
# therefore get different interpreters. The probe lives in common.sh now
# because install.sh asks the same question about Cline, and one answer is the
# only way the report and the install can agree.
_libc="$(fcc_libc)"
case "$_libc" in
	musl) add_result OK "libc" "musl" "musl" "" ;;
	*)    add_result WARN "libc" "$_libc" "musl" \
		"OpenWrt ships musl; the runtime is fetched for the libc found here." ;;
esac

# Storage at the install path's filesystem.
_stpath="$ROOT"
[ -d "$_stpath" ] || _stpath="$(dirname "$ROOT")"
[ -d "$_stpath" ] || _stpath="/"
_free_mb="$(df -P -k "$_stpath" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')"
if [ -n "$_free_mb" ] && [ "$_free_mb" -ge "$REQUIRED_FREE_MB" ]; then
	add_result OK "Storage" "${_free_mb} MB free" ">= ${REQUIRED_FREE_MB} MB" "$_stpath"
else
	add_result FAIL "Storage" "${_free_mb:-?} MB free" ">= ${REQUIRED_FREE_MB} MB" \
		"Free space at $_stpath is insufficient for the FCC runtime. Install to a filesystem that has room: set the install path (uci set fcc.main.install_path=...) to a mount with ${REQUIRED_FREE_MB} MB free, such as a USB disk."
fi

# /tmp space (section 3.6.4), which is a different filesystem from the install
# path on OpenWrt: /tmp is a tmpfs sized from RAM, so a router can have plenty
# of flash and almost no scratch space. The installer unpacks there.
#
# A warning rather than a failure: we cannot show that a small /tmp breaks a
# given install, and refusing to install on a router that would have worked is
# worse than installing with the risk stated.
_tmp_mb="$(df -P -k /tmp 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')"
if [ -n "$_tmp_mb" ] && [ "$_tmp_mb" -ge "$MIN_TMP_MB" ]; then
	add_result OK "/tmp space" "${_tmp_mb} MB free" ">= ${MIN_TMP_MB} MB" "/tmp"
else
	add_result WARN "/tmp space" "${_tmp_mb:-?} MB free" ">= ${MIN_TMP_MB} MB" \
		"The installer unpacks into /tmp; a small tmpfs may not be enough."
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

# tar, and specifically a tar that can do what uv's installer asks of it.
#
# A FAIL when there is no uv, because the installer then downloads one and
# unpacks it with `tar xf ... --no-same-owner --strip-components 1` — neither
# option exists in BusyBox tar, which is the only tar a stock OpenWrt image
# has. It prints its usage text, exits 1, and the installer stops with
# "uv installation failed with exit code 1" a few seconds after the last
# question. Nothing is installed and nothing says why on the page.
#
# A WARN when a uv is already on PATH, because ensure_uv() then leaves it
# alone and no archive is unpacked. Not an OK: this package keeps its uv under
# the runtime root, and the update path moves that directory aside before the
# installer runs, so the next update downloads uv again — and needs the tar.
#
# The verdict comes from unpacking a real archive, not from a version string:
# see fcc_tar_can_extract_uv_archive() in common.sh.
if fcc_tar_can_extract_uv_archive; then
	_tar_v="$(tar --version 2>/dev/null | grep -v '^[[:space:]]*$' | head -n1 | cut -c1-40)"
	add_result OK "tar" "${_tar_v:-present}" "supports --strip-components" ""
elif [ -n "$_uv" ]; then
	_tar_v="$(tar --version 2>/dev/null | grep -v '^[[:space:]]*$' | head -n1 | cut -c1-40)"
	add_result WARN "tar" "${_tar_v:-BusyBox tar}" "supports --strip-components" \
		"$(fcc_pkg_install_hint tar) — needed whenever uv has to be downloaded, which every update does."
else
	_tar_v="$(tar --version 2>/dev/null | grep -v '^[[:space:]]*$' | head -n1 | cut -c1-40)"
	add_result FAIL "tar" "${_tar_v:-not found}" "supports --strip-components" \
		"$(fcc_pkg_install_hint tar) — uv's installer unpacks its release with --strip-components and --no-same-owner, which BusyBox tar does not support, so the install stops before uv is installed." \
		tar
fi

# Node (needed by some agents).
_node="$(fcc_detect_version node --version 2>/dev/null || true)"
if [ -n "$_node" ]; then add_result OK "Node.js" "$_node" "if required by agents" ""
else add_result WARN "Node.js" "not found" "if required by agents" "Some agents need Node.js."; fi

# tmux — required for the Web Console, and for the runtime installer.
#
# A FAIL rather than a warning, and it used to be a warning. tmux is not only
# the console's backend: it is also the terminal the upstream installer's agent
# chooser is driven through, because that chooser reads /dev/tty and refuses to
# run without one. On a box with no tmux the install therefore does not merely
# lose a feature, it fails — and a check that says "warning" in front of a
# guaranteed failure is worse than no check, because it teaches the reader to
# ignore the one line that mattered.
#
# In practice this is nearly invisible: tmux is a hard dependency of this
# package, so it is present on every box that installed the package normally.
# The check fires when it has been removed, or when the package files were
# copied in by hand.
_tmux="$(fcc_detect_version tmux -V 2>/dev/null || true)"
if [ -n "$_tmux" ]; then
	add_result OK "tmux" "$_tmux" "required" ""
else
	add_result FAIL "tmux" "not found" "required" \
		"$(fcc_pkg_install_hint tmux) — the Web Console and the runtime installer both need it." \
		tmux
fi

# bash — required by five of the ten agents, and absent from every stock image.
#
# The upstream installer hands Claude Code, OpenCode, Hermes, Grok Build and
# Muse Code to their own installers, which are bash scripts, and stops with
# "bash is required. Install it first, then rerun this installer." when it
# cannot find one. OpenWrt ships busybox ash as /bin/sh and no bash at all, so
# before this check existed the install failed several minutes in, after the
# download, with the reason buried in logs/installer.out.
#
# Which agents count is not fixed. FCC_AGENT_SELECTION carries the set the user
# asked for, FCC_AGENT_NONE says the user unchecked all of them, and neither
# being set means upstream's defaults, which include Claude Code. In every case
# the effective set is that set *plus what is already installed* — upstream's
# chooser keeps an already-present agent without asking, so an agent that is
# installed is in the set whatever was requested.
#
# Computed once, here, because the fold check below asks the same question and
# a second copy of this logic is how the two would come to disagree. The
# installed set is kept separately as well: whether an agent is already present
# is what decides whether its installer runs at all, which is the difference
# between the fold check failing and warning.
_selection="${FCC_AGENT_SELECTION:-}"
_installed_set="$(fcc_installed_agents "$ROOT")"
if [ "${FCC_AGENT_NONE:-0}" = 1 ]; then
	_effective_set="$_installed_set"
elif [ -n "$_selection" ]; then
	_effective_set="$(fcc_effective_agents "$_selection" "$ROOT")"
else
	_effective_set="$(fcc_default_agents) $_installed_set"
fi

# An agent this system cannot install is not a requirement of the install.
# Cline on musl is the case: it is in the default set before the libc question
# is asked, and the install leaves it out (install.sh), so a Node or a bash it
# would have needed must not turn the report red for an install that will not
# run it. The per-agent row below still says it is unavailable, with the reason.
_unsupported_set="$(fcc_unsupported_agents_in "$_effective_set")"
if [ -n "$_unsupported_set" ]; then
	_kept_set=""
	for _us_id in $_effective_set; do
		case " $_unsupported_set " in
			*" $_us_id "*) ;;
			*) _kept_set="$_kept_set $_us_id" ;;
		esac
	done
	_effective_set="$_kept_set"
fi

_bash_req="needed by: $(printf '%s' "$FCC_BASH_AGENTS" | tr ' ' ',')"
_bash_names=""
for _ba_id in $FCC_BASH_AGENTS; do
	case " $_effective_set " in
		*" $_ba_id "*)
			# The id stands in when the registry cannot name it. The list is
			# what decides between FAIL and WARN below, so an empty name would
			# collapse it to a bare separator and turn a doomed install into a
			# warning — the one outcome this check exists to prevent.
			_ba_name="$(fcc_agent_name "$_ba_id")"
			[ -n "$_ba_name" ] || _ba_name="$_ba_id"
			_bash_names="$_bash_names, $_ba_name"
			;;
	esac
done
_bash_names="${_bash_names#, }"
_bash_v="$(fcc_detect_version bash --version 2>/dev/null || true)"
if [ -n "$_bash_v" ]; then
	add_result OK "bash" "$_bash_v" "$_bash_req" ""
elif [ -n "$_bash_names" ]; then
	add_result FAIL "bash" "not found" "$_bash_req" \
		"$(fcc_pkg_install_hint bash) — required by $_bash_names. Or select only agents that do not need it." \
		bash
else
	add_result WARN "bash" "not found" "$_bash_req" \
		"Not needed by the selected agents; add it before selecting one that needs it."
fi

# Tools the agent installers need, and this image's BusyBox may not provide.
#
# One loop over FCC_INSTALLER_TOOLS, because the two gaps found so far differ
# only in what they are called: fold is missing outright ("fold: not found"),
# sleep is present but cannot do fractions ("sleep: invalid number '0.075'"),
# and both end the same way — an installer that stops with an exit code and
# names nothing. The table in common.sh carries the measurements; this decides
# the verdict.
#
# A FAIL only when the installer that needs the tool will actually run. The
# agent may already be installed (its installer is then never fetched), or not
# selected at all — and a FAIL here clears install_allowed, which would block an
# install that works. That is the same reasoning as the tar check above, and the
# opposite of the bash check, which cannot know whether the agent's own
# installer will want it.
for _tl_tool in $FCC_INSTALLER_TOOLS; do
	_tl_agents="$(fcc_tool_agents "$_tl_tool")"
	# The tool's own name, not the package's: the row is about what is missing
	# from this image, and the package that fills the gap is in the hint.
	if fcc_tool_works "$_tl_tool"; then
		_tl_v="$(fcc_detect_version "$_tl_tool" --version 2>/dev/null || true)"
		# sleep has no --version under BusyBox and fold has none when the applet
		# is absent, so an empty value here is not a failure — fcc_tool_works
		# already answered the question that matters.
		add_result OK "$_tl_tool" "${_tl_v:-present}" "needed to install an agent" ""
		continue
	fi

	_tl_will_run=""
	_tl_present=""
	for _tl_id in $_tl_agents; do
		case " $_effective_set " in
			*" $_tl_id "*)
				# The id stands in when the registry cannot name it, for the
				# same reason as the bash check above: these two lists decide
				# the verdict, and one that an empty name can collapse would
				# report a doomed install as a warning.
				_tl_name="$(fcc_agent_name "$_tl_id")"
				[ -n "$_tl_name" ] || _tl_name="$_tl_id"
				case " $_installed_set " in
					*" $_tl_id "*) _tl_present="$_tl_present, $_tl_name" ;;
					*) _tl_will_run="$_tl_will_run, $_tl_name" ;;
				esac
				;;
		esac
	done
	_tl_will_run="${_tl_will_run#, }"
	_tl_present="${_tl_present#, }"

	# "not found" is the wrong word for a tool that is there and cannot do the
	# job — BusyBox's sleep exists and refuses the fraction the Pi installer
	# animates its logo with. The two are told apart by asking whether the
	# command is there at all, rather than by listing the tools that can be
	# limited: the next gap of this kind will be a different applet, and a
	# reader who is told a present tool is missing goes looking for it, finds
	# it, and is back where they started.
	_tl_state="not found"
	command -v "$_tl_tool" >/dev/null 2>&1 && _tl_state="too limited"
	_tl_pkg="$(fcc_tool_package "$_tl_tool")"
	_tl_why="$(fcc_tool_purpose "$_tl_tool")"

	if [ -n "$_tl_will_run" ]; then
		add_result FAIL "$_tl_tool" "$_tl_state" "needed to install an agent" \
			"$(fcc_pkg_install_hint "$_tl_pkg") — $_tl_why. Required by $_tl_will_run." \
			"$_tl_pkg"
	elif [ -n "$_tl_present" ]; then
		add_result WARN "$_tl_tool" "$_tl_state" "needed to install an agent" \
			"$_tl_present is already installed, so its installer is not run — but reinstalling it needs $_tl_tool: $(fcc_pkg_install_hint "$_tl_pkg")."
	else
		add_result WARN "$_tl_tool" "$_tl_state" "needed to install an agent" \
			"Not needed by the selected agents; add it before selecting one that needs it."
	fi
done

# Node.js — the runtime Pi, DeepSeek Harness and Cline are installed with.
#
# An absent Node is a WARN and not a FAIL, which is the opposite of every other
# row here, because this package fixes this one: the installer fetches a musl
# build before it runs the upstream installer (common.sh has the measurements).
# Reporting a FAIL would clear install_allowed and block an install that works.
#
# The FAIL is kept for the case it cannot fix — a CPU with no musl build — since
# that is a real dead end, and without it the install would run for minutes and
# then stop at the first npm-based agent.
_node_ids="$(fcc_node_agents_in "$_effective_set")"
if [ -n "$_node_ids" ]; then
	_node_names=""
	_node_unsatisfied=""
	for _node_id in $_node_ids; do
		_node_name="$(fcc_agent_name "$_node_id")"
		[ -n "$_node_name" ] || _node_name="$_node_id"
		fcc_node_ok_for "$_node_id" || _node_unsatisfied="$_node_unsatisfied, $_node_name"
		_node_names="$_node_names, $_node_name"
	done
	_node_names="${_node_names#, }"
	_node_unsatisfied="${_node_unsatisfied#, }"
	_node_v="$(fcc_node_version 2>/dev/null || true)"
	_node_req="needed to install $_node_names"
	if [ -z "$_node_unsatisfied" ]; then
		add_result OK "node" "$_node_v" "$_node_req" ""
	elif [ -z "$(fcc_node_arch)" ]; then
		add_result FAIL "node" "${_node_v:-not found}" "needed to install $_node_unsatisfied" \
			"No Node.js build exists for this CPU ($(uname -m 2>/dev/null)), so $_node_unsatisfied cannot be installed here."
	else
		# The build exists for this CPU, so the fetch the warning below promises
		# can happen — but a build that cannot load is not a Node, and the
		# warning was a promise this package could not keep. The musl build is
		# linked against libstdc++.so.6 and libgcc_s.so.1, and a stock image has
		# neither (common.sh carries the measurement): on 2026-10-19 the Node
		# this package fetched onto the test router was reported as installed
		# and then died in the loader, taking the whole install with it.
		#
		# A FAIL, because it is not something this package can fix and the user
		# can: one package, named here, before anything is downloaded. It closes
		# install_allowed, which is the point — the alternative is a rollback and
		# a transcript to read.
		_node_libs="$(fcc_node_missing_libs)"
		if [ -n "$_node_libs" ]; then
			# One string, two uses: the hint names every package (the loader may
			# be missing both libraries), and the same list is what --packages
			# hands the installer. Kept as one argument so the sixth-argument
			# contract of add_result holds even here.
			_node_pkgs="$(fcc_node_lib_packages $_node_libs)"
			add_result FAIL "node" "${_node_v:-not found}" "needed to install $_node_unsatisfied" \
				"The musl Node.js this package fetches needs $_node_libs, which this image has nowhere the loader looks: $(fcc_pkg_install_hint $_node_pkgs)." \
				"$_node_pkgs"
		else
			add_result WARN "node" "${_node_v:-not found}" "needed to install $_node_unsatisfied" \
				"The installer fetches a musl Node.js for them before it runs; nothing to do by hand."
		fi
	fi
fi

# The C++ runtime, for Hermes alone.
#
# Hermes is not one of the agents this package provisions Node for — its own
# installer clones the repository and fetches its own — but the Node it fetches
# is the same musl build, linked against the same libstdc++.so.6, and its
# prerequisites stage fails on a box without it:
#
#     ✗ musl host: the Node.js runtime needs the system libstdc++.
#
# The node row above asks the same question whenever a node agent is selected;
# this asks it when Hermes is the only thing that will need the answer. A
# Hermes-only install was the one case where the install could reach the
# installer and stop for a library the report never mentioned.
if [ -z "$_node_ids" ]; then
	case " $_effective_set " in *" hermes "*)
		_hm_libs="$(fcc_node_missing_libs)"
		if [ -z "$_hm_libs" ]; then
			add_result OK "libstdc++" "present" "needed to install Hermes" ""
		else
			_hm_pkgs="$(fcc_node_lib_packages $_hm_libs)"
			add_result FAIL "libstdc++" "$_hm_libs missing" "needed to install Hermes" \
				"The musl Node.js the Hermes installer fetches needs $_hm_libs, which this image has nowhere the loader looks: $(fcc_pkg_install_hint $_hm_pkgs)." \
				"$_hm_pkgs"
		fi
		;;
	esac
fi

# FCC runtime present?
if [ -x "$ROOT/bin/fcc-server" ]; then
	_fv="$(fcc_detect_version "$ROOT/bin/fcc-server" --version 2>/dev/null || true)"
	add_result OK "FCC Runtime" "${_fv:-present}" "any" ""
else
	add_result WARN "FCC Runtime" "not installed" "any" "Use Install FCC Runtime."
fi

# FCC Server — the running process, which section 80 lists separately from the
# runtime on disk. The two fail independently: the runtime can be installed with
# nothing running, and a stale pid file can outlive the process it names.
_server_pid="$(fcc_server_pid 2>/dev/null || true)"
if [ -n "$_server_pid" ] && fcc_proc_alive "$_server_pid"; then
	add_result OK "FCC Server" "running (pid $_server_pid)" "any" ""
else
	add_result WARN "FCC Server" "not running" "any" \
		"Start it from the Configuration page."
fi

# Port availability.
_port="$(fcc_uci_get main port 8082)"
if command -v netstat >/dev/null 2>&1; then
		# Read the table first, then match. netstat is a busybox applet, and a
		# `grep -q` at the far end of the pipe stops reading at the first match
		# and leaves netstat writing into a closed pipe — which busybox reports
		# as "netstat: standard output: Broken pipe", in the middle of an
		# install log that is already trying to explain a failure.
		_net_listen="$(netstat -ltn 2>/dev/null)"
		if printf '%s\n' "$_net_listen" | grep -q ":$_port[[:space:]]"; then
		add_result WARN "Port $_port" "in use" "free" "Another process is listening."
	else
		add_result OK "Port $_port" "free" "free" ""
	fi
else
	add_result OK "Port $_port" "unchecked" "free" "netstat unavailable."
fi

# Agent executables (section 80).
#
# One line per registered agent, so the report answers "which of these can I
# actually run?" instead of "is something missing?". A missing agent is a WARN
# and never a FAIL: the runtime installs perfectly well with none of them, and
# which agents a user wants is their choice. The launcher is what is tested, not
# the underlying CLI — it is the launcher that the console runs.
while IFS='|' read -r _ad_id _ad_name _ad_launch _ad_rest; do
	case "$_ad_id" in ''|\#*) continue ;; esac
	[ -n "$_ad_launch" ] || continue
	# An agent this system has no build for is not "not installed" — that
	# reads as something the user can fix from the page, and there is no such
	# installer to run. Cline on musl is the case; common.sh carries the
	# measurement and the sentence.
	_ad_unsupported="$(fcc_agent_unsupported_reason "$_ad_id")"
	if [ -n "$_ad_unsupported" ]; then
		add_result WARN "$_ad_name" "not available" "optional" "$_ad_unsupported"
		continue
	fi
	# The shared rule, not a bare `command -v`. This file already asks the
	# question the right way for its bash check above — fcc_installed_agents
	# takes the root — and the two answers have to agree. The launchers live in
	# <root>/bin, which the doctor does not have on PATH.
	if fcc_agent_installed "$_ad_id" "$ROOT"; then
		add_result OK "$_ad_name" "installed" "optional" ""
	else
		add_result WARN "$_ad_name" "not installed" "optional" \
			"Install it from the Configuration page to use it."
	fi
done <<-EOF
$(fcc_agents_each)
EOF

# DNS, checked separately from HTTPS: a resolver that does not answer and a
# route that does not carry traffic are different faults with different fixes,
# and "cannot download the installer" is not a useful thing to tell someone.
if command -v nslookup >/dev/null 2>&1; then
	if nslookup raw.githubusercontent.com >/dev/null 2>&1; then
		add_result OK "DNS" "resolves" "raw.githubusercontent.com" ""
	else
		add_result FAIL "DNS" "cannot resolve" "raw.githubusercontent.com" \
			"Check the router's DNS settings."
	fi
else
	add_result OK "DNS" "unchecked" "raw.githubusercontent.com" "nslookup unavailable."
fi

# HTTPS reachability to the installer host.
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
	add_result FAIL "curl" "not found" "required" "Install the curl package." curl
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

# The packages that would clear the report, or nothing.
#
# Nothing when any failure has no package behind it: an install of tar cannot
# make room on the flash, resolve DNS or give an unsupported CPU a Node build,
# and an installer that added packages anyway would be changing the system to
# no purpose. Nothing either when the report already passes — there is nothing
# to clear, and printing the packages of some earlier WARN would make the
# installer reach for the package manager on a box that needs nothing.
#
# Deduplicated and in check order: the same package can be named by two checks
# (curl is a dependency of the tar row's world too), and installing it twice is
# at best noise in the log.
fixable_packages() {
	[ "$fail_count" -gt 0 ] || return 0
	[ "$FIXABLE_FAIL_COUNT" -eq "$fail_count" ] || return 0
	printf '%s\n' $FIX_PACKAGES | awk 'NF && !seen[$0]++'
}

if [ "$LIST_PACKAGES" -eq 1 ]; then
	fixable_packages
	exit 0
fi

if [ "$BLOCKING" -eq 1 ]; then
	# Only the FAILs: this output is read by someone whose install just stopped,
	# and the passing checks are not why they are here. The label is the "result"
	# of the section 3.6.4 quartet; the three indented lines are the rest of it.
	printf '%s' "$RESULTS" | while IFS='|' read -r st name val req hint; do
		[ "$st" = FAIL ] || continue
		printf '[FAIL] %s\n' "$name"
		printf '  Current:    %s\n' "$val"
		printf '  Required:   %s\n' "$req"
		[ -n "$hint" ] && printf '  Suggestion: %s\n' "$hint"
	done
	exit 0
fi

if [ "$JSON" -eq 1 ]; then
	printf '{\n'
	printf '  "install_allowed": %s,\n' "$install_allowed"
	printf '  "fail_count": %s,\n' "$fail_count"
	printf '  "warn_count": %s,\n' "$warn_count"
	# What the installer will add before it starts — empty unless installing
	# packages is the whole of what stands between the report and a pass. The
	# page reads this so a blocked install it can fix does not read like one
	# that needs the user to go and fix it.
	printf '  "packages": ['
	_pkg_first=1
	fixable_packages | while IFS= read -r _pkg_name; do
		[ -n "$_pkg_name" ] || continue
		[ "$_pkg_first" -eq 1 ] || printf ', '
		_pkg_first=0
		printf '%s' "$(fcc_json_str "$_pkg_name")"
	done
	printf '],\n'
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
