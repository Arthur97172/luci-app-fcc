#!/bin/sh
# luci-app-fcc — run the FCC server with its output in section 39's log file.
#
# procd can send a service's output to syslog (`procd_set_param stdout 1`) but
# it cannot send it to a file, and DESIGN_SPEC.md section 39 puts the server's
# log at <install_path>/logs/fcc-server.log, where the LuCI log viewer reads it.
# So procd supervises this wrapper and the wrapper `exec`s the server: the shell
# is replaced rather than kept as a parent, so procd still tracks the server's
# own pid and signals it directly, and there is no second process to leak.
#
# The cost is that the server's output no longer reaches logread. That is a
# deliberate trade: the file is what the designed feature reads, and a router
# admin debugging a server that will not start is looking at the LuCI page. If
# the log file cannot be opened the wrapper falls back to plain exec, which
# leaves procd's own stdout/stderr capture to carry the output to syslog — so
# the service starts either way and only the destination changes.
#
# Usage: server-run.sh <logfile> <command> [args...]

set -u

_sr_log="$1"
shift
[ $# -gt 0 ] || exit 2

# Keep the log from growing without bound on a device that runs for months.
# Truncating once at start, rather than rotating, is enough: the file exists to
# answer "what went wrong just now", and an append-only log on flash is a wear
# problem long before it is a disk-space problem.
_sr_max="${FCC_SERVER_LOG_MAX_KB:-256}"
case "$_sr_max" in ''|*[!0-9]*) _sr_max=256 ;; esac

if [ -f "$_sr_log" ]; then
	_sr_kb="$(du -k "$_sr_log" 2>/dev/null | cut -f1)"
	case "$_sr_kb" in ''|*[!0-9]*) _sr_kb=0 ;; esac
	if [ "$_sr_kb" -gt "$_sr_max" ]; then
		# Keep the tail, which is the part anyone reads.
		tail -n 200 "$_sr_log" > "$_sr_log.tmp" 2>/dev/null &&
			mv "$_sr_log.tmp" "$_sr_log" 2>/dev/null
		rm -f "$_sr_log.tmp" 2>/dev/null
	fi
fi

# A start marker, so a restart is visible in the log as a restart rather than
# as output that mysteriously begins again.
if touch "$_sr_log" 2>/dev/null; then
	printf '\n=== %s starting ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$_sr_log" 2>/dev/null
	exec "$@" >> "$_sr_log" 2>&1
fi

exec "$@"
