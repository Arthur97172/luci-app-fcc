#!/bin/sh
# luci-app-fcc — packaging checks.
#
# The Makefile carries an explicit Package/... definition (DESIGN_SPEC.md
# sections 36 and 57 require it rather than delegating to luci.mk), which means
# the install manifest is hand-written and can drift from the source tree. These
# checks are what stops that: every path the manifest names must exist, and
# every file in the tree must be named by the manifest.

TESTS_NAME="packaging"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

MAKEFILE="$ROOT/Makefile"
WORKFLOW="$ROOT/.github/workflows/build.yml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The install block of the main package, with comment lines removed.
install_block() {
	sed -n '/^define Package\/luci-app-fcc\/install$/,/^endef$/p' "$MAKEFILE" \
		| grep -v '^[[:space:]]*#'
}

# The body of one `define <name> ... endef` block, comments excluded.
# install_block() strips comments for the same reason: the reasoning lives in
# the comment above a block, and a check that counted the comment as part of
# the block would still pass after the block itself had been emptied out.
makefile_define() { # makefile_define <name>
	awk -v name="$1" '
		$0 == "define " name { inside = 1; next }
		inside && $0 == "endef" { exit }
		inside && $0 !~ /^[[:space:]]*#/ { print }
	' "$MAKEFILE"
}

# Source paths the manifest installs from, as repo-relative paths.
manifest_sources() {
	install_block | grep -o '\./[^ 	]*' | sed 's#^\./##' | LC_ALL=C sort -u
}

# Every file in the tree that the package is expected to ship.
tree_files() {
	find "$ROOT/root" "$ROOT/htdocs" "$ROOT/luasrc" -type f 2>/dev/null \
		| sed "s#^$ROOT/##" | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# The manifest and the tree must describe the same package
# ---------------------------------------------------------------------------

test_manifest_sources_exist() {
	_ts_bad=""
	for _ts_f in $(manifest_sources); do
		[ -e "$ROOT/$_ts_f" ] || _ts_bad="$_ts_bad $_ts_f"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every manifest source exists"
}

test_tree_files_are_all_installed() {
	# A file added to the tree but not to the manifest would build and install
	# cleanly while silently doing nothing.
	_ts_bad=""
	# Space-separated, so the case patterns below can match whole path names.
	_ts_src="$(manifest_sources | tr '\n' ' ')"
	for _ts_f in $(tree_files); do
		case " $_ts_src " in
			*" $_ts_f "*) : ;;
			*) _ts_bad="$_ts_bad $_ts_f" ;;
		esac
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every shipped file is in the manifest"
}

test_manifest_has_no_duplicates() {
	_ts_n="$(install_block | grep -o '\./[^ 	]*' | sed 's#^\./##' | wc -l | tr -d ' ')"
	_ts_u="$(manifest_sources | wc -l | tr -d ' ')"
	assert_eq "$_ts_u" "$_ts_n" "no source is installed twice"
}

test_lua_install_paths_match_the_module_names() {
	# luasrc/ maps onto /usr/lib/lua/luci/, so luasrc/fcc/util.lua must land at
	# /usr/lib/lua/luci/fcc/util.lua. Any other destination makes require()
	# fail at runtime, which no build-time check would catch.
	_ts_bad=""
	for _ts_f in "$ROOT"/luasrc/fcc/*.lua; do
		_ts_rel="luasrc/fcc/$(basename "$_ts_f")"
		grep -q "\./$_ts_rel \$(1)/usr/lib/lua/luci/fcc/$(basename "$_ts_f")" "$MAKEFILE" \
			|| _ts_bad="$_ts_bad $(_ts_rel)"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "luasrc/fcc/*.lua installs to luci/fcc/"
}

# ---------------------------------------------------------------------------
# Package metadata
# ---------------------------------------------------------------------------

test_the_package_is_declared() {
	# Two packages, and exactly two: the application, which is English only, and
	# the translation. Section 52 asks for two languages; where they are built is
	# a packaging decision, and it is this one.
	assert_contains "$(cat "$MAKEFILE")" 'define Package/luci-app-fcc' "the package is declared"
	assert_contains "$(cat "$MAKEFILE")" '$(eval $(call BuildPackage,luci-app-fcc))' "the package is built"
	assert_eq "2" "$(grep -c '^\$(eval \$(call BuildPackage' "$MAKEFILE")" \
		"exactly two packages are built, and no more"
}

test_the_package_is_architecture_independent() {
	# This package is a pure control layer: Lua, JS and ash. Anything it ships
	# is interpreted, so PKGARCH:=all is what lets one .ipk serve every target.
	# Both packages, and only those two: an architecture-specific third one would
	# be a package this project does not mean to ship.
	_ts_n="$(grep -c '^[[:space:]]*PKGARCH:=all' "$MAKEFILE")"
	assert_eq "2" "$_ts_n" "both packages declare PKGARCH:=all"
}

test_does_not_use_luci_mk() {
	# DESIGN_SPEC sections 36 and 57: the Package definition is explicit, so the
	# build does not inherit buildroot-version-specific luci.mk behaviour.
	_ts_hits="$(grep -n 'luci\.mk' "$MAKEFILE" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v 'luci\.mk.s implicit')"
	assert_eq "" "$_ts_hits" "luci.mk is not included"
}

test_uses_the_shared_version_file() {
	# One VERSION file feeds the package version, the in-app version display and
	# the update check. A second copy would drift.
	assert_contains "$(cat "$MAKEFILE")" 'PKG_VERSION:=$(strip $(shell cat $(CURDIR)/VERSION' \
		"PKG_VERSION is read from ./VERSION"
	assert_contains "$(cat "$MAKEFILE")" '$(INSTALL_DATA) ./VERSION $(1)/usr/share/luci-app-fcc/VERSION' \
		"VERSION is installed for the runtime to read (section 37)"
	# The fallback is what an out-of-tree build reports when VERSION is missing,
	# and scripts/package-check.sh compares it with the real file. Bumping
	# VERSION without touching it makes CI fail on a tree that is otherwise
	# green, so check it here too.
	_ts_ver="$(tr -d ' \t\r\n' < "$ROOT/VERSION")"
	assert_contains "$(cat "$MAKEFILE")" "echo $_ts_ver)" \
		"the Makefile's VERSION fallback is the current version"
}

test_version_file_is_wellformed() {
	assert_file "$ROOT/VERSION"
	_ts_v="$(tr -d ' \t\r\n' < "$ROOT/VERSION")"
	case "$_ts_v" in
		[0-9]*.[0-9]*.[0-9]*) pass ;;
		*) fail "VERSION is not a dotted version: [$_ts_v]" ;;
	esac
	assert_eq "$_ts_v" "$(cat "$ROOT/VERSION")" "VERSION has no stray whitespace"
}

test_conffile_is_declared() {
	# /etc/config/fcc must survive an upgrade, so it has to be a conffile.
	assert_contains "$(cat "$MAKEFILE")" '/etc/config/fcc' "the UCI config is a conffile"
	assert_contains "$(cat "$MAKEFILE")" '$(INSTALL_CONF) ./root/etc/config/fcc' \
		"the UCI config is installed with INSTALL_CONF"
}

test_postinst_leaves_uci_defaults_to_the_wrapper() {
	_ts_pi="$(makefile_define Package/luci-app-fcc/postinst)"
	assert_ne "" "$_ts_pi" "the package declares a postinst"

	# Neither package manager runs this text on its own: both wrap it, and both
	# wrappers call default_postinst() from /lib/functions.sh *before* the block.
	# default_postinst() runs every /etc/uci-defaults/ file the package ships and
	# deletes each one, so a `. /etc/uci-defaults/99-fcc` here runs against a file
	# that is already gone:
	#
	#   /proc/self/fd/7: .: line 10: can't open /etc/uci-defaults/99-fcc: no such file
	#
	# It is noise on an install that worked and the last line on one that did
	# not, which is why the failure is easy to read as the cause. The wrapper
	# also removes /tmp/luci-indexcache.* itself, so doing it here is at best
	# redundant and at worst races the wrapper.
	assert_not_contains "$_ts_pi" 'uci-defaults' \
		"the postinst does not source /etc/uci-defaults"
	assert_not_contains "$_ts_pi" 'luci-indexcache' \
		"the postinst leaves the index cache to default_postinst"

	# The fix is to stop sourcing it, not to stop shipping it: the script is
	# still the thing that applies the defaults on a fresh install.
	assert_file "$ROOT/root/etc/uci-defaults/99-fcc"
	assert_contains "$(cat "$MAKEFILE")" '$(INSTALL_BIN) ./root/etc/uci-defaults/99-fcc' \
		"and the script is still shipped and installed"
}

# ---------------------------------------------------------------------------
# Section 87: the package must not drag a language runtime onto the router
# ---------------------------------------------------------------------------

test_no_runtime_dependencies() {
	_ts_depends="$(sed -n '/^define Package\/luci-app-fcc$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	assert_ne "" "$_ts_depends" "the app package declares DEPENDS"
	for _ts_forbidden in node nodejs npm python python3 python3-light uv ruby php; do
		case "$_ts_depends" in
			*"$_ts_forbidden"*)
				fail "DEPENDS must not pull in $_ts_forbidden: [$_ts_depends]" ;;
			*) pass ;;
		esac
	done
}

test_declared_dependencies_are_used() {
	# Every dependency should be a thing the code actually calls. These five are
	# the ones the backend shells out to.
	_ts_depends="$(sed -n '/^define Package\/luci-app-fcc$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	for _ts_d in luci-base luci-compat curl ca-bundle tmux; do
		case "$_ts_depends" in
			*"+$_ts_d"*) pass ;;
			*) fail "DEPENDS is missing +$_ts_d: [$_ts_depends]" ;;
		esac
	done
}

test_readmes_are_paired_and_cross_linked() {
	# README.md is the Chinese default and README.en.md the English one. Each
	# links to the other at the top, so whoever lands on either can switch. A
	# translation that silently drifts away is worse than none.
	assert_contains "$(cat "$ROOT/README.md")" "[English](README.en.md)" \
		"the Chinese README links to the English one"
	assert_contains "$(cat "$ROOT/README.en.md")" "[简体中文](README.md)" \
		"the English README links back to the Chinese one"
}

test_tar_is_not_a_dependency() {
	# On 25.12 upstream's tar carries DEPENDS:=+PACKAGE_TAR_XZ:xz, which the
	# metadata generator copies onto every dependent as
	#   depends on !(PACKAGE_TAR_XZ) || PACKAGE_xz-utils
	# TAR_XZ defaults to y and xz-utils to n, so the gate is false, kconfig drops
	# the symbol, and the build silently produces no package at all. Nothing here
	# calls tar — the installer is fetched as a shell script and run, backups are
	# directory renames — and busybox supplies /bin/tar anyway.
	_ts_depends="$(sed -n '/^define Package\/luci-app-fcc$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	case "$_ts_depends" in
		*"+tar"*) fail "+tar makes the package unselectable on 25.12: [$_ts_depends]" ;;
		*) pass ;;
	esac
}

test_tmux_dependency_matches_the_session_backend() {
	# The Web Console is tmux-backed. If tmux ever left DEPENDS the console
	# would break only on a router that did not happen to have it.
	assert_contains "$(cat "$ROOT/root/etc/config/fcc")" "option session_backend 'tmux'" \
		"the configured session backend is tmux"
	assert_contains "$(cat "$ROOT/root/usr/libexec/fcc/session.sh")" "tmux is required for the Web Console" \
		"session.sh states the tmux requirement"
}

# ---------------------------------------------------------------------------
# The translation, which ships in a package of its own
# ---------------------------------------------------------------------------

test_i18n_sources_are_wired_up() {
	assert_file "$ROOT/po/zh_Hans/fcc.po"
	assert_file "$ROOT/po/templates/fcc.pot"
	assert_contains "$(cat "$MAKEFILE")" 'po2lmo ./po/zh_Hans/fcc.po' "the .po is compiled with po2lmo"
	assert_contains "$(cat "$MAKEFILE")" 'fcc.zh-cn.lmo' "the .lmo uses LuCI's zh-cn language code"
	assert_contains "$(cat "$MAKEFILE")" 'PKG_BUILD_DEPENDS:=luci-base/host' \
		"po2lmo is available as a host tool"
}

test_the_catalogue_installs_into_the_translation_package() {
	# LuCI's template parser loads <name>.<lang>.lmo out of
	# /usr/lib/lua/luci/i18n by itself when the interface language is zh-cn.
	# Installing it anywhere else means the translation never loads — and
	# English still works, so nothing looks broken.
	_ts_inst="$(makefile_define 'Package/luci-i18n-fcc-zh-cn/install')"
	assert_contains "$_ts_inst" \
		'po2lmo ./po/zh_Hans/fcc.po $(1)/usr/lib/lua/luci/i18n/fcc.zh-cn.lmo' \
		"the catalogue is compiled into the translation package"
}

test_the_app_package_carries_no_catalogue() {
	# The separation is the point, and it is one line to undo by accident: a
	# po2lmo call left in the app package's install block would put the
	# catalogue back in the .ipk while the new package still built, and every
	# check that only looked for the new package would stay green.
	assert_not_contains "$(install_block)" 'po2lmo' \
		"the app package compiles no catalogue"
	assert_not_contains "$(install_block)" 'luci/i18n' \
		"the app package installs nothing under luci/i18n"
}

test_the_translation_package_is_defined_and_built() {
	assert_contains "$(cat "$MAKEFILE")" 'define Package/luci-i18n-fcc-zh-cn' \
		"the Makefile defines the translation package"
	assert_contains "$(cat "$MAKEFILE")" 'BuildPackage,luci-i18n-fcc-zh-cn' \
		"the Makefile builds the translation package"
	# PKGARCH:=all, like the app: the .lmo is data and must be installable on
	# every architecture the app is.
	assert_contains "$(makefile_define 'Package/luci-i18n-fcc-zh-cn')" 'PKGARCH:=all' \
		"the translation package is architecture-independent"
}

test_the_translation_package_does_not_depend_on_the_app() {
	# Not a style rule. A dependency on luci-app-fcc would be circular the
	# moment anything selected the translation by default, and it is not needed:
	# the .lmo is a data file LuCI loads by name, so it is harmless to install
	# on its own. What it must depend on is luci-base, which is where the loader
	# that reads it lives.
	# The DEPENDS line itself, not the whole block: the block's TITLE and URL
	# both name luci-app-fcc, and a check over the block would fail on those.
	_ts_dep="$(printf '%s\n' "$(makefile_define 'Package/luci-i18n-fcc-zh-cn')" \
		| grep '^[[:space:]]*DEPENDS:=')"
	assert_eq "  DEPENDS:=+luci-base" "$_ts_dep" "it depends on luci-base and nothing else"
}

# ---------------------------------------------------------------------------
# The Configuration page has no agent table
#
# Section 3.6.5 asked for a picker, and for a while the page had one: a table
# whose first column was a tick box, plus a recommended set and a per-row
# Install/Remove. It is gone (section 104.25), and what replaced it is not a
# picker: an install takes the whole registry, and the page carries two buttons
# — Install and Reinstall — that act on every agent.
#
# The one agent dropdown that now sits before Install (section 79's rollback is
# why it exists) is not that table coming back, and the difference is the point
# of this test: one value, no tick boxes, nothing rendered from a second source.
# What it does is pinned by test_the_config_page_can_install_one_agent.
#
# There is no DOM harness here, so the invariant is pinned against the markup
# and the script: the table and everything that fed it must be absent, and the
# two buttons must be present.
# ---------------------------------------------------------------------------

test_the_config_page_has_no_agent_table() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"

	assert_not_contains "$(cat "$_ts_view")" 'fcc-agent-table' "the view has no agent table"
	assert_not_contains "$(cat "$_ts_js")" 'fcc-agent-table' "and no script renders one"

	# The machinery that existed only to serve the table. Each of these is a
	# name the table needed and nothing else does; any one of them coming back
	# means the picker came back with it.
	for _ts_dead in renderAgents agentSelection agentRegistry agentRecommended \
	                selectedAgentIds applyRecommended loadRecommended \
	                refreshVersions requirementText fcc-agent-status \
	                fcc-install-agents-defaults fcc-agent-refresh; do
		assert_not_contains "$(cat "$_ts_js")" "$_ts_dead" "the table's $_ts_dead is gone"
	done

	# One button, not two. Install covers both jobs: with a runtime already
	# present and the dropdown on "All agents" it offers the remove-then-install
	# the old Reinstall button performed, behind a confirmation; a chosen agent
	# is still added without removing anything, which is what keeps the
	# remaining agents reachable one at a time. The tick-box machinery stays
	# dead either way — that is what this test is about.
	assert_contains "$(cat "$_ts_view")" 'id="fcc-runtime-install"' "the view has an Install button"
	assert_not_contains "$(cat "$_ts_view")" 'id="fcc-runtime-reinstall"' \
		"and no separate Reinstall button"
	assert_contains "$(cat "$_ts_js")" "runJobAction('reinstall_runtime', {}," \
		"the merged button still reaches the remove-then-install verb"
}

# ---------------------------------------------------------------------------
# One click installs every agent
#
# Section 104.25: the picker is gone, so an install is no longer a selection.
# What has to hold across the three layers is that the button asks for the whole
# registry *by flag* — the registry stays the only place the set is written
# down, so an eleventh agent is installed by the same click that installs ten,
# with no list to update. The runtime tests check what the flag resolves to; this
# checks that the click still reaches it.
#
# "With nothing chosen" is now part of the claim rather than the whole of it.
# The agent dropdown added beside the button narrows an install to one agent
# (test_the_config_page_can_install_one_agent below), and the default — the
# dropdown's empty value — is still the whole registry, by flag, exactly as
# before. What this pins is that the default did not change and that the set is
# still never listed.
# ---------------------------------------------------------------------------

test_the_config_page_installs_every_agent() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_ctrl="$ROOT/luasrc/controller/fcc.lua"

	# One button starts both jobs, and it is the only way the page starts an
	# install — the dropdown beside it chooses between one agent and all of
	# them, and the tick boxes that used to choose a subset are asserted gone
	# by test_the_config_page_has_no_agent_table.
	assert_contains "$(cat "$_ts_view")" 'id="fcc-runtime-install"' \
		"the Configuration page has an Install button"
	assert_not_contains "$(cat "$_ts_view")" 'id="fcc-runtime-reinstall"' \
		"with no separate Reinstall button beside it"

	# Install's payload depends on the dropdown: the one id it holds goes to the
	# install action, and the empty value (the whole registry) reads the status
	# first so that a runtime already present gets the remove-then-install verb.
	assert_contains "$(cat "$_ts_js")" "'install_runtime', { agent: agent }" \
		"a chosen agent is installed as that one id"
	assert_contains "$(cat "$_ts_js")" "d.fcc && d.fcc.installed" \
		"the whole-registry click checks whether a runtime is already installed"
	assert_contains "$(cat "$_ts_js")" "runJobAction('reinstall_runtime', {}," \
		"and an installed runtime gets the reinstall action"

	# The action is the flag, spelled once, and it is a flag rather than a list
	# of ids for the reason above: a list here would be a second place the agent
	# set lives, and the two would drift the first time the registry changed.
	# The default argv is that flag, and it is built before the dropdown is read,
	# so the whole-registry install is the path a click takes when the dropdown
	# says nothing — not a branch that has to keep working.
	assert_contains "$(cat "$_ts_ctrl")" '"install", "runtime", "--all-agents"' \
		"the install action asks for the whole registry by flag"
	assert_contains "$(cat "$_ts_ctrl")" 'local argv = { "install", "runtime", "--all-agents" }' \
		"and that is the argv an install starts from"

	# Reinstall is the remove-then-install verb, which install.sh implements.
	# Sending the install verb with a flag instead would reconcile rather than
	# reinstall, and the difference stays invisible on the page until an agent
	# that is already present is the one that is broken.
	assert_contains "$(cat "$_ts_ctrl")" '"install", "reinstall"' \
		"the reinstall action asks for the verb that removes first"
}

# ---------------------------------------------------------------------------
# One Install button, two jobs
#
# The toolbar used to carry Install and Reinstall side by side. They are one
# control now, and the difference between the jobs did not disappear with the
# second button: a chosen agent is added to the runtime that is there, while
# "All agents" on a device that already has a runtime removes that runtime and
# installs everything again. The removal is what makes a damaged agent
# reinstallable at all (upstream reconciles rather than reinstalls), so the
# confirmation in front of it is not decoration.
# ---------------------------------------------------------------------------

test_one_install_button_does_both_jobs() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_ctrl="$ROOT/luasrc/controller/fcc.lua"
	_ts_install="$ROOT/root/usr/libexec/fcc/install.sh"

	assert_contains "$(cat "$_ts_view")" 'id="fcc-runtime-install"' \
		"the runtime toolbar has one Install button"
	assert_not_contains "$(cat "$_ts_view")" 'id="fcc-runtime-reinstall"' \
		"and no Reinstall button beside it"

	# A chosen agent takes the plain install path. It must not reach the
	# remove-then-install verb: removing the runtime to add one agent is the
	# opposite of what the dropdown is for.
	assert_contains "$(cat "$_ts_js")" 'if (agent) {' \
		"Install branches on the dropdown value"
	assert_contains "$(cat "$_ts_js")" "'install_runtime', { agent: agent }" \
		"a chosen agent is installed on its own"
	assert_not_contains "$(cat "$_ts_js")" "'reinstall_runtime', { agent:" \
		"and never through the reinstall action"

	# The whole-registry path reads the current status first, then either
	# installs or — when a runtime is already there — asks before removing it.
	assert_contains "$(cat "$_ts_js")" "FCC.api('status'" \
		"the whole-registry click reads the current status"
	assert_contains "$(cat "$_ts_js")" 'if (!(d.fcc && d.fcc.installed)) {' \
		"it installs when no runtime is present"
	assert_contains "$(cat "$_ts_js")" "window.confirm(FCC._('Remove the FCC runtime" \
		"and asks before removing an installed one"
	assert_contains "$(cat "$_ts_js")" "runJobAction('reinstall_runtime', {}, 'install', 'fcc-runtime.log')" \
		"before running the remove-then-install job"

	# Both verbs still exist below the page: the controller routes the reinstall
	# action and install.sh implements it. The merge is a UI change, not a
	# backend one.
	assert_contains "$(cat "$_ts_ctrl")" 'act_reinstall_runtime' \
		"the controller still implements the reinstall action"
	assert_contains "$(cat "$_ts_install")" 'cmd_reinstall()' \
		"and install.sh still implements remove-then-install"
}

# ---------------------------------------------------------------------------
# The destructive button's name
#
# "Uninstall and remove all data" said what it does but read as a paragraph in
# a toolbar. "Uninstall completely" is a button name; the dialog still spells
# out what is deleted, which is the only place that can change the user's mind.
# ---------------------------------------------------------------------------

test_the_purge_button_is_named_plainly() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"

	assert_contains "$(cat "$_ts_view")" '<%:Uninstall completely%>' \
		"the destructive button is called Uninstall completely"
	assert_not_contains "$(cat "$_ts_view")" 'Uninstall and remove all data' \
		"and the old label is gone"
	assert_contains "$(cat "$_ts_js")" \
		'This deletes the runtime, the agents, your configuration and every backup.' \
		"while its confirmation still names everything that is lost"
}

# ---------------------------------------------------------------------------
# Backup path
#
# The rollback copy an install makes used to be written under <install_path>/
# backup, which put it on the same flash the runtime was already tight in. It
# now has a setting of its own — beside the install path, because that is the
# other place the install writes — defaulting to /tmp/fcc, which on OpenWrt is
# tmpfs. The path is validated twice, as install_path is: once in the UI so bad
# input never reaches UCI, once in the shell that actually writes there.
# ---------------------------------------------------------------------------

test_the_config_page_sets_the_backup_path() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_ctrl="$ROOT/luasrc/controller/fcc.lua"
	_ts_fc="$ROOT/root/etc/config/fcc"
	_ts_seed="$ROOT/root/etc/uci-defaults/99-fcc"

	assert_contains "$(cat "$_ts_view")" 'id="fcc-backup-path"' \
		"the Configuration page has a Backup path field"
	assert_contains "$(cat "$_ts_view")" '<%:Backup path%>' \
		"and it is labelled by a translatable string"

	# Above Bind address, as the settings area is ordered: the two paths sit
	# together, before the server's own address and port.
	_ts_ip="$(grep -n 'id="fcc-install-path"' "$_ts_view" | head -1 | cut -d: -f1)"
	_ts_bp="$(grep -n 'id="fcc-backup-path"' "$_ts_view" | head -1 | cut -d: -f1)"
	_ts_bind="$(grep -n 'id="fcc-bind"' "$_ts_view" | head -1 | cut -d: -f1)"
	if [ -n "$_ts_ip" ] && [ -n "$_ts_bp" ] && [ -n "$_ts_bind" ] \
		&& [ "$_ts_ip" -lt "$_ts_bp" ] && [ "$_ts_bp" -lt "$_ts_bind" ]; then
		pass
	else
		fail "Backup path does not sit between Install path and Bind address"
	fi

	assert_contains "$(cat "$_ts_js")" "FCC.\$('#fcc-backup-path').value = c.backup_path" \
		"the page loads the saved backup path"
	assert_contains "$(cat "$_ts_js")" "backup_path: FCC.\$('#fcc-backup-path').value" \
		"and saves it with the rest of the settings"

	assert_contains "$(cat "$_ts_ctrl")" "paths.backup_dir()" \
		"the controller reports the effective backup path"
	assert_contains "$(cat "$_ts_ctrl")" "util.valid_backup_path" \
		"and validates it before storing it"

	assert_contains "$(cat "$_ts_fc")" "option backup_path '/tmp/fcc'" \
		"the shipped configuration defaults the backup path to /tmp/fcc"
	assert_contains "$(cat "$_ts_seed")" "option backup_path '/tmp/fcc'" \
		"and the first-install seed writes the same default"
}

# ---------------------------------------------------------------------------
# Web Console toolbar
#
# "Clean up finished sessions" is gone: a session that has ended is already
# gone from the tab strip, and the action it called only swept tmux state the
# page no longer shows. "End all sessions" moved behind "Open in browser" —
# the destructive one last, out of the way of the two buttons pressed often.
# ---------------------------------------------------------------------------

test_the_console_toolbar_is_ordered_and_has_no_cleanup_button() {
	_ts_view="$ROOT/luasrc/view/fcc/console.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-terminal.js"

	assert_not_contains "$(cat "$_ts_view")" 'fcc-term-cleanup' \
		"the Web Console has no Clean up finished sessions button"
	assert_not_contains "$(cat "$_ts_view")" 'Clean up finished sessions' \
		"and nothing left of its label"
	assert_not_contains "$(cat "$_ts_js")" 'fcc-term-cleanup' \
		"the script has no handler wired for it"

	_ts_new="$(grep -n 'id="fcc-term-create"' "$_ts_view" | head -1 | cut -d: -f1)"
	_ts_pop="$(grep -n 'id="fcc-term-popout"' "$_ts_view" | head -1 | cut -d: -f1)"
	_ts_end="$(grep -n 'id="fcc-term-close-all"' "$_ts_view" | head -1 | cut -d: -f1)"
	if [ -n "$_ts_new" ] && [ -n "$_ts_pop" ] && [ -n "$_ts_end" ] \
		&& [ "$_ts_new" -lt "$_ts_pop" ] && [ "$_ts_pop" -lt "$_ts_end" ]; then
		pass
	else
		fail "the toolbar is not New session, Open in browser, End all sessions"
	fi
}

test_the_console_keeps_no_harness_address_row() {
	# DeepSeek Harness is the one agent whose interface is a browser, and its
	# pane prints the address (with the launch token) itself. The page used to
	# repeat that address in a row with a copy button; the pane is the only
	# place it belongs, so nothing of that row may come back.
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-terminal.js"
	assert_not_contains "$(cat "$_ts_js")" 'showDshUrl' \
		"the console paints no harness address row"
	assert_not_contains "$(cat "$_ts_js")" 'Copy the harness address' \
		"and offers no button to copy it"
	assert_not_contains "$(cat "$_ts_js")" 'DeepSeek Harness address:' \
		"and no label that introduced it"
	assert_contains "$(cat "$_ts_js")" 'waitForDshUrl(' \
		"while the window still finds the address the pane printed"
}

test_the_console_follows_the_configured_side() {
	# The Web Console has no switch of its own. It follows the Configuration
	# tab's [This router] [LAN] setting, and this check pins the three pieces
	# that make that visible: the label the dropdown carries, the per-tab badge
	# that says where an *existing* session runs, and the backend routes the
	# page reads the setting from.
	_view="$ROOT/luasrc/view/fcc/console.htm"
	_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-terminal.js"
	_css="$ROOT/htdocs/luci-static/resources/fcc/fcc.css"
	_ctrl="$ROOT/luasrc/controller/fcc.lua"
	_sess="$ROOT/root/usr/libexec/fcc/session.sh"

	assert_contains "$(cat "$_view")" 'id="fcc-agent-label"' \
		"the agent dropdown has a label the script can rewrite"
	assert_contains "$(cat "$_view")" '<%:Agent [This router]%>' \
		"whose static text is the default, this router"
	assert_not_contains "$(cat "$_view")" 'running a coding agent on this router' \
		"the page description no longer claims the agent runs here"
	assert_contains "$(cat "$_view")" '<%:On the LAN side the agent itself runs on the other machine, over SSH.%>' \
		"and it says where the agent runs in LAN mode"

	assert_contains "$(cat "$_js")" "FCC.api('console'" \
		"the page asks for the console state rather than only an agent list"
	assert_contains "$(cat "$_js")" "FCC.api('console_target'" \
		"and polls the target, so a switch made elsewhere is noticed"
	assert_contains "$(cat "$_js")" "FCC._('Agent [LAN]')" \
		"the label has a LAN form"
	assert_contains "$(cat "$_js")" "FCC._('Agent [This router]')" \
		"and a local one"
	assert_contains "$(cat "$_js")" "s.target === 'lan'" \
		"each tab is badged by the session's own target"
	assert_contains "$(cat "$_css")" '.fcc-term-tab .fcc-badge' \
		"the tab badge has a size of its own"

	assert_contains "$(cat "$_ctrl")" 'console = "act_console"' \
		"the console route is registered"
	assert_contains "$(cat "$_ctrl")" 'console_target = "act_console_target"' \
		"and so is the target poll"

	# One place decides. The pane is built from UCI, not from anything the
	# caller sent, so a console page left open on the other side cannot create
	# a session on the wrong machine.
	_create="$(sed -n '/^cmd_create()/,/^}/p' "$_sess")"
	assert_contains "$_create" 'fcc_uci_get main control_target local' \
		"the create reads the target from UCI"
	assert_contains "$_create" 'target_file "$_cr_name"' \
		"the session records where it runs"
}

test_the_console_offers_the_integrations_page_when_antigravity_cannot_start() {
	# Antigravity CLI is the one agent that will not run until FCC has connected
	# it on its Integrations page, and that page is FCC's own admin UI behind
	# this package's reverse proxy. The console used to show only
	# "Agent exited unexpectedly" — and upstream's own sentence points at
	# 127.0.0.1:8082, which no other machine can open. The refusal now carries a
	# reason code, and the page offers the link beside it.
	_view="$ROOT/luasrc/view/fcc/console.htm"
	_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-terminal.js"
	_sess="$ROOT/root/usr/libexec/fcc/session.sh"
	_common="$ROOT/root/usr/libexec/fcc/common.sh"
	_po="$ROOT/po/zh_Hans/fcc.po"

	assert_contains "$(cat "$_view")" 'var FCC_ADMIN' \
		"the console page publishes the admin proxy's base"
	assert_contains "$(cat "$_view")" 'admin/services/fcc/adminproxy' \
		"which is this package's proxy rather than the FCC port"

	assert_contains "$(cat "$_common")" 'fcc_agy_connected()' \
		"common.sh owns the connection question"
	assert_contains "$(sed -n '/^cmd_create()/,/^}/p' "$_sess")" 'fcc_agy_connected' \
		"the create refuses on it before a pane is made"
	assert_contains "$(cat "$_sess")" 'agy-not-connected' \
		"with a reason code rather than a sentence"

	assert_contains "$(cat "$_js")" "case 'agy-not-connected':" \
		"the console translates that reason"
	assert_contains "$(cat "$_js")" "base + '/admin/integrations'" \
		"and links to the Integrations page through the proxy"
	assert_contains "$(cat "$_js")" 'Antigravity CLI starts only after it has been connected' \
		"a crashed Antigravity session says what it needs"

	assert_contains "$(cat "$_po")" 'Antigravity CLI has not been connected to FCC yet.' \
		"and the sentence has a translation"
}

test_the_install_log_names_what_upstream_did_about_each_agent() {
	# The report: an install of Antigravity CLI alone logged nine "-> n" prompt
	# answers and never named the agent that was asked for. Upstream asks only
	# about agents it cannot find, so the requested set is logged by display
	# name and the installer's own verdict is quoted for each of them.
	_install="$ROOT/root/usr/libexec/fcc/install.sh"
	_rt="$ROOT/tests/test_runtime.sh"

	assert_contains "$(cat "$_install")" 'installer: requested agents:' \
		"the log names the agents the run was asked for"
	assert_contains "$(sed -n '/^cmd_runtime()/,/^}/p' "$_install")" 'installer_agent_verdict' \
		"and quotes what upstream did about each of them"
	assert_contains "$(sed -n '/^installer_agent_verdict()/,/^}/p' "$_install")" \
		'Ensuring " name " is installed' \
		"the verdict is anchored to the agent's own step"
	assert_contains "$(cat "$_rt")" 'test_installer_agent_verdict_reads_what_upstream_did_about_an_installed_agent' \
		"and it is covered by a behaviour test"
}

test_console_output_wait_ticks_faster_than_a_second() {
	# The browser repaints what the pane wrote only when the long-poll
	# returns, so the wait's tick is the console's echo latency. It used to be
	# a whole second — a typed character showed up to a second late — and is
	# now a fifth of a second where coreutils' timeout provides it. A router
	# without that keeps the one-second tick rather than spinning.
	_sess="$ROOT/root/usr/libexec/fcc/session.sh"
	_out="$(sed -n '/^cmd_output()/,/^}/p' "$_sess")"

	assert_contains "$_out" 'timeout 0.2 true' \
		"the wait probes for a fractional timer"
	assert_contains "$_out" '_ou_tick=10' \
		"and falls back to the one-second tick without one"
	assert_contains "$_out" 'timeout 0.2 sleep 1' \
		"the fast tick is a fifth of a second"
	assert_contains "$_out" 'sleep 1' \
		"the fallback tick is still a whole second"
	assert_contains "$_out" '_ou_waited % 10' \
		"tmux is asked about the pane once a second, not on every fast tick"
	assert_not_contains "$_out" "tr -d ' '" \
		"the size check no longer forks tr"
}

test_the_runtime_help_is_one_warning() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_css="$ROOT/htdocs/luci-static/resources/fcc/fcc.css"

	# The five notes that explained each toolbar action are gone — the buttons
	# and their dialogs say that much. What is left is the one thing they do
	# not: the whole registry is the default, and it costs GBs and minutes.
	for _ts_old in \
		'Install downloads the FCC runtime' \
		'Choose a single agent to install' \
		'Reinstall removes the runtime' \
		'Uninstall removes the runtime' \
		'An install deletes the rollback copy'; do
		assert_not_contains "$(cat "$_ts_view")" "$_ts_old" \
			"the runtime help no longer says '$_ts_old'"
	done

	assert_contains "$(cat "$_ts_view")" 'class="fcc-warn"' \
		"the replacement is a warning block"
	assert_contains "$(cat "$_ts_view")" 'avoid choosing “All agents” when installing' \
		"it warns against choosing the whole registry"
	assert_contains "$(cat "$_ts_view")" '8 GB' "and names the storage cost"

	_ts_css_text="$(cat "$_ts_css")"
	assert_contains "$_ts_css_text" 'var(--fcc-warn-color, #b45309)' "the warning text is deep amber"
	assert_contains "$_ts_css_text" 'var(--fcc-warn-bg, #fffbeb)' "on pale yellow"
	assert_contains "$_ts_css_text" 'var(--fcc-warn-border, #fde68a)' "with a pale yellow border"

	# Dark themes. The light shades are unreadable there, so the same amber
	# ramp is used in its dark-half values. The selectors follow each theme's
	# own dark-mode signal, and the media query is limited to Argon's default
	# mode: Material has no dark mode, and a bare prefers-color-scheme rule
	# would paint a dark block on its light page.
	assert_contains "$_ts_css_text" ':root[data-darkmode="true"]' \
		"the dark palette follows Bootstrap's data-darkmode"
	assert_contains "$_ts_css_text" ':root[data-argon-mode="dark"]' \
		"and Argon's explicit dark mode"
	assert_contains "$_ts_css_text" ':root[data-argon-mode="normal"]' \
		"with Argon's OS-driven mode under the media query"
	assert_contains "$_ts_css_text" '--fcc-warn-color: #fcd34d' "the dark text is amber-300"
	assert_contains "$_ts_css_text" '--fcc-warn-bg: #451a03' "on amber-950"
	assert_contains "$_ts_css_text" '--fcc-warn-border: #92400e' "with an amber-800 border"
}

test_settings_offer_save_and_reset_and_the_runtime_clears_its_record() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_ctrl="$ROOT/luasrc/controller/fcc.lua"
	_ts_view_text="$(cat "$_ts_view")"
	_ts_js_text="$(cat "$_ts_js")"
	_ts_ctrl_text="$(cat "$_ts_ctrl")"

	# Three verbs on the settings row, in increasing strength: Save & Apply
	# stores and restarts, Save settings stores and leaves a running server
	# alone, Reset changes throws the edits away. The two new labels name their
	# context instead of saying a bare "Save"/"Reset", because LuCI's compiled
	# catalogues share one global namespace and a generic key retitles every
	# other package's button.
	_ts_actions="$(sed -n '/class="fcc-actions"/,/<\/div>/p' "$_ts_view")"
	assert_contains "$_ts_actions" 'id="fcc-save"' "Save & Apply is still there"
	_ts_after_save="$(printf '%s\n' "$_ts_actions" | sed -n '/id="fcc-save"/,$p')"
	assert_contains "$_ts_after_save" 'id="fcc-save-only"' \
		"Save settings follows it"
	_ts_after_save_only="$(printf '%s\n' "$_ts_actions" | sed -n '/id="fcc-save-only"/,$p')"
	assert_contains "$_ts_after_save_only" 'id="fcc-reset"' \
		"and Reset changes follows Save settings"
	assert_contains "$_ts_actions" '<%:Save settings%>' \
		"the save-only button names what it saves"
	assert_contains "$_ts_actions" '<%:Reset changes%>' \
		"the reset button names what it discards"

	# The runtime toolbar's clear comes after Uninstall completely, where the
	# record it clears is produced.
	_ts_after_purge="$(sed -n '/id="fcc-runtime-purge"/,/<\/div>/p' "$_ts_view")"
	assert_contains "$_ts_after_purge" 'id="fcc-runtime-clear"' \
		"Clear record follows Uninstall completely"
	assert_contains "$_ts_view_text" '<%:Clear record%>' \
		"and is the one button that clears both records"
	assert_contains "$_ts_view_text" 'id="fcc-runtime-status"' \
		"the runtime section has its own place to answer a click"

	# The save handler is one function with the flag the backend reads. Both
	# buttons go through it, and the Apply path is the one that keeps the old
	# behaviour.
	assert_contains "$_ts_js_text" 'saveConfig(true)' \
		"Save & Apply applies"
	assert_contains "$_ts_js_text" 'saveConfig(false)' \
		"Save settings does not"
	assert_contains "$_ts_js_text" "apply: apply ? '1' : '0'" \
		"the choice travels to the backend as a flag"
	assert_contains "$_ts_ctrl_text" 'local apply = (http.formvalue("apply") ~= "0")' \
		"and the backend reads it, defaulting to apply"
	assert_contains "$_ts_ctrl_text" '"applied":' \
		"the reply says whether it was applied"
	assert_contains "$_ts_ctrl_text" 'if apply then' \
		"restart and firewall work only run on the apply path"

	# Reset reloads from UCI rather than a copy kept in the page, so it shows
	# what is saved now.
	assert_contains "$_ts_js_text" 'function resetConfig()' "Reset changes is its own action"
	assert_contains "$_ts_js_text" 'return loadConfig().then' \
		"and reads the saved settings back"
	assert_contains "$_ts_js_text" 'Changes discarded. The saved settings are shown.' \
		"telling the user the edits are gone"

	# Clearing the record is page-local, like every other Clear here, and
	# refused while the job that owns the log is still running. One button
	# empties both leftovers — the job panel and the version table.
	assert_contains "$_ts_js_text" 'function clearRecord()' \
		"Clear record is its own action"
	assert_contains "$_ts_js_text" 'if (jobTimer) {' \
		"it refuses while a job is running"
	assert_contains "$_ts_js_text" 'panel.style.display = '"'"'none'"'"';' \
		"and otherwise hides the job panel"
	assert_contains "$_ts_js_text" "pre.textContent = '';" \
		"empties the log on the page"
	assert_contains "$_ts_js_text" 'clearUpdateRecord();' \
		"and puts the update block back to its unchecked state"
	assert_contains "$_ts_js_text" "FCC.\$('#fcc-runtime-clear').addEventListener('click', clearRecord)" \
		"the button is wired"
}

test_every_page_asset_is_cache_stamped() {
	# The pages and the scripts ship in the same package, but a browser caches
	# them separately: the page is rendered per request while a /luci-static/
	# file with no Cache-Control may sit in its cache far longer. An upgrade
	# that removes a DOM node then leaves an old script reaching for it — which
	# is how r9's Configuration page came up with every setting empty: the r8
	# fcc-config.js in the browser threw on the deleted Delete backups button
	# before loadConfig() ran. The stamp makes each upgrade a new URL.
	local _ts_view
	for _ts_view in "$ROOT"/luasrc/view/fcc/*.htm; do
		assert_contains "$(cat "$_ts_view")" 'asset_version()' \
			"$(basename "$_ts_view") takes the stamp from luci.fcc.paths"
	done

	_ts_all="$(grep -rhoE '(src|href)="[^"]*/fcc/[^"]*"' "$ROOT"/luasrc/view/fcc/*.htm | wc -l)"
	_ts_stamped="$(grep -rhoE '(src|href)="[^"]*/fcc/[^"]*\?v=<%=v%>"' "$ROOT"/luasrc/view/fcc/*.htm | wc -l)"
	assert_ok "the views reference the package's assets" test "$_ts_all" -ge 15
	assert_eq "$_ts_stamped" "$_ts_all" \
		"every fcc asset a page requests carries the install stamp"
}

# ---------------------------------------------------------------------------
# Delete backups — removed
#
# The button existed because backup/ was the one part of the install path
# nothing used between runs. An install now deletes the copy it made when it
# ends either way — on success it is not needed, on failure it has just been
# rolled back — so the only copy left for a person to clear is the one a
# rollback that could not complete left behind. That one is evidence, and the
# page should not offer to throw it away. `install.sh cleanbackups` remains for
# a shell.
# ---------------------------------------------------------------------------

test_the_config_page_no_longer_offers_to_delete_the_backups() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_ctrl="$ROOT/luasrc/controller/fcc.lua"
	_ts_install="$ROOT/root/usr/libexec/fcc/install.sh"

	assert_not_contains "$(cat "$_ts_view")" 'fcc-runtime-cleanbackups' \
		"the Configuration page has no Delete backups button"
	assert_not_contains "$(cat "$_ts_view")" 'Delete backups' \
		"and no explanatory paragraph about it"
	assert_not_contains "$(cat "$_ts_js")" 'delete_backups' \
		"the page's script does not call a delete_backups action"
	assert_not_contains "$(cat "$_ts_ctrl")" 'act_delete_backups' \
		"the controller no longer routes or implements it"

	# The verb itself stays: Uninstall and remove all data uses the same
	# clearing code, and a shell is still a way to clear a stuck rollback.
	assert_contains "$(cat "$_ts_install")" 'cleanbackups)' \
		"install.sh still dispatches the cleanbackups verb for a shell"
	assert_contains "$(cat "$_ts_install")" 'cmd_cleanbackups()' \
		"and implements it"
}

# The agent dropdown, and the one thing it is for
#
# Upstream stops at the first agent it cannot install and rolls the whole run
# back (section 79). The whole-registry install is therefore all-or-nothing in a
# way the page did not admit: on a device where one agent cannot be installed —
# a box with no C++ runtime for the Node the npm three need, say — every install
# ends in the same rollback and no agent is reachable at all. The dropdown is
# how they are asked for one at a time.
#
# It is deliberately not the removed table (section 104.25) coming back, and the
# assertions are written to keep the difference: one control, one value, read
# when the button is pressed, no set to reconcile and nothing the page has to
# draw from a second source.
# ---------------------------------------------------------------------------

test_the_config_page_can_install_one_agent() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_ctrl="$ROOT/luasrc/controller/fcc.lua"

	# The control exists, and it is a <select> with a value — not a set of tick
	# boxes, which is what makes this a different thing from what was removed.
	assert_contains "$(cat "$_ts_view")" 'id="fcc-runtime-agent"' \
		"the runtime toolbar has an agent dropdown"
	assert_contains "$(cat "$_ts_view")" '<select id="fcc-runtime-agent"' \
		"and it is a single-value control rather than a list of tick boxes"
	assert_not_contains "$(cat "$_ts_view")" 'type="checkbox" id="fcc-agent' \
		"with no per-agent tick boxes beside it"

	# The user asked for the choice to be made before the action, and a control
	# drawn after the button it governs reads as belonging to the next one.
	_ts_order="$(awk '
		/id="fcc-runtime-agent"/   { pick = NR }
		/id="fcc-runtime-install"/ { btn = NR }
		END { print (pick && btn && pick < btn) ? "before" : "after" }
	' "$_ts_view")"
	assert_eq "before" "$_ts_order" "the dropdown is drawn before the Install button it narrows"

	# Its options come from the registry, which is the single source of truth
	# (section 12) — an agent added to agents.conf appears here with no change to
	# this page, and there is no second list to keep in step.
	assert_contains "$(cat "$_ts_view")" 'require("luci.fcc.agents").load()' \
		"the options are read from the registry rather than written on the page"

	# The default option is every agent, so a click that ignores the dropdown
	# installs what the page installed before the dropdown existed.
	assert_contains "$(cat "$_ts_view")" '<option value=""><%:All agents%></option>' \
		"the first option is every agent, so the default install is unchanged"

	# The script sends the value, and only the value. A chosen agent goes to the
	# install action on its own; the empty value falls through to the
	# whole-registry path, which checks whether a runtime is already present.
	assert_contains "$(cat "$_ts_js")" "FCC.\$('#fcc-runtime-agent')" \
		"Install reads the dropdown when it is pressed"
	assert_contains "$(cat "$_ts_js")" "'install_runtime', { agent: agent }" \
		"and sends the chosen id on its own"

	# The controller turns that one id into the backend's flag. A list would be
	# a second place the agent set lives; one id cannot drift from the registry
	# because it is checked against it.
	assert_contains "$(cat "$_ts_ctrl")" '"install", "runtime", "--agents", id' \
		"the controller passes the chosen agent to the backend by flag"
	assert_contains "$(cat "$_ts_ctrl")" 'util.valid_agent(want)' \
		"after checking that what arrived is an id at all"
	assert_contains "$(cat "$_ts_ctrl")" 'agents.exists(id)' \
		"and that the registry knows it"

	# The report follows the dropdown, because the checks are about a set of
	# agents rather than about the device: an install of every agent can be
	# blocked by something an install of Claude Code does not care about. Left
	# alone, the panel would report the whole-registry verdict over a narrowed
	# selection, and the reader would be told their install was blocked while the
	# job — which asks the shell the same question about the id it was given —
	# would have run it. What the two answers are is pinned by the runtime suite;
	# what is pinned here is that the selection reaches the report at all.
	#
	# Read from act_doctor's own body rather than from the file: the install
	# action reads the same form value, so a file-wide assertion would hold even
	# if the report stopped asking.
	_ts_doctor="$(awk '/^function act_doctor/,/^end/' "$_ts_ctrl")"
	assert_contains "$_ts_doctor" 'http.formvalue("agent")' \
		"the report reads the selection the page sends"
	assert_contains "$_ts_doctor" '"--json", "--agents", id' \
		"and hands it to the doctor as the set to answer about"
	assert_contains "$(cat "$_ts_js")" "FCC.api('doctor', doctorParams(), { method: 'GET' })" \
		"the checks are asked about the set the dropdown names"
	assert_contains "$(cat "$_ts_js")" "agentPicker.addEventListener('change', runDoctor)" \
		"and changing the dropdown asks again, so the panel cannot contradict it"
}

# ---------------------------------------------------------------------------
# "Open FCC Admin" goes through LuCI, not through the FCC port
#
# Section 13 wants the Admin UI reachable from a browser. It cannot be reached
# through the FCC server's own port: every admin route there is refused unless
# the TCP peer is loopback, so a browser on the LAN gets
# {"detail":"Admin UI is local-only"} whatever the bind address is. The page
# used to advise binding the server to the router's LAN address, which is
# exactly the change that does not help.
#
# The link therefore points at the LuCI reverse proxy (section 104.22), which
# reaches the server on 127.0.0.1 from the router itself and is behind LuCI's
# own authentication. Nothing about the link depends on the bind address, so
# there is no disabled state and no explanation to render.
# ---------------------------------------------------------------------------

test_the_admin_link_goes_through_the_luci_proxy() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_css="$ROOT/htdocs/luci-static/resources/fcc/fcc.css"

	# The link is the proxy route, always, with no href to add or remove. The
	# anchor is spread over three lines, so the check reads the element rather
	# than the line the id happens to sit on.
	_ts_link="$(sed -n '/id="fcc-admin-link"/,/<\/a>/p' "$_ts_view")"
	assert_contains "$_ts_link" 'admin/services/fcc/adminproxy' \
		"the Admin link points at the LuCI proxy route"

	# Nothing left that disabled it or explained why it could not work.
	assert_not_contains "$(cat "$_ts_view")" 'fcc-admin-note' "there is no note element to fill"
	assert_not_contains "$(cat "$_ts_js")" 'renderAdminNote' "and no renderer for one"
	assert_not_contains "$(cat "$_ts_js")" 'updateAdminLink' "nor anything that rewrites the link"
	assert_not_contains "$(cat "$_ts_css")" 'fcc-disabled' "and no disabled-link style"
	assert_not_contains "$(cat "$_ts_css")" 'not-allowed' "nor the cursor that went with it"

	# The advice that did not work must not come back as text either: a bind to
	# a specific address is narrowed to loopback precisely because it cannot
	# open the Admin page (section 104.23).
	assert_not_contains "$(cat "$_ts_js")" "FCC.\$('#fcc-bind').value = host" \
		"the page no longer tells the user to bind the server to the LAN address"
}

# ---------------------------------------------------------------------------
# The comments in the templates
#
# A `<%# … %>` comment ends at the first `%>` it contains, so quoting a
# template tag inside one ends the comment at that tag's closing bracket.
# Everything after it is then rendered as though it were page: the rest of the
# prose is printed as text, and the next partial is expanded where that text
# stands. That is what the standalone window did when it was first written —
# its comment named the header and footer partials by their tags, so the page
# opened with the LuCI footer, its version line and Argon's, above the
# terminal, and the tail of the comment printed underneath. Every other check
# on the views asks for markup or for msgids; none of them read the comments
# between.
#
# The rule enforced here is the one the source can be read against: no `<%`
# inside a comment. A tag cannot be written there without one, and a tag there
# is what ends the comment early.
# ---------------------------------------------------------------------------

test_no_template_tag_is_written_inside_a_comment() {
	_ts_comments="$(awk '
		{
			s = $0
			if (!inc) {
				i = index(s, "<%#")
				if (!i) next
				s = substr(s, i + 3)
				inc = 1
			}
			c = index(s, "%>")
			if (c) {
				print substr(s, 1, c - 1)
				inc = 0
			} else {
				print s
			}
		}
	' "$ROOT"/luasrc/view/fcc/*.htm)"

	assert_ne "" "$_ts_comments" "the views do write comments"

	assert_not_contains "$_ts_comments" '<%' \
		"no template tag is written inside a <%# … %> comment"
}

# ---------------------------------------------------------------------------
# Reattaching to a session
#
# `tmux capture-pane -p` separates the pane's rows with a bare LF — that is
# what tmux 3.6 printed when it was measured, `hello\nworld\n` — and xterm runs
# with convertEol off, because the live stream is a raw pty stream that writes
# its own carriage returns. With it off, an LF moves down one row and keeps the
# column, so painting the capture unchanged made every row start where the one
# above it ended: after logging out and back in, the console showed the agent's
# screen as a staircase until the browser was zoomed, which fired a resize, a
# pane resize and a full repaint by the agent.
#
# The fix has three parts, and each is checked here because each is a line that
# can be written back out: the capture is turned into CRLF, it is painted
# through that conversion, and the pane is told the window's size before the
# screen is taken — a captured grid wider than the terminal wraps at the wrong
# column even with the line endings right.
# ---------------------------------------------------------------------------

test_a_reattached_screen_is_painted_with_crlf() {
	_ts_common="$ROOT/htdocs/luci-static/resources/fcc/fcc-common.js"
	_ts_term="$ROOT/htdocs/luci-static/resources/fcc/fcc-terminal.js"
	_ts_pop="$ROOT/htdocs/luci-static/resources/fcc/fcc-popout.js"

	assert_contains "$(cat "$_ts_common")" 'function captureBytes(b64)' \
		"the shared helpers turn a capture's bare LFs into CRLF"
	assert_contains "$(cat "$_ts_common")" 'captureBytes: captureBytes' \
		"and export that to the pages"

	assert_contains "$(cat "$_ts_term")" 'state.term.write(FCC.captureBytes(r.data))' \
		"the console paints a reattached screen with CRLF line endings"
	assert_contains "$(cat "$_ts_pop")" 'term.write(FCC.captureBytes(r.data))' \
		"and so does the standalone window"
	# The live stream is deliberately still painted raw: it is the pty's own
	# bytes, and its carriage returns are already in it.
	assert_contains "$(cat "$_ts_term")" 'state.term.write(FCC.b64ToBytes(r.data))' \
		"the console still paints the live stream as it arrived"

	# fitNow() now resolves when the pane has been told the new size, and
	# attach waits on it before asking for the screen.
	_ts_order="$(awk '
		/^	function attach\(/ { inside = 1 }
		inside && /fitNow\(\)/ { fit = NR }
		inside && /session_capture/ { cap = NR }
		inside && /^	}$/ {
			print (fit && cap && fit < cap) ? "sized" : "captured first"
			exit
		}
	' "$_ts_term")"
	assert_eq "sized" "$_ts_order" \
		"the console sizes the pane before it captures its screen"
}

# ---------------------------------------------------------------------------
# The System list on Basic Information
#
# Section 15's System list, in the order the page shows it: what the CPU is,
# how hot it is, what platform it sits on, which architecture that is, and then
# the two pools of space. The temperature belongs directly under the CPU because
# it is a reading *of* that CPU. There is no DOM harness here, so the order is
# pinned against the renderer that produces it: the cards are appended in source
# order, which makes reading them off the source the same question as reading
# them off the page.
# ---------------------------------------------------------------------------

test_system_list_is_ordered_cpu_temp_platform_arch_memory_storage() {
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-info.js"

	_ts_order="$(sed -n '/^	function renderSystem/,/^	}$/p' "$_ts_js" \
		| grep -o "card(FCC\._('[^']*')" | sed "s/^card(FCC\._('//; s/')$//" \
		| tr '\n' ',' | sed 's/,$//')"

	assert_eq "CPU Info,Temperature,Platform,Architecture,Memory,Storage" "$_ts_order" \
		"the System cards are CPU Info, Temperature, Platform, Architecture, Memory and Storage, in that order"
}

# ---------------------------------------------------------------------------
# ACL
# ---------------------------------------------------------------------------

test_acl_lists_only_real_scripts() {
	_ts_bad=""
	for _ts_p in $(grep -o '"/usr/[^"]*"' "$ROOT/root/usr/share/rpcd/acl.d/luci-app-fcc.json" \
		| tr -d '"' | LC_ALL=C sort -u); do
		[ -e "$ROOT/root$_ts_p" ] || _ts_bad="$_ts_bad $_ts_p"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every ACL path exists in the package"
}

test_acl_covers_every_backend_script() {
	# A script the controller execs but the ACL does not list fails at runtime
	# with a permission error that looks like a bug in the app.
	_ts_acl="$(cat "$ROOT/root/usr/share/rpcd/acl.d/luci-app-fcc.json")"
	_ts_bad=""
	for _ts_f in "$ROOT"/root/usr/libexec/fcc/*.sh; do
		_ts_b="$(basename "$_ts_f")"
		[ "$_ts_b" = "common.sh" ] && continue   # sourced, never exec'd
		# procd execs this one as root to start the server; it is never an
		# rpcd endpoint, so listing it here would be dead configuration.
		[ "$_ts_b" = "server-run.sh" ] && continue
		case "$_ts_acl" in
			*"/usr/libexec/fcc/$_ts_b"*) : ;;
			*) _ts_bad="$_ts_bad $_ts_b" ;;
		esac
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every backend script is in the ACL"
}

# ---------------------------------------------------------------------------
# What a release publishes (sections 62 and 93)
#
# Sections 62 and 93 name the assets a release carries: luci-app-fcc's own
# packages. The SDK builds the whole dependency chain alongside them, and the
# difference between "we publish our package" and "we publish sixty upstream
# packages as well" is one glob — which is exactly the kind of thing that
# changes without anyone noticing, because nothing downstream complains.
# ---------------------------------------------------------------------------

# The collect step of the build job, up to the step that follows it.
collect_step() {
	sed -n '/- name: Collect artifacts/,/- name: Verify the artifacts/p' "$WORKFLOW"
}

# The release job, from its name to the end of the file.
release_job() {
	sed -n '/^  release:/,$p' "$WORKFLOW"
}

# The check job, up to the build job that follows it.
check_job() {
	sed -n '/^  check:/,/^  build:/p' "$WORKFLOW"
}

# A failing check has to be readable by whoever sees the red mark. The log is
# not: it is served only to a signed-in session. Annotations are public, so the
# failure lines are repeated as those, and the step still fails.
test_the_check_job_reports_its_failures() {
	_ts_c="$(check_job)"
	assert_contains "$_ts_c" 'sh scripts/test.sh' "the gate runs the suite"
	assert_contains "$_ts_c" '::error::' \
		"and repeats each failing check as an annotation"
	assert_contains "$_ts_c" 'head -10' \
		"up to the ten a step may raise"
	assert_contains "$_ts_c" 'exit 1' \
		"while still failing the job"
	assert_contains "$_ts_c" 'check.log' \
		"keeping the run's own log for the rest"
}

test_the_build_collects_only_our_package() {
	_ts_c="$(collect_step)"
	assert_ne "" "$_ts_c" "the build job has a collect step"
	# The glob that collects the entire chain. Spelled out literally so that an
	# edit reinstating it is caught rather than quietly republishing upstream
	# packages under this project's name.
	case "$_ts_c" in
		*'-name "*.${{ matrix.ext }}"'*)
			fail "the collect step copies every package the SDK built" ;;
		*) pass ;;
	esac
	# Both of our packages, and the version separator glob that matches the .ipk
	# and the .apk spellings of the same name. The translation is a package of
	# its own now, so a collect step that still named only the app would publish
	# a release with no Chinese interface in it — and the release job would be
	# happy, because dist would be non-empty.
	assert_contains "$_ts_c" 'luci-app-fcc' "the collect step is scoped to the app package"
	assert_contains "$_ts_c" 'luci-i18n-fcc' "the collect step also collects the translation"
	assert_contains "$_ts_c" '[-_]*' "the collect step matches both the .ipk and .apk spellings"
}

test_the_release_does_not_merge_architectures_blindly() {
	# All four artifacts carry the same package — section 92's PKGARCH=all
	# makes it architecture-independent — so merging them lets one copy
	# overwrite another with nothing said. Two SDKs disagreeing about the same
	# package is worth failing on, not resolving by arrival order.
	_ts_r="$(release_job)"
	assert_ne "" "$_ts_r" "the workflow has a release job"
	case "$_ts_r" in
		*'merge-multiple: true'*)
			fail "the release job merges artifacts, so duplicates overwrite silently" ;;
		*) pass ;;
	esac
	assert_contains "$_ts_r" 'cmp -s' "the release job compares the copies it received"
}

test_the_release_publishes_only_our_package() {
	_ts_r="$(release_job)"
	# Both of our packages, on the one line that decides. The translation does
	# not begin with "luci-app-fcc", so a filter that named only the app would
	# drop it here — with a warning, into a release that then looked complete.
	# Spelled out as the whole pattern so that a third alternative added later is
	# a deliberate edit rather than a quiet widening.
	assert_contains "$_ts_r" 'luci-app-fcc*|luci-i18n-fcc*) : ;;' \
		"the release job publishes our two packages and no others"
	# The publish list must be the collected directory, not the raw download:
	# artifacts/ is what the job received, release/ is what it decided to ship,
	# and only the second one has been filtered.
	_ts_gh="$(printf '%s\n' "$_ts_r" | sed -n '/gh release create/,$p')"
	assert_contains "$_ts_gh" 'release/*' "the release publishes the filtered directory"
	assert_not_contains "$_ts_gh" 'artifacts/' "the release does not publish the raw download"
}

test_the_release_is_named_after_the_package_version() {
	# Section 62: the tag, the release name and the package file name are one
	# string, composed from ./VERSION and the Makefile's PKG_RELEASE. The
	# release carrying luci-app-fcc_0.1.1-r2_all.ipk is called 0.1.1-r2 and is
	# tagged 0.1.1-r2 — with no v, because the name is the version rather than
	# a tag-shaped spelling of it.
	_ts_r="$(release_job)"
	assert_contains "$_ts_r" 'full="$(sh scripts/version.sh)"' \
		"the release reads the version from the one script that composes it"
	assert_contains "$_ts_r" 'PKGVER=$full' \
		"and hands it to the rest of the job as the version"

	# The assets are stamped from the same two files, so this is where "the
	# release carries what was actually built" is verified rather than assumed.
	# The whole string is compared: 0.1.1-r1 and 0.1.1-r2 are different packages.
	assert_contains "$_ts_r" 'does not carry version $full' \
		"the release checks each asset carries that version"

	# Tag and title are both the version itself. Taking either from the ref is
	# what this replaced: a tag is typed by hand and can name a version the
	# packages were not built from, and the release would follow the typo.
	assert_contains "$_ts_r" 'gh release create "$ver"' \
		"the release is tagged with the version"
	assert_contains "$_ts_r" '--title "$ver"' \
		"and named with the same string"
	assert_not_contains "$_ts_r" 'GITHUB_REF_NAME' \
		"neither of them comes from the ref"
	# The tag has to land on the commit this run built, not on whatever the
	# default branch points at when the release job finally runs: two pushes in
	# quick succession otherwise leave the first release's tag on the second
	# commit, and checking out that tag gives code the release does not carry.
	assert_contains "$_ts_r" '--target "$GITHUB_SHA"' \
		"and it is placed on the commit the packages came from"
	case "$_ts_r" in
		*'v$full'*|*'v$ver'*)
			fail "the release name is the version with a v put in front of it" ;;
		*) pass ;;
	esac
}

test_the_release_runs_on_a_push_and_never_on_a_pull_request() {
	# The tag is created by this job, so there is no tag to push and nothing to
	# mistype. What starts a release is a push to the default branch.
	_ts_on="$(sed -n '/^on:/,/^permissions:/p' "$WORKFLOW")"
	assert_ne "" "$_ts_on" "the workflow has a trigger block"
	case "$_ts_on" in
		*tags:*) fail "the workflow still triggers on a tag" ;;
		*) pass ;;
	esac
	assert_contains "$_ts_on" 'branches: [main, master]' \
		"a push to the default branch is what publishes"

	# A pull request must never be able to cut a release.
	_ts_r="$(release_job)"
	assert_contains "$_ts_r" "github.event_name != 'pull_request'" \
		"a pull request never publishes a release"

	# And the guard must not be one that overrides `needs`. `!cancelled()` and
	# `always()` both make a job run after a job it needs has failed, which here
	# would publish a package whose install smoke test failed — the one outcome
	# the release job exists to prevent. Comments are stripped first, because
	# the job explains at length why those two are not used.
	assert_contains "$_ts_r" 'needs: [build, smoke]' \
		"the release waits for every build and every smoke test"
	_ts_code="$(printf '%s\n' "$_ts_r" | grep -v '^[[:space:]]*#')"
	case "$_ts_code" in
		*'!cancelled()'*|*'always()'*)
			fail "the release guard runs the job even when a build or smoke leg failed" ;;
		*) pass ;;
	esac
}

test_the_release_replaces_the_one_for_the_same_version() {
	# A published release is immutable, so a rerun under the same version has to
	# drop the previous one first — otherwise a push that changed nothing about
	# the version would fail on a tag that already exists. Bumping PKG_RELEASE
	# is the deliberate act that cuts a new release; the same version twice
	# means the same release rebuilt.
	_ts_r="$(release_job)"
	assert_contains "$_ts_r" 'gh release delete "$ver"' \
		"the release job deletes the previous release for this version"
	assert_contains "$_ts_r" '--cleanup-tag' \
		"and takes the tag with it"
	assert_contains "$_ts_r" 'git/refs/tags/$ver' \
		"and a tag left behind without a release"

	# Order matters: deleting after creating would throw away the release that
	# was just published, which is worse than not publishing at all.
	_ts_del="$(printf '%s\n' "$_ts_r" | grep -n 'gh release delete' | head -1 | cut -d: -f1)"
	_ts_new="$(printf '%s\n' "$_ts_r" | grep -n 'gh release create' | head -1 | cut -d: -f1)"
	assert_ne "" "$_ts_del" "the job deletes a release"
	assert_ne "" "$_ts_new" "and creates one"
	if [ -n "$_ts_del" ] && [ -n "$_ts_new" ] && [ "$_ts_del" -lt "$_ts_new" ]; then
		pass
	else
		fail "the release is deleted after it is created"
	fi
}

test_the_release_notes_carry_what_section_93_lists() {
	# Section 93 lists what a release's notes have to contain, and gh's own
	# --generate-notes is a list of commits rather than any of it. Two of the
	# six are read from the files that define them — the version from
	# scripts/version.sh, the agents from the registry section 33 makes the
	# single source of truth — so a new agent reaches the notes without an edit
	# to the workflow.
	_ts_r="$(release_job)"
	assert_contains "$_ts_r" 'release-notes.md' \
		"the release builds its own notes"
	assert_contains "$_ts_r" '--notes-file release-notes.md' \
		"and hands those to gh rather than the generated commit list"
	assert_contains "$_ts_r" 'ver="${{ steps.version.outputs.PKGVER }}"' \
		"the notes carry the version the release is named after"
	assert_contains "$_ts_r" 'root/usr/share/luci-app-fcc/agents.conf' \
		"the agent list comes from the registry"
	assert_contains "$_ts_r" '24.10' "the notes name the release the .ipk is for"
	assert_contains "$_ts_r" '25.12' "and the one the .apk is for"
	assert_contains "$_ts_r" 'Architecture' \
		"the notes say which architectures the package fits"
	assert_contains "$_ts_r" 'not shipped and not pinned' \
		"and that the runtime is installed on demand rather than pinned here"
	assert_contains "$_ts_r" 'Known limitations' \
		"the notes list the known limitations"
}

test_the_version_script_composes_the_package_version() {
	# One place composes the version, and this is it. The workflow, the README
	# and this suite all ask it rather than each reading VERSION and deciding
	# for themselves what the release is called — the tag is public and
	# permanent, and one that disagrees with the packages under it cannot be
	# taken back.
	_ts_ver="$(tr -d ' \t\r\n' < "$ROOT/VERSION")"
	_ts_rel="$(sed -n 's/^PKG_RELEASE[ \t]*:=[ \t]*\([0-9][0-9]*\).*/\1/p' "$MAKEFILE")"
	assert_ne "" "$_ts_ver" "VERSION holds a version"
	assert_ne "" "$_ts_rel" "the Makefile holds a numeric PKG_RELEASE"

	assert_eq "$_ts_ver-r$_ts_rel" "$(sh "$ROOT/scripts/version.sh")" \
		"the script composes VERSION and PKG_RELEASE into the package version"

	# It is the tag as well as the package name, so it must not be spelled like
	# a tag: a v here would be a v in the tag, in the release name and in the
	# file name, and the release for 0.1.1-r2 is called 0.1.1-r2.
	case "$(sh "$ROOT/scripts/version.sh")" in
		v*) fail "the package version carries a v prefix" ;;
		*) pass ;;
	esac

	# The version the release is named after is the version the package file is
	# named after, so the two are asserted to be the same string rather than
	# assumed to be.
	assert_contains "$_ts_ver-r$_ts_rel" "$_ts_ver" \
		"the package version carries the file's version"
	assert_contains "$_ts_ver-r$_ts_rel" "r$_ts_rel" \
		"and the release number with it"

	assert_no "an option it does not know is refused" \
		sh "$ROOT/scripts/version.sh" --nonsense
	assert_no "--tag went with the tags it was there for" \
		sh "$ROOT/scripts/version.sh" --tag
}

# ---------------------------------------------------------------------------
# The FCC Server section controls one machine at a time
#
# [This router] [LAN] switches which, and the local panel keeps exactly the
# controls it had. The LAN panel has the same four buttons, its two fields, a
# key line and one collapsed block of advanced settings — the last of those is
# what keeps a feature with eight stored values from turning the section into a
# form.
# ---------------------------------------------------------------------------

test_the_server_section_switches_between_this_router_and_the_lan() {
	_ts_view="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_css="$ROOT/htdocs/luci-static/resources/fcc/fcc.css"

	assert_contains "$(cat "$_ts_view")" 'data-mode="local"' \
		"the switch offers this router"
	assert_contains "$(cat "$_ts_view")" 'data-mode="lan"' \
		"and the LAN"
	assert_contains "$(cat "$_ts_view")" '<%:This router%>' \
		"the local side is named in words rather than as a mode flag"
	assert_contains "$(cat "$_ts_view")" 'id="fcc-local-controls"' \
		"the local panel is a block of its own"
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-controls" hidden' \
		"and the LAN panel starts hidden"

	# The four buttons exist on both sides. The local ones keep data-op; the LAN
	# ones are data-remote-op, so the two handlers cannot bind to each other's
	# buttons.
	assert_contains "$(sed -n '/id="fcc-remote-controls"/,/<\/details>/p' "$_ts_view")" \
		'data-remote-op="start"' "LAN mode has Start"
	assert_contains "$(sed -n '/id="fcc-remote-controls"/,/<\/details>/p' "$_ts_view")" \
		'data-remote-op="stop"' "LAN mode has Stop"
	assert_contains "$(sed -n '/id="fcc-remote-controls"/,/<\/details>/p' "$_ts_view")" \
		'data-remote-op="restart"' "LAN mode has Restart"
	assert_contains "$(sed -n '/id="fcc-remote-controls"/,/<\/details>/p' "$_ts_view")" \
		'id="fcc-remote-admin-link"' "LAN mode has Open FCC Admin"
	assert_contains "$(cat "$_ts_js")" \
		"document.querySelectorAll('#fcc-local-controls [data-op]')" \
		"the local handler is scoped to the local panel"

	# The two fields and the button that acts on them.
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-host"' "the address field exists"
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-user"' "the account field exists"
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-test"' "and the connection test"

	# The key line, and the panels that hold the public key and the fingerprint
	# to confirm. They are elements the script fills, so they must be present
	# even before anything is configured.
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-key-state"' "the key status line exists"
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-keygen"' "with the first-use button"
	# The button makes the pair and shows the public half; putting it in place
	# on the other machine is the step after it, said in the panel, so the
	# label names only what the click does.
	assert_contains "$(cat "$_ts_view")" '<%:Generate key%>' \
		"whose label is the generating alone"
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-pubkey"' "and somewhere to show the key"
	# Where the key goes differs per platform, so the panel names all three:
	# a Unix path is wrong on Windows and wrong for OpenWrt's Dropbear.
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-key-path"' \
		"the authorized_keys location has its own element"
	assert_contains "$(cat "$_ts_js")" "'/.ssh/authorized_keys'" \
		"Linux uses the account's ~/.ssh/authorized_keys"
	assert_contains "$(cat "$_ts_js")" "/etc/dropbear/authorized_keys" \
		"OpenWrt's Dropbear reads /etc/dropbear/authorized_keys"
	assert_contains "$(cat "$_ts_js")" 'C:\\ProgramData\\ssh\\administrators_authorized_keys' \
		"a Windows administrator account uses the ProgramData file"
	assert_contains "$(cat "$_ts_js")" "'C:\\\\Users\\\\'" \
		"and a standard Windows account keeps it under its profile"
	assert_contains "$(cat "$_ts_js")" "'/Users/'" \
		"macOS keeps it under /Users, the same file Remote Login reads"
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-trust-fingerprint"' \
		"the fingerprint to confirm has its own element"

	# Advanced settings are collapsed: the section is meant to stay small, and
	# everything that is only touched once belongs behind the summary. The
	# platform is not one of those things — it decides what each button sends,
	# so it is read before the address. Directly under the summary comes the
	# status line, where every action's answer is written: a refused key, a
	# machine that cannot be reached, a fingerprint that changed. The key row
	# closes the section, and the panels its buttons open sit underneath it,
	# so a message never ends up separated from its field by that row.
	_ts_adv="$(sed -n '/<details class="fcc-advanced" id="fcc-remote-advanced">/,/<\/details>/p' "$_ts_view")"
	assert_contains "$_ts_adv" '<details class="fcc-advanced" id="fcc-remote-advanced">' \
		"the advanced settings are a collapsed details block"
	assert_contains "$_ts_adv" 'id="fcc-remote-ssh-port"' "SSH port is in it"
	assert_contains "$_ts_adv" 'id="fcc-remote-admin-port"' "so is the Admin port"
	assert_contains "$_ts_adv" 'id="fcc-remote-service"' "and the service name"
	assert_contains "$_ts_adv" 'id="fcc-remote-preview"' "and the command preview"
	assert_not_contains "$_ts_adv" 'id="fcc-remote-platform"' \
		"the platform is not"

	_ts_platform_line="$(grep -n 'id="fcc-remote-platform"' "$_ts_view" | head -1 | cut -d: -f1)"
	_ts_host_line="$(grep -n 'id="fcc-remote-host"' "$_ts_view" | head -1 | cut -d: -f1)"
	_ts_adv_line="$(grep -n '<details class="fcc-advanced" id="fcc-remote-advanced">' "$_ts_view" \
		| head -1 | cut -d: -f1)"
	_ts_key_line="$(grep -n 'id="fcc-remote-key-state"' "$_ts_view" | head -1 | cut -d: -f1)"
	_ts_status_line="$(grep -n 'id="fcc-remote-status"' "$_ts_view" | head -1 | cut -d: -f1)"
	_ts_helper_line="$(grep -n 'id="fcc-remote-helper-panel"' "$_ts_view" \
		| head -1 | cut -d: -f1)"
	assert_eq 1 "$((_ts_platform_line < _ts_host_line))" \
		"the platform comes before the address it belongs to"
	assert_eq 1 "$((_ts_adv_line < _ts_status_line))" \
		"the status line follows the advanced settings"
	assert_eq 1 "$((_ts_status_line < _ts_key_line))" \
		"and the key row comes after it"
	assert_eq 1 "$((_ts_key_line < _ts_helper_line))" \
		"with the panels it opens underneath that row"

	# The preview is the same three presets remote.sh runs, so a reader can see
	# what a click sends without opening the script.
	assert_contains "$(cat "$_ts_js")" "REMOTE_VERBS" \
		"the preview is built from the platform's verbs"
	assert_contains "$(cat "$_ts_js")" "'systemctl ' + verb + ' ' + service" \
		"Linux is systemctl"
	assert_contains "$(cat "$_ts_js")" "'/etc/init.d/' + service + ' ' + verb" \
		"OpenWrt is its init script"
	assert_contains "$(cat "$_ts_js")" "'Start-Service'" "Windows is PowerShell"
	# install.ps1 registers no Windows service, so the preview shows both
	# branches and the fallback to the upstream install's own server.
	assert_contains "$(cat "$_ts_js")" "if (Get-Service -Name '" \
		"the Windows preview asks whether a service of that name exists"
	assert_contains "$(cat "$_ts_js")" "Start-Process -WindowStyle Hidden" \
		"and shows the fallback that starts fcc-server when it does not"
	assert_contains "$(cat "$_ts_js")" "<PATH setup>" \
		"with the PATH setup it shares with the backend abbreviated"
	# macOS writes no launchd job either, but the launcher itself is what the
	# buttons start and stop there — so the preview shows those commands rather
	# than a sentence claiming the machine cannot be controlled from here.
	assert_contains "$(cat "$_ts_js")" "nohup fcc-server" \
		"macOS previews the launcher the buttons really start"
	assert_contains "$(cat "$_ts_js")" 'kill $(pgrep -f fcc-server)' \
		"and the pid-based stop they really run"
	# OpenWrt runs its init script when there is one and the launcher when there
	# is not, exactly as Linux does without a unit; the preview says so.
	assert_contains "$(cat "$_ts_js")" 'Without an init script of that name the launcher is used instead' \
		"the OpenWrt preview names the launcher fallback"
	assert_contains "$(cat "$_ts_view")" 'value="macos"' \
		"and macOS is one of the platform options"

	# The backend accepts the same four names, because a select's value is
	# stored UCI and the script is what acts on it.
	assert_contains "$(cat "$ROOT/root/usr/libexec/fcc/remote.sh")" \
		'linux|macos|openwrt|windows) return 0' \
		"the backend's platform list matches the select"

	# The buttons are disabled until the key, the trust and the OpenSSH client
	# are all in place — the same `ready` flag the backend computes.
	assert_contains "$(cat "$_ts_js")" 'b.disabled = !can' \
		"the LAN buttons follow the readiness flag"
	assert_contains "$(cat "$_ts_js")" 'remote.ready = d.ready === true' \
		"which is read from the backend rather than inferred"
	# The one-time panel has one way in: its own button. A refused Start used
	# to open it as well, and so did a Stop whose forwarding step was refused —
	# the second showed the block that installs the very setting the stop was
	# taking away, and both read as if the click had asked for authorization.
	assert_not_contains "$(cat "$_ts_js")" 'showRemoteHelper(true)' \
		"no control click opens the one-time panel"
	assert_contains "$(cat "$_ts_js")" 'showRemoteHelper(!panel || panel.hidden)' \
		"only the one-time authorization button does"
	assert_contains "$(cat "$_ts_css")" '.fcc-mode-btn.on' \
		"the selected side of the switch is styled"
	assert_contains "$(cat "$_ts_css")" '.fcc-locked' \
		"and the Admin link has a not-yet-usable state"
	# The Username box and the IP box are the same width on every theme. Argon
	# 24.10 stretches the field across the row and gives text inputs a width of
	# their own; a flex-grow on this input beat that width and left the Username
	# box 681px wide under a 256px IP box on 24.10 but 256px on 25.12.
	assert_contains "$(cat "$_ts_css")" \
		'.fcc-remote-row input[type="text"] { flex: 0 1 auto; }' \
		"the Username box keeps the width its theme gives it"

	# The client is checked on the router, and the page says which side is
	# wrong. OpenWrt's Dropbear answers as /usr/bin/ssh through alternatives, so
	# "OpenSSH is required" on its own sent people to install it on the remote
	# machine — the one place where it changes nothing.
	_ts_remote="$ROOT/root/usr/libexec/fcc/remote.sh"
	assert_contains "$(cat "$_ts_js")" 'remote.ssh_client = d.ssh_client' \
		"the page reads which ssh this router has"
	assert_contains "$(cat "$_ts_js")" "remote.ssh_client === 'dropbear'" \
		"and has a message for Dropbear specifically"
	assert_contains "$(cat "$_ts_js")" 'on the router' \
		"every client message names the router as the place to install it"
	assert_contains "$(cat "$_ts_js")" 'openssh-client-utils' \
		"with the package that provides ssh, ssh-keygen and ssh-keyscan"
	assert_contains "$(cat "$_ts_js")" 'openssh-keygen' \
		"and the package for the key generator when only that is missing"
	assert_contains "$(cat "$_ts_js")" 'ssh-keyscan' \
		"the host-key scanner is called out by name too"
	assert_contains "$(cat "$_ts_remote")" "printf 'openssh'" \
		"the backend classifies the client instead of just finding ssh"
	assert_contains "$(cat "$_ts_remote")" 'ssh on this router is Dropbear' \
		"and refuses Dropbear in those words"
	assert_contains "$(cat "$_ts_remote")" 'this router has no SSH client' \
		"with a separate sentence when there is no client at all"
	assert_contains "$(cat "$_ts_remote")" '"ssh_client":%s' \
		"the client name reaches the page in status"
	assert_not_contains "$(cat "$_ts_remote")" 'package openssh-client)' \
		"the old package name that exists on the remote machine is not used"

	# One FCC Server at a time. The switch, a Start on either side and the boot
	# path all have to stop the other side, or two instances answer on the same
	# network — which is what the page used to allow.
	_ts_ctl="$ROOT/luasrc/controller/fcc.lua"
	_ts_init="$ROOT/root/etc/init.d/fcc"
	assert_contains "$(cat "$_ts_view")" 'Only one FCC Server runs at a time' \
		"the switch says that only one side runs"
	assert_contains "$(cat "$_ts_js")" 'setModeBusy' \
		"the switch is disabled while it is being applied"
	assert_contains "$(cat "$_ts_js")" 'r.remote_stopped' \
		"the page reports whether the other side was stopped"
	assert_contains "$(cat "$_ts_ctl")" 'stop_remote_server' \
		"the controller stops the LAN server when it moves to this router"
	assert_contains "$(cat "$_ts_ctl")" 'remote_stopped' \
		"and tells the page whether that worked"
	assert_contains "$(cat "$_ts_init")" 'control_target' \
		"the init script reads the stored target"
	assert_contains "$(cat "$_ts_remote")" '[ "$_cc_op" != "stop" ]' \
		"the LAN script still allows Stop while the target is this router"

	# The switch position survives a logout; the running server is a fact about
	# another machine, so the page asks again instead of remembering an answer.
	assert_contains "$(cat "$_ts_view")" 'id="fcc-remote-server-state"' \
		"the LAN panel has a line for the remote server state"
	assert_contains "$(cat "$_ts_js")" 'checkRemoteRunning' \
		"the page checks it when the LAN panel is shown"
	assert_contains "$(cat "$_ts_js")" "'remote_running'" \
		"through a read-only endpoint of its own"
	assert_contains "$(cat "$_ts_remote")" 'systemctl is-active' \
		"which asks systemd on Linux"
	assert_contains "$(cat "$_ts_remote")" 'Get-Service' \
		"and PowerShell on Windows"
	assert_contains "$(cat "$_ts_ctl")" 'act_remote_running' \
		"the controller routes it"
	assert_not_contains "$(sed -n '/^mutating_actions()/,/^}/p' "$ROOT/tests/test_security.sh")" \
		'act_remote_running' "and it is not listed as state-changing"

	# That answer goes stale in a way the switch position does not: uptime and
	# memory move, and a server can die on its own. So the six lines are read
	# again every thirty seconds — and only then: the timer is armed by an
	# answer that says the server is running, and stopped by any other answer,
	# a failed check, or the panel leaving the LAN side.
	assert_contains "$(cat "$_ts_js")" 'var REMOTE_POLL_MS = 30000;' \
		"the LAN state is re-read every 30 seconds"
	assert_contains "$(cat "$_ts_js")" 'remotePollTimer = setInterval(' \
		"through a timer of its own"
	assert_contains "$(cat "$_ts_js")" 'keepRemotePolling(remote.server_running === true);' \
		"armed only while the server is running"
	assert_contains "$(cat "$_ts_js")" 'checkRemoteRunning(true);' \
		"and refreshed without blanking the card that is already up"

	# The one-time helper is about the LAN machine's sshd, not a third kind of
	# key, so it stays on the key row rather than on a row of its own further
	# down — the one-time command first, the public key for that account after
	# it.
	_ts_keys="$(sed -n '/id="fcc-remote-keygen"/,/id="fcc-remote-helper"/p' "$_ts_view")"
	assert_contains "$_ts_keys" 'id="fcc-remote-keygen"' \
		"the key row starts with the control that makes a key"
	assert_contains "$_ts_keys" '<%:One-time authorization%>' \
		"under the name it now carries"
	_ts_helper_line="$(grep -n 'id="fcc-remote-helper"' "$_ts_view" | cut -d: -f1)"
	_ts_show_line="$(grep -n 'id="fcc-remote-showkey"' "$_ts_view" | cut -d: -f1)"
	assert_ok "Show public key comes after the one-time authorization button" \
		test "$_ts_helper_line" -lt "$_ts_show_line"

	# The page is translated and remote.sh is not. A failure must not carry the
	# script's English sentence into a Chinese interface, and ssh's own warning
	# must not be the first line of every error.
	assert_contains "$(cat "$_ts_js")" 'REMOTE_ERROR_TEXT' \
		"the page translates the script's fixed sentences itself"
	assert_contains "$(cat "$_ts_js")" 'remoteFailure' \
		"every LAN failure goes through one translator"
	assert_contains "$(cat "$_ts_js")" 'remoteCaught' \
		"including a rejected request"
	assert_contains "$(cat "$_ts_js")" 'no-systemctl' \
		"a machine without systemctl is explained, not quoted"
	assert_contains "$(cat "$_ts_js")" 'remoteOutput' \
		"ssh's own warnings are filtered out of the diagnostics"

	# A start that failed is the one mapped reason whose sentence points at a
	# log, so the log's last lines — already collected by the check over there —
	# are shown with it instead of being thrown away by the mapping.
	_ts_fail="$(sed -n '/function remoteFailure/,/function remoteCaught/p' "$_ts_js")"
	assert_contains "$_ts_fail" "d.reason === 'start-failed'" \
		"a failed start keeps the log tail the check brought back"
	assert_contains "$_ts_fail" 'the FCC Server did not start' \
		"without repeating the verdict line the tail opens with"
	assert_contains "$(cat "$_ts_remote")" 'fcc_remote_output_filter' \
		"the script drops them before anything is relayed"
	assert_contains "$(cat "$_ts_remote")" 'fcc_remote_reason' \
		"and sends a reason code the page can translate"
	assert_not_contains \
		"$(sed -n '/function checkRemoteRunning/,/function remoteBlocker/p' "$_ts_js")" \
		'err.message' "the state check never shows a raw client message"
	assert_not_contains \
		"$(sed -n '/function remoteTest/,/function remoteControl/p' "$_ts_js")" \
		'err.message' "nor does any LAN button"

	# The platform name typed into the service field is a one-word mistake that
	# made every check ask for /etc/init.d/OpenWrt. It is corrected on write,
	# on read, and the page says why the field changed.
	assert_contains "$(cat "$ROOT/luasrc/fcc/util.lua")" 'service_is_a_platform_name' \
		"one predicate decides what a platform word is"
	assert_contains "$(cat "$_ts_ctl")" 'service_reset' \
		"the save stores the default and reports the correction"
	assert_contains "$(cat "$_ts_js")" 'r.service_reset' \
		"the page says why the service name changed"
	assert_contains "$(cat "$_ts_remote")" 'linux|macos|openwrt|windows) _sv_name=fcc' \
		"the script applies the same rule to stored UCI"

	# The LAN panel describes the server the way the local one does. The remote
	# machine runs this package too, so its status.sh is the document both
	# panels render — one renderer, six lines, two sides.
	assert_contains "$(cat "$_ts_remote")" 'fcc_remote_details' \
		"the backend asks the LAN machine for its own status document"
	assert_contains "$(cat "$_ts_remote")" '"details":{' \
		"and folds it into the running answer"
	assert_contains "$(cat "$_ts_js")" 'renderServerRows' \
		"the local and LAN panels share one set of rows"
	assert_contains "$(cat "$_ts_js")" 'remote.server_details' \
		"the LAN panel renders the document when one arrives"
	assert_contains "$(cat "$_ts_view")" '<div id="fcc-remote-server-state"' \
		"the LAN state is a container now — a table cannot live in a paragraph"

	# Both panels are read in the same order: the one-server notice, then what
	# the server is doing, then the buttons that act on it. A panel that offers
	# Start before it says what is running answers the question the user asks
	# second before the one they ask first.
	_ts_notice=$(grep -n 'Only one FCC Server runs at a time' "$_ts_view" | head -1 | cut -d: -f1)
	_ts_state=$(grep -n 'id="fcc-remote-server-state"' "$_ts_view" | head -1 | cut -d: -f1)
	_ts_start=$(grep -n 'data-remote-op="start"' "$_ts_view" | head -1 | cut -d: -f1)
	_ts_host=$(grep -n 'id="fcc-remote-host"' "$_ts_view" | head -1 | cut -d: -f1)
	assert_eq 1 "$((_ts_notice < _ts_state))" \
		"the LAN state follows the one-server notice"
	assert_eq 1 "$((_ts_state < _ts_start))" \
		"the LAN buttons follow the state"
	assert_eq 1 "$((_ts_start < _ts_host))" \
		"and the connection fields follow the buttons"
}

# ---------------------------------------------------------------------------
# Basic Information has manual, named controls
#
# A tab switch must not cost a network request, so the update check is a
# button and nothing else. The two clear buttons say which record each one
# empties: the check report on Diagnostics and the loaded log here.
# ---------------------------------------------------------------------------

test_basic_information_controls_are_manual_and_named() {
	_ts_info="$ROOT/luasrc/view/fcc/info.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-info.js"
	_ts_config="$ROOT/luasrc/view/fcc/config.htm"
	_ts_js_config="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"

	assert_contains "$(cat "$_ts_config")" '<%:Clear check log%>' \
		"the diagnostics button is named after the check report, not logs"
	assert_not_contains "$(cat "$_ts_config")" '<%:Clear log%>' \
		"so it cannot be read as the log viewer's control"

	# The log viewer on this page gets its own clear, next to Load.
	assert_contains "$(cat "$_ts_info")" 'id="fcc-info-log-clear"' \
		"the log viewer has a clear button"
	assert_contains "$(sed -n '/id="fcc-info-log-select"/,/<\/div>/p' "$_ts_info")" \
		'id="fcc-info-log-load"' "Load is in the same toolbar"
	assert_contains "$(sed -n '/id="fcc-info-log-select"/,/<\/div>/p' "$_ts_info")" \
		'id="fcc-info-log-clear"' "and Clear log sits beside it"
	assert_contains "$(cat "$_ts_js")" "FCC.\$('#fcc-info-log-clear')" \
		"the button is wired"
	assert_contains "$(cat "$_ts_js")" "FCC.\$('#fcc-info-log').textContent = ''" \
		"and empties the pane rather than any file"

	# Refresh is gone; the block's toolbar is Check for updates and Update FCC.
	assert_not_contains "$(cat "$_ts_info")" 'fcc-info-refresh' \
		"the update section no longer has a Refresh button"
	assert_not_contains "$(cat "$_ts_js")" 'fcc-info-refresh' \
		"and nothing still binds to it"

	# The whole update block lives under FCC Runtime on Configuration now.
	assert_not_contains "$(cat "$_ts_info")" 'fcc-info-update' \
		"Basic Information no longer carries the update controls"
	assert_not_contains "$(cat "$_ts_info")" 'id="fcc-info-updates"' \
		"and its update section is gone"
	assert_contains "$(cat "$_ts_config")" 'class="fcc-update-block"' \
		"Configuration carries the update block"
	_ts_warn_line="$(grep -n 'avoid choosing “All agents”' "$_ts_config" | cut -d: -f1)"
	_ts_block_line="$(grep -n 'class="fcc-update-block"' "$_ts_config" | cut -d: -f1)"
	_ts_job_line="$(grep -n 'id="fcc-job"' "$_ts_config" | cut -d: -f1)"
	if [ -n "$_ts_warn_line" ] && [ -n "$_ts_block_line" ] && [ -n "$_ts_job_line" ] \
		&& [ "$_ts_block_line" -gt "$_ts_warn_line" ] && [ "$_ts_block_line" -lt "$_ts_job_line" ]; then
		pass "the block sits below the install warning, above the job panel"
	else
		fail "the block sits below the install warning, above the job panel" \
			"warning=$_ts_warn_line block=$_ts_block_line job=$_ts_job_line"
	fi
	_ts_updates="$(sed -n '/class="fcc-update-block"/,/id="fcc-job"/p' "$_ts_config")"
	assert_contains "$_ts_updates" 'id="fcc-update-check"' \
		"Check for updates is in the block's toolbar"
	assert_contains "$_ts_updates" 'id="fcc-update-run"' \
		"Update FCC is in the update toolbar"
	_ts_after_update="$(sed -n '/id="fcc-update-run"/,/<\/div>/p' "$_ts_config")"
	# The update toolbar has the two buttons that act on the update; the third
	# one was a Clear that duplicated the runtime toolbar's, so it is gone.
	assert_not_contains "$_ts_after_update" 'id="fcc-update-clear"' \
		"and no Clear button follows it any more"

	# No check on load. The init body must not call the checker; the block
	# starts in the same state the clear button restores.
	_ts_init="$(sed -n '/^	function init()/,/^	}$/p' "$_ts_js_config")"
	assert_not_contains "$_ts_init" 'checkUpdates();' \
		"opening the tab does not run an update check"
	assert_contains "$_ts_init" 'clearUpdateRecord();' \
		"it renders the not-checked state instead"
	assert_not_contains "$(cat "$_ts_js_config")" 'checkUpdates();' \
		"no code path runs a check on its own, not even after an update"
	assert_contains "$(cat "$_ts_js_config")" "text: FCC._('Not checked yet.')" \
		"which is one shared sentence"
	assert_contains "$(cat "$_ts_js_config")" 'updateAvailable = false;' \
		"clearing also drops the pending update"
	assert_contains "$(cat "$_ts_js_config")" 'btn.disabled = true;' \
		"and disables Update FCC until a new check"
	# The runtime's "installed" field is the version string, null when absent.
	# Testing it for `true` left the button disabled after a check that found
	# an update, so the click did nothing — the reported bug.
	assert_not_contains "$(cat "$_ts_js_config")" 'f.installed === true' \
		"the check result's installed field is not treated as a boolean"
	assert_contains "$(cat "$_ts_js_config")" \
		"&& (f.update_available === true || f.update_available === 'true');" \
		"the button lights from a checked, installed runtime with an update"

	# The update holds fcc-update.lock, so the page must follow that lock. A
	# watch on 'install' found nothing on the first poll and reported the job
	# finished before it had started, which is why Update FCC looked inert.
	assert_contains "$(cat "$_ts_js_config")" \
		"runJobAction('update_runtime', {}, 'update', 'fcc-update.log', clearUpdateRecord)" \
		"the update watches its own lock and clears the record when it ends"
	assert_not_contains "$(cat "$_ts_js_config")" \
		"runJobAction('update_runtime', {}, 'install'" \
		"and never the install lock"
	assert_contains "$(cat "$_ts_js_config")" \
		"FCC.\$('#fcc-runtime-update').addEventListener('click', runUpdate)" \
		"the runtime toolbar's Update starts the same job"
	assert_contains "$(cat "$_ts_js_config")" \
		"FCC.\$('#fcc-update-check').addEventListener('click', checkUpdates)" \
		"Check for updates is wired"
	assert_not_contains "$(cat "$_ts_js_config")" \
		'fcc-update-clear' \
		"nothing still binds a second Clear button"
}

test_configuration_runtime_panel_polls_the_status() {
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-config.js"
	_ts_poll="$(sed -n '/function pollStatus()/,/^	}$/p' "$_ts_js")"
	_ts_start="$(sed -n '/function startStatusPoll()/,/^	}$/p' "$_ts_js")"

	# The runtime panel used to be the snapshot the page opened with: it could
	# still say "Running, uptime 26s" about a process restarted minutes ago.
	# Basic Information already polls the same call every two seconds, and the
	# status call is the cheap one, so Configuration follows the same cadence.
	assert_contains "$_ts_start" 'setInterval(pollStatus, 2000)' \
		"the runtime panel polls status every two seconds"
	assert_contains "$_ts_poll" '.then(refreshAll)' \
		"the poll redraws both panels from the one batched call"
	assert_contains "$_ts_poll" 'document.hidden' \
		"a hidden tab does not poll"
	assert_contains "$_ts_poll" 'statusBusy' \
		"and a slow answer is not overlapped by the next tick"
	assert_contains "$_ts_start" "addEventListener('visibilitychange', pollStatus)" \
		"coming back to the tab refreshes before the next interval"
	assert_contains "$_ts_start" "addEventListener('beforeunload'" \
		"leaving the page stops the timer"

	# The LAN panel is a different cost: its status is an SSH connection, not a
	# fork. It must stay out of this poll, or the router dials the remote every
	# two seconds.
	assert_not_contains "$_ts_poll" 'loadRemote' \
		"the LAN panel is not polled"
	assert_contains "$(cat "$_ts_js")" 'startStatusPoll();' \
		"init starts the poll after the first status answer"

	# Deleting the two rows was the other candidate; the fields stay because
	# DESIGN_SPEC 14.3 lists them.
	assert_contains "$(cat "$_ts_js")" "FCC._('Uptime')" \
		"the panel still shows the uptime the spec asks for"
	assert_contains "$(cat "$_ts_js")" "FCC._('Memory (RSS)')" \
		"and the RSS beside it"
}

test_malformed_response_is_translated() {
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-common.js"
	_ts_po="$ROOT/po/zh_Hans/fcc.po"

	# The API client builds this sentence itself, so it only reaches the
	# catalogue if it goes through FCC._. It did not, and showed in English on
	# a Chinese page.
	assert_contains "$(cat "$_ts_js")" \
		"window.FCC._('Malformed response from the router')" \
		"the API client's own error goes through the translator"
	assert_contains "$(grep -A1 'msgid "Malformed response from the router"' "$_ts_po")" \
		'msgstr "路由器返回的响应无法解析"' \
		"and has a Chinese translation"
}

test_agent_information_is_opt_in_and_named() {
	_ts_info="$ROOT/luasrc/view/fcc/info.htm"
	_ts_js="$ROOT/htdocs/luci-static/resources/fcc/fcc-info.js"

	# One button for state and versions, and a second one that puts the
	# section back to empty.
	_ts_toolbar="$(sed -n '/id="fcc-info-agent-versions"/,/<\/div>/p' "$_ts_info")"
	assert_contains "$(cat "$_ts_info")" '<%:Version status%>' \
		"the agent button names what it shows"
	assert_not_contains "$(cat "$_ts_info")" '<%:Re-detect versions%>' \
		"and no longer says re-detect"
	assert_contains "$_ts_toolbar" 'id="fcc-info-agent-clear"' \
		"Clear information follows it in the same toolbar"
	assert_contains "$(cat "$_ts_info")" '<%:Clear information%>' \
		"and is named for what it clears"
	assert_contains "$(cat "$_ts_info")" 'id="fcc-info-agents" hidden' \
		"the table starts hidden"

	# Nothing is detected on entry: the render is gated, and the per-minute
	# version refresh is gated with it, so a tab left open on another page
	# costs no agent processes.
	assert_contains "$(cat "$_ts_js")" 'if (agentShown) { renderAgents(' \
		"the table is drawn only once asked for"
	assert_contains "$(cat "$_ts_js")" 'if (!agentShown) { return; }' \
		"the version refresh does not run while the table is cleared"
	_ts_init="$(sed -n '/^	function init()/,/^	}$/p' "$_ts_js")"
	assert_not_contains "$_ts_init" 'agent_versions' \
		"opening the tab does not run a version detection"

	# Version status turns the table on before it asks the backend;
	# Clear information turns it off and empties what is on screen.
	assert_contains "$(cat "$_ts_js")" 'agentShown = true;' \
		"the button shows the table"
	assert_contains "$(cat "$_ts_js")" 'agentShown = false;' \
		"clearing hides it again"
	assert_contains "$(cat "$_ts_js")" 'table.hidden = true;' \
		"and removes it from view"
	assert_contains "$(cat "$_ts_js")" \
		"FCC.\$('#fcc-info-agent-clear').addEventListener('click', clearAgentInfo)" \
		"the clear button is wired"
	assert_contains "$(cat "$_ts_js")" "FCC.\$('#fcc-info-agent-status').textContent = ''" \
		"clearing also drops the detection sentence"
}

tests_main
