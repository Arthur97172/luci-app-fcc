#!/bin/sh
# luci-app-fcc — print the package's full version: <VERSION>-r<PKG_RELEASE>.
#
# The version is two files' worth of truth. ./VERSION holds the upstream
# version: the Makefile reads it for PKG_VERSION, the app displays it (section
# 37), and the release job checks the tag against it. The Makefile holds
# PKG_RELEASE. Together they are what the built file is named after —
# luci-app-fcc_0.1.1-r1_all.ipk — and section 62 requires the release and its
# tag to carry that whole string rather than the half of it that ./VERSION
# holds on its own.
#
# Composing it in one place is the point. The workflow, the README and the
# tests would otherwise each have their own idea of what the version is, and
# the tag is the one that is expensive to get wrong: a tag is public and
# permanent, and a tag that disagrees with the packages under it cannot be
# taken back.
#
# Usage:
#   sh scripts/version.sh          -> 0.1.1-r1
#   sh scripts/version.sh --tag    -> v0.1.1-r1

set -u

_ve_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
_ve_root=$(CDPATH= cd -- "$_ve_dir/.." && pwd)

_ve_ver=""
if [ -r "$_ve_root/VERSION" ]; then
	# stderr is redirected before the file is opened: the shell prints its own
	# message when a redirection fails, and the redirections apply left to
	# right, so the other order leaves that message on the log.
	_ve_ver=$(tr -d ' \t\r\n' 2>/dev/null < "$_ve_root/VERSION")
fi

# PKG_RELEASE is assigned once, as a plain integer. The pattern matches only
# that, so a value this script cannot use — one written as a $(shell ...) or a
# variable — comes back empty and is reported below rather than printed as if
# it were a release number. Spacing around the assignment is allowed, because
# make allows it and the question here is what the value is, not how it was
# written.
_ve_rel=""
if [ -r "$_ve_root/Makefile" ]; then
	_ve_rel=$(sed -n 's/^PKG_RELEASE[ \t]*:=[ \t]*\([0-9][0-9]*\).*/\1/p' 2>/dev/null \
		< "$_ve_root/Makefile")
fi

if [ -z "$_ve_ver" ] || [ -z "$_ve_rel" ]; then
	printf 'version.sh: cannot read the package version from %s and %s\n' \
		"$_ve_root/VERSION" "$_ve_root/Makefile" >&2
	exit 1
fi

case "${1:-}" in
	'')    printf '%s-r%s\n' "$_ve_ver" "$_ve_rel" ;;
	--tag) printf 'v%s-r%s\n' "$_ve_ver" "$_ve_rel" ;;
	*)     printf 'usage: %s [--tag]\n' "$0" >&2; exit 2 ;;
esac
