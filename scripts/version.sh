#!/bin/sh
# luci-app-fcc — print the package's full version: <VERSION>-r<PKG_RELEASE>.
#
# The version is two files' worth of truth. ./VERSION holds the upstream
# version: the Makefile reads it for PKG_VERSION and the app displays it
# (section 37). The Makefile holds PKG_RELEASE. Together they are what the
# built file is named after — luci-app-fcc_0.1.1-r2_all.ipk — and section 62
# requires the release and its tag to carry that whole string rather than the
# half of it that ./VERSION holds on its own.
#
# This string is the tag, the release name and the package name: one value
# with three uses, composed here so the three cannot disagree. The workflow
# tags and publishes under whatever this prints, so bumping PKG_RELEASE is
# what cuts the next release — there is no tag to type and none to mistype.
#
# Usage:
#   sh scripts/version.sh    -> 0.1.1-r2

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
	'') printf '%s-r%s\n' "$_ve_ver" "$_ve_rel" ;;
	*)  printf 'usage: %s\n' "$0" >&2; exit 2 ;;
esac

