#!/bin/sh
# luci-app-fcc — batched status collector.
#
# Emits a single JSON document describing LuCI-FCC, the FCC runtime, the FCC
# server, every coding agent, and system memory/storage. This is the ONE place
# the UI polls (DESIGN_SPEC.md section 3.8) so a refresh costs a single process
# rather than one `ps|grep|df` pipeline per agent.
#
# Usage:
#   status.sh                     fast status
#   status.sh --refresh-versions  also (re)detect the FCC/server version
#
# The output is always valid JSON, even when the FCC runtime is absent.
#
# Version policy (DESIGN_SPEC.md section 44/45): the FCC server version is read
# with `fcc-server --version` (documented as safe by upstream). Coding-agent
# versions are NEVER probed by running the launcher — `fcc-claude` & friends are
# *launchers* that would start the agent. Agent versions come from the runtime
# metadata written at install time, or show as null.
#
# Locals are per-function prefixed — see the note at the top of common.sh.

set -u
. "${FCC_LIBDIR:-/usr/libexec/fcc}/common.sh"

REFRESH_VERSIONS=0
[ "${1:-}" = "--refresh-versions" ] && REFRESH_VERSIONS=1

ROOT="$(fcc_root)"

# ---------------------------------------------------------------------------
# /proc helpers
# ---------------------------------------------------------------------------
# Build a "comm pid" map for every process, in one pass with builtin reads.
build_comm_map() {
	for _bc_d in /proc/[0-9]*; do
		[ -r "$_bc_d/comm" ] || continue
		IFS= read -r _bc_c < "$_bc_d/comm" 2>/dev/null || continue
		printf '%s %s\n' "$_bc_c" "${_bc_d#/proc/}"
	done
}

# ---------------------------------------------------------------------------
# Locate the FCC runtime and its process
#
# Both live in common.sh: the update path needs the same two answers for its
# health check, and two copies of "where is fcc-server / which PID is it" would
# eventually disagree about a box that has more than one FCC install.
# ---------------------------------------------------------------------------
FCC_SERVER_EXE="$(fcc_find_server_exe 2>/dev/null || true)"
fcc_installed=false
[ -n "$FCC_SERVER_EXE" ] && fcc_installed=true

server_pid="$(fcc_server_pid 2>/dev/null || true)"
server_running=false
server_uptime=""
server_rss=""
if [ -n "$server_pid" ] && fcc_proc_alive "$server_pid"; then
	server_running=true
	server_uptime="$(fcc_proc_uptime_secs "$server_pid")"
	server_rss="$(fcc_proc_rss_kb "$server_pid")"
fi

# ---------------------------------------------------------------------------
# Reachability (DESIGN_SPEC.md section 49)
#
# The same three signals an update is judged on, reported live so the page can
# show them without waiting for an update to fail. The HTTP probe only runs
# when something is actually listening: with nothing there the connection is
# refused instantly anyway, and with a hung server it would otherwise add its
# full timeout to every status refresh.
# ---------------------------------------------------------------------------
server_port="$(fcc_uci_get main port 8082)"
case "$server_port" in ''|*[!0-9]*) server_port=8082 ;; esac

server_listening=false
fcc_port_listening "$server_port" && server_listening=true

server_http=""
if [ "$server_listening" = true ]; then
	server_http="$(fcc_http_status "http://127.0.0.1:$server_port/admin" 2 2>/dev/null || true)"
fi

server_healthy=false
if [ "$server_running" = true ] && [ "$server_listening" = true ]; then
	# Without curl the HTTP leg cannot be tested at all, so the documented
	# minimum (process + port) stands rather than failing on a missing tool.
	if [ -n "$server_http" ] || ! command -v curl >/dev/null 2>&1; then
		server_healthy=true
	fi
fi

# ---------------------------------------------------------------------------
# Versions (bounded, cached)
# ---------------------------------------------------------------------------
fcc_version="$(fcc_cache_get fcc_version 2>/dev/null || true)"
if [ "$REFRESH_VERSIONS" -eq 1 ] || ! fcc_cache_fresh; then
	if [ "$fcc_installed" = true ]; then
		if _vv="$(fcc_detect_version "$FCC_SERVER_EXE" --version 2>/dev/null)"; then
			fcc_version="$_vv"
			fcc_cache_set fcc_version "$_vv"
		fi
	fi
	# Mark the cache fresh even if detection failed, so we do not retry-storm.
	fcc_cache_set refreshed_at "$(date +%s)"
fi

server_version="${fcc_version:-}"   # same executable reports both

# ---------------------------------------------------------------------------
# System memory / storage / arch
# ---------------------------------------------------------------------------
mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
[ -n "$mem_avail" ] || mem_avail="$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)"

storage_path="$ROOT"
[ -d "$storage_path" ] || storage_path="$(dirname "$ROOT")"
[ -d "$storage_path" ] || storage_path="/"
_df="$(df -P -k "$storage_path" 2>/dev/null | awk 'NR==2{print $2" "$3" "$4}')"
st_total_k="$(printf '%s' "$_df" | cut -d' ' -f1)"
st_used_k="$(printf '%s' "$_df" | cut -d' ' -f2)"
st_free_k="$(printf '%s' "$_df" | cut -d' ' -f3)"
case "$st_total_k" in ''|*[!0-9]*) st_total_k=0 ;; esac
case "$st_used_k"  in ''|*[!0-9]*) st_used_k=0  ;; esac
case "$st_free_k"  in ''|*[!0-9]*) st_free_k=0  ;; esac
st_total_b=$(( st_total_k * 1024 ))
st_free_b=$(( st_free_k * 1024 ))
st_used_b=$(( st_used_k * 1024 ))

arch="$(uname -m 2>/dev/null)"

# Hardware platform (section 15's System list). The OpenWrt target names the
# platform the firmware was built for — "airoha/an7581" on an Airoha AN7581
# board, "armsr/armv8" on a generic arm64 image — which is the thing that tells
# two devices with the same `arch` apart, so it is a reading of its own rather
# than something `arch` can be stretched to say.
#
# Read in a subshell: /etc/openwrt_release is a shell fragment, and sourcing it
# into this script would let it assign over the readings above it.
platform="$( ( . "$(fcc_openwrt_release)" 2>/dev/null; printf '%s' "${DISTRIB_TARGET:-}" ) 2>/dev/null )"
# A device whose image carries no openwrt_release still knows its board.
[ -n "$platform" ] || platform="$(cat "$(fcc_sysinfo_dir)/board_name" 2>/dev/null)"
# The board's own name for itself. The target covers a family of boards, so this
# is the only place the specific one is named. /tmp/sysinfo is written at boot,
# which is why it is absent from an image that has never been started.
platform_model="$(cat "$(fcc_sysinfo_dir)/model" 2>/dev/null)"

# ---------------------------------------------------------------------------
# CPU model, frequency and cores
#
# The model/core parsing lives in common.sh so it can be tested against the
# cpuinfo of every architecture this runs on, not just the one the test machine
# has. What stays here is the cpufreq lookup, which is the part that needs a
# real kernel: where /sys exposes a rate it is the frequency the CPU is running
# at now, which is a better answer than the nominal one cpuinfo reports.
# ---------------------------------------------------------------------------
cpu_model=""
cpu_mhz=""
cpu_mhz_max=""
cpu_cores=""

_cpu_info="$(fcc_cpu_info)"
{
	IFS= read -r cpu_model
	IFS= read -r cpu_mhz
	IFS= read -r cpu_cores
} <<-EOF
$_cpu_info
EOF

# /proc/cpuinfo reports MHz as a float ("2400.000"); the page shows whole MHz.
case "$cpu_mhz" in
	''|*[!0-9.]*) cpu_mhz="" ;;
	*.*)          cpu_mhz="${cpu_mhz%%.*}" ;;
esac
case "$cpu_mhz" in
	''|*[!0-9]*) cpu_mhz="" ;;
esac

# Where the kernel keeps its per-CPU facts. Needed by the model fallback below
# and by the cpufreq lookups after it.
_cpu_sys="$(fcc_sys_cpu)"

# The model, when /proc/cpuinfo names none.
#
# arm64 is that case rather than a broken board: mainline prints "model name"
# only for a 32-bit ELF platform and has no "Hardware" line at all, because
# that one is arm32 or a vendor tree. On an AN7581 the file therefore names no
# CPU, and the page showed a dash where the model belongs.
#
# The device tree always knows. The CPU node's `compatible` says
# "arm,cortex-a53" on that board, and cpu0/of_node is the kernel's own symlink
# to that node, so it is tried first — it avoids guessing the unit address
# (`cpu@0` on one SoC, `cpu@000` on the next). The path under the device tree
# base is what a kernel without the symlink leaves, and it is the one the smoke
# rootfs exercises.
if [ -z "$cpu_model" ]; then
	for _cpu_f in \
		"$_cpu_sys/cpu0/of_node" \
		"$(fcc_dt_base)/cpus/cpu@0"
	do
		cpu_model="$(fcc_cpu_dt_model "$_cpu_f")" || cpu_model=""
		[ -n "$cpu_model" ] && break
	done
fi

# cpufreq, where the kernel has it, answers better than /proc/cpuinfo: it is
# the rate the CPU is running at now rather than a nominal one.
#
# The sysfs layout moved. Until Linux 5.6 the attributes sat under
# cpu0/cpufreq; the cpufreq core now exposes one directory per policy, so an
# ARM router on a current kernel has cpufreq/policy0 and no cpu0/cpufreq at
# all. Both are tried. Current-rate attributes come first in each pair — a rate
# being read right now beats a maximum the CPU may never be asked to reach.
_cpu_khz=""
for _cpu_f in \
	"$_cpu_sys/cpu0/cpufreq/scaling_cur_freq" \
	"$_cpu_sys/cpu0/cpufreq/cpuinfo_cur_freq" \
	"$_cpu_sys/cpufreq/policy0/scaling_cur_freq" \
	"$_cpu_sys/cpufreq/policy0/cpuinfo_cur_freq" \
	"$_cpu_sys/cpu0/cpufreq/cpuinfo_max_freq" \
	"$_cpu_sys/cpufreq/policy0/cpuinfo_max_freq"
do
	[ -r "$_cpu_f" ] || continue
	IFS= read -r _cpu_khz < "$_cpu_f" 2>/dev/null || :
	[ -n "$_cpu_khz" ] && break
done
case "$_cpu_khz" in
	''|*[!0-9]*) _cpu_khz="" ;;
esac

# Device tree, when sysfs has nothing to say.
#
# This is the rate the kernel was told the CPU runs at. On a board with no
# cpufreq policy — either because the kernel has no driver for it or, as on the
# Airoha EN7581 under OpenWrt 24.10, because the driver that would bind is not
# built — it is the only clock figure that exists anywhere on the system, and
# without it the page shows a dash on hardware that is running perfectly well.
#
# It is a nominal rate, not a current one, and that difference is real: this is
# what the CPU is specified at, not what it is doing this second. It is used
# only after every cpufreq attribute has been tried, so a board that can answer
# the better question is never given the worse answer.
#
# Two shapes, because the device tree states this two ways and the boards that
# need the fallback use the second. `clock-frequency` is a big-endian 32-bit
# count of Hz, read as bytes — `read` would hand back four unprintable
# characters; cpu0/of_node is a symlink to the CPU's own device tree node, which
# avoids guessing the unit address (`cpu@0` on one SoC, `cpu@000` on the next).
# An arm64 board instead carries an operating-points-v2 table and no
# clock-frequency at all, which is what fcc_cpu_dt_opp_hz reads.
if [ -z "$_cpu_khz" ]; then
	for _cpu_f in \
		"$_cpu_sys/cpu0/of_node/clock-frequency" \
		"$(fcc_dt_base)/cpus/cpu@0/clock-frequency"
	do
		_cpu_hz="$(fcc_cpu_dt_hz "$_cpu_f")" || continue
		_cpu_khz=$(( _cpu_hz / 1000 ))
		[ "$_cpu_khz" -gt 0 ] && break
		_cpu_khz=""
	done
fi
if [ -z "$_cpu_khz" ]; then
	_cpu_hz="$(fcc_cpu_dt_opp_hz "$(fcc_dt_base)")" || _cpu_hz=""
	[ -n "$_cpu_hz" ] && _cpu_khz=$(( _cpu_hz / 1000 ))
fi
case "$_cpu_khz" in
	''|*[!0-9]*) _cpu_khz="" ;;
esac
[ -n "$_cpu_khz" ] && cpu_mhz=$(( _cpu_khz / 1000 ))

# The maximum, from the same two layouts. When the current rate came from the
# device tree there is no separate maximum to find, and the nominal clock is
# the best available answer to that question too.
_cpu_khz_max=""
for _cpu_f in \
	"$_cpu_sys/cpu0/cpufreq/cpuinfo_max_freq" \
	"$_cpu_sys/cpufreq/policy0/cpuinfo_max_freq" \
	"$_cpu_sys/cpu0/cpufreq/scaling_max_freq" \
	"$_cpu_sys/cpufreq/policy0/scaling_max_freq"
do
	[ -r "$_cpu_f" ] || continue
	IFS= read -r _cpu_khz_max < "$_cpu_f" 2>/dev/null || :
	[ -n "$_cpu_khz_max" ] && break
done
case "$_cpu_khz_max" in
	''|*[!0-9]*) _cpu_khz_max="" ;;
esac
[ -z "$_cpu_khz_max" ] && _cpu_khz_max="$_cpu_khz"
[ -n "$_cpu_khz_max" ] && cpu_mhz_max=$(( _cpu_khz_max / 1000 ))

# The core temperature (section 15's System list). The reader returns the value
# and the sensor it came from as one answer, because the name is only meaningful
# beside the reading it belongs to — a board with several sensors would otherwise
# have the page attribute one sensor's number to another's name.
#
# It is empty, not zero, when nothing answers: section 44 again. A board with no
# thermal zone and no hwmon is a board whose page shows a dash.
cpu_temp_mc=""
cpu_temp_source=""
_cpu_temp="$(fcc_cpu_temp_mc)" || _cpu_temp=""
if [ -n "$_cpu_temp" ]; then
	cpu_temp_mc="${_cpu_temp%%|*}"
	cpu_temp_source="${_cpu_temp#*|}"
fi
case "$cpu_temp_mc" in
	''|*[!0-9-]*) cpu_temp_mc="" ;;
esac

# Build the process maps ONCE (no per-agent forks).
#
# pane_dead/pane_dead_status ride along on the map we already fetch, which is
# what lets section 73 report why an agent stopped without a second tmux call
# and without keeping state between polls. Sessions are created with
# remain-on-exit on (see session.sh), so a pane that exited is still listed here
# with its exit status intact.
TMUX_MAP=""
command -v tmux >/dev/null 2>&1 && \
	TMUX_MAP="$(tmux list-panes -a -F '#{session_name} #{pane_pid} #{pane_dead} #{pane_dead_status}' 2>/dev/null)"
COMM_MAP="$(build_comm_map)"

# ---------------------------------------------------------------------------
# Emit JSON
# ---------------------------------------------------------------------------
{
	printf '{\n'
	printf '  "luci_fcc": {"version": %s},\n' "$(fcc_json_str "$(fcc_luci_version)")"
	printf '  "fcc": {"installed": %s, "version": %s},\n' \
		"$fcc_installed" "$(fcc_json_str_or_null "${fcc_version:-}")"
	printf '  "server": {"running": %s, "pid": %s, "version": %s, "uptime": %s, "memory_rss_kb": %s, "port": %s, "bind": %s, "listening": %s, "http_status": %s, "healthy": %s},\n' \
		"$server_running" \
		"$(fcc_json_num_or_null "$server_pid")" \
		"$(fcc_json_str_or_null "${server_version:-}")" \
		"$(fcc_json_num_or_null "$server_uptime")" \
		"$(fcc_json_num_or_null "$server_rss")" \
		"$server_port" \
		"$(fcc_json_str "$(fcc_uci_get main bind 127.0.0.1)")" \
		"$server_listening" \
		"$(fcc_json_num_or_null "${server_http:-}")" \
		"$server_healthy"
	# Session count, from the tmux map already built above — no extra fork. It
	# is what lets the Configuration page say how many agent sessions a server
	# stop would affect (section 12) instead of warning in the abstract.
	if [ -n "$TMUX_MAP" ]; then
		session_count="$(printf '%s\n' "$TMUX_MAP" | grep -c '^fcc-[a-z0-9]\{1,16\}-[0-9]\{3\} ' || true)"
	else
		session_count=0
	fi
	case "$session_count" in ''|*[!0-9]*) session_count=0 ;; esac
	printf '  "sessions": {"active": %s},\n' "$session_count"

	printf '  "system": {"memory_total_kb": %s, "memory_available_kb": %s, "storage_total_bytes": %s, "storage_free_bytes": %s, "storage_used_bytes": %s, "storage_path": %s, "arch": %s, "platform": %s, "platform_model": %s, "cpu_model": %s, "cpu_mhz": %s, "cpu_mhz_max": %s, "cpu_cores": %s, "cpu_temp_mc": %s, "cpu_temp_source": %s},\n' \
		"$(fcc_json_num_or_null "$mem_total")" \
		"$(fcc_json_num_or_null "$mem_avail")" \
		"$st_total_b" "$st_free_b" "$st_used_b" \
		"$(fcc_json_str "$storage_path")" \
		"$(fcc_json_str "$arch")" \
		"$(fcc_json_str_or_null "$platform")" \
		"$(fcc_json_str_or_null "$platform_model")" \
		"$(fcc_json_str_or_null "$cpu_model")" \
		"$(fcc_json_num_or_null "$cpu_mhz")" \
		"$(fcc_json_num_or_null "$cpu_mhz_max")" \
		"$(fcc_json_num_or_null "$cpu_cores")" \
		"$(fcc_json_num_or_null "$cpu_temp_mc")" \
		"$(fcc_json_str_or_null "$cpu_temp_source")"

	printf '  "agents": {'
	_ag_first=1
	while IFS='|' read -r aid aname acmd adef asize aram aprobe; do
		case "$aid" in ''|\#*) continue ;; esac
		[ -n "$aid" ] || continue

		ag_installed=false
		command -v "$acmd" >/dev/null 2>&1 && ag_installed=true

		# The agent's tmux session, if it has one. A session outlives its
		# process (remain-on-exit), so its pane may be dead while the session is
		# still listed: that is exactly the case section 73 is about.
		ag_dead=""; ag_exit=""
		ag_pid=""
		if [ -n "$TMUX_MAP" ]; then
			ag_line="$(printf '%s\n' "$TMUX_MAP" | awk -v p="fcc-$aid-" 'index($1,p)==1{print; exit}')"
			if [ -n "$ag_line" ]; then
				ag_pid="$(printf '%s' "$ag_line" | cut -d' ' -f2)"
				ag_dead="$(printf '%s' "$ag_line" | cut -d' ' -f3)"
				ag_exit="$(printf '%s' "$ag_line" | cut -d' ' -f4)"
			fi
		fi
		# A dead pane keeps its recorded pid, which may since have been reused by
		# an unrelated process; never measure a process we know has gone.
		ag_running=false
		if [ "$ag_dead" != "1" ] && [ -n "$ag_pid" ] && fcc_proc_alive "$ag_pid"; then
			ag_running=true
		fi
		if [ -z "$ag_pid" ] && [ "$ag_dead" != "1" ]; then
			ag_pid="$(printf '%s\n' "$COMM_MAP" | awk -v c="$acmd" '$1==c{print $2; exit}')"
			if [ -n "$ag_pid" ] && fcc_proc_alive "$ag_pid"; then
				ag_running=true
			else
				ag_pid=""
			fi
		fi

		# Section 73: "Stopped" on its own leaves the user with no idea what
		# happened. When the pane is dead and tmux recorded a non-zero status,
		# say so. A zero status is a normal finish, and a tmux too old to report
		# a status tells us nothing — in both cases we report no error rather
		# than invent one.
		ag_error=null
		if [ "$ag_dead" = "1" ]; then
			case "$ag_exit" in
				''|*[!0-9]*) ;;
				0) ;;
				*) ag_error="$(printf '{"code": %s, "message": %s}' \
					"$(fcc_json_str START_FAILED)" \
					"$(fcc_json_str "$acmd exited with status $ag_exit")")" ;;
			esac
			ag_pid=""
		fi

		ag_rss=""; ag_up=""
		if [ -n "$ag_pid" ]; then
			ag_rss="$(fcc_proc_rss_kb "$ag_pid")"
			ag_up="$(fcc_proc_uptime_secs "$ag_pid")"
		fi
		ag_ver="$(fcc_cache_get "agent_$aid" 2>/dev/null || true)"

		# Section 44: "no version because it is not installed" and "no version
		# because the probe failed" must not look identical, and inventing a
		# version is worse than either. The reason travels beside the null so the
		# table can say why rather than only that it does not know. This is the
		# same rule agent.sh applies to its single-agent output; the batched
		# document has to carry it too or the page loses the distinction.
		ag_verr=""
		if [ -z "${ag_ver:-}" ] && [ "$ag_installed" = true ]; then
			if [ -z "$aprobe" ]; then
				ag_verr="no version probe for this agent"
			else
				ag_verr="version command failed"
			fi
		fi

		[ "$_ag_first" -eq 1 ] || printf ','
		_ag_first=0
		printf '\n    %s: {"name": %s, "command": %s, "installed": %s, "running": %s, "pid": %s, "uptime": %s, "memory_rss_kb": %s, "version": %s, "version_error": %s, "default": %s, "approx_size_mb": %s, "min_ram_mb": %s, "error": %s}' \
			"$(fcc_json_str "$aid")" \
			"$(fcc_json_str "$aname")" \
			"$(fcc_json_str "$acmd")" \
			"$ag_installed" "$ag_running" \
			"$(fcc_json_num_or_null "$ag_pid")" \
			"$(fcc_json_num_or_null "$ag_up")" \
			"$(fcc_json_num_or_null "$ag_rss")" \
			"$(fcc_json_str_or_null "${ag_ver:-}")" \
			"$(fcc_json_str_or_null "${ag_verr:-}")" \
			"$(fcc_json_bool "$adef")" \
			"$(fcc_json_num_or_null "$asize")" \
			"$(fcc_json_num_or_null "$aram")" \
			"$ag_error"
	done <<-EOF
	$(fcc_agents_each)
	EOF
	printf '\n  }\n'
	printf '}\n'
}
