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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The install block of the main package, with comment lines removed.
install_block() {
	sed -n '/^define Package\/luci-app-fcc\/install$/,/^endef$/p' "$MAKEFILE" \
		| grep -v '^[[:space:]]*#'
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

test_both_packages_are_declared() {
	assert_contains "$(cat "$MAKEFILE")" 'define Package/luci-app-fcc' "the app package is declared"
	assert_contains "$(cat "$MAKEFILE")" 'define Package/luci-i18n-fcc-zh-cn' "the zh-cn i18n package is declared"
	assert_contains "$(cat "$MAKEFILE")" '$(eval $(call BuildPackage,luci-app-fcc))' "the app package is built"
	assert_contains "$(cat "$MAKEFILE")" '$(eval $(call BuildPackage,luci-i18n-fcc-zh-cn))' "the i18n package is built"
}

test_packages_are_architecture_independent() {
	# This package is a pure control layer: Lua, JS and ash. Anything it ships
	# is interpreted, so PKGARCH:=all is what lets one .ipk serve every target.
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
	# Every dependency should be a thing the code actually calls. These four are
	# the ones the backend shells out to.
	_ts_depends="$(sed -n '/^define Package\/luci-app-fcc$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	for _ts_d in luci-base luci-compat curl ca-bundle tar tmux; do
		case "$_ts_depends" in
			*"+$_ts_d"*) pass ;;
			*) fail "DEPENDS is missing +$_ts_d: [$_ts_depends]" ;;
		esac
	done
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
# The i18n package
# ---------------------------------------------------------------------------

test_i18n_package_is_wired_up() {
	assert_file "$ROOT/po/zh_Hans/fcc.po"
	assert_file "$ROOT/po/templates/fcc.pot"
	assert_contains "$(cat "$MAKEFILE")" 'po2lmo ./po/zh_Hans/fcc.po' "the .po is compiled with po2lmo"
	assert_contains "$(cat "$MAKEFILE")" 'fcc.zh-cn.lmo' "the .lmo uses LuCI's zh-cn language code"
	assert_contains "$(cat "$MAKEFILE")" 'PKG_BUILD_DEPENDS:=luci-base/host' \
		"po2lmo is available as a host tool"
}

test_i18n_auto_selects_with_the_language() {
	# LuCI has no luci-i18n-<lang> meta package: the DEFAULT line is what makes
	# menuconfig's language selection pull this package in.
	assert_contains "$(cat "$MAKEFILE")" 'DEFAULT:=LUCI_LANG_zh_Hans' \
		"the i18n package is selected by the zh_Hans language option"
}

test_i18n_package_depends_on_the_app() {
	_ts_depends="$(sed -n '/^define Package\/luci-i18n-fcc-zh-cn$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	assert_eq "+luci-app-fcc" "$_ts_depends" "the translation depends on the app"
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
		case "$_ts_acl" in
			*"/usr/libexec/fcc/$_ts_b"*) : ;;
			*) _ts_bad="$_ts_bad $_ts_b" ;;
		esac
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every backend script is in the ACL"
}

tests_main
